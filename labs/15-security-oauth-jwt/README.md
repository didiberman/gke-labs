# Lab 15 — Security: OAuth2 / JWT / RBAC

> **Goal:** Build a layered security posture for the payments platform — from how services
> authenticate to each other (OAuth2 Client Credentials + JWT), to how Kubernetes restricts
> what those services can do (RBAC), to how admission controllers prevent misconfiguration
> before it reaches production, to how cert-manager provides mTLS for zero-trust networking.

> **Series position:** Labs 01–14 built a working payments platform. This lab makes it secure.
> Every service-to-service call gets authenticated. Every pod gets least-privilege RBAC.
> Every deployment gets validated against policy before it lands on the cluster.

---

## Table of Contents

1. [OAuth2 Flows — Which One to Use When](#1-oauth2-flows--which-one-to-use-when)
2. [JWT Anatomy — Header, Payload, Signature](#2-jwt-anatomy--header-payload-signature)
3. [Auth Middleware Pattern in Go and Python](#3-auth-middleware-pattern-in-go-and-python)
4. [Kubernetes RBAC — Least Privilege for the Payments SA](#4-kubernetes-rbac--least-privilege-for-the-payments-sa)
5. [Admission Controllers — OPA Gatekeeper and Kyverno](#5-admission-controllers--opa-gatekeeper-and-kyverno)
6. [mTLS with cert-manager](#6-mtls-with-cert-manager)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. OAuth2 Flows — Which One to Use When

### The Four Main Flows

OAuth2 defines four "grant types" for different authentication scenarios:

| Grant Type | Use Case | Involves a User? |
|-----------|----------|-----------------|
| **Authorization Code** | User logs in via browser (web apps, SPAs) | Yes |
| **Authorization Code + PKCE** | User logs in from a mobile app / SPA without a backend secret | Yes |
| **Client Credentials** | Service-to-service authentication (no user involved) | No |
| **Device Code** | CLI tools, smart TVs — user approves on a separate device | Yes |

### Service-to-Service: Client Credentials Flow

For the payments API calling internal services (ledger-service, accounts-service), use
**Client Credentials**. There is no user in the flow — the service itself authenticates.

```
payments-api                     Identity Provider (e.g., GCP IAM, Auth0)
     │                                           │
     │   POST /oauth/token                       │
     │   grant_type=client_credentials           │
     │   client_id=payments-api                  │
     ├──────────────────────────────────────────►│
     │                                           │
     │   { access_token: "eyJ...", expires_in: 3600 }
     │◄──────────────────────────────────────────│
     │
     │   Authorization: Bearer eyJ...
     │   POST /internal/debit
     ├──────────────────────────────────────────► ledger-service
                                                       │
                                                  Validates JWT:
                                                  - Signature valid?
                                                  - Expiry not past?
                                                  - Audience = "ledger-service"?
                                                  - Scope includes "debit"?
```

### Authorization Code Flow (for user-facing APIs)

```
User's Browser              payments-api            Identity Provider
      │                          │                        │
      │  GET /pay                │                        │
      ├─────────────────────────►│                        │
      │                          │                        │
      │  302 Redirect to IdP     │                        │
      │◄─────────────────────────│                        │
      │                                                   │
      │  GET /authorize?client_id=...&redirect_uri=...    │
      ├──────────────────────────────────────────────────►│
      │                                                   │
      │  Login page                                       │
      │◄──────────────────────────────────────────────────│
      │  [user enters credentials]                        │
      │                                                   │
      │  302 redirect to /callback?code=AUTHCODE          │
      │◄──────────────────────────────────────────────────│
      │  GET /callback?code=AUTHCODE                      │
      ├─────────────────────────►│                        │
      │                          │ POST /token            │
      │                          │ code=AUTHCODE          │
      │                          │ client_secret=...      │
      │                          ├───────────────────────►│
      │                          │ { access_token: ... }  │
      │                          │◄───────────────────────│
      │  Set cookie / session    │                        │
      │◄─────────────────────────│
```

### Using GCP Service Account Tokens for Internal Auth

In GKE, services with Workload Identity can use their GCP service account identity as the
authentication token — no external IdP needed for internal calls:

```bash
# Inside a pod with Workload Identity configured, fetch a token for a specific audience
TOKEN=$(curl -sS \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://ledger-service.payments.svc" \
  -H "Metadata-Flavor: Google")

# Use the token in a service call
curl -H "Authorization: Bearer $TOKEN" \
  http://ledger-service.payments:8080/internal/debit
```

---

## 2. JWT Anatomy — Header, Payload, Signature

### The Three Parts

A JWT is `base64url(header) + "." + base64url(payload) + "." + base64url(signature)`.

```
eyJhbGciOiJSUzI1NiIsImtpZCI6ImFiYzEyMyJ9
.
eyJpc3MiOiJodHRwczovL2F1dGguZ2tlLWxhYnMuaW50ZXJuYWwiLCJzdWIiOiJwYXltZW50cy1hcGkiLCJhdWQiOiJsZWRnZXItc2VydmljZSIsImV4cCI6MTcwNTMyNTYwMCwiaWF0IjoxNzA1MzIyMDAwLCJzY29wZSI6InBheW1lbnRzOndyaXRlIGxlZGdlcjp3cml0ZSJ9
.
<signature bytes>
```

Decoded header:
```json
{
  "alg": "RS256",   // Algorithm: RSA + SHA256 (asymmetric — use this for services)
  "kid": "abc123"   // Key ID: which signing key was used (for key rotation)
}
```

Decoded payload:
```json
{
  "iss": "https://auth.gke-labs.internal",  // Issuer: who created this token
  "sub": "payments-api",                    // Subject: who this token represents
  "aud": "ledger-service",                  // Audience: who this token is FOR
  "exp": 1705325600,                        // Expiry: Unix timestamp (must check!)
  "iat": 1705322000,                        // Issued At: when it was created
  "scope": "payments:write ledger:write"    // What actions are allowed
}
```

### Why Asymmetric (RS256) over Symmetric (HS256)?

```
HS256 (symmetric):
  One shared secret key → signs AND verifies
  Problem: every service that verifies tokens KNOWS the signing secret
           → any service can forge tokens for any other service

RS256 (asymmetric):
  Private key → signs tokens (only the IdP has this)
  Public key  → verifies tokens (any service can verify)
  Advantage:  a service being compromised cannot forge tokens
```

### Standard Claims You Must Validate

```go
// Every JWT validator MUST check these — skipping any one is a security hole
func validateJWT(tokenString string, publicKeySet jwk.Set) (*Claims, error) {
    token, err := jwt.Parse(tokenString,
        jwt.WithKeySet(publicKeySet),       // Verify signature with public key
        jwt.WithValidate(true),             // Check exp, iat, nbf
        jwt.WithAudience("ledger-service"), // Reject tokens not intended for us
        jwt.WithIssuer("https://auth.gke-labs.internal"), // Reject tokens from wrong issuer
    )
    if err != nil {
        return nil, fmt.Errorf("invalid token: %w", err)
    }
    return tokenToInternalClaims(token), nil
}
```

| Claim | Must Check | Failure Mode If Skipped |
|-------|-----------|------------------------|
| `exp` | Yes | Stolen tokens work forever |
| `aud` | Yes | Token for service A works on service B |
| `iss` | Yes | Tokens from rogue IdPs accepted |
| `sig` | Yes (via library) | Unsigned tokens accepted — trivial forgery |
| `iat` | Optional | Can't detect pre-issued tokens |

---

## 3. Auth Middleware Pattern in Go and Python

### Go — HTTP Middleware

```go
// middleware/jwt.go
package middleware

import (
    "context"
    "net/http"
    "strings"
    "time"

    "github.com/lestrrat-go/jwx/v2/jwk"
    "github.com/lestrrat-go/jwx/v2/jwt"
)

type contextKey string
const claimsKey contextKey = "jwt_claims"

type JWTMiddleware struct {
    keySet    jwk.Set
    audience  string
    issuer    string
}

// NewJWTMiddleware creates a middleware that fetches JWKS from the IdP automatically
// and rotates keys when new key IDs appear.
func NewJWTMiddleware(jwksURL, audience, issuer string) (*JWTMiddleware, error) {
    cache := jwk.NewCache(context.Background())
    if err := cache.Register(jwksURL, jwk.WithMinRefreshInterval(15*time.Minute)); err != nil {
        return nil, err
    }
    keySet, err := cache.Get(context.Background(), jwksURL)
    if err != nil {
        return nil, err
    }
    return &JWTMiddleware{keySet: keySet, audience: audience, issuer: issuer}, nil
}

func (m *JWTMiddleware) Middleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        authHeader := r.Header.Get("Authorization")
        if !strings.HasPrefix(authHeader, "Bearer ") {
            http.Error(w, "missing or malformed Authorization header", http.StatusUnauthorized)
            return
        }
        tokenStr := strings.TrimPrefix(authHeader, "Bearer ")

        token, err := jwt.Parse([]byte(tokenStr),
            jwt.WithKeySet(m.keySet),
            jwt.WithValidate(true),
            jwt.WithAudience(m.audience),
            jwt.WithIssuer(m.issuer),
        )
        if err != nil {
            http.Error(w, "invalid token: "+err.Error(), http.StatusUnauthorized)
            return
        }

        // Store claims in request context for downstream handlers
        ctx := context.WithValue(r.Context(), claimsKey, token)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// Usage in main.go:
// jwtMiddleware, _ := middleware.NewJWTMiddleware(
//     "https://auth.gke-labs.internal/.well-known/jwks.json",
//     "payments-api",
//     "https://auth.gke-labs.internal",
// )
// mux.Handle("/api/payments", jwtMiddleware.Middleware(paymentsHandler))
```

### Python — FastAPI Dependency

```python
# auth/jwt_validator.py
from typing import Annotated
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import jwt
from jwt import PyJWKClient

JWKS_URL = "https://auth.gke-labs.internal/.well-known/jwks.json"
AUDIENCE = "payments-api"
ISSUER   = "https://auth.gke-labs.internal"

# PyJWKClient handles key fetching and caching automatically
jwks_client = PyJWKClient(JWKS_URL, cache_keys=True, max_cached_keys=16)
security     = HTTPBearer()

def verify_jwt(credentials: Annotated[HTTPAuthorizationCredentials, Depends(security)]):
    """FastAPI dependency — use in route handler with Depends(verify_jwt)."""
    token = credentials.credentials
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=AUDIENCE,
            issuer=ISSUER,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
        )
        return payload
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Token has expired")
    except jwt.InvalidAudienceError:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                            detail="Token audience mismatch")
    except jwt.InvalidTokenError as e:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail=f"Invalid token: {e}")

# Usage in routes:
# @app.post("/payments")
# async def create_payment(body: PaymentRequest, claims = Depends(verify_jwt)):
#     sub = claims["sub"]  # The calling service's identity
```

### Scope-Based Authorization

After validating the JWT signature and claims, check that the caller has the required scope:

```go
// Check scope after JWT validation
func requireScope(required string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            token := r.Context().Value(claimsKey).(jwt.Token)
            scopeClaim, ok := token.Get("scope")
            if !ok {
                http.Error(w, "token has no scope claim", http.StatusForbidden)
                return
            }
            scopes := strings.Fields(scopeClaim.(string))
            for _, s := range scopes {
                if s == required {
                    next.ServeHTTP(w, r)
                    return
                }
            }
            http.Error(w, "insufficient scope: requires "+required, http.StatusForbidden)
        })
    }
}
// Usage: mux.Handle("/api/payments/debit", jwtMiddleware.Middleware(requireScope("payments:write")(debitHandler)))
```

---

## 4. Kubernetes RBAC — Least Privilege for the Payments SA

### RBAC Concepts

```
ClusterRole   = set of permissions that apply cluster-wide (or as a template)
Role          = set of permissions scoped to ONE namespace
RoleBinding   = bind a Role (or ClusterRole) to a ServiceAccount within a namespace
ClusterRoleBinding = bind a ClusterRole to a SA cluster-wide
```

### What the Payments SA Needs

The payments-api service account needs exactly:
- Read Secrets in the `payments` namespace (DB credentials)
- No cluster-wide access
- No ability to create/delete pods or deployments

```yaml
# k8s/payments-rbac.yaml

# --- ServiceAccount ---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api-sa
  namespace: payments
  annotations:
    # Workload Identity: this K8s SA maps to the GCP SA
    iam.gke.io/gcp-service-account: payments-api@gke-labs.iam.gserviceaccount.com

---
# --- Role: minimal permissions for the payments namespace ---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payments-api-role
  namespace: payments
rules:
  # Read Secrets (to fetch DB credentials from Kubernetes secrets)
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames:
      - "payments-db-credentials"   # Lock down to a specific secret, not all secrets
      - "payments-api-tls"

  # Read ConfigMaps (for runtime config)
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
    resourceNames:
      - "payments-api-config"

---
# --- RoleBinding: attach the Role to the ServiceAccount ---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-api-rolebinding
  namespace: payments
subjects:
  - kind: ServiceAccount
    name: payments-api-sa
    namespace: payments
roleRef:
  kind: Role
  name: payments-api-role
  apiGroup: rbac.authorization.k8s.io
```

### Verify RBAC with `kubectl auth can-i`

```bash
# Can payments-api-sa read secrets in the payments namespace?
kubectl auth can-i get secret \
  --namespace=payments \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected: yes

# Can it list ALL secrets?
kubectl auth can-i list secret \
  --namespace=payments \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected: no (we only granted 'get', not 'list')

# Can it touch anything in kube-system?
kubectl auth can-i get secret \
  --namespace=kube-system \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected: no

# Can it create pods anywhere?
kubectl auth can-i create pods \
  --all-namespaces \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected: no

# Audit what a SA can do across all resources
kubectl auth can-i --list \
  --namespace=payments \
  --as=system:serviceaccount:payments:payments-api-sa
```

### Avoid the `cluster-admin` Trap

A common mistake is attaching `cluster-admin` to a service account to "make it work quickly":

```bash
# NEVER do this in production:
kubectl create clusterrolebinding payments-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=payments:payments-api-sa

# If payments-api is compromised, the attacker now has:
# - Full read/write to all secrets (including other teams' DB passwords)
# - Ability to create privileged pods
# - Ability to modify RBAC rules to expand their own access
# - Ability to exfiltrate data from any namespace
```

---

## 5. Admission Controllers — OPA Gatekeeper and Kyverno

### What Admission Controllers Do

Admission controllers intercept API Server requests (kubectl apply, helm install) **before**
resources are persisted to etcd. They can:
- **Validate**: reject requests that violate policy
- **Mutate**: automatically inject sidecar containers, add labels, set defaults

```
kubectl apply -f payment-deployment.yaml
        │
        ▼
  kube-apiserver
        │
        ├──► Authentication (is this user/SA who they say they are?)
        │
        ├──► Authorization (is this user/SA allowed to create deployments in 'payments'?)
        │
        ├──► Mutating Admission Webhooks (e.g., inject Istio sidecar, add resource defaults)
        │        [Kyverno mutate policies run here]
        │
        ├──► Schema Validation (is the YAML valid Kubernetes?)
        │
        ├──► Validating Admission Webhooks (e.g., enforce policy)
        │        [OPA Gatekeeper / Kyverno validate policies run here]
        │        REJECT if any policy fails ← resource never reaches etcd
        │
        └──► Persisted to etcd ✅
```

### Kyverno — Kubernetes-Native Policy Engine

Kyverno policies are Kubernetes resources (no Rego to learn). They're easier to adopt:

```bash
# Install Kyverno
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set replicaCount=3

kubectl get pods -n kyverno
```

**Policy: Require resource requests and limits on all pods in the payments namespace:**

```yaml
# policies/require-resource-limits.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
  annotations:
    policies.kyverno.io/title: Require Resource Limits
    policies.kyverno.io/description: >
      Enforce that all containers in the payments namespace have
      CPU and memory requests and limits set.
spec:
  validationFailureAction: Enforce   # Enforce = reject. Audit = warn but allow.
  background: true                   # Also validate existing resources
  rules:
    - name: require-limits-payments
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments"]
      validate:
        message: "CPU and memory requests/limits are required for all containers in the payments namespace."
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
                    cpu: "?*"
```

**Policy: Disallow privileged containers:**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-privileged
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            =(initContainers):
              - =(securityContext):
                  =(privileged): "false"
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

**Policy: Auto-inject team label (mutating):**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
    - name: add-team-label-payments
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments"]
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              team: payments   # Injected automatically — every pod gets this
```

### Test Policies Before Enforcing

```bash
# Apply policy in Audit mode first (validationFailureAction: Audit)
# Then check violations without blocking anything
kubectl get policyreport -n payments

# Or use kyverno CLI to test against a manifest before applying
kyverno apply policies/require-resource-limits.yaml \
  --resource k8s/payments-deployment.yaml
# Output: pass: 1, fail: 0, warn: 0, error: 0, skip: 0
```

---

## 6. mTLS with cert-manager

### What mTLS Solves

Regular TLS (one-way): client verifies the server's certificate. The server doesn't know who
the client is. Any pod in the cluster could call the ledger-service pretending to be payments-api.

mTLS (mutual TLS): both sides verify each other's certificates. The ledger-service rejects
any caller that doesn't present a valid certificate signed by the cluster's own CA. No JWT needed —
the certificate *is* the authentication.

```
payments-api                          ledger-service
     │                                      │
     │  ClientHello (start TLS)             │
     ├─────────────────────────────────────►│
     │                                      │
     │  ServerHello + server cert           │
     │◄─────────────────────────────────────│
     │                                      │
     │  Client cert (signed by cluster CA)  │
     ├─────────────────────────────────────►│
     │                                      │  Verifies: cert signed by cluster CA?
     │                                      │            CN = "payments-api"?
     │                                      │            Not expired?
     │  Encrypted channel established ✅    │
     │◄─────────────────────────────────────│
```

### Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --set global.leaderElection.namespace=cert-manager

kubectl get pods -n cert-manager
# cert-manager-*         1/1 Running
# cert-manager-cainjector-*  1/1 Running
# cert-manager-webhook-*     1/1 Running
```

### Create a Cluster CA

```yaml
# cert-manager/cluster-ca-issuer.yaml
# Step 1: Create a self-signed issuer to bootstrap the CA cert
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}

---
# Step 2: Create the cluster CA certificate
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cluster-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: gke-labs-cluster-ca
  secretName: cluster-ca-secret
  duration: 87600h    # 10 years for the CA
  renewBefore: 720h   # Renew 30 days before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer

---
# Step 3: Create the CA Issuer using the CA cert
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cluster-ca-issuer
spec:
  ca:
    secretName: cluster-ca-secret
```

### Issue Service Certificates

```yaml
# k8s/payments-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: payments-api-tls
  namespace: payments
spec:
  secretName: payments-api-tls    # cert-manager creates this Secret
  duration: 2160h                  # 90 days
  renewBefore: 360h               # Renew 15 days before expiry — zero downtime
  commonName: payments-api.payments.svc.cluster.local
  dnsNames:
    - payments-api
    - payments-api.payments
    - payments-api.payments.svc
    - payments-api.payments.svc.cluster.local
  issuerRef:
    name: cluster-ca-issuer
    kind: ClusterIssuer
  usages:
    - digital signature
    - key encipherment
    - client auth    # This cert can be used as a CLIENT cert in mTLS
    - server auth    # And as a SERVER cert
```

### Mount the Certificate in the Pod

```yaml
# In the payments-api Deployment:
spec:
  template:
    spec:
      volumes:
        - name: tls-certs
          secret:
            secretName: payments-api-tls    # Created by cert-manager
      containers:
        - name: payments-api
          volumeMounts:
            - name: tls-certs
              mountPath: /etc/tls
              readOnly: true
          env:
            - name: TLS_CERT_FILE
              value: /etc/tls/tls.crt
            - name: TLS_KEY_FILE
              value: /etc/tls/tls.key
            - name: CA_CERT_FILE
              value: /etc/tls/ca.crt
```

### Verify Certificate Rotation

```bash
# Check certificate status
kubectl get certificate -n payments
# NAME               READY   SECRET               AGE
# payments-api-tls   True    payments-api-tls     2d

# Check when it expires and when it will auto-renew
kubectl describe certificate payments-api-tls -n payments
# Renewal Time: 2024-04-01T00:00:00Z
# Not After:    2024-04-16T00:00:00Z

# Watch cert-manager automatically renew before expiry
kubectl logs -n cert-manager deployment/cert-manager --tail=50 | grep -i "renew\|certificate"
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1 — Privilege Escalation via RBAC Misconfiguration

**Goal:** Understand how over-permissive RBAC leads to privilege escalation.

```bash
# === BREAK IT ===
# Grant the payments SA access to list all secrets cluster-wide (dangerous!)
kubectl create clusterrolebinding payments-secret-reader-bad \
  --clusterrole=view \
  --serviceaccount=payments:payments-api-sa

# === OBSERVE THE PROBLEM ===
# The 'view' ClusterRole allows listing secrets across all namespaces
kubectl auth can-i list secrets \
  --all-namespaces \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected (BAD): yes

# A compromised payments-api can now read secrets from other teams
kubectl get secrets --all-namespaces \
  --as=system:serviceaccount:payments:payments-api-sa
# This reveals ALL secrets: Grafana passwords, other teams' DB credentials, etc.

# === FIX IT ===
# Remove the overly-permissive binding
kubectl delete clusterrolebinding payments-secret-reader-bad

# Verify it's gone
kubectl auth can-i list secrets \
  --all-namespaces \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected (GOOD): no

# Apply the correct minimal RBAC
kubectl apply -f k8s/payments-rbac.yaml

# Verify the minimal permissions work
kubectl auth can-i get secret payments-db-credentials \
  --namespace=payments \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected: yes

kubectl auth can-i get secret grafana-admin-password \
  --namespace=monitoring \
  --as=system:serviceaccount:payments:payments-api-sa
# Expected: no
```

---

### Exercise 2 — Bypass a Kyverno Policy

**Goal:** Understand what happens when a policy is in Audit vs Enforce mode, and why staging tests matter.

```bash
# === SETUP — Enforce mode ===
kubectl apply -f policies/require-resource-limits.yaml
# validationFailureAction: Enforce

# === BREAK IT — Try to deploy without resource limits ===
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-limits-test
  namespace: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: no-limits-test
  template:
    metadata:
      labels:
        app: no-limits-test
    spec:
      containers:
        - name: nginx
          image: nginx:latest
          # No resources block — should be REJECTED
EOF

# Expected output:
# Error from server: admission webhook "validate.kyverno.svc" denied the request:
# CPU and memory requests/limits are required for all containers in the payments namespace.

# === FIX IT — Add resource limits ===
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-limits-test
  namespace: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: no-limits-test
  template:
    metadata:
      labels:
        app: no-limits-test
    spec:
      containers:
        - name: nginx
          image: nginx:latest
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
EOF

# Should succeed now
kubectl get deployment no-limits-test -n payments

# Cleanup
kubectl delete deployment no-limits-test -n payments
```

---

### Exercise 3 — Verify JWT Validation Rejects Expired Tokens

```bash
# Generate an expired JWT (exp in the past)
# Use jwt.io or the python snippet below to create a test token
python3 - <<'EOF'
import jwt, time, datetime

# This is a test key — use real RSA keys in production
payload = {
    "iss": "https://auth.gke-labs.internal",
    "sub": "payments-api",
    "aud": "ledger-service",
    "exp": int(time.time()) - 3600,  # Expired 1 hour ago
    "iat": int(time.time()) - 7200,
    "scope": "ledger:write",
}
# Note: using HS256 for this test — real production should use RS256
token = jwt.encode(payload, "test-secret-key", algorithm="HS256")
print("Expired token:", token)
EOF

# Try to use the expired token against the payments API
EXPIRED_TOKEN="<paste token from above>"
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $EXPIRED_TOKEN" \
  http://localhost:8080/api/payments
# Expected: 401

# Generate a valid token and verify it works
python3 - <<'EOF'
import jwt, time
payload = {
    "iss": "https://auth.gke-labs.internal",
    "sub": "payments-api",
    "aud": "payments-api",
    "exp": int(time.time()) + 3600,  # Valid for 1 hour
    "iat": int(time.time()),
    "scope": "payments:write",
}
token = jwt.encode(payload, "test-secret-key", algorithm="HS256")
print("Valid token:", token)
EOF
```

---

## 8. Interview Q&A

---

### Q1: When should a service use OAuth2 Client Credentials vs mTLS for authenticating to another service?

**Answer:**

Both solve the same problem — proving identity in service-to-service calls — but they operate
at different layers and have different operational tradeoffs.

**Client Credentials (OAuth2/JWT):**
- Authentication is at the **application layer** (HTTP header)
- Works across networks, clouds, and different clusters
- Requires an Identity Provider to issue and validate tokens
- Easy to add fine-grained authorization (scopes, claims)
- Token expiry is short-lived — compromise window is limited

**mTLS (cert-manager / Istio):**
- Authentication is at the **transport layer** (TLS handshake)
- Implemented by the infrastructure, not the application code
- Works even for non-HTTP protocols (gRPC, raw TCP)
- Certificate rotation is automatic (cert-manager)
- No application code changes needed if using a service mesh

**In practice:** use **mTLS as the baseline** for all in-cluster service communication (zero-trust
networking — a compromised pod can't impersonate another service). Add **JWT/OAuth2 on top** for
fine-grained authorization (this service can call the debit endpoint but not the delete endpoint).
The two are complementary, not mutually exclusive.

---

### Q2: What is the `aud` (audience) claim in a JWT and what attack does it prevent?

**Answer:**

The `aud` claim specifies which service or resource the token is intended for.

**The attack it prevents: token forwarding / confused deputy.**

Without `aud` validation: an attacker who intercepts a valid token issued for `ledger-service`
could replay it against `accounts-service`, `admin-service`, or any other service. The token
is valid (signature checks out, not expired) but was never meant for those services.

With `aud` validation: `ledger-service` only accepts tokens where `aud == "ledger-service"`.
A token for `accounts-service` is rejected even if it's otherwise valid.

**Implementation note:** the audience check must be explicit in your validation code:
```go
jwt.WithAudience("ledger-service")  // Go: reject if aud doesn't match
```
Many JWT libraries validate the signature but NOT the audience by default. You must opt in.

---

### Q3: Explain the difference between ClusterRole and Role in Kubernetes RBAC. When would you use each?

**Answer:**

**Role** — scoped to a single namespace. A Role in namespace `payments` cannot grant permissions
in namespace `monitoring`. Use for application service accounts that should only access
resources in their own namespace. This is the default choice for microservices.

**ClusterRole** — cluster-wide scope. Can grant permissions on:
- Cluster-scoped resources (Nodes, PersistentVolumes, ClusterRoles themselves)
- Namespace-scoped resources in *any* namespace
- Non-resource URLs (e.g., `/healthz`)

Use ClusterRole for: cluster-level operators (cert-manager, Prometheus Operator), monitoring
agents (node-exporter needs to read node metrics), and platform infrastructure that legitimately
spans namespaces.

**The RoleBinding/ClusterRoleBinding distinction:**
- `RoleBinding` + `ClusterRole` → grants the ClusterRole's permissions *only in that namespace*
  (useful for templating: define once as ClusterRole, bind per-namespace as RoleBinding)
- `ClusterRoleBinding` + `ClusterRole` → truly cluster-wide

```
Most secure (right to left preference):
  Role + RoleBinding        → namespace-scoped (preferred for apps)
  ClusterRole + RoleBinding → namespace-scoped (useful for templates)
  ClusterRole + ClusterRoleBinding → cluster-wide (minimize use)
```

---

### Q4: An engineer accidentally committed a Kubernetes Secret YAML to Git. What do you do?

**Answer:**

Treat the secret as compromised regardless of who has access to the repository. The exposure
window started at the time of the commit, not when it was discovered.

**Immediate response (first 30 minutes):**
```bash
# 1. Rotate the compromised credential immediately
# (change DB password, regenerate API key, etc.)

# 2. Delete and recreate the Kubernetes Secret with the new value
kubectl delete secret payments-db-credentials -n payments
kubectl create secret generic payments-db-credentials \
  --from-literal=password='new-strong-password' \
  -n payments

# 3. Roll out the payments-api to pick up the new secret
kubectl rollout restart deployment/payments-api -n payments
```

**Git cleanup (prevents future access but doesn't un-expose what's already been seen):**
```bash
# Remove from Git history using git-filter-repo (preferred over BFG)
git filter-repo --path k8s/payments-db-secret.yaml --invert-paths
# Or remove a specific string pattern:
git filter-repo --replace-text <(echo 'REPLACE_PASSWORD==>REMOVED')
git push --force-with-lease  # Force push to all branches
```

**Prevent recurrence:**
- Add `*.yaml` with secrets to `.gitignore` and use pre-commit hooks to scan for secrets
- Use `git-secrets`, `detect-secrets`, or `gitleaks` in CI to block commits with credentials
- Move to External Secrets Operator — secrets live in GCP Secret Manager, never in Git
- Add a GitHub Actions check: `gitleaks scan --source . --verbose`

---

### Q5: What is an OPA Gatekeeper ConstraintTemplate and how does it differ from Kyverno?

**Answer:**

**OPA Gatekeeper** uses the **Rego** policy language. A `ConstraintTemplate` defines a new
Kubernetes CRD (the constraint type) and the Rego logic that implements it. A `Constraint`
is an instance of that template with specific parameters.

```
ConstraintTemplate → defines the schema and Rego logic → creates a CRD
Constraint          → instance of the template with parameters → applies the rule
```

**Kyverno** uses YAML patterns — policies are Kubernetes resources written in the same YAML
syntax engineers already know. No new language to learn.

| Aspect | OPA Gatekeeper | Kyverno |
|--------|---------------|---------|
| Policy language | Rego (Datalog-inspired) | YAML patterns |
| Learning curve | High (Rego is complex) | Low |
| Expressiveness | Very high | High |
| Mutating policies | Via separate mutation webhooks | Native |
| Ecosystem maturity | Older, large community | Newer, growing fast |
| Testing tooling | OPA CLI, conftest | Kyverno CLI |

For most teams, Kyverno is the pragmatic choice — the policies are readable to any engineer who
knows Kubernetes YAML. Gatekeeper is worth the investment when you need very complex policy logic
that would be unreadable in YAML (e.g., cross-resource validation referencing data from multiple
objects simultaneously).

---

### Q6: How does cert-manager handle certificate rotation without service downtime?

**Answer:**

cert-manager rotates certificates automatically before they expire by setting `renewBefore` in the
Certificate resource (typically 15–30% of the certificate lifetime before expiry).

The rotation process:
1. cert-manager detects the certificate will expire within `renewBefore` time
2. It requests a new certificate from the Issuer (re-signing the CSR)
3. The new certificate is written to the **same Secret** — but the old cert is kept alongside
   the new one temporarily (graceful overlap period)
4. Applications watching the Secret via volume mounts see the update immediately —
   Kubernetes re-mounts the Secret content without a pod restart

**For zero downtime with your application code:**
- Load the certificate from disk at the start of each TLS connection, not at startup
- Or use a file watcher to reload the cert when the secret changes
- Go's `tls.Config.GetCertificate` callback re-reads the certificate on each new TLS handshake —
  no restart needed

```go
// Go: reload cert on each new TLS handshake — survives cert-manager rotation
tlsConfig := &tls.Config{
    GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
        cert, err := tls.LoadX509KeyPair("/etc/tls/tls.crt", "/etc/tls/tls.key")
        return &cert, err
    },
}
```

---

*Next: [Lab 16 — Cloud SQL Operations](../16-cloud-sql-ops/README.md)*
