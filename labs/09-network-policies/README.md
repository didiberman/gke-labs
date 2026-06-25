# Lab 09 — Network Policies

> **Goal:** Lock down the `payments` namespace to a zero-trust baseline: no traffic in or out
> unless explicitly permitted. By the end you should be able to write NetworkPolicy YAML from
> memory, test policies with `kubectl exec`, and explain how GKE DataPlane V2 (eBPF) enforces
> them differently from legacy iptables Calico.

> **Series position:** Labs 01–06 built the cluster and deployed services. This lab adds the
> network security layer on top. The `payments` namespace must already exist with `payments-api`,
> a Cloud SQL Auth Proxy sidecar, and a Redis client.

---

## Table of Contents

1. [Why Default-Allow Is Dangerous in Kubernetes](#1-why-default-allow-is-dangerous-in-kubernetes)
2. [NetworkPolicy Spec Anatomy](#2-networkpolicy-spec-anatomy)
3. [Zero-Trust Baseline — Deny-All + Explicit Allow](#3-zero-trust-baseline--deny-all--explicit-allow)
4. [Payments Namespace Isolation](#4-payments-namespace-isolation)
5. [Testing Policies with kubectl exec + curl](#5-testing-policies-with-kubectl-exec--curl)
6. [Calico vs Cilium — How GKE DataPlane V2 (eBPF) Changes the Game](#6-calico-vs-cilium--how-gke-dataplane-v2-ebpf-changes-the-game)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. Why Default-Allow Is Kubernetes' Biggest Security Footgun

Fresh Kubernetes clusters have **no NetworkPolicy objects**. With no policy, all traffic is
allowed: any pod can reach any other pod, in any namespace, on any port.

### What This Means in Practice

```
Default state (no NetworkPolicy):

  payments-api ──────────────────────────────► auth-service          ✅ intended
  payments-api ──────────────────────────────► cloud-sql-proxy       ✅ intended
  payments-api ──────────────────────────────► kube-dns              ✅ needed

  debug-pod (in kube-system) ────────────────► payments-api:8080     ✅ or ❌?
  debug-pod ─────────────────────────────────► cloud-sql-proxy:5432  ❌ should be blocked
  compromised-app (any namespace) ───────────► payments-api:8080     ❌ lateral movement
  compromised-app ────────────────────────────► metadata-server:80   ❌ SSRF to steal SA tokens
```

In a financial services platform:
- A compromised pod in the `staging` namespace can query `payments-api` in production
- An attacker with code execution in any pod can scan the cluster's internal network
- A misconfigured service can accidentally write to Cloud SQL through the proxy

### The Attack Path Without Network Policies

```
Internet
   │
   ▼ (exploited CVE in shopping-cart service)
shopping-cart pod (staging namespace)
   │
   │  Direct pod-to-pod traffic — no policy blocks it
   ▼
payments-api pod (payments namespace)
   │
   │  Cloud SQL Proxy accepts connections from any client
   ▼
cloud-sql-proxy:5432 (payments namespace)
   │
   ▼
Cloud SQL (financial transactions database)
```

### The Kubernetes Networking Model

By design, the Kubernetes network model requires:
1. Every pod gets a unique IP address
2. Any pod can communicate with any other pod without NAT
3. No filtering unless NetworkPolicy objects explicitly add it

NetworkPolicy is **additive** — you start from "allow everything" and add deny rules by
creating policy objects. The policies are enforced by the **CNI plugin** (Calico or Cilium),
not by kube-proxy or the API server.

---

## 2. NetworkPolicy Spec Anatomy

A `NetworkPolicy` selects a set of pods and specifies what ingress (inbound) and/or egress
(outbound) traffic is allowed.

### The Full Spec

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: policy-name
  namespace: payments      # Policies are namespace-scoped
spec:

  # Step 1: Which pods does this policy apply to?
  podSelector:
    matchLabels:
      app: payments-api    # Applies to pods with label app=payments-api
                           # {} means ALL pods in this namespace

  # Step 2: Which directions does this policy control?
  policyTypes:
    - Ingress              # Control inbound connections
    - Egress               # Control outbound connections
                           # If Ingress listed: ingress is restricted to rules below
                           # If Egress listed: egress is restricted to rules below

  # Step 3: What inbound traffic is allowed?
  ingress:
    - from:                # Allow from these sources
        - podSelector:       # Source must have this label
            matchLabels:
              app: ingress-nginx
          namespaceSelector: # AND be in this namespace
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
        - ipBlock:           # OR from this CIDR (e.g., load balancer health checks)
            cidr: 10.132.0.0/20
            except:
              - 10.132.0.5/32   # Exclude this specific IP
      ports:
        - protocol: TCP
          port: 8080

  # Step 4: What outbound traffic is allowed?
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: cloud-sql-proxy
      ports:
        - protocol: TCP
          port: 5432
    - to:                  # Allow DNS resolution (always needed)
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### Key Selector Combinations

The `from` and `to` arrays use **OR** logic between list items, but `podSelector`
and `namespaceSelector` within the **same** list item use **AND** logic.

```yaml
# This means: pods labeled app=web AND in namespace labeled env=prod
- from:
  - podSelector:
      matchLabels:
        app: web
    namespaceSelector:      # Same list item → AND
      matchLabels:
        env: prod

# This means: pods labeled app=web OR any pod in namespace labeled env=prod
- from:
  - podSelector:            # Separate list item → OR
      matchLabels:
        app: web
  - namespaceSelector:      # Separate list item → OR
      matchLabels:
        env: prod
```

> This AND vs OR distinction is one of the most common NetworkPolicy mistakes. Always test.

---

## 3. Zero-Trust Baseline — Deny-All + Explicit Allow

### Step 1: Label the Namespace

NetworkPolicy selectors reference namespace labels. Always label your namespaces:

```bash
# Label the payments namespace
kubectl label namespace payments \
  kubernetes.io/metadata.name=payments \
  env=production \
  team=payments

# Label kube-system (needed for DNS egress rules)
kubectl label namespace kube-system \
  kubernetes.io/metadata.name=kube-system

# Verify
kubectl get namespace payments --show-labels
```

### Step 2: Deny-All Ingress and Egress

```yaml
# deny-all.yaml — apply this FIRST, then add explicit allows
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}       # Applies to ALL pods in namespace
  policyTypes:
    - Ingress
    - Egress
  # No ingress/egress rules = deny everything
```

```bash
kubectl apply -f deny-all.yaml

# Verify: DNS should fail immediately after applying deny-all
kubectl run dns-test \
  --image=busybox \
  --rm -it \
  --restart=Never \
  --namespace=payments \
  -- nslookup kubernetes.default
# ;; connection timed out; no servers could be reached
# Expected — DNS is now blocked too
```

### Step 3: Allow DNS (Without This, Nothing Works)

```yaml
# allow-dns-egress.yaml — always apply this alongside deny-all
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```bash
kubectl apply -f allow-dns-egress.yaml

# Verify DNS works again
kubectl run dns-test \
  --image=busybox \
  --rm -it \
  --restart=Never \
  --namespace=payments \
  -- nslookup kubernetes.default
# Server:    10.96.0.10
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
# ✅ DNS is working, everything else is still blocked
```

---

## 4. Payments Namespace Isolation

The `payments` namespace handles financial transactions. The security requirements:

```
ALLOWED inbound:
  ✅ ingress-nginx gateway → payments-api:8080 (public API traffic)

ALLOWED outbound:
  ✅ payments-api → cloud-sql-proxy:5432 (database writes)
  ✅ payments-api → redis:6379 (session/cache)
  ✅ all pods → kube-dns:53 (DNS resolution)
  ✅ cloud-sql-proxy → 0.0.0.0/0:3307 (Cloud SQL IAM auth via TCP tunnel)

BLOCKED everything else:
  ❌ payments-api → staging namespace
  ❌ payments-api → monitoring namespace
  ❌ any other namespace → payments-api
  ❌ payments-api → internet (except Cloud SQL tunnel)
```

### Policy 1: Allow Ingress from Gateway

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-gateway
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
```

### Policy 2: Allow Egress to Cloud SQL Proxy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-cloudsql
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: cloud-sql-proxy
      ports:
        - protocol: TCP
          port: 5432    # PostgreSQL port on the proxy
```

### Policy 3: Allow Egress to Redis

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-redis
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - protocol: TCP
          port: 6379
```

### Policy 4: Allow Cloud SQL Proxy Egress to GCP

The Cloud SQL Auth Proxy connects outbound to GCP's Cloud SQL service. This is an external IP:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-cloudsql-proxy-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: cloud-sql-proxy
  policyTypes:
    - Egress
  egress:
    # Cloud SQL uses port 3307 for the Auth Proxy connection
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0     # Cloud SQL IPs are GCP-managed — allow all
            except:
              - 10.0.0.0/8      # But NOT internal cluster traffic
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 3307
```

### Apply All Policies

```bash
# Apply the full payments namespace policy set
kubectl apply -f deny-all.yaml
kubectl apply -f allow-dns-egress.yaml
kubectl apply -f allow-ingress-from-gateway.yaml
kubectl apply -f allow-egress-to-cloudsql.yaml
kubectl apply -f allow-egress-to-redis.yaml
kubectl apply -f allow-cloudsql-proxy-egress.yaml

# Verify all policies are created
kubectl get networkpolicies -n payments

# NAME                          POD-SELECTOR       AGE
# allow-dns-egress              <none>             5s
# allow-egress-to-cloudsql      app=payments-api   5s
# allow-egress-to-redis         app=payments-api   5s
# allow-ingress-from-gateway    app=payments-api   5s
# allow-cloudsql-proxy-egress   app=cloud-sql-proxy 5s
# default-deny-all              <none>             5s
```

---

## 5. Testing Policies with kubectl exec + curl

**Never deploy a NetworkPolicy without testing it.** Untested policies can silently break
services in non-obvious ways (DNS failures, health check failures, downstream dependency
timeouts).

### Test 1: Verify Gateway → API Is Allowed

```bash
# Port-forward to simulate gateway
kubectl port-forward svc/payments-api 8080:8080 -n payments &

# Request through the port-forward (bypasses NetworkPolicy — for baseline)
curl -i http://localhost:8080/health

# Test from an ingress-nginx pod (goes through NetworkPolicy)
INGRESS_POD=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o name | head -1)
kubectl exec -n ingress-nginx ${INGRESS_POD} -- \
  curl -si http://payments-api.payments.svc.cluster.local:8080/health
# Expected: HTTP/1.1 200 OK ✅
```

### Test 2: Verify Cross-Namespace Blocked

```bash
# Try to reach payments-api from a different namespace
kubectl run attack-pod \
  --image=curlimages/curl \
  --restart=Never \
  --namespace=default \
  -- curl -v --max-time 5 http://payments-api.payments.svc.cluster.local:8080/health

# Check the logs
kubectl logs attack-pod -n default
# Expected: curl: (28) Connection timed out after 5001 milliseconds ✅

kubectl delete pod attack-pod -n default
```

### Test 3: Verify DNS Works

```bash
kubectl run dns-test \
  --image=busybox \
  --rm -it \
  --restart=Never \
  --namespace=payments \
  -- nslookup redis.payments.svc.cluster.local
# Expected: Answer from kube-dns with IP address ✅
```

### Test 4: Verify Redis Connection Allowed

```bash
# From payments-api pod, test Redis connectivity
PAYMENTS_POD=$(kubectl get pod -n payments -l app=payments-api -o name | head -1)

kubectl exec -n payments ${PAYMENTS_POD} -- \
  nc -zv redis.payments.svc.cluster.local 6379
# Expected: Connection to redis.payments.svc.cluster.local 6379 port [tcp/redis] succeeded! ✅

# Test from a pod that should NOT be allowed
kubectl run redis-attack \
  --image=busybox \
  --restart=Never \
  --namespace=default \
  -- nc -zv redis.payments.svc.cluster.local 6379

kubectl logs redis-attack -n default
# Expected: nc: timed out ✅

kubectl delete pod redis-attack -n default
```

### Test 5: Verify No Unexpected Egress

```bash
# payments-api should NOT be able to reach the internet
PAYMENTS_POD=$(kubectl get pod -n payments -l app=payments-api -o name | head -1)

kubectl exec -n payments ${PAYMENTS_POD} -- \
  curl --max-time 5 https://example.com
# Expected: curl: (28) Connection timed out ✅
```

### Test Matrix — Document Your Tests

| Source | Destination | Port | Expected | Actual |
|--------|------------|------|----------|--------|
| ingress-nginx (pod) | payments-api | 8080 | ✅ Allow | |
| default namespace | payments-api | 8080 | ❌ Block | |
| payments-api | cloud-sql-proxy | 5432 | ✅ Allow | |
| payments-api | redis | 6379 | ✅ Allow | |
| payments-api | 8.8.8.8 | 443 | ❌ Block | |
| payments-api | kube-dns | 53 | ✅ Allow | |
| monitoring (pod) | payments-api | 8080 | ❌ Block | |

---

## 6. Calico vs Cilium — How GKE DataPlane V2 (eBPF) Changes the Game

### Traditional Calico: iptables-Based Enforcement

Before GKE DataPlane V2, GKE used Calico with iptables:

```
Packet arrives at node
  │
  ▼
iptables PRE_ROUTING chain
  ├── KUBE-SERVICES rules (service IP translation)
  ├── CALICO-FROM-HOST-ENDPOINT rules
  └── CALICO-POD-TO-POD rules
        ├── Match network policy → ACCEPT
        └── No match → DROP

  iptables rules: O(N) per packet lookup, N = total rules in cluster
  At 10,000 services × 50 endpoints: ~500,000 iptables rules
  Packet processing time: grows linearly with cluster size
```

**iptables limitations at scale:**
- Rule sync time: at 10k+ services, a single service update takes 5–10 seconds to propagate
- Memory: each iptables rule takes ~500 bytes; 500k rules = 250MB kernel memory
- Debugging: `iptables-save | grep <pod-ip>` returns thousands of lines

### GKE DataPlane V2: Cilium + eBPF

GKE DataPlane V2 replaces iptables with eBPF (extended Berkeley Packet Filter) programs
attached directly to the Linux kernel's networking stack:

```
Packet arrives at NIC (network interface)
  │
  ▼
eBPF XDP program (runs at driver level, before kernel TCP/IP stack)
  │
  ├── Lookup BPF hash map: (src_ip, dst_ip, dst_port) → verdict
  │     O(1) lookup — hash map, not linear iptables scan
  │
  ├── ALLOW → forward to destination
  └── DENY  → drop in-place (never reaches kernel TCP/IP stack)
```

### DataPlane V2 Advantages

| Feature | iptables (Classic) | eBPF (DataPlane V2) |
|---------|-------------------|---------------------|
| Lookup time | O(N) rules | O(1) hash map |
| Rule sync | Full iptables rewrite on change | Incremental BPF map update |
| Network Policy enforcement | Node-level | Pod-level (per-pod BPF program) |
| Visibility | Zero (rules drop silently) | Network flow logs per pod |
| Encryption | Requires Istio/mTLS | WireGuard transparent encryption (built-in) |
| Load balancing | kube-proxy DNAT | Direct BPF DNAT (removes kube-proxy) |
| Service mesh | External (Istio, Linkerd) | Cilium Service Mesh (sidecar-free option) |

### Enabling DataPlane V2 on GKE

```bash
# DataPlane V2 must be enabled at cluster creation — cannot be changed later
gcloud container clusters create gke-labs-dev \
  --project=gke-labs \
  --region=europe-west1 \
  --enable-dataplane-v2 \
  --cluster-version=latest

# Check if DataPlane V2 is enabled on an existing cluster
gcloud container clusters describe gke-labs-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(networkConfig.datapathProvider)"
# Expected: ADVANCED_DATAPATH

# Check Cilium is running (DataPlane V2 uses managed Cilium under the hood)
kubectl get pods -n kube-system | grep cilium
# anetd-xxxxx (GKE's Cilium agent, named "anetd")
```

### Network Flow Visibility with DataPlane V2

```bash
# Enable network policy logging (DataPlane V2 feature)
# Packets dropped by NetworkPolicy are logged to Cloud Logging

# View denied connections in Cloud Logging
gcloud logging read \
  'resource.type="k8s_node" AND jsonPayload.connection.dest_port=8080' \
  --project=gke-labs \
  --freshness=1h \
  --format=json | \
  jq '.[] | {src: .jsonPayload.connection.src_ip, dst: .jsonPayload.connection.dest_ip, verdict: .jsonPayload.disposition}'
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1: Missing DNS Rule Breaks Everything

**What we're testing:** Understand why DNS egress must be the first policy you add.

```bash
# === BREAK IT ===
# Apply deny-all WITHOUT the DNS egress allow
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-break-test
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF

# Try to make any request from a payments pod
PAYMENTS_POD=$(kubectl get pod -n payments -l app=payments-api -o name | head -1)
kubectl exec -n payments ${PAYMENTS_POD} -- \
  curl --max-time 5 http://redis.payments.svc.cluster.local:6379

# === OBSERVE ===
# Error: curl: (6) Could not resolve host: redis.payments.svc.cluster.local
# NOT a connection refused — DNS resolution fails first because CoreDNS port 53 is blocked

# The app's own health checks will fail
kubectl get pods -n payments
# payments-api may show Unhealthy readinessProbe failures

# === FIX IT ===
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-break-test
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF

# Test again
kubectl exec -n payments ${PAYMENTS_POD} -- \
  nslookup redis.payments.svc.cluster.local
# Now resolves successfully ✅

# Cleanup
kubectl delete networkpolicy deny-all-break-test allow-dns-break-test -n payments
```

---

### Exercise 2: AND vs OR Selector Bug

**What we're testing:** The AND/OR distinction in podSelector + namespaceSelector.

```bash
# === SETUP ===
kubectl label namespace ingress-nginx kubernetes.io/metadata.name=ingress-nginx

# === BREAK IT ===
# Apply a policy with the WRONG selector combination (OR instead of AND)
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wrong-selector-test
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:               # Separate items = OR
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
        - namespaceSelector:         # This allows ANY pod in ANY namespace
            matchLabels:             # that has label env=production
              env: production
      ports:
        - protocol: TCP
          port: 8080
EOF

# This policy accidentally allows ANY pod in ANY production-labeled namespace
# to reach payments-api — not just the ingress controller

# Label a namespace as production
kubectl label namespace default env=production

# Now a pod in 'default' namespace can reach payments-api
kubectl run bypass-test \
  --image=curlimages/curl \
  --restart=Never \
  --namespace=default \
  -- curl -si http://payments-api.payments.svc.cluster.local:8080/health

kubectl logs bypass-test -n default
# HTTP/1.1 200 OK — This should have been blocked!

# === FIX IT ===
# Use a SINGLE list item with BOTH selectors (AND logic)
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wrong-selector-test
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:               # Same list item = AND
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
          namespaceSelector:         # Must be BOTH ingress pod AND ingress namespace
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
EOF

# Re-run the bypass test — now it should be blocked
kubectl delete pod bypass-test -n default 2>/dev/null

kubectl run bypass-retry \
  --image=curlimages/curl \
  --restart=Never \
  --namespace=default \
  -- curl -si --max-time 5 http://payments-api.payments.svc.cluster.local:8080/health

kubectl logs bypass-retry -n default
# curl: (28) Connection timed out ✅ Correctly blocked

# Cleanup
kubectl delete pod bypass-retry -n default
kubectl delete networkpolicy wrong-selector-test -n payments
kubectl label namespace default env-
```

---

### Exercise 3: Health Check Broken by Egress Policy

```bash
# === BREAK IT ===
# Apply an egress policy that blocks the kubelet health check path
# (This simulates a real mistake: over-restricting egress on pods with health checks
# that call external services)

# First, check what health check endpoint payments-api uses
kubectl describe deployment payments-api -n payments | grep -A 5 "Liveness:"

# Apply a policy that blocks egress to the monitoring namespace
# (many health checks emit metrics or call healthcheck aggregators)
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-monitoring-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: cloud-sql-proxy
      ports:
        - protocol: TCP
          port: 5432
    # DNS is in a separate policy — this one doesn't include it
    # Also not including Redis — this will cause health check failures
EOF

# === OBSERVE ===
# Watch for health check failures
kubectl get events -n payments | grep -i "unhealthy\|failed\|probe"

# Pods will show 0/1 READY if liveness probe requires Redis
kubectl get pods -n payments

# === FIX IT ===
# Add missing Redis egress rule
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-redis-fix
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - protocol: TCP
          port: 6379
EOF

kubectl rollout restart deployment/payments-api -n payments
kubectl rollout status deployment/payments-api -n payments

# Cleanup
kubectl delete networkpolicy block-monitoring-egress allow-egress-redis-fix -n payments
```

---

## 8. Interview Q&A

---

### Q1: Kubernetes pods can talk to each other by default. How would you implement a zero-trust network model?

**Answer:**

The key insight is that NetworkPolicy is **additive from a deny perspective** — policies are
ORed together, meaning you can't create a "deny" rule. You create a baseline deny-all, then
add explicit allow rules on top.

**Step-by-step zero-trust implementation:**

1. **Label all namespaces** with `kubernetes.io/metadata.name=<name>` so namespaceSelector
   can reference them precisely.

2. **Apply default-deny-all** to every namespace that should be isolated:
   ```yaml
   podSelector: {}
   policyTypes: [Ingress, Egress]
   # No rules = deny all
   ```

3. **Add DNS egress** as the first allow rule (without DNS, nothing works):
   UDP/TCP port 53 to kube-dns.

4. **Add service-specific allows**: ingress from legitimate callers (with both podSelector
   AND namespaceSelector to restrict by both identity and namespace), egress to dependencies.

5. **Allow metrics scraping** from Prometheus in the monitoring namespace (easy to forget).

6. **Test with curl/nc** from unauthorized pods to verify blocks are in place.

7. **Enable Network Policy logging** (GKE DataPlane V2) or use Cilium Hubble to audit
   allowed/denied connections.

The hardest part: discovering all legitimate traffic flows. Use a CNI with flow visibility
(Cilium Hubble, Calico flow logs) in **audit mode** before enforcing, to see what
communication exists in production before writing the policies.

---

### Q2: Explain the difference between podSelector and namespaceSelector in a NetworkPolicy `from` clause.

**Answer:**

`podSelector` matches pods by their **labels**. `namespaceSelector` matches pods by the
**labels on their namespace**.

The critical subtlety: **where you place them in the YAML determines AND vs OR logic**.

```yaml
# AND: source must be a pod matching both conditions simultaneously
from:
  - podSelector: {matchLabels: {app: frontend}}
    namespaceSelector: {matchLabels: {env: prod}}
# → Only pods with app=frontend that are in a namespace labeled env=prod

# OR: source can be either condition independently
from:
  - podSelector: {matchLabels: {app: frontend}}
  - namespaceSelector: {matchLabels: {env: prod}}
# → Any pod with app=frontend (in ANY namespace)
# → OR any pod (with any labels) in a namespace labeled env=prod
```

The OR form is almost always a security mistake — it allows any pod in a namespace.
Always use the AND form (both selectors in the same list item) when you want to restrict
to a specific pod identity in a specific namespace.

---

### Q3: What is GKE DataPlane V2 and why does it matter for NetworkPolicy?

**Answer:**

GKE DataPlane V2 is Google's eBPF-based networking stack (built on Cilium). It replaces
kube-proxy and iptables with eBPF programs loaded directly into the Linux kernel.

**Why it matters for NetworkPolicy:**

1. **Performance**: iptables has O(N) per-packet lookup across all rules. eBPF uses hash maps
   with O(1) lookup. At 10,000+ services, this is a dramatic difference in latency.

2. **Policy enforcement granularity**: iptables rules are evaluated on the node's network
   namespace. eBPF programs are attached per-pod — each pod has its own ingress/egress programs,
   providing stronger isolation.

3. **Observability**: DataPlane V2 logs every dropped packet to Cloud Logging with full
   five-tuple (src IP, dst IP, src port, dst port, protocol). With iptables, packets are
   dropped silently — you know something is blocked but not what.

4. **L7 policy** (future): Cilium's eBPF can enforce HTTP-level policies (allow GET /health
   but not POST /admin). Standard K8s NetworkPolicy is L3/L4 only.

To enable: `--enable-dataplane-v2` at cluster creation. It cannot be changed post-creation.

---

### Q4: A pod in the payments namespace suddenly can't reach Cloud SQL. How do you debug it?

**Answer:**

```bash
# Step 1: Verify the proxy pod is running and healthy
kubectl get pods -n payments -l app=cloud-sql-proxy
kubectl describe pod <proxy-pod> -n payments | grep -A 5 "Conditions:"

# Step 2: Test connectivity at the network level (before app-layer)
PAYMENTS_POD=$(kubectl get pod -n payments -l app=payments-api -o name | head -1)
kubectl exec -n payments ${PAYMENTS_POD} -- \
  nc -zv cloud-sql-proxy.payments.svc.cluster.local 5432

# If this times out: NetworkPolicy is blocking it
# If connection refused: the proxy pod is down or not listening
# If connection succeeds: problem is at application layer (credentials, SSL)

# Step 3: Verify NetworkPolicy allows the traffic
kubectl get networkpolicies -n payments
# Look for a policy with podSelector: app=payments-api and egress to port 5432

# Step 4: Check for recently changed policies
kubectl get networkpolicies -n payments -o yaml | grep -A 30 "cloud-sql\|5432"

# Step 5: On DataPlane V2 — check flow logs for drops
gcloud logging read \
  'resource.type="k8s_node" AND jsonPayload.connection.dest_port=5432 AND jsonPayload.disposition="deny"' \
  --project=gke-labs \
  --freshness=30m

# Step 6: Verify the proxy itself can reach Cloud SQL (separate from the app → proxy hop)
kubectl exec -n payments <proxy-pod> -- \
  nc -zv <cloud-sql-ip> 3307
```

Most likely root causes: (a) NetworkPolicy was updated and no longer allows app→proxy traffic,
(b) Cloud SQL Proxy pod was deleted and recreated with a different label, (c) ResourceQuota
exhaustion prevented the proxy from restarting after a crash.

---

*Next: [Lab 10 — CI/CD Pipeline](../10-cicd-pipeline/README.md)*
