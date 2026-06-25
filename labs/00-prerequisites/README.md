# Lab 00 — Prerequisites & Environment Setup

> **Goal:** Get every tool installed, authenticated, and verified before touching a single GKE resource.
> A broken environment wastes hours. A clean one lets you focus on learning.

---

## Table of Contents

1. [Required Tools & Versions](#1-required-tools--versions)
2. [GCP Account & Project Setup](#2-gcp-account--project-setup)
3. [Authentication Deep Dive](#3-authentication-deep-dive)
4. [Running setup-gcp.sh](#4-running-setup-gcpsh)
5. [Verify Everything Works](#5-verify-everything-works)
6. [kubectl Aliases & Productivity Tips](#6-kubectl-aliases--productivity-tips)
7. [Recommended VS Code Extensions](#7-recommended-vs-code-extensions)
8. [k9s Cheatsheet](#8-k9s-cheatsheet)
9. [Break-It & Fix-It Exercises](#9-break-it--fix-it-exercises)
10. [Interview Q&A](#10-interview-qa)

---

## 1. Required Tools & Versions

| Tool | Minimum Version | Purpose | Install |
|------|----------------|---------|---------|
| `gcloud` CLI | 460.0.0+ | GCP API gateway | [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) |
| `kubectl` | 1.29+ | Kubernetes API client | `gcloud components install kubectl` |
| `helm` | 3.14+ | Package manager for K8s | `brew install helm` |
| `terraform` | 1.7+ | Infrastructure as Code | `brew install terraform` |
| `k9s` | 0.31+ | Terminal UI for K8s | `brew install k9s` |
| `kubectx` / `kubens` | 0.9.5+ | Fast context/namespace switching | `brew install kubectx` |
| `jq` | 1.7+ | JSON processor | `brew install jq` |
| `psql` | 14+ | PostgreSQL client (Cloud SQL labs) | `brew install libpq` |
| `redis-cli` | 7.0+ | Redis client (Memorystore labs) | `brew install redis` |

### Install All at Once (macOS)

```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install all required tools
brew install \
  helm \
  terraform \
  k9s \
  kubectx \
  jq \
  libpq \
  redis

# Add psql to PATH (libpq formula is keg-only)
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Install Google Cloud SDK (if not already installed)
brew install --cask google-cloud-sdk

# Install kubectl via gcloud
gcloud components install kubectl gke-gcloud-auth-plugin
```

### Install All at Once (Linux / Cloud Shell)

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# k9s
wget https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar xzf k9s_Linux_amd64.tar.gz && sudo mv k9s /usr/local/bin/

# kubectx + kubens
sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

### Verify Versions

```bash
gcloud version
kubectl version --client
helm version
terraform version
k9s version
kubectx --version
jq --version
psql --version
redis-cli --version
```

Expected output (versions may be newer):
```
Google Cloud SDK 473.0.0
kubectl: v1.29.3
helm version.BuildInfo{Version:"v3.14.2"}
Terraform v1.7.4
v0.31.7
0.9.5
jq-1.7.1
psql (PostgreSQL) 15.4
Redis server v=7.2.4
```

---

## 2. GCP Account & Project Setup

### Enable Required APIs

The lab uses the following GCP APIs. Enable them all upfront to avoid surprises:

```bash
export PROJECT_ID="gke-labs"
export REGION="europe-west1"

gcloud config set project ${PROJECT_ID}
gcloud config set compute/region ${REGION}

# Enable all required APIs in one shot
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  redis.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicenetworking.googleapis.com \
  dns.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  cloudtrace.googleapis.com \
  artifactregistry.googleapis.com \
  --project=${PROJECT_ID}

echo "APIs enabled successfully"
```

### Verify APIs Are Enabled

```bash
gcloud services list --enabled --project=${PROJECT_ID} \
  --filter="name:(container OR sqladmin OR redis OR secretmanager)" \
  --format="table(name,state)"
```

Expected output:
```
NAME                                    STATE
container.googleapis.com                ENABLED
redis.googleapis.com                    ENABLED
secretmanager.googleapis.com            ENABLED
sqladmin.googleapis.com                 ENABLED
```

### Set Permanent gcloud Configuration

```bash
# Create a named configuration for this lab (keeps your existing config intact)
gcloud config configurations create gke-labs
gcloud config set project gke-labs
gcloud config set compute/region europe-west1
gcloud config set compute/zone europe-west1-b

# Verify active configuration
gcloud config list
```

---

## 3. Authentication Deep Dive

This is the most important concept to understand before proceeding. There are **two completely different authentication flows** in gcloud.

### The Difference Explained

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   gcloud auth login                   gcloud auth application-default login│
│   ──────────────────                  ────────────────────────────────────  │
│                                                                             │
│   WHO: YOU (a human)                  WHO: YOUR CODE / TOOLS               │
│                                                                             │
│   USED BY:                            USED BY:                             │
│   • gcloud CLI commands               • Terraform                          │
│   • gcloud compute ssh                • Google Cloud client libraries      │
│   • gcloud container clusters         • Any SDK using ADC                  │
│                                       • kubectl (via plugin)               │
│                                                                             │
│   STORED AT:                          STORED AT:                           │
│   ~/.config/gcloud/credentials.db     ~/.config/gcloud/application_        │
│                                       default_credentials.json             │
│                                                                             │
│   QUOTA/BILLING:                      QUOTA/BILLING:                       │
│   Attributed to your user             Attributed to your user (local)      │
│                                       or to the service account (CI/CD)    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Step 1: Login as a Human User

```bash
# Opens a browser window — authenticate with your Google account
gcloud auth login

# Verify who you're logged in as
gcloud auth list
```

Expected output:
```
  Credentialed Accounts
ACTIVE  ACCOUNT
*       your-email@example.com

To set the active account, run:
    $ gcloud config set account `ACCOUNT`
```

### Step 2: Set Application Default Credentials (ADC)

```bash
# This creates ~/.config/gcloud/application_default_credentials.json
# Terraform, kubectl, and the GCP SDKs will use this automatically
gcloud auth application-default login

# Verify ADC is set
gcloud auth application-default print-access-token | head -c 20
echo "..."  # Token exists — truncated for display
```

### Step 3: Configure kubectl

After the GKE cluster is created, configure kubectl to connect to it:

```bash
# Fetch credentials for the GKE cluster (creates/updates ~/.kube/config)
gcloud container clusters get-credentials gke-lab-cluster \
  --region=${REGION} \
  --project=${PROJECT_ID}

# Verify kubectl is talking to your cluster
kubectl cluster-info
kubectl get nodes
```

> **Important:** The `gke-gcloud-auth-plugin` must be installed for modern GKE auth.
> If you see "exec plugin is configured to use API version", run:
> `gcloud components install gke-gcloud-auth-plugin`

### Understanding Application Default Credentials (ADC)

ADC is a strategy that allows your code to find credentials automatically
without hardcoding them. The lookup order is:

```
1. GOOGLE_APPLICATION_CREDENTIALS env var (points to a JSON key file)
   └─ Used in CI/CD pipelines with service account keys (avoid in prod!)

2. gcloud Application Default Credentials
   └─ ~/.config/gcloud/application_default_credentials.json
   └─ Used during local development (what we set above)

3. Attached Service Account (Metadata Server)
   └─ Used when running ON GCP (GCE, GKE, Cloud Run, etc.)
   └─ No key files needed — this is Workload Identity territory
```

---

## 4. Running setup-gcp.sh

The `setup-gcp.sh` script bootstraps the GCP project with everything Terraform needs:

```bash
# From the repo root
cd /path/to/gke-labs

# Review what the script will do before running it
cat scripts/setup-gcp.sh

# Run the bootstrap script
chmod +x scripts/setup-gcp.sh
./scripts/setup-gcp.sh
```

The script performs these actions:
1. Enables all required GCP APIs
2. Creates a Terraform state GCS bucket (`gs://gke-labs-terraform-state`)
3. Creates a Terraform service account with required IAM roles
4. Outputs the service account key path for CI/CD (but we use ADC locally)

### Verify Bootstrap Completed

```bash
# Terraform state bucket exists
gsutil ls gs://gke-labs-terraform-state/

# Terraform service account exists
gcloud iam service-accounts list \
  --filter="email:terraform@gke-labs.iam.gserviceaccount.com" \
  --project=${PROJECT_ID}
```

---

## 5. Verify Everything Works

Run this end-to-end verification checklist. Every command should succeed:

```bash
#!/bin/bash
# Save this as scripts/verify-prereqs.sh and run it
set -e

echo "=== GKE Labs Prerequisites Verification ==="
echo ""

check() {
  echo -n "Checking $1... "
  if eval "$2" &>/dev/null; then
    echo "✅ OK"
  else
    echo "❌ FAILED — $3"
  fi
}

# Tool checks
check "gcloud"    "gcloud version"                         "Install Google Cloud SDK"
check "kubectl"   "kubectl version --client"               "Run: gcloud components install kubectl"
check "helm"      "helm version"                           "Run: brew install helm"
check "terraform" "terraform version"                      "Run: brew install terraform"
check "k9s"       "k9s version"                            "Run: brew install k9s"
check "kubectx"   "kubectx --version"                      "Run: brew install kubectx"
check "jq"        "jq --version"                           "Run: brew install jq"
check "psql"      "psql --version"                         "Run: brew install libpq"
check "redis-cli" "redis-cli --version"                    "Run: brew install redis"

echo ""
# Auth checks
check "gcloud auth"    "gcloud auth list 2>&1 | grep -q ACTIVE"             "Run: gcloud auth login"
check "ADC set"        "gcloud auth application-default print-access-token" "Run: gcloud auth application-default login"

echo ""
# GCP project checks
check "project set"    "gcloud config get project | grep -q gke-labs"       "Run: gcloud config set project gke-labs"
check "region set"     "gcloud config get compute/region | grep -q europe-west1" "Run: gcloud config set compute/region europe-west1"

echo ""
echo "=== Verification Complete ==="
```

```bash
chmod +x scripts/verify-prereqs.sh
./scripts/verify-prereqs.sh
```

---

## 6. kubectl Aliases & Productivity Tips

Add these to your `~/.zshrc` or `~/.bashrc`:

```bash
# ─── Core kubectl alias ───────────────────────────────────────────────────────
alias k='kubectl'
alias kk='kubectl -n kube-system'   # quickly inspect system namespace

# ─── Context & Namespace ──────────────────────────────────────────────────────
alias kx='kubectx'                  # switch clusters
alias kns='kubens'                  # switch namespaces
alias kctx='kubectl config current-context'
alias kns-list='kubectl get namespaces'

# ─── Get resources ────────────────────────────────────────────────────────────
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'             # all namespaces
alias kgpw='kubectl get pods -w'             # watch mode
alias kgd='kubectl get deployments'
alias kgs='kubectl get services'
alias kgn='kubectl get nodes'
alias kge='kubectl get events --sort-by=.lastTimestamp'
alias kgea='kubectl get events -A --sort-by=.lastTimestamp'

# ─── Describe ─────────────────────────────────────────────────────────────────
alias kdp='kubectl describe pod'
alias kdd='kubectl describe deployment'
alias kdn='kubectl describe node'

# ─── Logs ─────────────────────────────────────────────────────────────────────
alias kl='kubectl logs'
alias klf='kubectl logs -f'                  # follow
alias klp='kubectl logs -f --previous'       # crashed container

# ─── Apply / Delete ───────────────────────────────────────────────────────────
alias kaf='kubectl apply -f'
alias kdf='kubectl delete -f'
alias kdel='kubectl delete'

# ─── Exec ─────────────────────────────────────────────────────────────────────
alias kex='kubectl exec -it'
alias kesh='kubectl exec -it -- /bin/sh'

# ─── Rollout ──────────────────────────────────────────────────────────────────
alias krr='kubectl rollout restart deployment'
alias krs='kubectl rollout status deployment'

# ─── Port-forward ─────────────────────────────────────────────────────────────
alias kpf='kubectl port-forward'

# ─── Namespace shortcuts ──────────────────────────────────────────────────────
alias kgp-app='kubectl get pods -n application'
alias kgp-sys='kubectl get pods -n kube-system'

# ─── Useful functions ─────────────────────────────────────────────────────────

# Shell into a pod by partial name match
kshell() {
  local ns=${2:-default}
  local pod=$(kubectl get pods -n "$ns" --no-headers | grep "$1" | head -1 | awk '{print $1}')
  echo "Connecting to pod: $pod"
  kubectl exec -it "$pod" -n "$ns" -- /bin/sh
}

# Tail logs by partial pod name
ktail() {
  local ns=${2:-default}
  local pod=$(kubectl get pods -n "$ns" --no-headers | grep "$1" | head -1 | awk '{print $1}')
  echo "Following logs for pod: $pod"
  kubectl logs -f "$pod" -n "$ns"
}

# Get all resources in a namespace
kall() {
  kubectl get all -n "${1:-default}"
}

# Watch pods in a namespace
kwatch() {
  watch -n 2 "kubectl get pods -n ${1:-default} -o wide"
}
```

Reload your shell:
```bash
source ~/.zshrc
```

### Enable kubectl Autocomplete

```bash
# bash
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

# zsh
echo 'source <(kubectl completion zsh)' >> ~/.zshrc
echo 'compdef __start_kubectl k' >> ~/.zshrc   # also complete for 'k' alias

source ~/.zshrc
```

---

## 7. Recommended VS Code Extensions

Install these extensions for the best experience with this lab:

```bash
# Install via CLI (or search in VS Code Extensions panel)
code --install-extension ms-kubernetes-tools.vscode-kubernetes-tools
code --install-extension hashicorp.terraform
code --install-extension redhat.vscode-yaml
code --install-extension ms-azuretools.vscode-docker
code --install-extension golang.go
code --install-extension ms-vscode-remote.remote-containers
code --install-extension esbenp.prettier-vscode
code --install-extension streetsidesoftware.code-spell-checker
```

| Extension | Purpose |
|-----------|---------|
| Kubernetes | Auto-complete for K8s YAML, pod explorer in sidebar |
| HashiCorp Terraform | HCL syntax highlighting, auto-complete, validation |
| YAML | Schema validation for K8s/Helm YAML |
| Docker | Dockerfile support, image management |
| Go | If exploring GKE controllers or operators |
| Dev Containers | Run the full lab in a container (reproducible env) |

### VS Code Workspace Settings

Create `.vscode/settings.json` in the repo root:

```json
{
  "editor.formatOnSave": true,
  "editor.tabSize": 2,
  "yaml.schemas": {
    "kubernetes": "**/*.yaml"
  },
  "[terraform]": {
    "editor.defaultFormatter": "hashicorp.terraform",
    "editor.formatOnSave": true
  },
  "terraform.experimentalFeatures.prefillRequiredFields": true,
  "kubernetes.kubectlVersioning": "user-provided"
}
```

---

## 8. k9s Cheatsheet

k9s is a terminal-based UI that dramatically speeds up Kubernetes debugging.

### Launch k9s

```bash
k9s                          # connects to current kubectl context
k9s -n application           # start in a specific namespace
k9s --context gke-labs       # start with a specific context
```

### Navigation

| Key | Action |
|-----|--------|
| `:` | Open command bar (type resource names) |
| `0` | Show all namespaces |
| `1-9` | Jump to namespace shortcuts |
| `↑↓` | Navigate list |
| `Enter` | Drill into resource |
| `Esc` | Go back |
| `q` | Quit |
| `?` | Show help |

### Working with Pods

| Key | Action |
|-----|--------|
| `:pods` | Show all pods |
| `l` | View pod logs |
| `s` | Shell into container |
| `d` | Describe resource |
| `y` | View YAML |
| `e` | Edit resource (live edit!) |
| `ctrl-k` | Kill (delete) a pod |
| `ctrl-d` | Delete resource |
| `/` | Filter/search in current view |

### Useful k9s Commands (type after `:`)

| Command | Shows |
|---------|-------|
| `:pods` | All pods |
| `:deploy` | Deployments |
| `:svc` | Services |
| `:nodes` | Nodes |
| `:events` | Events |
| `:secrets` | Secrets |
| `:cm` | ConfigMaps |
| `:ing` | Ingresses |
| `:hpa` | HorizontalPodAutoscalers |
| `:pvc` | PersistentVolumeClaims |
| `:ctx` | Switch context |
| `:ns` | Switch namespace |
| `:pulse` | Cluster health at a glance |
| `:xray deploy` | Dependency tree for deployments |

### k9s Log Navigation

When viewing logs (`l`):
- `f` — Toggle full screen
- `/` — Search in logs
- `ctrl-s` — Save logs to a file
- `w` — Toggle word wrap
- `m` — Mark timestamps
- `t` — Toggle timestamps

---

## 9. Break-It & Fix-It Exercises

### Exercise 1: Break kubectl Auth

```bash
# Simulate a broken kubeconfig
mv ~/.kube/config ~/.kube/config.bak

# Try any kubectl command — it should fail
kubectl get nodes
# Error: no configuration has been provided

# Fix it
mv ~/.kube/config.bak ~/.kube/config
kubectl get nodes  # works again
```

### Exercise 2: Use Wrong Project

```bash
# Switch to a non-existent project
gcloud config set project wrong-project-id

# Try to list GKE clusters
gcloud container clusters list
# Error: The project 'wrong-project-id' does not exist

# Fix it
gcloud config set project gke-labs
gcloud container clusters list
```

### Exercise 3: Revoke and Re-establish ADC

```bash
# Revoke application default credentials
gcloud auth application-default revoke

# Try a terraform plan (or any SDK-using tool)
cd terraform/
terraform plan
# Error: could not find default credentials

# Fix it
gcloud auth application-default login
terraform plan  # works again
```

---

## 10. Interview Q&A

---

### Q1: What's the difference between `gcloud auth login` and `gcloud auth application-default login`?

**Answer:**

`gcloud auth login` authenticates **you as a human** to use the `gcloud` CLI. The credentials are used when you type `gcloud` commands in your terminal. They identify you as a specific Google user account.

`gcloud auth application-default login` sets up **Application Default Credentials (ADC)** — credentials that Google client libraries, SDKs, and tools like Terraform use automatically when they need to call GCP APIs. These credentials are stored separately and follow a lookup chain:

1. `GOOGLE_APPLICATION_CREDENTIALS` environment variable (service account key file)
2. `~/.config/gcloud/application_default_credentials.json` (what ADC login sets)
3. The GCE/GKE metadata server (automatic when running on GCP)

The key insight: **you can be logged in as yourself with gcloud but have a service account's ADC** set for your tools — this is exactly how CI/CD pipelines work. Locally, you use your own ADC; in production, pods use Workload Identity (no key files ever).

---

### Q2: Why do we need the `gke-gcloud-auth-plugin` separately?

**Answer:**

Before Kubernetes 1.26, kubectl handled GKE authentication internally using a built-in GKE plugin. Google deprecated this in-tree plugin to keep kubectl vendor-neutral. The `gke-gcloud-auth-plugin` is a separate binary that kubectl calls via the `exec` credential plugin mechanism (defined in `~/.kube/config`). This separation means the auth logic can be updated independently of kubectl, and other cloud providers (EKS, AKS) follow the same pattern.

---

### Q3: If you have multiple GCP projects and multiple GKE clusters, how do you manage context switching efficiently?

**Answer:**

Use named gcloud configurations + kubectx:
- `gcloud config configurations create prod` — named gcloud config
- `gcloud config configurations activate prod` — switch GCP project/region
- `kubectx` — lists all kubectl contexts (clusters)
- `kubectx prod-cluster` — switches kubectl context
- `kubens application` — switches the active namespace

For very large environments, tools like `kubie` (context isolation per terminal) or direnv (auto-switch based on directory) prevent accidents where you run a command against the wrong cluster.

---

### Q4: How would you set up this environment in a CI/CD pipeline (GitHub Actions)?

**Answer:**

In CI/CD, never use `gcloud auth login` (that's for humans). Instead:

```yaml
- name: Authenticate to GCP
  uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: 'projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL/providers/PROVIDER'
    service_account: 'terraform@gke-labs.iam.gserviceaccount.com'

- name: Setup gcloud
  uses: google-github-actions/setup-gcloud@v2

- name: Get GKE credentials
  run: |
    gcloud container clusters get-credentials gke-lab-cluster \
      --region=europe-west1 --project=gke-labs
```

This uses **Workload Identity Federation** — GitHub's OIDC token is exchanged for a short-lived GCP credential. No service account key file exists anywhere. This is the modern, keyless approach.

---

### Q5: What does `kubectl config get-contexts` show, and how does it differ from `gcloud container clusters list`?

**Answer:**

`kubectl config get-contexts` shows **what's in your local `~/.kube/config` file** — clusters you've previously fetched credentials for. It's a local view.

`gcloud container clusters list` shows **what GKE clusters actually exist in your GCP project** — the source of truth. A cluster can exist in GCP but not be in your kubeconfig yet (you haven't run `get-credentials`). A cluster can be in your kubeconfig but deleted in GCP (stale entry — kubectl commands will fail).

Always verify with `gcloud container clusters list` if you're unsure a cluster actually exists.
