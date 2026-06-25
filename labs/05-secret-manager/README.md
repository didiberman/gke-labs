# Lab 05 — Secret Manager, External Secrets Operator, and Secret Rotation

> **Goal:** Understand why environment variables are not a safe secret delivery mechanism,
> how GCP Secret Manager stores and versions secrets, how External Secrets Operator (ESO)
> syncs those secrets into Kubernetes without human intervention, and how the full Workload
> Identity chain works — from a GKE pod's identity through to a decrypted secret. By the end
> you should be able to explain why Kubernetes native Secrets are insufficient for a
> PCI-DSS-scoped environment and what the correct architecture looks like.

---

## Table of Contents

1. [Why Not Environment Variables?](#1-why-not-environment-variables)
2. [Secret Manager Concepts — Versions, Rotation, IAM](#2-secret-manager-concepts--versions-rotation-iam)
3. [External Secrets Operator — How It Works](#3-external-secrets-operator--how-it-works)
4. [Workload Identity Integration — The Full Chain](#4-workload-identity-integration--the-full-chain)
5. [Secret Rotation — Automatic Refresh Intervals in ESO](#5-secret-rotation--automatic-refresh-intervals-in-eso)
6. [Referencing Secrets in Pods — Files vs Environment Variables](#6-referencing-secrets-in-pods--files-vs-environment-variables)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. Why Not Environment Variables?

### The Three Problems with Env Var Secrets

Most tutorials show `DB_PASSWORD=secret` in a `spec.containers[].env` or a Kubernetes
`Secret` decoded with `echo $SECRET | base64 -d`. Here is why financial-services platforms
reject this pattern.

#### Problem 1: Process Listing Exposure

On any Linux system, environment variables of running processes are readable by any user
with access to `/proc`:

```bash
# On a compromised node or in a pod with hostPID: true:
cat /proc/$(pgrep payments-api)/environ | tr '\0' '\n' | grep PASSWORD
# Output: DB_PASSWORD=s3cr3t-prod-db-password

# OR via kubectl exec (anyone with exec permission sees all env vars):
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- env | grep -i secret
```

#### Problem 2: Log Leakage

Frameworks commonly print env vars in crash reports, startup logs, or debug endpoints.
Even well-written applications leak secrets through:

```
# Django debug mode prints environment
DATABASES = {'default': {'PASSWORD': 'actual-password-here'}}

# Node.js unhandled rejection stack traces include process.env
UnhandledPromiseRejection: ... process.env.DB_PASSWORD = "actual-password"

# Go panic() dumps goroutine stacks — may include string variables
goroutine 1 [running]:
main.connect(password=0xc000012340, 0x10)  ← pointer, not value, but...
```

#### Problem 3: Kubernetes Secrets Are Base64, Not Encrypted

Kubernetes `Secrets` of type `Opaque` are base64-encoded, not encrypted:

```bash
# Any user with GET permission on the secret sees the decoded value:
kubectl get secret payments-db-credentials -n payments \
  -o jsonpath='{.data.password}' | base64 -d
# Output: actual-plaintext-password

# In etcd (without Envelope Encryption), Secrets are stored in base64 on disk.
# Anyone with access to the etcd backup or snapshot can decode them.
# GKE encrypts etcd at rest at the infrastructure level, but Envelope Encryption
# at the application layer (CMEK with Cloud KMS) provides defense-in-depth.
```

### The Correct Architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│  Secret Lifecycle                                                      │
│                                                                       │
│  1. Secret created/rotated by: Terraform random_password resource     │
│     OR manual rotation script                                         │
│                     │                                                 │
│                     ▼                                                 │
│  2. Stored in: GCP Secret Manager (encrypted, versioned, audited)     │
│                     │                                                 │
│                     ▼                                                 │
│  3. Synced by: External Secrets Operator (ESO)                        │
│     - watches SecretStore + ExternalSecret CRDs                       │
│     - fetches secret from GCP API (using Workload Identity)           │
│     - creates/updates a standard Kubernetes Secret                    │
│                     │                                                 │
│                     ▼                                                 │
│  4. Consumed by: Pod via volume mount (as a FILE)                     │
│     - file is unreadable by other processes                           │
│     - not visible in process listing                                  │
│     - not logged by frameworks                                        │
│                                                                       │
│  NEVER: pass secret directly as an env var to a container             │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 2. Secret Manager Concepts — Versions, Rotation, IAM

### What Is a Secret Manager Secret?

A Secret Manager "secret" is a container that holds one or more **versions**. Each version
is an immutable blob of bytes. Rotation creates a new version without deleting the old one,
allowing graceful rollover.

```
Secret: payments-api-db-password
├── Version 1  (created: 2026-01-15) DISABLED
├── Version 2  (created: 2026-03-01) DISABLED
├── Version 3  (created: 2026-05-01) ENABLED  ← current active version
└── Version 4  (created: 2026-06-25) ENABLED  ← newly rotated version
```

### Creating a Secret

```bash
# Create a new secret (empty container)
gcloud secrets create payments-api-db-password \
  --project=gke-labs \
  --replication-policy=user-managed \
  --locations=europe-west1 \
  --labels=app=payments-api,env=prod,managed-by=terraform

# Add the first version (the actual secret value)
echo -n "s3cur3-p@ssw0rd-$(openssl rand -hex 8)" | \
  gcloud secrets versions add payments-api-db-password \
    --project=gke-labs \
    --data-file=-

# Verify
gcloud secrets versions list payments-api-db-password \
  --project=gke-labs \
  --format="table(name,state,createTime)"

# Output:
# NAME  STATE   CREATE_TIME
# 1     ENABLED 2026-06-25T14:00:00Z
```

### Retrieving a Secret Value

```bash
# Access the latest version (requires roles/secretmanager.secretAccessor)
gcloud secrets versions access latest \
  --secret=payments-api-db-password \
  --project=gke-labs

# Access a specific version
gcloud secrets versions access 3 \
  --secret=payments-api-db-password \
  --project=gke-labs

# Access with format (useful for automation)
gcloud secrets versions access latest \
  --secret=payments-api-db-password \
  --project=gke-labs \
  --format="value(payload.data)" | base64 -d
```

### IAM Controls — Principle of Least Privilege

Secret Manager has granular IAM roles:

| Role | What It Allows |
|------|----------------|
| `roles/secretmanager.viewer` | View secret metadata, NOT the value |
| `roles/secretmanager.secretAccessor` | Read secret versions (access the value) |
| `roles/secretmanager.secretVersionAdder` | Create new versions (rotation) |
| `roles/secretmanager.admin` | Full control including delete |

```bash
# Grant the payments-api GSA access to read its specific secret only
# (secret-level IAM, not project-level — principle of least privilege)
gcloud secrets add-iam-policy-binding payments-api-db-password \
  --project=gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# The ESO controller SA also needs access to ALL secrets it manages
gcloud projects add-iam-policy-binding gke-labs \
  --member="serviceAccount:eso-controller@gke-labs.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
# In practice, scope ESO to specific secrets or use resource-based IAM per secret.

# Audit who can access a secret
gcloud secrets get-iam-policy payments-api-db-password \
  --project=gke-labs \
  --format="table(bindings.role,bindings.members)"
```

### Secret Audit Logging

Secret Manager integrates with Cloud Audit Logs automatically:

```bash
# View audit logs for a specific secret
gcloud logging read \
  'resource.type="audited_resource" AND
   protoPayload.resourceName="projects/gke-labs/secrets/payments-api-db-password"' \
  --project=gke-labs \
  --format="table(timestamp,protoPayload.authenticationInfo.principalEmail,protoPayload.methodName)" \
  --limit=20

# This shows: who accessed the secret, when, and from what IP.
# Required by PCI-DSS Requirement 10: Monitor all access to cardholder data.
```

---

## 3. External Secrets Operator — How It Works

### What Problem Does ESO Solve?

You need secrets from GCP Secret Manager to land as Kubernetes Secrets so your pods can
use them. Options:

1. **Manually `kubectl create secret`:** Human error, no rotation, secrets in shell history.
2. **Init container with `gcloud secrets versions access`:** Secret briefly in container
   stdout, complex, non-standard.
3. **External Secrets Operator:** Standard CRD-based, Kubernetes-native, automatic rotation,
   auditable, supports many backends (GCP, AWS, Vault, Azure).

### ESO Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  GKE Cluster (namespace: external-secrets)                          │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  External Secrets Operator (Deployment)                       │  │
│  │  - Watches ExternalSecret CRDs cluster-wide                  │  │
│  │  - Connects to backend (GCP Secret Manager) via Workload     │  │
│  │    Identity                                                   │  │
│  │  - Reconciles every refreshInterval                          │  │
│  └──────────────────────────────────────────────────────────────┘  │
│            │ reads                                │ creates/updates │
│            ▼                                      ▼                 │
│  ┌───────────────────┐              ┌───────────────────────────┐  │
│  │  SecretStore CRD  │              │  Kubernetes Secret         │  │
│  │  (namespace-scoped│              │  payments-db-credentials   │  │
│  │  or ClusterStore) │              │  (type: Opaque)            │  │
│  │                   │              │  data:                     │  │
│  │  provider:        │              │    password: <synced>      │  │
│  │    gcpsm:         │              └───────────────────────────┘  │
│  │      auth:        │                          │ mounted as volume │
│  │        workload-  │                          ▼                   │
│  │        identity   │              ┌───────────────────────────┐  │
│  └───────────────────┘              │  Pod                       │  │
│            │ ExternalSecret points  │  /var/secrets/password     │  │
│            │ to SecretStore         │  (file, not env var)       │  │
│            ▼                        └───────────────────────────┘  │
│  ┌───────────────────┐                                             │
│  │  ExternalSecret   │                                             │
│  │  CRD              │                                             │
│  │                   │                                             │
│  │  target:          │                                             │
│  │    name: payments-│                                             │
│  │    db-credentials │                                             │
│  │  data:            │                                             │
│  │    - secretKey:   │                                             │
│  │      password     │                                             │
│  │      remoteRef:   │                                             │
│  │        key: pay-  │                                             │
│  │        ments-api- │                                             │
│  │        db-password│                                             │
│  └───────────────────┘                                             │
└─────────────────────────────────────────────────────────────────────┘
```

### Installing ESO

```bash
# Install External Secrets Operator via Helm
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"=\
"eso-controller@gke-labs.iam.gserviceaccount.com" \
  --wait

# Verify
kubectl get pods -n external-secrets
# NAME                                          READY   STATUS    RESTARTS
# external-secrets-5d7f9f8d6c-k9r2x             1/1     Running   0
# external-secrets-cert-controller-xxx          1/1     Running   0
# external-secrets-webhook-xxx                  1/1     Running   0
```

### Creating a SecretStore

The `SecretStore` tells ESO how to connect to the backend (GCP Secret Manager):

```yaml
# k8s/secret-stores/gcp-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: gcp-secrets-store
  namespace: payments
spec:
  provider:
    gcpsm:
      projectID: gke-labs
      # Use Workload Identity — no SA key files needed.
      # The ESO pod's KSA is annotated with the GSA email.
      auth:
        workloadIdentity:
          clusterLocation: europe-west1
          clusterName: gke-labs-dev
          clusterProjectID: gke-labs
          serviceAccountRef:
            name: payments-api     # KSA in the payments namespace
            namespace: payments
```

```bash
kubectl apply -f k8s/secret-stores/gcp-secret-store.yaml

# Verify the SecretStore is ready
kubectl get secretstore gcp-secrets-store -n payments
# NAME                READY   AGE
# gcp-secrets-store   True    45s

kubectl describe secretstore gcp-secrets-store -n payments
# Status:
#   Conditions:
#     Message: store validated
#     Reason:  Valid
#     Status:  True
#     Type:    Ready
```

### Creating an ExternalSecret

```yaml
# k8s/external-secrets/payments-db-credentials.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-db-credentials
  namespace: payments
spec:
  # How often ESO polls Secret Manager for changes
  refreshInterval: 1h

  secretStoreRef:
    name: gcp-secrets-store
    kind: SecretStore

  target:
    name: payments-db-credentials    # Name of the Kubernetes Secret to create
    creationPolicy: Owner            # ESO owns this Secret (deletes on ExternalSecret delete)
    deletionPolicy: Retain           # Keep the Secret even if ExternalSecret is deleted
    template:
      type: Opaque
      # Optional: add metadata to the created Secret
      metadata:
        labels:
          app: payments-api
          managed-by: external-secrets-operator

  data:
    # Map GCP Secret Manager key → Kubernetes Secret key
    - secretKey: password            # key in the Kubernetes Secret
      remoteRef:
        key: payments-api-db-password   # name of the GCP Secret
        version: latest              # always fetch the latest enabled version
```

```bash
kubectl apply -f k8s/external-secrets/payments-db-credentials.yaml

# Watch the ExternalSecret sync status
kubectl get externalsecret payments-db-credentials -n payments
# NAME                        STORE               REFRESH INTERVAL  STATUS
# payments-db-credentials     gcp-secrets-store   1h                SecretSynced

# Verify the Kubernetes Secret was created
kubectl get secret payments-db-credentials -n payments
kubectl describe secret payments-db-credentials -n payments
# Data
# ====
# password:  32 bytes    ← synced from GCP Secret Manager

# Check sync status details
kubectl get externalsecret payments-db-credentials -n payments \
  -o jsonpath='{.status.conditions}' | jq .
```

---

## 4. Workload Identity Integration — The Full Chain

### Why Workload Identity?

Without Workload Identity, you would need to:
1. Create a GCP Service Account key (JSON file)
2. Store the key as a Kubernetes Secret
3. Mount the key into pods that need GCP access
4. Rotate the key manually (typically annually, which teams forget)

This is insecure: a key file is a long-lived credential that can be exfiltrated and used
from anywhere on the internet, not just from your cluster.

### Workload Identity: The Full Trust Chain

```
Step 1: Configure Workload Identity on the cluster
  gke-labs-dev cluster
  ├── Workload Identity Pool: gke-labs.svc.id.goog
  └── Each node has the Metadata Server running (169.254.169.254)

Step 2: Create a GCP Service Account (GSA)
  payments-api@gke-labs.iam.gserviceaccount.com
  └── Grant it: roles/secretmanager.secretAccessor on specific secrets

Step 3: Create a Kubernetes Service Account (KSA)
  namespace: payments
  name: payments-api
  └── Annotate with GSA email:
      iam.gke.io/gcp-service-account: payments-api@gke-labs.iam.gserviceaccount.com

Step 4: Grant the KSA permission to impersonate the GSA
  gcloud iam service-accounts add-iam-policy-binding \
    payments-api@gke-labs.iam.gserviceaccount.com \
    --member="serviceAccount:gke-labs.svc.id.goog[payments/payments-api]" \
    --role=roles/iam.workloadIdentityUser

Step 5: Pod uses the annotated KSA
  spec.serviceAccountName: payments-api
  └── GKE Metadata Server intercepts calls to 169.254.169.254/computeMetadata/v1/
      └── Returns an OIDC token for the GSA
          └── ESO uses this token to authenticate to secretmanager.googleapis.com
```

### Setting Up the Full Chain

```bash
# Step 1: Verify Workload Identity is enabled on the cluster
gcloud container clusters describe gke-labs-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(workloadIdentityConfig.workloadPool)"
# Expected: gke-labs.svc.id.goog

# Step 2: Create the GSA
gcloud iam service-accounts create payments-api \
  --project=gke-labs \
  --display-name="Payments API service account" \
  --description="Used by the payments-api Deployment in GKE"

# Step 3: Grant the GSA access to its secrets
gcloud secrets add-iam-policy-binding payments-api-db-password \
  --project=gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding payments-api-redis-auth \
  --project=gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding payments-api-jwt-secret \
  --project=gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Step 4: Create the KSA and annotate it
kubectl create serviceaccount payments-api \
  --namespace=payments

kubectl annotate serviceaccount payments-api \
  --namespace=payments \
  iam.gke.io/gcp-service-account=payments-api@gke-labs.iam.gserviceaccount.com

# Step 5: Bind the KSA to the GSA (Workload Identity binding)
gcloud iam service-accounts add-iam-policy-binding \
  payments-api@gke-labs.iam.gserviceaccount.com \
  --project=gke-labs \
  --member="serviceAccount:gke-labs.svc.id.goog[payments/payments-api]" \
  --role=roles/iam.workloadIdentityUser

# Step 6: Verify the full chain works
# Run a test pod using the payments-api KSA
kubectl run wi-test \
  --image=google/cloud-sdk:alpine \
  --restart=Never \
  --rm -it \
  --namespace=payments \
  --serviceaccount=payments-api \
  -- gcloud auth print-access-token

# If this returns a token, Workload Identity is working.
# If it fails with "Unable to generate access token", check the annotation
# and the IAM binding.
```

### Debugging Workload Identity

```bash
# Check the KSA annotation
kubectl get serviceaccount payments-api -n payments \
  -o jsonpath='{.metadata.annotations}'
# Expected: {"iam.gke.io/gcp-service-account":"payments-api@gke-labs.iam.gserviceaccount.com"}

# Verify the IAM binding exists
gcloud iam service-accounts get-iam-policy \
  payments-api@gke-labs.iam.gserviceaccount.com \
  --project=gke-labs \
  --format="table(bindings.role,bindings.members)"
# Look for: roles/iam.workloadIdentityUser | serviceAccount:gke-labs.svc.id.goog[payments/payments-api]

# Check node pool has Workload Identity enabled
gcloud container node-pools describe application-pool \
  --cluster=gke-labs-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(config.workloadMetadataConfig.mode)"
# Expected: GKE_METADATA (not EXPOSE, which would bypass Workload Identity)
```

---

## 5. Secret Rotation — Automatic Refresh Intervals in ESO

### How Rotation Works End-to-End

```
1. Secret Manager triggers a rotation notification
   (or rotation is done manually: gcloud secrets versions add ...)
   │
2. New version is created in Secret Manager; old version remains ENABLED
   during transition period
   │
3. ESO reconciliation loop fires at refreshInterval (e.g., 1h)
   └─ Compares current Kubernetes Secret value with latest Secret Manager version
   └─ If different: updates the Kubernetes Secret
   │
4. Application reads the updated secret from the mounted file
   └─ File-mounted secrets are updated in-place by kubelet
   └─ Application must re-read the file to pick up the new value
   │
5. After all pods have confirmed the new credential works:
   └─ Disable the old Secret Manager version
```

### Configuring Rotation in ExternalSecret

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-db-credentials
  namespace: payments
spec:
  # Rotation check interval
  # Shorter interval = faster pickup of rotated secrets
  # Longer interval = fewer API calls to Secret Manager (cost and rate limit)
  # Recommendation for database passwords: 1h
  # Recommendation for high-rotation secrets (session keys): 5m
  refreshInterval: 1h

  secretStoreRef:
    name: gcp-secrets-store
    kind: SecretStore

  target:
    name: payments-db-credentials
    creationPolicy: Owner

  data:
    - secretKey: password
      remoteRef:
        key: payments-api-db-password
        # "latest" always fetches the most recent ENABLED version.
        # This is why rotation works: add a new version → it becomes latest →
        # ESO picks it up at the next refresh.
        version: latest
```

### Force Immediate Rotation (Manual Trigger)

```bash
# 1. Create a new secret version (the actual rotation)
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
echo -n "${NEW_PASSWORD}" | \
  gcloud secrets versions add payments-api-db-password \
    --project=gke-labs \
    --data-file=-

# 2. Update the database user password to match
# (via Cloud SQL admin API or psql — must be done before disabling old version)
gcloud sql users set-password payments-api \
  --instance=gke-lab-postgres-dev \
  --project=gke-labs \
  --password="${NEW_PASSWORD}"

# 3. Force ESO to reconcile immediately (don't wait for refreshInterval)
kubectl annotate externalsecret payments-db-credentials \
  --namespace=payments \
  force-sync="$(date +%s)" \
  --overwrite

# 4. Verify the Kubernetes Secret was updated
kubectl get secret payments-db-credentials -n payments \
  -o jsonpath='{.metadata.annotations.refresh-time}'

# 5. Verify pods are using the new credential
# (file-mounted secrets update automatically without pod restart)
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- cat /var/secrets/db-password
# Should show the new password

# 6. Test that the application still connects to the database
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- pg_isready -h 127.0.0.1 -p 5432 -U payments-api -d payments

# 7. Disable the old secret version (after confirming new password works)
OLD_VERSION=$(gcloud secrets versions list payments-api-db-password \
  --project=gke-labs \
  --filter="state=ENABLED" \
  --sort-by="createTime" \
  --format="value(name)" | head -1)

gcloud secrets versions disable "${OLD_VERSION}" \
  --secret=payments-api-db-password \
  --project=gke-labs
```

### Rotation Without Pod Restart

File-mounted secrets update automatically because kubelet periodically syncs the mounted
volume from the Secret. The default sync period is 60 seconds (configurable via
`--sync-frequency` on kubelet). Your application must be written to re-read the file:

```python
# GOOD: read secret from file on each use (or cache with short TTL)
import pathlib
import time

_DB_PASSWORD_CACHE = None
_DB_PASSWORD_CACHE_TIME = 0
_CACHE_TTL = 60  # re-read every 60 seconds

def get_db_password() -> str:
    global _DB_PASSWORD_CACHE, _DB_PASSWORD_CACHE_TIME
    now = time.time()
    if now - _DB_PASSWORD_CACHE_TIME > _CACHE_TTL:
        _DB_PASSWORD_CACHE = pathlib.Path('/var/secrets/db-password').read_text().strip()
        _DB_PASSWORD_CACHE_TIME = now
    return _DB_PASSWORD_CACHE

# BAD: read once at startup — won't pick up rotation until pod restart
DB_PASSWORD = open('/var/secrets/db-password').read().strip()  # never do this
```

---

## 6. Referencing Secrets in Pods — Files vs Environment Variables

### The File-Based Pattern (Recommended)

Mount the Kubernetes Secret as a volume. The secret value lands as a file on disk:

```yaml
spec:
  volumes:
    - name: db-credentials
      secret:
        secretName: payments-db-credentials
        # Optional: restrict file permissions
        defaultMode: 0400    # owner read-only; 0400 = -r--------

  containers:
    - name: payments-api
      image: europe-west1-docker.pkg.dev/gke-labs/payments/payments-api:latest
      volumeMounts:
        - name: db-credentials
          mountPath: /var/secrets
          readOnly: true
      # Application reads password from /var/secrets/password
      # NOT from an environment variable
```

Verify the file is mounted correctly:

```bash
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- ls -la /var/secrets/
# -r-------- 1 root root 32 Jun 25 14:00 password

kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- cat /var/secrets/password
# s3cur3-p@ssw0rd-abc123def

# Confirm the secret is NOT in env:
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- env | grep -i password
# (no output — correct!)
```

### Why Files Are Better Than Env Vars for Secrets

| Property | File Mount | Environment Variable |
|----------|-----------|---------------------|
| Visible in `ps aux` / `/proc/PID/environ` | No | Yes |
| Rotates without pod restart | Yes (kubelet syncs) | No (restart required) |
| Logged by most frameworks | No | Sometimes (crash dumps, debug) |
| Accessible by child processes | Only with explicit file read | Inherited by all subprocesses |
| Audit trail | Secret Manager + RBAC | Only K8s RBAC |
| File permission control | Yes (chmod 0400) | No |

### When Env Vars Are Acceptable (Non-Secret Config)

Environment variables are appropriate for non-sensitive configuration:

```yaml
env:
  # Non-secret configuration — fine as env vars
  - name: DB_HOST
    value: "127.0.0.1"
  - name: DB_PORT
    value: "5432"
  - name: DB_NAME
    value: "payments"
  - name: APP_ENV
    value: "production"
  - name: LOG_LEVEL
    value: "info"

  # Secret values — use volume mounts instead
  # WRONG:
  # - name: DB_PASSWORD
  #   valueFrom:
  #     secretKeyRef:
  #       name: payments-db-credentials
  #       key: password
```

### Reading Multiple Secrets from One ExternalSecret

ESO can sync multiple Secret Manager keys into a single Kubernetes Secret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-all-credentials
  namespace: payments
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secrets-store
    kind: SecretStore
  target:
    name: payments-all-credentials
  data:
    - secretKey: db-password
      remoteRef:
        key: payments-api-db-password
    - secretKey: redis-auth
      remoteRef:
        key: payments-api-redis-auth
    - secretKey: jwt-secret
      remoteRef:
        key: payments-api-jwt-secret
```

```yaml
# Pod spec: mount all secrets in one volume
volumeMounts:
  - name: app-credentials
    mountPath: /var/secrets
    readOnly: true

# Files available in the pod:
# /var/secrets/db-password
# /var/secrets/redis-auth
# /var/secrets/jwt-secret
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1: SecretStore Misconfiguration — Wrong Project ID

**Goal:** Understand the error surface when ESO can't connect to the backend.

```bash
# Step 1: Edit the SecretStore to use a wrong project
kubectl patch secretstore gcp-secrets-store \
  -n payments \
  --type=merge \
  -p '{"spec":{"provider":{"gcpsm":{"projectID":"wrong-project-id"}}}}'

# Step 2: Force a sync
kubectl annotate externalsecret payments-db-credentials \
  --namespace=payments \
  force-sync="broken-$(date +%s)" \
  --overwrite

# Step 3: Observe the error
kubectl get externalsecret payments-db-credentials -n payments
# STATUS: SecretSyncedError

kubectl describe externalsecret payments-db-credentials -n payments
# Events:
#   Warning  UpdateFailed  ...  failed to call GCP API: ...
#   could not access secret: googleapi: Error 403: ... OR Error 404: project not found

# Step 4: Fix the SecretStore
kubectl patch secretstore gcp-secrets-store \
  -n payments \
  --type=merge \
  -p '{"spec":{"provider":{"gcpsm":{"projectID":"gke-labs"}}}}'

# Step 5: Verify recovery
sleep 30
kubectl get externalsecret payments-db-credentials -n payments
# STATUS: SecretSynced
```

---

### Exercise 2: Missing IAM Binding — Access Denied

**Goal:** Observe the error when the GSA lacks `secretAccessor` on a secret.

```bash
# Step 1: Remove the IAM binding
gcloud secrets remove-iam-policy-binding payments-api-db-password \
  --project=gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Step 2: Force ESO to attempt a sync
kubectl annotate externalsecret payments-db-credentials \
  --namespace=payments \
  force-sync="iam-test-$(date +%s)" \
  --overwrite

# Step 3: Watch the error
watch kubectl get externalsecret payments-db-credentials -n payments
# After ~30 seconds: STATUS: SecretSyncedError

kubectl describe externalsecret payments-db-credentials -n payments | grep -A 5 "Error"
# Error: failed to get secret: rpc error: code = PermissionDenied
# desc = Request had insufficient authentication scopes.
# OR: Error 403: The caller does not have permission

# Step 4: Restore the IAM binding
gcloud secrets add-iam-policy-binding payments-api-db-password \
  --project=gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Step 5: Trigger a fresh reconcile and verify
kubectl annotate externalsecret payments-db-credentials \
  --namespace=payments \
  force-sync="restored-$(date +%s)" \
  --overwrite

sleep 30
kubectl get externalsecret payments-db-credentials -n payments
# STATUS: SecretSynced
```

---

### Exercise 3: Simulate Secret Rotation and Verify Zero-Downtime

**Goal:** Rotate a secret and confirm pods pick it up without a restart.

```bash
# Step 1: Read the current secret value from a pod
BEFORE=$(kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- cat /var/secrets/db-password)
echo "Before rotation: ${BEFORE}"

# Step 2: Add a new version to Secret Manager
NEW_VALUE="rotated-$(date +%Y%m%d)-$(openssl rand -hex 4)"
echo -n "${NEW_VALUE}" | \
  gcloud secrets versions add payments-api-db-password \
    --project=gke-labs \
    --data-file=-

# Step 3: Force ESO to sync
kubectl annotate externalsecret payments-db-credentials \
  --namespace=payments \
  force-sync="rotation-$(date +%s)" \
  --overwrite

# Step 4: Wait for the Kubernetes Secret to update (ESO reconciliation)
echo "Waiting for ESO reconciliation..."
sleep 30

# Step 5: Check when the Kubernetes Secret was last updated
kubectl get secret payments-db-credentials -n payments \
  -o jsonpath='{.metadata.annotations.reconcile\.external-secrets\.io/data-hash}'

# Step 6: Wait for kubelet to sync the volume (up to 60 seconds)
echo "Waiting for kubelet volume sync..."
sleep 60

# Step 7: Read the new value from the pod — no restart required
AFTER=$(kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -- cat /var/secrets/db-password)
echo "After rotation: ${AFTER}"

# Compare — they should be different if file-based mounting is working
if [ "${BEFORE}" != "${AFTER}" ]; then
  echo "SUCCESS: Secret rotated without pod restart"
else
  echo "ISSUE: Secret not yet updated in pod"
fi

# Step 8: Clean up — disable the old version
OLD_VERSION=$(gcloud secrets versions list payments-api-db-password \
  --project=gke-labs \
  --filter="state=ENABLED" \
  --sort-by="createTime" \
  --format="value(name)" | head -1)

gcloud secrets versions disable "${OLD_VERSION}" \
  --secret=payments-api-db-password \
  --project=gke-labs
```

---

## 8. Interview Q&A

---

### Q1: Why are Kubernetes Secrets not "secure" even though they're not stored as plaintext in etcd on GKE?

**Answer:**

GKE encrypts etcd at rest using Google-managed keys at the infrastructure level. However,
Kubernetes Secrets have several remaining weaknesses:

1. **Base64 is encoding, not encryption:** Anyone with `kubectl get secret` permission reads
   the value immediately. Base64 provides no security — it's a display transformation.

2. **RBAC proliferation:** The default Kubernetes RBAC grants broad Secret access to many
   service accounts. A misconfigured Role or ClusterRoleBinding can expose all secrets in
   a namespace to any pod.

3. **No versioning or audit trail:** Kubernetes Secrets have no history. If a secret is
   changed, there is no record of what the old value was or who changed it.

4. **No access logging:** Accessing a Kubernetes Secret via `kubectl` or the API is not
   audited at the same granularity as GCP Secret Manager's Cloud Audit Logs.

5. **GitOps risk:** Developers sometimes accidentally commit Secret manifests to Git
   (base64 is deceptive — it "looks" encoded).

**GCP Secret Manager + ESO solves all of these:** encrypted storage, IAM-based access
control, version history, Cloud Audit Logs for every access, and no values in Git.

---

### Q2: What is the difference between `ClusterSecretStore` and `SecretStore`?

**Answer:**

**SecretStore:** Namespace-scoped. ExternalSecrets in the `payments` namespace can only
reference a SecretStore in the `payments` namespace. This provides isolation — a developer
in the `staging` namespace cannot use a SecretStore from `production`.

**ClusterSecretStore:** Cluster-scoped. Any ExternalSecret in any namespace can reference
it. Reduces configuration duplication but increases the blast radius — a misconfigured
ClusterSecretStore affects the entire cluster.

**Best practice for financial services:** Use namespace-scoped `SecretStore` resources.
Create one per environment namespace (`payments-prod`, `payments-staging`). Each points to
the same GCP Secret Manager but the GCP IAM bindings are scoped per environment's GSA,
so prod secrets are not accessible from staging and vice versa.

---

### Q3: A developer asks: "Why don't we just put secrets in a ConfigMap? Secrets are just ConfigMaps with a different type, right?"

**Answer:**

This is a common misconception. ConfigMaps and Secrets differ in important ways:

1. **etcd storage:** Kubernetes Secrets are stored in a separate etcd key range than
   ConfigMaps. Envelope Encryption (when enabled) applies specifically to Secrets, not
   ConfigMaps. Putting a secret in a ConfigMap bypasses this protection.

2. **`kubectl` display:** `kubectl describe configmap` shows the full value in plain text.
   `kubectl describe secret` shows `<key>: N bytes` — the value is redacted by default.

3. **Logging:** Many Kubernetes controllers and admission webhooks log ConfigMap contents
   for debugging. Secrets are treated differently and their values are typically not logged.

4. **Kubelet behavior:** Secret volumes are stored in a `tmpfs` (memory filesystem) by
   default, not written to disk on the node. ConfigMap volumes are written to the node's
   filesystem. For secrets, this means no disk forensics can recover the value after the
   pod is deleted.

**Verdict:** Never use ConfigMaps for secrets, even though you technically can.

---

### Q4: How does ESO authenticate to GCP Secret Manager without a service account key file?

**Answer:**

ESO uses Workload Identity. The chain is:

1. The ESO controller pod runs with a Kubernetes Service Account (KSA) annotated with a
   GCP Service Account (GSA) email.
2. When the pod calls the GKE Metadata Server (`http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token`),
   the Metadata Server intercepts the request and returns a short-lived OIDC token for the
   annotated GSA — not the node's default SA.
3. ESO uses this OIDC token to call `secretmanager.googleapis.com/v1/projects/.../secrets/.../versions/latest:access`.
4. GCP validates the token, checks that the GSA has `roles/secretmanager.secretAccessor`
   on the requested secret, and returns the decrypted value.

The key insight: no static credentials leave the cluster. The OIDC token is valid for 1 hour
and is bound to the specific GKE cluster and KSA. It cannot be used from outside the cluster.

---

### Q5: Secret rotation is configured with `refreshInterval: 1h`. How long is the maximum window during which a pod might be running with a stale secret after rotation?

**Answer:**

There are three delays in the chain:

1. **ESO reconciliation delay:** Up to `refreshInterval` (1 hour) until ESO polls
   Secret Manager and updates the Kubernetes Secret.

2. **Kubelet volume sync delay:** After the Kubernetes Secret is updated, kubelet syncs
   mounted volumes on the next sync cycle. Default sync period: ~60 seconds.
   Controlled by `--sync-frequency` on the kubelet.

3. **Application re-read delay:** If the application caches the secret value in memory
   (e.g., reads once at startup), it will continue using the old value until it re-reads
   the file or is restarted. With a 60-second cache TTL in the application, this adds
   up to 60 seconds.

**Maximum stale window = refreshInterval + kubelet sync + app cache TTL**
= 60 minutes + 60 seconds + 60 seconds ≈ **62 minutes**

**How to reduce this:**
- Use a shorter `refreshInterval` (e.g., 5 minutes) for high-sensitivity secrets
- Use `force-sync` annotation to trigger immediate reconciliation after rotation
- Design the application to re-read secrets from disk on a configurable interval
- For database password rotation: use a connection pool that creates new connections with
  the new password while gracefully draining connections using the old one (requires
  the old password to remain valid during the transition window — both Secret Manager
  versions enabled simultaneously)
