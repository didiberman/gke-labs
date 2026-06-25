# Lab 11 — Observability Stack

> **Goal:** Deploy and understand the full LGTM stack (Loki, Grafana, Tempo, Mimir/Prometheus)
> using the Helm chart at `helm/observability/`. Learn how Prometheus scrapes metrics, how
> Promtail ships logs to Loki, how to build a Golden Signals dashboard in Grafana, and how
> exemplars link a slow metric spike directly to the trace that caused it.

> **Series position:** Labs 01–10 built and deployed the cluster and application. This lab
> adds the full observability layer. Lab 12 extends it with distributed tracing. You need
> a running cluster with the `payments` namespace before proceeding.

---

## Table of Contents

1. [The LGTM Stack — Loki, Grafana, Tempo, Mimir/Prometheus](#1-the-lgtm-stack)
2. [Prometheus Architecture — Scraping, remote_write, Recording Rules](#2-prometheus-architecture)
3. [Loki Log Shipping — Promtail DaemonSet, Log Format, LogQL Basics](#3-loki-log-shipping)
4. [Grafana Dashboards — Datasources, Variables, Exemplars](#4-grafana-dashboards)
5. [Setting Up the Observability Namespace with Helm](#5-setting-up-the-observability-namespace-with-helm)
6. [Golden Signals Dashboard — Latency, Traffic, Errors, Saturation](#6-golden-signals-dashboard)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. The LGTM Stack

The LGTM stack is a fully open-source observability platform that covers all three pillars:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          LGTM Observability Stack                           │
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────┐ │
│  │    Loki      │    │   Grafana    │    │    Tempo     │    │ Mimir /   │ │
│  │              │    │              │    │              │    │Prometheus │ │
│  │  Log Storage │◄───┤  Dashboard   │───►│Trace Storage │    │           │ │
│  │  + Query     │    │  + Alerting  │    │  + Query     │    │  Metrics  │ │
│  │              │    │              │    │              │    │  Storage  │ │
│  └──────┬───────┘    └──────────────┘    └──────────────┘    └─────┬─────┘ │
│         │                   ▲                   ▲                  │       │
│         │                   │                   │                  │       │
│  ┌──────▼───────┐    ┌──────┴────────┐   ┌──────┴────────┐        │       │
│  │   Promtail   │    │    Grafana    │   │  OTel         │        │       │
│  │  DaemonSet   │    │    Agent      │   │  Collector    │        │       │
│  │ (log shipper)│    │ (pulls metrics│   │(receives spans│        │       │
│  │              │    │  via remote_  │   │ from apps)    │        │       │
│  └──────┬───────┘    │  write)       │   └───────────────┘        │       │
│         │            └──────┬────────┘                            │       │
│    Tails pod logs           │ remote_write                  scrapes│       │
│    from /var/log/           │                              /metrics│       │
│    containers/              │                                      │       │
│                             └──────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why This Stack Instead of a SaaS Solution?

| Dimension | SaaS (Datadog, New Relic) | Self-hosted LGTM |
|-----------|--------------------------|-----------------|
| Cost at scale | $15-50/host/month, linear scaling | Infrastructure cost only (GCS: ~$0.02/GB) |
| Setup time | Minutes | Hours (first time), minutes (Helm after that) |
| Vendor lock-in | High (custom query languages) | None (PromQL, LogQL are open standards) |
| Data control | Data leaves your infrastructure | Data stays in your GCS bucket |
| Customization | Limited | Unlimited |
| Cardinality limits | Enforced | You control |

For a financial services platform, data residency requirements often mandate self-hosted.

### Component Responsibilities

| Component | What It Does | Port | Storage Backend |
|-----------|-------------|------|----------------|
| **Prometheus** | Scrapes metrics, evaluates alerts, short-term storage | 9090 | Local disk (15d) |
| **Mimir** | Long-term metrics storage (months/years) | 9009 | GCS bucket |
| **Loki** | Log aggregation and querying | 3100 | GCS bucket |
| **Tempo** | Trace storage and querying | 3200 | GCS bucket |
| **Grafana** | Unified dashboard, alerting UI | 3000 | PostgreSQL / SQLite |
| **Promtail** | Log collection agent (DaemonSet) | 3101 | — (ships to Loki) |
| **OTel Collector** | Receives traces from apps, ships to Tempo | 4317 | — (ships to Tempo) |

---

## 2. Prometheus Architecture

Prometheus uses a **pull model** — it scrapes metrics from targets rather than having targets
push to it. This is the opposite of most traditional monitoring systems.

### Scrape Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                  Prometheus Scrape Loop (every 30s)              │
│                                                                  │
│  Service Discovery                                               │
│  ─────────────────                                               │
│  Kubernetes SD discovers all pods with annotation:              │
│    prometheus.io/scrape: "true"                                  │
│    prometheus.io/port:   "8080"                                  │
│    prometheus.io/path:   "/metrics"                              │
│                                                                  │
│  For each discovered target:                                     │
│    HTTP GET http://<pod-ip>:8080/metrics                         │
│    ← Plain text Prometheus exposition format:                    │
│                                                                  │
│    # HELP http_requests_total Total HTTP requests                │
│    # TYPE http_requests_total counter                             │
│    http_requests_total{method="GET",status="200"} 1234           │
│    http_requests_total{method="POST",status="500"} 7             │
│                                                                  │
│  Store as time series:                                           │
│    metric_name{label1="val1", label2="val2"} value @timestamp   │
└──────────────────────────────────────────────────────────────────┘
```

### ServiceMonitor — The Operator Way

Instead of pod annotations, the Prometheus Operator uses `ServiceMonitor` custom resources.
This gives you more control and works with the kube-prometheus-stack Helm chart:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payments-api
  namespace: payments
  labels:
    release: kube-prometheus-stack   # Must match Prometheus's serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app: payments-api              # Select Services with this label
  endpoints:
    - port: http-metrics             # Named port in the Service spec
      path: /metrics
      interval: 30s
      scheme: http
      relabelings:
        - action: replace
          sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - action: replace
          sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
```

```bash
# Apply the ServiceMonitor
kubectl apply -f payments-api-servicemonitor.yaml

# Verify Prometheus discovered it
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
# Open http://localhost:9090/targets
# Look for: serviceMonitor/payments/payments-api/0 → UP
```

### remote_write — Shipping to Mimir for Long-Term Storage

Prometheus's local storage is limited (15 days by default). `remote_write` ships all scraped
metrics to Mimir (or any Prometheus-compatible remote storage) in real time:

```yaml
# In helm/observability/values.yaml:
kube-prometheus-stack:
  prometheus:
    prometheusSpec:
      remoteWrite:
        - url: http://mimir.monitoring.svc.cluster.local:9009/api/v1/push
          headers:
            X-Scope-OrgID: gke-labs      # Mimir tenant ID
          queueConfig:
            capacity: 10000
            maxSamplesPerSend: 5000
            batchSendDeadline: 5s
```

```
Timeline:
  0s:   Prometheus scrapes metrics → stores locally
  30s:  remote_write queue flushes → Mimir stores for long-term
  15d:  Prometheus local TSDB truncates (data still in Mimir)
  1y:   Data queryable from Mimir (cost: ~$0.02/GB/month in GCS)
```

### Recording Rules — Pre-Computing Expensive Queries

Recording rules evaluate PromQL expressions on a schedule and store the result as a new time
series. Expensive queries run once (on the Prometheus server) instead of at query time for
every Grafana panel:

```yaml
# In helm/observability/values.yaml → additionalPrometheusRulesMap:
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payments-api-rules
  namespace: payments
spec:
  groups:
    - name: payments.api.recording
      interval: 60s    # Evaluate every 60s, store result
      rules:
        # Pre-compute 5-minute success rate across all pods
        - record: job:http_request_success_rate:5m
          expr: |
            sum(rate(http_requests_total{status=~"2..",namespace="payments"}[5m]))
            /
            sum(rate(http_requests_total{namespace="payments"}[5m]))

        # Pre-compute p99 latency for Grafana dashboards
        - record: job:http_request_duration_p99:5m
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket{namespace="payments"}[5m]))
              by (le, job)
            )
```

---

## 3. Loki Log Shipping

### Promtail DaemonSet — How Logs Are Collected

Promtail runs on every node (DaemonSet) and tails container log files directly:

```
Node filesystem:
  /var/log/containers/
    payments-api-xxxxx_payments_payments-api-abc123.log  ← Promtail tails this
    auth-service-xxxxx_default_auth-service-def456.log

Promtail reads: the JSON lines that containerd writes to these files
Promtail adds: Kubernetes metadata labels (namespace, pod, container, node)
Promtail sends: batches of log lines to Loki via HTTP/gRPC
```

```yaml
# The Promtail config (managed by the Helm chart, but good to understand):
# In helm/observability/values.yaml:
promtail:
  enabled: true
  config:
    clients:
      - url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
    scrapeConfigs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        pipeline_stages:
          # Stage 1: Parse the container log JSON envelope
          - cri: {}
          # Stage 2: If the log message is JSON, parse it
          - json:
              expressions:
                level: level
                msg: msg
                trace_id: trace_id    # Extract for log-to-trace linking
          # Stage 3: Add labels from parsed fields
          - labels:
              level:
              trace_id:
```

### Structured Log Format — What Loki Expects

Loki indexes **labels** (low cardinality) and full-text searches **log lines** (high cardinality).
The most important labels are the ones Promtail adds automatically:

```
Automatic Loki labels from Kubernetes metadata:
  namespace:  payments
  pod:        payments-api-7d9f8b-xxxxx
  container:  payments-api
  node:       gke-gke-labs-dev-application-pool-abc-0
  app:        payments-api           ← from pod label
```

Application logs should be structured JSON for best queryability:

```json
{
  "level": "info",
  "time": "2025-06-15T14:30:00Z",
  "msg": "Payment processed",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "payment_id": "pay_12345",
  "amount": 99.99,
  "currency": "EUR",
  "duration_ms": 45
}
```

> **Don't use high-cardinality values as labels.** `trace_id` or `user_id` have millions of
> unique values — making them Loki labels would create a label cardinality explosion.
> Use them as log line fields (searchable via LogQL), not Loki labels.

### LogQL Basics

LogQL is Loki's query language. It has two parts: a **log stream selector** (which streams
to query) and optional **pipeline stages** (how to filter/parse).

```logql
# Basic log stream selector — mandatory
{namespace="payments"}
{namespace="payments", container="payments-api"}
{namespace="payments"} |= "ERROR"    # Contains "ERROR" string

# Parse JSON and filter on a field
{namespace="payments"} | json | level="error"

# Filter by trace_id (for log-trace correlation)
{namespace="payments"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"

# Count error rate over time (metric query)
sum(rate({namespace="payments"} | json | level="error" [5m]))

# Find slow requests (duration_ms > 500)
{namespace="payments"} | json | duration_ms > 500

# Pattern matching with regex
{namespace="payments"} | json | msg =~ "Payment.*failed"

# Aggregate: count log lines by pod
sum by (pod) (count_over_time({namespace="payments"}[5m]))
```

```bash
# Test LogQL queries without Grafana UI
kubectl port-forward svc/loki 3100:3100 -n monitoring &

# Query via HTTP API
curl -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="payments"} | json | level="error"' \
  --data-urlencode 'start=2025-06-15T14:00:00Z' \
  --data-urlencode 'end=2025-06-15T15:00:00Z' \
  --data-urlencode 'limit=100' | \
  jq '.data.result[].values[][1]'
```

---

## 4. Grafana Dashboards — Datasources, Variables, Exemplars

### Configuring Datasources via Helm

The observability Helm chart provisions all datasources automatically using Grafana's
datasource provisioning:

```yaml
# In helm/observability/values.yaml (Grafana section):
grafana:
  enabled: true
  grafana.ini:
    auth:
      disable_login_form: false
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          uid: prometheus-uid
          url: http://prometheus-operated.monitoring:9090
          isDefault: true
          jsonData:
            timeInterval: 30s
            exemplarTraceIdDestinations:
              - name: trace_id          # Field name in the exemplar
                datasourceUid: tempo-uid

        - name: Loki
          type: loki
          uid: loki-uid
          url: http://loki.monitoring:3100
          jsonData:
            derivedFields:
              - name: TraceID
                matcherRegex: '"trace_id":"(\w+)"'
                url: '$${__value.raw}'
                datasourceUid: tempo-uid   # Links trace_id to Tempo
                urlDisplayLabel: View Trace

        - name: Tempo
          type: tempo
          uid: tempo-uid
          url: http://tempo.monitoring:3200
          jsonData:
            tracesToLogsV2:
              datasourceUid: loki-uid
              tags:
                - key: service.name
                  value: app
              filterByTraceID: true
              spanStartTimeShift: '-2m'
              spanEndTimeShift: '2m'
            serviceMap:
              datasourceUid: prometheus-uid
            nodeGraph:
              enabled: true
```

### Dashboard Variables

Variables make dashboards reusable across namespaces, services, and time ranges.

```json
// Variable definition (in Dashboard JSON):
{
  "name": "namespace",
  "type": "query",
  "query": "label_values(kube_pod_info, namespace)",
  "refresh": 2,          // Refresh on time range change
  "includeAll": true,
  "multi": false
}
```

```promql
# In panel queries, reference variables with $variable syntax:
# Error rate for the selected namespace and service:
sum(rate(http_requests_total{namespace="$namespace", job="$service", status=~"5.."}[5m]))
/
sum(rate(http_requests_total{namespace="$namespace", job="$service"}[5m]))
```

### Exemplars — Linking Metrics to Traces

Exemplars are the bridge between a metric anomaly and the specific trace that caused it.

```
Normal Prometheus scrape:
  http_request_duration_seconds_bucket{le="0.5"} 9823  @timestamp=1234567890

Exemplar-enriched scrape:
  http_request_duration_seconds_bucket{le="0.5"} 9823  @timestamp=1234567890
    # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736"} 0.734  ← This request took 734ms
    #  └── Grafana renders this as a diamond ◇ on the graph
    #  └── Click the ◇ → opens Tempo with this exact trace
```

Your application must emit exemplars. Example in Python:

```python
from prometheus_client import Histogram
from opentelemetry import trace

REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration',
    ['method', 'endpoint'],
    exemplars=True    # Enable exemplar support
)

def handle_request(method, endpoint):
    with REQUEST_LATENCY.labels(method=method, endpoint=endpoint).time() as timer:
        # The OTel SDK automatically attaches the current trace_id as an exemplar
        result = process_request()
    return result
```

Grafana displays exemplars as diamonds (◇) on latency graphs. Clicking a diamond opens
the trace in Tempo — zero manual correlation needed.

---

## 5. Setting Up the Observability Namespace with Helm

The full observability stack is deployed via `helm/observability/` — an umbrella chart that
depends on kube-prometheus-stack, Loki, Tempo, and Promtail.

### Prerequisites

```bash
# Verify cluster is running
kubectl get nodes -o wide

# Create the observability namespace
kubectl create namespace observability

# Create GCS buckets for long-term storage
for bucket in gke-labs-metrics gke-labs-logs gke-labs-traces; do
  gcloud storage buckets create gs://${bucket} \
    --project=gke-labs \
    --location=europe-west1 \
    --uniform-bucket-level-access
  echo "Created: gs://${bucket}"
done

# Create a GCP service account for the observability stack to access GCS
gcloud iam service-accounts create observability-sa \
  --display-name="Observability GCS Access" \
  --project=gke-labs

gcloud projects add-iam-policy-binding gke-labs \
  --role="roles/storage.objectAdmin" \
  --member="serviceAccount:observability-sa@gke-labs.iam.gserviceaccount.com"

# Bind to the Kubernetes service account (Workload Identity)
gcloud iam service-accounts add-iam-policy-binding \
  observability-sa@gke-labs.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:gke-labs.svc.id.goog[observability/observability]" \
  --project=gke-labs
```

### Install the Helm Chart

```bash
# Add required repos
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install using the repo's umbrella chart and dev values
helm upgrade --install observability helm/observability \
  --namespace observability \
  --create-namespace \
  --values helm/observability/values.yaml \
  --values helm/observability/values.dev.yaml \
  --timeout 10m \
  --atomic

# Watch the rollout
kubectl get pods -n observability -w
```

Expected pods after installation:
```
NAME                                              READY   STATUS    RESTARTS
alertmanager-kube-prometheus-stack-alertmanager   2/2     Running   0
grafana-xxxxx                                     1/1     Running   0
kube-prometheus-stack-operator-xxxxx              1/1     Running   0
loki-backend-0                                    1/1     Running   0
loki-read-0                                       1/1     Running   0
loki-write-0                                      1/1     Running   0
prometheus-kube-prometheus-stack-prometheus-0     2/2     Running   0
promtail-xxxxx (DaemonSet — one per node)         1/1     Running   0
tempo-xxxxx                                       1/1     Running   0
```

### Access Grafana

```bash
# Get the admin password
kubectl get secret grafana \
  -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Port-forward Grafana
kubectl port-forward svc/grafana 3000:80 -n observability

# Open http://localhost:3000
# Login: admin / <password from above>
```

### Verify Prometheus Is Scraping payments-api

```bash
# Port-forward Prometheus
kubectl port-forward svc/prometheus-operated 9090:9090 -n observability &

# Check targets
curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.namespace == "payments") | {job: .labels.job, health: .health}'

# Query a metric from payments-api
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=http_requests_total{namespace="payments"}' | \
  jq '.data.result[].metric'
```

---

## 6. Golden Signals Dashboard — Latency, Traffic, Errors, Saturation

Google's SRE Book defines the **Four Golden Signals** as the minimum viable set of metrics
for any user-facing service. Build this dashboard first before adding anything else.

```
The Four Golden Signals:

  LATENCY     — How long does it take to service a request?
                Measure: p50, p95, p99 of http_request_duration_seconds
                Alert: p99 > SLO threshold (e.g., 500ms)

  TRAFFIC     — How much demand is being placed on the system?
                Measure: requests per second (RPS)
                Use: capacity planning, anomaly detection (sudden drop = something broken)

  ERRORS      — What is the rate of requests that fail?
                Measure: HTTP 5xx / total requests
                Alert: error rate > 0.1% (99.9% success rate SLO)

  SATURATION  — How full is your service?
                Measure: CPU utilization, memory usage, connection pool depth
                Alert: CPU > 80% sustained → scale out trigger
```

### Building the Dashboard — Panel by Panel

#### Panel 1: Request Rate (Traffic)

```promql
# PromQL for requests per second by status code:
sum by (status) (
  rate(http_requests_total{namespace="payments", job="payments-api"}[5m])
)
```

Visualization: **Time series** with stacked lines (2xx = green, 4xx = yellow, 5xx = red)

```json
// Panel config in Grafana JSON:
{
  "title": "Request Rate",
  "type": "timeseries",
  "fieldConfig": {
    "overrides": [
      {"matcher": {"id": "byRegexp", "options": ".*5.."}, "properties": [{"id": "color", "value": {"fixedColor": "red", "mode": "fixed"}}]},
      {"matcher": {"id": "byRegexp", "options": ".*2.."}, "properties": [{"id": "color", "value": {"fixedColor": "green", "mode": "fixed"}}]}
    ]
  }
}
```

#### Panel 2: Error Rate (Errors)

```promql
# Error rate as a percentage:
100 * sum(rate(http_requests_total{namespace="payments", status=~"5.."}[5m]))
    / sum(rate(http_requests_total{namespace="payments"}[5m]))
```

Visualization: **Stat** panel with thresholds: green < 0.1%, yellow < 1%, red > 1%

#### Panel 3: p50 / p95 / p99 Latency

```promql
# p99 latency using histogram_quantile (requires histogram metric type):
histogram_quantile(0.99,
  sum by (le) (
    rate(http_request_duration_seconds_bucket{namespace="payments"}[5m])
  )
)

# p95:
histogram_quantile(0.95,
  sum by (le) (
    rate(http_request_duration_seconds_bucket{namespace="payments"}[5m])
  )
)
```

Visualization: **Time series** with multiple queries (p50 in green, p95 in yellow, p99 in red)

Enable exemplars on this panel to see trace links:
- Panel options → Exemplars → Enable
- Data source: Prometheus (with exemplar datasource configured to Tempo)

#### Panel 4: CPU Saturation

```promql
# CPU utilization as % of request:
sum by (pod) (
  rate(container_cpu_usage_seconds_total{namespace="payments", container!=""}[5m])
)
/
sum by (pod) (
  kube_pod_container_resource_requests{namespace="payments", resource="cpu"}
)
* 100
```

Visualization: **Gauge** panels, one per pod, threshold at 80%

#### Panel 5: Memory Saturation

```promql
# Memory usage vs limit:
sum by (pod) (
  container_memory_working_set_bytes{namespace="payments", container!=""}
)
/
sum by (pod) (
  kube_pod_container_resource_limits{namespace="payments", resource="memory"}
)
* 100
```

### Dashboard Variables for the Golden Signals Dashboard

```
Variable: namespace
  Type: Query
  Query: label_values(kube_pod_info, namespace)
  
Variable: service  
  Type: Query
  Query: label_values(kube_pod_info{namespace="$namespace"}, pod)
  Depends on: namespace

Variable: interval
  Type: Interval
  Values: 1m, 5m, 15m, 30m, 1h
  Default: 5m
```

### Exporting the Dashboard as JSON

```bash
# Export dashboard via Grafana API (useful for GitOps)
GRAFANA_URL="http://localhost:3000"
DASHBOARD_UID="golden-signals"

curl -u admin:$(kubectl get secret grafana -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d) \
  "${GRAFANA_URL}/api/dashboards/uid/${DASHBOARD_UID}" | \
  jq '.dashboard' > dashboards/golden-signals.json

# Import a dashboard from JSON
curl -u admin:password \
  -X POST "${GRAFANA_URL}/api/dashboards/import" \
  -H "Content-Type: application/json" \
  -d @dashboards/golden-signals.json
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1: Prometheus Can't Scrape payments-api

**What we're testing:** Debug why a target shows as DOWN in Prometheus.

```bash
# === BREAK IT ===
# Remove the Prometheus scrape annotation from payments-api
kubectl annotate deployment payments-api \
  -n payments \
  prometheus.io/scrape-

# Or if using ServiceMonitor: delete the ServiceMonitor
# kubectl delete servicemonitor payments-api -n payments

# === OBSERVE ===
kubectl port-forward svc/prometheus-operated 9090:9090 -n observability &

# Check the targets page
curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.namespace == "payments")'
# Either no results (target removed) or health: "down"

# In Prometheus UI: Status → Targets
# Look for: payments-api target with error message

# === FIX IT ===
# Re-add the scrape annotation
kubectl annotate deployment payments-api \
  -n payments \
  prometheus.io/scrape=true \
  prometheus.io/port=8080 \
  prometheus.io/path=/metrics

# Wait 30s for Prometheus to re-discover the target
sleep 30
curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.namespace == "payments") | .health'
# Expected: "up" ✅
```

---

### Exercise 2: Loki Receives No Logs

**What we're testing:** Debug a Promtail configuration issue.

```bash
# === BREAK IT ===
# Misconfigure Promtail to send to wrong URL
kubectl patch configmap promtail -n observability --type=merge -p='{
  "data": {
    "promtail.yaml": "..wrong-loki-url.."
  }
}'
# Note: in practice, patch the Helm values and upgrade

# Simulate by scaling Promtail to 0
kubectl scale daemonset promtail -n observability --replicas=0 2>/dev/null || \
  kubectl patch daemonset promtail -n observability \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"no-such-label":"true"}}}}}'

# === OBSERVE ===
# Query Loki for recent logs — should return empty
kubectl port-forward svc/loki 3100:3100 -n observability &

NOW=$(date +%s)000000000
BEFORE=$((NOW - 300000000000))

curl -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="payments"}' \
  --data-urlencode "start=${BEFORE}" \
  --data-urlencode "end=${NOW}" | \
  jq '.data.result | length'
# Returns 0 — no logs

# === FIX IT ===
# Restore the Promtail DaemonSet
kubectl rollout undo daemonset/promtail -n observability
# or
kubectl patch daemonset promtail -n observability \
  -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'

# Verify Promtail pods are running on all nodes
kubectl get pods -n observability -l app.kubernetes.io/name=promtail -o wide

# Verify logs are flowing
sleep 30
curl -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="payments"}' \
  --data-urlencode "start=${BEFORE}" \
  --data-urlencode "end=$(date +%s)000000000" | \
  jq '.data.result | length'
# Expected: > 0 ✅
```

---

### Exercise 3: Alert Fires for Wrong Threshold

**What we're testing:** Update a PrometheusRule alert threshold without restarting Prometheus.

```bash
# === SETUP ===
# Apply a PrometheusRule that fires immediately (threshold too low)
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payments-error-rate
  namespace: payments
  labels:
    release: kube-prometheus-stack   # Must match Prometheus's ruleSelector
spec:
  groups:
    - name: payments.api
      rules:
        - alert: PaymentsHighErrorRate
          expr: |
            sum(rate(http_requests_total{namespace="payments",status=~"5.."}[5m]))
            /
            sum(rate(http_requests_total{namespace="payments"}[5m]))
            > 0.0001   # ← Too low: fires on 1-in-10000 errors
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "High error rate in payments-api"
            description: "Error rate is {{ $value | humanizePercentage }}"
EOF

# === OBSERVE ===
# Check alert firing status
curl -s http://localhost:9090/api/v1/alerts | \
  jq '.data.alerts[] | select(.labels.alertname == "PaymentsHighErrorRate")'
# Alert is firing because the threshold is too low

# === FIX IT ===
# Update the threshold — no Prometheus restart needed
kubectl patch prometheusrule payments-error-rate \
  -n payments \
  --type=json \
  -p='[{"op": "replace",
         "path": "/spec/groups/0/rules/0/expr",
         "value": "sum(rate(http_requests_total{namespace=\"payments\",status=~\"5..\"}[5m]))\n/ sum(rate(http_requests_total{namespace=\"payments\"}[5m]))\n> 0.01"}]'

# Prometheus Operator detects the ConfigMap change and reloads rules
# within ~1 minute (without restarting the Prometheus pod)

# Verify the rule was updated
sleep 60
curl -s http://localhost:9090/api/v1/rules | \
  jq '.data.groups[] | select(.name == "payments.api") | .rules[].query'
# Should show the updated expression with > 0.01
```

---

## 8. Interview Q&A

---

### Q1: Explain the difference between Prometheus and Loki. Why do you need both?

**Answer:**

**Prometheus** is a **metrics** database. It stores time-series data: numeric measurements
sampled at regular intervals. Each metric has labels (dimensions) but no free-form text.
PromQL is the query language.

Example: `http_requests_total{method="GET", status="200"} 12345 @1718469600`

**Loki** is a **log** aggregation system. It stores log lines — arbitrary text (or structured
JSON). It indexes only labels (namespace, pod, container) for efficient stream selection, and
full-text searches the log content.

Example: `{"level":"error","msg":"DB connection failed","trace_id":"abc123"} @1718469600`

You need both because they answer different questions:
- Prometheus answers: "What is the error rate over the last hour?" (aggregate numeric)
- Loki answers: "What exactly happened in this pod at 14:35?" (specific log content)

The combination is powerful: Prometheus alerts tell you **something is wrong**. Loki shows
you **the exact error messages** in the pods that triggered the alert. And Tempo (from the
`trace_id` in the Loki log) shows you **the full call graph** for that specific request.

---

### Q2: What is a recording rule in Prometheus and why would you use one?

**Answer:**

A recording rule evaluates a PromQL expression on a schedule (e.g., every 60 seconds) and
stores the result as a new time series under a new metric name. This is called
**pre-computation**.

Without a recording rule:
```promql
# This complex join query runs at dashboard render time (1-2 seconds per panel)
histogram_quantile(0.99,
  sum by (le, job) (
    rate(http_request_duration_seconds_bucket{namespace="payments"}[5m])
  )
)
```

With a recording rule:
```yaml
- record: job:http_request_duration_p99:5m
  expr: |
    histogram_quantile(0.99,
      sum by (le, job) (rate(http_request_duration_seconds_bucket{namespace="payments"}[5m]))
    )
```

The Grafana panel now queries:
```promql
job:http_request_duration_p99:5m{job="payments-api"}
```

This is a simple label lookup — nearly instantaneous. Dashboard load time drops from 3–5
seconds to under 100ms.

Recording rules are also essential for **alert expressions** on expensive queries — the
alert evaluation runs the recording rule's pre-computed result rather than the original query.

---

### Q3: What is cardinality in Prometheus and how does high cardinality break things?

**Answer:**

**Cardinality** = the total number of unique time series in Prometheus. Each unique combination
of metric name + label values creates a new time series.

```
Low cardinality:
  http_requests_total{method="GET", status="200"}  → 1 series
  http_requests_total{method="POST", status="200"} → 1 series
  http_requests_total{method="GET", status="500"}  → 1 series
  Total: ~6 series (2 methods × 3 status codes)

High cardinality (the mistake):
  http_requests_total{user_id="u-12345", method="GET"}   → 1 series per user
  http_requests_total{user_id="u-12346", method="GET"}   → ...
  http_requests_total{user_id="u-99999", method="GET"}   → ...
  Total: 100,000 series (one per user)
```

High cardinality causes:
1. **Memory explosion**: Prometheus keeps all active series in memory. 10 million series
   → 20–30GB RAM just for the head block
2. **Slow queries**: `sum(http_requests_total)` must sum 10M series instead of 6
3. **Slow scrapes**: the `/metrics` endpoint itself becomes large and slow to serialize

**Fix:** Remove high-cardinality labels (`user_id`, `trace_id`, `request_id`) from metric
labels. Aggregate them at the application level before exposing metrics.

In Loki: same principle. Don't create labels for `trace_id` — it belongs in the log line body,
not the label set.

---

### Q4: A developer reports Grafana dashboards are blank — no data showing. How do you debug this?

**Answer:**

Work through the pipeline from source to display:

```bash
# Step 1: Is Grafana itself healthy?
kubectl get pods -n observability | grep grafana
# If not Running: kubectl describe pod grafana-xxxxx -n observability

# Step 2: Is Prometheus running and connected?
kubectl port-forward svc/prometheus-operated 9090:9090 -n observability &
curl -s http://localhost:9090/-/healthy
# Expected: Prometheus Server is Healthy.

# Step 3: Are there any targets being scraped?
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
# If 0: Prometheus can't discover any targets
# Fix: Check ServiceMonitor labels match Prometheus's serviceMonitorSelector

# Step 4: Is the specific metric present?
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=http_requests_total{namespace="payments"}' | \
  jq '.data.result | length'
# If 0: the metric doesn't exist or the target is DOWN

# Step 5: Check Grafana's datasource configuration
kubectl port-forward svc/grafana 3000:80 -n observability &
curl -u admin:password http://localhost:3000/api/datasources | jq '.[].name,.url'
# Verify the Prometheus URL is correct (service name + port)

# Step 6: Check Grafana logs for query errors
kubectl logs -n observability deployment/grafana | grep -i "error\|datasource"

# Step 7: Test the query directly in Grafana Explore
# Grafana → Explore → Prometheus → Paste PromQL query → Run
# If "No data" in Explore: the PromQL expression is wrong or metric doesn't exist
# If data in Explore but not in dashboard: dashboard variable/template is filtering it out
```

---

*Next: [Lab 12 — Distributed Tracing](../12-distributed-tracing/README.md)*
