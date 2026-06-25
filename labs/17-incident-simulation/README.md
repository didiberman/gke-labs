# Lab 17 — Incident Simulation

> **Goal:** Run three realistic production incidents from first page to post-mortem. Each scenario
> synthesizes skills from the entire lab series — monitoring, kubectl debugging, database ops, and
> deployment rollbacks — into the kind of high-pressure situation you face on call. By the end you
> should be able to walk through any incident calmly, with a methodical process.

> **Series position:** This is the capstone lab. Labs 01–16 built the payments platform. This lab
> breaks it and makes you fix it. No new concepts — only applied judgment under simulated pressure.

---

## Table of Contents

1. [Incident Response Framework — Declare, Triage, Mitigate, Resolve, Post-mortem](#1-incident-response-framework)
2. [Scenario A — The Payments API Is Returning 500s](#2-scenario-a--the-payments-api-is-returning-500s)
3. [Scenario B — Database Connection Pool Exhausted](#3-scenario-b--database-connection-pool-exhausted)
4. [Scenario C — Grafana Shows No Data After a Deploy](#4-scenario-c--grafana-shows-no-data-after-a-deploy)
5. [Writing a Post-mortem — 5-Why Analysis](#5-writing-a-post-mortem--5-why-analysis)
6. [Interview Q&A](#6-interview-qa)

---

## 1. Incident Response Framework

### The Five Phases

Every incident, from a 2-minute alert flap to a 4-hour P0 outage, follows the same structure.
Having a framework prevents thrashing and reduces time-to-mitigation.

```
  1. DECLARE   2. TRIAGE    3. MITIGATE   4. RESOLVE    5. POST-MORTEM
  ──────────   ──────────   ───────────   ──────────    ──────────────
  Alert fires  What is      Stop the      Find root     Why did this
  Acknowledge  the scope?   bleeding      cause         happen?
  Create war   Who is       Rollback /    Fix properly  5-why analysis
  room         affected?    scale up /    Monitor for   Action items
  Assign IC    Severity?    disable feat  recurrence    Blameless doc
```

**Incident Commander (IC):** One person coordinates. Others execute. Without a clear IC,
multiple engineers pull in different directions and communications collapse.

**War Room (Slack channel / Bridge):** Create `#incident-YYYYMMDD-payments-api-500s` immediately.
All updates go there. Stakeholders join to observe, not to direct.

**Severity Levels:**

| Severity | Definition | Expected Response | Example |
|----------|-----------|------------------|---------|
| SEV-1 | Complete service down, revenue-impacting | IC in 5 min, all-hands | Payments API returning 100% 500s |
| SEV-2 | Major feature degraded, partial data loss possible | IC in 15 min, team on-call | p99 latency > 5s, 10% errors |
| SEV-3 | Minor degradation, no data loss, workaround exists | Next business day | Dashboard missing some metrics |
| SEV-4 | Cosmetic / informational | Planned sprint work | Alert too noisy, no impact |

### The On-Call Mindset

```
What you should do:               What you should NOT do:
─────────────────────────         ─────────────────────────
Communicate frequently            Silently debug for 30 min
"I'm looking at X right now"      Make irreversible changes without backup
Confirm the scope first           Try every fix simultaneously
Work one hypothesis at a time     Skip the rollback — "the code looks fine"
Ask for help early                Blame the engineer who deployed
Document as you go                Wait for perfect understanding before mitigating
```

---

## 2. Scenario A — The Payments API Is Returning 500s

### The Story

It's 2:47 AM. PagerDuty fires `PaymentsAPIHighErrorBudgetBurn`. The payments API has an error
rate of 45%. The SLO breach is 3 minutes away. Investigate and mitigate.

---

### Alarm — What the Alert Looks Like

```
PagerDuty Alert:
  Title: Payments API burning error budget 14.4x faster than allowed
  Severity: CRITICAL
  Summary: Error rate 45% detected on payments-api.
           At this rate the 30-day error budget will be exhausted in ~50 hours.
  Dashboard: https://grafana.internal/d/payments-overview
  Runbook:   https://wiki.internal/runbooks/payments-api-high-error-rate
  Labels:    namespace=payments, team=payments, cluster=gke-labs-dev
```

```
Grafana: payments-overview
  HTTP Error Rate:  ████████████████████  45%   ← bright red
  p99 Latency:      ░░░░░░░░░░░░░░░░░░░░  120ms  ← normal
  Pod Count:        ░░░░░░░░░░░░░░░░░░░░  3/3    ← normal
  DB Connections:   ░░░░░░░░░░░░░░░░░░░░  12/20  ← normal
```

**Initial read:** High error rate, normal latency, normal pod count, normal DB connections.
This is an application-level error, not infrastructure saturation.

---

### Clues — kubectl Commands That Reveal the Root Cause

**Step 1 — Was there a recent deployment?**

```bash
kubectl rollout history deployment/payments-api -n payments
# REVISION  CHANGE-CAUSE
# 1         initial deployment
# 2         added merchant lookup feature
# 3         <none>   ← deployed 12 minutes ago, just before the alert

kubectl get events -n payments --sort-by='.lastTimestamp' | tail -20
# 02:35:17  Normal   ScalingReplicaSet  Deployment/payments-api
#           Scaled down replica set payments-api-v2-abc to 0
#           Scaled up replica set payments-api-v3-xyz to 3
# ← Deployment finished at 02:35. Alert fired at 02:39. Causally related.
```

**Step 2 — What are the pods saying?**

```bash
kubectl get pods -n payments -l app=payments-api
# NAME                           READY   STATUS    RESTARTS   AGE
# payments-api-v3-xyz-aaaa       1/1     Running   0          14m
# payments-api-v3-xyz-bbbb       1/1     Running   4          14m  ← 4 restarts!
# payments-api-v3-xyz-cccc       1/1     Running   3          14m  ← 3 restarts!

kubectl describe pod payments-api-v3-xyz-bbbb -n payments | grep -A 10 "Last State:"
# Last State:     Terminated
#   Reason:       OOMKilled
#   Exit Code:    137
#   Started:      Wed, 15 Jan 2024 02:41:00 +0000
#   Finished:     Wed, 15 Jan 2024 02:41:47 +0000

# OOMKilled = pod exceeded its memory limit and was killed by the kernel
```

**Step 3 — Why is it OOMKilling?**

```bash
# Check the current memory limit
kubectl get deployment payments-api -n payments -o yaml \
  | grep -A 5 "resources:"
# resources:
#   requests:
#     memory: 128Mi
#   limits:
#     memory: 256Mi   ← only 256MB limit

# Check actual memory usage in the surviving pod
kubectl top pods -n payments -l app=payments-api
# NAME                     CPU(cores)   MEMORY(bytes)
# payments-api-v3-xyz-aaaa 45m          251Mi   ← 251Mi of 256Mi limit — nearly full!
# payments-api-v3-xyz-bbbb 2m           12Mi    ← just restarted
# payments-api-v3-xyz-cccc 3m           18Mi    ← just restarted

# Check recent commits for memory-related changes
kubectl exec -n payments payments-api-v3-xyz-aaaa -- env | grep -i cache
# MERCHANT_CACHE_SIZE=unlimited   ← new env var from revision 3 — unbounded in-memory cache!
```

**Root Cause Found:**
The new merchant lookup feature introduced an unbounded in-memory cache. Under production load,
the cache grew to 251MB, hit the 256MB limit, and the kernel killed the process. The pod restarts
briefly restore service, but the cache refills and the kill cycle repeats. 45% error rate is
the fraction of requests that arrive while the pod is restarting.

---

### Fix — The Actual Fix with Commands

**Mitigation (immediate — stop the bleeding):**

```bash
# Option A — Roll back the deployment (fastest, most reliable)
kubectl rollout undo deployment/payments-api -n payments
# Reverts to revision 2, which had no memory issue

# Watch pods come back
kubectl rollout status deployment/payments-api -n payments
# Waiting for deployment "payments-api" rollout to finish: 2 out of 3 new replicas have been updated...
# Waiting for deployment "payments-api" rollout to finish: 1 old replicas are pending termination...
# deployment "payments-api" successfully rolled out

# Verify error rate drops
# In Grafana: the error rate should fall to near-zero within 2 minutes of the rollout completing

# Option B — If rollback is not desired (e.g., other critical fixes in revision 3)
# Increase the memory limit to give the cache room + add a cache size limit
kubectl set resources deployment payments-api \
  -n payments \
  --limits=memory=512Mi \
  --requests=memory=256Mi
# AND fix the code to use a bounded cache (LRU with max entries)
```

**Verify the fix:**

```bash
# 1. Check pod stability (no more restarts)
kubectl get pods -n payments -l app=payments-api -w
# All pods should show 0 restarts and stay Running

# 2. Check error rate in Grafana
# http://localhost:3000/d/payments-overview
# Error rate should drop to <0.1% within 5 minutes

# 3. Check SLO burn rate in Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=rate(http_requests_total{job="payments-api",status=~"5.."}[5m])/rate(http_requests_total{job="payments-api"}[5m])' \
  | jq '.data.result[0].value[1]'
# Expected: "0.0001" or similar (near zero)
```

---

### Prevention — What Architectural Change Prevents Recurrence

```yaml
# 1. Always set resource limits in all Deployments
# Enforce via Kyverno policy (Lab 15):
#   validationFailureAction: Enforce
#   require CPU and memory limits on all pods in 'payments' namespace

# 2. Add a pre-deploy load test in CI/CD
# Run a 2-minute Locust test after every deploy to staging before production

# 3. Add a canary deployment gate
# Deploy revision 3 to 5% of traffic first, monitor for 10 minutes
# kubectl argo rollouts set weight payments-api 5 --namespace=payments
# Only promote to 100% if error rate stays below 0.5%

# 4. Use a bounded LRU cache in code (fix the root cause, not just the symptom)
# Go example:
# import "github.com/hashicorp/golang-lru/v2"
# cache, _ := lru.New[string, MerchantInfo](10000)  // max 10,000 entries
```

---

## 3. Scenario B — Database Connection Pool Exhausted

### The Story

Monday morning, 09:15. The week starts and the payments API goes to 100% errors. Traffic is
normal — nothing special happened overnight. The Grafana DB connections panel is off the chart.

---

### Alarm — What the Alert Looks Like

```
PagerDuty Alert:
  Title: PgBouncer connection pool exhausted for payments DB
  Severity: CRITICAL
  Summary: 87 clients are waiting for a DB connection.
           This will cause payment timeouts within seconds.
  Labels:  namespace=payments, alertname=PaymentsDBConnectionPoolExhausted
```

```
Grafana: payments-overview
  HTTP Error Rate:  ████████████████████  100%   ← every request failing
  p99 Latency:      ████████████████████  30s    ← timeout
  Pod Count:        ░░░░░░░░░░░░░░░░░░░░  12/12  ← HPA scaled up (makes it worse)
  DB Connections:   ████████████████████  400/400 ← MAXED OUT
```

**Initial read:** 100% errors, max DB connections, HPA scaled up. Classic connection exhaustion.
The HPA scaling is a feedback loop — more pods means more DB connections means more errors.

---

### Clues — Commands That Reveal the Root Cause

**Step 1 — What's happening at the DB level?**

```bash
# Connect to PostgreSQL and check active connections
gcloud sql connect payments-db --user=postgres --project=gke-labs

# Inside psql:
SELECT count(*), state, wait_event_type, wait_event
FROM pg_stat_activity
GROUP BY state, wait_event_type, wait_event
ORDER BY count DESC;

# Output:
#  count | state  | wait_event_type | wait_event
# ───────────────────────────────────────────────
#    380 | active | Client          | ClientRead
#     18 | idle   | Client          | ClientRead
#      2 | active | Lock            | relation     ← 2 connections waiting on locks

SELECT max_connections FROM pg_settings WHERE name = 'max_connections';
# 400 — we're at 380/400 = 95% utilized

# Who is holding all these connections?
SELECT application_name, count(*) FROM pg_stat_activity GROUP BY application_name;
# payments-api         340
# pgbouncer            20
# temporal-worker      15
# reporting-job         7   ← interesting, should be 0 during business hours
```

**Step 2 — Why does payments-api have 340 connections? PgBouncer should cap it at 20.**

```bash
# Check if the payments-api pods are connecting DIRECTLY to Cloud SQL (bypassing PgBouncer)
kubectl get deployment payments-api -n payments -o yaml | grep DB_HOST
#   value: cloud-sql-proxy.payments   ← NOT pgbouncer.payments! Direct connection!

# Check when this changed
kubectl rollout history deployment/payments-api -n payments
# REVISION  CHANGE-CAUSE
# 4         updated DB_HOST to cloud-sql-proxy.payments
# ← someone changed DB_HOST during a "hotfix" over the weekend

# Check the number of pods × connections per pod
kubectl get pods -n payments -l app=payments-api --no-headers | wc -l
# 12 pods (HPA scaled up)
# 12 × 20 connections per pgx pool = 240 direct connections
# + temporal-worker 15 + reporting-job 7 + pgbouncer 20 = ~282
# Close enough to the 380 we see (some slack in pool accounting)
```

**Step 3 — Why is the reporting job running at 09:15?**

```bash
kubectl get cronjob -n payments
# NAME              SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# monthly-report    0 9 1 * *   False     1        9m              45d
# ← runs on the 1st of the month at 09:00 — today IS the 1st!

kubectl get jobs -n payments
# NAME                       COMPLETIONS   DURATION   AGE
# monthly-report-1705396800  0/1           9m         9m

kubectl logs -n payments job/monthly-report --tail=20
# Running full table scan on transactions for monthly report...
# Opened 7 database connections
# Query running: SELECT * FROM transactions WHERE date_trunc('month', created_at) = ...
# [query has been running for 9 minutes — holding 7 connections]
```

**Root Cause Found:**
Two compounding causes:
1. A weekend hotfix accidentally changed `DB_HOST` from `pgbouncer.payments` to
   `cloud-sql-proxy.payments`, bypassing PgBouncer entirely
2. The monthly reporting cron job started at 09:00 (coincidental, but holding 7 connections for
   a long-running query, contributing to the exhaustion)

HPA made it worse: seeing errors, HPA scaled from 3 to 12 pods, adding 180 more direct connections.

---

### Fix — The Actual Fix with Commands

**Mitigation (immediate):**

```bash
# Step 1 — Kill the runaway reporting job (frees 7 connections immediately)
kubectl delete job monthly-report-1705396800 -n payments
# This terminates the long-running query and releases its connections

# Step 2 — Scale down payments-api to reduce connection load while we fix routing
kubectl scale deployment payments-api --replicas=3 -n payments

# Step 3 — Restore PgBouncer routing
kubectl set env deployment/payments-api -n payments DB_HOST=pgbouncer.payments

# Step 4 — Roll out the fix
kubectl rollout status deployment/payments-api -n payments

# Step 5 — Verify connection count drops
gcloud sql connect payments-db --user=postgres --project=gke-labs
# SELECT count(*) FROM pg_stat_activity WHERE usename = 'payments_app';
# Expected: ~20 (PgBouncer pool) instead of 300+
```

**Verify the fix:**

```bash
# Check error rate dropped
# Grafana should show: HTTP Error Rate dropping from 100% to <0.5% within 2 minutes

# Check PgBouncer pool stats
kubectl exec -n payments deploy/pgbouncer -c pgbouncer -- \
  psql -h 127.0.0.1 -p 5432 -U pgbouncer pgbouncer -c "SHOW POOLS;"
# cl_active should be < max_client_conn (200)
# cl_waiting should be 0

# Allow HPA to scale back up (now safely through PgBouncer)
kubectl scale deployment payments-api --replicas=3 -n payments
# Let HPA take over from here
```

---

### Prevention — What Architectural Change Prevents Recurrence

```yaml
# 1. Bake DB_HOST into the container image or a ConfigMap — not an env var that can be patched
#    Use an ExternalSecret that only references pgbouncer.payments
#    Make it impossible to accidentally change

# 2. Kyverno policy: validate DB_HOST in payments namespace
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: enforce-pgbouncer-host
  namespace: payments
spec:
  validationFailureAction: Enforce
  rules:
    - name: db-host-must-be-pgbouncer
      match:
        resources:
          kinds: ["Deployment"]
          namespaces: ["payments"]
      validate:
        message: "DB_HOST must be pgbouncer.payments in the payments namespace"
        pattern:
          spec:
            template:
              spec:
                containers:
                  - env:
                      - name: DB_HOST
                        value: "pgbouncer.payments"

# 3. Rate-limit the reporting job connections
# Use a dedicated low-connection-count user for reporting with a separate PgBouncer pool

# 4. Add a circuit breaker on the HPA
# Set a maxReplicas that, even at maximum scale, stays within PgBouncer's pool capacity
# maxReplicas = floor(pgbouncer_max_client_conn / db_connections_per_pod)
# = floor(200 / 10) = 20 pods maximum
```

---

## 4. Scenario C — Grafana Shows No Data After a Deploy

### The Story

Tuesday afternoon, 14:30. A platform engineer deployed a new version of the payments-api Helm
chart. The deploy completed successfully (`kubectl rollout status` showed no issues). But the
payments team immediately reports in Slack: "Grafana shows no data for our namespace — all panels
are flat-lined." No PagerDuty alert fired because there are no errors. But the team is blind.

---

### Alarm — What the Alert Looks Like

This scenario has no PagerDuty alert — it's reported via Slack. This is common for
"missing data" incidents: your alerting is based on metrics that now don't exist.

```
Slack: #payments-engineering
  @platform-team our Grafana dashboard is showing no data since the deploy at 14:28.
  The Payments Overview dashboard — all panels show "No data"
  Error rate panel:    No data
  Latency panel:       No data
  Pod count:           No data (even though pods are Running!)
```

```
Grafana: payments-overview
  HTTP Error Rate:  ─────────────────── No data
  p99 Latency:      ─────────────────── No data
  Pod Count:        ─────────────────── No data
  DB Connections:   ─────────────────── No data
```

**Initial read:** All panels flat-lined simultaneously after a deploy. Not a query issue — it's
a scraping issue. Prometheus isn't collecting metrics from the payments-api pods.

---

### Clues — Commands That Reveal the Root Cause

**Step 1 — Is Prometheus even trying to scrape payments-api?**

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-prometheus 9090:9090 &

# Check Prometheus targets
# http://localhost:9090/targets → search for "payments"
# OR via API:
curl -s 'http://localhost:9090/api/v1/targets' \
  | jq '.data.activeTargets[] | select(.labels.namespace == "payments") | {
      job: .labels.job,
      instance: .labels.instance,
      state: .health,
      lastError: .lastError
    }'

# If there are NO results for namespace=payments:
# → Prometheus has no scrape targets for payments — ServiceMonitor issue

# If there ARE results but state is "down":
# → Prometheus found the targets but can't reach them — network/port issue
```

**Step 2 — Check the ServiceMonitor**

```bash
# List ServiceMonitors in the payments namespace
kubectl get servicemonitor -n payments
# NAME                  AGE
# payments-api          2d

# Describe the ServiceMonitor to see its selector
kubectl describe servicemonitor payments-api -n payments
# Spec:
#   Endpoints:
#     Port: metrics
#     Path: /metrics
#   Namespace Selector:
#     Match Names:  [payments]
#   Selector:
#     Match Labels:
#       app: payments-api-service   ← looking for label "app=payments-api-service"

# Check the actual labels on the payments-api Service
kubectl get service -n payments payments-api -o yaml | grep -A 10 "labels:"
# labels:
#   app: payments-api   ← label is "app=payments-api" NOT "app=payments-api-service"
```

**Step 3 — When did the label change?**

```bash
# Check the Helm chart change
kubectl rollout history deployment/payments-api -n payments
# REVISION 5 — helm upgrade payments-api ./helm/payments-api

# The new Helm chart version changed the Service label from
# "app: payments-api-service" to "app: payments-api"
# The ServiceMonitor still has the old selector

# Confirm the mismatch:
echo "ServiceMonitor selector:"
kubectl get servicemonitor payments-api -n payments \
  -o jsonpath='{.spec.selector.matchLabels}' && echo

echo "Service labels:"
kubectl get service payments-api -n payments \
  -o jsonpath='{.metadata.labels}' && echo

# Output confirms the mismatch
```

**Root Cause Found:**
The Helm chart upgrade changed the Service label from `app: payments-api-service` to
`app: payments-api`. The ServiceMonitor's selector still matched the old label. Prometheus
can't find any Services matching the selector, so it has zero scrape targets for the payments
namespace. All metrics disappeared instantly.

---

### Fix — The Actual Fix with Commands

**Fix A — Update the ServiceMonitor to match the new label (preferred):**

```bash
# Patch the ServiceMonitor selector to match the current Service label
kubectl patch servicemonitor payments-api -n payments \
  --type=json \
  -p='[{"op": "replace", "path": "/spec/selector/matchLabels", "value": {"app": "payments-api"}}]'

# Wait ~30 seconds for Prometheus to re-evaluate its targets
sleep 30

# Verify Prometheus picked up the target
curl -s 'http://localhost:9090/api/v1/targets' \
  | jq '.data.activeTargets[] | select(.labels.namespace == "payments") | .health'
# Expected: "up"

# Verify Grafana shows data again
# In Grafana: refresh the payments-overview dashboard
# Metrics should start populating (there will be a ~30-60s gap from when scraping resumed)
```

**Fix B — Roll back the Helm chart (if the label change was unintentional):**

```bash
helm rollback payments-api 4 -n payments   # Roll back to revision 4
kubectl rollout status deployment/payments-api -n payments
# Verify metrics return
```

**Verify the fix:**

```bash
# Check Prometheus scrape success
curl -s 'http://localhost:9090/api/v1/query?query=up{job="payments-api"}' \
  | jq '.data.result[0].value[1]'
# Expected: "1" (up)

# Check a real metric exists again
curl -s 'http://localhost:9090/api/v1/query?query=rate(http_requests_total{job="payments-api"}[5m])' \
  | jq '.data.result | length'
# Expected: > 0
```

---

### Prevention — What Architectural Change Prevents Recurrence

```bash
# 1. Co-locate the ServiceMonitor in the same Helm chart as the Service
#    The ServiceMonitor selector should reference a Helm template value:
#    selector:
#      matchLabels:
#        {{- include "payments-api.selectorLabels" . | nindent 6 }}
#    This ensures ServiceMonitor and Service always use the same labels.

# 2. Add a CI check that validates Prometheus targets in staging before promoting to production
#    After every deploy to staging, run:
check_prometheus_targets() {
  local namespace=$1
  local job=$2
  local count=$(curl -s "http://prometheus-staging:9090/api/v1/targets" \
    | jq "[.data.activeTargets[] | select(.labels.namespace == \"$namespace\" and .health == \"up\")] | length")
  if [ "$count" -eq "0" ]; then
    echo "ERROR: No healthy Prometheus targets for $job in $namespace"
    exit 1
  fi
  echo "OK: $count targets healthy for $job in $namespace"
}
# Run in CI post-deploy:
# check_prometheus_targets payments payments-api

# 3. Add a "metrics health" Prometheus alert that fires when NO metrics are seen
#    from the payments namespace for 5 minutes:
# - alert: PaymentsAPIMetricsMissing
#   expr: absent(http_requests_total{namespace="payments"})
#   for: 5m
#   labels:
#     severity: warning
#   annotations:
#     summary: "No metrics from payments-api — ServiceMonitor may be broken"
```

---

## 5. Writing a Post-mortem — 5-Why Analysis

### The Purpose of a Post-mortem

Post-mortems are **blameless**. The goal is to improve the system, not to find someone to blame.
A deployment caused an outage — but what in the *system* allowed that to happen?

A post-mortem that concludes "engineer X made a mistake" improves nothing.
A post-mortem that concludes "our review process didn't catch X and our rollout procedure
doesn't verify metric continuity" makes the system more resilient.

### 5-Why Analysis — Scenario B Example

The 5-why technique traces a problem back to its systemic root cause by asking "why?" five times.

```
SYMPTOM: Payments API returned 100% errors for 8 minutes.

WHY 1: Why did the API return 100% errors?
       Because Cloud SQL rejected new connections — max_connections was reached.

WHY 2: Why was max_connections reached?
       Because payments-api pods were connecting directly to Cloud SQL instead of PgBouncer,
       and HPA had scaled to 12 pods × 20 connections = 240 direct connections.

WHY 3: Why were pods connecting directly to Cloud SQL?
       Because DB_HOST was changed from "pgbouncer.payments" to "cloud-sql-proxy.payments"
       during a weekend hotfix.

WHY 4: Why was a change to a critical env var possible without review?
       Because the hotfix was applied with `kubectl set env` directly — bypassing the
       normal PR and approval process.

WHY 5: Why was `kubectl set env` used instead of a PR?
       Because there is no technical control preventing direct kubectl changes in production,
       and the engineer felt the pressure of an unrelated incident and needed a fast fix.

ROOT CAUSE: Production environment lacks guardrails against direct kubectl changes.
            The reliance on a single env var (DB_HOST) for PgBouncer routing is fragile.
```

### Post-mortem Template

```markdown
# Incident Post-mortem: Payments API Connection Exhaustion

**Date:** 2024-01-15
**Duration:** 09:13 – 09:21 UTC (8 minutes)
**Severity:** SEV-1
**Incident Commander:** @alice
**Authors:** @alice, @bob

---

## Impact

- 100% of payment requests failed for 8 minutes (09:13–09:21 UTC)
- Approximately 4,800 failed payment attempts (600 req/min × 8 min)
- Estimated revenue impact: ~£8,400 (£1.75 avg transaction × failed requests)
- No data loss — failed requests returned errors to clients, no partial transactions

---

## Timeline

| Time  | Event |
|-------|-------|
| 08:55 | Monthly report cron job starts at 09:00 (scheduled) |
| 09:00 | Monthly report cron job opens 7 long-running DB connections |
| 09:01 | Unrelated hotfix on Jan 13 changed DB_HOST (identified post-incident) |
| 09:08 | Traffic increases as users start the working day |
| 09:13 | DB connection count hits 400/400, Cloud SQL starts rejecting connections |
| 09:13 | Prometheus fires PaymentsDBConnectionPoolExhausted → PagerDuty alert |
| 09:15 | IC (alice) acknowledges, creates #incident-20240115-db-connections |
| 09:17 | Root cause identified: direct DB connections + monthly report |
| 09:19 | Monthly report job killed, payments-api scaled down to 3 replicas |
| 09:19 | DB_HOST updated to pgbouncer.payments |
| 09:21 | Error rate drops to 0%. Incident resolved. |

---

## Root Cause

Two compounding factors:

1. **Primary:** DB_HOST was changed to bypass PgBouncer during a weekend hotfix on Jan 13,
   replacing the connection-pooled path with direct Cloud SQL connections.

2. **Contributing:** The monthly reporting cron job held 7 long-lived connections for 9+ minutes,
   consuming connection capacity during the morning traffic ramp-up.

---

## 5-Why Analysis

[See above]

---

## Action Items

| Action | Owner | Due Date | Priority |
|--------|-------|----------|----------|
| Add Kyverno policy enforcing DB_HOST=pgbouncer.payments | @platform | 2024-01-22 | HIGH |
| Move DB_HOST to a ConfigMap managed via GitOps (ArgoCD) | @platform | 2024-01-29 | HIGH |
| Add monthly report connection limit (max 2 connections) | @data-eng | 2024-01-22 | MEDIUM |
| Add HPA maxReplicas cap tied to PgBouncer pool capacity | @payments | 2024-01-22 | MEDIUM |
| Create runbook for DB connection exhaustion (improve existing) | @alice | 2024-01-17 | MEDIUM |
| Add pg_stat_activity alerting for connection approaching limit | @platform | 2024-01-29 | LOW |

---

## What Went Well

- Alert fired within 30 seconds of connections reaching max
- Runbook correctly guided IC to the right debugging steps
- Total resolution time was 8 minutes from page to recovery
- Communication in the incident channel was clear and timely

## What Could Have Been Better

- The Jan 13 hotfix was not reviewed and caused the incident 2 days later
- HPA scaling during the incident made it worse before it got better
- Monthly report job had no connection limits and no monitoring

---

*This document will be reviewed in the weekly platform meeting on 2024-01-17.*
```

---

## 6. Interview Q&A

---

### Q1: Tell me about a production incident you handled. How did you approach it?

**Answer framework (use STAR method, adapted for incidents):**

```
SITUATION:  What was the service, what was the impact, what time was it?
TASK:       What was your role? (IC, responder, support)
ACTION:     Walk through your methodology — do NOT just list what you did.
            Explain WHY you did each step.
RESULT:     Time to mitigate, time to resolve, what you learned.
```

**Example answer structure:**

"We had a payment processing service returning 100% errors on a Monday morning — roughly 8
minutes of complete outage affecting several thousand transactions.

My first action was to acknowledge the page and create an incident channel — even before I
opened a terminal. Coordination takes 30 seconds and prevents the chaos of 3 engineers
debugging in parallel and contradicting each other.

Then I followed a structured triage: is this infrastructure (pods are down, nodes are dead)
or application (pods are running but returning errors)? The Grafana dashboard told me pods
were running and memory/CPU were normal — application error, not infrastructure.

The next question was: what changed recently? I checked `kubectl rollout history` and `kubectl
get events`. A deployment had happened 6 minutes before the errors started. I rolled back
immediately — before I even knew the root cause — because getting the service back up was more
important than understanding the failure.

After the rollback restored service, I investigated the root cause without time pressure. I
found that the new deployment had an unbounded in-memory cache that OOMKilled pods under load.

The post-mortem produced two action items: a Kyverno policy enforcing resource limits, and a
canary deployment process with a 10-minute observation window before full rollout."

---

### Q2: How do you decide when to roll back vs when to roll forward with a fix?

**Answer:**

Default to rollback unless there's a strong reason not to. The decision framework:

**Roll back when:**
- The last deployment is the likely cause (within 30 minutes, causally correlated)
- A working previous version exists
- The fix for the new version is not trivial (more than 30 minutes to write and test)
- Data migration was NOT part of the new deploy (rollback would leave new data in old format)

**Roll forward when:**
- A backward-incompatible database migration ran — rolling back the app code would break
  because the old code can't read the new schema
- The previous version had a critical security vulnerability
- The fix is one-line and can be tested immediately

The asymmetry: a rollback takes 2 minutes and is almost always safe. A hotfix takes 15-45 minutes,
may introduce new bugs, and skips normal review processes. In an incident, time is the most
critical resource. Roll back, restore service, then fix properly.

```bash
# Roll back is always this fast:
kubectl rollout undo deployment/payments-api -n payments
# ~2 minutes total including pod replacement
```

---

### Q3: Describe the difference between MTTD, MTTA, MTTI, and MTTR. Which do you optimize first?

**Answer:**

| Metric | Full Name | Definition |
|--------|-----------|-----------|
| **MTTD** | Mean Time to Detect | Time from incident start to alert firing |
| **MTTA** | Mean Time to Acknowledge | Time from alert firing to IC acknowledging |
| **MTTI** | Mean Time to Investigate | Time from acknowledgement to root cause identified |
| **MTTR** | Mean Time to Resolve | Total time from incident start to full resolution |

`MTTR = MTTD + MTTA + MTTI + fix_time`

**Optimization order:**

1. **MTTD first** (detection) — you can't fix what you don't know is broken. Good SLO-based
   alerting (Lab 13) with tight evaluation windows catches incidents in seconds, not minutes.
   A 5-minute MTTD improvement saves 5 minutes of customer impact on every incident.

2. **MTTA second** (acknowledgement) — improve with on-call rotation tooling, clear escalation
   policies, and team agreements. 5-minute acknowledgement SLO.

3. **MTTI third** (investigation) — improve with good runbooks (Lab 13), pre-built dashboards,
   and practice (this lab). Each incident you run through becomes faster the next time.

4. **Fix time last** — this depends on the root cause. Fast rollback (2 minutes) massively
   reduces MTTR; that's the most impactful single change in most organizations.

In practice, most organizations have 60-90 minute MTTRs because their MTTD is 20+ minutes
(poor alerting) and their MTTI is 40+ minutes (no runbooks, no dashboards). Fixing alerting
and runbooks delivers more MTTR improvement than any infrastructure change.

---

### Q4: How do you communicate during an incident? Who gets what information and when?

**Answer:**

Clear communication prevents a coordination disaster on top of a technical one.

**Three audiences with different needs:**

**Engineering responders** (incident channel):
- Technical updates every 5-10 minutes
- Current hypothesis, what's being tried, what was ruled out
- Example: "09:17: root cause found — DB_HOST changed to bypass PgBouncer during weekend hotfix.
  Mitigation: kill monthly report job + restore DB_HOST. ETA: 2 min."

**Stakeholders / management** (separate slack channel or status page):
- Business impact focus: which features are affected, estimated user count
- Current status: investigating / mitigating / resolved
- No technical jargon, no hypotheses (only confirmed facts)
- Example: "09:15 SEV-1 ACTIVE: Payment processing unavailable. Team investigating.
  09:21 SEV-1 RESOLVED: Payment processing restored. Root cause identified. Post-mortem to follow."

**External customers** (status page — statuspage.io / statuspages):
- Simple, accurate, non-technical
- Update every 15-30 minutes during active incident
- Example: "Payments: We are investigating reports of payment failures. Our team is actively
  working to resolve the issue. Next update in 15 minutes."

**Golden rules:**
- Over-communicate during an incident — silence is interpreted as "it's worse than we're saying"
- Never communicate hypotheses to stakeholders — only confirmed facts
- Designate one person to handle comms so the IC can focus on the technical problem
- Post a resolution message that closes the loop — many teams forget this

---

### Q5: A junior engineer deployed a change that caused a 15-minute outage. How do you handle this in the post-mortem?

**Answer:**

The post-mortem is blameless. The question is not "why did the engineer make this mistake" but
"what in the system allowed this mistake to reach production and cause an outage?"

**The wrong post-mortem conclusion:**
"Engineer X deployed without sufficient testing. Action item: engineer X to take additional
training." — This is blame. It fixes nothing. Another engineer will make a similar mistake later.

**The right post-mortem conclusion:**
Ask: "What system properties allowed this to happen?"
- Did the change go through code review? If not, why is that possible?
- Did staging tests catch the problem? If not, what test was missing?
- Did the deployment process include a canary/gradual rollout? If not, why not?
- Could the engineer roll back without senior approval? If not, can they now?

Typical systemic findings:
- "Our staging environment doesn't receive production-level traffic, so load-related bugs don't
  surface there." → Action: add load testing to the deploy pipeline
- "Our rollout was 100% — no canary." → Action: require canary rollouts for payments-api
- "The engineer didn't know about the rollback command." → Action: add rollback procedure to
  the onboarding checklist

The post-mortem should make it **impossible or much harder** for the same class of problem to
recur, regardless of which engineer deploys next time. That's systemic improvement.

---

*You have completed the gke-labs series. Labs 01–17 covered every layer of a production GKE
payments platform: cluster setup, networking, storage, observability, alerting, workflows,
security, database operations, and incident response.*

*The best next step: pick one scenario from Lab 17 and run it live against your cluster.*
