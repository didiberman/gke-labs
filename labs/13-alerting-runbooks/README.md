# Lab 13 — Alerting + Runbooks

> **Goal:** Build a production-grade alerting stack for the payments API — from defining SLOs and
> error budgets to writing PrometheusRules, routing pages to PagerDuty, and authoring runbooks that
> an on-call engineer can follow at 3 AM without any prior context.

> **Series position:** Labs 01–12 covered cluster fundamentals, networking, storage, and the full
> observability triad (metrics, logs, traces). This lab converts those signals into **actionable
> alerts** — the bridge between observing a problem and waking someone up to fix it.

---

## Table of Contents

1. [SLOs, SLIs, and Error Budgets — the Math](#1-slos-slis-and-error-budgets--the-math)
2. [AlertManager Architecture](#2-alertmanager-architecture)
3. [Writing a PrometheusRule for the Payments API](#3-writing-a-prometheusrule-for-the-payments-api)
4. [PagerDuty / OpsGenie Integration](#4-pagerduty--opsgenie-integration)
5. [Runbook Structure — What Makes a Good Runbook](#5-runbook-structure--what-makes-a-good-runbook)
6. [Alert Fatigue — Why Less Is More](#6-alert-fatigue--why-less-is-more)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. SLOs, SLIs, and Error Budgets — the Math

### The Vocabulary

**SLI (Service Level Indicator)** — a quantitative measure of service behavior.
Example: "the fraction of HTTP requests that returned 2xx in the last 5 minutes."

**SLO (Service Level Objective)** — the target you set for an SLI.
Example: "99.9% of payment requests must succeed over a 30-day rolling window."

**SLA (Service Level Agreement)** — an SLO with contractual penalties attached.
Your SLO is always stricter than your SLA to give yourself a buffer.

**Error Budget** — the amount of failure your SLO *allows* before you breach.
If your SLO is 99.9%, your error budget is 0.1% of requests (or time).

### The Math

```
SLO = 99.9%  →  Error Budget = 0.1%

Over 30 days:
  Total minutes:  30 × 24 × 60 = 43,200 min
  Budget minutes: 43,200 × 0.001 = 43.2 min/month of allowed downtime

Over 365 days:
  Total minutes:  525,600 min
  Budget minutes: 525,600 × 0.001 = 525.6 min ≈ 8.7 hours/year

Availability nines cheat sheet:
  99%     → 7.2 hr/day  / 3.65 days/year
  99.5%   → 3.6 hr/day  / 1.83 days/year
  99.9%   → 43.2 min/day / 8.7 hr/year
  99.95%  → 21.6 min/day / 4.4 hr/year
  99.99%  → 4.3 min/day  / 52.6 min/year
  99.999% → 26 sec/day   / 5.3 min/year
```

> **Practical advice:** 99.9% is achievable with a well-run GKE cluster and Cloud SQL HA.
> 99.99% requires multi-region active-active — a fundamentally different architecture.
> Don't promise 99.99% unless you've built for it.

### Calculating Error Budget Burn Rate

"Burn rate" tells you how quickly you're consuming your error budget *relative to* the
normal pace. A burn rate of 1 means you're consuming budget at exactly the rate your SLO allows.
A burn rate of 14.4 means you'll exhaust a 30-day budget in 50 hours.

```
Burn rate = (current error rate) / (1 - SLO target)

Example:
  SLO target    = 99.9%  → tolerated error rate = 0.1% = 0.001
  Current rate  = 1.44%  → 0.0144
  Burn rate     = 0.0144 / 0.001 = 14.4

  At burn rate 14.4 you exhaust 30 days of budget in:
    30 days / 14.4 = 2.08 days
```

### Defining SLIs for the Payments API

Good SLIs are **specific and measurable from existing telemetry**:

| SLI | Definition | Target |
|-----|-----------|--------|
| Availability | `rate(http_requests_total{status=~"5.."}[5m])` / total requests | 99.9% |
| Latency p99 | 99th percentile of `http_request_duration_seconds` | < 500ms |
| Latency p50 | 50th percentile of `http_request_duration_seconds` | < 100ms |
| Payment success rate | `rate(payment_transactions_total{status="succeeded"})` / total | 99.5% |

```
SLI Measurement Points — where to measure matters

  Client                Load Balancer           payments-api           Cloud SQL
  ──────                ────────────            ────────────           ─────────
     │                      │                       │                      │
     │──── request ─────────►│                       │                      │
     │                      │──── forward ──────────►│                      │
     │                      │                       │──── DB query ─────────►│
     │                      │                       │◄──── result ──────────│
     │◄──── response ────────│◄──── response ────────│                      │

  Measure at (A) = "what the client experiences"  ← SLI should be here
  Measure at (B) = "what the service experiences" ← good proxy, misses LB issues
  Measure at (C) = "what the DB experiences"      ← too deep, not user-facing
```

---

## 2. AlertManager Architecture

### What AlertManager Does

Prometheus **fires** alerts. AlertManager **routes, deduplicates, silences, and delivers** them.
The split is intentional: Prometheus evaluates rule logic; AlertManager handles operational concerns.

```
┌──────────────────────────────────────────────────────────────────┐
│                         GKE Cluster                               │
│                                                                    │
│  ┌─────────────────┐   fires alerts    ┌─────────────────────┐   │
│  │   Prometheus    │ ─────────────────► │    AlertManager     │   │
│  │  (evaluates     │                   │                     │   │
│  │  PrometheusRules│                   │  ┌───────────────┐  │   │
│  │  every 15s)     │                   │  │  Route tree   │  │   │
│  └─────────────────┘                   │  │               │  │   │
│                                        │  │ match: team=  │  │   │
│                                        │  │  payments     │  │   │
│                                        │  │     │         │  │   │
│                                        │  │     ▼         │  │   │
│                                        │  │ receiver:     │  │   │
│                                        │  │  pagerduty    │  │   │
│                                        │  └───────────────┘  │   │
│                                        │                     │   │
│                                        │  ┌──────────────┐   │   │
│                                        │  │  Silences DB │   │   │
│                                        │  │  (in-memory) │   │   │
│                                        │  └──────────────┘   │   │
│                                        └──────────┬──────────┘   │
│                                                   │               │
└───────────────────────────────────────────────────┼───────────────┘
                                                    │
                         ┌──────────────────────────┼──────────────────┐
                         ▼                          ▼                  ▼
                    PagerDuty                    Slack             OpsGenie
                   (critical)                 (warnings)          (backup)
```

### Core Concepts

**Grouping** — AlertManager batches multiple alerts that fire at the same time into a single
notification. Without grouping, a node failure that causes 50 alerts fires 50 pages.

```yaml
# Group alerts by cluster and alertname — one page per unique (cluster, alert) pair
route:
  group_by: ['cluster', 'alertname']
  group_wait: 30s        # Wait 30s before sending — more alerts may arrive
  group_interval: 5m     # If new alerts join the group, wait 5m before re-notifying
  repeat_interval: 4h    # Re-send if alert is still firing after 4 hours
```

**Inhibit Rules** — suppress child alerts when a parent alert is firing.
Classic use case: don't page about high error rates if the entire node is down.

```yaml
inhibit_rules:
  - source_match:
      severity: 'critical'
      alertname: 'NodeDown'
    target_match:
      severity: 'warning'
    # Only inhibit alerts that share the same 'instance' label
    equal: ['instance']
```

**Silences** — mute alerts during known maintenance windows.

```bash
# Create a silence for planned maintenance on the payments namespace
# Duration: 2 hours from now
amtool silence add \
  --alertmanager.url=http://alertmanager.monitoring:9093 \
  --duration=2h \
  --comment="Planned payments-api release v2.3.1" \
  namespace=payments

# List active silences
amtool silence query --alertmanager.url=http://alertmanager.monitoring:9093

# Expire a silence early (by its ID)
amtool silence expire <silence-id> \
  --alertmanager.url=http://alertmanager.monitoring:9093
```

### Full AlertManager ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-config
  namespace: monitoring
data:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
      # PagerDuty default URL
      pagerduty_url: 'https://events.pagerduty.com/v2/enqueue'

    templates:
      - '/etc/alertmanager/templates/*.tmpl'

    route:
      receiver: 'default-receiver'
      group_by: ['cluster', 'alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h

      routes:
        # Critical payments alerts → PagerDuty (immediate page)
        - match:
            team: payments
            severity: critical
          receiver: pagerduty-payments
          group_wait: 0s        # Fire immediately — no batching for critical
          repeat_interval: 1h

        # Warning payments alerts → Slack
        - match:
            team: payments
            severity: warning
          receiver: slack-payments
          repeat_interval: 6h

        # Watchdog alert (always fires — proves AlertManager is alive)
        - match:
            alertname: Watchdog
          receiver: 'null'

    receivers:
      - name: 'null'  # Swallows the alert silently

      - name: 'default-receiver'
        slack_configs:
          - api_url: '${SLACK_WEBHOOK_URL}'
            channel: '#alerts-general'
            send_resolved: true

      - name: 'pagerduty-payments'
        pagerduty_configs:
          - routing_key: '${PAGERDUTY_ROUTING_KEY}'
            description: '{{ template "pagerduty.default.description" . }}'
            details:
              runbook: '{{ (index .Alerts 0).Annotations.runbook_url }}'
              dashboard: '{{ (index .Alerts 0).Annotations.dashboard_url }}'
            send_resolved: true

      - name: 'slack-payments'
        slack_configs:
          - api_url: '${SLACK_WEBHOOK_URL}'
            channel: '#alerts-payments'
            title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
            text: |
              {{ range .Alerts }}
              *Alert:* {{ .Annotations.summary }}
              *Description:* {{ .Annotations.description }}
              *Runbook:* {{ .Annotations.runbook_url }}
              {{ end }}
            send_resolved: true

    inhibit_rules:
      - source_match:
          alertname: 'KubeNodeNotReady'
        target_match_re:
          alertname: 'Payments.*'
        equal: ['cluster']
```

---

## 3. Writing a PrometheusRule for the Payments API

### PrometheusRule Anatomy

A `PrometheusRule` is a Kubernetes CRD (from the `monitoring.coreos.com` API group) that
Prometheus Operator watches and loads automatically into Prometheus.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payments-api-alerts
  namespace: payments
  labels:
    # This label must match the PrometheusRule selector in your Prometheus CR
    prometheus: kube-prometheus
    role: alert-rules
    team: payments
spec:
  groups:
    - name: payments.api.availability
      interval: 30s   # How often this group is evaluated (overrides global)
      rules: []       # defined below
```

### Recording Rules First (Pre-Compute Expensive Queries)

Recording rules store the result of expensive queries so alerts evaluate fast:

```yaml
    - name: payments.api.recording
      interval: 30s
      rules:
        # Pre-compute 5-minute error rate for the payments API
        - record: job:payments_http_requests_errors:rate5m
          expr: |
            rate(http_requests_total{
              job="payments-api",
              namespace="payments",
              status=~"5.."
            }[5m])

        # Pre-compute 5-minute total request rate
        - record: job:payments_http_requests_total:rate5m
          expr: |
            rate(http_requests_total{
              job="payments-api",
              namespace="payments"
            }[5m])

        # Pre-compute p99 latency using histogram (requires _bucket metrics)
        - record: job:payments_request_duration_p99:rate5m
          expr: |
            histogram_quantile(0.99,
              rate(http_request_duration_seconds_bucket{
                job="payments-api",
                namespace="payments"
              }[5m])
            )
```

### Alert Rules — Availability, Latency, Saturation

```yaml
    - name: payments.api.availability
      interval: 30s
      rules:

        # ── Error Budget Burn Rate Alerts ────────────────────────────────────
        # Page immediately if we're burning budget 14.4x faster than allowed
        # (will exhaust 30-day budget in 50 hours)
        - alert: PaymentsAPIHighErrorBudgetBurn
          expr: |
            (
              job:payments_http_requests_errors:rate5m
              / job:payments_http_requests_total:rate5m
            ) > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            team: payments
            slo: "payments-api-availability"
          annotations:
            summary: "Payments API burning error budget 14.4x faster than allowed"
            description: |
              Error rate {{ $value | humanizePercentage }} detected on payments-api.
              At this rate the 30-day error budget will be exhausted in ~50 hours.
            runbook_url: "https://wiki.internal/runbooks/payments-api-high-error-rate"
            dashboard_url: "https://grafana.internal/d/payments-overview"

        # Warn if burn rate is 6x — slower burn, but worth investigating
        - alert: PaymentsAPIModerateErrorBudgetBurn
          expr: |
            (
              job:payments_http_requests_errors:rate5m
              / job:payments_http_requests_total:rate5m
            ) > (6 * 0.001)
          for: 15m
          labels:
            severity: warning
            team: payments
          annotations:
            summary: "Payments API error rate elevated"
            description: "Error rate {{ $value | humanizePercentage }}. Budget burn rate ~6x."
            runbook_url: "https://wiki.internal/runbooks/payments-api-high-error-rate"

        # ── Latency Alerts ───────────────────────────────────────────────────
        - alert: PaymentsAPIHighP99Latency
          expr: job:payments_request_duration_p99:rate5m > 0.5
          for: 5m
          labels:
            severity: critical
            team: payments
          annotations:
            summary: "Payments API p99 latency exceeds 500ms SLO"
            description: |
              p99 latency is {{ $value | humanizeDuration }}.
              SLO requires p99 < 500ms.
            runbook_url: "https://wiki.internal/runbooks/payments-api-high-latency"

        # ── Saturation Alerts ────────────────────────────────────────────────
        - alert: PaymentsAPIPodCountLow
          expr: |
            kube_deployment_status_replicas_available{
              deployment="payments-api",
              namespace="payments"
            } < 2
          for: 5m
          labels:
            severity: critical
            team: payments
          annotations:
            summary: "Payments API has fewer than 2 available replicas"
            description: |
              Only {{ $value }} replicas are available.
              Minimum required: 2. Service may be degraded.
            runbook_url: "https://wiki.internal/runbooks/payments-api-pod-count-low"

        # ── Dependency Alerts ────────────────────────────────────────────────
        - alert: PaymentsDBConnectionPoolExhausted
          expr: |
            pgbouncer_pools_cl_waiting{database="payments"} > 10
          for: 2m
          labels:
            severity: critical
            team: payments
          annotations:
            summary: "PgBouncer connection pool exhausted for payments DB"
            description: |
              {{ $value }} clients are waiting for a DB connection.
              This will cause payment timeouts within seconds.
            runbook_url: "https://wiki.internal/runbooks/payments-db-connection-pool"

        # ── Watchdog (always fires — proves the pipeline is alive) ───────────
        - alert: Watchdog
          expr: vector(1)
          labels:
            severity: none
          annotations:
            summary: "Confirming Prometheus → AlertManager pipeline is alive"
```

### Apply and Verify

```bash
# Apply the PrometheusRule
kubectl apply -f payments-prometheusrule.yaml

# Verify Prometheus loaded it (no errors)
kubectl exec -n monitoring prometheus-kube-prometheus-prometheus-0 -- \
  promtool check rules /etc/prometheus/rules/payments-api-alerts.yaml

# Check that rules appear in Prometheus UI
kubectl port-forward -n monitoring svc/kube-prometheus-prometheus 9090:9090 &
# Open http://localhost:9090/rules → look for "payments.api.availability" group

# Trigger a test alert by querying the rule expression directly
kubectl exec -n monitoring prometheus-kube-prometheus-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  'job:payments_http_requests_errors:rate5m / job:payments_http_requests_total:rate5m'

# Check AlertManager is receiving alerts
kubectl port-forward -n monitoring svc/kube-prometheus-alertmanager 9093:9093 &
# Open http://localhost:9093/#/alerts
```

---

## 4. PagerDuty / OpsGenie Integration

### PagerDuty Setup

PagerDuty uses **routing keys** (formerly integration keys) to accept events from external systems.

```bash
# ── PagerDuty Side ──────────────────────────────────────────────────────────
# 1. In PagerDuty: Services → Add Integration → Prometheus
# 2. Copy the "Integration Key" (32-character hex string)
# 3. This becomes your PAGERDUTY_ROUTING_KEY

# ── Kubernetes Side ─────────────────────────────────────────────────────────
# Store the key as a Kubernetes Secret (never hardcode it in the ConfigMap)
kubectl create secret generic alertmanager-pagerduty \
  --from-literal=routing-key=YOUR_32_CHAR_ROUTING_KEY \
  --namespace=monitoring

# Reference it in the AlertManager deployment as an environment variable
# (kube-prometheus-stack handles this via values.yaml)
```

AlertManager config for PagerDuty (using the secret mounted as env var):

```yaml
receivers:
  - name: 'pagerduty-payments'
    pagerduty_configs:
      - routing_key: '${PAGERDUTY_ROUTING_KEY}'
        severity: '{{ if eq .Labels.severity "critical" }}critical{{ else }}warning{{ end }}'
        client: 'AlertManager on gke-labs-dev'
        client_url: 'https://alertmanager.internal'
        description: '{{ template "pagerduty.default.description" . }}'
        details:
          firing:      '{{ .Alerts.Firing | len }}'
          resolved:    '{{ .Alerts.Resolved | len }}'
          num_firing:  '{{ .Alerts.Firing | len }}'
          runbook:     '{{ (index .Alerts 0).Annotations.runbook_url }}'
          namespace:   '{{ (index .Alerts 0).Labels.namespace }}'
          pod:         '{{ (index .Alerts 0).Labels.pod }}'
        links:
          - href: '{{ (index .Alerts 0).Annotations.runbook_url }}'
            text: 'Runbook'
          - href: '{{ (index .Alerts 0).Annotations.dashboard_url }}'
            text: 'Dashboard'
```

### OpsGenie as a Backup / Escalation Path

```yaml
receivers:
  - name: 'opsgenie-escalation'
    opsgenie_configs:
      - api_key: '${OPSGENIE_API_KEY}'
        api_url: 'https://api.opsgenie.com/'
        message: '{{ .GroupLabels.alertname }}'
        description: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
        priority: '{{ if eq (index .Alerts 0).Labels.severity "critical" }}P1{{ else }}P3{{ end }}'
        tags: 'payments,gke,{{ .GroupLabels.cluster }}'
        details:
          runbook: '{{ (index .Alerts 0).Annotations.runbook_url }}'

# Escalation route: if PagerDuty doesn't acknowledge within 30 min, fire OpsGenie
route:
  routes:
    - match:
        severity: critical
        team: payments
      receiver: pagerduty-payments
      # child route: escalate if this alert keeps firing after 30 min
      routes:
        - match:
            severity: critical
          receiver: opsgenie-escalation
          repeat_interval: 30m
```

### Testing the Integration End-to-End

```bash
# Send a test alert manually using amtool
amtool alert add \
  --alertmanager.url=http://localhost:9093 \
  alertname=TestPaymentsAlert \
  severity=critical \
  team=payments \
  namespace=payments \
  --annotation=summary="Test alert from amtool" \
  --annotation=runbook_url="https://wiki.internal/runbooks/test"

# Verify it appears in AlertManager UI
curl -s http://localhost:9093/api/v2/alerts | jq '.[] | {alertname: .labels.alertname, status: .status}'

# Verify it was sent to PagerDuty/Slack by checking AlertManager logs
kubectl logs -n monitoring alertmanager-kube-prometheus-alertmanager-0 \
  --tail=50 | grep -E "notify|pagerduty|slack"
```

---

## 5. Runbook Structure — What Makes a Good Runbook

### The Problem with Bad Runbooks

A runbook written at 2 PM by a well-rested engineer, full of institutional knowledge,
is useless at 3 AM to an on-call engineer who joined three weeks ago.

Bad runbook signals:
- "Check the logs and fix the issue"
- Requires tribal knowledge not in the doc
- Doesn't tell you what "fixed" looks like
- Written for the author, not the reader

### Runbook Template

```markdown
# Runbook: PaymentsAPIHighErrorBudgetBurn

**Last updated:** 2024-01-15
**Maintainer:** @payments-team
**SLO affected:** payments-api-availability (99.9% target)
**Severity:** Critical
**Est. resolution time:** 15–30 min (known cause), 30–90 min (unknown cause)

---

## Alert Description

The payments API is returning HTTP 5xx errors at a rate that will exhaust the
30-day error budget within 50 hours. Immediate action is required.

---

## Symptoms

- PagerDuty: "Payments API burning error budget 14.4x faster than allowed"
- Grafana: [Payments Overview Dashboard](https://grafana.internal/d/payments-overview)
  shows elevated error rate in the top-left panel
- Users: "Payment failed" errors in the mobile app / checkout page

---

## Immediate Triage (first 5 minutes)

### Step 1 — Check pod health

kubectl get pods -n payments -l app=payments-api
# Expected: all pods Running
# Red flag: CrashLoopBackOff, OOMKilled, ImagePullBackOff

### Step 2 — Check recent error logs

kubectl logs -n payments -l app=payments-api --tail=100 | grep -i "error\|panic\|fatal"
# Look for: database connection errors, timeout errors, panic stack traces

### Step 3 — Check if it's a downstream issue

kubectl exec -n payments deploy/payments-api -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://cloud-sql-proxy.payments:5432/health
# If this fails → database issue (go to DB runbook)
# If this succeeds → application code issue (continue below)

### Step 4 — Check recent deploys

kubectl rollout history deployment/payments-api -n payments
kubectl get events -n payments --sort-by='.lastTimestamp' | tail -20

---

## Diagnosis Decision Tree

Error logs show DB connection refused?
  YES → Go to: Runbook: PaymentsDBConnectionPoolExhausted
  NO  → Continue

Pods in CrashLoopBackOff?
  YES → kubectl describe pod <pod> -n payments
        Check "Last State: Terminated / Reason: OOMKilled"?
          YES → Increase memory limits (see fix below)
          NO  → Check pod logs for startup errors
  NO  → Continue

Recent deployment < 30 min ago?
  YES → Roll back: kubectl rollout undo deployment/payments-api -n payments
        Wait 5 minutes, check error rate in Grafana
  NO  → Continue

---

## Fixes

### Fix A — Roll back a bad deployment

kubectl rollout undo deployment/payments-api -n payments
kubectl rollout status deployment/payments-api -n payments --timeout=120s

# Verify: error rate should drop to near-zero within 2 minutes
# Check: https://grafana.internal/d/payments-overview

### Fix B — Restart pods (clears transient errors)

kubectl rollout restart deployment/payments-api -n payments
kubectl rollout status deployment/payments-api -n payments --timeout=120s

### Fix C — Scale up if under load

kubectl scale deployment/payments-api --replicas=6 -n payments
# Default is 3. Scaling to 6 handles 2x load without HPA lag.

---

## Escalation

- 5 min without improvement → page @payments-oncall-lead
- 15 min without improvement → page @payments-engineering-manager
- Database involved → page @platform-dba-oncall simultaneously

---

## Post-Incident

After resolving: file incident report in #incidents within 24 hours.
Update this runbook if you encountered a scenario not covered above.
```

### Where to Store Runbooks

| Option | Pros | Cons |
|--------|------|------|
| Git repo wiki | Version controlled, PR review process | Harder to search during incident |
| Notion / Confluence | Fast search, rich formatting | No history if someone edits wrong |
| Runbook URL in alert annotation | One click from PagerDuty | Must keep URL stable |
| In-code comments next to the PrometheusRule | Always co-located | Only engineers can read |

**Best practice:** Git repo + `runbook_url` annotation on every alert that links to it.

---

## 6. Alert Fatigue — Why Less Is More

### The Cost of Too Many Alerts

Alert fatigue is when on-call engineers stop taking alerts seriously because there are too
many of them. This is an existential threat to your on-call rotation.

```
Signal-to-noise ratio degradation:

  Week 1:  3 alerts/day  → 100% investigated thoroughly
  Week 4:  30 alerts/day → "Which ones are real?" → some dismissed
  Week 8:  80 alerts/day → Engineers start silencing everything
  Week 12: Real P0 fires  → Engineer misses it — it's buried in noise
```

### Symptom-Based vs Cause-Based Alerts

**Anti-pattern (cause-based):** Alert on every possible cause of failure.
- "CPU > 80%" — fires 20x/day, almost never correlates with user impact
- "Pod restart detected" — fires on every deployment
- "Disk > 70%" — weeks before it's actually a problem

**Best practice (symptom-based):** Alert when *users are affected*, and investigate causes in dashboards.

```
Cause-based alert pyramid (problematic)           Symptom-based alerts (good)
──────────────────────────────────────            ──────────────────────────
  CPU high                                         SLO error rate high
  Memory high           → many alerts →            SLO latency high
  Disk high               alert fatigue            SLO availability low
  Pod restarts
  GC pressure
  Connection pool warn
  Certificate expiry
  ...
```

### Severity Taxonomy

| Severity | Definition | Delivery | Expectation |
|----------|-----------|----------|-------------|
| `critical` | Users impacted now, SLO burning | Page (wakes people up) | Respond in 5 min |
| `warning` | Trending toward impact, no SLO breach yet | Slack | Investigate in 1 hour |
| `info` | Informational, no action usually needed | Dashboard / email digest | Review weekly |
| `none` / `watchdog` | Infrastructure health checks | Route to `/dev/null` | Never pages |

### Alert Review Checklist

Before merging any new alert, ask:

```
□ Does this alert correspond to a user-facing symptom?
□ Is there a runbook linked in the annotations?
□ Can an on-call engineer fix this at 3 AM with only the runbook?
□ Is the `for` duration long enough to avoid flapping? (>= 5 min for warnings)
□ Does this alert duplicate an existing one?
□ Have we tested this alert fires AND resolves in staging?
□ Is the severity correct (would this actually wake someone up)?
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1 — Trigger a Real Alert

**Goal:** Cause the `PaymentsAPIHighErrorBudgetBurn` alert to fire by injecting errors.

```bash
# Deploy a broken version of payments-api that returns 500s
kubectl set env deployment/payments-api \
  -n payments \
  FORCE_ERROR_RATE=0.05  # 5% error rate → burn rate = 50x

# Watch the alert fire in AlertManager
kubectl port-forward -n monitoring svc/kube-prometheus-alertmanager 9093:9093 &
# Open http://localhost:9093/#/alerts
# Within 2 minutes you should see PaymentsAPIHighErrorBudgetBurn in FIRING state

# Generate traffic to make errors visible
for i in $(seq 1 50); do
  curl -s http://localhost:8080/api/payments > /dev/null
  sleep 0.1
done

# Check Prometheus rule evaluation
curl -s 'http://localhost:9090/api/v1/query?query=ALERTS{alertname="PaymentsAPIHighErrorBudgetBurn"}' \
  | jq '.data.result'

# Fix it
kubectl set env deployment/payments-api -n payments FORCE_ERROR_RATE-

# Watch alert resolve (state changes to "resolved")
kubectl port-forward -n monitoring svc/kube-prometheus-alertmanager 9093:9093 &
# Open http://localhost:9093/#/alerts — alert should disappear within 5 minutes
```

---

### Exercise 2 — Create and Expire a Silence

**Goal:** Practice silencing alerts for a maintenance window.

```bash
# Install amtool if not present
go install github.com/prometheus/alertmanager/cmd/amtool@latest
# or use the binary from the AlertManager pod

# Port-forward AlertManager
kubectl port-forward -n monitoring svc/kube-prometheus-alertmanager 9093:9093 &

# Create a 30-minute silence for the payments namespace
SILENCE_ID=$(amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --duration=30m \
  --comment="Lab 13 Exercise 2 — planned maintenance" \
  namespace=payments)

echo "Silence ID: $SILENCE_ID"

# Verify the silence is active
amtool silence query --alertmanager.url=http://localhost:9093

# Trigger an alert (it should be silenced — not delivered)
kubectl set env deployment/payments-api -n payments FORCE_ERROR_RATE=0.05
sleep 120  # Wait for alert to evaluate

# Check AlertManager — alert is in SUPPRESSED state (not FIRING for notification)
curl -s http://localhost:9093/api/v2/alerts | jq '.[] | select(.status.state == "suppressed")'

# Expire the silence early
amtool silence expire $SILENCE_ID --alertmanager.url=http://localhost:9093

# Now the alert should become active and page
amtool silence query --alertmanager.url=http://localhost:9093
# → Silence should show as expired

# Cleanup
kubectl set env deployment/payments-api -n payments FORCE_ERROR_RATE-
```

---

### Exercise 3 — Debug a Missing Alert

**Goal:** Understand why an alert you expect to fire isn't firing.

```bash
# Scenario: you added a PrometheusRule but it never fires. Debug the pipeline.

# Step 1 — Verify the rule was loaded by Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-prometheus 9090:9090 &
# http://localhost:9090/rules → search for your rule group

# If it's missing, check if the PrometheusRule labels match
kubectl get prometheus -n monitoring kube-prometheus-prometheus -o yaml \
  | grep -A 10 "ruleSelector"

kubectl get prometheusrule payments-api-alerts -n payments -o yaml \
  | grep -A 5 "labels:"

# The labels on the PrometheusRule MUST match the ruleSelector on the Prometheus CR
# Common mistake: wrong label value for 'prometheus' or 'role'

# Step 2 — Verify the metric actually exists
curl -s 'http://localhost:9090/api/v1/query?query=http_requests_total{job="payments-api"}' \
  | jq '.data.result | length'
# If 0 → the ServiceMonitor isn't scraping the payments-api

# Step 3 — Check ServiceMonitor
kubectl get servicemonitor -n payments
kubectl describe servicemonitor payments-api -n payments
# Verify: selector matches payments-api service labels

# Step 4 — Check Prometheus targets
# http://localhost:9090/targets → look for payments-api
# If state is DOWN → Prometheus can't reach the payments-api /metrics endpoint

# Step 5 — Test the alert expression manually
curl -s 'http://localhost:9090/api/v1/query?query=rate(http_requests_total{job="payments-api",status=~"5.."}[5m])' \
  | jq '.'
```

---

## 8. Interview Q&A

---

### Q1: What is the difference between an SLO and an SLA, and why should your SLO be stricter?

**Answer:**

An **SLO (Service Level Objective)** is an internal engineering target — the reliability level you
*aim* to achieve. An **SLA (Service Level Agreement)** is a contract with customers that specifies
consequences (usually credits or refunds) for missing availability targets.

The SLO must be stricter than the SLA for two reasons:

1. **Buffer for measurement drift.** Your internal monitoring and the customer's perception of
   availability rarely measure exactly the same thing. You need headroom.

2. **Operational reaction time.** If your SLA is 99.9%, you need to alert and respond to a
   problem *before* you breach 99.9%. Your SLO might be 99.95%, so you page when burn rate
   threatens the 99.95% target — giving you time to fix it before the SLA breach.

Common practice: SLO = SLA + one nine (e.g., SLA is 99.9%, SLO is 99.95%).

---

### Q2: Explain error budget burn rate. Why do multi-window burn rate alerts outperform single-window?

**Answer:**

**Burn rate** is the ratio of your current error rate to your allowed error rate.
At burn rate 1, you're spending budget at exactly the SLO-allowed pace.
At burn rate 14.4, you'll exhaust a 30-day budget in 50 hours.

A **single-window alert** (e.g., "error rate > 1% for 5 minutes") has two failure modes:
- **False positives:** a 2-minute spike fires the alert even if budget impact is trivial
- **Missed slow burns:** a consistent 0.5% error rate (below the threshold) slowly drains budget
  over weeks without ever alerting

**Multi-window burn rate** solves this by requiring the burn rate to be elevated in *both* a
short window (recent severity) and a long window (sustained impact):

```yaml
# Page if burn rate is high over BOTH 1h and 5m windows
# (short window prevents flapping on spikes, long window ensures it's sustained)
expr: |
  (
    rate(errors[1h]) / rate(total[1h]) > 14.4 * 0.001
  ) and (
    rate(errors[5m]) / rate(total[5m]) > 14.4 * 0.001
  )
```

Google's SRE book recommends a 4-alert multi-window scheme (2 critical, 2 warning) covering
different burn rates and windows to catch both fast burns and slow burns.

---

### Q3: An alert is firing but AlertManager isn't sending a page. What do you check?

**Answer:**

Work through the pipeline from right to left:

```bash
# 1. Is the alert actually in AlertManager?
curl http://localhost:9093/api/v2/alerts | jq '.[].labels.alertname'

# 2. Is the alert silenced?
# http://localhost:9093/#/silences — check for active silences
# amtool silence query

# 3. Is the alert inhibited?
# Check inhibit_rules in alertmanager.yaml — is a source alert firing?
curl http://localhost:9093/api/v2/alerts | jq '.[] | {name: .labels.alertname, inhibited: .status.inhibitedBy}'

# 4. Does the alert's labels match any route?
# AlertManager has a "debug" endpoint:
amtool config routes test --alertmanager.url=http://localhost:9093 \
  severity=critical team=payments
# Output shows which receiver the alert would be sent to

# 5. Is the receiver misconfigured?
kubectl logs -n monitoring alertmanager-kube-prometheus-alertmanager-0 \
  | grep -i "error\|failed\|notify"
# Common errors: invalid PagerDuty key, Slack webhook 404, TLS cert issues

# 6. Is it in group_wait? Alert just fired and group_wait=30s hasn't elapsed
# group_wait is the initial hold before first notification — normal behavior
```

---

### Q4: What is the Watchdog alert and why do you need it?

**Answer:**

The Watchdog alert is a PrometheusRule that always evaluates to `true` (using `vector(1)`).
It fires constantly, which seems counterintuitive.

Its purpose is to prove that the **entire alerting pipeline is alive**: Prometheus is evaluating
rules → AlertManager is receiving alerts → AlertManager is routing to receivers.

Without a Watchdog, a failure in any part of the pipeline is silent. If AlertManager crashes, or
its Slack/PagerDuty credentials expire, or the Prometheus rule evaluation fails — you'd never know.
You'd only find out when a real incident occurs and no one gets paged.

In practice, you route the Watchdog to a low-noise channel (a dedicated Slack bot that posts
"heartbeat OK" once per hour) and set up a **dead man's switch**: if that heartbeat stops arriving,
an external system (like PagerDuty's "Heartbeat" feature or a simple monitoring cron) pages you.

---

### Q5: How do you prevent alert storms when a single root cause triggers dozens of alerts?

**Answer:**

Three mechanisms in combination:

**1. Inhibit Rules** — suppress symptom alerts when the root cause alert is firing.
If `NodeDown` is firing for a node, inhibit all pod-level alerts for pods on that node.
The key is the `equal` field — only inhibit alerts that share the same label (e.g., `instance`).

**2. Alert Grouping** — `group_by` in AlertManager batches related alerts into one notification.
A node failure that spawns 20 pod alerts arrives as one page: "20 alerts firing in cluster=gke-labs-dev".

**3. Symptom-Based Alerting** — If you only alert on user-facing symptoms (SLO burn rate),
a node failure that causes increased error rate fires exactly *one* alert: the burn rate alert.
You investigate the cause in Grafana, not via pager.

In practice for the payments API: a Cloud SQL failover triggers increased latency and some errors.
A cause-based approach pages 5 times (connection pool, retry count, error rate, latency, pod restarts).
A symptom-based approach pages once: `PaymentsAPIHighErrorBudgetBurn`. One runbook. One investigation.

---

### Q6: What makes a runbook good vs useless at 3 AM?

**Answer:**

A good runbook has six properties:

1. **Self-contained** — the on-call engineer needs zero prior knowledge. Every term is defined.
   No "check the usual place" — explicit paths and commands.

2. **Decision tree, not prose** — structured as IF/THEN/ELSE branches. At 3 AM, humans cannot
   parse paragraphs. "If X, run Y, expect Z, if Z → step 4, if not Z → step 5."

3. **Copy-paste commands** — real commands with real resource names (namespace, deployment,
   cluster). Not `kubectl get pods` but `kubectl get pods -n payments -l app=payments-api`.

4. **Defines "fixed"** — explicitly states what the system looks like when the issue is resolved.
   "Error rate should drop below 0.1% within 2 minutes of the rollback completing."

5. **Escalation path** — when to stop trying and wake someone else up. Time-boxed:
   "If not resolved in 15 minutes, page @payments-lead."

6. **Versioned and reviewed** — runbooks in Git get PR review. Stale runbooks (pointing to
   deleted resources) are worse than no runbook. Review as part of incident retrospectives.

---

*Next: [Lab 14 — Temporal Workflows](../14-temporal-workflows/README.md)*
