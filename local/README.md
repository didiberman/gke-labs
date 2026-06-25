# GKE Labs — Local Development Environment

Practice every lab topic **without incurring any GCP costs**. The Docker Compose stack mirrors the production GKE architecture as closely as possible, and the kind cluster lets you test Kubernetes manifests before deploying to GKE.

---

## Directory layout

```
local/
├── docker-compose.yml          # Full local stack (Temporal, Postgres, Grafana stack)
├── prometheus.yml              # Prometheus scrape config
├── tempo.yaml                  # Tempo (distributed tracing) config
├── kind-cluster.yaml           # kind Kubernetes cluster (4 nodes)
└── grafana/
    └── provisioning/
        └── datasources/
            └── datasources.yaml  # Auto-wires Prometheus + Loki + Tempo in Grafana
```

---

## Quick start — Docker Compose

```bash
# From the repo root
cd local

# Start everything in the background
docker compose up -d

# Watch startup logs (Ctrl-C to exit, containers keep running)
docker compose logs -f

# Check all containers are healthy
docker compose ps
```

> [!IMPORTANT]
> Temporal's `auto-setup` image runs schema migrations on first start. Wait ~30 seconds before opening the Temporal UI — you'll see the `lab-temporal` container restart once while migrations run.

---

## Service URLs

| Service | URL | Credentials |
|---|---|---|
| **Grafana** | http://localhost:3000 | `admin` / `admin` |
| **Temporal UI** | http://localhost:8080 | — |
| **Prometheus** | http://localhost:9090 | — |
| **httpbin** | http://localhost:8000 | — |
| **Loki** (API) | http://localhost:3100 | — |
| **Tempo** (API) | http://localhost:3200 | — |
| **PostgreSQL** | localhost:5432 | `payments` / `localpassword` |
| **Redis** | localhost:6379 | password: `localpassword` |
| **Temporal gRPC** | localhost:7233 | — |

---

## What each service does

| Service | Purpose | GKE equivalent |
|---|---|---|
| **postgres** | State store for Temporal workflow executions and app workloads | Cloud SQL (PostgreSQL 15) |
| **redis** | Caching, pub/sub, and queue experiments | Memorystore (Redis) |
| **temporal** | Workflow orchestration engine | Temporal on GKE (helm/temporal) |
| **temporal-ui** | Web dashboard for inspecting workflows and activities | Same — exposed via Ingress |
| **prometheus** | Scrapes metrics from all services; evaluates alert rules | kube-prometheus-stack |
| **grafana** | Dashboards, log exploration, trace search | Grafana on GKE |
| **loki** | Aggregates container logs; queried from Grafana | Grafana Loki / Cloud Logging |
| **tempo** | Stores and queries distributed traces (OTLP/Zipkin) | Grafana Tempo / Cloud Trace |
| **httpbin** | HTTP echo service for testing ingress, retries, auth | Any backend service |

---

## Managing the stack

```bash
# Stop all containers (data persisted in volumes)
docker compose down

# Destroy containers AND all data volumes
docker compose down -v

# Restart a single service after config change
docker compose restart prometheus

# Reload Prometheus config without restart
curl -s -X POST http://localhost:9090/-/reload

# Reload Grafana datasources without restart
curl -s -u admin:admin -X POST \
  http://localhost:3000/api/admin/provisioning/datasources/reload

# Open a psql shell
docker compose exec postgres psql -U payments payments

# Run a tctl / temporal CLI command
docker compose exec temporal \
  temporal workflow list --namespace default
```

---

## kind cluster setup

The kind cluster creates **4 nodes** that mirror the GKE node pool layout:

| Node | Label | Mirrors |
|---|---|---|
| `kind-control-plane` | `ingress-ready=true` | GKE control plane (managed) |
| `kind-worker` | `role=application`, zone `b` | App node pool |
| `kind-worker2` | `role=application`, zone `c` | App node pool |
| `kind-worker3` | `role=system`, zone `d` | System node pool |

### Create the cluster

```bash
# Requires: kind ≥ 0.22, kubectl
kind create cluster --config local/kind-cluster.yaml --name gke-labs

# Verify
kubectl cluster-info --context kind-gke-labs
kubectl get nodes -o wide
```

### Install ingress-nginx (exposes port 80/443 from kind-cluster.yaml)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for the controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

### Tear down

```bash
kind delete cluster --name gke-labs
```

---

## Practising each lab topic

### 1 — GKE node pools & scheduling

| Topic | How to practice locally |
|---|---|
| Node selectors | Deploy a pod with `nodeSelector: role: application` — it lands on worker or worker2 |
| Taints & tolerations | Uncomment the taint line in `kind-cluster.yaml`, recreate cluster, verify system workloads need tolerations |
| Topology spread | Use `topologySpreadConstraints` with `topology.kubernetes.io/zone` — nodes have zone labels `b`, `c`, `d` |
| Resource quotas | Create a `ResourceQuota` in a namespace and try to exceed it |

### 2 — Temporal workflows

```bash
# Install the Temporal CLI
brew install temporal

# Point it at the local server
export TEMPORAL_ADDRESS=localhost:7233

# Create a namespace
temporal operator namespace create --namespace my-namespace

# List workflows
temporal workflow list --namespace default

# Open the UI
open http://localhost:8080
```

> [!TIP]
> The `temporalio/auto-setup` image automatically creates the `default` namespace and runs all schema migrations — no manual setup needed for local dev.

### 3 — Observability (Prometheus + Grafana + Loki + Tempo)

```bash
# Explore metrics in Prometheus
open http://localhost:9090

# Grafana — Explore logs from Loki
open http://localhost:3000/explore

# Send a test trace via OTLP HTTP
curl -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d @- <<'EOF'
{
  "resourceSpans": [{
    "resource": {"attributes": [{"key":"service.name","value":{"stringValue":"test-svc"}}]},
    "scopeSpans": [{"spans": [{"traceId":"00000000000000000000000000000001","spanId":"0000000000000001","name":"test-span","startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000","kind":1}]}]
  }]
}
EOF

# Search for that trace in Tempo
open http://localhost:3200

# Add postgres_exporter for DB metrics
docker run -d \
  -e DATA_SOURCE_NAME="postgresql://payments:localpassword@localhost:5432/payments?sslmode=disable" \
  -p 9187:9187 \
  --network local_lab \
  --name postgres-exporter \
  quay.io/prometheuscommunity/postgres-exporter
```

### 4 — Ingress & networking

```bash
# After creating the kind cluster and installing ingress-nginx:
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: httpbin
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: httpbin.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: httpbin
                port:
                  number: 80
EOF

# Add to /etc/hosts (one-time)
echo "127.0.0.1 httpbin.local" | sudo tee -a /etc/hosts

curl http://httpbin.local/get
```

### 5 — Helm charts (Temporal)

```bash
# Update chart dependencies
helm dependency update helm/temporal

# Dry-run against the kind cluster
helm upgrade --install temporal helm/temporal \
  -f helm/temporal/values.yaml \
  -f helm/temporal/values.dev.yaml \
  --dry-run --debug \
  -n temporal --create-namespace

# Real install (against kind — Cloud SQL proxy will fail without credentials)
# For kind-only testing, use the docker-compose Temporal instead.
```

---

## Local vs real GKE — key differences

| Aspect | Local (Docker Compose / kind) | Real GKE |
|---|---|---|
| **Authentication** | No auth; everything on localhost | GKE Workload Identity, Cloud IAM |
| **Database** | Postgres in Docker container | Cloud SQL with private IP, TLS, IAM auth |
| **Networking** | Docker bridge / kind CNI (kindnet) | VPC-native, Private Cluster, Cloud NAT |
| **TLS / certificates** | None (HTTP only) | cert-manager + Let's Encrypt / GCP CA |
| **Secret management** | Plain env vars / docker-compose | Secret Manager, ESO, Workload Identity |
| **Storage** | Docker named volumes | GCE Persistent Disk, Filestore |
| **Load balancing** | ingress-nginx on NodePort | GKE Ingress (GCLB), NEGs, BackendConfig |
| **DNS** | `/etc/hosts` edits | Cloud DNS, internal cluster DNS |
| **Observability** | Prometheus + Grafana + Loki + Tempo | Cloud Monitoring, Cloud Logging, Cloud Trace |
| **Autoscaling** | Manual (no HPA / CA) | HPA, VPA, Cluster Autoscaler, NAP |
| **Node pools** | Simulated via labels | Real pools with machine types, taints |
| **Temporal persistence** | Auto-setup single Postgres | Cloud SQL with HA, PITR, automated backups |

> [!NOTE]
> The networking and auth differences are the most impactful. Code that works locally may need minor changes for GKE (e.g. database connection strings, service account annotations for Workload Identity). Aim to keep these in environment-specific values files and Kubernetes Secrets so the app code itself doesn't change.

> [!TIP]
> Use **Skaffold** or **Telepresence** to bridge the gap: develop locally with hot-reload while running the rest of the stack in GKE.

---

## Troubleshooting

### Temporal fails to start

```bash
# Check if postgres is healthy first
docker compose ps postgres

# View Temporal startup logs
docker compose logs temporal --tail=100

# If schema migration failed, reset and retry
docker compose down -v
docker compose up -d
```

### Port conflict on 9090

Both Prometheus and the Temporal metrics endpoint use port 9090. In `docker-compose.yml` the Temporal metrics endpoint is internal-only (not mapped to the host). If you see a conflict, check for other local services:

```bash
lsof -i :9090
```

### Grafana shows "No data" for Loki

Loki uses its default config which writes to memory, not disk. After a container restart, historical logs are lost. This is expected for local dev. To persist logs, mount a custom Loki config with a filesystem store.

### kind cluster nodes NotReady

```bash
kubectl describe node kind-worker | grep -A5 Conditions
# Usually a CNI issue — wait ~60s for kindnet to initialise
```
