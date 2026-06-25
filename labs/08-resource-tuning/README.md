# Lab 08 — Resource Tuning

> **Goal:** Master Kubernetes resource requests and limits, understand how the three QoS classes
> affect pod eviction order, learn why CPU throttling and memory OOM kill have completely different
> mechanics, and use VPA recommendations alongside LimitRange and ResourceQuota to build
> namespace-level guardrails for the `payments` namespace.

> **Series position:** Lab 07 introduced HPA and VPA conceptually. This lab goes deep on the
> resource model that underpins all autoscaling decisions. You need a running cluster and the
> `payments` namespace from Lab 06.

---

## Table of Contents

1. [Requests vs Limits — The 3 QoS Classes](#1-requests-vs-limits--the-3-qos-classes)
2. [Why CPU Throttling Is Different from Memory OOM](#2-why-cpu-throttling-is-different-from-memory-oom)
3. [Right-Sizing with VPA Recommendations](#3-right-sizing-with-vpa-recommendations)
4. [Memory Limits and JVM/Node.js Heap Sizing Gotchas](#4-memory-limits-and-jvmnodejs-heap-sizing-gotchas)
5. [LimitRange and ResourceQuota — Namespace-Level Guardrails](#5-limitrange-and-resourcequota--namespace-level-guardrails)
6. [Vertical Scaling vs Horizontal Scaling Decision Framework](#6-vertical-scaling-vs-horizontal-scaling-decision-framework)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. Requests vs Limits — The 3 QoS Classes

### The Fundamental Distinction

**Requests** are a **scheduling promise** — the kubelet guarantees a pod will always have at
least this much CPU/memory available on the node. The scheduler only places a pod on a node
that has enough Allocatable resources to honor all requests.

**Limits** are a **runtime ceiling** — enforced by the Linux kernel's cgroups subsystem.
Exceeding CPU limit causes throttling. Exceeding memory limit causes OOMKill.

```
Node: e2-standard-4 (4 CPU, 16 GB RAM)
Allocatable: 3920m CPU, ~12.8 GB RAM (after OS/kubelet reservations)

Pod A requests: 500m CPU, 256Mi RAM   → Scheduler checks: 3920m ≥ 500m? Yes. Schedule.
Pod B requests: 500m CPU, 256Mi RAM   → Scheduler checks: 3420m ≥ 500m? Yes. Schedule.
...
Pod N requests: 500m CPU, 256Mi RAM   → Scheduler checks: 220m ≥ 500m? No. Pending.
```

### The Three QoS Classes

Kubernetes assigns one of three Quality of Service classes to every pod. This class determines
**eviction priority** when a node is under memory pressure.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         QoS Class Hierarchy                              │
│                                                                          │
│  Guaranteed    ← Evicted LAST (highest priority to keep running)         │
│  Burstable     ← Evicted second                                          │
│  BestEffort    ← Evicted FIRST (lowest priority)                         │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Guaranteed QoS

```yaml
# Guaranteed: every container has requests == limits for BOTH CPU and memory
containers:
  - name: payments-api
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: 500m      # ← must equal request
        memory: 512Mi  # ← must equal request
```

- The pod is pinned to an exact resource slice
- Kubelet will NEVER evict this pod for resource reclamation
- CPU is hard-capped: the pod can never burst above 500m
- The cost: you're paying for 500m CPU even when idle

### Burstable QoS

```yaml
# Burstable: requests < limits (recommended for most production services)
containers:
  - name: payments-api
    resources:
      requests:
        cpu: 200m       # ← What you need at baseline
        memory: 256Mi
      limits:
        cpu: 1000m      # ← What you can burst to under load
        memory: 512Mi
```

- Scheduler places the pod based on the (lower) request
- Pod can burst to its limit when the node has spare capacity
- Evicted only when node memory pressure exceeds Guaranteed pods' needs
- **The right setting for most stateless services**

### BestEffort QoS

```yaml
# BestEffort: NO requests or limits set at all
containers:
  - name: payments-api
    # No resources block
```

- Scheduler ignores capacity (always places the pod if any node is available)
- The pod has no guaranteed resources — it uses whatever is left over
- Evicted FIRST when any node memory pressure occurs
- Use only for: non-critical batch jobs, temporary debug pods

### Viewing QoS Class

```bash
# View the QoS class assigned to a pod
kubectl get pod payments-api-xxxxx -n payments \
  -o jsonpath='{.status.qosClass}'
# Output: Burstable

# View QoS class for all pods in namespace
kubectl get pods -n payments \
  -o custom-columns="NAME:.metadata.name,QOS:.status.qosClass"
```

### Setting the Right QoS for Each Workload

| Workload Type | Recommended QoS | Reasoning |
|--------------|----------------|-----------|
| payments-api (user-facing) | **Burstable** | Needs burst headroom for traffic spikes |
| payments-worker (batch) | **Burstable** or BestEffort | Lower priority, can be preempted |
| Redis, Cloud SQL proxy | **Guaranteed** | Must not be evicted — data loss risk |
| Prometheus, Grafana | **Burstable** | Important but not user-facing |
| Debug/ephemeral pods | **BestEffort** | Short-lived, eviction is fine |

---

## 2. Why CPU Throttling Is Different from Memory OOM

This is one of the most misunderstood areas in Kubernetes operations. CPU throttling and
memory OOM kill are fundamentally different mechanisms.

### CPU: Throttling (Compressible Resource)

CPU is a **compressible resource** — exceeding the limit doesn't kill the process.
The kernel simply gives the process fewer CPU cycles (rate-limiting).

```
CPU Limit Mechanics (Linux cgroups v2):
  
  cpu.max = 100000 (quota) / 100000 (period) = 1.0 CPU
  cpu.max = 50000 / 100000 = 0.5 CPU  ← 500m in Kubernetes notation

  Every 100ms period:
    Process can use up to 50ms of CPU time.
    If it tries to use 80ms, the kernel throttles it for the remaining 30ms.
    The process doesn't die — it just runs slower.
```

**Why throttling is insidious:** Your pod shows "Running", requests succeed, but with much
higher latency than expected. A payments API that normally responds in 50ms may respond in
500ms when CPU-throttled — enough to trigger timeouts and SLA breaches.

```bash
# Check if a container is being CPU-throttled
# throttled_time is cumulative nanoseconds the container was throttled
kubectl exec payments-api-xxxxx -n payments -- \
  cat /sys/fs/cgroup/cpu.stat
# Look for: throttled_usec (microseconds throttled)
# If this number grows rapidly, your container is hitting its CPU limit

# Or using node-level metrics (requires ssh to node or metrics-server):
kubectl top pods -n payments
# If CPU shows close to limit, throttling is likely occurring

# Best signal: use Prometheus to alert on cgroup throttling
# Metric: container_cpu_cfs_throttled_seconds_total
```

### Memory: OOMKill (Incompressible Resource)

Memory is an **incompressible resource** — the kernel cannot "slow down" memory usage.
When a container exceeds its memory limit, the kernel's OOM killer terminates the process
immediately.

```
Memory Limit Mechanics:

  memory.max = 512Mi  ← hard limit in cgroup

  When the process tries to allocate memory that would exceed 512Mi:
    1. Kernel checks cgroup memory usage
    2. Usage > memory.max
    3. OOM killer selects a process in the cgroup to kill
    4. Process receives SIGKILL (not SIGTERM — no graceful shutdown)
    5. Container exits with code 137
    6. Kubelet restarts the container (if restartPolicy: Always)
```

**The critical difference:** CPU throttling causes slow responses. Memory OOM causes crashes.
A payments transaction in progress when OOM kill hits is lost.

```bash
# Check for OOM kills
kubectl describe pod payments-api-xxxxx -n payments | grep -A 5 "Last State:"
# Last State: Terminated
#   Reason:    OOMKilled
#   Exit Code: 137

# View OOM events across namespace
kubectl get events -n payments | grep -i oom

# Check total OOM kills on a node
kubectl debug node/gke-gke-labs-dev-application-pool-abc-0 \
  -it --image=ubuntu -- chroot /host dmesg | grep -i "oom"

# Prometheus alert for OOM kills:
# kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0
```

### CPU Requests vs Limits — Setting Both Correctly

```
Common mistake: setting limits << requests

  requests.cpu: 100m   ← scheduler allocates 100m
  limits.cpu:   50m    ← but the container can only use 50m??
  
  Result: containers immediately throttled below their request.
  Always: limits >= requests

Common mistake: setting limits << actual usage

  requests.cpu: 200m
  limits.cpu:   300m   ← but the app actually uses 800m under load
  
  Result: 300/800 = 62.5% of CPU time throttled during peak load

Common mistake: no CPU limits at all (on shared nodes)

  requests.cpu: 200m
  limits.cpu:   <none>
  
  Result: one noisy neighbor pod can consume all spare CPU on the node,
  causing other pods to only get their guaranteed 200m.
  Set limits to 3-5x requests as a reasonable ceiling.
```

---

## 3. Right-Sizing with VPA Recommendations

VPA's Recommender watches actual CPU and memory usage via the metrics-server and produces
statistically-based recommendations. Here's how to read and apply them.

### Deploying VPA in Recommendation Mode

```bash
# Enable VPA on GKE (one-time cluster operation)
gcloud container clusters update gke-labs-dev \
  --enable-vertical-pod-autoscaling \
  --region=europe-west1 \
  --project=gke-labs

# Apply a VPA object in Off mode for the payments-api
cat <<EOF | kubectl apply -f -
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
    updateMode: "Off"    # Read-only — never modifies pods
  resourcePolicy:
    containerPolicies:
      - containerName: payments-api
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: 4
          memory: 4Gi
        controlledValues: RequestsOnly
EOF
```

After 24–72 hours of real traffic, read the recommendations:

```bash
kubectl describe vpa payments-api-vpa -n payments
```

Sample output and how to interpret each value:

```
Status:
  Recommendation:
    Container Recommendations:
      Container Name:  payments-api
      
      Lower Bound:
        Cpu:     25m        ← 5th percentile — request at least this
        Memory:  52Mi
      
      Target:
        Cpu:     120m       ← 50th percentile + headroom — USE THIS for requests
        Memory:  180Mi
      
      Uncapped Target:
        Cpu:     115m       ← What VPA would recommend ignoring minAllowed/maxAllowed
        Memory:  175Mi
      
      Upper Bound:
        Cpu:     1200m      ← 95th percentile spike — consider for limits
        Memory:  1800Mi
```

**Applying recommendations:**

```bash
# Read the target values
VPA_CPU=$(kubectl get vpa payments-api-vpa -n payments \
  -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}')
VPA_MEM=$(kubectl get vpa payments-api-vpa -n payments \
  -o jsonpath='{.status.recommendation.containerRecommendations[0].target.memory}')

echo "VPA recommends: CPU=${VPA_CPU}, Memory=${VPA_MEM}"

# Apply as requests, set limits to 2.5x requests for burst headroom
kubectl set resources deployment/payments-api \
  -c payments-api \
  --requests="cpu=${VPA_CPU},memory=${VPA_MEM}" \
  -n payments

# After applying, verify the deployment rolls out cleanly
kubectl rollout status deployment/payments-api -n payments
kubectl top pods -n payments
```

---

## 4. Memory Limits and JVM/Node.js Heap Sizing Gotchas

The two most common runtimes in GKE — JVM (Java/Kotlin/Scala) and Node.js — have memory
management behavior that interacts badly with cgroup memory limits in non-obvious ways.

### JVM Memory Gotcha: Heap + Non-Heap

The JVM allocates memory in multiple areas:

```
JVM Memory Layout:
  ┌────────────────────────────────────────────────────────┐
  │  Heap (controlled by -Xmx)                             │
  │  ├── Young generation (Eden, Survivor)                 │
  │  └── Old generation (Tenured)                         │
  ├────────────────────────────────────────────────────────┤
  │  Non-Heap (NOT controlled by -Xmx)                    │
  │  ├── Metaspace (class metadata) — ~150-400MB typical  │
  │  ├── Code cache (JIT-compiled bytecode) — ~50-100MB   │
  │  ├── Direct ByteBuffer (off-heap NIO) — variable      │
  │  └── Stack frames (one per thread) — ~1MB × threads   │
  └────────────────────────────────────────────────────────┘
```

**The trap:** If you set `memory.limit = 1Gi` and `-Xmx = 1g`, the JVM will OOMKill because
Non-Heap usage pushes total above the cgroup limit.

**Rule of thumb:**
```
memory.limit = Xmx + 400Mi (for non-heap overhead)

# If you want 1GB heap:
requests.memory: 1Gi
limits.memory: 1536Mi    # 1GB heap + 512MB non-heap overhead

# Deployment environment variable:
env:
  - name: JAVA_OPTS
    value: "-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m -XX:+UseContainerSupport"
```

`-XX:+UseContainerSupport` (default since JDK 10) makes the JVM read cgroup memory limits
instead of the host's physical RAM. Always include this flag.

```bash
# Verify the JVM sees the cgroup limit, not the node's RAM
kubectl exec -n payments payments-api-xxxxx -- \
  java -XX:+PrintFlagsFinal -version 2>&1 | grep MaxHeapSize
# Should show: MaxHeapSize = 1073741824 (1GB), not 16GB (node RAM)
```

### Node.js Memory Gotcha: V8 Heap + Buffer Allocations

Node.js runs the V8 JavaScript engine which has its own heap:

```
Node.js Memory Layout:
  ├── V8 Heap (JavaScript objects, strings) — controlled by --max-old-space-size
  ├── Heap off-heap: ArrayBuffer, Buffer (Node.js) — NOT in V8 heap
  └── Native modules (C++ allocations) — NOT in V8 heap
```

**The trap:** Node.js defaults `--max-old-space-size` to ~1.5GB on a 64-bit system. In a
container with a 512Mi memory limit, Node.js will try to use 1.5GB and get OOMKilled.

```yaml
# Set the flag explicitly in your container command:
env:
  - name: NODE_OPTIONS
    value: "--max-old-space-size=384"   # 384MB V8 heap
                                        # leaves ~128MB for Buffers and native modules
                                        # with a 512Mi container limit
```

```
Memory limit: 512Mi = 524MB
  V8 heap:         384MB   (--max-old-space-size=384)
  Node overhead:   ~80MB   (native, buffers, V8 overhead)
  Safety margin:   ~60MB
```

**Monitoring Node.js heap:**

```javascript
// Expose V8 heap stats as Prometheus metrics
const v8 = require('v8');
const { heapUsed, heapTotal } = process.memoryUsage();

// In your metrics endpoint:
// process_heap_bytes = heapUsed
// process_heap_size_bytes = heapTotal
// Alert when heapUsed > 90% of heapTotal (approaching GC pressure)
```

---

## 5. LimitRange and ResourceQuota — Namespace-Level Guardrails

Individual pod resource settings protect one workload. Namespace-level controls protect the
cluster from a whole namespace consuming unbounded resources.

### LimitRange — Default Requests and Limits

`LimitRange` sets defaults and constraints for every pod in a namespace. If a pod is created
without resource specifications, LimitRange fills them in automatically.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: payments-limits
  namespace: payments
spec:
  limits:
    - type: Container
      # Default values injected if the container has no resources spec
      default:
        cpu: 200m
        memory: 256Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      # Hard constraints — any container EXCEEDING these is rejected
      max:
        cpu: 4
        memory: 4Gi
      # Any container BELOW these is rejected
      min:
        cpu: 10m
        memory: 16Mi
      # Ratio: limits/requests must not exceed this
      maxLimitRequestRatio:
        cpu: 10      # limits.cpu can be at most 10x requests.cpu
        memory: 4    # limits.memory can be at most 4x requests.memory

    - type: Pod
      # These apply to the SUM of all containers in a pod
      max:
        cpu: 8
        memory: 8Gi

    - type: PersistentVolumeClaim
      max:
        storage: 50Gi
      min:
        storage: 1Gi
```

```bash
kubectl apply -f payments-limitrange.yaml

# Test: create a pod without resources — LimitRange injects defaults
kubectl run test-defaults \
  --image=nginx \
  --restart=Never \
  --namespace=payments

kubectl describe pod test-defaults -n payments | grep -A 10 "Limits:"
# Limits: cpu=200m, memory=256Mi   ← injected by LimitRange
# Requests: cpu=100m, memory=128Mi ← injected by LimitRange

# Test: create a pod with too-large resources — LimitRange rejects it
kubectl run too-big \
  --image=nginx \
  --restart=Never \
  --namespace=payments \
  --limits=cpu=8,memory=8Gi
# Error: cpu: max limit is 4, memory: max limit is 4Gi

kubectl delete pod test-defaults -n payments
```

### ResourceQuota — Total Namespace Budget

`ResourceQuota` caps the total resources consumed by all pods in a namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: payments
spec:
  hard:
    # Compute resources
    requests.cpu: "8"          # Total CPU requests across all pods ≤ 8 cores
    requests.memory: 16Gi      # Total memory requests ≤ 16Gi
    limits.cpu: "32"           # Total CPU limits ≤ 32 cores
    limits.memory: 64Gi        # Total memory limits ≤ 64Gi

    # Object count limits (prevent accidental sprawl)
    pods: "50"                 # Max 50 pods in namespace
    services: "10"
    persistentvolumeclaims: "20"
    configmaps: "50"
    secrets: "30"

    # Specific QoS class quotas
    count/pods.guaranteed: "5"    # Max 5 Guaranteed pods
    count/pods.burstable: "30"    # Max 30 Burstable pods
    count/pods.besteffort: "10"   # Max 10 BestEffort pods
```

```bash
kubectl apply -f payments-quota.yaml

# Check quota usage
kubectl describe resourcequota payments-quota -n payments
```

Sample output:
```
Name:            payments-quota
Namespace:       payments
Resource         Used    Hard
--------         ----    ----
limits.cpu       4800m   32
limits.memory    4Gi     64Gi
pods             8       50
requests.cpu     1600m   8
requests.memory  2Gi     16Gi
services         3       10
```

> **Quota enforcement:** Once `requests.cpu: "8"` is reached, any new pod with `requests.cpu`
> will be rejected with `forbidden: exceeded quota`. Existing pods continue running.
> Fix: either increase the quota, or scale down other workloads first.

---

## 6. Vertical Scaling vs Horizontal Scaling Decision Framework

Both approaches increase capacity, but they apply to different bottlenecks.

### The Core Trade-Off

```
Vertical Scaling (bigger pods):
  + Simple: no load balancing changes, no session handling
  + Works for stateful workloads (one database primary)
  - Hard ceiling: you can't grow beyond one node's capacity
  - Requires pod restart to apply (with VPA Auto) → brief downtime risk
  - Doesn't improve availability (still one point of failure)

Horizontal Scaling (more pods):
  + Unlimited ceiling (add nodes if needed)
  + Improves availability — N replicas tolerate N-1 pod failures
  + Zero downtime: new pods added before old ones are removed
  - Requires stateless design (or shared state via Redis/DB)
  - Adds complexity: load balancing, session stickiness, cache coordination
```

### Decision Framework

```
Is your workload stateful?
  YES → Can you externalize state (Redis, Cloud SQL, GCS)?
          YES → Refactor, then horizontal scale
          NO  → Vertical scale only (single large pod)

Is the bottleneck CPU?
  YES → Is it CPU-bound algorithm work or waiting for I/O?
          Algorithm work → Horizontal scale (parallelize)
          I/O bound      → Horizontal scale (more concurrent waiters)
          Both           → Fix the I/O first, then horizontal scale

Is the bottleneck memory?
  YES → Is it a large in-memory dataset (cache, ML model)?
          YES → Vertical scale or shard the dataset
          NO  → Memory leak? Fix the bug first.

Is the bottleneck throughput (requests/second)?
  YES → Horizontal scale — more pods handle more concurrent requests

Is the bottleneck database connections?
  YES → Connection pooling (PgBouncer) first, then horizontal scale
        (horizontal scaling of the app creates more DB connections)
```

### Right-Sizing Matrix for the Payments Platform

| Service | Bottleneck Type | Recommended Strategy |
|---------|----------------|---------------------|
| `payments-api` | CPU (request processing) | Horizontal — HPA on RPS |
| `payments-worker` | I/O (Cloud SQL writes) | Horizontal — KEDA on queue depth |
| Cloud SQL | Disk I/O | Vertical — larger instance tier |
| Redis Memorystore | Memory (key storage) | Vertical — larger instance tier |
| Cloud SQL Proxy sidecar | CPU (TLS termination) | Vertical — more CPU on sidecar container |

### Vertical Scaling Checklist

Before increasing pod resources, verify:

```bash
# 1. Is the pod actually hitting its current limits?
kubectl top pods -n payments
# Compare MEMORY/CPU columns to the limits in the pod spec

# 2. Is CPU being throttled? (Needs Prometheus)
# container_cpu_cfs_throttled_seconds_total > 0 → yes

# 3. Are there OOMKills in recent history?
kubectl get events -n payments | grep OOMKilling

# 4. What does VPA recommend?
kubectl describe vpa payments-api-vpa -n payments | grep -A 10 "Target:"

# 5. Is there LimitRange headroom?
kubectl describe limitrange payments-limits -n payments

# 6. Is there ResourceQuota headroom?
kubectl describe resourcequota payments-quota -n payments
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1: OOMKill a Container

**What we're testing:** Observe memory limit enforcement and recovery.

```bash
# === SETUP ===
# Deploy a container that will exceed its memory limit
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: oom-test
  namespace: payments
spec:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "application"
      effect: "NoSchedule"
  containers:
    - name: memory-consumer
      image: polinux/stress
      resources:
        requests:
          memory: "100Mi"
        limits:
          memory: "150Mi"    # ← Limit is 150Mi
      command: ["stress"]
      args: ["--vm", "1", "--vm-bytes", "200M", "--timeout", "60s"]
      # stress will try to allocate 200MB, but limit is 150MB → OOMKill
EOF

# === OBSERVE ===
# Watch the pod status
kubectl get pod oom-test -n payments -w
# STATUS: OOMKilled

# Confirm the reason
kubectl describe pod oom-test -n payments | grep -A 8 "Last State:"
# Last State:     Terminated
#   Reason:       OOMKilled
#   Exit Code:    137

# OOMKill event
kubectl get events -n payments | grep -i oom

# === FIX IT ===
# Option 1: Increase the memory limit
kubectl delete pod oom-test -n payments

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: oom-fixed
  namespace: payments
spec:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "application"
      effect: "NoSchedule"
  containers:
    - name: memory-consumer
      image: polinux/stress
      resources:
        requests:
          memory: "150Mi"
        limits:
          memory: "300Mi"    # ← Now has headroom for 200MB allocation
      command: ["stress"]
      args: ["--vm", "1", "--vm-bytes", "200M", "--timeout", "30s"]
EOF

kubectl get pod oom-fixed -n payments -w
# STATUS: Running → Completed (no OOMKill this time)

kubectl delete pod oom-fixed -n payments
```

---

### Exercise 2: ResourceQuota Blocks a Deployment

**What we're testing:** Understand how ResourceQuota enforcement works.

```bash
# === SETUP ===
# Create a tight quota on a test namespace
kubectl create namespace quota-test

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tight-quota
  namespace: quota-test
spec:
  hard:
    requests.cpu: "200m"    # Only 200m total CPU requests allowed
    requests.memory: "256Mi"
    pods: "3"
EOF

# === BREAK IT ===
# Try to deploy 4 pods that together exceed the quota
kubectl create deployment quota-breaker \
  --image=nginx \
  --replicas=4 \
  --namespace=quota-test

# Add resource requests (without them the quota would reject the pod via LimitRange)
kubectl set resources deployment/quota-breaker \
  -c nginx \
  --requests=cpu=100m,memory=100Mi \
  --limits=cpu=200m,memory=200Mi \
  --namespace=quota-test

# === OBSERVE ===
kubectl get pods -n quota-test
# Only 2 pods will start (2 × 100m = 200m, which hits the limit)
# The 3rd and 4th pods are not created — the ReplicaSet can't create them

kubectl describe replicaset -n quota-test | grep -A 5 "Events:"
# Events: Warning FailedCreate: ... exceeded quota: tight-quota,
# requested: requests.cpu=100m, used: requests.cpu=200m, limited: requests.cpu=200m

kubectl describe resourcequota tight-quota -n quota-test
# requests.cpu   200m   200m   ← Used = Hard (quota exhausted)

# === FIX IT ===
# Option 1: Increase the quota
kubectl patch resourcequota tight-quota -n quota-test --type=merge -p='{
  "spec": {"hard": {"requests.cpu": "500m", "requests.memory": "1Gi", "pods": "10"}}
}'

# Watch the pending pods get created
kubectl get pods -n quota-test -w

# Option 2: Reduce the deployment replicas
# kubectl scale deployment quota-breaker --replicas=2 -n quota-test

# Cleanup
kubectl delete namespace quota-test
```

---

### Exercise 3: JVM Heap Misconfiguration → OOMKill

**What we're testing:** The gap between JVM `-Xmx` and container memory limit.

```bash
# === BREAK IT ===
# Simulate a Java service with Xmx set equal to the container limit
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jvm-oom
  namespace: payments
spec:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "application"
      effect: "NoSchedule"
  containers:
    - name: java-app
      image: openjdk:17-slim
      resources:
        requests:
          memory: 512Mi
        limits:
          memory: 512Mi      # Container limit = 512MB
      command:
        - java
        - -Xms512m           # ← Problem: heap = container limit
        - -Xmx512m           # ← JVM will need more for non-heap
        - -cp
        - /dev/null
        - java.lang.Object   # Dummy class to just run the JVM
EOF

# === OBSERVE ===
kubectl get pod jvm-oom -n payments -w
# OOMKilled — the JVM's non-heap (metaspace, code cache) pushed it over 512MB

# === FIX IT ===
kubectl delete pod jvm-oom -n payments

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jvm-fixed
  namespace: payments
spec:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "application"
      effect: "NoSchedule"
  containers:
    - name: java-app
      image: openjdk:17-slim
      resources:
        requests:
          memory: 512Mi
        limits:
          memory: 896Mi      # ← 512Mi heap + 384Mi for non-heap overhead
      command:
        - java
        - -Xms256m
        - -Xmx512m           # Heap ≤ 512MB
        - -XX:MaxMetaspaceSize=128m
        - +XX:+UseContainerSupport
        - -cp
        - /dev/null
        - java.lang.Object
EOF

kubectl get pod jvm-fixed -n payments -w
# Running — JVM has room for non-heap allocations

kubectl delete pod jvm-fixed -n payments
```

---

## 8. Interview Q&A

---

### Q1: What is the difference between a CPU request and a CPU limit, and what happens at runtime if a container exceeds each?

**Answer:**

**CPU request** is used by the scheduler to find a node with enough available CPU. At runtime,
the kernel's CFS (Completely Fair Scheduler) uses requests as **relative weights** — a container
with 200m gets twice the CPU time of a container with 100m when both are competing for the
same CPU.

**CPU limit** is enforced by cgroups v2's `cpu.max` setting. The kernel allows the process
`quota` microseconds of CPU time per `period`. If the process uses more than `quota`, it is
**throttled** — it simply runs slower, but it does not crash.

Key runtime behaviors:
- Exceeding CPU request: nothing happens (the request is just for scheduling)
- Exceeding CPU limit: the container is throttled (slows down, never killed)
- No CPU limit set: the container can use all spare CPU on the node (noisy neighbor risk)

---

### Q2: What is the Guaranteed QoS class and when should you use it?

**Answer:**

A pod is classified as `Guaranteed` when every container in the pod has `requests == limits`
for **both** CPU and memory. This tells the kubelet: "this pod will never use more or less
than these resources."

Guaranteed pods are **never evicted** for resource reclamation. The kubelet will evict
BestEffort pods first, then Burstable pods (in order of how much they exceed their requests),
and only evicts Guaranteed pods as a last resort (which in practice means the node is failing).

**When to use Guaranteed:**
- Redis, PostgreSQL primary, Cloud SQL proxy — any component where eviction causes data loss
  or requires a manual failover
- Controllers, admission webhooks — infrastructure components whose failure cascades

**When NOT to use Guaranteed:**
- Stateless services with variable load — you'll waste resources during low-traffic periods
  because the limit prevents bursting
- Anything behind an HPA — HPA and Guaranteed QoS conflict: Guaranteed prevents CPU bursting,
  so HPA's CPU metric will never spike and scaling never triggers

---

### Q3: Walk me through how you would right-size a new microservice that has just been deployed.

**Answer:**

1. **Start with VPA in Off mode**: Apply a `VerticalPodAutoscaler` with `updateMode: Off`
   immediately after deploying. Set conservative initial requests (e.g., 100m CPU, 128Mi RAM).

2. **Run for 24–72 hours**: Let the VPA Recommender observe real traffic including peak and
   off-peak periods.

3. **Read the recommendation**: `kubectl describe vpa <name>` shows Target, LowerBound, and
   UpperBound. The **Target** is your recommended request value.

4. **Set requests = Target, limits = 2–3x Target**: This gives burst headroom without being
   a noisy neighbor. For memory, check if the service is JVM or Node.js and add non-heap
   overhead accordingly.

5. **Set up CPU throttling metrics**: Deploy a Prometheus alert on
   `container_cpu_cfs_throttled_seconds_total`. If throttling exceeds 5% of total CPU time,
   the limit is too low.

6. **Monitor for OOMKills**: Alert on
   `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`. Each OOMKill
   means the memory limit is too low.

7. **Iterate over 2 weeks**: Adjust requests/limits based on observed behavior. After
   stabilization, the VPA recommendation will reflect steady-state needs.

---

### Q4: What is a LimitRange and how does it differ from a ResourceQuota?

**Answer:**

**LimitRange** operates at the **pod/container level**. It:
- Injects default `requests` and `limits` into containers that don't specify them
- Enforces min/max constraints per container (rejecting pods that exceed bounds)
- Can enforce a maximum ratio of limits to requests

**ResourceQuota** operates at the **namespace level**. It:
- Caps the total sum of requests/limits across all pods in the namespace
- Caps the number of objects (pods, services, PVCs, etc.)
- Does not inject defaults — it only rejects new objects that would exceed the total

They complement each other:
- LimitRange ensures every pod has valid resource specifications
- ResourceQuota ensures the namespace as a whole doesn't overcommit the cluster

Without LimitRange, a pod with no resource specs would use 0 resources toward the
ResourceQuota — effectively bypassing it. LimitRange forces all pods to declare resources,
making ResourceQuota meaningful.

---

### Q5: A payments-api pod is running, but its p99 latency is 10× higher than in local testing. No errors. No OOMKills. What do you check?

**Answer:**

The most likely cause with those symptoms: **CPU throttling**.

```bash
# Check CPU throttling via the container's cgroup stats
kubectl exec -n payments <pod> -- cat /sys/fs/cgroup/cpu.stat | grep throttled
# throttled_usec: if this number is large and growing, the container is throttled

# Check if the pod is near its CPU limit
kubectl top pod -n payments
# If usage is close to (limit) -- throttling is occurring even if not at 100%

# Prometheus query for throttling ratio:
# rate(container_cpu_cfs_throttled_seconds_total[5m]) /
# rate(container_cpu_cfs_periods_total[5m])
# If > 0.05 (5%), the container is being throttled significantly
```

Other things to check in order:
1. **Node pressure**: `kubectl describe node` — check MemoryPressure, DiskPressure conditions
2. **Noisy neighbors**: `kubectl top pods -n payments` — another pod consuming excessive CPU
3. **GC pressure** (JVM): high GC time causes application pauses that look like latency spikes
4. **External dependency**: Is Cloud SQL slow? Use distributed tracing (Lab 12) to find where
   time is spent in the call graph
5. **DNS**: `kubectl exec <pod> -- time nslookup kubernetes.default` — DNS lookup adds to
   every outbound connection's latency if CoreDNS is overloaded

---

*Next: [Lab 09 — Network Policies](../09-network-policies/README.md)*
