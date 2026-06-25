# Lab 10 — CI/CD Pipeline

> **Goal:** Understand every job in the three workflow files — `ci.yml`, `cd-dev.yml`, and
> `cd-staging.yml` — and know how to debug failures in each. Learn Dockerfile best practices,
> how Trivy surfaces CRITICAL vulnerabilities, what `helm upgrade --atomic` does on failure,
> and when to choose canary vs blue/green vs rolling deployments.

> **Series position:** Labs 01–09 built and secured the cluster. This lab covers how code gets
> from a developer's laptop to the running cluster. The workflow files are at
> `.github/workflows/` in this repository.

---

## Table of Contents

1. [GitHub Actions Workflow Anatomy](#1-github-actions-workflow-anatomy)
2. [Container Image Build — Dockerfile Best Practices](#2-container-image-build--dockerfile-best-practices)
3. [Image Scanning with Trivy](#3-image-scanning-with-trivy)
4. [Helm Upgrade with --atomic and Rollback Mechanics](#4-helm-upgrade-with---atomic-and-rollback-mechanics)
5. [Smoke Tests in CI — What to Test After Deploy](#5-smoke-tests-in-ci--what-to-test-after-deploy)
6. [Progressive Delivery — Canary vs Blue/Green vs Rolling](#6-progressive-delivery--canary-vs-bluegreen-vs-rolling)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. GitHub Actions Workflow Anatomy

This repository has three workflow files. Each has a distinct role and trigger:

```
.github/workflows/
  ├── ci.yml          — Runs on every push to main/develop + PRs
  │                     Jobs: lint-terraform, lint-helm, docker-build, terraform-plan
  │
  ├── cd-dev.yml      — Runs on every push to main (auto-deploy)
  │                     Jobs: deploy (Helm upgrade → smoke test → rollback on failure)
  │
  └── cd-staging.yml  — Manual trigger only (workflow_dispatch)
                        Jobs: deploy (with required reviewer approval), integration-test
```

### ci.yml — The Four Jobs

```
Push to main/develop or PR to main
         │
         ├──────────────────────────────────────────────────────────────┐
         │                                                              │
         ▼                                                              ▼
  lint-terraform                                                   lint-helm
  ─────────────                                                    ─────────
  • terraform fmt -check -recursive                                • helm lint --strict
  • terraform init -backend=false                                  • validates chart syntax
  • terraform validate                                             • validates values schemas
         │                                                              │
         └───────────────────────┬───────────────────────────────────────┘
                                 │ (both must pass)
                                 ▼
                          docker-build
                          ─────────────
                          • docker buildx build (no push)
                          • trivy scan → SARIF uploaded to GitHub Security
                          • Fails on CRITICAL vulnerabilities
                                 │
                                 ▼
                       terraform-plan (PRs only)
                       ──────────────────────────
                       • GCP auth via Workload Identity Federation
                       • terraform plan for each environment
                       • Posts plan diff as PR comment
```

### cd-dev.yml — Deploy on Every Merge

The CD workflow triggers on **push to `main`** — every merged PR auto-deploys to dev:

```
Push to main
     │
     ▼
Deploy job (environment: dev)
  1. Checkout + GCP auth (Workload Identity Federation — no SA keys)
  2. gcloud container clusters get-credentials gke-labs-dev
  3. helm upgrade --install payments-api helm/payments-api \
       --namespace payments \
       --values helm/payments-api/values-dev.yaml \
       --set image.tag=$IMAGE_TAG \
       --atomic \         ← rolls back automatically on failure
       --timeout 5m
  4. helm upgrade --install observability helm/observability \
       --namespace observability \
       --atomic \
       --timeout 5m
  5. Smoke test: curl /health endpoint
  6. If smoke test fails → helm rollback (triggered by --atomic)
```

Key environment variables in `cd-dev.yml`:

```yaml
env:
  GKE_CLUSTER:   gke-labs-dev
  GKE_LOCATION:  europe-west1       # regional cluster
  PAYMENTS_NS:   payments
  IMAGE_TAG:     ${{ github.sha }}  # Every deploy uses the exact commit SHA as image tag
```

### cd-staging.yml — Manual Gated Deployment

Staging requires a **human approval** before deploying:

```yaml
# The 'staging' GitHub Environment has Required Reviewers configured
# (Settings → Environments → staging → Required reviewers)
environment:
  name: staging
  url: https://payments-api.staging.example.com
```

This causes the deploy job to **pause at the environment gate**. A team member must click
"Review deployments → Approve" in the GitHub Actions UI before the deploy proceeds.

Additionally, `cd-staging.yml` runs an `integration-test` job after deploy:

```
deploy job (waits for approval)
     │
     ▼  (approved)
Helm upgrade → staging cluster
     │
     ▼
integration-test job
  • needs: [deploy]   ← only runs if deploy succeeded
  • Runs full API test suite against staging endpoint
  • kubectl wait --for=condition=available deployment/payments-api
  • curl POST /payments (end-to-end transaction test)
  • If tests fail: manual rollback required (no --atomic here, want to keep failed env for debugging)
```

### Workload Identity Federation — No SA Keys

Both CD workflows authenticate to GCP without storing service account JSON keys:

```yaml
- name: Authenticate to Google Cloud (WIF)
  uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    service_account:            ${{ secrets.GCP_SERVICE_ACCOUNT }}
```

The OIDC token from GitHub Actions is exchanged for a short-lived GCP access token.
The `workload_identity_provider` secret contains a resource name like:
`projects/123456789/locations/global/workloadIdentityPools/github-pool/providers/github-provider`

```bash
# One-time setup for Workload Identity Federation
gcloud iam workload-identity-pools create github-pool \
  --project=gke-labs \
  --location=global \
  --display-name="GitHub Actions Pool"

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --project=gke-labs \
  --location=global \
  --workload-identity-pool=github-pool \
  --display-name="GitHub OIDC Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Grant the GitHub Actions SA permission to deploy to GKE
gcloud projects add-iam-policy-binding gke-labs \
  --role="roles/container.developer" \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository/your-org/gke-labs"
```

---

## 2. Container Image Build — Dockerfile Best Practices

The `ci.yml` workflow builds the image at `docker/httpbin/Dockerfile`. Here are the principles
that apply to any service in this platform.

### Multi-Stage Build

Multi-stage builds separate the **build environment** (compiler, test runner, dev dependencies)
from the **runtime image** (only what the app needs to run):

```dockerfile
# Stage 1: Builder — has the full toolchain
FROM node:20-alpine AS builder

WORKDIR /app

# Copy dependency manifests first (cache layer invalidation optimization)
COPY package.json package-lock.json ./
RUN npm ci --only=production    # Install only production deps

# Copy source code (changes more frequently — cache miss expected here)
COPY src/ ./src/
RUN npm run build               # Compile TypeScript / bundle

# Stage 2: Runtime — minimal image, no build tools
FROM node:20-alpine AS runtime

# Run as non-root (security best practice)
RUN addgroup -S payments && adduser -S payments -G payments
USER payments

WORKDIR /app

# Copy only the compiled output and production node_modules
COPY --from=builder --chown=payments:payments /app/dist/ ./dist/
COPY --from=builder --chown=payments:payments /app/node_modules/ ./node_modules/

# Declare port (documentation only — doesn't actually expose the port)
EXPOSE 8080

# Use exec form to ensure SIGTERM is passed to the Node.js process
# (shell form `CMD node ...` wraps in /bin/sh, which doesn't forward signals)
CMD ["node", "dist/server.js"]
```

**Size comparison:**
```
node:20 (full image):          1.1GB
node:20-alpine (builder):      180MB
Multi-stage runtime output:    ~90MB
```

### Distroless Images

For maximum security, use Google's distroless base images — they contain only the runtime
(JVM, Python interpreter, Node.js runtime) with no shell, no package manager:

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o payments-api .

FROM gcr.io/distroless/static-debian12 AS runtime
# No shell, no package manager, no apt, no curl
COPY --from=builder /app/payments-api /payments-api
USER nonroot:nonroot
ENTRYPOINT ["/payments-api"]
```

**Distroless benefits:**
- Massively reduced attack surface (no `sh`, no `curl`, no `wget`)
- Smaller image size (~5MB for static binaries)
- No CVEs in system packages (almost none to scan)
- **Trade-off**: you cannot `kubectl exec` into a distroless container (no shell)

### Image Tagging Strategy

```
Bad:    image: payments-api:latest
  → "latest" is mutable — you don't know what version is running

Good:   image: europe-west1-docker.pkg.dev/gke-labs/payments/payments-api:sha-abc1234
  → Pinned to a specific commit SHA — immutable, auditable

The cd-dev.yml workflow uses:
  image.tag: ${{ github.sha }}
  → Full 40-character commit SHA as the tag
  → Every commit gets a unique, traceable image
```

```bash
# Build and push with commit SHA tag (what the CI workflow does)
IMAGE_TAG=$(git rev-parse HEAD)
REGISTRY="europe-west1-docker.pkg.dev/gke-labs/payments"

docker buildx build \
  --platform linux/amd64 \
  --tag "${REGISTRY}/payments-api:${IMAGE_TAG}" \
  --push \
  docker/payments-api/

# Verify the image is in Artifact Registry
gcloud artifacts docker images list \
  europe-west1-docker.pkg.dev/gke-labs/payments \
  --project=gke-labs
```

---

## 3. Image Scanning with Trivy

The `ci.yml` workflow runs Trivy as a required check. Understanding its output is critical
for making informed decisions about vulnerability remediation.

### How Trivy Scans

Trivy scans container images layer by layer:
1. Pulls the image manifest and extracts each layer
2. Identifies the OS distribution and version (Alpine 3.19, Debian 12, etc.)
3. Lists all installed packages and their versions
4. Cross-references against the CVE database (NVD, GitHub Advisory, etc.)
5. Also scans application-level dependencies (node_modules, go.sum, requirements.txt)

### What a CRITICAL Vulnerability Looks Like

```yaml
# In ci.yml, the Trivy step:
- name: Run Trivy vulnerability scanner
  uses: aquasecurity/trivy-action@0.24.0
  with:
    image-ref: "httpbin:${{ github.sha }}"
    format:    "sarif"
    output:    "trivy-results.sarif"
    severity:  "CRITICAL"
    exit-code: "1"           # Fails the job
    ignore-unfixed: true     # Skip CVEs with no available fix
```

Sample SARIF output (what ends up in GitHub Security → Code scanning):

```json
{
  "ruleId": "CVE-2024-12345",
  "message": {
    "text": "openssl: Buffer overflow in X.509 certificate verification (CRITICAL)"
  },
  "locations": [{
    "physicalLocation": {
      "artifactLocation": {"uri": "usr/lib/libssl.so.3"},
      "region": {"startLine": 1}
    }
  }],
  "properties": {
    "security-severity": "9.8",    // CVSS score
    "affected": "openssl 3.0.2",
    "fixed-in": "openssl 3.0.9"    // upgrade target
  }
}
```

### Fixing a CRITICAL Vulnerability

**Scenario**: Trivy reports `CVE-2024-12345` in `openssl 3.0.2`, fixed in `3.0.9`.

```dockerfile
# Before: using an old Alpine base
FROM alpine:3.16   # openssl 3.0.2

# Fix Option 1: Update the base image (preferred)
FROM alpine:3.19   # openssl 3.0.9 included

# Fix Option 2: Explicitly upgrade the vulnerable package
FROM alpine:3.16
RUN apk update && apk upgrade openssl   # Force upgrade to latest
```

```bash
# Rebuild and scan locally to verify the fix
docker buildx build \
  --platform linux/amd64 \
  --tag payments-api:test-fix \
  --load \
  docker/payments-api/

trivy image \
  --severity CRITICAL \
  --ignore-unfixed \
  payments-api:test-fix

# If no output: no more CRITICAL CVEs
# Commit the Dockerfile change — CI will pass on next push
```

### Trivy in Local Development

```bash
# Install Trivy locally
brew install aquasecurity/trivy/trivy

# Scan a local image before pushing
trivy image \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  europe-west1-docker.pkg.dev/gke-labs/payments/payments-api:latest

# Scan a Dockerfile for misconfigurations (Dockle rules)
trivy config docker/payments-api/Dockerfile

# Scan the Helm chart for Kubernetes security misconfigurations
trivy config helm/payments-api/
```

---

## 4. Helm Upgrade with --atomic and Rollback Mechanics

### What --atomic Does

```yaml
# In cd-dev.yml:
helm upgrade --install payments-api helm/payments-api \
  --namespace payments \
  --values helm/payments-api/values-dev.yaml \
  --set image.tag=${IMAGE_TAG} \
  --atomic \
  --timeout 5m
```

`--atomic` is a compound flag that enables:
1. `--wait`: Waits for all pods in the release to reach Ready state before marking success
2. **Auto-rollback**: If `--wait` times out or any pod fails to start, Helm automatically
   rolls back to the previous successful release

```
Without --atomic:
  helm upgrade → sends new manifests to API server → returns immediately
  Broken deployment: you don't find out for minutes when someone notices errors

With --atomic:
  helm upgrade → sends manifests → waits for Deployment rollout to complete
  If pods fail to start → automatic rollback → pipeline fails → developer is notified
```

### Rollback Mechanics Under the Hood

```bash
# Helm stores release history in Kubernetes Secrets (base64-encoded gzip)
kubectl get secrets -n payments | grep helm
# sh.helm.release.v1.payments-api.v1
# sh.helm.release.v1.payments-api.v2
# sh.helm.release.v1.payments-api.v3  ← current

# View release history
helm history payments-api -n payments
# REVISION  UPDATED                  STATUS     CHART               APP VERSION  DESCRIPTION
# 1         Mon Jun 15 10:00:00 2025 superseded payments-api-1.0.0  v1.2.0       Install
# 2         Mon Jun 15 14:30:00 2025 superseded payments-api-1.0.1  v1.3.0       Upgrade
# 3         Mon Jun 15 16:45:00 2025 failed     payments-api-1.0.2  v1.4.0       Upgrade (auto-rolled back)
# 2         Mon Jun 15 16:45:10 2025 deployed   payments-api-1.0.1  v1.3.0       Rollback to 2

# Manual rollback to a specific revision
helm rollback payments-api 2 --namespace payments

# Roll back to the previous revision
helm rollback payments-api --namespace payments
```

### Debugging --atomic Failures

When `--atomic` rolls back, the pipeline fails. Here's how to investigate:

```bash
# Step 1: Check what Helm rolled back from
helm history payments-api -n payments
# Find the FAILED revision number

# Step 2: Check pod events during the failed rollout
kubectl get events -n payments --sort-by='.lastTimestamp' | tail -30
# Look for: FailedScheduling, CrashLoopBackOff, ImagePullBackOff, OOMKilled

# Step 3: Check what image was being deployed
helm get values payments-api -n payments --revision <failed-revision>
# Shows: image.tag: abc123 ← the SHA that failed

# Step 4: Check the pod logs from the failed deployment
# The pods may have been deleted during rollback, so check previous logs
kubectl logs -n payments -l app=payments-api --previous

# Step 5: Re-enable the failed version manually (if you want to debug)
helm upgrade payments-api helm/payments-api \
  --namespace payments \
  --set image.tag=<failed-sha> \
  --no-hooks    # skip pre/post hooks for debugging
  # Note: do NOT use --atomic while debugging

# Step 6: Look at the failing pod
kubectl describe pod -n payments -l app=payments-api
```

### Helm Hooks

Pre-upgrade and post-upgrade hooks run before/after the main resources:

```yaml
# database-migration-job.yaml — runs BEFORE the new deployment starts
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    "helm.sh/hook": pre-upgrade              # Run before upgrade
    "helm.sh/hook-weight": "-5"              # Run early if multiple pre-upgrade hooks
    "helm.sh/hook-delete-policy": hook-succeeded  # Clean up after success
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: europe-west1-docker.pkg.dev/gke-labs/payments/payments-api:{{ .Values.image.tag }}
          command: ["python", "manage.py", "migrate", "--no-input"]
      restartPolicy: Never
  backoffLimit: 3
```

With `--atomic`, if the migration job fails, the entire upgrade rolls back — protecting you
from deploying new code against an unmigrated database schema.

---

## 5. Smoke Tests in CI — What to Test After Deploy

Smoke tests run in the `cd-dev.yml` workflow immediately after `helm upgrade` completes.
They verify the deployment is functional before the pipeline reports success.

### What Makes a Good Smoke Test

```
A smoke test should:
  ✅ Complete in < 30 seconds
  ✅ Test the most critical user path (not edge cases)
  ✅ Catch the most common failure modes (app won't start, misconfigured env vars)
  ✅ Use the same authentication as real traffic (not bypass auth)

A smoke test should NOT:
  ❌ Test every feature (that's integration/E2E tests)
  ❌ Write to production databases
  ❌ Depend on external services (makes the test flaky)
  ❌ Take longer than the deployment itself
```

### The Smoke Test Pattern Used in cd-dev.yml

```bash
# From cd-dev.yml (simplified):

# Step 1: Wait for the rollout to complete (--atomic handles this, but be explicit)
kubectl rollout status deployment/payments-api \
  --namespace=payments \
  --timeout=5m

# Step 2: Port-forward to the service (avoids needing public ingress)
kubectl port-forward svc/payments-api 8080:80 \
  --namespace=payments &
PF_PID=$!
sleep 3   # Give port-forward time to establish

# Step 3: Health check
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
if [ "$HTTP_CODE" != "200" ]; then
  echo "Health check failed: HTTP $HTTP_CODE"
  kill $PF_PID
  exit 1
fi
echo "Health check passed: HTTP $HTTP_CODE ✅"

# Step 4: Readiness check — verify all replicas are ready
READY=$(kubectl get deployment payments-api -n payments \
  -o jsonpath='{.status.readyReplicas}')
DESIRED=$(kubectl get deployment payments-api -n payments \
  -o jsonpath='{.spec.replicas}')
if [ "$READY" != "$DESIRED" ]; then
  echo "Not all replicas ready: $READY/$DESIRED"
  exit 1
fi
echo "All replicas ready: $READY/$DESIRED ✅"

# Step 5: Critical API path test
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST http://localhost:8080/api/payments/validate \
  -H "Content-Type: application/json" \
  -d '{"amount": 0.01, "currency": "EUR"}')
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)

if [ "$HTTP_CODE" != "200" ]; then
  echo "API test failed: HTTP $HTTP_CODE, body: $BODY"
  kill $PF_PID
  exit 1
fi
echo "API test passed ✅"

kill $PF_PID
```

### Additional Smoke Test Ideas

```bash
# Verify the database migration ran (if applicable)
kubectl run db-check \
  --image=europe-west1-docker.pkg.dev/gke-labs/payments/payments-api:${IMAGE_TAG} \
  --restart=Never \
  --namespace=payments \
  --rm -it \
  -- python manage.py showmigrations | grep "\[ \]"
# Exit code 0 = all migrations applied; non-zero = unapplied migrations remain

# Check that no pods are in CrashLoopBackOff
kubectl get pods -n payments | grep -c CrashLoopBackOff
# Expected: 0

# Verify the observability stack can see the new deployment
curl -s "http://prometheus.monitoring.svc.cluster.local:9090/api/v1/targets" | \
  jq '.data.activeTargets[] | select(.labels.namespace == "payments") | .health'
# Expected: "up" for all targets
```

---

## 6. Progressive Delivery — Canary vs Blue/Green vs Rolling

All three strategies route traffic gradually to a new version, but they have very different
operational characteristics.

### Rolling Update (Kubernetes Default)

```
Strategy: Replace old pods with new pods one at a time.

Before:   [v1.3] [v1.3] [v1.3] [v1.3]   4 replicas all serving v1.3

Rolling:  [v1.3] [v1.3] [v1.3] [v1.4]   25% on v1.4
          [v1.3] [v1.3] [v1.4] [v1.4]   50% on v1.4
          [v1.3] [v1.4] [v1.4] [v1.4]   75% on v1.4
          [v1.4] [v1.4] [v1.4] [v1.4]   100% on v1.4

Config in Deployment:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1           # Create 1 extra pod before removing old ones
      maxUnavailable: 0     # Never have less than desired replicas serving

Pros:  Simple, built-in, no extra infrastructure
Cons:  Both versions serve traffic simultaneously (API contract must be backward-compatible)
       No traffic control by user percentage
       Hard to roll back immediately (must re-deploy old version)
```

### Blue/Green Deployment

```
Strategy: Run two identical environments (blue=current, green=new).
          Switch traffic instantly by updating the Service selector.

Blue (current):   payments-api-blue  [v1.3] [v1.3] [v1.3]  ← Service selector: version=blue
Green (new):      payments-api-green [v1.4] [v1.4] [v1.4]  ← Receives no traffic yet

Cutover: kubectl patch service payments-api -p '{"spec":{"selector":{"version":"green"}}}'

Traffic instantly moves to green.
If problems detected: patch service back to blue — immediate rollback.

Pros:  Zero-downtime cutover
       Instant rollback (just flip the service selector)
       Green environment can be pre-warmed (JVM JIT compilation, caches loaded)

Cons:  Requires 2× the pod capacity during the cutover window
       All-or-nothing: no gradual traffic shift
       Stateful requests in flight at cutover time may fail
```

```yaml
# Helm values for blue/green:
# helm/payments-api/values.yaml
deployment:
  activeSlot: blue   # Switch to "green" for new deployment

# The Helm chart creates two Deployments and one Service
# Service selector: { version: {{ .Values.deployment.activeSlot }} }
```

### Canary Deployment

```
Strategy: Send a small % of traffic to the new version.
          Gradually increase if metrics are healthy. Roll back instantly if not.

100% on v1.3:  [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3]

Canary 10%:    [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.4]
               ◄────────────────── 90% ─────────────────────────────────────────► ◄10%►

Canary 50%:    [v1.3] [v1.3] [v1.3] [v1.3] [v1.3] [v1.4] [v1.4] [v1.4] [v1.4] [v1.4]

Full 100%:     [v1.4] × 10

Pros:  Low blast radius — only X% of users affected if new version is broken
       Real production traffic validation before full rollout
       Automatic rollback based on error rate (Flagger)

Cons:  More complex infrastructure (needs traffic splitting: Istio/Gateway API/NGINX)
       Both versions must be schema-compatible
       Canary analysis takes time (minutes to hours)
```

### Implementing Canary with Flagger on GKE

```bash
# Install Flagger (integrates with NGINX Ingress or Istio)
helm upgrade --install flagger flagger/flagger \
  --namespace ingress-nginx \
  --set meshProvider=nginx \
  --set metricsServer=http://prometheus.monitoring:9090

# Create a Canary object
cat <<EOF | kubectl apply -f -
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: payments-api
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  progressDeadlineSeconds: 120
  service:
    port: 8080
  analysis:
    interval: 1m          # Evaluate metrics every minute
    threshold: 5          # Max 5 failed checks before rollback
    maxWeight: 50         # Max 50% traffic to canary
    stepWeight: 10        # Increase traffic by 10% each step
    metrics:
      - name: request-success-rate
        threshold: 99     # Rollback if error rate > 1%
        interval: 1m
      - name: request-duration
        threshold: 500    # Rollback if p99 latency > 500ms
        interval: 1m
EOF
```

### Decision Guide

| Scenario | Use | Why |
|----------|-----|-----|
| Regular feature release, stateless API | **Rolling** | Simple, zero infrastructure overhead |
| Database schema change | **Blue/Green** | Need instant rollback before schema is irreversible |
| High-traffic service, low error budget | **Canary** | Validate with real traffic before full exposure |
| Hotfix under time pressure | **Rolling** (maxSurge=1, maxUnavailable=0) | Fastest path to production |
| Services with long-lived connections (WebSockets) | **Blue/Green** | Rolling disrupts existing connections |
| Feature flag controlled release | **Rolling** + feature flags | Separate deploy from release |

---

## 7. Break-It & Fix-It Exercises

### Exercise 1: Force a Trivy Failure

**What we're testing:** Understand how to identify and fix a blocking CVE.

```bash
# === BREAK IT ===
# Build an image using a known-vulnerable base image
cat <<'EOF' > /tmp/Dockerfile-vulnerable
FROM alpine:3.14    # Has multiple CRITICAL CVEs
RUN apk add --no-cache curl
CMD ["curl", "--version"]
EOF

docker buildx build \
  --platform linux/amd64 \
  --tag vulnerable-test:latest \
  --load \
  --file /tmp/Dockerfile-vulnerable \
  /tmp/

# === OBSERVE ===
trivy image \
  --severity CRITICAL \
  --ignore-unfixed \
  vulnerable-test:latest

# You should see output like:
# vulnerable-test:latest (alpine 3.14.6)
# CRITICAL: 8
# ┌───────────────────┬────────────────┬──────────┬──────────────┬────────────────────────────────┐
# │ Library           │ Vulnerability  │ Severity │ Installed    │ Fixed In                       │
# ├───────────────────┼────────────────┼──────────┼──────────────┼────────────────────────────────┤
# │ openssl           │ CVE-2023-xxxx  │ CRITICAL │ 1.1.1t-r0    │ 1.1.1u-r0                      │
# │ libcrypto1.1      │ CVE-2023-xxxx  │ CRITICAL │ 1.1.1t-r0    │ 1.1.1u-r0                      │

# === FIX IT ===
cat <<'EOF' > /tmp/Dockerfile-fixed
FROM alpine:3.19    # Current LTS with patched packages
RUN apk add --no-cache curl
CMD ["curl", "--version"]
EOF

docker buildx build \
  --platform linux/amd64 \
  --tag fixed-test:latest \
  --load \
  --file /tmp/Dockerfile-fixed \
  /tmp/

# Verify no more CRITICAL CVEs
trivy image \
  --severity CRITICAL \
  --ignore-unfixed \
  fixed-test:latest
# No output = zero CRITICAL vulnerabilities ✅
```

---

### Exercise 2: --atomic Rollback in Action

**What we're testing:** Watch Helm --atomic catch a bad deployment and roll back automatically.

```bash
# === SETUP ===
# Ensure the current payments-api is deployed and healthy
helm status payments-api -n payments

# === BREAK IT ===
# Deploy with a non-existent image tag (simulates a bad build)
helm upgrade payments-api helm/payments-api \
  --namespace payments \
  --values helm/payments-api/values-dev.yaml \
  --set image.tag=doesnotexist-abc999 \
  --atomic \
  --timeout 3m

# === OBSERVE ===
# In a separate terminal, watch the pods:
# kubectl get pods -n payments -w
#
# You'll see:
# payments-api-new-xxxxx   0/1   ImagePullBackOff   0   30s
# payments-api-new-xxxxx   0/1   ImagePullBackOff   0   60s
# (after timeout, Helm rolls back)
# payments-api-new-xxxxx   0/1   Terminating        0   3m
# payments-api-old-xxxxx   1/1   Running            0   3m10s

# After --atomic rolls back, check Helm history
helm history payments-api -n payments
# The failed release shows status: "failed", followed by a rollback entry

# Verify the old version is still running
kubectl get deployment payments-api -n payments \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Shows the previous good image tag ✅

# === FIX IT ===
# Deploy the correct tag
helm upgrade payments-api helm/payments-api \
  --namespace payments \
  --values helm/payments-api/values-dev.yaml \
  --set image.tag=$(git rev-parse HEAD) \
  --atomic \
  --timeout 5m
```

---

### Exercise 3: Rolling Update with Zero Downtime

```bash
# === SETUP ===
# Start a continuous traffic generator against payments-api
kubectl port-forward svc/payments-api 8080:80 -n payments &
PF_PID=$!

# Run requests in background, count errors
error_count=0
request_count=0
while true; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 2 http://localhost:8080/health)
  request_count=$((request_count + 1))
  if [ "$HTTP_CODE" != "200" ]; then
    error_count=$((error_count + 1))
    echo "ERROR: HTTP $HTTP_CODE (request $request_count)"
  fi
  sleep 0.1
done &
LOAD_PID=$!

# === BREAK IT (accidentally) ===
# Deploy with maxUnavailable=1, maxSurge=0 — causes brief downtime
kubectl patch deployment payments-api -n payments --type=merge -p='{
  "spec": {
    "strategy": {
      "rollingUpdate": {
        "maxSurge": 0,
        "maxUnavailable": 1
      }
    }
  }
}'

# Trigger a new rollout
kubectl set env deployment/payments-api -n payments \
  TRIGGER_REDEPLOY=$(date +%s)

# Watch the load test — some requests will fail during the period when
# one pod is terminated and the replacement isn't ready yet

# === FIX IT ===
# Set maxUnavailable=0, maxSurge=1 for true zero-downtime
kubectl patch deployment payments-api -n payments --type=merge -p='{
  "spec": {
    "strategy": {
      "rollingUpdate": {
        "maxSurge": 1,
        "maxUnavailable": 0
      }
    }
  }
}'

# Trigger another rollout
kubectl set env deployment/payments-api -n payments \
  TRIGGER_REDEPLOY=$(date +%s)2

# The load test should now show zero errors during the rollout

# Cleanup
kill $LOAD_PID $PF_PID 2>/dev/null
echo "Total requests: $request_count, Errors: $error_count"
```

---

## 8. Interview Q&A

---

### Q1: Walk me through what happens when a pull request is merged to `main` in this repository.

**Answer:**

1. **CI workflow triggers** (`ci.yml`): `lint-terraform`, `lint-helm`, and `docker-build` run in
   parallel. `docker-build` builds the image and scans it with Trivy. If any job fails, the
   CD workflow does not start.

2. **CD Dev workflow triggers** (`cd-dev.yml`): On successful push to `main`. Authenticates
   to GCP using Workload Identity Federation (no keys stored). Fetches GKE credentials via
   `gcloud container clusters get-credentials`.

3. **Helm upgrade runs** with `--atomic --timeout 5m`: Applies the Helm chart with the new
   image tag (`$GITHUB_SHA`). Waits for all pods to become Ready.

4. **If deployment succeeds**: Smoke test runs — curl /health endpoint, check replica count.

5. **If deployment or smoke test fails**: `--atomic` triggers automatic rollback to the
   previous Helm release. CI pipeline shows failure. Developer is notified.

6. **If everything passes**: The commit SHA is now deployed to `gke-labs-dev` in the
   `payments` namespace. The staging deploy requires a separate manual `workflow_dispatch`.

---

### Q2: What is the difference between `--atomic` and `--wait` in Helm?

**Answer:**

`--wait` makes Helm wait until all resources (Deployments, StatefulSets, Jobs) have reached
their ready state before returning. If they don't become ready within `--timeout`, the command
exits with a non-zero code — but the partially-deployed resources remain in the cluster.

`--atomic` is `--wait` plus **automatic rollback**: if the wait times out or a resource fails,
Helm automatically rolls back to the previous successful release. After rollback, the command
exits non-zero.

**In production:**
- Use `--atomic` in CI/CD pipelines — failure is always rolled back, cluster is never left
  in a partially-upgraded state
- Avoid `--atomic` when debugging a failing deployment manually — it undoes your changes
  before you can inspect the pods. Instead, use `--wait` and inspect the failing pods before
  they're cleaned up

---

### Q3: A GitHub Actions workflow authenticates to GCP. What are the two approaches and which is preferred?

**Answer:**

**Approach 1 — Service Account JSON key (legacy, avoid):**
```yaml
# Stored as a GitHub secret
- uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.GCP_SA_KEY }}
```
Problems: the JSON key is valid indefinitely, stored in GitHub's secret store, can be
exfiltrated if the runner is compromised, requires manual rotation.

**Approach 2 — Workload Identity Federation (preferred, keyless):**
```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    service_account:            ${{ secrets.GCP_SERVICE_ACCOUNT }}
```
GitHub Actions provides an OIDC token (JWT) signed by GitHub. The Workload Identity Provider
in GCP validates the JWT signature and exchanges it for a **short-lived GCP access token**
(1-hour TTL). No long-lived credentials are stored anywhere.

The secrets stored in GitHub (`GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`) are
not credentials — they're resource identifiers. Even if leaked, they're useless without a
valid GitHub OIDC token from an authorized repository and branch.

---

### Q4: When would you choose canary deployment over rolling update for the payments API?

**Answer:**

I would use canary deployment when:

1. **Significant API behavior change**: The new version changes how payment processing works
   (e.g., new validation logic, different rounding behavior). A rolling update exposes 100%
   of users within minutes. A canary lets you validate behavior with 5–10% of real traffic.

2. **Low error budget**: If the payments SLA is 99.99% (52 minutes downtime/year), even a
   10-minute incident from a bad rolling deploy is significant. Canary limits blast radius.

3. **You have metrics-based auto-analysis**: Flagger or Argo Rollouts can automatically
   roll back based on error rate or latency. This makes canary practical without manual
   monitoring.

**When rolling update is fine:**
- Internal services (no direct user impact)
- Pure bug fixes with no behavior change
- Configuration changes (environment variables)
- Under time pressure for a hotfix

The key trade-off: canary requires traffic splitting infrastructure (Istio, NGINX annotations,
Gateway API) and increases operational complexity. For most routine deployments, rolling update
with `maxUnavailable: 0, maxSurge: 1` provides zero-downtime without the overhead.

---

*Next: [Lab 11 — Observability Stack](../11-observability-setup/README.md)*
