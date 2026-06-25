# Lab 14 — Temporal Workflows

> **Goal:** Understand why Temporal exists, deploy it on GKE using the Helm chart in this repo,
> and implement the payments saga pattern — a multi-step financial transaction that survives
> crashes, retries, and compensating rollbacks without data corruption.

> **Series position:** Labs 01–13 covered cluster fundamentals through alerting. This lab introduces
> **workflow orchestration** — the missing layer between message queues and databases that makes
> long-running distributed transactions reliable. The payments namespace used throughout this repo
> gets its first saga.

---

## Table of Contents

1. [Why Workflow Orchestration?](#1-why-workflow-orchestration)
2. [Temporal Concepts — Workflow, Activity, Worker, Task Queue, Namespace](#2-temporal-concepts)
3. [Failure Modes and Retry Policies](#3-failure-modes-and-retry-policies)
4. [The Payments Saga Pattern](#4-the-payments-saga-pattern)
5. [Deploying Temporal on GKE](#5-deploying-temporal-on-gke)
6. [Using tctl / temporal CLI](#6-using-tctl--temporal-cli)
7. [Break-It & Fix-It Exercises](#7-break-it--fix-it-exercises)
8. [Interview Q&A](#8-interview-qa)

---

## 1. Why Workflow Orchestration?

### The Problem: Distributed Transactions Are Hard

Consider a simple payment: debit the sender, credit the receiver, record the ledger entry.
In a distributed system these are three separate service calls. What happens when the third
call fails after the first two succeeded?

```
Without orchestration — the partial failure problem:

  payments-api
      │
      ├──► ledger-service.Debit(user_A, $100)      ✅ succeeds
      │
      ├──► accounts-service.Reserve(user_B, $100)  ✅ succeeds
      │
      └──► ledger-service.Commit(txn_id)            ❌ CRASHES (pod OOMKilled)

  State: user_A is debited. user_B's funds are reserved.
  No record of the transaction. System is inconsistent.
  No one knows whether to retry or roll back.
```

### Why Not Cron Jobs?

Cron jobs solve the "run this regularly" problem, not the "survive a crash mid-execution" problem.

| Problem | Cron | Message Queue | Temporal |
|---------|------|---------------|---------|
| Execute code on a schedule | ✅ | ❌ | ✅ |
| Retry on failure | Manual | ✅ (with DLQ) | ✅ automatic |
| Survive worker crashes mid-step | ❌ | Partial | ✅ always |
| Multi-step transactions | ❌ | ❌ complex | ✅ native |
| Compensating transactions (rollback) | Manual | Very hard | ✅ native |
| Query workflow state | ❌ | ❌ | ✅ queries |
| Human approval steps | ❌ | ❌ | ✅ signals |
| Long-running (days/months) | ❌ | ❌ | ✅ years |
| Visibility into execution | ❌ | None | ✅ full UI |

### Why Not Just a Message Queue?

Message queues are excellent for decoupling services. But they don't maintain state across steps.
If your workflow has 5 steps and the worker crashes on step 3, the queue doesn't know which step
you were on. You'd need a separate state machine, database transactions, idempotency keys,
dead letter queues, and replay logic — which is what Temporal already provides.

### The Temporal Value Proposition

```
Temporal makes your code behave as if:
  1. The worker never crashes
  2. The network never drops packets
  3. Third-party APIs never time out permanently
  4. You can always see exactly what a workflow is doing

By persisting every step to its event history, Temporal can replay
any workflow from the beginning to reconstruct state after a crash.
```

---

## 2. Temporal Concepts

### Core Primitives

**Workflow** — a function that defines the business logic steps. It must be **deterministic**:
given the same inputs and history, it always produces the same outputs. Workflows orchestrate
Activities. They do not call external systems directly.

**Activity** — a function that calls external systems (DB writes, HTTP calls, GCS uploads).
Activities are allowed to fail. They have their own retry policies. They are the "unsafe" parts
that Temporal wraps with reliability guarantees.

**Worker** — a process your team runs that polls a Task Queue and executes Workflow and Activity
code. Workers are stateless — Temporal Server holds all state.

**Task Queue** — a named queue in Temporal Server. Workers poll their assigned task queue.
You route different workloads to different workers by using different task queues.

**Namespace** — an isolation boundary within Temporal, like a Kubernetes namespace.
Separate namespaces per environment: `payments-prod`, `payments-staging`.

**Event History** — the complete append-only log of everything that happened in a workflow execution.
This is how Temporal achieves durability: when a worker restarts, it replays the history to
reconstruct the current workflow state.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Temporal Server (GKE)                         │
│                                                                       │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────┐  ┌───────────┐  │
│   │   Frontend   │  │   History    │  │ Matching │  │  Worker   │  │
│   │   Service    │  │   Service    │  │ Service  │  │  Service  │  │
│   │  (API gateway│  │ (persists    │  │ (routes  │  │ (internal)│  │
│   │   port 7233) │  │  event log)  │  │ tasks)   │  │           │  │
│   └──────┬───────┘  └──────┬───────┘  └────┬─────┘  └───────────┘  │
│          │                 │               │                          │
│          └─────────────────┴───────────────┘                         │
│                        Cassandra / PostgreSQL                         │
│                        (persistence layer)                            │
└──────────────────────────────────────────────────────────────────────┘
         ▲                                        │
         │ gRPC (port 7233)                       │ polls task queue
         │                                        ▼
  ┌──────┴────────────────────────────────────────────────┐
  │              Your Worker Process (GKE pod)             │
  │                                                        │
  │   Worker.RegisterWorkflow(PaymentSagaWorkflow)         │
  │   Worker.RegisterActivity(DebitActivity)               │
  │   Worker.RegisterActivity(ReserveActivity)             │
  │   Worker.RegisterActivity(CommitActivity)              │
  │   worker.Run()  ← long-polling loop                    │
  └────────────────────────────────────────────────────────┘
         │
         │ also connects
         ▼
  payments-api
  Cloud SQL (payments DB)
  accounts-service
```

### Workflow Execution Lifecycle

```
  Client.ExecuteWorkflow("payment-saga", {from: A, to: B, amount: 100})
         │
         ▼ Temporal creates WorkflowExecution with RunID
  ┌──────────────────────────────────────────────────────────┐
  │ Event History                                             │
  │  [1] WorkflowExecutionStarted                            │
  │  [2] WorkflowTaskScheduled                               │
  │  [3] WorkflowTaskStarted  ← worker picks it up          │
  │  [4] WorkflowTaskCompleted → schedules DebitActivity     │
  │  [5] ActivityTaskScheduled: DebitActivity                │
  │  [6] ActivityTaskStarted  ← worker starts activity      │
  │  [7] ActivityTaskCompleted: result={success: true}       │
  │  [8] WorkflowTaskScheduled  ← workflow continues        │
  │  ...                                                     │
  │  [N] WorkflowExecutionCompleted                          │
  └──────────────────────────────────────────────────────────┘
```

---

## 3. Failure Modes and Retry Policies

### What Happens When a Worker Crashes

Temporal's durability model is based on the event history. When a worker crashes mid-workflow:

```
Worker crashes during ActivityTaskStarted (step 6 above):

  1. Temporal detects the heartbeat timeout (configurable, default 10s for activities)
  2. Temporal marks the activity as failed with reason: "worker lost"
  3. Temporal reschedules the activity on a different worker (or same worker after restart)
  4. The activity REPLAYS from the beginning (it was never "partially committed" to Temporal)
  5. Your activity code must be idempotent for this to work correctly
```

### Activity Retry Policy

```go
// Go SDK example — retry policy for a payment activity
activityOptions := workflow.ActivityOptions{
    TaskQueue:              "payments-task-queue",
    StartToCloseTimeout:    10 * time.Second,  // Activity must complete within 10s
    ScheduleToCloseTimeout: 2 * time.Minute,   // Total time including all retries
    HeartbeatTimeout:       3 * time.Second,   // Long-running activities must heartbeat
    RetryPolicy: &temporal.RetryPolicy{
        InitialInterval:    time.Second,        // Wait 1s before first retry
        BackoffCoefficient: 2.0,                // Double wait each retry: 1s, 2s, 4s, 8s...
        MaximumInterval:    30 * time.Second,   // Cap at 30s between retries
        MaximumAttempts:    5,                  // Give up after 5 attempts
        NonRetryableErrorTypes: []string{
            // These error types will NOT be retried
            "InsufficientFundsError",           // Business logic errors shouldn't retry
            "AccountFrozenError",
            "InvalidAccountError",
        },
    },
}
ctx = workflow.WithActivityOptions(ctx, activityOptions)
```

### Timeout Hierarchy

```
ScheduleToCloseTimeout  ← Total lifecycle of the activity (wall clock)
│
├── ScheduleToStartTimeout  ← How long to wait for a worker to pick it up
│                             (catches: no workers running, queue saturated)
│
└── StartToCloseTimeout     ← How long the execution itself can take
                              (catches: slow APIs, DB timeouts, infinite loops)
```

### Idempotency — The Critical Property

Because activities can be retried, they **must be idempotent**:
calling them twice with the same input produces the same result without side effects.

```go
// BAD: not idempotent — creates duplicate records if retried
func DebitActivity(ctx context.Context, input DebitInput) error {
    _, err := db.Exec("INSERT INTO transactions VALUES ($1, $2, $3)",
        input.TransactionID, input.Amount, time.Now())
    return err
}

// GOOD: idempotent — uses INSERT ... ON CONFLICT DO NOTHING
func DebitActivity(ctx context.Context, input DebitInput) error {
    _, err := db.Exec(`
        INSERT INTO transactions (id, amount, created_at, status)
        VALUES ($1, $2, $3, 'pending')
        ON CONFLICT (id) DO NOTHING`,  -- idempotency key = transaction ID
        input.TransactionID, input.Amount, time.Now())
    return err
}
```

---

## 4. The Payments Saga Pattern

### What Is a Saga?

A saga is a sequence of local transactions, each with a corresponding **compensating transaction**
that reverses its effect. If any step fails, the saga runs compensations in reverse order to
restore consistency.

```
Forward path (happy):                Compensation path (failure):

  Debit sender       ─────────────►  Debit sender reversed (credit back)
       │                                    ▲
       ▼                                    │
  Reserve receiver   ─────────────►  Release reservation
       │                                    ▲
       ▼                                    │
  Commit to ledger   ── FAILS ──────────────┘
                                    (compensations run in reverse order)
```

### Payments Saga Workflow — Go Implementation

```go
// workflows/payment_saga.go
package workflows

import (
    "fmt"
    "time"

    "go.temporal.io/sdk/temporal"
    "go.temporal.io/sdk/workflow"
)

type PaymentInput struct {
    TransactionID string
    FromAccountID string
    ToAccountID   string
    AmountCents   int64
    Currency      string
}

type PaymentResult struct {
    TransactionID string
    Status        string
    LedgerEntryID string
}

// PaymentSagaWorkflow orchestrates a complete payment transaction.
// All external calls are delegated to Activities — the Workflow itself is pure logic.
func PaymentSagaWorkflow(ctx workflow.Context, input PaymentInput) (PaymentResult, error) {
    logger := workflow.GetLogger(ctx)
    logger.Info("PaymentSaga started", "transactionID", input.TransactionID)

    // Track which compensations need to run if something fails
    var compensations []func(workflow.Context) error

    // ── Step 1: Debit the sender ─────────────────────────────────────────────
    debitCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
        TaskQueue:           "payments-task-queue",
        StartToCloseTimeout: 10 * time.Second,
        RetryPolicy: &temporal.RetryPolicy{
            MaximumAttempts:        3,
            NonRetryableErrorTypes: []string{"InsufficientFundsError", "AccountFrozenError"},
        },
    })

    var debitResult DebitResult
    err := workflow.ExecuteActivity(debitCtx, DebitActivity, DebitInput{
        TransactionID: input.TransactionID,
        AccountID:     input.FromAccountID,
        AmountCents:   input.AmountCents,
    }).Get(ctx, &debitResult)

    if err != nil {
        return PaymentResult{}, fmt.Errorf("debit failed (no compensation needed): %w", err)
    }

    // Register compensation: if anything below fails, credit the sender back
    compensations = append(compensations, func(ctx workflow.Context) error {
        return workflow.ExecuteActivity(ctx, CreditActivity, CreditInput{
            TransactionID: "comp-" + input.TransactionID,
            AccountID:     input.FromAccountID,
            AmountCents:   input.AmountCents,
            Reason:        "saga_compensation",
        }).Get(ctx, nil)
    })

    // ── Step 2: Reserve funds for the receiver ───────────────────────────────
    reserveCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
        TaskQueue:           "payments-task-queue",
        StartToCloseTimeout: 10 * time.Second,
        RetryPolicy: &temporal.RetryPolicy{
            MaximumAttempts:        3,
            NonRetryableErrorTypes: []string{"AccountClosedError"},
        },
    })

    var reserveResult ReserveResult
    err = workflow.ExecuteActivity(reserveCtx, ReserveActivity, ReserveInput{
        TransactionID: input.TransactionID,
        AccountID:     input.ToAccountID,
        AmountCents:   input.AmountCents,
    }).Get(ctx, &reserveResult)

    if err != nil {
        // Step 2 failed — run compensations (credit sender back)
        logger.Error("Reserve failed, running compensations", "error", err)
        runCompensations(ctx, compensations, logger)
        return PaymentResult{}, fmt.Errorf("reserve failed, saga compensated: %w", err)
    }

    // Register compensation: release the reservation
    compensations = append(compensations, func(ctx workflow.Context) error {
        return workflow.ExecuteActivity(ctx, ReleaseReservationActivity, ReserveInput{
            TransactionID: input.TransactionID,
            AccountID:     input.ToAccountID,
            AmountCents:   input.AmountCents,
        }).Get(ctx, nil)
    })

    // ── Step 3: Commit — finalize the ledger entry ───────────────────────────
    commitCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
        TaskQueue:           "payments-task-queue",
        StartToCloseTimeout: 10 * time.Second,
        RetryPolicy: &temporal.RetryPolicy{
            MaximumAttempts: 5, // Commit is safe to retry — it's idempotent
        },
    })

    var commitResult CommitResult
    err = workflow.ExecuteActivity(commitCtx, CommitActivity, CommitInput{
        TransactionID:  input.TransactionID,
        DebitEntryID:   debitResult.EntryID,
        ReserveEntryID: reserveResult.EntryID,
    }).Get(ctx, &commitResult)

    if err != nil {
        logger.Error("Commit failed, running compensations", "error", err)
        runCompensations(ctx, compensations, logger)
        return PaymentResult{}, fmt.Errorf("commit failed, saga compensated: %w", err)
    }

    logger.Info("PaymentSaga completed", "transactionID", input.TransactionID,
        "ledgerEntryID", commitResult.LedgerEntryID)

    return PaymentResult{
        TransactionID: input.TransactionID,
        Status:        "completed",
        LedgerEntryID: commitResult.LedgerEntryID,
    }, nil
}

// runCompensations executes all registered compensations in reverse order.
func runCompensations(ctx workflow.Context, compensations []func(workflow.Context) error,
    logger workflow.Logger) {

    compensationCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
        StartToCloseTimeout: 30 * time.Second,
        RetryPolicy: &temporal.RetryPolicy{
            MaximumAttempts: 10, // Compensations MUST succeed — retry aggressively
        },
    })

    for i := len(compensations) - 1; i >= 0; i-- {
        if err := compensations[i](compensationCtx); err != nil {
            // Log but don't stop — attempt all compensations
            logger.Error("Compensation failed", "index", i, "error", err)
        }
    }
}
```

### The Worker That Runs the Saga

```go
// cmd/worker/main.go
package main

import (
    "log"
    "gke-labs/activities"
    "gke-labs/workflows"
    "go.temporal.io/sdk/client"
    "go.temporal.io/sdk/worker"
)

func main() {
    c, err := client.Dial(client.Options{
        HostPort:  "temporal-frontend.temporal:7233",
        Namespace: "payments-prod",
    })
    if err != nil {
        log.Fatalf("Failed to connect to Temporal: %v", err)
    }
    defer c.Close()

    w := worker.New(c, "payments-task-queue", worker.Options{
        MaxConcurrentActivityExecutionSize:    10,
        MaxConcurrentWorkflowTaskExecutionSize: 5,
    })

    w.RegisterWorkflow(workflows.PaymentSagaWorkflow)
    w.RegisterActivity(activities.DebitActivity)
    w.RegisterActivity(activities.ReserveActivity)
    w.RegisterActivity(activities.CommitActivity)
    w.RegisterActivity(activities.CreditActivity)          // compensation
    w.RegisterActivity(activities.ReleaseReservationActivity) // compensation

    if err := w.Run(worker.InterruptCh()); err != nil {
        log.Fatalf("Worker exited: %v", err)
    }
}
```

---

## 5. Deploying Temporal on GKE

### Repo Structure

This repo includes a Helm chart for Temporal at `helm/temporal/`. It deploys the full
Temporal server stack on the `temporal` namespace.

```bash
ls helm/temporal/
# Chart.yaml  values.yaml  templates/

# The chart deploys:
# - temporal-frontend  (gRPC API, port 7233)
# - temporal-history   (workflow event persistence)
# - temporal-matching  (task queue routing)
# - temporal-worker    (internal Temporal workers, not your workers)
# - temporal-web       (UI, port 8080)
# - PostgreSQL         (bundled, or use Cloud SQL — see values.yaml)
```

### Deploy to GKE

```bash
# Step 1 — Create the namespace
kubectl create namespace temporal

# Step 2 — Create a secret for PostgreSQL credentials
# (if using Cloud SQL — recommended for production)
kubectl create secret generic temporal-postgres \
  --from-literal=password='your-strong-password-here' \
  --namespace=temporal

# Step 3 — Review and adjust values
cat helm/temporal/values.yaml
# Key settings to review:
#   server.replicaCount: 1 (increase for production)
#   postgresql.enabled: true (set false and configure externalDatabase for Cloud SQL)
#   web.enabled: true
#   server.config.persistence.default.driver: sql

# Step 4 — Install
helm upgrade --install temporal helm/temporal/ \
  --namespace temporal \
  --values helm/temporal/values.yaml \
  --wait \
  --timeout=5m

# Step 5 — Verify all pods are running
kubectl get pods -n temporal
# Expected output:
# NAME                                  READY   STATUS    RESTARTS   AGE
# temporal-frontend-7d9b8c-xxxxx        1/1     Running   0          2m
# temporal-history-5f6d7e-xxxxx         1/1     Running   0          2m
# temporal-matching-6c5b4a-xxxxx        1/1     Running   0          2m
# temporal-worker-8e7d6c-xxxxx          1/1     Running   0          2m
# temporal-web-9f8e7d-xxxxx             1/1     Running   0          2m
# temporal-postgresql-0                 1/1     Running   0          2m
```

### Access the Temporal UI

```bash
# Port-forward to the web UI
kubectl port-forward svc/temporal-web 8080:8080 -n temporal &
# Open http://localhost:8080
# You should see the default namespace and workflow execution list
```

### Using Docker Compose Locally (for development)

The repo includes `local/docker-compose.yml` which runs a single-node Temporal for local dev:

```bash
cd local/
docker compose up -d

# Services started:
#   temporalio/auto-setup:1.24  → localhost:7233 (gRPC API)
#   temporal-ui                 → localhost:8080 (Web UI)

# Connect your worker to local Temporal
export TEMPORAL_GRPC_ENDPOINT=localhost:7233

# Run your worker locally
go run ./cmd/worker/main.go
```

### Worker Deployment on GKE

```yaml
# k8s/payments-worker-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-temporal-worker
  namespace: payments
spec:
  replicas: 3   # Multiple workers — Temporal distributes tasks across all of them
  selector:
    matchLabels:
      app: payments-temporal-worker
  template:
    metadata:
      labels:
        app: payments-temporal-worker
    spec:
      serviceAccountName: payments-worker-sa  # Needs Workload Identity for DB access
      containers:
        - name: worker
          image: gcr.io/gke-labs/payments-worker:latest
          env:
            - name: TEMPORAL_GRPC_ENDPOINT
              value: "temporal-frontend.temporal:7233"
            - name: TEMPORAL_NAMESPACE
              value: "payments-prod"
            - name: TEMPORAL_TASK_QUEUE
              value: "payments-task-queue"
            - name: DB_HOST
              value: "127.0.0.1"  # Cloud SQL Auth Proxy sidecar
            - name: DB_NAME
              value: "payments"
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
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
```

---

## 6. Using tctl / temporal CLI

### Install temporal CLI

```bash
# macOS
brew install temporal

# Linux
curl -sSf https://temporal.download/cli.sh | sh

# Or run from the Temporal server pod
kubectl exec -n temporal deployment/temporal-frontend -- temporal --version
```

### Namespace Management

```bash
# Set environment for convenience
export TEMPORAL_ADDRESS=localhost:7233  # after port-forwarding
export TEMPORAL_NAMESPACE=payments-prod

# Create a namespace
temporal operator namespace create payments-prod \
  --description "Payments domain workflows" \
  --retention 30d    # How long to keep workflow history after completion

# List namespaces
temporal operator namespace list

# Describe a namespace
temporal operator namespace describe payments-prod
```

### Workflow Operations

```bash
# Start a workflow manually (useful for testing)
temporal workflow start \
  --task-queue payments-task-queue \
  --type PaymentSagaWorkflow \
  --input '{"transactionID":"test-001","fromAccountID":"acct-A","toAccountID":"acct-B","amountCents":10000,"currency":"GBP"}' \
  --namespace payments-prod

# List running workflows
temporal workflow list \
  --namespace payments-prod \
  --query 'ExecutionStatus="Running"'

# Describe a specific workflow (see its current state and history)
temporal workflow describe \
  --workflow-id payment-saga-test-001 \
  --namespace payments-prod

# Show the full event history of a workflow
temporal workflow show \
  --workflow-id payment-saga-test-001 \
  --namespace payments-prod

# Query a workflow's current state (requires a Query handler in the workflow code)
temporal workflow query \
  --workflow-id payment-saga-test-001 \
  --query-type getCurrentStep \
  --namespace payments-prod
```

### Signals and Cancellations

```bash
# Send a signal to a running workflow
# (e.g., "approve" a payment that requires human review)
temporal workflow signal \
  --workflow-id payment-saga-test-001 \
  --name approvePayment \
  --input '{"approvedBy":"manager@example.com"}' \
  --namespace payments-prod

# Cancel a running workflow gracefully
# (triggers cancellation handler in the workflow code)
temporal workflow cancel \
  --workflow-id payment-saga-test-001 \
  --namespace payments-prod

# Terminate immediately (no cancellation handler — use only in emergencies)
temporal workflow terminate \
  --workflow-id payment-saga-test-001 \
  --reason "Emergency stop — suspected fraud" \
  --namespace payments-prod
```

### Searching Workflows with List Filters

```bash
# Find all failed workflows in the last hour
temporal workflow list \
  --namespace payments-prod \
  --query 'ExecutionStatus="Failed" AND StartTime > "2024-01-15T10:00:00Z"'

# Find workflows by custom search attribute (if configured)
# e.g., find all workflows for account acct-A
temporal workflow list \
  --namespace payments-prod \
  --query 'CustomStringField01="acct-A"'

# Count workflows by status
temporal workflow count \
  --namespace payments-prod \
  --query 'ExecutionStatus="Running"'
```

---

## 7. Break-It & Fix-It Exercises

### Exercise 1 — Crash a Worker Mid-Workflow

**Goal:** Prove that Temporal resumes workflows after a worker crash.

```bash
# Step 1 — Start a long-running workflow (with artificial delays between steps)
kubectl exec -n temporal deployment/temporal-frontend -- temporal workflow start \
  --task-queue payments-task-queue \
  --type PaymentSagaWorkflow \
  --input '{"transactionID":"crash-test-001","fromAccountID":"acct-A","toAccountID":"acct-B","amountCents":5000,"currency":"GBP"}' \
  --namespace payments-prod

# Note the workflow ID
WF_ID="PaymentSagaWorkflow-crash-test-001"

# Step 2 — Watch the workflow progress in the UI
kubectl port-forward svc/temporal-web 8080:8080 -n temporal &
# Open http://localhost:8080 → search for the workflow ID

# Step 3 — Kill all worker pods while the workflow is mid-execution
kubectl delete pods -n payments -l app=payments-temporal-worker

# Step 4 — Watch the workflow in the UI — it should PAUSE (no workers)
# The workflow is not lost — it's waiting for a worker to pick up the pending task

# Step 5 — The deployment will recreate the worker pods automatically
# Watch the pods restart
kubectl get pods -n payments -l app=payments-temporal-worker -w

# Step 6 — Verify the workflow completes
temporal workflow describe \
  --workflow-id $WF_ID \
  --namespace payments-prod
# Status should eventually be: Completed

# Step 7 — Check the event history to see the worker crash and resume
temporal workflow show \
  --workflow-id $WF_ID \
  --namespace payments-prod
# Look for: ActivityTaskTimedOut (when worker died) → ActivityTaskScheduled (retry)
```

**What you observed:** The workflow paused when all workers died but was NOT lost. When a new worker
came up and polled the task queue, Temporal delivered the pending activity task and execution
resumed exactly where it left off.

---

### Exercise 2 — Trigger a Saga Compensation

**Goal:** Cause an activity to fail non-retryably and observe the compensating transactions run.

```bash
# Step 1 — Configure the accounts-service to reject "acct-FROZEN"
kubectl set env deployment/accounts-service \
  -n payments \
  FROZEN_ACCOUNTS=acct-FROZEN

# Step 2 — Start a workflow targeting the frozen account
temporal workflow start \
  --task-queue payments-task-queue \
  --type PaymentSagaWorkflow \
  --input '{"transactionID":"comp-test-001","fromAccountID":"acct-A","toAccountID":"acct-FROZEN","amountCents":10000,"currency":"GBP"}' \
  --namespace payments-prod

# Step 3 — Watch the workflow in the UI
# Expected sequence:
#   1. DebitActivity → COMPLETED (acct-A debited)
#   2. ReserveActivity → FAILED with "AccountFrozenError" (non-retryable)
#   3. Workflow enters compensation path
#   4. CreditActivity runs → COMPLETED (acct-A credited back)
#   5. Workflow FAILED with message: "reserve failed, saga compensated"

# Step 4 — Verify acct-A balance is unchanged (debit was compensated)
kubectl exec -n payments deploy/accounts-service -- \
  curl -s http://localhost:8080/accounts/acct-A | jq '.balance_cents'
# Expected: same as before the workflow ran

# Cleanup
kubectl set env deployment/accounts-service -n payments FROZEN_ACCOUNTS-
```

---

### Exercise 3 — Non-Determinism Error

**Goal:** Introduce a non-determinism bug and see how Temporal detects it.

```bash
# Temporal replays workflow history to reconstruct state.
# If the workflow code changes between replays, the replay diverges — non-determinism error.

# Step 1 — Start a workflow
temporal workflow start \
  --task-queue payments-task-queue \
  --type PaymentSagaWorkflow \
  --input '{"transactionID":"det-test-001","fromAccountID":"acct-A","toAccountID":"acct-B","amountCents":100}' \
  --namespace payments-prod

# Step 2 — While it's running (paused at an activity), deploy a new worker
# with a different workflow code (e.g., different activity order, added sleep)
kubectl set image deployment/payments-temporal-worker \
  worker=gcr.io/gke-labs/payments-worker:nondeterministic-version \
  -n payments

# Step 3 — Observe the error in worker logs
kubectl logs -n payments -l app=payments-temporal-worker --tail=20
# ERROR: workflow.ExecuteActivity: nondeterministic error: [history says next command
# should be ActivityTaskScheduled for DebitActivity, but code says CommitActivity]

# Lesson: Never change the ORDER of activities in a workflow that has running instances.
# Use versioning: workflow.GetVersion() to handle code changes gracefully.

# Fix: Roll back the worker to the original version
kubectl rollout undo deployment/payments-temporal-worker -n payments
```

---

## 8. Interview Q&A

---

### Q1: What is Temporal and how does it differ from a message queue like Kafka or RabbitMQ?

**Answer:**

Temporal is a **workflow orchestration engine** — it executes and persists the state of long-running
business processes. Kafka and RabbitMQ are **message transport systems** — they move data between
services but don't maintain workflow state.

The key differences:

| Concern | Kafka/RabbitMQ | Temporal |
|---------|---------------|---------|
| Persists workflow step | No — you build this | Yes — event history |
| Retries with backoff | No — you implement | Yes — RetryPolicy |
| Multi-step coordination | No — you build a state machine | Yes — native |
| Compensating transactions | Very hard | Native — saga pattern |
| Query current state | No | Yes — queries, visibility |
| Long-running (months) | No | Yes — years |
| Visibility into execution | No | Full UI + event history |

A common pattern is to use both: Temporal for complex multi-step business workflows (payment sagas,
loan approvals) and Kafka for high-throughput event streaming (audit logs, analytics pipelines).
They are not mutually exclusive.

---

### Q2: What does "deterministic workflow code" mean and why is it required?

**Answer:**

Temporal replays workflow history to rebuild state when a worker restarts. During replay, the workflow
code runs again, but Activity calls are "short-circuited" — instead of actually calling the activity,
Temporal returns the previously recorded result from history.

For this replay to produce the same execution path, the workflow code must be **deterministic**:
given the same inputs and activity results, it must make the same branching decisions every time.

**Things that break determinism:**
- `time.Now()` — returns different values on each run → use `workflow.Now(ctx)` instead
- `rand.Int()` — returns different values → use a seeded PRNG stored in workflow state
- `os.Getenv()` — environment might differ between workers → pass as workflow input
- Goroutines / goroutine order — use `workflow.Go()` for coroutines
- External HTTP calls directly in workflow code — use an Activity for all I/O

**Version handling:** When you need to change workflow logic and running instances exist, use
`workflow.GetVersion()` to branch the new code path without breaking replay of old history.

---

### Q3: A Temporal workflow is stuck in Running state for 3 days. How do you investigate?

**Answer:**

```bash
# Step 1 — Check the event history for the last event
temporal workflow show \
  --workflow-id <id> \
  --namespace payments-prod \
  | tail -30
# Look for: ActivityTaskScheduled but no ActivityTaskStarted → workers not picking it up
# OR: ActivityTaskStarted repeatedly with no Completed → activity keeps failing

# Step 2 — Check the workflow's pending activities
temporal workflow describe \
  --workflow-id <id> \
  --namespace payments-prod
# pendingActivities section shows retryCount, lastFailure

# Step 3 — Check if workers are running and connected
temporal task-queue describe \
  --task-queue payments-task-queue \
  --namespace payments-prod
# pollerCount = 0 → no workers are polling = workers are down

# Step 4 — Check worker pod logs
kubectl logs -n payments -l app=payments-temporal-worker --tail=100
# Common issues: DB connection error, rate limiting, OOM

# Step 5 — If the workflow is truly stuck and should be terminated:
temporal workflow terminate \
  --workflow-id <id> \
  --reason "Stuck for 3 days — root cause: worker DB connection failure" \
  --namespace payments-prod
```

Likely causes:
- Workers are down (check pod status)
- Activity is hitting `MaximumAttempts` and the error type is retryable (bug in error classification)
- `ScheduleToCloseTimeout` hasn't elapsed yet (it's still within the allowed window)
- Activity is calling an external service that's permanently down

---

### Q4: How do you handle a required code change to a workflow that has running instances?

**Answer:**

You cannot simply change the workflow code because existing instances will replay their history
against the new code — if the execution path differs, you get a non-determinism error.

**The `workflow.GetVersion()` pattern:**

```go
// Original code:
err := workflow.ExecuteActivity(ctx, OldDebitActivity, input).Get(ctx, nil)

// After a code change — use GetVersion to branch:
v := workflow.GetVersion(ctx, "use-new-debit-activity", workflow.DefaultVersion, 1)
if v == workflow.DefaultVersion {
    // Original path — used for instances that ran before the change
    err = workflow.ExecuteActivity(ctx, OldDebitActivity, input).Get(ctx, nil)
} else {
    // New path — used for instances started after the change
    err = workflow.ExecuteActivity(ctx, NewDebitActivity, input).Get(ctx, nil)
}
```

`GetVersion` records a marker in the event history on first call. On replay, it returns the
recorded version, so old instances take the old path and new instances take the new path.

For **larger refactors**, the practical approach is:
1. Deploy the new workflow code with a **new workflow type name** (e.g., `PaymentSagaWorkflowV2`)
2. Route new workflow starts to V2
3. Wait for all V1 instances to complete naturally (or force-terminate if they're stuck)
4. Remove V1 worker registration after all V1 instances are done

---

*Next: [Lab 15 — Security: OAuth2, JWT, and RBAC](../15-security-oauth-jwt/README.md)*
