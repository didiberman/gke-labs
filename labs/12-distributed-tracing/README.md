# Lab 12 — Distributed Tracing with OpenTelemetry and Tempo

> **Series position:** Labs 01–11 covered cluster fundamentals, networking, storage, and observability
> (metrics/logs). This lab adds the third pillar of observability: **traces**. You will instrument
> services, collect spans with the OpenTelemetry Collector, store them in Grafana Tempo, and
> correlate traces with logs in Loki.

---

## Table of Contents

1. [What Problem Does Distributed Tracing Solve?](#1-what-problem-does-distributed-tracing-solve)
2. [OpenTelemetry — SDK, Collector, and OTLP](#2-opentelemetry--sdk-collector-and-otlp)
3. [TraceID, SpanID, and W3C Propagation](#3-traceid-spanid-and-w3c-propagation)
4. [Grafana Tempo — Receiving and Querying Traces](#4-grafana-tempo--receiving-and-querying-traces)
5. [Linking Loki Logs to Tempo Traces](#5-linking-loki-logs-to-tempo-traces)
6. [Lab Exercise — End-to-End Trace Walkthrough](#6-lab-exercise--end-to-end-trace-walkthrough)
7. [Break-It-and-Fix-It Exercises](#7-break-it-and-fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. What Problem Does Distributed Tracing Solve?

### The Microservices Latency Problem

In a monolith, a slow function call is easy to find: one process, one call stack, one profiler.

In a microservices architecture, a single user request might fan out across many services:

```
Browser
  └─► API Gateway         (10ms)
        └─► Auth Service  (5ms)
        └─► Products Svc  (120ms)   ← is THIS the bottleneck?
              └─► Cache   (2ms)
              └─► Database (115ms)  ← or THIS?
                    └─► Read Replica (108ms)  ← or THIS?
```

Metrics tell you _something_ is slow. Logs tell you _what happened_ in one service. Traces tell you
**exactly where time was spent across the entire call graph**, for a specific request.

### Before Tracing Existed

Engineers would:
- Add timestamps to logs in every service manually
- Correlate logs by request ID (if they remembered to pass it)
- Guess at bottlenecks from p99 latency graphs
- Debug production issues by reproducing locally (which never reproduced real conditions)

### The Three Pillars of Observability

| Question | Metrics | Logs | Traces |
|---|---|---|---|
| Is the API slow overall? | ✅ | ❌ | ✅ |
| Which service is slow for **this** request? | ❌ | ❌ | ✅ |
| What DB query caused it? | ❌ | Partially | ✅ |
| What was the full call graph? | ❌ | ❌ | ✅ |
| When did each operation start/end? | ❌ | ❌ | ✅ |

---

## 2. OpenTelemetry — SDK, Collector, and OTLP

### The OpenTelemetry Standard

OpenTelemetry (OTel) is a CNCF project providing a **vendor-neutral** standard for:
- **Instrumentation APIs** — how you add tracing/metrics/logging to your code
- **SDKs** — language-specific implementations (Go, Python, Node.js, Java, etc.)
- **The OpenTelemetry Collector** — receives, processes, and exports telemetry
- **OTLP** — OpenTelemetry Protocol, the wire format

Before OTel, every vendor had their own SDK: Datadog agent, Jaeger client, Zipkin client.
OTel unifies them so you instrument once and switch backends freely.

### Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Your GKE Cluster                        │
│                                                              │
│  ┌─────────────────┐   OTLP/gRPC   ┌────────────────────┐  │
│  │   Your App      │ ────────────► │  OTel Collector    │  │
│  │  (SDK inside)   │               │  (DaemonSet or     │  │
│  └─────────────────┘               │   Deployment)      │  │
│                                    └─────────┬──────────┘  │
│                                              │               │
│                             ┌────────────────▼───────────┐  │
│                             │       Grafana Tempo         │  │
│                             │  (trace storage + query)    │  │
│                             └────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### OTel Collector Pipeline

The Collector has three stages — **receivers → processors → exporters**:

```yaml
# otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317   # Apps send spans here via gRPC
      http:
        endpoint: 0.0.0.0:4318   # Apps send spans here via HTTP

processors:
  batch:
    timeout: 5s                   # Group spans into batches for efficiency
    send_batch_size: 1000
  memory_limiter:
    check_interval: 1s
    limit_mib: 400                # Prevent the Collector from OOMing
    spike_limit_mib: 100
  resource:
    attributes:
      - key: k8s.cluster.name
        value: "gke-labs-cluster"
        action: insert            # Enrich every span with cluster metadata

exporters:
  otlp/tempo:
    endpoint: tempo.monitoring:4317   # Forward to Tempo
    tls:
      insecure: true             # Use TLS in production

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlp/tempo]
```

### OTLP Protocol

OTLP (OpenTelemetry Protocol) is the wire format for telemetry data:
- **gRPC (port 4317)** — preferred; uses Protocol Buffers, efficient, bidirectional streaming
- **HTTP/JSON (port 4318)** — easier to debug with curl; useful in browsers or restricted environments

When your app's OTel SDK sends a batch of spans, they're serialized as OTLP protobuf over gRPC.

---

## 3. TraceID, SpanID, and W3C Propagation

### The Anatomy of a Trace

A **trace** represents a single end-to-end request. It is made up of **spans**.

A **span** represents a unit of work in a single service (an HTTP handler, DB query, cache lookup).

```
Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
│
├── Span: api-gateway.handle_request       (0ms → 140ms)    [SpanID: aabbcc]
│     ├── Span: auth.validate_token        (5ms → 10ms)     [SpanID: ddeeff]
│     └── Span: products.get_product       (15ms → 135ms)   [SpanID: 112233]
│           ├── Span: cache.get            (15ms → 17ms)    ← cache miss
│           └── Span: db.query             (18ms → 133ms)   ← SLOW SPAN
│                 └── Span: db.read_replica (20ms → 130ms)  ← root cause
```

Each span records:
- `trace_id` — which trace it belongs to
- `span_id` — its unique identifier
- `parent_span_id` — its parent (builds the tree)
- `start_time`, `end_time` — timing
- `attributes` — HTTP method, DB query, error codes, custom business data
- `status` — OK, ERROR, UNSET

### W3C TraceContext — The `traceparent` Header

The W3C `traceparent` header (IETF RFC 9631) is the standardized propagation format:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ─┬  ────────────────┬───────────────  ────────┬───────  ─┬
              │                  │                          │          │
          version           trace-id (128-bit)         parent-span-id  flags
          (always 00)        32 hex chars               16 hex chars  (01=sampled)
```

**How propagation works:**
1. Service A receives an HTTP request (no `traceparent`) → creates a **root span**, generates a new TraceID
2. Service A calls Service B → **injects** `traceparent` header with its TraceID + SpanID
3. Service B receives the request → **extracts** the TraceID and parent SpanID
4. Service B creates a child span using the same TraceID → trace tree is built

```bash
# Verify traceparent propagation by inspecting response headers
curl -v http://localhost:8080/api/products 2>&1 | grep traceparent
# < traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01

# Inject your own traceparent to trace a specific test request
curl -H 'traceparent: 00-deadbeef00000000deadbeef00000001-0000000000000001-01' \
     http://localhost:8080/api/products
# Then search Tempo for trace ID: deadbeef00000000deadbeef00000001
```

---

## 4. Grafana Tempo — Receiving and Querying Traces

### Why Tempo?

Grafana Tempo stores traces at massive scale with **low cost**:
- Traces stored in **object storage** (GCS, S3, MinIO) — not indexed columns
- Query by **TraceID only** — no expensive full-text index like Elasticsearch/Jaeger
- Integrates natively with Grafana and Loki
- Cost: ~$0.02/GB/month in GCS vs hundreds of dollars/month for indexed backends

### Tempo Architecture

```
OTel Collector ──OTLP──► Tempo Distributor
                               │
                          Tempo Ingester   (in-memory WAL buffer)
                               │
                         Tempo Compactor  ──► GCS Bucket (long-term storage)
                               │
                 Grafana Query ──► Tempo Querier ──► GCS
```

### Deploying Tempo on GKE

```bash
# Add the Grafana Helm chart repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Create GCS bucket for trace storage
gcloud storage buckets create gs://gke-labs-traces \
  --project=gke-labs \
  --location=europe-west1 \
  --uniform-bucket-level-access

# Install Tempo with GCS backend
helm upgrade --install tempo grafana/tempo-distributed \
  --namespace monitoring \
  --create-namespace \
  --values - <<'EOF'
storage:
  trace:
    backend: gcs
    gcs:
      bucket_name: gke-labs-traces

distributor:
  replicas: 2

ingester:
  replicas: 2
  persistence:
    enabled: true
    size: 10Gi

querier:
  replicas: 1

compactor:
  replicas: 1

serviceAccount:
  annotations:
    # Workload Identity for GCS access
    iam.gke.io/gcp-service-account: tempo-sa@gke-labs.iam.gserviceaccount.com
EOF

# Verify Tempo is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo
```

### TraceQL — Tempo's Query Language

TraceQL lets you search traces beyond just TraceID:

```
# Find all traces where a DB span took more than 100ms
{ span.db.system = "postgresql" } | duration > 100ms

# Find all error traces from the products-api in the last hour
{ resource.service.name = "products-api" && span.http.status_code >= 500 }

# Find slow end-to-end requests
{ resource.service.name = "api-gateway" } | duration > 2s

# Find traces touching both auth-service and products-api
{ resource.service.name = "auth-service" } && { resource.service.name = "products-api" }
```

---

## 5. Linking Loki Logs to Tempo Traces

This is where observability becomes **powerful**: click a TraceID in a log line and jump directly
to the full trace. Click a span in a trace and see logs from that service during that span.

### Step 1 — Emit TraceID in Every Log Line

Your app's OTel SDK injects the current TraceID into each log entry automatically when using OTel logging:

```python
# Python: structlog + OpenTelemetry integration
import structlog
from opentelemetry import trace

def get_current_trace_context():
    span = trace.get_current_span()
    ctx = span.get_span_context()
    return {
        "trace_id": format(ctx.trace_id, '032x'),
        "span_id": format(ctx.span_id, '016x'),
    }

logger = structlog.get_logger()

# In a request handler:
with tracer.start_as_current_span("handle_request"):
    logger.info("Processing request",
                **get_current_trace_context(),
                user_id=user.id,
                product_id=product_id)
```

Log output:
```json
{
  "level": "info",
  "msg": "Processing request",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "user_id": "u-12345",
  "product_id": "prod-789"
}
```

### Step 2 — Configure Derived Fields in Grafana (Loki → Tempo)

In Grafana → Configuration → Data Sources → Loki → **Derived Fields**:

| Field | Value |
|---|---|
| Name | TraceID |
| Regex | `"trace_id":\s*"(\w+)"` |
| Query | `${__value.raw}` |
| Internal link | ✅ Enabled |
| Data source | Tempo |

Now when you view a Loki log line containing `trace_id`, a **🔗 Tempo** button appears inline.
Clicking it opens the full trace in Tempo — zero copy-paste needed.

### Step 3 — Configure Tempo to Link Back to Loki

In the Tempo data source configuration in Grafana:

```yaml
# Grafana data source provisioning: tempo-datasource.yaml
apiVersion: 1
datasources:
  - name: Tempo
    type: tempo
    url: http://tempo.monitoring:3200
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki-uid
        tags:
          - key: service.name
            value: app
          - key: k8s.pod.name
            value: pod
        filterByTraceID: true
        filterBySpanID: false
        spanStartTimeShift: '-2m'    # Look 2 min before span started
        spanEndTimeShift: '2m'       # Look 2 min after span ended
      serviceMap:
        datasourceUid: prometheus-uid
      nodeGraph:
        enabled: true
```

---

## 6. Lab Exercise — End-to-End Trace Walkthrough

### Prerequisites

- Labs 09–11 stack running (Prometheus, Loki, Grafana)
- `helm` CLI installed
- `kubectl` configured for gke-labs cluster

### Step 1 — Deploy the OTel Collector

```bash
# Apply OTel Collector ConfigMap
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: monitoring
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 512
      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100
      resource:
        attributes:
          - key: k8s.cluster.name
            value: gke-labs-cluster
            action: insert

    exporters:
      otlp/tempo:
        endpoint: tempo.monitoring:4317
        tls:
          insecure: true
      logging:
        verbosity: normal

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [otlp/tempo, logging]
EOF

# Deploy OTel Collector
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: monitoring
  labels:
    app: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
      - name: otel-collector
        image: otel/opentelemetry-collector-contrib:0.100.0
        args: ["--config=/conf/config.yaml"]
        ports:
        - name: otlp-grpc
          containerPort: 4317
        - name: otlp-http
          containerPort: 4318
        - name: metrics
          containerPort: 8888
        volumeMounts:
        - name: config
          mountPath: /conf
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 500m
            memory: 500Mi
        livenessProbe:
          httpGet:
            path: /
            port: 13133
          initialDelaySeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 13133
          initialDelaySeconds: 5
      volumes:
      - name: config
        configMap:
          name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: monitoring
spec:
  selector:
    app: otel-collector
  ports:
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
    protocol: TCP
  - name: otlp-http
    port: 4318
    targetPort: 4318
    protocol: TCP
EOF

kubectl rollout status deployment/otel-collector -n monitoring --timeout=120s
```

### Step 2 — Deploy Tempo (Local storage for lab)

```bash
helm upgrade --install tempo grafana/tempo \
  --namespace monitoring \
  --set tempo.storage.trace.backend=local \
  --set tempo.storage.trace.local.path=/var/tempo \
  --set persistence.enabled=true \
  --set persistence.size=10Gi \
  --set service.type=ClusterIP

# Expose Tempo for querying (port 3200)
kubectl rollout status statefulset/tempo -n monitoring --timeout=120s

# Verify Tempo is accepting OTLP
kubectl logs -n monitoring deployment/otel-collector --tail=20
# You should see: "Everything is ready. Begin running and processing data."
```

### Step 3 — Instrument the Lab Application

```bash
# Patch the api-gateway deployment with OTel environment variables
# (assumes your app already has the OTel SDK installed)
kubectl patch deployment api-gateway -n default --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
   "value": {"name": "OTEL_EXPORTER_OTLP_ENDPOINT",
              "value": "http://otel-collector.monitoring:4317"}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
   "value": {"name": "OTEL_SERVICE_NAME", "value": "api-gateway"}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
   "value": {"name": "OTEL_TRACES_SAMPLER", "value": "parentbased_always_on"}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
   "value": {"name": "OTEL_PROPAGATORS", "value": "tracecontext,baggage"}}
]'

# Repeat for other services
for svc in products-api auth-service payments-api; do
  kubectl set env deployment/$svc \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring:4317 \
    OTEL_SERVICE_NAME=$svc \
    OTEL_TRACES_SAMPLER=parentbased_always_on \
    OTEL_PROPAGATORS=tracecontext,baggage \
    -n default
done

# Wait for rollouts
kubectl rollout status deployment/api-gateway deployment/products-api -n default
```

### Step 4 — Generate Traffic and Capture a TraceID

```bash
# Port-forward the API gateway
kubectl port-forward svc/api-gateway 8080:80 -n default &
PF_PID=$!

sleep 2  # Wait for port-forward to establish

# Send a request and capture the trace ID from the response header
echo "=== Sending request ==="
TRACE_RESPONSE=$(curl -si http://localhost:8080/api/products 2>&1)
echo "$TRACE_RESPONSE" | head -20

# Extract the TraceID from the traceparent response header
TRACE_ID=$(echo "$TRACE_RESPONSE" | grep -i traceparent | grep -oP '(?<=00-)[a-f0-9]{32}')
echo ""
echo "=== Captured TraceID: $TRACE_ID ==="

# Also check the OTel Collector logs for confirmation
echo ""
echo "=== OTel Collector logs (should show spans) ==="
kubectl logs -n monitoring deployment/otel-collector --tail=30 | grep -E "trace_id|span|export"
```

### Step 5 — View the Trace in Grafana Tempo

```bash
# Port-forward Grafana
kubectl port-forward svc/grafana 3000:3000 -n monitoring &
```

1. Open **http://localhost:3000** (admin / admin or check the secret)
2. Go to **Explore** (compass icon on the left)
3. Select **Tempo** from the data source dropdown (top left)
4. In **Query type**, select **TraceID**
5. Paste your `$TRACE_ID` and click **Run query**

**What to observe in the flame graph:**
- The horizontal axis is time (from request start to end)
- Each colored bar is one span — width = duration
- Indentation shows the parent-child relationship
- Click any span to see its attributes (HTTP URL, DB query, status code, etc.)
- The **critical path** (longest chain) appears highlighted

### Step 6 — Find the Trace via Loki

In Grafana Explore → switch to **Loki** data source:

```logql
# Find all log lines for this specific request
{namespace="default"} | json | trace_id = "<YOUR_TRACE_ID>"

# Or find log lines with errors across all services
{namespace="default"} | json | level = "error" | trace_id != ""
```

Look for the **Tempo** button next to log lines with a `trace_id` field. Clicking it jumps
directly to the full trace view.

---

## 7. Break-It-and-Fix-It Exercises

### Exercise A — Inject a 500ms Artificial Delay

**Goal:** Introduce a slow span, locate it in Tempo using TraceQL, and identify the exact cause.

```bash
# === BREAK IT ===

# 1. Add an artificial delay to the products-api
kubectl set env deployment/products-api \
  ARTIFICIAL_DELAY_MS=500 \
  -n default

# Wait for the rollout
kubectl rollout status deployment/products-api -n default

# 2. Generate traffic to observe the slowdown
echo "Generating traffic — watch latency..."
for i in $(seq 1 10); do
  time_taken=$(curl -w "%{time_total}" -o /dev/null -s http://localhost:8080/api/products)
  echo "Request $i: ${time_taken}s"
done

# === INVESTIGATE IN TEMPO ===
# In Grafana Explore → Tempo, run TraceQL:
# { resource.service.name = "products-api" } | duration > 400ms
#
# You will see:
# api-gateway.handle_request        520ms ████████████████████
#   products-api.get_products        510ms ████████████████████
#     products-api.artificial_sleep  500ms ████████████████████  ← ROOT CAUSE

# === FIX IT ===
kubectl set env deployment/products-api ARTIFICIAL_DELAY_MS- -n default
kubectl rollout status deployment/products-api -n default

# Verify latency is back to normal
echo "Verifying fix..."
for i in $(seq 1 5); do
  time_taken=$(curl -w "%{time_total}" -o /dev/null -s http://localhost:8080/api/products)
  echo "Request $i: ${time_taken}s"
done
```

**Expected result after fix:** Requests should return to ~20-30ms.

### Exercise B — Break Trace Propagation

**Goal:** Understand what happens when a service in the chain doesn't propagate `traceparent`.

```bash
# === BREAK IT ===
# Simulate a service that drops the W3C traceparent header
# (In practice: the service doesn't call context.propagate() in its HTTP client)
kubectl set env deployment/auth-service \
  DISABLE_TRACE_PROPAGATION=true \
  -n default

# === OBSERVE IN TEMPO ===
# Generate traffic
for i in $(seq 1 5); do
  curl -s http://localhost:8080/api/products > /dev/null
done

# In Grafana Explore → Tempo → Search:
# You will see ORPHANED traces from auth-service:
#   - Span: auth.validate_token  (standalone, no parent)
#   - The api-gateway trace shows a GAP where auth was called
#   - products-api span connects to api-gateway, but auth is missing

# The symptoms:
#   1. Incomplete flame graph (auth gap)
#   2. Auth-service appears as orphaned single-span traces in Tempo
#   3. End-to-end latency looks fine but auth spans are unaccounted

# === FIX IT ===
kubectl set env deployment/auth-service DISABLE_TRACE_PROPAGATION- -n default

# Lesson: Every service must:
# 1. Extract traceparent from incoming requests
# 2. Inject traceparent into ALL outgoing HTTP/gRPC requests
# 3. Include trace_id in all log output
```

---

## 8. Interview Q&A

---

### Q: "How do you trace a slow request across 5 microservices without access to the source code?"

**Answer:**

Great question — and a realistic constraint. There are three approaches, in order of richness:

**Option 1 — Zero-code auto-instrumentation agents**

Most OTel SDKs support zero-code instrumentation via language agents that monkey-patch HTTP
clients, gRPC stubs, and database drivers at runtime:

```bash
# Java: attach agent as JVM argument in the Deployment
kubectl patch deployment products-api -n default --type=json -p='[{
  "op": "add",
  "path": "/spec/template/spec/containers/0/env/-",
  "value": {
    "name": "JAVA_TOOL_OPTIONS",
    "value": "-javaagent:/otel/opentelemetry-javaagent.jar"
  }
}]'

# Node.js: require the auto-instrumentation package at startup
# CMD: ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "app.js"]

# Python: wrap the startup command
# CMD: ["opentelemetry-instrument", "python", "app.py"]
```

**Option 2 — Istio/Envoy sidecar tracing (no code change at all)**

The Envoy sidecar proxy generates spans for every L7 request automatically:

```bash
# Enable distributed tracing in Istio MeshConfig
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |
    defaultConfig:
      tracing:
        sampling: 100.0
        zipkin:
          address: otel-collector.monitoring:9411
EOF
```

Limitation: You see network-level spans (inter-service latency) but not intra-service spans
(e.g., which specific DB query inside a service is slow).

**Option 3 — Log-based trace synthesis**

Parse structured access logs that contain request IDs/timestamps, extract timing information
with the OTel Collector's `filelogreceiver`, and synthesize synthetic trace spans.

**My investigation workflow once traces are flowing:**
1. Reproduce the slow request and capture its TraceID from the `traceparent` response header
2. Open Tempo, paste the TraceID — the flame graph shows the full call graph
3. Identify the widest bar (highest duration span)
4. Check span attributes: `db.statement`, `http.url`, `rpc.method`
5. Click the Loki button to see application logs during that specific span

---

### Q: "What is the difference between head-based and tail-based sampling?"

**Answer:**

**Head-based sampling** — the decision to sample a trace is made at the **root span** (the first service):
- Simple: just set `OTEL_TRACES_SAMPLER=traceidratio` and a rate like `0.01` (1%)
- Problem: you might drop the one slow/erroring request you needed to investigate
- Good for: high-volume healthy systems where you just need statistical sampling

**Tail-based sampling** — the OTel Collector buffers all spans from a trace, waits for the trace
to complete, then decides whether to keep it based on the outcome:

```yaml
processors:
  tail_sampling:
    decision_wait: 30s          # Wait up to 30s for all spans to arrive
    num_traces: 50000           # Max traces held in memory simultaneously
    policies:
      - name: always-sample-errors
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: always-sample-slow
        type: latency
        latency: {threshold_ms: 1000}
      - name: probabilistic-baseline
        type: probabilistic
        probabilistic: {sampling_percentage: 1}
```

**Best practice:** Use tail-based sampling in production. You pay for storage proportional to
*interesting* events (errors, slowness) rather than total traffic volume.

---

### Q: "How do Tempo's storage costs compare to Jaeger with Elasticsearch?"

**Answer:**

Jaeger with Elasticsearch indexes every span attribute — it needs to support arbitrary queries
like "find all traces where `user.id = 12345`". This index consumes 2–5x the raw data size.

Tempo uses **trace-ID-first storage**: raw trace data is stored as flat files in object storage
(GCS/S3), organized by TraceID. No inverted index. To query beyond TraceID, Tempo uses
**TraceQL metrics generators** that pre-aggregate common queries into Prometheus metrics.

Cost comparison for 1TB/month of trace data:
- Jaeger + Elasticsearch: ~$50-200/month (indexed, fast arbitrary queries)
- Grafana Tempo + GCS: ~$20/month (object storage, TraceID queries instant, TraceQL queries slower)

For most organizations, Tempo's trade-off is excellent: you spend 80% of your time querying
by TraceID from a Loki log link, and only occasionally need TraceQL searches.

---

*Next: [Lab 13 — Alerting, SLOs, and Runbooks](../13-alerting-runbooks/README.md)*
