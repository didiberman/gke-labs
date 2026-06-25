# GKE Production Lab

> A production-quality GCP/GKE lab environment built the way a real financial-services platform team would build it — not tutorial-grade shortcuts.

18 guided labs covering everything from cluster setup to incident simulation, backed by real Terraform modules, Helm charts, and GitHub Actions pipelines.

---

## What's Inside

```
gke-labs/
├── terraform/           # 6 reusable modules + dev environment root
│   ├── modules/
│   │   ├── gke/         # GKE Standard cluster, node pools, Workload Identity
│   │   ├── cloud-sql/   # PostgreSQL 15, private IP, HA, backups
│   │   ├── memorystore/ # Redis 7, basic tier, VPC-native
│   │   ├── networking/  # VPC, subnets, Cloud NAT, firewall rules
│   │   ├── iam/         # Service accounts, Workload Identity bindings
│   │   ├── secret-manager/ # Secrets, IAM, version management
│   │   └── storage/     # GCS buckets, lifecycle rules, IAM
│   └── environments/dev/
├── helm/
│   ├── payments-api/    # App chart: Deployment, HPA, PDB, NetworkPolicy
│   ├── observability/   # kube-prometheus-stack + Loki + Tempo + Grafana
│   └── temporal/        # Temporal server wired to Cloud SQL via Auth Proxy
├── .github/workflows/   # ci.yml, cd-dev.yml, cd-staging.yml
├── local/               # Docker Compose stack (Temporal, Postgres, LGTM)
├── scripts/             # GCP bootstrap, cluster connect, teardown
└── labs/                # 18 guided exercises (00–17)
```

---

## Lab Index

| # | Lab | Topics |
|---|-----|--------|
| [00](labs/00-prerequisites/README.md) | Prerequisites & GCP Setup | gcloud, kubectl, helm, terraform, k9s |
| [01](labs/01-gke-cluster-setup/README.md) | GKE Cluster Deep Dive | Node pools, taints/tolerations, Autopilot vs Standard, private cluster |
| [02](labs/02-workload-identity/README.md) | Workload Identity | No SA keys, KSA→GSA binding, pod-level GCP auth |
| [03](labs/03-cloud-sql-private/README.md) | Cloud SQL (Private IP) | Auth Proxy sidecar, schema migrations, PITR, slow queries |
| [04](labs/04-memorystore-redis/README.md) | Memorystore Redis | Cache-aside, write-through, eviction policies, connection pooling |
| [05](labs/05-secret-manager/README.md) | Secret Manager + ESO | External Secrets Operator, secret rotation, file mounts vs env vars |
| [06](labs/06-helm-deployments/README.md) | Helm in Production | Chart anatomy, values per env, upgrades, rollbacks, Helm hooks |
| [07](labs/07-autoscaling-hpa-vpa/README.md) | HPA + VPA + KEDA | CPU/custom metrics, VPA modes, Cluster Autoscaler, spot preemptions |
| [08](labs/08-resource-tuning/README.md) | Resource Tuning | QoS classes, CPU throttling vs OOM, LimitRange, ResourceQuota |
| [09](labs/09-network-policies/README.md) | Network Policies | Zero-trust baseline, deny-all + explicit allow, Cilium/DataPlane V2 |
| [10](labs/10-cicd-pipeline/README.md) | CI/CD Pipeline | GitHub Actions, Trivy scanning, Helm --atomic, progressive delivery |
| [11](labs/11-observability-setup/README.md) | Observability Stack | Prometheus, Grafana, Loki, Tempo — full LGTM, Golden Signals |
| [12](labs/12-distributed-tracing/README.md) | Distributed Tracing | OpenTelemetry SDK + Collector, Tempo, trace/log correlation |
| [13](labs/13-alerting-runbooks/README.md) | Alerting + Runbooks | SLOs, error budgets, AlertManager routing, runbook structure |
| [14](labs/14-temporal-workflows/README.md) | Temporal Workflows | Activities, Workers, saga pattern, retries, tctl CLI |
| [15](labs/15-security-oauth-jwt/README.md) | OAuth2 / JWT / RBAC | Client Credentials flow, JWT verification, K8s RBAC, Kyverno |
| [16](labs/16-cloud-sql-ops/README.md) | Cloud SQL Operations | Backup strategy, PITR, HA, PgBouncer, maintenance windows |
| [17](labs/17-incident-simulation/README.md) | Incident Simulation | 3 war-game scenarios, post-mortem writing, 5-why analysis |

Each lab is 900–1,200 lines: concept explanation → architecture diagram → hands-on commands → break-it exercises → interview Q&A.

---

## Infrastructure Overview

```
                         ┌─────────────────────────────────────┐
                         │           GCP Project: gke-labs      │
                         │           Region: europe-west1        │
                         │                                       │
                         │  ┌──────────────────────────────┐   │
                         │  │         Custom VPC            │   │
                         │  │  10.0.0.0/16                 │   │
                         │  │                               │   │
                         │  │  ┌────────────────────────┐  │   │
                         │  │  │   GKE Standard Cluster  │  │   │
                         │  │  │   gke-labs-dev          │  │   │
                         │  │  │                         │  │   │
                         │  │  │  system-pool (e2-std-2) │  │   │
                         │  │  │  app-pool    (e2-std-4) │  │   │
                         │  │  │  spot-pool   (e2-std-4) │  │   │
                         │  │  └────────────────────────┘  │   │
                         │  │                               │   │
                         │  │  ┌──────────┐ ┌───────────┐  │   │
                         │  │  │ Cloud SQL │ │Memorystore│  │   │
                         │  │  │ Postgres  │ │  Redis 7  │  │   │
                         │  │  │ (private) │ │ (private) │  │   │
                         │  │  └──────────┘ └───────────┘  │   │
                         │  └──────────────────────────────┘   │
                         │                                       │
                         │  Secret Manager · GCS · Cloud NAT    │
                         └─────────────────────────────────────┘
```

**Terraform modules:** `networking` → `iam` → `gke` → `cloud-sql` + `memorystore` + `storage` + `secret-manager`

---

## GCP Cost Estimate

| Resource | $/hr |
|---|---|
| GKE Standard cluster (3× e2-standard-4) | ~$0.60 |
| Cloud SQL PostgreSQL (db-f1-micro) | ~$0.05 |
| Memorystore Redis (basic 1GB) | ~$0.05 |
| Cloud NAT | ~$0.04 |
| **Total while running** | **~$0.74/hr** |

Run `terraform destroy` when done. Everything recreates in ~15 minutes.

---

## Quick Start

### Prerequisites

```bash
# macOS
brew install terraform kubectl helm google-cloud-sdk k9s

# Verify
terraform version   # >= 1.7
helm version        # >= 3.14
gcloud version
```

### 1 — Authenticate with GCP

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project <YOUR_PROJECT_ID>

# Enable all required APIs (one-time)
bash scripts/setup-gcp.sh
```

### 2 — Provision infrastructure (~15 min)

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set project_id to your GCP project

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Resources provision in dependency order:
```
VPC + subnets + NAT  (~2 min)
  └─ IAM + SAs       (~1 min)
       └─ GKE         (~8 min)
       └─ Cloud SQL   (~5 min)
       └─ Memorystore (~3 min)
       └─ GCS + Secrets (~1 min)
```

### 3 — Connect to the cluster

```bash
gcloud container clusters get-credentials gke-labs-dev \
  --region europe-west1 \
  --project <YOUR_PROJECT_ID>

kubectl get nodes
```

### 4 — Deploy the app stack

```bash
# External Secrets Operator — reads secrets from Secret Manager
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace

# Payments API
helm upgrade --install payments-api helm/payments-api \
  --namespace payments --create-namespace \
  -f helm/payments-api/values.dev.yaml

# Observability (Prometheus + Grafana + Loki + Tempo)
helm upgrade --install observability helm/observability \
  --namespace monitoring --create-namespace \
  -f helm/observability/values.dev.yaml

# Temporal workflow engine
helm dependency update helm/temporal
helm upgrade --install temporal helm/temporal \
  --namespace temporal --create-namespace \
  -f helm/temporal/values.yaml \
  -f helm/temporal/values.dev.yaml \
  --set cloudSql.instanceConnectionName=<PROJECT>:<REGION>:<INSTANCE>
```

### 5 — Open Grafana

```bash
kubectl port-forward svc/observability-grafana 3000:80 -n monitoring
# http://localhost:3000  —  admin / prom-operator
```

### 6 — Work through the labs

```bash
# Start here
open labs/00-prerequisites/README.md
```

Follow the numbered sequence. Each lab is self-contained and builds on the previous one.

---

## Local Development (No GCP Required)

Practice every lab locally with Docker Compose — zero cost, zero GCP account needed.

```bash
cd local
docker compose up -d
docker compose ps
```

| Service | URL | Credentials |
|---|---|---|
| Grafana | http://localhost:3000 | admin / admin |
| Temporal UI | http://localhost:8080 | — |
| Prometheus | http://localhost:9090 | — |
| PostgreSQL | localhost:5432 | payments / localpassword |
| Redis | localhost:6379 | password: localpassword |

The local stack runs: PostgreSQL 15, Redis 7, Temporal (auto-setup), Prometheus, Grafana, Loki, Tempo, and httpbin for testing.

For Kubernetes-based labs, a kind cluster config is included:

```bash
kind create cluster --config local/kind-cluster.yaml
kubectl get nodes
```

---

## Helm Charts

### payments-api

Production-ready application chart with:
- `Deployment` with rolling update strategy
- `HorizontalPodAutoscaler` (CPU + custom metrics ready)
- `PodDisruptionBudget` (minAvailable: 1)
- `NetworkPolicy` (deny-all + explicit ingress/egress)
- `ServiceAccount` with Workload Identity annotation

```bash
helm upgrade --install payments-api helm/payments-api \
  -f helm/payments-api/values.dev.yaml \
  -n payments --create-namespace
```

### observability

Wraps `kube-prometheus-stack` and wires in Loki + Tempo + pre-built Grafana dashboards.

```bash
helm upgrade --install observability helm/observability \
  -f helm/observability/values.dev.yaml \
  -n monitoring --create-namespace
```

### temporal

Wraps the official `temporalio/temporal` chart, replaces bundled databases with Cloud SQL (PostgreSQL) via a Cloud SQL Auth Proxy sidecar. Supports Workload Identity — no SA key files needed.

```bash
helm dependency update helm/temporal
helm upgrade --install temporal helm/temporal \
  -f helm/temporal/values.yaml \
  -f helm/temporal/values.dev.yaml \
  --set cloudSql.instanceConnectionName=PROJECT:REGION:INSTANCE \
  -n temporal --create-namespace
```

---

## CI/CD Pipelines

Three GitHub Actions workflows in `.github/workflows/`:

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Every push / PR | Lint → build image → Trivy scan → unit tests |
| `cd-dev.yml` | Push to `main` | Deploy to dev cluster via Helm + smoke test |
| `cd-staging.yml` | Push to `release/*` | Deploy to staging + integration test gate |

All workflows use Workload Identity Federation — no long-lived credentials stored in GitHub secrets.

---

## Teardown

```bash
cd terraform/environments/dev
terraform destroy

# Verify all resources are gone
gcloud compute instances list --project <YOUR_PROJECT_ID>
gcloud sql instances list --project <YOUR_PROJECT_ID>
gcloud redis instances list --region europe-west1 --project <YOUR_PROJECT_ID>
```

---

## Skills Covered

This lab prepares you for senior/staff engineer roles requiring GKE production experience:

**Infrastructure:** Terraform modules · GKE Standard (node pools, taints, Cluster Autoscaler) · VPC-native networking · Private Cloud SQL · Memorystore · GCS · Secret Manager · Workload Identity

**Kubernetes:** HPA · VPA · KEDA · PodDisruptionBudget · NetworkPolicy · RBAC · LimitRange · ResourceQuota · Admission Controllers

**Observability:** Prometheus · Grafana · Loki · Tempo · OpenTelemetry · SLOs · AlertManager · Runbooks

**Security:** Workload Identity (no SA keys) · External Secrets Operator · OAuth2 · JWT verification · mTLS · Kyverno policies · Trivy image scanning

**Operations:** Helm upgrades/rollbacks · Blue-green/canary · Database PITR · Connection pooling · Incident simulation · Post-mortem writing

---

## License

MIT
