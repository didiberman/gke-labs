# Lab 06 — Helm in Production: Deployments, Upgrades, and Rollbacks

> **Difficulty:** Intermediate | **Time:** ~90 minutes | **Cluster:** `gke-labs` / `europe-west1`

---

## Table of Contents

1. [Concept: Why Helm?](#1-concept-why-helm)
2. [Chart Structure Walkthrough](#2-chart-structure-walkthrough)
3. [helm install vs upgrade --install](#3-helm-install-vs-upgrade---install)
4. [Values Hierarchy](#4-values-hierarchy)
5. [Release History](#5-release-history)
6. [Rolling Upgrade — Changing Image Tags](#6-rolling-upgrade--changing-image-tags)
7. [Rollback](#7-rollback)
8. [Helm Diff Plugin](#8-helm-diff-plugin)
9. [Helm Secrets](#9-helm-secrets)
10. [Break-it-and-Fix-it Exercise](#10-break-it-and-fix-it-exercise)
11. [Interview Q&A](#11-interview-qa)

---

## 1. Concept: Why Helm?

Helm is the **package manager for Kubernetes**. Without it, you manage dozens of raw YAML files,
copy-paste values between environments, and have no concept of release history or rollback.

```
WITHOUT HELM                          WITH HELM
──────────────────────────────        ─────────────────────────────────────
deployment.yaml (prod)                helm upgrade --install payments-api \
deployment.yaml (staging)               ./charts/payments-api \
service.yaml                            -f values.yaml \
configmap.yaml                          -f values-prod.yaml \
hpa.yaml                                --set image.tag=v2.3.1 \
ingress.yaml                            -n payments
...copy-paste manually...
                                      → versioned, repeatable, rollback-able
```

Helm solves three problems:

1. **Templating** — One chart, many environments, no copy-paste
2. **Release tracking** — Every install/upgrade is a versioned release stored as a K8s Secret
3. **Lifecycle management** — `install`, `upgrade`, `rollback`, `uninstall` as first-class operations

---

## 2. Chart Structure Walkthrough

Our `payments-api` Helm chart lives at `charts/payments-api/`. Every file has a purpose:

```
charts/payments-api/
├── Chart.yaml              ← Chart metadata (name, version, appVersion)
├── values.yaml             ← Default values (safe to commit, no secrets)
├── values-staging.yaml     ← Staging-specific overrides
├── values-prod.yaml        ← Production-specific overrides
├── .helmignore             ← Files excluded from `helm package`
└── templates/
    ├── _helpers.tpl        ← Named templates / reusable helper functions
    ├── deployment.yaml     ← Core Deployment resource
    ├── service.yaml        ← ClusterIP / LoadBalancer Service
    ├── ingress.yaml        ← Ingress resource (nginx)
    ├── hpa.yaml            ← HorizontalPodAutoscaler
    ├── serviceaccount.yaml ← Kubernetes Service Account (linked to GCP SA via WIF)
    ├── configmap.yaml      ← Non-secret application config
    ├── networkpolicy.yaml  ← NetworkPolicy (see Lab 09)
    ├── pdb.yaml            ← PodDisruptionBudget
    └── NOTES.txt           ← Printed to stdout after helm install/upgrade
```

### Chart.yaml — The Manifest

```yaml
# charts/payments-api/Chart.yaml
apiVersion: v2
name: payments-api
description: Payments API microservice for GKE Labs
type: application

# Chart version — bump when chart STRUCTURE or templates change
version: 1.4.0

# App version — default Docker image tag (overridden at deploy time)
appVersion: "v2.3.1"

maintainers:
  - name: Platform Team
    email: platform@company.com

dependencies: []
```

> **Key distinction — `version` vs `appVersion`:**
> `version` is the chart's own semver; bump it when you change templates or add new values.
> `appVersion` is just a default label — the actual running image tag is passed via `--set image.tag=`.
> They are **independent**. A chart bug fix increments `version` without touching `appVersion`.

### _helpers.tpl — Shared Template Functions

```yaml
{{/*
Expand chart name, honouring nameOverride.
Usage: {{ include "payments-api.name" . }}
*/}}
{{- define "payments-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name — Release.Name + chart name, max 63 chars.
*/}}
{{- define "payments-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Standard labels applied to every Kubernetes resource.
*/}}
{{- define "payments-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ include "payments-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

### templates/deployment.yaml — Annotated

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "payments-api.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "payments-api.labels" . | nindent 4 }}
  annotations:
    # PRODUCTION PATTERN: Force a pod rollout whenever the ConfigMap changes.
    # Without this, Helm updates the ConfigMap but running pods keep stale env vars.
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
spec:
  replicas: {{ .Values.replicaCount }}   # Overridden by HPA in production
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "payments-api.name" . }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # maxSurge: allows +1 pod above desired during rollout
      # maxUnavailable: 0 means zero pods go down until a new pod is Ready
      maxSurge: {{ .Values.rollingUpdate.maxSurge | default 1 }}
      maxUnavailable: {{ .Values.rollingUpdate.maxUnavailable | default 0 }}
  template:
    metadata:
      labels:
        {{- include "payments-api.labels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "payments-api.fullname" . }}
      # Spread pods across nodes for HA
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ include "payments-api.name" . }}
      containers:
        - name: payments-api
          # image.tag defaults to Chart.AppVersion if not specified at deploy time
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
```

---

## 3. `helm install` vs `upgrade --install`

```bash
# ─────────────────────────────────────────────────────────────
# helm install — creates a NEW release. Fails if already exists.
# ─────────────────────────────────────────────────────────────
helm install payments-api ./charts/payments-api \
  --namespace payments \
  --create-namespace \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v2.3.1

# ─────────────────────────────────────────────────────────────
# helm upgrade — upgrades an existing release. Fails if not found.
# ─────────────────────────────────────────────────────────────
helm upgrade payments-api ./charts/payments-api \
  --namespace payments \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v2.3.2

# ─────────────────────────────────────────────────────────────
# helm upgrade --install — idempotent. Use this in CI/CD.
# Installs if release does not exist, upgrades if it does.
# ─────────────────────────────────────────────────────────────
helm upgrade --install payments-api ./charts/payments-api \
  --namespace payments \
  --create-namespace \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v2.3.2 \
  --atomic \     # Auto-rollback if upgrade fails (pods don't become Ready in time)
  --timeout 5m \ # Give pods 5 minutes to become Ready before declaring failure
  --wait         # Block until all pods are Ready before returning exit 0
```

> **`--atomic` is your production safety net.** If the new revision's pods fail readiness within
> the timeout, Helm automatically rolls back to the last successful revision and exits non-zero —
> failing your pipeline visibly. Always use `--atomic` in automated pipelines.

---

## 4. Values Hierarchy

Helm merges values from multiple sources. **Later sources always win:**

```
┌─────────────────────────────────────────────────────────────────┐
│           VALUES PRECEDENCE  (lowest → highest)                 │
│                                                                 │
│  1. Chart defaults       charts/payments-api/values.yaml        │
│  2. Extra -f files       -f values-staging.yaml                 │
│  3. Last -f file         -f values-prod.yaml          ▲         │
│  4. --set flags          --set image.tag=v2.3.2        │ wins   │
│  5. --set-string         (forces string type)          │        │
│  6. --set-file           (reads value from file)       │        │
└─────────────────────────────────────────────────────────────────┘

Rule: --set always beats -f files. The last -f file beats earlier -f files.
```

### values.yaml — Defaults (committed to git, no secrets)

```yaml
# charts/payments-api/values.yaml
replicaCount: 2

image:
  repository: europe-west1-docker.pkg.dev/gke-labs/payments/payments-api
  tag: ""           # Empty string = use .Chart.AppVersion
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

rollingUpdate:
  maxSurge: 1
  maxUnavailable: 0

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

ingress:
  enabled: false
  hostname: ""
  tls: false

podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

### values-prod.yaml — Production overrides

```yaml
# charts/payments-api/values-prod.yaml
# Only override what differs from the defaults above.

replicaCount: 3   # Higher baseline for production traffic

resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 65   # Scale earlier under prod load

ingress:
  enabled: true
  hostname: api.payments.example.com
  tls: true
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rate-limit: "100"

podDisruptionBudget:
  enabled: true
  minAvailable: 2   # Keep at least 2 pods during node maintenance
```

### Inspecting computed values

```bash
# Render templates locally — no cluster connection needed
helm template payments-api ./charts/payments-api \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v2.3.1 \
  --namespace payments \
  | grep -A 5 "image:"

# Inspect what values a LIVE release is using (user-supplied only)
helm get values payments-api -n payments

# Inspect ALL computed values including chart defaults
helm get values payments-api -n payments --all

# Show the full rendered manifests of the live release
helm get manifest payments-api -n payments
```

---

## 5. Release History

Every `helm install` or `helm upgrade` creates a numbered **revision** stored as a Kubernetes Secret
in the release namespace. This is Helm's "source of truth" for history and rollback.

```bash
# List all revisions for a release
helm history payments-api -n payments

# Example output:
# REVISION  UPDATED                    STATUS      CHART                APP VERSION  DESCRIPTION
# 1         2024-01-15 09:00:00 +0000  superseded  payments-api-1.3.0   v2.2.0       Install complete
# 2         2024-01-20 14:30:00 +0000  superseded  payments-api-1.4.0   v2.3.0       Upgrade complete
# 3         2024-01-22 11:15:00 +0000  deployed    payments-api-1.4.0   v2.3.1       Upgrade complete

# Inspect the manifests of a specific revision (useful for auditing)
helm get manifest payments-api -n payments --revision 2

# See the release notes for a revision
helm get notes payments-api -n payments

# List all Helm-managed releases in a namespace
helm list -n payments

# List across ALL namespaces in the cluster
helm list --all-namespaces

# The Secrets backing the history (each Secret = one revision)
kubectl get secrets -n payments -l owner=helm --sort-by='.metadata.creationTimestamp'
```

---

## 6. Rolling Upgrade — Changing Image Tags

The most common production operation: deploying a new application version.

```bash
# ─── Terminal 1: Watch pods in real time ───
kubectl get pods -n payments -w

# ─── Terminal 2: Trigger the upgrade ───
helm upgrade payments-api ./charts/payments-api \
  -n payments \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v2.3.2 \
  --wait \
  --timeout 5m
```

### What you will observe in Terminal 1

```
NAME                             READY   STATUS              RESTARTS
payments-api-7d9b4c-abc11        1/1     Running             0   ← v2.3.1
payments-api-7d9b4c-abc22        1/1     Running             0   ← v2.3.1
payments-api-7d9b4c-abc33        1/1     Running             0   ← v2.3.1

payments-api-8f2a1d-new11        0/1     Pending             0   ← v2.3.2 surge pod
payments-api-8f2a1d-new11        0/1     ContainerCreating   0
payments-api-8f2a1d-new11        0/1     Running             0
payments-api-8f2a1d-new11        1/1     Running             0   ← passed readiness!
payments-api-7d9b4c-abc11        1/1     Terminating         0   ← NOW we remove old pod

payments-api-8f2a1d-new22        0/1     Pending             0   ← next surge pod
... (repeats)
```

### Timeline diagram — maxUnavailable: 0, maxSurge: 1, 3 replicas

```
t=0s   [v1][v1][v1]                        (3 running, desired=3)
t=10s  [v1][v1][v1][v2...]                 (surge: 4 pods, v2 starting)
t=25s  [v1][v1][v1][v2✓]                  (new pod passed readiness probe)
t=26s  [v1][v1]    [v2✓]                  (old pod terminated — never < 3)
t=36s  [v1][v1][v2...][v2✓]              (next surge)
t=50s  [v1]    [v2✓][v2✓]               (another old pod gone)
t=80s  [v2✓][v2✓][v2✓]                  (rollout complete)
```

---

## 7. Rollback

```bash
# Rollback to the immediately previous revision (N-1)
helm rollback payments-api -n payments

# Rollback to a specific revision number
helm rollback payments-api 1 -n payments

# Wait until rollback is complete before returning
helm rollback payments-api 1 -n payments --wait --timeout 3m

# ─── After rollback ─────────────────────────────────────────
helm history payments-api -n payments
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         failed      Upgrade failed (bad image)
# 4         deployed    Rollback to 1          ← NEW revision, identical to #1

# Confirm the running image is back to the old version
kubectl get pods -n payments -o custom-columns=\
'NAME:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase'
```

> **Critical insight:** `helm rollback` creates a **new revision** (revision 4 above).
> It does NOT rewind the revision counter. Revision 4 has the same manifests as revision 1,
> but the history is preserved in full. This gives you a complete audit trail —
> essential for compliance in financial systems.

---

## 8. Helm Diff Plugin

`helm-diff` shows you exactly what YAML will change before you run `helm upgrade` —
like `terraform plan` for Helm. Make this a mandatory step in code review.

### Installation

```bash
helm plugin install https://github.com/databus23/helm-diff

# Verify
helm plugin list
```

### Usage

```bash
# Preview what would change if we upgrade to v2.3.2
helm diff upgrade payments-api ./charts/payments-api \
  -n payments \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v2.3.2

# Example output (colourised in your terminal):
# payments/Deployment/payments-api
#   spec:
#     template:
#       spec:
#         containers:
# -         - image: .../payments-api:v2.3.1
# +         - image: .../payments-api:v2.3.2

# Preview what a rollback to revision 1 would do
helm diff rollback payments-api 1 -n payments

# Compare two specific historical revisions
helm diff revision payments-api 2 3 -n payments

# Suppress unchanged context (only show changed blocks)
helm diff upgrade payments-api ./charts/payments-api \
  -n payments \
  -f charts/payments-api/values.yaml \
  --set image.tag=v2.3.2 \
  --context 5         # lines of context around each change
```

### Integrate into GitHub Actions (PR comment)

```yaml
# .github/workflows/helm-diff.yaml
name: Helm Diff on PR
on:
  pull_request:
    paths:
      - 'charts/**'
      - '.github/workflows/deploy.yaml'

jobs:
  diff:
    runs-on: ubuntu-latest
    permissions:
      id-token: write    # Workload Identity Federation
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github
          service_account: github-actions@gke-labs.iam.gserviceaccount.com

      - name: Get GKE credentials
        uses: google-github-actions/get-gke-credentials@v2
        with:
          cluster_name: gke-labs-cluster
          location: europe-west1

      - name: Install helm-diff
        run: helm plugin install https://github.com/databus23/helm-diff

      - name: Run helm diff
        id: diff
        run: |
          DIFF=$(helm diff upgrade payments-api ./charts/payments-api \
            -n payments \
            -f charts/payments-api/values.yaml \
            -f charts/payments-api/values-prod.yaml \
            --set image.tag=${{ github.sha }} \
            --no-hooks 2>&1 || true)
          echo "DIFF<<EOF" >> $GITHUB_OUTPUT
          echo "$DIFF" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT

      - name: Post diff as PR comment
        uses: actions/github-script@v7
        with:
          script: |
            const diff = `${{ steps.diff.outputs.DIFF }}`;
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `## Helm Diff — payments-api\n\`\`\`diff\n${diff}\n\`\`\``
            });
```

---

## 9. Helm Secrets (SOPS + GCP KMS)

Never store plaintext secrets in any values file. Use `helm-secrets` with Mozilla SOPS
backed by GCP Cloud KMS.

### One-time Setup

```bash
# 1. Install the helm-secrets plugin
helm plugin install https://github.com/jkroepke/helm-secrets

# 2. Install SOPS
brew install sops

# 3. Create a GCP KMS key for Helm secret encryption
gcloud kms keyrings create helm-secrets \
  --location=europe-west1 \
  --project=gke-labs

gcloud kms keys create payments-key \
  --keyring=helm-secrets \
  --location=europe-west1 \
  --purpose=encryption \
  --project=gke-labs

# 4. Grant yourself (and the CI service account) encrypt/decrypt permissions
gcloud kms keys add-iam-policy-binding payments-key \
  --keyring=helm-secrets \
  --location=europe-west1 \
  --member="user:$(gcloud config get-value account)" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project=gke-labs

# 5. Create .sops.yaml at the repo root — tells SOPS which key to use for which file
cat > .sops.yaml << 'EOF'
creation_rules:
  # Any file named secrets.yaml anywhere in the repo uses GCP KMS
  - path_regex: secrets\.yaml$
    gcp_kms: projects/gke-labs/locations/europe-west1/keyRings/helm-secrets/cryptoKeys/payments-key
EOF
```

### Creating and Using Encrypted Secrets

```bash
# Write your plaintext secrets — do NOT commit this file
cat > /tmp/secrets-plaintext.yaml << 'EOF'
database:
  password: "super-secret-db-password"
stripe:
  apiKey: "sk_live_xxxxxxxxxxxxxxxxx"
jwt:
  signingKey: "my-jwt-signing-key-min-32-chars"
EOF

# Encrypt with SOPS (uses the .sops.yaml config automatically)
sops --encrypt /tmp/secrets-plaintext.yaml > charts/payments-api/secrets.yaml
# Now secrets.yaml is ciphertext — SAFE to commit to git

# Verify it's encrypted
cat charts/payments-api/secrets.yaml
# database:
#     password: ENC[AES256_GCM,data:abc123...,iv:...,tag:...,type:str]
#     ...

# Decrypt and view (does NOT write plaintext to disk)
sops --decrypt charts/payments-api/secrets.yaml

# Edit secrets in place (decrypts, opens $EDITOR, re-encrypts on save)
sops charts/payments-api/secrets.yaml

# Deploy — helm-secrets decrypts in memory, never touches disk
helm secrets upgrade --install payments-api ./charts/payments-api \
  -n payments \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  -f charts/payments-api/secrets.yaml \
  --set image.tag=v2.3.1
```

> **Why not Kubernetes Secrets directly?**
> Kubernetes Secrets are base64 encoded, not encrypted — anyone with `kubectl get secret`
> access can read them. SOPS-encrypted values in git are encrypted with AES-256-GCM and
> only decryptable by holders of the KMS key. Combine with GCP KMS IAM for audit trails
> of every decryption operation.

---

## 10. Break-it-and-Fix-it Exercise

### The Break — Deploy a non-existent image tag

```bash
# Upgrade with a tag that does not exist in Artifact Registry
helm upgrade payments-api ./charts/payments-api \
  -n payments \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v9.9.9-does-not-exist
  # Note: NOT using --atomic so we can observe the stuck state
```

### Observe the failure

```bash
# Watch pods — old pods stay Running, new pods fail to pull the image
kubectl get pods -n payments -w

# Expected output:
# NAME                             READY   STATUS             RESTARTS
# payments-api-7d9b4c-abc11        1/1     Running            0   ← old, still alive
# payments-api-7d9b4c-abc22        1/1     Running            0   ← old, still alive
# payments-api-8f2a1d-bad11        0/1     ErrImagePull       0   ← new, stuck
# payments-api-8f2a1d-bad11        0/1     ImagePullBackOff   0

# Describe the failing pod to see the exact error
kubectl describe pod -n payments -l app.kubernetes.io/instance=payments-api \
  | grep -A 15 "^Events:"
# Events:
#   Warning  Failed  5s   kubelet  Failed to pull image "...v9.9.9-does-not-exist": ...
#   Warning  Failed  5s   kubelet  Error: ErrImagePull
#   Warning  BackOff 2s   kubelet  Back-off pulling image "...v9.9.9-does-not-exist"

# Check release status — it's stuck in "pending-upgrade"
helm status payments-api -n payments

# Check history
helm history payments-api -n payments
# REVISION  STATUS           DESCRIPTION
# 1         superseded       Install complete
# 2         superseded       Upgrade complete
# 3         pending-upgrade  Preparing upgrade   ← STUCK
```

### Diagnose

```bash
# Why is the release stuck in pending-upgrade?
# Because without --atomic, Helm doesn't monitor pod readiness after the API call succeeds.
# The Kubernetes API accepted the Deployment update (valid YAML), but the pods are failing.
# Helm considers its job done at the API level.

# This is WHY you must always use --wait or --atomic in production.
```

### Fix — Option A: Deploy a known-good image tag

```bash
helm upgrade payments-api ./charts/payments-api \
  -n payments \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v2.3.1 \
  --wait \
  --timeout 5m

kubectl get pods -n payments
# All pods should be Running/Ready again
```

### Fix — Option B: Rollback to last known-good revision

```bash
# Find the last DEPLOYED revision
helm history payments-api -n payments | grep "deployed\|superseded" | tail -1

# Roll back to it (substitute N with the revision number)
helm rollback payments-api N -n payments --wait

# Verify
helm status payments-api -n payments
kubectl get pods -n payments
```

### Prevention — Always use --atomic in CI/CD

```bash
# With --atomic, Helm handles this automatically:
helm upgrade --install payments-api ./charts/payments-api \
  -n payments \
  -f charts/payments-api/values.yaml \
  -f charts/payments-api/values-prod.yaml \
  --set image.tag=v9.9.9-does-not-exist \
  --atomic \      # ← this is the key: if upgrade fails, auto-rollback + exit 1
  --timeout 3m

# Output:
# UPGRADE FAILED: release: not ready
# Helm is rolling back to revision 2...
# Rollback was a success! Happy Helming!
# Error: UPGRADE FAILED: release: not ready
# (exits 1 — pipeline fails visibly)
```

---

## 11. Interview Q&A

### Q: "What's your strategy for managing Helm values across multiple environments?"

**Strong answer:**

> We use a layered values approach. A base `values.yaml` lives in the chart with safe,
> production-like defaults — replica counts, resource requests, image pull policy,
> all structural config. Then environment-specific override files (`values-staging.yaml`,
> `values-prod.yaml`) contain only the deltas. These are layered with `-f` flags,
> environment file last so it wins. Sensitive values live in a separate `secrets.yaml`
> encrypted with SOPS and GCP KMS, deployed via helm-secrets — decrypted in memory only.
> The image tag is always passed as `--set image.tag=$GIT_SHA` at pipeline time, never
> baked into any file, so the chart is environment-agnostic. This way every deploy is
> a git-auditable, reproducible operation.

---

### Q: "How do you handle a failed Helm upgrade in production?"

**Strong answer:**

> In CI/CD we always use `--atomic --timeout 5m`. If a new pod doesn't become Ready
> within 5 minutes, Helm automatically rolls back and exits non-zero, failing the pipeline
> visibly. Our readiness probe is the real gate — it only passes when the app is healthy
> and connected to its dependencies. For manual rollback: `helm rollback <release> -n <ns>`.
> I also run `helm diff` as a required step before every production deploy — it surfaces
> as a PR comment, so reviewers see the exact YAML diff before approving. Think of it
> as `terraform plan` for Kubernetes.

---

### Q: "What is stored in a Helm release Secret?"

**Strong answer:**

> Helm stores release state in Kubernetes Secrets in the release namespace, named
> `sh.helm.release.v1.<release>.v<N>`. Each Secret contains a base64-encoded,
> gzip-compressed JSON blob with: the full rendered manifests for that revision,
> the user-supplied values, and chart metadata. This is how `helm history`,
> `helm rollback`, and `helm get manifest` work — they read these Secrets.
> Deleting those Secrets orphans the resources from Helm's management without
> deleting the actual Kubernetes objects. In production, RBAC should restrict
> who can read these Secrets, since rendered manifests may include sensitive config.

---

### Q: "What is the checksum/config annotation pattern and why do you use it?"

**Strong answer:**

> It's a trick to force a pod rollout when a ConfigMap or Secret changes. Normally,
> if you update a ConfigMap, Helm applies the new ConfigMap but the running pods keep
> reading the old values — because Kubernetes Deployments only restart pods when the
> pod template itself changes. By computing a SHA256 hash of the ConfigMap's content
> and storing it in the Deployment's annotation (`checksum/config: {{ sha256sum }}`),
> any change to the ConfigMap changes the annotation, changes the pod template hash,
> and triggers a rolling restart. It's a zero-boilerplate way to keep config and
> pods in sync.

---

## What to Observe — Summary Checklist

- [ ] `helm history` shows every revision with status and description
- [ ] Pod watch confirms **zero downtime** during rolling upgrade (`maxUnavailable: 0`)
- [ ] Old pods only terminate **after** new pods pass the readiness probe
- [ ] `helm rollback` creates a **new** revision (full audit trail preserved)
- [ ] `helm diff` shows exact YAML diff — no surprises at apply time
- [ ] `--atomic` auto-rolls-back a bad deploy and exits non-zero
- [ ] `cat charts/payments-api/secrets.yaml` shows SOPS ciphertext, not plaintext

---

*← [Lab 05](../05-iam-workload-identity/README.md) | [Lab 07 — Autoscaling →](../07-autoscaling-hpa-vpa/README.md)*
