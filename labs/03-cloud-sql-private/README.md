# Lab 03 — Cloud SQL with Private IP, Auth Proxy, and PITR

> **Goal:** Understand every layer between your GKE pod and a Cloud SQL PostgreSQL instance —
> private networking, the Cloud SQL Auth Proxy sidecar, IAM-based authentication, schema
> migrations, backup configuration, and point-in-time recovery. By the end you should be able
> to explain why public IPs on managed databases are a compliance red flag and how the Auth
> Proxy achieves mTLS without client certificate management.

---

## Table of Contents

1. [Why Private IP? Network Isolation in Financial Services](#1-why-private-ip-network-isolation-in-financial-services)
2. [Cloud SQL Auth Proxy — How It Works](#2-cloud-sql-auth-proxy--how-it-works)
3. [Terraform Walkthrough — The cloud-sql Module](#3-terraform-walkthrough--the-cloud-sql-module)
4. [Connecting from GKE — Sidecar Pattern in Practice](#4-connecting-from-gke--sidecar-pattern-in-practice)
5. [Schema Migrations — golang-migrate and Flyway Patterns](#5-schema-migrations--golang-migrate-and-flyway-patterns)
6. [Backup and Point-In-Time Recovery (PITR)](#6-backup-and-point-in-time-recovery-pitr)
7. [Slow Query Analysis — pg_stat_statements and EXPLAIN ANALYZE](#7-slow-query-analysis--pg_stat_statements-and-explain-analyze)
8. [Break-It & Fix-It Exercises](#8-break-it--fix-it-exercises)
9. [Interview Q&A](#9-interview-qa)

---

## 1. Why Private IP? Network Isolation in Financial Services

### The Problem with Public Endpoints

Every Cloud SQL instance by default can be configured with a public IP — a globally routable
address accessible from anywhere on the internet. For a financial-services platform this is
a serious risk:

- **Attack surface:** A misconfigured firewall rule or weak password exposes payment data
  to brute-force attacks from any IP on earth.
- **Compliance violations:** PCI-DSS Requirement 1.3 mandates that cardholder data
  environments must not have direct internet connectivity. A public database endpoint
  fails this requirement.
- **Lateral movement:** If an attacker compromises a workload, a public IP gives them
  an additional pivot point from outside the cluster.

### Private IP — VPC Peering Under the Hood

Cloud SQL with private IP works through **Private Service Access (PSA)**, a form of VPC
peering between your project's VPC and Google's service producer network.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Your VPC  (project: gke-labs, region: europe-west1)                │
│                                                                     │
│  GKE Cluster Nodes          Service Networking Peering              │
│  10.0.0.0/20                ◄─────────────────────────┐            │
│     │                                                  │            │
│     │ Pod CIDR                                         │            │
│     │ 10.4.0.0/14                                      │            │
│     ▼                                     ┌────────────┴──────────┐ │
│  Pod: payments-api ──────────────────────►│  Cloud SQL Private IP │ │
│  IP: 10.4.2.15                            │  10.105.0.3:5432      │ │
│                                           │  (Google-managed VPC) │ │
│                                           └───────────────────────┘ │
│                                                                     │
│  ✗ No public IP. Reachable only from within your VPC.              │
└─────────────────────────────────────────────────────────────────────┘
```

### What PSA Actually Does

1. You allocate a private IP range in your VPC:
   `google_compute_global_address` with `purpose = "VPC_PEERING"`.
2. You create a service networking connection:
   `google_service_networking_connection` which peers your VPC with Google's
   `servicenetworking.googleapis.com` network.
3. Cloud SQL instances in that peered range get an RFC 1918 IP in your VPC's address space.
4. Your GKE pods can reach that IP directly — no NAT, no internet gateway.

### Verify the Setup

```bash
# List Cloud SQL instances and their IP addresses
gcloud sql instances list \
  --project=gke-labs \
  --format="table(name,databaseVersion,ipAddresses[0].ipAddress,ipAddresses[0].type)"

# You should see:
# NAME                    DATABASE_VERSION  IP_ADDRESS    TYPE
# gke-lab-postgres-dev    POSTGRES_15       10.105.0.3    PRIVATE
# (no PUBLIC type entry)

# Confirm the VPC peering exists
gcloud compute networks peerings list \
  --network=gke-labs-vpc \
  --project=gke-labs

# Confirm the allocated IP range
gcloud compute addresses list \
  --project=gke-labs \
  --filter="purpose=VPC_PEERING" \
  --format="table(name,address,prefixLength,status)"
```

### Why Not Just Use the Private IP Directly?

You could point your application at `10.105.0.3:5432` with a username/password — and it
would work. But there are critical problems:

| Problem | Direct Private IP | Auth Proxy |
|---------|------------------|------------|
| Authentication | Username/password only | IAM identity (no passwords in code) |
| TLS | You manage client certificates | Proxy handles mTLS automatically |
| Secret rotation | Requires app restart | Proxy gets new IAM token per connection |
| Audit | PostgreSQL logs only | Cloud SQL audit logs + IAM activity |
| Dynamic IPs | IP can change if instance is recreated | Auth Proxy uses instance name, not IP |

This is why the Auth Proxy exists.

---

## 2. Cloud SQL Auth Proxy — How It Works

### The Core Idea

The Auth Proxy is a local TCP listener that:
1. Accepts connections from your application on `127.0.0.1:5432`
2. Authenticates to Google APIs using the pod's IAM identity
3. Wraps the connection in a mutually-authenticated TLS tunnel to the Cloud SQL API
4. Forwards your PostgreSQL protocol bytes through that tunnel

Your application connects to `localhost:5432` as if it were talking to a local database.
No SSL certificates in your app. No long-lived passwords. No key files (when Workload
Identity is configured).

```
┌─────────────────────────────────────────────────────────────────────┐
│  Kubernetes Pod                                                      │
│                                                                     │
│  ┌──────────────────┐        ┌──────────────────────────────────┐  │
│  │  payments-api    │        │  cloud-sql-proxy sidecar          │  │
│  │  container       │        │  (gcr.io/cloud-sql-connectors/   │  │
│  │                  │        │   cloud-sql-proxy:2.11.0)        │  │
│  │  psql connect    │        │                                  │  │
│  │  host=127.0.0.1  │─TCP──► │  :5432 (listen)                 │  │
│  │  port=5432       │        │       │                          │  │
│  │  (no TLS config) │        │       │ IAM token (Workload      │  │
│  │                  │        │       │ Identity)                │  │
│  └──────────────────┘        │       ▼                          │  │
│                               │  Cloud SQL API                  │  │
│                               │  sqladmin.googleapis.com        │  │
│                               │  (mTLS, ephemeral certs)        │  │
│                               │       │                          │  │
│                               │       ▼                          │  │
│                               │  Cloud SQL Private IP           │  │
│                               │  gke-labs:europe-west1:         │  │
│                               │  gke-lab-postgres-dev           │  │
└─────────────────────────────────────────────────────────────────────┘
```

### Authentication Flow (Workload Identity Path)

```
1. Pod starts with Kubernetes Service Account (KSA)
   └─ KSA is annotated with GCP Service Account (GSA) email

2. Auth Proxy calls the GKE Metadata Server (169.254.169.254)
   └─ Metadata Server returns an OIDC token for the GSA

3. Auth Proxy presents the OIDC token to sqladmin.googleapis.com
   └─ Google verifies the token and checks IAM

4. Google issues a short-lived (1h) mTLS certificate
   └─ Auth Proxy uses this certificate to open an encrypted
      tunnel to the Cloud SQL instance

5. Your app's TCP bytes flow through the tunnel
   └─ From the database's perspective: a normal TLS connection
```

The GSA needs `roles/cloudsql.client` on the project (or the specific instance).

### IAM Permission Required

```bash
# Grant the payments-api GSA permission to connect to Cloud SQL
gcloud projects add-iam-policy-binding gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

# Verify
gcloud projects get-iam-policy gke-labs \
  --flatten="bindings[].members" \
  --filter="bindings.role=roles/cloudsql.client" \
  --format="table(bindings.members)"
```

### Proxy Version and Flags

The proxy image is pinned in `helm/temporal/values.yaml`:
```
gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.11.0
```

Key flags used:
- `--structured-logs`: JSON log output (parseable by Cloud Logging)
- `--port=5432`: Listen on port 5432 (default for PostgreSQL)
- `--private-ip`: Force the proxy to use the private IP path (skip public IP fallback)
- `--auto-iam-authn`: Use IAM database authentication instead of a password
  (requires the database user to be a Cloud IAM user type)

---

## 3. Terraform Walkthrough — The cloud-sql Module

The module lives at `terraform/modules/cloud-sql/`. Let's walk through what it creates and why
each decision exists.

### What the Module Creates

```
terraform/modules/cloud-sql/
├── main.tf       ← Cloud SQL instance, databases, users
├── variables.tf  ← Input variables with validation
└── outputs.tf    ← connection_name, private_ip_address, etc.
```

### Key Variables

```hcl
# From terraform/modules/cloud-sql/variables.tf

variable "availability_type" {
  description = "ZONAL for dev, REGIONAL for staging/prod"
  default     = "ZONAL"
}
# REGIONAL means Cloud SQL maintains a hot standby in a second zone.
# Automatic failover happens within ~60 seconds. Cost doubles.
# For financial services production: always REGIONAL.

variable "tier" {
  description = "Cloud SQL machine tier"
  default     = "db-g1-small"
}
# db-g1-small: 0.6 vCPU, 1.7 GB RAM — OK for lab/dev
# db-n1-standard-2: 2 vCPU, 7.5 GB RAM — minimum for payments production
# db-n1-standard-4: 4 vCPU, 15 GB RAM — typical for 100 TPS payments load

variable "deletion_protection" {
  description = "Set false for lab so terraform destroy works"
  default     = false
}
# MUST be true for production. Prevents accidental terraform destroy
# from dropping a live database. Requires setting to false before any
# intentional deletion.
```

### Backup Configuration (in main.tf)

```hcl
backup_configuration {
  enabled                        = true
  start_time                     = "03:00"  # 3AM UTC — low traffic window
  point_in_time_recovery_enabled = true     # enables WAL archiving for PITR
  transaction_log_retention_days = 7        # keep WAL logs for 7 days
  backup_retention_settings {
    retained_backups = 30                   # keep 30 daily backups
    retention_unit   = "COUNT"
  }
}
```

### Database Flags for PostgreSQL

```hcl
database_flags {
  name  = "cloudsql.iam_authentication"
  value = "on"
}
# Required for Cloud IAM database authentication.
# Allows GSA-mapped database users to authenticate using IAM tokens
# instead of passwords — eliminates long-lived DB credentials entirely.

database_flags {
  name  = "log_checkpoints"
  value = "on"
}

database_flags {
  name  = "log_connections"
  value = "on"
}

database_flags {
  name  = "log_disconnections"
  value = "on"
}
# PCI-DSS 10.2 requires logging of all individual user access to cardholder data.
# These flags ensure the database logs who connected and disconnected.
```

### Reading Module Outputs

```bash
# After terraform apply, inspect outputs:
cd terraform/
terraform output -json | jq '.cloud_sql'

# Expected output structure:
# {
#   "connection_name": "gke-labs:europe-west1:gke-lab-postgres-dev",
#   "private_ip_address": "10.105.0.3",
#   "instance_name": "gke-lab-postgres-dev"
# }

# Use the connection_name to configure the Auth Proxy:
CONNECTION_NAME=$(terraform output -raw cloud_sql_connection_name 2>/dev/null || \
  gcloud sql instances describe gke-lab-postgres-dev \
    --project=gke-labs \
    --format="value(connectionName)")
echo "Connection name: $CONNECTION_NAME"
```

---

## 4. Connecting from GKE — Sidecar Pattern in Practice

### Why Sidecar (not DaemonSet)?

You could run one Auth Proxy per node (DaemonSet) and have all pods on that node share it.
This is cheaper on resources but creates a blast radius problem: if the proxy crashes on one
node, all database connections from all pods on that node fail simultaneously.

The sidecar pattern — one proxy per pod — means:
- Failure is isolated to one pod
- Each pod has its own IAM identity and connection pool
- Pod lifecycle is tied: proxy starts before app, stops after app

### Complete Sidecar Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      serviceAccountName: payments-api   # KSA linked to GSA via Workload Identity

      # Init container ensures Cloud SQL proxy is ready before the app starts.
      # Without this, the app may fail to connect on startup.
      initContainers:
        - name: wait-for-proxy
          image: busybox:1.35
          command:
            - sh
            - -c
            - |
              until nc -z 127.0.0.1 5432; do
                echo "Waiting for Cloud SQL proxy..."
                sleep 1
              done
              echo "Proxy is ready"

      containers:
        # ── Main application container ──────────────────────────────────────
        - name: payments-api
          image: europe-west1-docker.pkg.dev/gke-labs/payments/payments-api:latest
          env:
            - name: DB_HOST
              value: "127.0.0.1"
            - name: DB_PORT
              value: "5432"
            - name: DB_NAME
              value: "payments"
            - name: DB_USER
              value: "payments-api"
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: payments-db-credentials
                  key: password
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi

        # ── Cloud SQL Auth Proxy sidecar ────────────────────────────────────
        - name: cloud-sql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.11.0
          args:
            - "--structured-logs"
            - "--port=5432"
            - "--private-ip"          # force private IP path; reject public IP fallback
            - "$(CLOUD_SQL_INSTANCE)"
          env:
            - name: CLOUD_SQL_INSTANCE
              valueFrom:
                configMapKeyRef:
                  name: payments-cloudsql-config
                  key: instance_connection_name
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
          # Liveness probe: verify proxy can still reach Cloud SQL API
          livenessProbe:
            httpGet:
              path: /liveness
              port: 9090      # proxy admin port (--http-address flag)
            initialDelaySeconds: 10
            periodSeconds: 30
            failureThreshold: 3
```

### Verify the Proxy is Running

```bash
# Check all containers in payments-api pods
kubectl get pods -n payments -o wide
kubectl describe pod -n payments -l app=payments-api

# Check proxy container logs specifically
kubectl logs -n payments \
  -l app=payments-api \
  -c cloud-sql-proxy \
  --tail=50

# Expected output (structured JSON):
# {"level":"info","msg":"Authorizing with Application Default Credentials","version":"2.11.0"}
# {"level":"info","msg":"Listening on 127.0.0.1:5432","conn":"gke-labs:europe-west1:gke-lab-postgres-dev"}

# Test connectivity from inside the main container
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -c payments-api \
  -- pg_isready -h 127.0.0.1 -p 5432 -U payments-api -d payments
# Expected: 127.0.0.1:5432 - accepting connections
```

### ConfigMap for the Instance Connection Name

```bash
# Create the ConfigMap that the proxy reads from
kubectl create configmap payments-cloudsql-config \
  --from-literal=instance_connection_name=gke-labs:europe-west1:gke-lab-postgres-dev \
  -n payments

# Verify
kubectl get configmap payments-cloudsql-config -n payments -o yaml
```

---

## 5. Schema Migrations — golang-migrate and Flyway Patterns

### Why Not Run Migrations in the App?

Many frameworks (Django, Rails, Hibernate) support running migrations automatically on
startup. For financial-services production this is dangerous:

- **Race condition:** Multiple pods start simultaneously and each tries to run migrations
- **No review gate:** Migrations bypass code review once they reach the cluster
- **Failed rollback:** If a migration fails mid-way, the app may start in a broken state
- **Blast radius:** A bad migration affects the database before the app can be rolled back

The correct pattern is: **migrations run as a Kubernetes Job, before the Deployment rolls out**.

### golang-migrate Pattern

```bash
# The golang-migrate CLI tool (used in this lab's CI pipeline)
# Install: https://github.com/golang-migrate/migrate

# Migration file naming convention (important!):
# migrations/
#   000001_create_payments_table.up.sql
#   000001_create_payments_table.down.sql
#   000002_add_idempotency_key.up.sql
#   000002_add_idempotency_key.down.sql

# Run migrations via the Auth Proxy (proxy must be running)
# In a local dev setup, use Cloud SQL proxy directly:
cloud-sql-proxy \
  --port=5432 \
  gke-labs:europe-west1:gke-lab-postgres-dev &

migrate \
  -source file://migrations \
  -database "postgres://payments-api:${DB_PASSWORD}@127.0.0.1:5432/payments?sslmode=disable" \
  up

# Check current migration version
migrate \
  -source file://migrations \
  -database "postgres://payments-api:${DB_PASSWORD}@127.0.0.1:5432/payments?sslmode=disable" \
  version

# Roll back the last migration (test this before production!)
migrate \
  -source file://migrations \
  -database "postgres://payments-api:${DB_PASSWORD}@127.0.0.1:5432/payments?sslmode=disable" \
  down 1
```

### Kubernetes Migration Job

```yaml
# k8s/jobs/migrate.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: payments-db-migrate-{{ .Release.Revision }}   # unique per Helm upgrade
  namespace: payments
  annotations:
    helm.sh/hook: pre-upgrade,pre-install
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3          # retry up to 3 times on failure
  activeDeadlineSeconds: 300  # fail the job if it takes > 5 minutes
  template:
    spec:
      restartPolicy: OnFailure
      serviceAccountName: payments-api   # needs Cloud SQL client IAM role

      initContainers:
        - name: wait-for-proxy
          image: busybox:1.35
          command: ["sh", "-c", "until nc -z 127.0.0.1 5432; do sleep 1; done"]

      containers:
        - name: migrate
          image: europe-west1-docker.pkg.dev/gke-labs/payments/payments-migrate:latest
          command: ["migrate"]
          args:
            - "-source"
            - "file:///migrations"
            - "-database"
            - "postgres://payments-api:$(DB_PASSWORD)@127.0.0.1:5432/payments?sslmode=disable"
            - "up"
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: payments-db-credentials
                  key: password

        - name: cloud-sql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.11.0
          args:
            - "--structured-logs"
            - "--port=5432"
            - "--private-ip"
            - "gke-labs:europe-west1:gke-lab-postgres-dev"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
```

### Writing Safe Migrations for Financial Data

```sql
-- 000003_add_payment_status_index.up.sql
-- GOOD: CREATE INDEX CONCURRENTLY avoids locking the table
-- IMPORTANT: cannot run in a transaction block — use -x false flag with golang-migrate
CREATE INDEX CONCURRENTLY IF NOT EXISTS
  idx_payments_status_created
  ON payments(status, created_at)
  WHERE status IN ('PENDING', 'PROCESSING');

-- GOOD: Adding a nullable column is always safe (no table rewrite)
ALTER TABLE payments
  ADD COLUMN IF NOT EXISTS idempotency_key VARCHAR(255);

-- GOOD: Adding a constraint with NOT VALID defers validation to a later VALIDATE step
-- This avoids a full table scan during the migration
ALTER TABLE payments
  ADD CONSTRAINT fk_payments_accounts
  FOREIGN KEY (account_id) REFERENCES accounts(id)
  NOT VALID;

-- In a separate migration — validate (acquires only ShareUpdateExclusiveLock)
ALTER TABLE payments VALIDATE CONSTRAINT fk_payments_accounts;

-- BAD (never do this on a live table with data):
-- ALTER TABLE payments ADD COLUMN amount NUMERIC NOT NULL;  -- blocks all writes
-- ALTER TABLE payments ALTER COLUMN status TYPE payment_status_enum;  -- table rewrite
```

### Monitor Migration Job

```bash
# Watch the migration job
kubectl get jobs -n payments -w

# Check logs
kubectl logs -n payments -l job-name=payments-db-migrate-1 -c migrate

# If migration is stuck, describe the job
kubectl describe job payments-db-migrate-1 -n payments

# Check migration version directly in the database (via admintools pod or psql)
kubectl run psql-debug --rm -it \
  --image=postgres:15-alpine \
  --restart=Never \
  -n payments \
  -- psql "host=127.0.0.1 port=5432 user=payments-api dbname=payments sslmode=disable" \
  -c "SELECT version, dirty FROM schema_migrations;"
```

---

## 6. Backup and Point-In-Time Recovery (PITR)

### How Cloud SQL Backups Work

Cloud SQL provides two complementary backup mechanisms:

```
Time ──────────────────────────────────────────────────────────────►

03:00     04:00     05:00     06:00
  │                                     12:37:42 ← incident time
  │ Daily automated backup               │
  │ (full snapshot)                      │ PITR target
  └──────────────────────────────────────┘
  
  Cloud SQL can restore to ANY second between the daily backup
  and now, using the daily backup + WAL (Write-Ahead Log) replay.
  
  WAL is streamed continuously to Cloud Storage.
  Retention: 7 days of WAL (set in Terraform module).
```

| Backup Type | What It Is | Use Case |
|-------------|-----------|----------|
| Automated backup | Full database snapshot at `start_time` | Daily safety net |
| On-demand backup | Manual snapshot triggered via API/Console | Before risky migrations |
| PITR | Replay WAL from a backup to any point in time | Recover from data corruption |

### Enabling PITR — Verify Terraform Config

The `terraform/modules/cloud-sql/main.tf` sets:
```hcl
point_in_time_recovery_enabled = true
transaction_log_retention_days = 7
```

Verify it's active:
```bash
gcloud sql instances describe gke-lab-postgres-dev \
  --project=gke-labs \
  --format="json" | \
  jq '.settings.backupConfiguration | {
    enabled,
    pointInTimeRecoveryEnabled,
    transactionLogRetentionDays,
    startTime
  }'

# Expected:
# {
#   "enabled": true,
#   "pointInTimeRecoveryEnabled": true,
#   "transactionLogRetentionDays": 7,
#   "startTime": "03:00"
# }
```

### Creating an On-Demand Backup

Always create a manual backup before running schema migrations or any bulk data operation:

```bash
# Create on-demand backup before a risky migration
gcloud sql backups create \
  --instance=gke-lab-postgres-dev \
  --project=gke-labs \
  --description="pre-migration-000004-$(date +%Y%m%d-%H%M%S)"

# List all backups
gcloud sql backups list \
  --instance=gke-lab-postgres-dev \
  --project=gke-labs \
  --format="table(id,startTime,status,type,description)"

# Output example:
# ID          START_TIME                STATUS       TYPE        DESCRIPTION
# 1719298823  2026-06-25T03:00:23Z      SUCCESSFUL   AUTOMATED
# 1719312422  2026-06-25T11:47:02Z      SUCCESSFUL   ON_DEMAND   pre-migration-000004-...
```

### Point-In-Time Recovery Procedure

**Scenario:** A developer accidentally ran `DELETE FROM payments WHERE true` at 2026-06-25T14:22:10Z.
The table had 847,293 rows. You need to recover.

```bash
# Step 1: Identify the target recovery time
# Recovery time must be BEFORE the accident — use 14:21:50 for a 20-second margin
RECOVERY_TIME="2026-06-25T14:21:50.000Z"
TARGET_INSTANCE="gke-lab-postgres-dev-pitr-$(date +%Y%m%d-%H%M)"

# Step 2: Clone the instance to a new instance at the target point in time
# IMPORTANT: PITR restores to a NEW instance — never restores in-place.
# This protects you from making the situation worse.
gcloud sql instances clone gke-lab-postgres-dev ${TARGET_INSTANCE} \
  --project=gke-labs \
  --point-in-time="${RECOVERY_TIME}"

# This takes 5-15 minutes depending on database size.
# Watch progress:
gcloud sql operations list \
  --instance=${TARGET_INSTANCE} \
  --project=gke-labs \
  --filter="status!=DONE"

# Step 3: Verify the recovered data
gcloud sql connect ${TARGET_INSTANCE} \
  --user=payments-api \
  --project=gke-labs

# Inside psql:
SELECT COUNT(*) FROM payments;
-- Expected: 847293 rows recovered

# Step 4: Export the recovered table to GCS for safe transfer
gcloud sql export csv ${TARGET_INSTANCE} \
  gs://gke-labs-db-recovery/payments-recovered-$(date +%Y%m%d).csv \
  --project=gke-labs \
  --database=payments \
  --query="SELECT * FROM payments"

# Step 5: Import the recovered data back to the production instance
# Use UPSERT to avoid duplicates if any payments were processed after the incident
gcloud sql import csv gke-lab-postgres-dev \
  gs://gke-labs-db-recovery/payments-recovered-$(date +%Y%m%d).csv \
  --project=gke-labs \
  --database=payments \
  --table=payments

# Step 6: Clean up the recovery instance (it costs money while running)
gcloud sql instances delete ${TARGET_INSTANCE} \
  --project=gke-labs \
  --quiet
```

### PITR Recovery Time Objective (RTO)

For the lab's `db-g1-small` instance with a small database:
- Clone time: ~5 minutes
- Verification: ~5 minutes
- Data transfer (export/import): variable

For production (`db-n1-standard-4`, 500GB database):
- Clone time: 20-40 minutes
- Plan for RTO of 60-90 minutes for PITR scenarios

**Key lesson for financial services:** PITR gives you theoretical recovery to any second
within the retention window, but the actual RTO depends on database size. Test your recovery
procedure quarterly — do not discover your RTO under real incident pressure.

---

## 7. Slow Query Analysis — pg_stat_statements and EXPLAIN ANALYZE

### Enabling pg_stat_statements

Cloud SQL for PostgreSQL supports `pg_stat_statements` but it must be enabled as a
database flag (it's a shared_preload_library):

```bash
# Enable via gcloud (requires instance restart)
gcloud sql instances patch gke-lab-postgres-dev \
  --project=gke-labs \
  --database-flags=pg_stat_statements.track=all

# Then create the extension in each database
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -c cloud-sql-proxy -- /bin/sh -c \
  "psql -h 127.0.0.1 -U payments-api -d payments \
   -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'"
```

### Finding Slow Queries

```sql
-- Connect to the database via psql
-- (from a debug pod with the cloud-sql-proxy sidecar)

-- Top 10 slowest queries by total time
SELECT
  round(total_exec_time::numeric, 2)        AS total_ms,
  calls,
  round(mean_exec_time::numeric, 2)         AS mean_ms,
  round(stddev_exec_time::numeric, 2)       AS stddev_ms,
  round((100 * total_exec_time /
    sum(total_exec_time) OVER ())::numeric, 2) AS pct_total,
  substring(query, 1, 120)                  AS query_snippet
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Queries with high variance (inconsistent performance = cache misses / lock waits)
SELECT
  calls,
  round(mean_exec_time::numeric, 2)   AS mean_ms,
  round(stddev_exec_time::numeric, 2) AS stddev_ms,
  round((stddev_exec_time / NULLIF(mean_exec_time,0))::numeric, 3) AS cv,
  substring(query, 1, 120) AS query_snippet
FROM pg_stat_statements
WHERE calls > 100
ORDER BY cv DESC
LIMIT 10;

-- Reset statistics (do this after resolving a slow query to get fresh data)
SELECT pg_stat_statements_reset();
```

### EXPLAIN ANALYZE — Reading the Output

```sql
-- Run EXPLAIN ANALYZE on a suspected slow query
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT p.id, p.amount, p.status, a.account_number
FROM payments p
JOIN accounts a ON p.account_id = a.id
WHERE p.status = 'PENDING'
  AND p.created_at > NOW() - INTERVAL '1 hour'
ORDER BY p.created_at DESC
LIMIT 100;
```

```
-- Sample EXPLAIN output and how to read it:

Limit  (cost=0.00..245.00 rows=100 width=48) (actual time=0.821..0.843 ms rows=100 loops=1)
  ->  Nested Loop  (cost=0.00..2450.00 rows=1000 width=48) (actual time=0.819..0.838 ms)
        ->  Index Scan using idx_payments_status_created on payments p
              (cost=0.00..850.00 rows=1000 width=32) (actual time=0.012..0.052 ms rows=100)
              Index Cond: ((status = 'PENDING') AND (created_at > (now() - '1 hour')))
              Buffers: shared hit=12                   ← 12 pages from cache (GOOD)
        ->  Index Scan using accounts_pkey on accounts a
              (cost=0.00..1.60 rows=1 width=16) (actual time=0.007..0.007 ms rows=1)
              Index Cond: (id = p.account_id)
              Buffers: shared hit=3 read=0             ← all from cache (GOOD)
Planning Time: 0.321 ms
Execution Time: 0.869 ms                              ← total wall-clock time

-- RED FLAGS to look for in EXPLAIN output:
-- "Seq Scan" on a large table → missing index
-- "Buffers: shared read=N" (large N) → data not cached, doing disk I/O
-- "Hash Join" on large tables with bad row estimates → stale statistics
-- cost=XX rows=1 actual rows=50000 → row estimate is wildly wrong (run ANALYZE)
-- "Sort Method: external merge Disk" → sort spilled to disk (increase work_mem)
```

### Running ANALYZE to Update Statistics

```bash
# If row estimates are wrong, update statistics
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -c payments-api \
  -- psql -h 127.0.0.1 -U payments-api -d payments \
  -c "ANALYZE VERBOSE payments;"

# For the whole database
kubectl exec -n payments \
  $(kubectl get pod -n payments -l app=payments-api -o name | head -1) \
  -c payments-api \
  -- psql -h 127.0.0.1 -U payments-api -d payments \
  -c "ANALYZE VERBOSE;"
```

### Cloud SQL Insights — Managed Query Analysis

Cloud SQL Insights is a managed alternative to manually querying pg_stat_statements:

```bash
# Enable Query Insights (requires Enterprise or Enterprise Plus tier)
gcloud sql instances patch gke-lab-postgres-dev \
  --project=gke-labs \
  --insights-config-query-insights-enabled \
  --insights-config-record-application-tags \
  --insights-config-record-client-address

# View in Cloud Console:
# https://console.cloud.google.com/sql/instances/gke-lab-postgres-dev/insights
```

---

## 8. Break-It & Fix-It Exercises

### Exercise 1: Misconfigure the Instance Connection Name

**Goal:** Understand what happens when the Auth Proxy can't find the Cloud SQL instance.

```bash
# Step 1: Update the ConfigMap with a wrong instance connection name
kubectl patch configmap payments-cloudsql-config \
  -n payments \
  --type=merge \
  -p '{"data":{"instance_connection_name":"gke-labs:europe-west1:nonexistent-db"}}'

# Step 2: Restart a pod to pick up the new ConfigMap
kubectl rollout restart deployment/payments-api -n payments

# Step 3: Observe the failure
kubectl logs -n payments \
  -l app=payments-api \
  -c cloud-sql-proxy \
  --tail=20

# Expected error:
# {"level":"error","msg":"Error dialing instance","err":"instance not found"}

# Step 4: Check if the app container is also failing
kubectl logs -n payments \
  -l app=payments-api \
  -c payments-api \
  --tail=20
# Expected: connection refused or dial tcp 127.0.0.1:5432: connect: connection refused

# Step 5: Fix by restoring the correct connection name
kubectl patch configmap payments-cloudsql-config \
  -n payments \
  --type=merge \
  -p '{"data":{"instance_connection_name":"gke-labs:europe-west1:gke-lab-postgres-dev"}}'

kubectl rollout restart deployment/payments-api -n payments
kubectl rollout status deployment/payments-api -n payments
```

---

### Exercise 2: Remove the cloudsql.client IAM Role

**Goal:** Understand how IAM authentication failures surface.

```bash
# Step 1: Remove the IAM binding (note: this affects ALL pods using this GSA)
gcloud projects remove-iam-policy-binding gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

# Step 2: Restart the deployment to force new proxy connections
kubectl rollout restart deployment/payments-api -n payments

# Step 3: Read the proxy logs
kubectl logs -n payments \
  -l app=payments-api \
  -c cloud-sql-proxy \
  --tail=30

# Expected error:
# {"level":"error","msg":"Failed to retrieve instance metadata",
#  "err":"googleapi: Error 403: The client is not authorized to make this request"}

# Step 4: Restore the IAM binding
gcloud projects add-iam-policy-binding gke-labs \
  --member="serviceAccount:payments-api@gke-labs.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

# Step 5: Restart and verify recovery
kubectl rollout restart deployment/payments-api -n payments
kubectl rollout status deployment/payments-api -n payments
```

---

### Exercise 3: Break a Migration with a Dirty Flag

**Goal:** Understand how golang-migrate handles failed migrations and the `dirty` state.

```bash
# Step 1: Intentionally create a bad migration file
cat > /tmp/000099_bad_migration.up.sql << 'EOF'
-- This migration will fail partway through
ALTER TABLE payments ADD COLUMN test_col VARCHAR(100);
-- Syntax error below will cause the migration to fail mid-transaction
THIS IS NOT VALID SQL;
EOF

# Step 2: Run the bad migration
migrate \
  -source file:///tmp \
  -database "postgres://payments-api:${DB_PASSWORD}@127.0.0.1:5432/payments?sslmode=disable" \
  up

# Expected error:
# error: migration failed: syntax error at or near "THIS" (details...)
# DIRTY: true

# Step 3: Observe the dirty flag
migrate \
  -source file:///tmp \
  -database "postgres://payments-api:${DB_PASSWORD}@127.0.0.1:5432/payments?sslmode=disable" \
  version
# Output: 99 (dirty)

# Step 4: Running further migrations will fail:
# error: Dirty database version 99. Fix and force version.

# Step 5: Manually fix — force the version back to last known good
migrate \
  -source file:///tmp \
  -database "postgres://payments-api:${DB_PASSWORD}@127.0.0.1:5432/payments?sslmode=disable" \
  force 98

# Verify the dirty flag is cleared
migrate \
  -source file:///tmp \
  -database "postgres://payments-api:${DB_PASSWORD}@127.0.0.1:5432/payments?sslmode=disable" \
  version
# Output: 98 (clean)
```

---

### Exercise 4: Simulate a Database Failover

**Goal:** Observe Regional (HA) Cloud SQL automatic failover and measure recovery time.

```bash
# IMPORTANT: This exercise requires a REGIONAL instance (availability_type=REGIONAL).
# The lab's default is ZONAL. Temporarily recreate with REGIONAL availability
# or observe by reading docs only if you want to skip the cost.

# Step 1: Check current availability type
gcloud sql instances describe gke-lab-postgres-dev \
  --project=gke-labs \
  --format="value(settings.availabilityType)"

# Step 2: If REGIONAL, trigger a manual failover
gcloud sql instances failover gke-lab-postgres-dev \
  --project=gke-labs

# Step 3: While failover is in progress, watch your application
# In a separate terminal, run a loop that hits the payments API
while true; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:8080/health)
  echo "$(date +%H:%M:%S) HTTP $HTTP_CODE"
  sleep 0.5
done

# Expected during failover (~30-60 seconds):
# 14:23:10 HTTP 200
# 14:23:10 HTTP 200
# 14:23:11 HTTP 503   ← failover begins
# ...20-60 seconds of errors...
# 14:23:48 HTTP 200   ← reconnected to new primary

# Step 4: Check what happened in the proxy logs
kubectl logs -n payments \
  -l app=payments-api \
  -c cloud-sql-proxy \
  --since=5m
# You should see reconnection attempts and successful reconnection
```

---

## 9. Interview Q&A

---

### Q1: Why use Cloud SQL Auth Proxy instead of connecting directly to the private IP?

**Answer:**

Direct private IP connection works but has significant security weaknesses:
1. **Static credentials:** You must store a database password somewhere (Secret, env var), creating a secret management problem.
2. **No automatic TLS:** You must configure client-side SSL certificates and rotate them.
3. **Dynamic IPs:** If the Cloud SQL instance is recreated (e.g., after a major version upgrade), its private IP can change. The Auth Proxy uses the instance connection name (`PROJECT:REGION:INSTANCE`), which is stable.
4. **No IAM integration:** There's no way to tie a database connection to a GKE pod's Workload Identity when connecting directly.

The Auth Proxy solves all of these: it uses the pod's IAM identity (Workload Identity), establishes an mTLS tunnel automatically, and references the instance by name rather than IP.

---

### Q2: What happens to database connections during a Cloud SQL maintenance window?

**Answer:**

Cloud SQL maintenance events cause the instance to restart. For ZONAL instances this means
all connections drop. For REGIONAL (HA) instances, Cloud SQL performs a failover to the
standby replica first, then updates the primary — connection drops are shorter (~30 seconds).

The Auth Proxy handles reconnection automatically. Your application must also handle
connection pool reconnection:

- **pgx (Go):** uses `pgxpool` with `HealthCheckPeriod` to detect broken connections
- **psycopg2 (Python):** set `keepalives=1` and handle `OperationalError` with retry logic
- **pg (Node.js):** `pg-pool` has built-in reconnection, set `idleTimeoutMillis`

Production pattern: set `maxConnLifetime: 1h` in your connection pool so connections are
recycled before the maintenance window opens (typically 4 hours, pre-announced in the
Cloud Console).

---

### Q3: How does Private Service Access differ from Private Google Access?

**Answer:**

They are different features often confused:

**Private Service Access (PSA):**
- Creates a VPC peering between your VPC and a Google-managed service producer network
- Required for Cloud SQL private IP, Memorystore, and other managed services that need a VM with a private IP in your address space
- You allocate an IP range and create a `google_service_networking_connection`
- Traffic goes through the peering, not through the internet

**Private Google Access (PGA):**
- Allows VMs without external IPs to reach Google APIs (`storage.googleapis.com`, `pubsub.googleapis.com`, etc.)
- Traffic to Google APIs goes via Google's internal network, not through the internet
- Configured per subnet: `google_compute_subnetwork` with `private_ip_google_access = true`
- Uses the special `199.36.153.8/30` range (or Virtual Private Cloud service controls range)

In this lab: you need **both**. PSA for the Cloud SQL instance private IP, and PGA so your GKE nodes (which have no external IP) can reach the Cloud SQL Auth Proxy's API endpoint at `sqladmin.googleapis.com`.

---

### Q4: A schema migration ran and now queries are 10x slower. What do you check first?

**Answer:**

```sql
-- Step 1: Check if statistics are stale after bulk insert/delete
-- Migrations that move large amounts of data can make statistics stale
SELECT schemaname, tablename, last_autoanalyze, last_analyze, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
ORDER BY last_autoanalyze DESC NULLS LAST;

-- If last_analyze is old, run it manually:
ANALYZE VERBOSE payments;

-- Step 2: Check if an index was accidentally dropped
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'payments';

-- Step 3: Check for table bloat from a migration that deleted many rows
SELECT
  relname AS table,
  n_dead_tup,
  n_live_tup,
  round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct
FROM pg_stat_user_tables
WHERE relname = 'payments';
-- If dead_pct > 20%, run: VACUUM ANALYZE payments;

-- Step 4: Use EXPLAIN ANALYZE to confirm which plan changed
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- Look for: Seq Scan where Index Scan was expected
```

---

### Q5: Explain the difference between `availability_type = ZONAL` and `REGIONAL`. When must you use REGIONAL?

**Answer:**

**ZONAL:**
- Single database instance in one zone
- If the zone has an outage, your database is unavailable
- No automatic failover
- ~50% cheaper than REGIONAL
- Appropriate for: development, staging, non-critical workloads

**REGIONAL:**
- Primary in one zone, hot standby replica in another zone in the same region
- Standby is continuously synchronized via synchronous replication
- Automatic failover in ~30-60 seconds if the primary zone fails
- Data is committed to both zones before acknowledging writes (zero data loss)
- Appropriate for: any production workload with an SLA, financial transaction databases

**Must use REGIONAL when:**
- Your SLA requires > 99.9% availability
- Data loss is unacceptable (RPO = 0 for committed transactions)
- You need to pass PCI-DSS, SOC 2, or FCA audit requirements for high availability

**Important caveat:** REGIONAL protects against zone failure, not region failure. For cross-region DR, you need either a Cloud SQL read replica in another region or a separate database with replication at the application layer.
