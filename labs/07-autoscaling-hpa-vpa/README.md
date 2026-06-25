# Lab 07 — HPA + VPA: Autoscaling Deep Dive

> **Goal:** Understand every lever GKE gives you for scaling workloads automatically — from
> CPU-based HPA to custom Prometheus metrics, from VPA recommendation mode to Cluster Autoscaler
> node scale-out, and how Spot node pools interact with preemption events. By the end you should
> be able to design a production autoscaling strategy and explain every trade-off.

> **Series position:** Lab 06 covered Helm deployments. This lab builds on the `payments`
> namespace and the node pool structure created in Lab 01. You need a running cluster before
> proceeding.

---

## Table of Contents

1. [HPA vs VPA vs KEDA — When to Use Each](#1-hpa-vs-vpa-vs-keda--when-to-use-each)
2. [HPA Deep Dive — Cooldown, Scale-Down Stabilization, Custom Metrics](#2-hpa-deep-dive--cooldown-scale-down-stabilization-custom-metrics)
3. [Writing a Custom Metrics HPA with Prometheus Adapter](#3-writing-a-custom-metrics-hpa-with-prometheus-adapter)
4. [VPA Modes — Off, Initial, Auto — and Why Auto Is Dangerous in Production](#4-vpa-modes--off-initial-auto--and-why-auto-is-dangerous-in-production)
5. [Cluster Autoscaler — How Node Scale-Out Is Triggered](#5-cluster-autoscaler--how-node-scale-out-is-triggered)
6. [Spot Node Pools and Graceful Handling of Preemptions](#6-spot-node-pools-and-graceful-handling-of-preemptions)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. HPA vs VPA vs KEDA — When to Use Each

Three autoscalers exist in the Kubernetes ecosystem. They solve different problems and can
coexist — but combining them carelessly leads to oscillation, OOMKills, and eviction loops.

### What Each Autoscaler Does

```
HPA (HorizontalPodAutoscaler)
  └─ Adds/removes Pod replicas
  └─ Reacts to: CPU, memory, custom metrics, external metrics
  └─ Result: more (or fewer) identical pods running

VPA (VerticalPodAutoscaler)
  └─ Changes the CPU/memory requests+limits on a running pod
  └─ Reacts to: actual resource usage observed over time
  └─ Result: the same pod count, but each pod is bigger or smaller

KEDA (Kubernetes Event-Driven Autoscaler)
  └─ Scales pods to zero, then from zero, based on event queue depth
  └─ Reacts to: Kafka lag, SQS queue depth, Redis list length, cron schedules
  └─ Result: pods exist only when there is work to process
```

### Feature Comparison

| Dimension | **HPA** | **VPA** | **KEDA** |
|-----------|---------|---------|---------|
| Scaling axis | Horizontal (replica count) | Vertical (resource size) | Horizontal (0 → N) |
| Built into GKE? | Yes | Yes (via addon) | No — separate Helm install |
| Scale to zero | No (min=1) | No | Yes |
| Reaction speed | Fast (~15–30s) | Slow (hours) | Near-real-time |
| Causes pod restart? | No | Yes (in Auto mode) | No |
| Good for | Stateless services, bursty traffic | Right-sizing singleton/stateful services | Queue processors, batch, cron |
| Conflicts | VPA Auto + HPA on same resource | Conflicts with HPA | Works with HPA on different metrics |
| Custom metrics needed | Optional | No | Required (event source) |

### Decision Framework

```
Does your workload need to handle traffic spikes?
  YES → Is traffic bursty and unpredictable?
          YES → HPA on CPU or request rate
        Is there a queue or event source driving load?
          YES → KEDA
          NO  → HPA on CPU

Is your workload a singleton (statefulset, single-replica DB sidecar)?
  YES → VPA in Recommendation or Initial mode

Do you need to scale to zero during off-hours?
  YES → KEDA (only autoscaler that can scale to zero)

Are you unsure what requests/limits to set for a new service?
  YES → VPA in Off mode for 24–72 hours, read recommendations, set manually
```

**For the `payments` namespace in this lab:** The `payments-api` deployment uses HPA on request
rate (via Prometheus Adapter). The `payments-worker` deployment uses KEDA on Redis list depth.

---

## 2. HPA Deep Dive — Cooldown, Scale-Down Stabilization, Custom Metrics

### The HPA Algorithm

The HPA controller runs every 15 seconds (configurable) and evaluates:

```
desiredReplicas = ceil(currentReplicas × (currentMetricValue / desiredMetricValue))

Example:
  currentReplicas: 4
  currentCPU:      70%
  targetCPU:       50%
  
  desiredReplicas = ceil(4 × (70 / 50)) = ceil(5.6) = 6
```

The ceiling ensures you never round down when under pressure.

### Scale-Up vs Scale-Down Behaviour

```
Scale-UP:
  • Happens aggressively — HPA can triple replica count in one evaluation
  • Only cooldown: --horizontal-pod-autoscaler-upscale-delay (default: 3 min on older K8s)
  • On K8s 1.18+ (GKE): controlled by scaleUp.stabilizationWindowSeconds

Scale-DOWN:
  • Happens conservatively by default
  • stabilizationWindowSeconds: 300 (5 min) — HPA looks at the HIGH WATERMARK
    of desired replicas over the last 5 minutes before scaling down
  • Prevents thrashing when traffic is spiky
```

### Full HPA Spec with Stabilization Windows

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 2
  maxReplicas: 20

  metrics:
    # Primary metric: CPU utilization
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60   # Target 60% CPU across all pods

    # Secondary metric: memory (HPA scales when EITHER threshold is breached)
    - type: Resource
      resource:
        name: memory
        target:
          type: AverageValue
          averageValue: 400Mi      # Target 400Mi average memory per pod

  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60    # Only 60s window on scale-up (respond fast)
      policies:
        - type: Percent
          value: 100                    # Can double replicas per period
          periodSeconds: 60
        - type: Pods
          value: 4                      # Or add max 4 pods per period
          periodSeconds: 60
      selectPolicy: Max                 # Use whichever policy adds MORE pods

    scaleDown:
      stabilizationWindowSeconds: 300   # 5-minute window before scaling down
      policies:
        - type: Percent
          value: 25                     # Remove max 25% of replicas per period
          periodSeconds: 120
      selectPolicy: Min                 # Use whichever policy removes FEWER pods
```

### Reading HPA Status

```bash
# Summary view
kubectl get hpa -n payments

# Sample output:
# NAME           REFERENCE              TARGETS          MINPODS   MAXPODS   REPLICAS
# payments-api   Deployment/payments-api 45%/60%, 280Mi/400Mi   2         20        4

# Detailed status including recent events
kubectl describe hpa payments-api -n payments

# Key sections to read:
# Conditions:
#   AbleToScale:     True  (ScaleDownStabilized or DesiredWithinRange)
#   ScalingActive:   True  (ValidMetricFound)
#   ScalingLimited:  False (no min/max breach)
#
# Events:
#   Normal  SuccessfulRescale  Scaled up replica set to 6 replicas
#   Normal  SuccessfulRescale  Scaled down replica set to 4 replicas

# Watch HPA events in real time
kubectl get events -n payments --field-selector reason=SuccessfulRescale -w
```

---

## 3. Writing a Custom Metrics HPA with Prometheus Adapter

CPU and memory alone are often poor proxies for application load. A payments API that spends
most of its time waiting for Cloud SQL doesn't show high CPU even at saturation. Better signal:
**request rate** or **queue depth**.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GKE Cluster                                  │
│                                                                      │
│  payments-api ──scrape──► Prometheus ──► Prometheus Adapter          │
│                                              │                       │
│                                              │ /apis/custom.metrics  │
│                                              │                       │
│                           HPA controller ◄───┘                       │
│                               │                                      │
│                               └──► scale payments-api replicas       │
└─────────────────────────────────────────────────────────────────────┘
```

The Prometheus Adapter bridges Prometheus metrics into the Kubernetes custom metrics API.
The HPA controller polls `custom.metrics.k8s.io` every 15 seconds.

### Step 1 — Instrument Your Application

Your `payments-api` must expose a Prometheus counter. Example in Python:

```python
from prometheus_client import Counter, start_http_server

http_requests_total = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status']
)

# In your request handler:
http_requests_total.labels(method='POST', endpoint='/payments', status='200').inc()

# Expose metrics on :8080/metrics
start_http_server(8080)
```

The scrape annotation on the Deployment:
```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port:   "8080"
    prometheus.io/path:   "/metrics"
```

### Step 2 — Install Prometheus Adapter

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus-adapter \
  prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.url=http://prometheus-operated.monitoring \
  --set prometheus.port=9090
```

### Step 3 — Configure the Adapter Rule

Create a custom metrics rule that turns `http_requests_total` into a per-pod rate:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-adapter-config
  namespace: monitoring
data:
  config.yaml: |
    rules:
      - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
        resources:
          overrides:
            namespace:
              resource: namespace
            pod:
              resource: pod
        name:
          matches: "^(.*)_total$"
          as: "${1}_per_second"
        metricsQuery: |
          sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)
EOF

# Restart adapter to pick up the new config
kubectl rollout restart deployment/prometheus-adapter -n monitoring
kubectl rollout status deployment/prometheus-adapter -n monitoring

# Verify the metric is visible in the custom metrics API
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/payments/pods/*/http_requests_per_second | jq .
```

### Step 4 — Create the Custom Metrics HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api-rps
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 2
  maxReplicas: 20

  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second    # Name from adapter rule
        target:
          type: AverageValue
          averageValue: "50"                # Scale when avg pod handles > 50 rps

  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
```

```bash
kubectl apply -f hpa-custom-metrics.yaml

# Trigger load and watch scaling
kubectl run load-test \
  --image=busybox \
  --rm -it \
  --restart=Never \
  --namespace=payments \
  -- /bin/sh -c "while true; do wget -qO- http://payments-api/health; done"

# In another terminal
kubectl get hpa payments-api-rps -n payments -w
```

---

## 4. VPA Modes — Off, Initial, Auto — and Why Auto Is Dangerous in Production

### VPA Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      VPA Components                       │
│                                                          │
│  VPA Admission Controller  ←──── Webhook (pod creation)  │
│                                                          │
│  VPA Recommender ──────────────► watches pod metrics      │
│         │                        writes recommendations   │
│         ▼                                                │
│  VPA object (recommendations)                            │
│                                                          │
│  VPA Updater ──────────────────► evicts pods to apply    │
│                                  new requests (Auto mode) │
└──────────────────────────────────────────────────────────┘
```

### The Three Modes

```yaml
# Mode: Off — read-only recommendations, no action taken
updatePolicy:
  updateMode: "Off"
# Use case: right-sizing analysis for a new service; run for 48-72h, then
# read spec.recommendation.containerRecommendations and manually update your
# Deployment's requests/limits.

# Mode: Initial — applies recommendations at pod creation only
updatePolicy:
  updateMode: "Initial"
# Use case: ephemeral environments, batch jobs where pods start fresh.
# Does NOT evict running pods. Safe for production stateless services.

# Mode: Auto — evicts and recreates pods to apply new recommendations
updatePolicy:
  updateMode: "Auto"
# Use case: development/staging only. DO NOT use in production without
# understanding the consequences (see below).
```

### Full VPA Spec

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: payments-api-vpa
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api

  updatePolicy:
    updateMode: "Off"    # Safe starting point

  resourcePolicy:
    containerPolicies:
      - containerName: payments-api
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
        controlledResources: ["cpu", "memory"]
        # Prevent VPA from touching limits (only adjust requests):
        controlledValues: RequestsOnly
```

### Reading VPA Recommendations

```bash
# Install VPA (GKE has it as an addon)
gcloud container clusters update gke-labs-dev \
  --enable-vertical-pod-autoscaling \
  --region=europe-west1 \
  --project=gke-labs

# Apply VPA object
kubectl apply -f payments-api-vpa.yaml

# Wait 24 hours for the Recommender to observe traffic patterns
# Then read recommendations:
kubectl describe vpa payments-api-vpa -n payments
```

Sample recommendation output:
```
Status:
  Recommendation:
    Container Recommendations:
      Container Name: payments-api
      Lower Bound:
        Cpu:     25m
        Memory:  52Mi
      Target:                     ← USE THIS for your Deployment
        Cpu:     120m
        Memory:  180Mi
      Uncapped Target:
        Cpu:     115m
        Memory:  175Mi
      Upper Bound:
        Cpu:     1200m
        Memory:  1800Mi
```

The **Target** is what VPA would set as your requests. Apply this to your Deployment manually:

```bash
kubectl set resources deployment/payments-api \
  -c payments-api \
  --requests=cpu=120m,memory=180Mi \
  --limits=cpu=500m,memory=360Mi \
  -n payments
```

### Why Auto Mode Is Dangerous in Production

VPA Auto mode evicts pods to resize them. Eviction looks like:

```
VPA Updater: "cpu request should be 120m, currently 500m — evict pod"
  │
  └─► Pod is deleted (triggers graceful termination)
  └─► New pod starts with 120m CPU request
  └─► Under traffic: you may briefly have 0 ready pods if minReplicas = 1
  └─► Under traffic spike: VPA may evict the pod RIGHT when you need it most
```

**Specific risks:**

1. **VPA + HPA conflict**: If HPA is scaling based on CPU and VPA shrinks the CPU request, HPA
   recalculates and may scale down replicas — reducing capacity while load is high.

2. **Eviction during peak traffic**: The VPA Updater does not know about your traffic patterns.
   A pod eviction at 14:00 during a payments spike causes dropped requests.

3. **PodDisruptionBudget bypass**: In some older VPA versions, the Updater doesn't respect PDBs
   correctly. Test carefully before enabling Auto mode.

**Safe production pattern**: Use `Off` mode continuously, read recommendations weekly, and
apply them as part of your release process — not automatically.

---

## 5. Cluster Autoscaler — How Node Scale-Out Is Triggered

### The CA Decision Loop

```
Every 10 seconds, Cluster Autoscaler checks:
  1. Are there any Pending pods?
  2. If yes: can any existing node pool accommodate them?
     YES → wait, maybe a node just freed up
     NO  → find a node pool whose instances, if added, would allow scheduling
  3. Add a node to that pool (via MIG resize)
  4. Wait for the node to become Ready (~2-3 minutes)
  5. Kubernetes scheduler places the pending pods

Every 10 seconds, CA also checks:
  1. Are there underutilized nodes? (< 50% of requested resources for 10+ min)
  2. Can all pods on that node fit on other nodes?
     YES → drain and delete the node
     NO  → leave it
```

### What Causes Scale-Out

```bash
# Simulate a scale-out by deploying more pods than fit on current nodes
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-trigger
  namespace: payments
spec:
  replicas: 20
  selector:
    matchLabels:
      app: scale-trigger
  template:
    metadata:
      labels:
        app: scale-trigger
    spec:
      tolerations:
        - key: "workload"
          operator: "Equal"
          value: "application"
          effect: "NoSchedule"
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 500m       # Each pod requests 500m CPU
              memory: 256Mi
EOF

# Watch pods go Pending and then CA add nodes
kubectl get pods -n payments -l app=scale-trigger -w &
watch -n 5 "kubectl get nodes -o wide"
```

### Reading CA Logs

```bash
# CA logs are in kube-system
kubectl logs -n kube-system -l component=cluster-autoscaler --tail=100 | \
  grep -E "scale_up|scale_down|pending|trigger"

# Sample log output:
# I0615 12:34:01 scale_up.go:468] Scale-up: setting group
#   gke-gke-labs-dev-application-pool-abc to size 3
# I0615 12:34:01 scale_up.go:500] 3 unschedulable pods were scheduled
```

### CA Configuration — Expander Policy

When multiple node pools can accommodate pending pods, CA uses an **expander** to choose:

```bash
# Check current expander policy
gcloud container clusters describe gke-labs-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(autoscaling.autoscalingProfile)"

# Expander options:
# random      — pick a random eligible pool (default)
# most-pods   — pick the pool that can schedule the most pending pods
# least-waste — pick the pool that wastes the least CPU/memory
# price       — pick the cheapest pool (Spot first)
# priority    — pick based on user-defined priority list

# Set to least-waste for cost efficiency:
gcloud container clusters update gke-labs-dev \
  --autoscaling-profile=optimize-utilization \
  --region=europe-west1 \
  --project=gke-labs
```

### Scale-Down Safeguards

CA will NOT remove a node if:
- Any pod on it has no controller (naked pods)
- Any pod has a local storage request (`emptyDir`, `hostPath`)
- A PodDisruptionBudget would be violated
- The node has the `cluster-autoscaler.kubernetes.io/scale-down-disabled: "true"` annotation
- Pod has `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` annotation

```bash
# Prevent CA from removing a node (e.g., during incident investigation)
kubectl annotate node gke-gke-labs-dev-application-pool-abc-0001 \
  cluster-autoscaler.kubernetes.io/scale-down-disabled=true

# Allow CA to evict a pod that would otherwise block scale-down
kubectl annotate pod my-pod -n payments \
  cluster-autoscaler.kubernetes.io/safe-to-evict=true
```

---

## 6. Spot Node Pools and Graceful Handling of Preemptions

### What Is a Spot Node?

GCP Spot VMs are spare compute capacity offered at up to 91% discount. The trade-off:
**GCP can reclaim Spot VMs with a 30-second warning at any time.**

```
Regular VM:
  Cost: $0.19/hr (e2-standard-4)
  Availability: Guaranteed
  Use for: payments-api, auth-service, any latency-sensitive service

Spot VM:
  Cost: $0.05/hr (e2-standard-4 spot) — up to 73% cheaper
  Availability: Not guaranteed — preempted when GCP needs capacity
  Use for: batch workers, ML training, CI/CD runners, queue processors
```

### How GKE Signals Preemption

When GCP decides to reclaim a Spot node:

```
1. GCP sends SIGTERM to all pods on the node (via the node's shutdown signal)
2. GKE fires a Node "Shutdown" event
3. Kubelet starts the graceful shutdown sequence:
   - Sets node condition: "Ready: False"
   - Starts pod graceful termination (sends SIGTERM to containers)
   - Waits up to terminationGracePeriodSeconds (default 30s)
   - Sends SIGKILL if pods haven't exited
4. Node disappears from kubectl get nodes
5. Cluster Autoscaler detects the missing node
6. CA adds a new Spot node (or regular node if Spot capacity exhausted)
```

### Configuring Graceful Shutdown

```yaml
# In your spot-targeted Deployment:
spec:
  template:
    spec:
      tolerations:
        - key: "cloud.google.com/gke-spot"
          operator: "Equal"
          value: "true"
          effect: "NoSchedule"
      nodeSelector:
        cloud.google.com/gke-spot: "true"

      # Give pods enough time to finish in-flight work
      terminationGracePeriodSeconds: 60

      containers:
        - name: payments-worker
          image: europe-west1-docker.pkg.dev/gke-labs/payments/worker:latest

          # Handle SIGTERM gracefully in your application code
          lifecycle:
            preStop:
              exec:
                # Drain the current job before the container is killed
                command: ["/bin/sh", "-c", "kill -SIGTERM 1 && sleep 5"]

          resources:
            requests:
              cpu: 500m
              memory: 512Mi
```

### Using PodDisruptionBudget with Spot Nodes

PDB protects your service from too many pods being evicted simultaneously:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-worker-pdb
  namespace: payments
spec:
  minAvailable: 1         # Always keep at least 1 worker running
  selector:
    matchLabels:
      app: payments-worker
```

> **Note:** PDB does NOT prevent Spot preemption — GCP's preemption bypasses the Kubernetes
> eviction API. PDB only applies to voluntary disruptions (CA scale-down, node drain, upgrades).
> Design Spot workloads to be resumable, not PDB-protected.

### KEDA + Spot Pattern for Queue Workers

The most cost-effective pattern for batch workloads:

```yaml
# ScaledObject: scale payments-worker based on Redis queue depth
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: payments-worker-scaler
  namespace: payments
spec:
  scaleTargetRef:
    name: payments-worker
  minReplicaCount: 0       # Scale to zero when queue is empty (cost = $0)
  maxReplicaCount: 50
  triggers:
    - type: redis
      metadata:
        address: redis-master.payments.svc.cluster.local:6379
        listName: payment-jobs
        listLength: "10"   # One worker per 10 jobs in queue
```

```bash
# Install KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace

# Apply the ScaledObject
kubectl apply -f payments-worker-scaledobject.yaml

# Watch KEDA scale workers as jobs arrive
kubectl get pods -n payments -l app=payments-worker -w
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1: HPA Thrashing

**What we're testing:** Scale-down stabilization window prevents thrashing under oscillating load.

```bash
# === SETUP ===
# Deploy payments-api with an HPA that has NO stabilization window
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api-thrash
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 0    # <── The problem: no stabilization
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
EOF

# === BREAK IT ===
# Run oscillating load: 30s on, 30s off, repeat
for round in 1 2 3 4 5; do
  echo "=== Round $round: Loading ===" 
  kubectl run load-$round \
    --image=busybox \
    --restart=Never \
    --namespace=payments \
    -- /bin/sh -c "for i in \$(seq 1 1000); do wget -qO- http://payments-api/health; done" &
  sleep 30
  kubectl delete pod load-$round -n payments 2>/dev/null
  echo "=== Round $round: Idle (30s) ===" 
  sleep 30
done &

# Watch the thrashing: replicas jumping between 1 and 8+ every minute
kubectl get hpa payments-api-thrash -n payments -w

# === OBSERVE ===
kubectl describe hpa payments-api-thrash -n payments | grep -A 20 "Events:"
# You'll see rapid scale-up / scale-down cycles — wasteful and disruptive

# === FIX IT ===
kubectl patch hpa payments-api-thrash -n payments --type=merge -p='{
  "spec": {
    "behavior": {
      "scaleDown": {
        "stabilizationWindowSeconds": 300,
        "policies": [{"type": "Percent", "value": 25, "periodSeconds": 60}]
      }
    }
  }
}'

# Rerun the load pattern and observe stable replica count
```

**What you learned:** Without a stabilization window, HPA reacts to every 15-second metric
snapshot. The 5-minute window looks at the worst case over that window — keeping replicas high
during bursty load and reducing them gradually afterward.

---

### Exercise 2: VPA Evicts a Pod Under Traffic

**What we're testing:** Understanding why VPA Auto mode is dangerous when live traffic is flowing.

```bash
# === SETUP ===
# Apply VPA in Auto mode with a very low initial CPU request
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: payments-api-auto-vpa
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
      - containerName: payments-api
        minAllowed:
          cpu: 10m
          memory: 32Mi
        maxAllowed:
          cpu: 1
          memory: 1Gi
EOF

# Force a suboptimal resource setting that VPA will immediately want to change
kubectl set resources deployment/payments-api \
  -c payments-api \
  --requests=cpu=1000m,memory=1Gi \
  --limits=cpu=2000m,memory=2Gi \
  -n payments

# === BREAK IT ===
# Start continuous traffic
kubectl run live-traffic \
  --image=busybox \
  --restart=Never \
  --namespace=payments \
  -- /bin/sh -c "while true; do wget -qO- http://payments-api/health; sleep 0.1; done" &

# VPA Updater will evict the pod to apply its "correct" resource recommendation
# Watch for pod evictions
kubectl get pods -n payments -l app=payments-api -w

# === OBSERVE ===
# The VPA-triggered eviction log
kubectl get events -n payments | grep -i "evict\|vpa\|vertical"

# Requests that were in-flight during the eviction will fail
kubectl logs -n payments -l app=payments-api --previous | tail -20

# === FIX IT ===
# Switch VPA back to Off mode — apply recommendations manually during a maintenance window
kubectl patch vpa payments-api-auto-vpa -n payments --type=merge -p='{
  "spec": {"updatePolicy": {"updateMode": "Off"}}
}'

# Read the recommendation
kubectl describe vpa payments-api-auto-vpa -n payments | grep -A 20 "Recommendation:"

# Apply manually during a low-traffic window
# kubectl set resources deployment/payments-api -c payments-api \
#   --requests=cpu=120m,memory=180Mi --limits=cpu=500m,memory=360Mi -n payments

# Cleanup
kubectl delete pod live-traffic -n payments 2>/dev/null
kubectl delete vpa payments-api-auto-vpa -n payments
```

---

### Exercise 3: Cluster Autoscaler Blocked by PodDisruptionBudget

```bash
# === SETUP ===
# Create a PDB that prevents CA from draining a node
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api-pdb-strict
  namespace: payments
spec:
  maxUnavailable: 0    # <── Problem: zero allowed disruptions
  selector:
    matchLabels:
      app: payments-api
EOF

# Scale to exactly 1 replica
kubectl scale deployment payments-api -n payments --replicas=1

# === BREAK IT ===
# Now try to drain a node (simulating a scale-down or node upgrade)
NODE=$(kubectl get nodes -l node-pool=application -o name | head -1)
kubectl drain ${NODE} --ignore-daemonsets --delete-emptydir-data

# === OBSERVE ===
# Expected error:
# error when evicting pods/payments-api-xxxxx in namespace "payments":
# Cannot evict pod as it would violate the pod's disruption budget.

# The drain hangs — CA can't scale down this node either

# === FIX IT ===
# Option 1: Allow at least 1 unavailable pod
kubectl patch pdb payments-api-pdb-strict -n payments --type=merge -p='{
  "spec": {"maxUnavailable": 1}
}'

# Option 2: Use minAvailable instead (allows scale-down when replicas > minimum)
# kubectl delete pdb payments-api-pdb-strict -n payments
# kubectl apply -f - <<YAML
# apiVersion: policy/v1
# kind: PodDisruptionBudget
# ...
#   spec:
#     minAvailable: 1  # As long as ≥1 pod is running, eviction is allowed
# YAML

# Resume the drain after fixing the PDB
kubectl drain ${NODE} --ignore-daemonsets --delete-emptydir-data
kubectl uncordon ${NODE}
```

---

## 8. Interview Q&A

---

### Q1: Explain the HPA algorithm. If you have 4 replicas at 70% CPU and your target is 50%, how many replicas does HPA request?

**Answer:**

The HPA formula is:

```
desiredReplicas = ceil(currentReplicas × (currentMetric / targetMetric))
                = ceil(4 × (70 / 50))
                = ceil(5.6)
                = 6
```

HPA always rounds up (ceiling) to avoid under-provisioning under load. The evaluation runs
every 15 seconds by default (`--horizontal-pod-autoscaler-sync-period`).

One nuance: HPA uses **average** CPU across all pods, not total. If one pod is at 90% and three
are at 60%, the average is 67.5% — below the threshold — and HPA won't scale despite the hot pod.
This is why CPU-based HPA works best for stateless services where load is uniformly distributed.

---

### Q2: When would you use KEDA instead of HPA, and when would you combine them?

**Answer:**

Use **KEDA** when:
- You need to scale to **zero** (HPA minimum is 1)
- Your scaling signal is an **external event source**: Kafka consumer group lag, SQS queue depth,
  Redis list length, Cloud PubSub subscriptions, or a cron schedule
- Your workload is batch-oriented — workers that consume jobs, not servers that handle requests

Use **HPA** when:
- Your service must always have at least 1 replica ready
- You're scaling on CPU, memory, or a request rate metric
- The workload is a long-running server, not a batch consumer

**Combining them:** KEDA implements the same `autoscaling/v2` HPA spec under the hood. When you
create a `ScaledObject`, KEDA creates and manages an HPA object on your behalf. You shouldn't
create both a `ScaledObject` and a manual HPA for the same deployment.

The valid combination: KEDA on one deployment (workers), HPA on another (API servers) — both
in the same namespace, scaling different deployments.

---

### Q3: What are the three VPA modes and which is safe for production?

**Answer:**

- **Off**: The Recommender observes and writes recommendations to the VPA status object, but no
  action is taken. Pods run with whatever requests/limits your Deployment spec says. The safest
  mode — use it to collect right-sizing data without any operational impact.

- **Initial**: Recommendations are applied when a pod is first created (admission webhook
  mutates the pod spec). Running pods are not touched. Safe for production if you understand
  that new pods will have different resources than your Deployment spec says.

- **Auto**: VPA evicts running pods and recreates them with the recommended resource settings.
  The Updater makes this decision autonomously, without respecting your traffic patterns or
  deployment windows.

**Production recommendation**: Use **Off** mode permanently for the Recommender to collect
data. Once a week, read `kubectl describe vpa` and manually apply the Target recommendation to
your Deployment's `resources.requests`. This gives you the right-sizing benefit without
autonomous evictions.

The one exception: Autopilot GKE clusters manage VPA automatically — in that context, VPA Auto
is safe because Autopilot controls the entire lifecycle.

---

### Q4: A pending pod never gets scheduled even though the Cluster Autoscaler is enabled. What are the possible causes?

**Answer:**

CA will NOT add nodes for pods that are unschedulable for reasons other than resource shortage:

1. **Taint mismatch**: The pod has no toleration for any existing node pool's taint. CA won't
   add a node because the pod would still be rejected.
   ```bash
   kubectl describe pod <pending> | grep "had untolerated taint"
   ```

2. **NodeSelector / NodeAffinity**: Pod requires a label (`zone=eu-west1-b`) that no node pool
   provides. CA can't create nodes with arbitrary labels.

3. **PodAffinity / Anti-affinity**: Pod requires co-location with or separation from other
   pods that constrains which nodes are valid.

4. **maxReplicas reached**: CA can't exceed the node pool's `maxNodeCount`.

5. **CA disabled on the pool**: Node pool has `autoscaling: false`.

6. **LimitRange / ResourceQuota**: Namespace quota exhausted — no amount of nodes will fix a
   quota violation.

7. **Spot capacity exhausted**: Spot node pool can't be expanded because GCP has no Spot VM
   capacity in the region at that moment. CA will try the regular pool if configured.

```bash
# Check CA logs for the specific reason
kubectl logs -n kube-system -l component=cluster-autoscaler | grep "cannot"
```

---

### Q5: How do HPA and Cluster Autoscaler work together? Trace the sequence from a traffic spike to a new node being ready.

**Answer:**

```
T+0s:   Traffic spike begins. Pods start using more CPU.

T+15s:  HPA controller evaluates metrics.
        desiredReplicas = 8, currentReplicas = 3 → scale up to 8.
        HPA sends PATCH to the Deployment: replicas=8.

T+16s:  ReplicaSet controller creates 5 new pods.
        Scheduler tries to place them. Current nodes have capacity for 2.
        3 pods go Pending ("Insufficient CPU").

T+30s:  Cluster Autoscaler polls for pending pods.
        Finds 3 pending pods that could be scheduled on a new node.
        Calls the GCP API to resize the application-pool MIG: +1 node.
        (CA may request +1 more if it predicts further scale-up.)

T+90s:  New node VM is provisioned and boots.
        Kubelet starts, node registers with the API server.
        Node status: NotReady (kubelet is connecting).

T+120s: Node reaches Ready status.
        Scheduler places the 3 pending pods on the new node.
        Pods transition from Pending → ContainerCreating → Running.

T+135s: All 8 replicas are Running. Traffic is handled.
```

Key insight: there is a **2–3 minute gap** between HPA requesting more pods and those pods
being able to run on a new node. Design your HPA `minReplicas` to handle expected burst traffic
without needing a new node, and use CA as a safety net for sustained growth.

---

### Q6: What happens to a Spot node when GCP preempts it? How do you minimize the impact?

**Answer:**

GCP preemption sequence:
1. GCP sends a shutdown signal to the VM
2. The OS propagates SIGTERM to all processes (including kubelet)
3. Kubelet begins graceful pod termination: sends SIGTERM to containers, waits up to
   `terminationGracePeriodSeconds` (default 30s), then SIGKILL
4. The node disappears from the cluster; Cluster Autoscaler detects the missing node
5. CA adds a replacement node (could be Spot again, or regular if Spot is exhausted)
6. Pods that were on the preempted node restart on the new node

**Minimizing impact:**

1. **Only schedule fault-tolerant workloads on Spot**: batch workers, ML jobs, CI runners —
   never payments-api, auth-service, or databases.

2. **Set `terminationGracePeriodSeconds`**: Long enough to finish in-flight work. For a queue
   worker that processes 5-second jobs, set it to at least 30s.

3. **Use job checkpointing**: Batch jobs should save progress (write to GCS or database) so
   that a preemption only loses the current in-progress unit, not hours of work.

4. **PodDisruptionBudget doesn't help for Spot**: PDB only applies to voluntary evictions
   (kubectl drain, CA scale-down). GCP preemption is involuntary and bypasses PDB.

5. **Multi-zone Spot pools**: Spread across `europe-west1-b`, `europe-west1-c`, `europe-west1-d`
   to reduce correlated preemptions (GCP rarely preempts all zones simultaneously).

---

*Next: [Lab 08 — Resource Tuning](../08-resource-tuning/README.md)*
