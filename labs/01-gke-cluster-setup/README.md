# Lab 01 — GKE Cluster Deep Dive

> **Goal:** Understand every decision behind the cluster Terraform creates — node pools,
> Workload Identity, private networking, and how GKE self-heals. By the end you should be able
> to read a `kubectl get nodes` output like a book.

---

## Table of Contents

1. [Autopilot vs Standard — When to Choose What](#1-autopilot-vs-standard--when-to-choose-what)
2. [Node Pools: System, Application, Spot](#2-node-pools-system-application-spot)
3. [Taint & Toleration Mechanics](#3-taint--toleration-mechanics)
4. [Terraform Walkthrough — What Each Resource Creates](#4-terraform-walkthrough--what-each-resource-creates)
5. [Reading Node Output](#5-reading-node-output)
6. [Workload Identity — Why SA Keys Are Dangerous](#6-workload-identity--why-sa-keys-are-dangerous)
7. [Private Cluster & Master Authorized Networks](#7-private-cluster--master-authorized-networks)
8. [Break-It & Fix-It Exercises](#8-break-it--fix-it-exercises)
9. [Interview Q&A](#9-interview-qa)

---

## 1. Autopilot vs Standard — When to Choose What

GKE offers two fundamentally different operating modes. Understanding the trade-offs
prevents expensive mistakes in production.

### Feature Comparison

| Dimension | **Standard** | **Autopilot** |
|-----------|-------------|--------------|
| Node management | You manage nodes, pools, sizes | Google manages everything |
| Pricing model | Per node (VM uptime) | Per Pod resource request |
| Bin packing | You control pod density | Google optimizes |
| Node access | SSH into nodes, DaemonSets work freely | No SSH, limited DaemonSets |
| Spot/Preemptible | You configure per pool | Autopilot has spot pods |
| Node auto-provisioning | Optional (NAP) | Always on |
| Custom node images | Yes (COS or Ubuntu) | No — Google-managed only |
| Resource limits | You set requests/limits | Enforced — no limits = rejected |
| Vertical Pod Autoscaler | Optional | Managed automatically |
| Cost predictability | Lower unit cost, manual effort | Higher unit cost, zero ops |
| Compliance & hardening | Full control over node config | Opinionated, hardened by default |
| Good for | Batch jobs, GPUs, custom kernels, cost optimization at scale | Microservices, serverless-style, teams without K8s expertise |

### Decision Framework

```
Do you have dedicated K8s platform engineers?
  YES → Standard (more control, lower cost at scale)
  NO  → Autopilot (managed, best practices enforced)

Do you run GPU workloads, DPDK networking, or custom kernel modules?
  YES → Standard (required for hardware access)

Do you want per-pod billing granularity?
  YES → Autopilot

Is your team < 10 engineers with no dedicated infra team?
  YES → Autopilot

Are you running this as a learning lab?
  → Standard (you can observe and control everything)
```

**This lab uses Standard mode** so you can observe node behavior, taint nodes,
inspect system pods, and understand the full lifecycle.

---

## 2. Node Pools: System, Application, Spot

The Terraform in this lab creates **three separate node pools**. Here's why.

### Why Separate Pools?

Mixing workloads on the same nodes creates several problems:
- System pods (kube-dns, metrics-server) can be evicted by hungry application pods
- You can't independently scale different workload types
- Spot/preemptible nodes shouldn't run critical system components
- Node sizing is a compromise when all workloads share the same machine type

### Pool Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    GKE Cluster: gke-lab-cluster             │
│                                                             │
│  ┌─────────────────┐  ┌──────────────────┐  ┌───────────┐  │
│  │   system-pool   │  │  application-pool │  │ spot-pool │  │
│  │─────────────────│  │──────────────────│  │───────────│  │
│  │ e2-standard-2   │  │  e2-standard-4   │  │e2-std-4   │  │
│  │ min: 1, max: 3  │  │  min: 1, max: 5  │  │min:0 max:5│  │
│  │                 │  │                  │  │  SPOT     │  │
│  │ Taint: ─────── │  │ Taint: ────────  │  │ Taint:    │  │
│  │ CriticalAddons  │  │ app=true:NoSched │  │ spot=true │  │
│  │ Only=true:NoSch │  │                  │  │ :NoSched  │  │
│  │                 │  │                  │  │           │  │
│  │ RUNS:           │  │ RUNS:            │  │ RUNS:     │  │
│  │ • kube-dns      │  │ • Your services  │  │ • Batch   │  │
│  │ • metrics-server│  │ • APIs           │  │ • Workers │  │
│  │ • CSI drivers   │  │ • Web frontends  │  │ • Jobs    │  │
│  │ • Ingress ctrl  │  │                  │  │           │  │
│  └─────────────────┘  └──────────────────┘  └───────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Pool Configuration in Terraform

```hcl
# system-pool: always-on, small, tolerates critical system workloads
resource "google_container_node_pool" "system" {
  name       = "system-pool"
  cluster    = google_container_cluster.main.name
  location   = var.region

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-standard-2"
    
    # Taint prevents regular pods from scheduling here
    taint {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    labels = {
      "node-pool" = "system"
      "workload"  = "system"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"  # Required for Workload Identity
    }
  }
}

# application-pool: your actual services run here
resource "google_container_node_pool" "application" {
  name       = "application-pool"
  cluster    = google_container_cluster.main.name
  location   = var.region

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  node_config {
    machine_type = "e2-standard-4"

    taint {
      key    = "workload"
      value  = "application"
      effect = "NO_SCHEDULE"
    }

    labels = {
      "node-pool" = "application"
      "workload"  = "application"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# spot-pool: low-cost for fault-tolerant batch/worker workloads
resource "google_container_node_pool" "spot" {
  name       = "spot-pool"
  cluster    = google_container_cluster.main.name
  location   = var.region

  autoscaling {
    min_node_count = 0  # scale to zero when idle!
    max_node_count = 5
  }

  node_config {
    machine_type = "e2-standard-4"
    spot         = true  # Spot instances (replaces preemptible)

    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    labels = {
      "node-pool"                       = "spot"
      "cloud.google.com/gke-spot"       = "true"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
```

---

## 3. Taint & Toleration Mechanics

Taints are the **"keep out" signs** on nodes. Tolerations are the **permission passes** on pods.

### How It Works

```
Node Taint:   key=value:Effect
Pod Toleration: must match key, value, and effect to be "tolerated"

Effects:
  NoSchedule        → New pods cannot schedule here (existing pods unaffected)
  PreferNoSchedule  → Scheduler tries to avoid, but can schedule if needed
  NoExecute         → New pods can't schedule + existing pods WITHOUT toleration are evicted
```

### Practical Example: Application Pool

The application node pool has taint: `workload=application:NoSchedule`

A pod WITHOUT a toleration will be **rejected** by the scheduler:
```bash
kubectl describe pod <pending-pod>
# Events: Warning  FailedScheduling  0/3 nodes are available:
#         3 node(s) had untolerated taint {workload: application}
```

A pod WITH the correct toleration **will be scheduled**:
```yaml
# In your Deployment spec:
spec:
  template:
    spec:
      tolerations:
        - key: "workload"
          operator: "Equal"
          value: "application"
          effect: "NoSchedule"
      nodeSelector:
        workload: application  # Also pin to the right pool via label
      containers:
        - name: my-app
          image: my-image:latest
```

### Spot Pool Toleration (for batch jobs)

```yaml
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
```

### System Pool Toleration (for DaemonSets/system components)

```yaml
spec:
  template:
    spec:
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Equal"
          value: "true"
          effect: "NoSchedule"
```

---

## 4. Terraform Walkthrough — What Each Resource Creates

```bash
cd terraform/
terraform init
terraform plan -out=tfplan
terraform show tfplan
```

### Resource Map

| Terraform Resource | What GCP Creates |
|-------------------|-----------------|
| `google_compute_network.main` | VPC network: `gke-labs-vpc` |
| `google_compute_subnetwork.gke` | Subnet in `europe-west1` with secondary ranges for pods & services |
| `google_container_cluster.main` | GKE control plane (private, regional) |
| `google_container_node_pool.system` | Node pool with autoscaling for system workloads |
| `google_container_node_pool.application` | Node pool for application workloads |
| `google_container_node_pool.spot` | Spot node pool (scale-to-zero capable) |
| `google_service_account.workload_identity` | GCP SA for pod-level GCP auth |
| `google_project_iam_member.*` | IAM bindings for the service account |
| `google_compute_router.main` | Cloud Router for NAT |
| `google_compute_router_nat.main` | Cloud NAT — allows private nodes to reach internet |

### Apply the Cluster

```bash
cd terraform/
terraform init
terraform apply -var="project_id=gke-labs" -var="region=europe-west1"
# Takes ~10-15 minutes for a regional cluster
```

Watch the cluster appear:
```bash
watch -n 10 "gcloud container clusters list --project=gke-labs"
```

### Fetch Credentials After Apply

```bash
gcloud container clusters get-credentials gke-lab-cluster \
  --region=europe-west1 \
  --project=gke-labs
```

---

## 5. Reading Node Output

### Basic Node Status

```bash
kubectl get nodes -o wide
```

Sample output and what each column means:
```
NAME                                         STATUS   ROLES    AGE   VERSION    INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                             KERNEL-VERSION   CONTAINER-RUNTIME
gke-gke-lab-cluster-system-pool-abc-0001     Ready    <none>   2d    v1.29.3    10.132.0.10    <none>        Container-Optimized OS from Google    5.15.109+        containerd://1.7.2
gke-gke-lab-cluster-application-pool-abc-0  Ready    <none>   2d    v1.29.3    10.132.0.11    <none>        Container-Optimized OS from Google    5.15.109+        containerd://1.7.2
```

| Column | Meaning |
|--------|---------|
| `STATUS: Ready` | Kubelet is healthy, node can accept pods |
| `STATUS: NotReady` | Kubelet is down or network is broken — investigate immediately |
| `ROLES: <none>` | GKE worker node (control plane is managed, not visible here) |
| `AGE` | How long since the node joined the cluster |
| `VERSION` | Kubernetes version running on the node |
| `INTERNAL-IP` | Node's IP on the VPC subnet (this is what pods talk to) |
| `EXTERNAL-IP: <none>` | Private cluster — no public IP, as expected |
| `CONTAINER-RUNTIME` | containerd (Docker was deprecated in K8s 1.24) |

### Describe a Node — Capacity vs Allocatable

```bash
kubectl describe node gke-gke-lab-cluster-application-pool-abc-0
```

Key sections to understand:
```
Capacity:
  cpu:                4          ← Total CPUs on the VM
  ephemeral-storage:  98831908Ki
  hugepages-1Gi:      0
  hugepages-2Mi:      0
  memory:             15399Mi    ← Total RAM
  pods:               110        ← Max pods this node can run (GKE default)

Allocatable:
  cpu:                3920m      ← Available for pods (OS/kubelet reserves ~80m)
  ephemeral-storage:  47060071947
  hugepages-1Gi:      0
  hugepages-2Mi:      0
  memory:             12800Mi    ← Available for pods (system daemons reserve ~2.6Gi)
  pods:               110
```

> **Why the gap?** GKE reserves CPU and memory for the OS, kubelet, and system daemons.
> On `e2-standard-4` (4 CPU, 16GB): ~6% CPU + ~10% memory is reserved.
> Always set resource **requests** based on Allocatable, not Capacity.

```
Conditions:
  Type                 Status  
  ─────────────────────────────
  MemoryPressure       False   ← Good. True = node is running out of memory
  DiskPressure         False   ← Good. True = ephemeral disk filling up
  PIDPressure          False   ← Good. True = too many processes
  Ready                True    ← All good — this is the one to watch
```

```
Non-terminated Pods:
  Namespace         Name                                   CPU Requests  Memory Requests
  ─────────────────────────────────────────────────────────────────────────────────────
  application       my-app-7d9f8b-xxxxx                    250m (6%)     256Mi (2%)
  kube-system       kube-proxy-xxxxx                       100m (2%)     0 (0%)
```

### Filter Nodes by Pool

```bash
# Show only application pool nodes
kubectl get nodes -l node-pool=application

# Show node labels (see all your custom labels)
kubectl get nodes --show-labels

# Show only nodes that are cordoned (scheduling disabled)
kubectl get nodes | grep SchedulingDisabled
```

---

## 6. Workload Identity — Why SA Keys Are Dangerous

### The Problem with JSON Key Files

```
WITHOUT Workload Identity:
────────────────────────────────────────────────────────────────────────────────

Developer creates SA key:
  gcloud iam service-accounts keys create key.json --iam-account=app@project.iam...
  
Developer stores it as a K8s secret:
  kubectl create secret generic gcp-key --from-file=key.json

App mounts it:
  volumeMounts: [{name: gcp-key, mountPath: /secrets}]

Problems:
  ❌ Key is valid forever (or until manually rotated)
  ❌ key.json might get committed to Git
  ❌ Anyone who kubectl-execs into the pod can steal it
  ❌ Leaked key works from ANYWHERE in the world
  ❌ No clear audit trail for who's using the key
  ❌ Rotation is manual and error-prone
```

### How Workload Identity Solves This

```
WITH Workload Identity:
────────────────────────────────────────────────────────────────────────────────

Pod                  GKE Metadata       GCP IAM          GCP API
─────────────────    ────────────────   ──────────────   ────────────
Pod starts
  │
  ├─ Pod has annotation:
  │  iam.gke.io/gcp-service-account=
  │  app-sa@gke-labs.iam.gserviceaccount.com
  │
  ├───────────────────► metadata.google.internal
  │                      /computeMetadata/v1/instance/
  │                      service-accounts/default/token
  │
  │                      GKE intercepts this call.
  │                      Checks pod's K8s SA annotation.
  │                      Verifies IAM binding exists.
  │
  │                   ◄─────────── Short-lived OAuth token ────────────────────┐
  │                                (expires in ~1 hour, auto-refreshed)        │
  │                                                                            │
  └──────────────────────────────────────────────────────── GCS.Get() ────────►│
                                                                               │
                                                    GCP verifies token:        │
                                                    ✅ No key file             │
                                                    ✅ Token scope is limited  │
                                                    ✅ Auto-expires            │
                                                    ✅ Tied to this specific   │
                                                       pod/SA combination      │
```

### Setting Up Workload Identity

```bash
export PROJECT_ID="gke-labs"
export K8S_SA_NAME="app-workload-sa"
export K8S_NAMESPACE="application"
export GCP_SA_NAME="app-workload-sa"
export GCP_SA_EMAIL="${GCP_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Step 1: Create the GCP Service Account
gcloud iam service-accounts create ${GCP_SA_NAME} \
  --display-name="GKE Workload Identity SA" \
  --project=${PROJECT_ID}

# Step 2: Grant the K8s SA permission to impersonate the GCP SA
# This is the critical IAM binding that links them
gcloud iam service-accounts add-iam-policy-binding ${GCP_SA_EMAIL} \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA_NAME}]" \
  --project=${PROJECT_ID}

# Step 3: Create the K8s ServiceAccount with the annotation
kubectl create serviceaccount ${K8S_SA_NAME} -n ${K8S_NAMESPACE}

kubectl annotate serviceaccount ${K8S_SA_NAME} \
  -n ${K8S_NAMESPACE} \
  iam.gke.io/gcp-service-account=${GCP_SA_EMAIL}

# Step 4: Grant the GCP SA actual GCP permissions (e.g., GCS access)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --role="roles/storage.objectViewer" \
  --member="serviceAccount:${GCP_SA_EMAIL}"
```

### Verify Workload Identity Works

```bash
# Run a test pod using the annotated K8s service account
kubectl run -it --rm workload-identity-test \
  --image=google/cloud-sdk:slim \
  --restart=Never \
  --namespace=${K8S_NAMESPACE} \
  --overrides="{\"spec\":{\"serviceAccountName\":\"${K8S_SA_NAME}\"}}" \
  -- /bin/bash

# Inside the pod:
# Fetch a token from the metadata server
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token

# You should see a JSON response with access_token, expires_in, token_type

# Check which SA identity the pod has
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
# Expected: app-workload-sa@gke-labs.iam.gserviceaccount.com

# Test actual GCP access
gcloud auth list  # Shows the GCP SA

exit
```

---

## 7. Private Cluster & Master Authorized Networks

### Cluster Architecture

```
Internet
   │
   │ (blocked: nodes have no public IPs)
   │
   ▼
Cloud NAT ──► Nodes ──► Can reach internet for image pulls etc.
   ▲              │
   │              │ (internal VPC traffic only)
   │              ▼
   │         Pods (RFC 1918 IPs from secondary range)
   │
   │ HTTPS 443 ──────────────────────────────────────────────────────────────►
   │                                                             GKE Control Plane
   │◄──────────────────────────────────────────────────── Private Endpoint ───
   │                                               (10.x.x.x internal address)
   │
Your laptop (master authorized networks) ──► Public Endpoint ──► Control Plane
```

### Why Private Cluster + Public Endpoint for This Lab

In full production, you'd disable the public endpoint and use a bastion host or VPN.
For this lab, we keep the public endpoint enabled because:

1. **Simplicity** — You can run `kubectl` from your laptop without a VPN
2. **Master Authorized Networks** restrict access to only your IP — nearly as secure
3. **The nodes are still private** — attackers can't SSH in or reach pods directly

### What Master Authorized Networks Do

```bash
# Show current master authorized networks
gcloud container clusters describe gke-lab-cluster \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(masterAuthorizedNetworksConfig)"

# Add your current IP to authorized networks
MY_IP=$(curl -s ifconfig.me)/32
gcloud container clusters update gke-lab-cluster \
  --enable-master-authorized-networks \
  --master-authorized-networks=${MY_IP} \
  --region=europe-west1 \
  --project=gke-labs

echo "Added ${MY_IP} to master authorized networks"
```

### Verify the Cluster Is Private

```bash
# Node IPs should be RFC 1918 (private ranges)
kubectl get nodes -o wide
# EXTERNAL-IP column should show <none> for all nodes

# Pods should have IPs from the secondary range
kubectl get pods -A -o wide | awk '{print $7}' | sort -u
# These IPs are from the pod secondary CIDR, not routable publicly
```

---

## 8. Break-It & Fix-It Exercises

### Exercise 1: Cordon All Application Nodes

**What we're testing:** Pod scheduling behavior when no nodes are available

```bash
# Step 1: List application nodes
kubectl get nodes -l node-pool=application

# Step 2: Cordon each application node (prevent new scheduling)
for node in $(kubectl get nodes -l node-pool=application -o name); do
  kubectl cordon $node
  echo "Cordoned: $node"
done

# Step 3: Deploy a test application
kubectl create deployment cordon-test \
  --image=nginx:latest \
  --replicas=3 \
  --namespace=application

# Add toleration (otherwise it would be rejected by the taint)
kubectl patch deployment cordon-test -n application -p '
{
  "spec": {
    "template": {
      "spec": {
        "tolerations": [{
          "key": "workload",
          "operator": "Equal",
          "value": "application",
          "effect": "NoSchedule"
        }]
      }
    }
  }
}'

# Step 4: Watch the pods go Pending
kubectl get pods -n application -w
# STATUS: Pending — no nodes available (all cordoned)

# Step 5: Describe a pending pod to see the scheduling failure
kubectl describe pod -n application -l app=cordon-test | grep -A 10 "Events:"
# Events: Warning FailedScheduling: 0/3 nodes available: 3 node(s) were unschedulable

# Step 6: Uncordon nodes to fix it
for node in $(kubectl get nodes -l node-pool=application -o name); do
  kubectl uncordon $node
  echo "Uncordoned: $node"
done

# Watch pods recover
kubectl get pods -n application -w

# Cleanup
kubectl delete deployment cordon-test -n application
```

**What you observed:** Cordon marks a node as `SchedulingDisabled`. New pods can't be scheduled there, but existing pods keep running. This is how you gracefully drain a node before maintenance.

---

### Exercise 2: Delete a Node and Watch Auto-Repair

**What we're testing:** GKE node auto-repair

```bash
# Step 1: List nodes and pick an application node
kubectl get nodes -l node-pool=application -o wide

# Note the node name
NODE_NAME="gke-gke-lab-cluster-application-pool-XXXXX"

# Step 2: Delete the node via gcloud (simulates node failure)
# First, find the instance group that owns this node
gcloud compute instances list \
  --filter="name:${NODE_NAME}" \
  --project=gke-labs

# Delete the underlying VM
gcloud compute instances delete ${NODE_NAME} \
  --zone=europe-west1-b \
  --project=gke-labs \
  --quiet

# Step 3: Watch what happens
kubectl get nodes -w
# The deleted node disappears from the node list immediately
# Within 2-3 minutes, a new node appears (GKE auto-repair)
# Within 5-7 minutes, the new node reaches Ready status

# Watch in a separate terminal
watch -n 5 "kubectl get nodes -o wide"

# Check events for auto-repair activity
kubectl get events -n kube-system | grep -i "repair\|node"

# Check the managed instance group activity
gcloud compute instance-groups managed list-instances \
  $(gcloud container clusters describe gke-lab-cluster \
    --region=europe-west1 \
    --project=gke-labs \
    --format="value(nodePools[1].instanceGroupUrls[0])" | \
    sed 's|.*/||') \
  --region=europe-west1 \
  --project=gke-labs
```

**What you observed:** GKE's node auto-repair detected the missing node within ~2 minutes and provisioned a replacement. This is managed by the **Managed Instance Group (MIG)** that backs each node pool. The MIG's target size ensures the pool always has the configured number of nodes.

---

### Exercise 3: Simulate Resource Pressure

```bash
# Deploy a memory-hungry pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: memory-hog
  namespace: application
spec:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "application"
      effect: "NoSchedule"
  containers:
    - name: memory-hog
      image: polinux/stress
      resources:
        requests:
          memory: "100Mi"
        limits:
          memory: "200Mi"
      command: ["stress"]
      args: ["--vm", "1", "--vm-bytes", "250M", "--timeout", "60s"]
EOF

# Watch the pod get OOM killed
kubectl get pod memory-hog -n application -w
# STATUS: OOMKilled → means it exceeded its memory limit

kubectl describe pod memory-hog -n application
# Look for: Last State: Terminated / Reason: OOMKilled

# Cleanup
kubectl delete pod memory-hog -n application
```

---

## 9. Interview Q&A

---

### Q1: What's the difference between a node pool and a node group in GKE?

**Answer:**

A **node pool** is GKE's abstraction — a set of nodes with identical configuration (machine type, disk, taints, labels, image type). GKE node pools are backed by **Managed Instance Groups (MIGs)**, which are GCP's compute abstraction.

When you tell GKE to add a node, it updates the MIG's target size and the MIG creates a new VM from the instance template. Node auto-repair and auto-upgrade work through the MIG — GKE can recreate instances using `recreate` actions without losing the node pool definition.

The practical difference: GKE users interact with node pools (GKE API); GCP infrastructure-level automation interacts with MIGs (Compute API).

---

### Q2: A pod is stuck in Pending. Walk me through your debugging process.

**Answer:**

```bash
# Step 1: Why is it pending?
kubectl describe pod <pod-name> -n <namespace>
# Look at the Events section at the bottom

# Common causes:
# "0 nodes available: N node(s) had untolerated taint"
#   → Fix: Add correct tolerations to the pod spec

# "0 nodes available: insufficient memory"
#   → Fix: Reduce memory requests OR scale up the node pool

# "0 nodes available: node(s) didn't match node selector"
#   → Fix: Correct the nodeSelector, or add the label to nodes

# "did not have required affinity"
#   → Fix: Correct pod/node affinity rules

# Step 2: Check if the node pool can scale up
kubectl get hpa,events -n <namespace>
gcloud container node-pools describe application-pool \
  --cluster=gke-lab-cluster --region=europe-west1

# Step 3: Check cluster autoscaler logs
kubectl logs -n kube-system -l component=cluster-autoscaler

# Step 4: Check node conditions
kubectl describe nodes | grep -A 5 "Conditions:"
```

---

### Q3: Explain the difference between resource Requests and Limits in GKE. What happens when you set limits but not requests?

**Answer:**

**Requests** are what the scheduler uses to find a node. The node must have at least `request` amount of CPU/memory available in its Allocatable capacity.

**Limits** are the hard ceiling enforced at runtime by the container runtime (cgroups). Exceeding CPU limit = throttled. Exceeding memory limit = OOMKilled.

If you set **limits but no requests**, Kubernetes sets requests = limits (for CPU and memory). This can cause over-provisioning if limits are set conservatively high.

If you set **neither**, the pod is `BestEffort` QoS class — it will be the first evicted when a node is under memory pressure.

The **three QoS classes**:
- `Guaranteed`: requests = limits (for all containers) — safest
- `Burstable`: requests < limits — recommended for most apps
- `BestEffort`: no requests or limits — evicted first, use only for batch

---

### Q4: What is the cluster autoscaler and how does it differ from the HorizontalPodAutoscaler?

**Answer:**

**HPA (HorizontalPodAutoscaler):** Scales the number of *pods* based on metrics (CPU utilization, custom metrics, external metrics). HPA doesn't create nodes — if there's no capacity, new pods pend.

**Cluster Autoscaler (CA):** Scales the number of *nodes*. It watches for pending pods and, if they're pending due to insufficient resources, adds nodes to the pool. It also scales down by identifying nodes with low utilization that can be drained safely.

They work together: HPA fires, creates new pods, they pend → CA fires, adds a node → pods schedule.

**Key CA behaviors:**
- Scale-up triggered within 1-2 minutes of pods pending
- Scale-down is conservative: a node must be underutilized for 10+ minutes before removal
- CA respects PodDisruptionBudgets during scale-down
- Spot pool CA can scale to zero (min=0) unlike regular pools

---

### Q5: What happens to running pods when you perform a GKE node upgrade?

**Answer:**

GKE performs node upgrades via a **blue-green rollout**:

1. New node is provisioned with the new Kubernetes version
2. The old node is **cordoned** (no new pods schedule there)
3. The old node is **drained** (pods are gracefully evicted, respecting PodDisruptionBudgets and `terminationGracePeriodSeconds`)
4. The old node is deleted
5. Repeat for each node in the pool

Critical production considerations:
- Set `PodDisruptionBudget` to ensure at least N replicas stay running during drain
- Set `terminationGracePeriodSeconds` long enough for graceful shutdown
- Use `maxSurge` and `maxUnavailable` in the node pool upgrade settings to control rollout speed
- Monitor with `kubectl get nodes -w` and `kubectl get pods -A -w` during upgrade
