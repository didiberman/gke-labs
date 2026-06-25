# Lab 16 — Cloud SQL Operations

> **Goal:** Operate Cloud SQL PostgreSQL at production standards — understand backup strategies,
> perform a point-in-time recovery to a specific minute, configure high availability so failover
> is automatic, diagnose slow queries with `pg_stat_statements`, and eliminate connection exhaustion
> with PgBouncer. By the end you should be able to respond to any database incident on the
> payments platform.

> **Series position:** Labs 01–15 built and secured the payments platform. This lab covers the
> persistence layer — the component where data loss is permanent and mistakes are the most
> expensive. The Cloud SQL instance referenced throughout this repo is
> `gke-labs:europe-west1:payments-db`.

---

## Table of Contents

1. [Backup Strategy — Automated, On-Demand, and Cross-Region](#1-backup-strategy)
2. [Point-in-Time Recovery — WAL Segments and Restoring to a Minute](#2-point-in-time-recovery)
3. [High Availability — HA vs Read Replicas vs Failover Replicas](#3-high-availability)
4. [Slow Query Analysis — pg_stat_statements and EXPLAIN ANALYZE](#4-slow-query-analysis)
5. [Connection Limits — Why PgBouncer Is Mandatory at Scale](#5-connection-limits)
6. [Maintenance Windows and Zero-Downtime Upgrades](#6-maintenance-windows-and-zero-downtime-upgrades)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. Backup Strategy

### The Two Types of Cloud SQL Backups

**Automated backups** — taken daily by Cloud SQL automatically. Retained for 7 days by default
(configurable up to 365 days). Stored in the same region as the instance.

**On-demand backups** — triggered manually via gcloud or the Console. Retained until you
explicitly delete them (or when the instance is deleted). Use before risky migrations.

```
Backup Architecture for payments-db:
┌─────────────────────────────────────────────────────────────────┐
│  Cloud SQL Instance: payments-db (europe-west1)                  │
│                                                                   │
│  Automated Backup Schedule: 02:00 UTC daily                      │
│  Retention: 30 days                                               │
│                                                                   │
│  WAL (Write-Ahead Log) streaming ──────────────────────────────► │
│  to Cloud Storage: gs://gke-labs-sql-wal/payments-db/            │
│  (enables Point-in-Time Recovery between backups)                 │
│                                                                   │
│  ┌──────────────────────────────────────┐                        │
│  │ Exported Backups (cross-region)       │                        │
│  │ gs://gke-labs-backups-eu-north/      │                        │
│  │ (europe-north1 — different region)   │                        │
│  │ Retention: 90 days                    │                        │
│  └──────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

### Configure Automated Backups

```bash
# Enable automated backups with 30-day retention and PITR
gcloud sql instances patch payments-db \
  --project=gke-labs \
  --backup-start-time=02:00 \
  --retained-backups-count=30 \
  --enable-point-in-time-recovery \
  --transaction-log-retention-days=7  # WAL retained for 7 days (max for PITR window)

# Verify the configuration
gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format="yaml(settings.backupConfiguration)"
```

Expected output:
```yaml
settings:
  backupConfiguration:
    backupRetentionSettings:
      retainedBackups: 30
      retentionUnit: COUNT
    enabled: true
    kind: sql#backupConfiguration
    location: europe-west1
    pointInTimeRecoveryEnabled: true
    startTime: 02:00
    transactionLogRetentionDays: 7
```

### Take an On-Demand Backup Before a Migration

```bash
# Always take a manual backup before running migrations in production
gcloud sql backups create \
  --instance=payments-db \
  --project=gke-labs \
  --description="Pre-migration backup: adding payment_methods table 2024-01-15"

# List all backups (automated + on-demand)
gcloud sql backups list \
  --instance=payments-db \
  --project=gke-labs

# Note the backup ID from the output — you'll need it to restore
```

### Cross-Region Backup Export

Cloud SQL automated backups are stored in the same region. For true disaster recovery, export
to a different region:

```bash
# Export to a GCS bucket in europe-north1 (different region than the instance)
gcloud sql export sql payments-db \
  gs://gke-labs-backups-eu-north/payments-db/$(date +%Y%m%d-%H%M%S).sql.gz \
  --project=gke-labs \
  --database=payments \
  --offload  # Reduces load on the primary by using a serverless export

# This creates a standard SQL dump — can be imported into any PostgreSQL instance
# Use for: disaster recovery, cross-region clones, audit archive
```

---

## 2. Point-in-Time Recovery

### How PITR Works

PostgreSQL writes every database change to **Write-Ahead Log (WAL) segments** before applying
them to the data files. This means every modification is recorded sequentially with a timestamp.
Cloud SQL streams these WAL segments to Cloud Storage continuously.

```
Time ──────────────────────────────────────────────────────────────►

  00:00  02:00           09:47           09:53    10:00
  │      │               │               │        │
  │    DAILY             │             BAD        │
  │   BACKUP           PITR             DEPLOY    │
  │   taken            TARGET           bad       │
  │                                     migration │
  │                                               │
  │◄────── Automated backup baseline ────────────►│
  │                                               │
  │◄────── WAL stream fills the gap ─────────────►│
  │                                               │
  Restore to 09:47 = base backup + replay WAL up to 09:47
```

### Perform a Point-in-Time Recovery

> **Warning:** Cloud SQL PITR creates a **new instance** — it does not overwrite the existing one.
> This is intentional: you can verify the restored instance before switching traffic.

```bash
# Step 1 — Identify the recovery window
# (must be within the last transactionLogRetentionDays = 7 days)
RECOVERY_TIME="2024-01-15T09:47:00.000Z"  # The minute BEFORE the bad migration

# Step 2 — Restore to a new instance
# This creates payments-db-recovered from the 02:00 backup + WAL replay to 09:47
gcloud sql instances clone payments-db payments-db-recovered \
  --project=gke-labs \
  --point-in-time="$RECOVERY_TIME"

# This takes 5-15 minutes depending on instance size
# Watch progress:
watch -n 10 "gcloud sql instances describe payments-db-recovered \
  --project=gke-labs --format='value(state)'"
# PENDING_CREATE → RUNNABLE

# Step 3 — Verify data on the recovered instance
gcloud sql connect payments-db-recovered \
  --user=postgres \
  --project=gke-labs

# Inside psql:
# \dt payments.*
# SELECT COUNT(*) FROM payments.transactions;
# SELECT MAX(created_at) FROM payments.transactions;
# ← verify the last record is at or before 09:47
# \q

# Step 4 — Switch traffic (if verified correct)
# Option A: rename (can't rename Cloud SQL instances — use IP swap)
# Option B: update Cloud SQL Auth Proxy connection string in the app

# Update the Cloud SQL Auth Proxy connection in the payments-api deployment
kubectl set env deployment/payments-api \
  -n payments \
  CLOUD_SQL_INSTANCE=gke-labs:europe-west1:payments-db-recovered

kubectl rollout status deployment/payments-api -n payments

# Step 5 — Clean up old bad instance after verification
# Keep it for at least 24 hours in case further rollback is needed
gcloud sql instances delete payments-db \
  --project=gke-labs \
  --quiet
# Rename payments-db-recovered to payments-db is not possible in Cloud SQL
# Best practice: update all connection strings to point to the recovered instance
```

---

## 3. High Availability

### The Three Availability Options

| Option | How It Works | Failover Time | Use Case |
|--------|-------------|--------------|----------|
| **HA (High Availability)** | Synchronous standby in a different zone | ~30-60 seconds | Production primary |
| **Read Replica** | Asynchronous replication, separate endpoint | Manual promotion (minutes) | Read scale-out, reporting |
| **Failover Replica** | Asynchronous, can be promoted to primary | Minutes (manual) | Cross-region DR |

### Cloud SQL HA Architecture

```
europe-west1-b (primary zone)        europe-west1-c (secondary zone)
────────────────────────────         ──────────────────────────────────
  payments-db PRIMARY                  payments-db STANDBY
  ┌──────────────────────┐            ┌──────────────────────┐
  │  PostgreSQL running  │            │  PostgreSQL standby   │
  │  Accepting writes    │            │  NOT accepting traffic │
  │                      │            │                        │
  │  Regional disk ──────┼────────────┼─► Synced disk        │
  │  (synchronous write) │            │   (same data block)   │
  └──────────────────────┘            └──────────────────────┘
           │                                     │
           │ floating IP (same connection string) │
           ▼                                     ▼
    payments-api connects here ─────────────────►
    (Cloud SQL Auth Proxy handles reconnection)
```

### Enable HA

```bash
# Enable HA on an existing instance (this causes a brief restart)
# Best done during a maintenance window
gcloud sql instances patch payments-db \
  --project=gke-labs \
  --availability-type=REGIONAL  # REGIONAL = HA; ZONAL = no standby

# Verify HA is enabled
gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format="value(settings.availabilityType)"
# Expected: REGIONAL
```

### Test Failover

```bash
# Trigger a manual failover to test your application handles reconnection
# This simulates a zone failure in europe-west1-b

# Step 1 — Watch current primary zone
gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format="value(gceZone)"
# e.g., europe-west1-b

# Step 2 — Start a connectivity test in a separate terminal
# This measures downtime during failover
while true; do
  RESULT=$(gcloud sql connect payments-db --user=postgres --project=gke-labs \
    --quiet -- -c "SELECT NOW();" 2>&1)
  echo "$(date +%T): $RESULT"
  sleep 2
done

# Step 3 — Trigger the failover
gcloud sql instances failover payments-db --project=gke-labs

# Step 4 — Observe in the test terminal:
# ~30 seconds of connection errors (failover in progress)
# Then connections resume to the new primary (now in europe-west1-c)

# Step 5 — Verify new primary zone
gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format="value(gceZone)"
# e.g., europe-west1-c (changed!)
```

### Application Reconnection — Why Cloud SQL Auth Proxy Matters

During a failover, the Cloud SQL IP address doesn't change (it's a floating IP managed by GCP).
But the underlying connection is dropped. Your application needs to handle reconnection:

```go
// Go: pgx connection pool handles reconnection automatically
pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
// pgxpool automatically retries failed connections

// Python: SQLAlchemy pool_pre_ping verifies connections before use
engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,     # Ping before each request — drops dead connections
    pool_recycle=300,       # Recycle connections every 5 minutes
    pool_timeout=30,
)
```

---

## 4. Slow Query Analysis

### Enable pg_stat_statements

`pg_stat_statements` tracks execution statistics for all SQL statements. It is the most
useful tool for database performance analysis.

```bash
# Enable pg_stat_statements in Cloud SQL (requires instance restart)
gcloud sql instances patch payments-db \
  --project=gke-labs \
  --database-flags=cloudsql.enable_pg_stat_statements=on

# Connect to the database
gcloud sql connect payments-db \
  --user=postgres \
  --project=gke-labs

# Inside psql — create the extension in the payments database
\c payments
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

# Verify it's working (after some queries have run)
SELECT * FROM pg_stat_statements LIMIT 5;
```

### Finding Your Slowest Queries

```sql
-- Top 10 slowest queries by total execution time
SELECT
    round(total_exec_time::numeric, 2)         AS total_ms,
    round(mean_exec_time::numeric, 2)          AS avg_ms,
    round(stddev_exec_time::numeric, 2)        AS stddev_ms,
    calls,
    round((total_exec_time / sum(total_exec_time) OVER ()) * 100, 2) AS pct_of_total,
    left(query, 80)                            AS query_preview
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Top queries by average latency (single call bottlenecks)
SELECT
    round(mean_exec_time::numeric, 2) AS avg_ms,
    round(max_exec_time::numeric, 2)  AS max_ms,
    calls,
    left(query, 80)                   AS query_preview
FROM pg_stat_statements
WHERE calls > 100  -- ignore one-off queries
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Queries with high row estimates (potential missing index)
SELECT
    calls,
    round(rows::numeric / calls, 2) AS avg_rows_returned,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    left(query, 80)                 AS query_preview
FROM pg_stat_statements
WHERE calls > 100
ORDER BY (rows / calls) DESC
LIMIT 10;

-- Reset statistics (do this after applying index fixes to get a clean baseline)
SELECT pg_stat_statements_reset();
```

### Enable Slow Query Logging

```bash
# Log queries that take more than 100ms
# (Adjust threshold — 100ms catches most production problems without flooding logs)
gcloud sql instances patch payments-db \
  --project=gke-labs \
  --database-flags=log_min_duration_statement=100

# Also log lock waits
gcloud sql instances patch payments-db \
  --project=gke-labs \
  --database-flags=log_lock_waits=on,deadlock_timeout=500

# View slow query logs via Cloud Logging
gcloud logging read \
  'resource.type="cloudsql_database" AND
   resource.labels.database_id="gke-labs:payments-db" AND
   textPayload=~"duration:"' \
  --project=gke-labs \
  --limit=20 \
  --freshness=1h \
  --format="value(textPayload)"
```

### EXPLAIN ANALYZE — Diagnose a Specific Query

```sql
-- Bad query: sequential scan on a large table
EXPLAIN ANALYZE
SELECT *
FROM transactions
WHERE user_id = 'usr-12345'
ORDER BY created_at DESC
LIMIT 20;

-- Output shows:
-- Seq Scan on transactions  (cost=0.00..48923.00 rows=23 width=128)
--                            (actual time=15.234..2340.567 rows=23 loops=1)
-- Filter: (user_id = 'usr-12345')
-- Rows Removed by Filter: 1283456   ← scanning 1.2M rows to find 23
-- Planning Time: 0.123 ms
-- Execution Time: 2340.789 ms      ← 2.3 seconds! needs an index

-- Fix: add an index on user_id + created_at (covering index for ORDER + LIMIT)
CREATE INDEX CONCURRENTLY idx_transactions_user_created
  ON transactions (user_id, created_at DESC);
-- CONCURRENTLY = no table lock — safe in production

-- After index:
-- Index Scan using idx_transactions_user_created on transactions
--   (actual time=0.045..0.234 rows=23 loops=1)
-- Execution Time: 0.312 ms         ← 7,500x faster
```

### Reading EXPLAIN Output

```
Key terms to watch for:

  Seq Scan     → full table scan, usually bad for large tables (missing index)
  Index Scan   → good, uses index to find rows
  Index Only Scan → best, all needed data is in the index (covering index)
  Nested Loop  → join strategy, can be slow with large datasets
  Hash Join    → join strategy, better for large datasets
  Bitmap Heap Scan → OR conditions, multiple indexes, usually fine

  cost=0.00..48923.00  → estimated cost (higher = more work)
  rows=23              → estimated rows (compare to actual rows — big gaps indicate stale stats)
  actual time=15..2340 → real wall clock time in ms (first number=startup, second=total)
  loops=1              → this node executed N times (nested loops multiply!)

  "Rows Removed by Filter: 1283456" → red flag: sequential scan touching many rows
  "Buffers: shared hit=1024 read=8092" → read = disk I/O (cache miss)
```

---

## 5. Connection Limits

### Why Cloud SQL Has a Connection Limit

Each PostgreSQL connection is a **forked OS process** consuming ~5-10MB of RAM plus CPU.
Cloud SQL limits connections based on instance size:

| Machine Type | Max Connections |
|-------------|-----------------|
| db-f1-micro | 25 |
| db-g1-small | 100 |
| db-n1-standard-1 (1 vCPU) | 200 |
| db-n1-standard-2 (2 vCPU) | 400 |
| db-n1-standard-4 (4 vCPU) | 600 |
| db-n1-highmem-4 (4 vCPU) | 600 |

### The Problem at Scale

```
Without PgBouncer — connection math:
  payments-api pods:        10 replicas
  × DB connections per pod: 20 (typical Go pgx pool)
  = 200 connections to Cloud SQL

  Add ledger-service:       5 replicas × 10 = 50 more
  Add accounts-service:     5 replicas × 10 = 50 more
  Add temporal workers:     3 replicas × 5  = 15 more
  Add reporting jobs:       2 replicas × 10 = 20 more
  ────────────────────────────────────────────────────
  Total: 335 connections → approaching the 400 limit

  During a traffic spike, HPA scales payments-api to 20 replicas:
  20 × 20 = 400 connections — OVER THE LIMIT
  
  Cloud SQL rejects new connections:
  "FATAL: remaining connection slots are reserved for non-replication superuser connections"
  → Payments API can't connect to DB → 500 errors → SLO breach
```

### PgBouncer Architecture

PgBouncer maintains a pool of long-lived database connections and multiplexes many short-lived
application connections onto them:

```
  200 application connections (from all services)
         │
         ▼
  ┌─────────────────────────────────────────────────────┐
  │                   PgBouncer                          │
  │                                                      │
  │  Transaction pooling: connection released back to    │
  │  pool after each transaction completes              │
  │                                                      │
  │  pool_size = 20  (max connections TO Cloud SQL)     │
  │  max_client_conn = 200 (max app connections to PgBouncer) │
  └─────────────────────────────────────────────────────┘
         │
         ▼
  20 real database connections to Cloud SQL
```

### Deploy PgBouncer on GKE

```yaml
# k8s/pgbouncer-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer
  namespace: payments
spec:
  replicas: 2   # 2 replicas for HA
  selector:
    matchLabels:
      app: pgbouncer
  template:
    metadata:
      labels:
        app: pgbouncer
    spec:
      serviceAccountName: payments-api-sa   # For Cloud SQL Auth Proxy
      containers:
        - name: pgbouncer
          image: bitnami/pgbouncer:1.22.0
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRESQL_HOST
              value: "127.0.0.1"   # Cloud SQL Auth Proxy sidecar
            - name: POSTGRESQL_PORT
              value: "5432"
            - name: POSTGRESQL_DATABASE
              value: "payments"
            - name: POSTGRESQL_USERNAME
              value: "payments_app"
            - name: POSTGRESQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: payments-db-credentials
                  key: password
            - name: PGBOUNCER_POOL_MODE
              value: "transaction"   # transaction = most efficient
            - name: PGBOUNCER_MAX_CLIENT_CONN
              value: "200"
            - name: PGBOUNCER_DEFAULT_POOL_SIZE
              value: "20"           # Max connections TO Cloud SQL per user/database
            - name: PGBOUNCER_MIN_POOL_SIZE
              value: "5"
            - name: PGBOUNCER_RESERVE_POOL_SIZE
              value: "5"            # Extra connections during traffic spikes
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
          livenessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 15
        - name: cloud-sql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.8.0
          args:
            - "--structured-logs"
            - "--port=5432"
            - "gke-labs:europe-west1:payments-db"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: pgbouncer
  namespace: payments
spec:
  selector:
    app: pgbouncer
  ports:
    - port: 5432
      targetPort: 5432
```

### Update payments-api to Use PgBouncer

```bash
# Change DB connection string to point to PgBouncer instead of Cloud SQL directly
kubectl set env deployment/payments-api \
  -n payments \
  DB_HOST=pgbouncer.payments \
  DB_PORT=5432

kubectl rollout status deployment/payments-api -n payments

# Monitor PgBouncer stats
# Connect to PgBouncer admin interface (special database: pgbouncer)
kubectl exec -n payments deploy/pgbouncer -c pgbouncer -- \
  psql -h 127.0.0.1 -p 5432 -U pgbouncer pgbouncer \
  -c "SHOW POOLS;"

# Expected output:
# database  | user         | cl_active | cl_waiting | sv_active | sv_idle | sv_used
# payments  | payments_app | 12        | 0          | 12        | 8       | 0
# cl_active  = active client connections (app → PgBouncer)
# cl_waiting = clients waiting for a pool connection (> 0 = pool too small)
# sv_active  = active server connections (PgBouncer → Cloud SQL)
# sv_idle    = idle server connections (holding slots in Cloud SQL)
```

### PgBouncer Pooling Modes

```
Session pooling  → connection assigned to client for entire session duration
                   Least efficient. One-to-one with no benefit over direct connection.

Transaction pooling → connection released back to pool after each COMMIT/ROLLBACK
                      Best efficiency. Enables 200 clients → 20 server connections.
                      LIMITATION: some PostgreSQL features don't work:
                      - SET statement is connection-scoped → use SET LOCAL
                      - Prepared statements → use named prepared statements
                      - LISTEN/NOTIFY → not compatible
                      - Advisory locks → not compatible

Statement pooling → connection released after every single statement
                    Most aggressive. Breaks multi-statement transactions.
                    Not suitable for transactional applications.
```

---

## 6. Maintenance Windows and Zero-Downtime Upgrades

### Configure Maintenance Windows

Cloud SQL maintenance (PostgreSQL version upgrades, OS patches) happens in a maintenance window
you configure. Outside the window, Cloud SQL won't apply maintenance automatically.

```bash
# Set maintenance window: Sunday 03:00-07:00 UTC
gcloud sql instances patch payments-db \
  --project=gke-labs \
  --maintenance-window-day=SUN \
  --maintenance-window-hour=3

# Verify
gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format="yaml(settings.maintenanceWindow)"
```

### Check for Upcoming Maintenance

```bash
# Check when next maintenance is scheduled
gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format="yaml(scheduledMaintenance)"

# Deny upcoming maintenance (reschedule to next window)
gcloud sql instances reschedule-maintenance payments-db \
  --project=gke-labs \
  --reschedule-type=NEXT_AVAILABLE_WINDOW
```

### Zero-Downtime Major Version Upgrade Strategy

Major PostgreSQL version upgrades (e.g., 14 → 15) require more careful planning:

```
Zero-downtime upgrade with logical replication:

  [payments-db]               [payments-db-v15]
  PostgreSQL 14               PostgreSQL 15 (new instance)
       │                              │
       │  logical replication         │
       │  (pg_logical_replication     │
       │   or pglogical)              │
       └─────────────────────────────►│
                                      │ ← catches up to primary
                                      │
  Traffic still goes to payments-db   │
                                      │
  When replica is caught up (lag < 100ms):
  1. Lock application writes momentarily (or use a feature flag)
  2. Verify replica is at same LSN as primary
  3. Switch application connection string to payments-db-v15
  4. Unlock writes
  Total downtime: < 30 seconds

  Compared to Cloud SQL in-place upgrade:
  - Cloud SQL handles minor versions (14.6 → 14.9): automatic, HA failover, ~1 min
  - Major version: Cloud SQL supports in-place upgrade with a restart (~5-10 min downtime)
```

### In-Place Major Version Upgrade (simpler, with brief downtime)

```bash
# Step 1 — Take a backup before upgrading
gcloud sql backups create \
  --instance=payments-db \
  --project=gke-labs \
  --description="Pre-upgrade backup: PostgreSQL 14 → 15"

# Step 2 — Check upgrade compatibility
gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format="value(databaseVersion)"
# e.g., POSTGRES_14

# Step 3 — Perform the upgrade (causes a restart — ~5-10 min downtime)
gcloud sql instances patch payments-db \
  --project=gke-labs \
  --database-version=POSTGRES_15

# Step 4 — Monitor the upgrade
watch -n 5 "gcloud sql instances describe payments-db \
  --project=gke-labs --format='value(state,databaseVersion)'"
# MAINTENANCE → RUNNABLE POSTGRES_15

# Step 5 — Run post-upgrade verification
gcloud sql connect payments-db --user=postgres --project=gke-labs
# Inside psql:
# SELECT version();  -- verify PostgreSQL 15.x
# \dt payments.*     -- verify tables are intact
# SELECT COUNT(*) FROM payments.transactions;  -- verify data
# \q
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1 — Exhaust the Connection Pool

**Goal:** Reproduce the "connection pool exhausted" incident and fix it with PgBouncer.

```bash
# === SETUP — Deploy payments-api WITHOUT PgBouncer, with large pools ===
kubectl set env deployment/payments-api -n payments \
  DB_HOST=cloud-sql-proxy.payments \
  DB_MAX_CONNS=50   # 50 connections per pod

# Scale up to trigger exhaustion
kubectl scale deployment/payments-api --replicas=15 -n payments

# Watch Cloud SQL connections
watch -n 5 "gcloud sql instances describe payments-db \
  --project=gke-labs \
  --format='value(currentDiskSize, settings.tier)'"

# Query connections in PostgreSQL
gcloud sql connect payments-db --user=postgres --project=gke-labs
# Inside psql:
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
SELECT count(*) FROM pg_stat_activity;  -- should be approaching max_connections

# === BREAK IT — exceed max_connections ===
kubectl scale deployment/payments-api --replicas=20 -n payments
# Wait ~60 seconds, then check app logs
kubectl logs -n payments -l app=payments-api --tail=20 | grep -i "connection refused\|too many"
# Expected: "FATAL: remaining connection slots are reserved for non-replication superuser"

# === FIX IT — deploy PgBouncer ===
kubectl apply -f k8s/pgbouncer-deployment.yaml
kubectl rollout status deployment/pgbouncer -n payments

# Switch payments-api to use PgBouncer
kubectl set env deployment/payments-api -n payments \
  DB_HOST=pgbouncer.payments \
  DB_MAX_CONNS=10   # Reduce per-pod pool — PgBouncer handles multiplexing

kubectl rollout status deployment/payments-api -n payments

# Verify connection count is now bounded
gcloud sql connect payments-db --user=postgres --project=gke-labs
# Inside psql:
SELECT count(*) FROM pg_stat_activity WHERE usename = 'payments_app';
# Expected: ~20 (PgBouncer pool_size), not 200+ (direct connections)
```

---

### Exercise 2 — Find and Fix a Slow Query

```bash
# === SETUP — generate slow queries ===
# Reset pg_stat_statements for a clean baseline
gcloud sql connect payments-db --user=postgres --project=gke-labs
# Inside psql:
\c payments
SELECT pg_stat_statements_reset();

-- Run a deliberately slow query 100 times (missing index simulation)
DO $$
BEGIN
  FOR i IN 1..100 LOOP
    PERFORM * FROM transactions WHERE merchant_id = 'merch-' || floor(random() * 1000)::text
    ORDER BY created_at DESC LIMIT 10;
  END LOOP;
END $$;

-- Find the slowest query
SELECT
    round(mean_exec_time::numeric, 2) AS avg_ms,
    calls,
    left(query, 100) AS query_preview
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 5;
# Expected: the merchant_id query shows high avg_ms (Seq Scan)

-- EXPLAIN the query to confirm Seq Scan
EXPLAIN ANALYZE
SELECT * FROM transactions
WHERE merchant_id = 'merch-100'
ORDER BY created_at DESC LIMIT 10;
# Expected: Seq Scan on transactions (slow!)

-- === FIX IT ===
CREATE INDEX CONCURRENTLY idx_transactions_merchant_created
  ON transactions (merchant_id, created_at DESC);

-- Re-run EXPLAIN to verify Index Scan
EXPLAIN ANALYZE
SELECT * FROM transactions
WHERE merchant_id = 'merch-100'
ORDER BY created_at DESC LIMIT 10;
# Expected: Index Scan using idx_transactions_merchant_created (fast!)

-- Verify the index
\d transactions
\q
```

---

### Exercise 3 — Perform a PITR Drill

**Goal:** Practice the recovery procedure so it's not the first time you do it during an incident.

```bash
# Record the current time — this is our "good" state target
RECOVERY_TARGET=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Recovery target: $RECOVERY_TARGET"

# === BREAK IT — simulate a bad migration ===
gcloud sql connect payments-db --user=postgres --project=gke-labs
# Inside psql:
\c payments
-- Oops: dropped the wrong table
DROP TABLE IF EXISTS payment_methods;
-- Or: corrupt data
UPDATE transactions SET status = 'failed' WHERE created_at > NOW() - INTERVAL '1 hour';
\q

# Wait 2 minutes to ensure WAL has propagated

# === FIX IT — PITR to just before the mistake ===
gcloud sql instances clone payments-db payments-db-pitr-drill \
  --project=gke-labs \
  --point-in-time="$RECOVERY_TARGET"

# Wait for recovery (~10 minutes)
watch -n 15 "gcloud sql instances describe payments-db-pitr-drill \
  --project=gke-labs --format='value(state)'"

# Verify the restored instance has the correct data
gcloud sql connect payments-db-pitr-drill --user=postgres --project=gke-labs
# Inside psql:
\c payments
\dt  -- payment_methods should exist again
SELECT COUNT(*) FROM transactions WHERE status = 'failed';  -- should be lower
\q

# Clean up the drill instance
gcloud sql instances delete payments-db-pitr-drill \
  --project=gke-labs \
  --quiet
```

---

## 8. Interview Q&A

---

### Q1: What is the difference between Cloud SQL automated backups and PITR? Which do you use for what scenario?

**Answer:**

**Automated backups** are daily full snapshots of the Cloud SQL instance data files. They are
point-in-time snapshots, but only at the backup time (e.g., 02:00 UTC). To restore from an
automated backup, you can clone an instance from any of the retained backups. The limitation is
granularity: you can only restore to the exact backup time, not to "09:47 this morning."

**PITR (Point-in-Time Recovery)** uses continuous WAL streaming. Every database write is
recorded in WAL segments that Cloud SQL ships to Cloud Storage. PITR lets you restore to
*any second* within the WAL retention window (up to 7 days). The implementation uses:
`base backup (from daily snapshot) + WAL replay up to the target timestamp`.

| Scenario | Use | Why |
|----------|-----|-----|
| Bad migration ran at 09:47, discovered at 10:05 | PITR | Restore to 09:46:59 — minute-level precision |
| Instance accidentally deleted | Automated backup | Full instance restore from last backup |
| Compliance audit copy of data from 3 weeks ago | Automated backup export | Within retention window |
| Test a schema change without touching production | Clone from automated backup | Faster than PITR for "some point in time" |

Always enable both: automated backups provide the base for PITR, and PITR gives you the
precision to undo surgical mistakes.

---

### Q2: Why can't you just increase max_connections instead of deploying PgBouncer?

**Answer:**

Increasing `max_connections` in PostgreSQL reserves more RAM for connection metadata.
Each PostgreSQL connection is an OS process consuming approximately 5-10MB of RAM for the
shared memory segment, backend process, and WAL logging structures.

If you increase `max_connections` from 400 to 1000 on a `db-n1-standard-4` (4 vCPU, 15GB RAM):
- Connection overhead: 1000 × ~8MB = ~8GB reserved for connection slots
- Available for shared_buffers (cache): 15GB - 8GB - OS overhead = ~5GB
- You've traded half your DB cache for connections you mostly don't use simultaneously

More concretely: PostgreSQL performs best when most of its RAM is in `shared_buffers` (cache).
Bloating connection slots steals from the cache, causing more disk I/O, which slows all queries.

PgBouncer solves the real problem: you don't need 400 *simultaneous* DB queries — you need 400
application threads to be *able* to make DB queries. With transaction pooling, 20 real connections
serve 200 application threads because each application thread holds a DB connection for only
the duration of a transaction (~1-50ms), not for the entire HTTP request lifetime.

---

### Q3: Walk me through how you would diagnose a Cloud SQL instance where query latency doubled overnight.

**Answer:**

Systematic investigation from the outside in:

```bash
# 1. Is it Cloud SQL infrastructure, or application queries?
# Check Cloud SQL system metrics in Cloud Monitoring:
gcloud monitoring time-series list \
  --filter='metric.type="cloudsql.googleapis.com/database/cpu/utilization"' \
  --interval-start-time=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --project=gke-labs
# High CPU → queries are more expensive (not infrastructure)
# Normal CPU → check locks, connections, or infrastructure

# 2. Connection count — is pool exhaustion causing queueing?
# pg_stat_activity check (from earlier)

# 3. Lock waits — are transactions blocking each other?
SELECT
    blocking.pid         AS blocking_pid,
    blocking.query       AS blocking_query,
    blocked.pid          AS blocked_pid,
    blocked.query        AS blocked_query,
    now() - blocked.query_start AS wait_duration
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.cardinality(pg_blocking_pids(blocked.pid)) > 0;
-- Long-lived locks here → a stuck transaction is blocking others

# 4. pg_stat_statements — what changed?
SELECT round(mean_exec_time::numeric, 2) AS avg_ms, calls, query
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
-- Compare with yesterday's Grafana dashboard (if you're scraping pg_stat_statements)

# 5. Table bloat — VACUUM may be needed
SELECT relname, n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup, 0) * 100, 2) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 10;
-- High dead_pct → table needs VACUUM ANALYZE

# 6. Missing statistics — did a new deploy insert many rows?
ANALYZE transactions;  -- Update planner statistics
-- Then re-check the slow query with EXPLAIN ANALYZE
```

Most common causes of overnight latency increase: a new deploy changed a query pattern, a
background job loaded data causing table/index bloat, autovacuum hasn't caught up, or a
new index is missing for a new query pattern.

---

### Q4: What is the difference between a Cloud SQL read replica and a High Availability standby?

**Answer:**

Both are copies of the primary, but they serve different purposes:

**HA standby:**
- Synchronously replicated — every write is confirmed on BOTH primary and standby before
  acknowledging to the application (PostgreSQL's synchronous streaming replication)
- NOT accessible for reads — it exists purely as a failover target
- Automatic failover: if the primary zone fails, Cloud SQL promotes the standby in ~30-60 seconds
- Same connection string — the application reconnects to the same IP

**Read replica:**
- Asynchronously replicated — there is replication lag (typically milliseconds, can be seconds
  under heavy write load)
- Accessible for reads — has its own connection string; use for reporting, analytics, background jobs
- Failover is MANUAL — you must promote the replica and update connection strings
- Promotion takes minutes; you decide when and how to switch

In production, use both: HA standby for automatic failover (zero RTO for zone failures), plus
a read replica to offload analytics queries from the primary.

---

*Next: [Lab 17 — Incident Simulation](../17-incident-simulation/README.md)*
