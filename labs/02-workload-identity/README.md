# Lab 02 — Workload Identity: Pod-Level GCP Auth Without Keys

> **Goal:** Understand how GKE pods authenticate to GCP APIs without ever touching a JSON key file.
> By the end of this lab you will have verified token issuance from inside a running pod,
> tested real GCS and Secret Manager access, and deliberately broken and repaired the binding.

---

## Table of Contents

1. [How Workload Identity Works](#1-how-workload-identity-works)
2. [Prerequisites Verification](#2-prerequisites-verification)
3. [The Annotation That Links K8s SA to GCP SA](#3-the-annotation-that-links-k8s-sa-to-gcp-sa)
4. [Verifying It Works — From Inside the Pod](#4-verifying-it-works--from-inside-the-pod)
5. [Testing GCS Access from a Pod](#5-testing-gcs-access-from-a-pod)
6. [Testing Secret Manager Access from a Pod](#6-testing-secret-manager-access-from-a-pod)
7. [Common Mistakes & How to Debug Them](#7-common-mistakes--how-to-debug-them)
8. [Break-It & Fix-It Exercises](#8-break-it--fix-it-exercises)
9. [Interview Q&A](#9-interview-qa)

---

## 1. How Workload Identity Works

### The Big Picture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         GKE Node (VM)                                       │
│                                                                             │
│  ┌─────────────────────────────────────────────────────┐                   │
│  │                      Pod                            │                   │
│  │                                                     │                   │
│  │   app container                                     │                   │
│  │   ─────────────                                     │                   │
│  │   serviceAccountName: app-workload-sa  ─────────────┼──────────────────►│
│  │                                                     │  K8s SA token     │
│  └─────────────────────────────────────────────────────┘  (projected vol)  │
│                                                                             │
│  GKE Metadata Server (interceptor on 169.254.169.254)                      │
│  ─────────────────────────────────────────────────────                      │
│  Intercepts metadata calls from pods.                                       │
│  Reads the pod's K8s SA → looks up the iam.gke.io annotation               │
│  Verifies the IAM workloadIdentityUser binding                              │
│  Returns a short-lived GCP OAuth2 token for the mapped GCP SA              │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
         │
         │  Short-lived token (~1h, auto-refreshed)
         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Google APIs                                        │
│                                                                             │
│   Cloud Storage  │  Secret Manager  │  Pub/Sub  │  BigQuery  │  Cloud SQL  │
│                                                                             │
│   Token is validated. Request scoped to GCP SA's IAM roles only.           │
│   Token is NOT usable outside this pod's identity context.                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The IAM Binding — The Critical Link

```
┌─────────────────────┐    IAM Binding    ┌──────────────────────────────────┐
│ Kubernetes           │   ────────────►  │ GCP IAM                          │
│ ServiceAccount       │                  │ Service Account                   │
│                      │                  │                                   │
│ Namespace: application│                 │ app-workload-sa@                  │
│ Name: app-workload-sa│                  │   gke-labs.iam.gserviceaccount.com│
│                      │                  │                                   │
│ annotation:          │    roles/iam.    │ Has GCP permissions:              │
│  iam.gke.io/gcp-sa = │  workloadIdentity│  • roles/storage.objectViewer    │
│  app-workload-sa@... │    User          │  • roles/secretmanager.accessor   │
└─────────────────────┘                   └──────────────────────────────────┘

The "member" in the IAM binding is:
  serviceAccount:gke-labs.svc.id.goog[application/app-workload-sa]
                 ──────────────────── ──────────── ───────────────
                 Workload Identity    Namespace     K8s SA name
                 Pool (project-level)
```

### Token Flow in Detail

```
1. Pod starts with serviceAccountName: app-workload-sa

2. K8s injects a projected ServiceAccount token into:
   /var/run/secrets/kubernetes.io/serviceaccount/token
   (This is a K8s token, NOT a GCP token)

3. App code (or gcloud CLI, or GCP SDK) calls:
   GET http://metadata.google.internal/computeMetadata/v1/
           instance/service-accounts/default/token
   Header: Metadata-Flavor: Google

4. The GKE Metadata Server on the node intercepts this call.
   - Identifies the calling pod via network namespace
   - Reads pod's serviceAccountName
   - Checks annotation iam.gke.io/gcp-service-account
   - Verifies the IAM workloadIdentityUser binding exists
   - Exchanges the K8s token for a short-lived GCP OAuth2 token

5. Returns a GCP access token that apps use for API calls.
   Token expires in ~3600 seconds and is automatically refreshed.
```

---

## 2. Prerequisites Verification

Ensure the cluster has Workload Identity enabled:

```bash
export PROJECT_ID="gke-labs"
export REGION="europe-west1"
export CLUSTER_NAME="gke-lab-cluster"

# Verify Workload Identity is enabled on the cluster
gcloud container clusters describe ${CLUSTER_NAME} \
  --region=${REGION} \
  --project=${PROJECT_ID} \
  --format="value(workloadIdentityConfig.workloadPool)"

# Expected output:
# gke-labs.svc.id.goog
```

If the output is empty, Workload Identity is not enabled. Enable it:

```bash
gcloud container clusters update ${CLUSTER_NAME} \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --region=${REGION} \
  --project=${PROJECT_ID}
```

Verify the node pool has `GKE_METADATA` mode (required for WI to work on nodes):

```bash
gcloud container node-pools describe application-pool \
  --cluster=${CLUSTER_NAME} \
  --region=${REGION} \
  --project=${PROJECT_ID} \
  --format="value(config.workloadMetadataConfig.mode)"

# Expected: GKE_METADATA
```

---

## 3. The Annotation That Links K8s SA to GCP SA

### Full Setup — Step by Step

```bash
export PROJECT_ID="gke-labs"
export K8S_NAMESPACE="application"
export K8S_SA_NAME="app-workload-sa"
export GCP_SA_NAME="app-workload-sa"
export GCP_SA_EMAIL="${GCP_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ─── Step 1: Ensure the namespace exists ─────────────────────────────────────
kubectl create namespace ${K8S_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# ─── Step 2: Create the GCP Service Account ──────────────────────────────────
gcloud iam service-accounts create ${GCP_SA_NAME} \
  --display-name="Workload Identity SA for GKE app pods" \
  --description="Used by pods in the application namespace via Workload Identity" \
  --project=${PROJECT_ID}

# ─── Step 3: Grant the K8s SA permission to impersonate the GCP SA ───────────
# IMPORTANT: The member format is very specific — one typo = it won't work
gcloud iam service-accounts add-iam-policy-binding ${GCP_SA_EMAIL} \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA_NAME}]" \
  --project=${PROJECT_ID}

# Verify the binding was created
gcloud iam service-accounts get-iam-policy ${GCP_SA_EMAIL} \
  --project=${PROJECT_ID}
# Look for: role: roles/iam.workloadIdentityUser
#           member: serviceAccount:gke-labs.svc.id.goog[application/app-workload-sa]

# ─── Step 4: Create the Kubernetes ServiceAccount with the annotation ─────────
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${K8S_SA_NAME}
  namespace: ${K8S_NAMESPACE}
  annotations:
    # THIS IS THE KEY ANNOTATION — it tells GKE which GCP SA to impersonate
    iam.gke.io/gcp-service-account: ${GCP_SA_EMAIL}
EOF

# Verify the annotation is set
kubectl describe serviceaccount ${K8S_SA_NAME} -n ${K8S_NAMESPACE}
# Look for:
# Annotations: iam.gke.io/gcp-service-account: app-workload-sa@gke-labs.iam.gserviceaccount.com
```

---

## 4. Verifying It Works — From Inside the Pod

This is the most important verification step. You're confirming the full token exchange
works end-to-end by calling the metadata server from inside a running pod.

### Deploy a Test Pod

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-test-pod
  namespace: ${K8S_NAMESPACE}
spec:
  serviceAccountName: ${K8S_SA_NAME}   # Must reference our annotated SA
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "application"
      effect: "NoSchedule"
  containers:
    - name: test
      image: google/cloud-sdk:slim
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
EOF

# Wait for the pod to be running
kubectl wait pod wi-test-pod -n ${K8S_NAMESPACE} \
  --for=condition=Ready --timeout=120s

kubectl get pod wi-test-pod -n ${K8S_NAMESPACE}
```

### Shell Into the Pod and Verify

```bash
kubectl exec -it wi-test-pod -n ${K8S_NAMESPACE} -- /bin/bash
```

Inside the pod, run these commands:

```bash
# ─── 1. Fetch the raw OAuth2 token from the metadata server ──────────────────
curl -s \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

# Expected JSON response:
# {
#   "access_token": "ya29.c.XXXXXXX...",
#   "expires_in": 3599,
#   "token_type": "Bearer"
# }

# ─── 2. Check which GCP identity this pod has ────────────────────────────────
curl -s \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"

# Expected: app-workload-sa@gke-labs.iam.gserviceaccount.com

# ─── 3. List all service accounts visible to this pod ────────────────────────
curl -s \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/"

# ─── 4. Check using gcloud (uses ADC internally, which uses the metadata server)
gcloud auth list
# Should show: app-workload-sa@gke-labs.iam.gserviceaccount.com

gcloud config list account
# Expected: app-workload-sa@gke-labs.iam.gserviceaccount.com

exit
```

> **If you see your personal account email instead of the SA email**, the Workload Identity
> binding is not working. See Section 7 for debugging steps.

### Verify Via gcloud From Outside

```bash
# Inspect the projected SA token (the K8s token, not the GCP token)
kubectl exec wi-test-pod -n ${K8S_NAMESPACE} -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token | \
  cut -d. -f2 | base64 -d 2>/dev/null | jq .

# Look for "kubernetes.io/serviceaccount/service-account.name" in the payload
# This shows the K8s SA name that gets exchanged for a GCP token
```

---

## 5. Testing GCS Access from a Pod

### Setup: Create a Test Bucket and Grant Access

```bash
# From your local machine (outside the pod)

# Create a test GCS bucket
gsutil mb -p ${PROJECT_ID} -l ${REGION} gs://gke-labs-wi-test-$(date +%s)
export TEST_BUCKET="gke-labs-wi-test-XXXXX"  # Replace with actual bucket name

# Upload a test file
echo "Workload Identity test - $(date)" | gsutil cp - gs://${TEST_BUCKET}/test.txt

# Grant the GCP SA read access to the bucket
gsutil iam ch serviceAccount:${GCP_SA_EMAIL}:objectViewer gs://${TEST_BUCKET}

# Verify the IAM policy
gsutil iam get gs://${TEST_BUCKET}
```

### Test GCS Access From Inside the Pod

```bash
kubectl exec -it wi-test-pod -n ${K8S_NAMESPACE} -- /bin/bash
```

Inside the pod:
```bash
export TEST_BUCKET="gke-labs-wi-test-XXXXX"  # Your bucket name

# ─── Test 1: List bucket contents using gsutil ───────────────────────────────
gsutil ls gs://${TEST_BUCKET}/
# Expected: gs://gke-labs-wi-test-XXXXX/test.txt

# ─── Test 2: Read the file ───────────────────────────────────────────────────
gsutil cat gs://${TEST_BUCKET}/test.txt
# Expected: Workload Identity test - <timestamp>

# ─── Test 3: Try to write (should FAIL — we only granted objectViewer) ───────
echo "unauthorized write test" | gsutil cp - gs://${TEST_BUCKET}/unauthorized.txt
# Expected: AccessDeniedException: 403 Caller does not have permission

# ─── Test 4: Use the GCP Storage API directly with curl ──────────────────────
TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://storage.googleapis.com/storage/v1/b/${TEST_BUCKET}/o/test.txt?alt=media"
# Expected: Workload Identity test - <timestamp>

exit
```

---

## 6. Testing Secret Manager Access from a Pod

### Setup: Create a Test Secret

```bash
# From your local machine

# Grant the GCP SA access to Secret Manager secrets
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --role="roles/secretmanager.secretAccessor" \
  --member="serviceAccount:${GCP_SA_EMAIL}"

# Create a test secret
echo -n "super-secret-db-password-123" | \
  gcloud secrets create wi-test-secret \
    --data-file=- \
    --replication-policy=user-managed \
    --locations=${REGION} \
    --project=${PROJECT_ID}

# Verify the secret exists
gcloud secrets list --project=${PROJECT_ID}
gcloud secrets versions list wi-test-secret --project=${PROJECT_ID}
```

### Test Secret Manager Access From Inside the Pod

```bash
kubectl exec -it wi-test-pod -n ${K8S_NAMESPACE} -- /bin/bash
```

Inside the pod:
```bash
export PROJECT_ID="gke-labs"
export SECRET_NAME="wi-test-secret"
export PROJECT_NUMBER=$(curl -s \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/numeric-project-id")

# ─── Method 1: Using gcloud ──────────────────────────────────────────────────
gcloud secrets versions access latest \
  --secret=${SECRET_NAME} \
  --project=${PROJECT_ID}
# Expected: super-secret-db-password-123

# ─── Method 2: Using the REST API directly ───────────────────────────────────
TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${SECRET_NAME}/versions/latest:access" \
  | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
print(base64.b64decode(data['payload']['data']).decode())
"
# Expected: super-secret-db-password-123

exit
```

---

## 7. Common Mistakes & How to Debug Them

### Mistake 1: Wrong Namespace in the IAM Binding

```bash
# WRONG — wrong namespace in the member string
gcloud iam service-accounts add-iam-policy-binding ${GCP_SA_EMAIL} \
  --member="serviceAccount:gke-labs.svc.id.goog[default/app-workload-sa]"  # ← 'default' is wrong!

# CORRECT — must match the actual pod's namespace
gcloud iam service-accounts add-iam-policy-binding ${GCP_SA_EMAIL} \
  --member="serviceAccount:gke-labs.svc.id.goog[application/app-workload-sa]"
```

**How to spot this:** Token call returns an error like:
```json
{"error": "invalid_grant", "error_description": "...workloadIdentityUser binding not found"}
```

### Mistake 2: Missing or Typo in Annotation

```bash
# Check the annotation
kubectl get serviceaccount app-workload-sa -n application -o yaml

# You should see:
# annotations:
#   iam.gke.io/gcp-service-account: app-workload-sa@gke-labs.iam.gserviceaccount.com

# Common typos:
# iam.gke.io/gcp-sa-name  ← WRONG key name
# iam.gke.io/gcp-service-account: app-workload-sa  ← missing @project.iam.gserviceaccount.com
```

### Mistake 3: Pod Not Using the Annotated K8s SA

```bash
# Check which SA the pod is using
kubectl get pod wi-test-pod -n application -o jsonpath='{.spec.serviceAccountName}'
# Must match the SA that has the annotation

# If using 'default' SA — that's the problem
# Fix: explicitly set serviceAccountName in the pod spec
```

### Mistake 4: Node Pool Not in GKE_METADATA Mode

```bash
# Check the mode
gcloud container node-pools describe application-pool \
  --cluster=gke-lab-cluster \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(config.workloadMetadataConfig.mode)"

# If output is 'EXPOSE_SEND_METADATA' or empty, update it:
gcloud container node-pools update application-pool \
  --cluster=gke-lab-cluster \
  --region=europe-west1 \
  --project=gke-labs \
  --workload-metadata=GKE_METADATA
```

### Debugging Checklist

```bash
# Run this script from your local machine to check everything
check_workload_identity() {
  local K8S_NS=$1
  local K8S_SA=$2
  local GCP_SA=$3

  echo "=== Workload Identity Debug Checklist ==="
  echo ""

  echo "1. Cluster WI pool:"
  gcloud container clusters describe gke-lab-cluster \
    --region=europe-west1 --project=gke-labs \
    --format="value(workloadIdentityConfig.workloadPool)"

  echo ""
  echo "2. K8s SA annotation:"
  kubectl get serviceaccount ${K8S_SA} -n ${K8S_NS} \
    -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
  echo ""

  echo ""
  echo "3. IAM binding on GCP SA:"
  gcloud iam service-accounts get-iam-policy ${GCP_SA} \
    --format="table(bindings.role,bindings.members)"

  echo ""
  echo "4. Node pool metadata mode:"
  gcloud container node-pools list \
    --cluster=gke-lab-cluster \
    --region=europe-west1 \
    --project=gke-labs \
    --format="table(name,config.workloadMetadataConfig.mode)"
}

check_workload_identity "application" "app-workload-sa" \
  "app-workload-sa@gke-labs.iam.gserviceaccount.com"
```

---

## 8. Break-It & Fix-It Exercises

### Exercise 1: Remove the IAM Binding and Watch It Fail

This exercise demonstrates exactly what breaks when the Workload Identity
chain is incomplete.

```bash
# Step 1: Confirm everything works first
kubectl exec wi-test-pod -n ${K8S_NAMESPACE} -- \
  curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
# Expected: app-workload-sa@gke-labs.iam.gserviceaccount.com

# Step 2: Remove the IAM binding
gcloud iam service-accounts remove-iam-policy-binding ${GCP_SA_EMAIL} \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA_NAME}]" \
  --project=${PROJECT_ID}

# Step 3: Wait ~60 seconds for the change to propagate, then test again
sleep 60

kubectl exec wi-test-pod -n ${K8S_NAMESPACE} -- \
  curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

# Expected failure:
# {
#   "error": "invalid_grant",
#   "error_description": "The workloadIdentityUser binding does not exist..."
# }

# Step 4: Try to access GCS — it should now fail
kubectl exec wi-test-pod -n ${K8S_NAMESPACE} -- \
  gsutil ls gs://${TEST_BUCKET}/
# Expected: AccessDeniedException: 403 or ServiceException

# Step 5: Restore the binding
gcloud iam service-accounts add-iam-policy-binding ${GCP_SA_EMAIL} \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA_NAME}]" \
  --project=${PROJECT_ID}

# Step 6: Wait for propagation and verify recovery
sleep 60
kubectl exec wi-test-pod -n ${K8S_NAMESPACE} -- \
  curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
# Expected: app-workload-sa@gke-labs.iam.gserviceaccount.com (restored!)
```

### Exercise 2: Use the Wrong K8s Service Account

```bash
# Create a K8s SA WITHOUT the Workload Identity annotation
kubectl create serviceaccount no-wi-sa -n ${K8S_NAMESPACE}

# Deploy a pod using this SA
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: no-wi-pod
  namespace: ${K8S_NAMESPACE}
spec:
  serviceAccountName: no-wi-sa   # No WI annotation!
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "application"
      effect: "NoSchedule"
  containers:
    - name: test
      image: google/cloud-sdk:slim
      command: ["sleep", "3600"]
EOF

kubectl wait pod no-wi-pod -n ${K8S_NAMESPACE} --for=condition=Ready --timeout=60s

# Test token — you'll get the node's default service account, not your GCP SA!
kubectl exec no-wi-pod -n ${K8S_NAMESPACE} -- \
  curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
# Returns the node's service account (a Compute default SA) — NOT what you want

# Cleanup
kubectl delete pod no-wi-pod -n ${K8S_NAMESPACE}
kubectl delete serviceaccount no-wi-sa -n ${K8S_NAMESPACE}
```

**Lesson:** Always verify the email returned by the metadata server matches your intended GCP SA.

---

## 9. Interview Q&A

---

### Q1: How does Workload Identity prevent credential leakage compared to mounting a JSON key file?

**Answer:**

With a JSON key file approach, the private key is a **long-lived credential** that:
- Exists as a file that can be accidentally committed to Git
- Remains valid for months or indefinitely unless manually rotated
- Works from **anywhere in the world** — stolen keys work outside GCP
- Has no cryptographic binding to the workload that's supposed to use it
- Is replicated everywhere the K8s Secret is used

With Workload Identity:
- **No key file exists anywhere** — there's nothing to leak, commit, or steal
- Tokens are **short-lived** (~1 hour) and automatically refreshed
- Tokens are **cryptographically bound** to the specific pod's identity via the K8s projected ServiceAccount token
- Tokens only work from **within the GKE cluster** — they can't be used externally
- The token exchange happens via the GKE Metadata Server, which validates the pod's K8s identity before issuing a GCP token
- Revoking access is **immediate** — remove the IAM binding and the next token refresh fails

The attack surface difference: with key files, you need to protect a static secret. With Workload Identity, there is no static secret to protect.

---

### Q2: A pod is failing to access GCS. It worked yesterday. How do you debug this?

**Answer:**

```bash
# Step 1: Check the pod is using the right K8s SA
kubectl get pod <pod-name> -n <ns> -o jsonpath='{.spec.serviceAccountName}'

# Step 2: Check the K8s SA has the WI annotation
kubectl get sa <sa-name> -n <ns> -o yaml | grep iam.gke.io

# Step 3: Verify the IAM binding exists
gcloud iam service-accounts get-iam-policy <gcp-sa>@gke-labs.iam.gserviceaccount.com \
  --format="table(bindings.role,bindings.members)"

# Step 4: Check the GCP SA has the correct GCS permissions
gcloud projects get-iam-policy gke-labs \
  --filter="bindings.members:serviceAccount:<gcp-sa>@gke-labs.iam.gserviceaccount.com"

# Step 5: From inside the pod, test the metadata server directly
kubectl exec -it <pod> -n <ns> -- curl -s \
  -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email

# Step 6: Check if someone rotated or removed GCS bucket IAM
gsutil iam get gs://<bucket-name>

# Step 7: Check Cloud Audit Logs for denied access
gcloud logging read \
  'protoPayload.methodName="google.iam.credentials.v1.GenerateAccessToken" AND severity=ERROR' \
  --project=gke-labs --limit=20 --format=json
```

Common causes: IAM binding removed by terraform drift, bucket IAM policy changed, GCP SA deleted and recreated with same name (new SA needs new binding).

---

### Q3: Can you use Workload Identity with a pod running in the `default` namespace?

**Answer:**

Yes — Workload Identity works with any namespace including `default`. The IAM binding member string includes the namespace:

```
serviceAccount:gke-labs.svc.id.goog[default/my-sa]
```

However, it's a security best practice to **avoid using the `default` namespace** in production because:
1. The `default` namespace has no resource quotas by default
2. It's easy to accidentally grant broad permissions to `default`
3. RBAC is harder to scope correctly in `default`
4. Workload Identity bindings in `default` can be confused with test/debug pods

Best practice: use dedicated namespaces per team/service and create separate Workload Identity SAs per service (principle of least privilege).

---

### Q4: What's the difference between `roles/iam.workloadIdentityUser` and `roles/iam.serviceAccountTokenCreator`?

**Answer:**

`roles/iam.workloadIdentityUser`: Allows a Workload Identity Pool identity (like a K8s SA) to **impersonate** the GCP SA via the GKE metadata server. This is what we use in this lab. The token exchange happens automatically inside GKE via the metadata server — the pod itself doesn't need to know it's happening.

`roles/iam.serviceAccountTokenCreator`: Allows a principal to **manually create tokens** for a service account by calling `projects.serviceAccounts.generateAccessToken` on the IAM Credentials API. This is used in **service account impersonation chains** (e.g., SA A generates tokens for SA B), in CI/CD systems (Terraform impersonating a deploy SA), or in Workload Identity Federation for non-GCP environments.

In practice: for GKE Workload Identity use `workloadIdentityUser`. For "SA A needs to act as SA B" use `serviceAccountTokenCreator`.

---

### Q5: How would you audit which pods are using which GCP service accounts?

**Answer:**

```bash
# List all K8s SAs with the WI annotation across all namespaces
kubectl get serviceaccounts -A \
  -o=custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,GCP-SA:.metadata.annotations.iam\.gke\.io/gcp-service-account' \
  | grep -v '<none>'

# Find all pods and their service accounts
kubectl get pods -A \
  -o=custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,SA:.spec.serviceAccountName'

# Use Cloud Audit Logs to see which GCP SA made which API calls
gcloud logging read \
  'protoPayload.authenticationInfo.principalEmail:"@gke-labs.iam.gserviceaccount.com"' \
  --project=gke-labs \
  --limit=50 \
  --format="table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)"
```

For ongoing governance: use **Recommender API** (IAM Insights) to identify GCP SAs with unused permissions, and **Asset Inventory** to track which K8s SAs are bound to which GCP SAs across the organization.
