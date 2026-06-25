# Lab 04 — Memorystore Redis: Caching, Eviction, and Connection Patterns

> **Goal:** Understand the operational and architectural differences between Memorystore (managed Redis)
> and self-managed Redis on GKE, connect a GKE workload to Memorystore without a public IP,
> implement cache-aside and write-through patterns, and configure eviction policies correctly
> for a payments platform where some keys must never be evicted. By the end you should be able
> to explain why `allkeys-lru` would be catastrophic for this lab's use case and what to use instead.

---

## Table of Contents

1. [Memorystore vs Self-Managed Redis](#1-memorystore-vs-self-managed-redis)
2. [Connecting from GKE — No Public IP, VPC Access](#2-connecting-from-gke--no-public-ip-vpc-access)
3. [Caching Patterns — Cache-Aside, Write-Through, TTL Design](#3-caching-patterns--cache-aside-write-through-ttl-design)
4. [Eviction Policies — Choosing the Right Strategy](#4-eviction-policies--choosing-the-right-strategy)
5. [Redis Data Types and When to Use Them](#5-redis-data-types-and-when-to-use-them)
6. [Connection Pooling — Client Library Patterns](#6-connection-pooling--client-library-patterns)
7. [Monitoring Redis — Memory, Hit Ratio, Keyspace](#7-monitoring-redis--memory-hit-ratio-keyspace)
8. [Break-It & Fix-It Exercises](#8-break-it--fix-it-exercises)
9. [Interview Q&A](#9-interview-qa)

---

## 1. Memorystore vs Self-Managed Redis

### Why Not Run Redis in GKE?

Running Redis as a Kubernetes Deployment or StatefulSet is technically straightforward.
Many teams start there. Here is why financial-services platforms move off it:

```
Self-Managed Redis on GKE vs Memorystore
─────────────────────────────────────────────────────────────────────

Self-Managed Pain Points:
├── Persistence: you configure RDB/AOF, manage fsync settings
├── Upgrades: you manage Redis version upgrades manually
├── Replication: you configure master/replica, handle failover
├── Backups: no built-in backup — you script RDB snapshots to GCS
├── Scaling: to add memory you must reconfigure StatefulSet and
│            restart Redis (loses all in-memory data)
├── HA: Redis Sentinel or Redis Cluster requires careful K8s setup
│       and expertise most app teams don't have
└── Compliance: you own the patching and CVE response timeline

Memorystore Advantages:
├── Fully managed upgrades (with maintenance window you control)
├── STANDARD_HA tier: automatic failover to replica in < 1 second
├── Encryption in-transit (TLS) and at-rest by default
├── Integrated with Cloud Monitoring — no custom exporters needed
├── AUTH token managed by GCP — no secrets to rotate manually
├── Scaling: resize memory without data loss (in STANDARD_HA tier)
└── SLA: 99.9% monthly uptime for STANDARD_HA
```

### Feature Comparison

| Dimension | Self-Managed on GKE | Memorystore BASIC | Memorystore STANDARD_HA |
|-----------|---------------------|-------------------|------------------------|
| High Availability | Manual Sentinel/Cluster | No HA | Automatic failover < 1s |
| Persistence | Manual RDB/AOF config | No persistence | No persistence |
| Backups | Script to GCS | None | None |
| Memory resize | Restart required | Online resize | Online resize |
| Encryption at-rest | You configure | Included | Included |
| TLS in-transit | You configure | Optional | Optional |
| AUTH | You manage | Included | Included |
| Versions supported | Any | Redis 6.x, 7.x | Redis 6.x, 7.x |
| Cost | Node cost only | Lower | ~2x BASIC |
| SLA | No GCP SLA | 99.9% | 99.9% |
| Network | K8s Service | Private IP only | Private IP only |
| Best for | Dev/test, special configs | Session cache | Production |

### What This Lab Deploys

The Terraform module at `terraform/modules/memorystore/` creates a `STANDARD_HA` instance
for the `payments` namespace — the payments-api uses Redis for:
1. **Idempotency key cache** — store processed payment IDs for 24h to prevent duplicates
2. **Account balance cache** — cache read-heavy account balance queries for 30 seconds
3. **Rate limiting** — sliding window rate limits for the payments API (per-account)

---

## 2. Connecting from GKE — No Public IP, VPC Access

### Memorystore Network Model

Like Cloud SQL, Memorystore uses Private Service Access. The Redis instance gets a private IP
in your VPC — it is never reachable from the public internet.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Your VPC (gke-labs, europe-west1)                                  │
│                                                                     │
│  GKE Node                    PSA Peering                           │
│  10.0.0.0/20                 ◄────────────────────────────┐        │
│     │                                                      │        │
│     │ Pod network 10.4.0.0/14                              │        │
│     ▼                                         ┌────────────┴──────┐ │
│  Pod: payments-api ──────────────────────────►│  Memorystore      │ │
│  redis.NewClient({                            │  10.106.0.4:6379  │ │
│    Addr: "10.106.0.4:6379",                   │  (STANDARD_HA)    │ │
│    Password: env.REDIS_AUTH,                  │                   │ │
│  })                                           └───────────────────┘ │
│                                                                     │
│  ✗ No Auth Proxy needed — connect directly to the private IP.      │
│  ✓ Use AUTH token for authentication.                               │
│  ✓ Enable TLS for in-transit encryption.                            │
└─────────────────────────────────────────────────────────────────────┘
```

### There Is No Proxy — Direct Connection

Unlike Cloud SQL (which requires the Auth Proxy), Memorystore is accessed directly.
Your pod connects to the Redis private IP on port 6379. Authentication is handled by the
Redis AUTH command with the token GCP generates for your instance.

```bash
# Get the Memorystore host and port from Terraform output
REDIS_HOST=$(terraform output -raw memorystore_host 2>/dev/null || \
  gcloud redis instances describe gke-lab-redis-dev \
    --region=europe-west1 \
    --project=gke-labs \
    --format="value(host)")

REDIS_PORT=$(gcloud redis instances describe gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(port)")

echo "Redis: ${REDIS_HOST}:${REDIS_PORT}"
# Output: Redis: 10.106.0.4:6379
```

### Retrieving the AUTH Token

Memorystore generates an AUTH token automatically. It is stored in a GCP Secret:

```bash
# Retrieve the AUTH string via gcloud
gcloud redis instances describe gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(authString)"
# Note: this requires roles/redis.viewer or higher

# In production, the terraform/modules/secret-manager/ module stores this
# as 'payments-api-redis-auth' in Secret Manager.
# ESO (External Secrets Operator) syncs it to the payments namespace.
```

### Kubernetes Secret for Redis AUTH

```yaml
# If using External Secrets Operator (recommended — see lab 05):
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-redis-credentials
  namespace: payments
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secrets-store
    kind: SecretStore
  target:
    name: payments-redis-credentials
  data:
    - secretKey: auth
      remoteRef:
        key: payments-api-redis-auth
        version: latest
```

### Connecting From a Debug Pod

```bash
# Spin up a redis-cli debug pod
kubectl run redis-debug \
  --image=redis:7-alpine \
  --restart=Never \
  --rm -it \
  -n payments \
  -- redis-cli \
     -h ${REDIS_HOST} \
     -p 6379 \
     -a "${REDIS_AUTH}"

# Or with TLS enabled:
kubectl run redis-debug \
  --image=redis:7-alpine \
  --restart=Never \
  --rm -it \
  -n payments \
  -- redis-cli \
     -h ${REDIS_HOST} \
     -p 6379 \
     -a "${REDIS_AUTH}" \
     --tls

# Test the connection
127.0.0.1:6379> PING
PONG

# Check server info
127.0.0.1:6379> INFO server | grep redis_version
redis_version:7.0.15

# Check memory
127.0.0.1:6379> INFO memory | grep used_memory_human
used_memory_human:2.45M
```

### TLS Configuration

Memorystore supports in-transit TLS. For PCI-DSS compliance you should enable it:

```bash
# Enable TLS on the instance (requires instance recreation in BASIC tier,
# or an in-place update in STANDARD_HA)
gcloud redis instances update gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --transit-encryption-mode=SERVER_AUTHENTICATION

# Get the server CA cert
gcloud redis instances describe gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(serverCaCerts[0].cert)" > /tmp/redis-server-ca.pem

# Store as a ConfigMap for pods to mount
kubectl create configmap redis-server-ca \
  --from-file=ca.pem=/tmp/redis-server-ca.pem \
  -n payments
```

---

## 3. Caching Patterns — Cache-Aside, Write-Through, TTL Design

### Pattern 1: Cache-Aside (Lazy Loading)

Cache-aside is the most common pattern. The application is responsible for populating the cache.

```
Read Path:
  1. App checks cache for key
  2. Cache MISS → app queries database
  3. App writes result to cache with TTL
  4. App returns result

Write Path:
  1. App writes to database
  2. App DELETES (not updates) the cache key
     (prevents stale reads if update fails partway)
```

```python
# Python example — cache-aside for account balance
import redis
import json
from datetime import timedelta

r = redis.Redis(
    host=REDIS_HOST,
    port=6379,
    password=REDIS_AUTH,
    ssl=True,
    ssl_ca_certs='/etc/redis-ca/ca.pem',
    decode_responses=True,
)

BALANCE_TTL = timedelta(seconds=30)   # 30-second TTL for balance cache

def get_account_balance(account_id: str) -> dict:
    cache_key = f"balance:{account_id}"

    # Step 1: Try cache
    cached = r.get(cache_key)
    if cached:
        return json.loads(cached)  # cache HIT

    # Step 2: Cache MISS — query database
    balance = db.query(
        "SELECT balance, currency, updated_at FROM accounts WHERE id = %s",
        (account_id,)
    )

    # Step 3: Write to cache with TTL
    r.setex(cache_key, BALANCE_TTL, json.dumps(balance))

    return balance  # cache MISS result

def update_account_balance(account_id: str, new_balance: float):
    # Step 1: Write to database first (source of truth)
    db.execute(
        "UPDATE accounts SET balance = %s WHERE id = %s",
        (new_balance, account_id)
    )

    # Step 2: Delete cache (don't update — avoids race conditions)
    r.delete(f"balance:{account_id}")
```

### Pattern 2: Write-Through

Write-through keeps the cache and database synchronized on every write. It prevents
cache misses but adds latency to writes.

```
Write Path:
  1. App writes to cache with TTL
  2. Cache write succeeds
  3. App writes to database
  4. Both succeed → consistent

Trade-off: 
  Every write hits both cache and DB.
  If DB write fails after cache write: cache has stale data until TTL expires.
  Better than cache-aside for write-heavy workloads with high read concurrency.
```

```go
// Go example — write-through for idempotency keys
// Payments must not be processed twice (idempotency guarantee)

func ProcessPayment(ctx context.Context, idempotencyKey string, payment Payment) (*Result, error) {
    cacheKey := fmt.Sprintf("idem:%s", idempotencyKey)

    // Step 1: Check if this payment was already processed
    existing, err := rdb.Get(ctx, cacheKey).Result()
    if err == nil {
        // Already processed — return cached result
        var result Result
        json.Unmarshal([]byte(existing), &result)
        return &result, nil
    }
    if err != redis.Nil {
        return nil, fmt.Errorf("cache check failed: %w", err)
    }

    // Step 2: Process the payment
    result, err := processPaymentInDB(ctx, payment)
    if err != nil {
        return nil, err
    }

    // Step 3: Write result to cache — 24h TTL for idempotency window
    resultJSON, _ := json.Marshal(result)
    rdb.Set(ctx, cacheKey, resultJSON, 24*time.Hour)

    // Note: for strict write-through, use a pipeline or Lua script
    // to make cache + DB writes atomic. See Exercise 3.

    return result, nil
}
```

### TTL Design for Financial Services

TTL decisions have direct business consequences:

| Data | Recommended TTL | Rationale |
|------|-----------------|-----------|
| Account balance | 30 seconds | Balance can change with any transaction; stale reads within 30s are acceptable for display, never for transaction authorization |
| Exchange rates | 60 seconds | Market rates change rapidly; UI can show slightly stale, but not for settlement |
| Idempotency keys | 24 hours | Matches industry standard idempotency window (e.g. Stripe) |
| Session tokens | Same as JWT expiry | Should expire together to avoid security gaps |
| Rate limit counters | 60 seconds (sliding window) | Match your rate limit window duration |
| Read-heavy reference data (account types, fee schedules) | 300 seconds | Low mutation rate; cache aggressively |
| Never cache | Raw payment transactions | Source of truth must always be the database |

---

## 4. Eviction Policies — Choosing the Right Strategy

### The Memory Pressure Problem

When Redis reaches its `maxmemory` limit, it must decide what to do with new writes.
The `maxmemory-policy` configuration controls this behavior. Getting it wrong can cause
data loss or application errors in ways that are hard to debug.

```bash
# Check current maxmemory and policy
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO memory | \
  grep -E "maxmemory|maxmemory_policy|used_memory_human"

# Output example:
# used_memory_human:3.82G
# maxmemory:4294967296          (4GB)
# maxmemory_policy:volatile-lru
```

### All Eight Eviction Policies

| Policy | What Gets Evicted | When to Use |
|--------|------------------|-------------|
| `noeviction` | Nothing — writes fail with OOM error | When you NEVER want data silently dropped; catch errors in app |
| `allkeys-lru` | Any key, least recently used | Pure cache; all keys are equally evictable |
| `allkeys-lfu` | Any key, least frequently used | Pure cache with access-frequency awareness (better than LRU for Zipf distributions) |
| `allkeys-random` | Any key, randomly | Pure cache, uniform access patterns |
| `volatile-lru` | Keys WITH a TTL, LRU order | Mixed: some permanent keys (no TTL) + cache keys (with TTL) |
| `volatile-lfu` | Keys WITH a TTL, LFU order | Same as volatile-lru but frequency-aware |
| `volatile-random` | Keys WITH a TTL, randomly | Mixed; simpler than volatile-lru |
| `volatile-ttl` | Keys WITH a TTL, soonest-to-expire first | Prefer evicting short-lived keys |

### Why allkeys-lru Is Wrong for This Lab

The payments platform stores two categories of data in Redis:

1. **Idempotency keys** (no TTL — must persist for 24h): If evicted, a duplicate payment could
   be processed. This is a financial integrity violation.
2. **Cache data** (with TTL — 30 seconds to 5 minutes): OK to evict; app falls back to DB.

With `allkeys-lru`, Redis can evict ANY key including idempotency keys when memory is full.
A sudden traffic spike could flush all idempotency keys and trigger double-charges.

**Correct policy for this lab: `volatile-lru`**

```
volatile-lru behavior:
  - Cache keys (with TTL) → eligible for eviction via LRU
  - Idempotency keys (no TTL) → NEVER evicted
  - If only no-TTL keys exist and memory is full → writes fail with OOM
    (this is the desired behavior — we want to catch this in monitoring)
```

### Setting the Eviction Policy

```bash
# Memorystore does not allow direct CONFIG SET for maxmemory-policy.
# You must set it via gcloud:
gcloud redis instances update gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --redis-config=maxmemory-policy=volatile-lru

# Verify
gcloud redis instances describe gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --format="value(redisConfigs)"
# Output: {'maxmemory-policy': 'volatile-lru'}
```

### Monitoring for Eviction Events

```bash
# Connect to Redis and check eviction stats
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO stats | \
  grep evicted_keys
# evicted_keys:0   ← good; any non-zero value means eviction is happening

# Check keyspace stats
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO keyspace
# db0:keys=18432,expires=16890,avg_ttl=28440
# keys=18432: total keys
# expires=16890: keys with TTL (these are cache keys — evictable)
# avg_ttl: average remaining TTL in ms

# Alert threshold: if evicted_keys increases by > 0/sec, investigate
# This can indicate memory undersizing or a TTL configuration problem
```

---

## 5. Redis Data Types and When to Use Them

### Choosing the Right Data Structure

Redis is often used as a simple key-value store, but its data structures unlock significant
performance improvements for specific patterns.

### String — The Default

```bash
# Simple key-value; use for single-value cache entries
SET balance:acc-001 "1250.00" EX 30
GET balance:acc-001

# Atomic increment for counters (rate limiting)
INCR ratelimit:payments:acc-001:2026062514    # hour bucket
EXPIRE ratelimit:payments:acc-001:2026062514 3600

# NX flag — set only if not exists (idempotency check)
SET idem:pay-uuid-001 '{"status":"COMPLETED","id":"pay-001"}' EX 86400 NX
# Returns OK on first write, nil on subsequent writes → safe idempotency
```

### Hash — Object Storage

```bash
# Store a structured object as a Hash (more memory-efficient than JSON string)
HSET payment:pay-001 \
  id "pay-001" \
  amount "500.00" \
  currency "GBP" \
  status "COMPLETED" \
  account_id "acc-001"
EXPIRE payment:pay-001 300

# Read a single field (more efficient than GET + JSON parse)
HGET payment:pay-001 status

# Read all fields
HGETALL payment:pay-001

# Atomic field update
HSET payment:pay-001 status "SETTLED"
```

### Sorted Set — Rate Limiting with Sliding Window

The Sorted Set (ZSET) is ideal for implementing a sliding window rate limiter:

```python
# Sliding window rate limit: max 100 payments per account per 60 seconds
def check_rate_limit(account_id: str) -> bool:
    key = f"ratelimit:payments:{account_id}"
    now_ms = int(time.time() * 1000)
    window_ms = 60 * 1000         # 60-second window
    limit = 100

    pipe = r.pipeline()
    pipe.zremrangebyscore(key, 0, now_ms - window_ms)   # remove old entries
    pipe.zadd(key, {str(now_ms): now_ms})                # add current request
    pipe.zcard(key)                                       # count in window
    pipe.expire(key, 120)                                 # expire after 2x window
    _, _, count, _ = pipe.execute()

    return count <= limit

# This is accurate to the millisecond and requires no cron cleanup.
# Sorted set members are scored by timestamp; ZREMRANGEBYSCORE removes
# entries older than the window boundary.
```

### List — Simple Message Queue / Work Queue

```bash
# Producer: push payment processing jobs
LPUSH payment:queue '{"payment_id":"pay-001","retry":0}'

# Consumer: blocking pop (waits up to 30s for a new job)
BRPOP payment:queue 30

# Check queue depth
LLEN payment:queue
```

### Pub/Sub — Real-Time Notifications

```python
# Subscribe to payment status updates
def watch_payment_updates():
    pubsub = r.pubsub()
    pubsub.subscribe('payment:updates')

    for message in pubsub.listen():
        if message['type'] == 'message':
            event = json.loads(message['data'])
            print(f"Payment {event['id']} → {event['status']}")

# Publish a status update from the payments service
r.publish('payment:updates', json.dumps({
    'id': 'pay-001',
    'status': 'SETTLED',
    'timestamp': '2026-06-25T14:23:00Z',
}))
```

---

## 6. Connection Pooling — Client Library Patterns

### Why Connection Pools Matter

Opening a new TCP connection to Redis takes ~1ms. At 1,000 requests/second, that's 1s
of pure connection overhead per second. Connection pools maintain open connections and
reuse them.

Memorystore STANDARD_HA has a default connection limit. Exceeding it causes new connections
to fail with `ERR max number of clients reached`.

```bash
# Check current connection count
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  INFO clients | grep connected_clients
# connected_clients:47

# Check max clients (Memorystore default for 1GB: ~65,000)
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  CONFIG GET maxclients
```

### go-redis Pool Configuration

```go
// main.go — Redis client initialization
import (
    "context"
    "crypto/tls"
    "github.com/redis/go-redis/v9"
)

func NewRedisClient(host, auth string) *redis.Client {
    return redis.NewClient(&redis.Options{
        Addr:     host + ":6379",
        Password: auth,

        // TLS for Memorystore in-transit encryption
        TLSConfig: &tls.Config{
            ServerName: host,
        },

        // Connection pool settings
        PoolSize:     10,              // max connections per pod replica
        MinIdleConns: 3,               // keep 3 connections warm
        PoolTimeout:  4 * time.Second, // wait up to 4s for a free connection
        DialTimeout:  5 * time.Second, // TCP connection timeout
        ReadTimeout:  3 * time.Second, // Redis command read timeout
        WriteTimeout: 3 * time.Second, // Redis command write timeout

        // Connection health check
        // go-redis v9 pings connections before use by default
        ConnMaxIdleTime: 5 * time.Minute,  // close idle connections after 5m
        ConnMaxLifetime: 30 * time.Minute, // recycle connections every 30m
    })
}

// Health check: verify Redis connectivity at startup
func checkRedis(ctx context.Context, rdb *redis.Client) error {
    ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
    defer cancel()
    return rdb.Ping(ctx).Err()
}
```

### redis-py Pool Configuration

```python
# Python — connection pool with retry
import redis
from redis.retry import Retry
from redis.backoff import ExponentialBackoff

pool = redis.ConnectionPool(
    host=REDIS_HOST,
    port=6379,
    password=REDIS_AUTH,
    ssl=True,
    ssl_ca_certs='/etc/redis-ca/ca.pem',
    max_connections=10,         # per pod replica
    socket_connect_timeout=5,   # seconds
    socket_timeout=3,           # seconds for read/write
    health_check_interval=30,   # seconds; checks idle connections
    decode_responses=True,
    retry=Retry(ExponentialBackoff(cap=3, base=0.1), 3),  # 3 retries
    retry_on_error=[redis.ConnectionError, redis.TimeoutError],
)

r = redis.Redis(connection_pool=pool)
```

### ioredis (Node.js) Pool Configuration

```javascript
// payments-api/src/redis.js
const Redis = require('ioredis');
const fs = require('fs');

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: 6379,
  password: process.env.REDIS_AUTH,

  // TLS
  tls: {
    ca: fs.readFileSync('/etc/redis-ca/ca.pem'),
    servername: process.env.REDIS_HOST,
  },

  // Connection pool (ioredis uses a single connection by default;
  // use Cluster or separate clients for multiple connections)
  connectTimeout: 5000,     // ms
  commandTimeout: 3000,     // ms
  retryStrategy(times) {
    if (times > 3) return null;  // stop retrying after 3 attempts
    return Math.min(times * 100, 1000);  // exponential backoff up to 1s
  },

  // Reconnect on command failures
  reconnectOnError(err) {
    return err.message.includes('READONLY');
  },
});

redis.on('error', (err) => {
  console.error('Redis error:', err);
});
```

### Pool Sizing Formula

```
max_connections_per_pod = (max_concurrent_requests_per_pod / avg_redis_calls_per_request)
                          × 1.5 safety factor

Example:
  max_concurrent_requests = 50 (Go runtime handles 50 concurrent HTTP requests)
  avg_redis_calls = 3 (1 idempotency check + 1 balance read + 1 rate limit check)
  safety factor = 1.5

  max_connections = (50 / 3) × 1.5 ≈ 25

Total connections across all pods:
  25 connections × 4 replicas = 100 total connections

This is well under Memorystore's ~65,000 connection limit for a 1GB instance.
```

---

## 7. Monitoring Redis — Memory, Hit Ratio, Keyspace

### Key Metrics to Watch

```bash
# Full INFO output — all Redis statistics
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO all

# The sections most relevant for operations:
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO memory
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO stats
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO clients
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO replication
```

### Cache Hit Ratio

```bash
# Calculate hit ratio from stats
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO stats | \
  grep -E "keyspace_hits|keyspace_misses"

# keyspace_hits:1823491
# keyspace_misses:45821

# Hit ratio = hits / (hits + misses) = 1823491 / 1869312 = 97.5%
# Target: > 95% for a well-tuned cache
# Below 80%: TTLs too short, wrong keys cached, or cold start
```

### Memory Fragmentation Ratio

```bash
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} INFO memory | \
  grep -E "used_memory_human|used_memory_rss_human|mem_fragmentation_ratio"

# used_memory_human: 2.45G          ← memory Redis is using for data
# used_memory_rss_human: 2.93G      ← memory the OS has allocated to Redis
# mem_fragmentation_ratio: 1.19     ← RSS / used; > 1 means fragmentation

# Fragmentation ratio interpretation:
# 1.0 - 1.5: Normal — some fragmentation is fine
# > 1.5:     High fragmentation — Redis is using much more OS memory than data needs
#             Fix: MEMORY PURGE (Redis 4+) or restart Redis
# < 1.0:     Memory swapping — Redis is using swap; CRITICAL, causes huge latency
#             Fix: increase Memorystore memory immediately
```

### Keyspace Notifications for Debugging

Keyspace notifications let you subscribe to events like key expiry, SET, DEL:

```bash
# Enable keyspace notifications (notify-keyspace-events)
# For Memorystore, use gcloud:
gcloud redis instances update gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --redis-config=notify-keyspace-events=KEA
# K = keyspace events, E = keyevent events, A = all commands

# Subscribe to all expired key events
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  PSUBSCRIBE '__keyevent@0__:expired'

# Subscribe to all SET commands (useful for debugging unexpected cache writes)
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  PSUBSCRIBE '__keyevent@0__:set'

# WARNING: keyspace notifications add CPU overhead.
# Use KEA only temporarily for debugging. In production use Kx (expiry only).
```

### Cloud Monitoring Dashboards

```bash
# Useful Monitoring queries for Memorystore

# Memory utilization (alert if > 80%)
# Metric: redis.googleapis.com/stats/memory/usage_ratio

# Cache hit ratio
# Metric: redis.googleapis.com/stats/keyspace_hits
# Metric: redis.googleapis.com/stats/keyspace_misses

# Connected clients
# Metric: redis.googleapis.com/clients/connected

# Evicted keys (alert if > 0)
# Metric: redis.googleapis.com/stats/evicted_keys

# Create an alert for eviction events
gcloud alpha monitoring policies create \
  --policy-from-file=- << 'EOF'
displayName: "Memorystore: Key Eviction Detected"
conditions:
  - displayName: "evicted_keys > 0"
    conditionThreshold:
      filter: 'metric.type="redis.googleapis.com/stats/evicted_keys" AND resource.type="redis_instance"'
      comparison: COMPARISON_GT
      thresholdValue: 0
      duration: 60s
      aggregations:
        - alignmentPeriod: 60s
          perSeriesAligner: ALIGN_RATE
notificationChannels:
  - projects/gke-labs/notificationChannels/CHANNEL_ID
EOF
```

---

## 8. Break-It & Fix-It Exercises

### Exercise 1: Fill Redis to Capacity and Observe Eviction

**Goal:** Observe volatile-lru eviction behavior under memory pressure.

```bash
# Step 1: Get current memory usage
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  INFO memory | grep used_memory_human

# Step 2: Write a large number of cache keys (with TTL — evictable)
# This script writes 100,000 keys with 60-second TTL
for i in $(seq 1 100000); do
  redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
    SET "cache:fill:${i}" "$(head -c 1024 /dev/urandom | base64)" \
    EX 60 > /dev/null
done

# Step 3: Also write some idempotency keys WITHOUT TTL
for i in $(seq 1 100); do
  redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
    SET "idem:payment:${i}" '{"status":"COMPLETED"}' > /dev/null
done

# Step 4: Check eviction stats
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  INFO stats | grep evicted_keys

# Step 5: Verify that idempotency keys (no TTL) were NOT evicted
for i in $(seq 1 100); do
  result=$(redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
    GET "idem:payment:${i}")
  if [ -z "$result" ]; then
    echo "ERROR: idempotency key ${i} was evicted!"
  fi
done
# Expected: no output (none evicted)

# Step 6: Cleanup
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  KEYS "cache:fill:*" | xargs redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} DEL
```

---

### Exercise 2: Connection Pool Exhaustion

**Goal:** Observe what happens when all pool connections are in use.

```bash
# Step 1: Simulate pool exhaustion by opening many blocking connections
# (In a test, this simulates many concurrent requests each holding a connection)

# Start 20 blocking connections (more than the pool size of 10)
for i in $(seq 1 20); do
  redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
    BLPOP nonexistent:queue 10 &
done

# Step 2: Check connected clients
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
  INFO clients | grep connected_clients
# connected_clients:21  ← your 20 blocking + 1 monitoring connection

# Step 3: In your application, observe connection pool timeout errors
# When pool is exhausted: "redis: connection pool timeout"
# This shows up in app logs as a 503 to API callers

# Step 4: Kill the background connections
kill %1 %2 %3 %4 %5 %6 %7 %8 %9 %10 %11 %12 %13 %14 %15 %16 %17 %18 %19 %20

# Step 5: What to fix:
# Option A: increase pool size (if Redis can handle more connections)
# Option B: reduce concurrent request handling in the app
# Option C: investigate slow Redis commands holding connections open
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} SLOWLOG GET 10
```

---

### Exercise 3: Wrong Eviction Policy — Data Loss Scenario

**Goal:** Understand what `allkeys-lru` does to idempotency keys.

```bash
# Step 1: Change eviction policy to allkeys-lru (DANGEROUS)
gcloud redis instances update gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --redis-config=maxmemory-policy=allkeys-lru

# Step 2: Write idempotency keys WITHOUT TTL (important — no TTL)
for i in $(seq 1 50); do
  redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
    SET "idem:payment:${i}" '{"status":"COMPLETED"}' > /dev/null
done

# Step 3: Fill memory with cache data (with TTL)
for i in $(seq 1 100000); do
  redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
    SET "cache:pressure:${i}" "$(head -c 512 /dev/urandom | base64)" \
    EX 60 > /dev/null
done

# Step 4: Check if idempotency keys survived
MISSING=0
for i in $(seq 1 50); do
  result=$(redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} \
    GET "idem:payment:${i}")
  if [ -z "$result" ]; then
    MISSING=$((MISSING + 1))
  fi
done
echo "Missing idempotency keys: $MISSING"
# With allkeys-lru: many or all may be evicted!

# Step 5: Fix — restore the correct policy
gcloud redis instances update gke-lab-redis-dev \
  --region=europe-west1 \
  --project=gke-labs \
  --redis-config=maxmemory-policy=volatile-lru

# Cleanup
redis-cli -h ${REDIS_HOST} -p 6379 -a ${REDIS_AUTH} FLUSHDB ASYNC
```

---

## 9. Interview Q&A

---

### Q1: Why can't GKE pods connect to Memorystore without any special proxy or tunnel?

**Answer:**

GKE pods can connect directly to Memorystore's private IP because both resources are in the
same VPC via Private Service Access. The pod's IP is in the cluster's Pod CIDR
(which is a subnet of your VPC), and the Memorystore instance has a private IP in a
peered address range within the same VPC.

There's no NAT, no internet gateway, and no proxy required — it's a direct Layer 3 path
from pod to Redis. This is fundamentally different from Cloud SQL, which requires the Auth
Proxy because Cloud SQL's authentication uses Google's IAM API (not just a network connection).

The requirements to make it work: PSA must be configured (which the Terraform module handles),
and the pod's service account must be able to retrieve the AUTH token (via Secret Manager or ESO).

---

### Q2: You see `mem_fragmentation_ratio: 2.3` in Redis INFO. What does this mean and what do you do?

**Answer:**

A fragmentation ratio of 2.3 means Redis has allocated 2.3× more OS memory (RSS) than it
is actually using for data. This typically happens when:
1. Many keys were deleted or expired, leaving gaps in the allocator's memory pages
2. The workload has highly variable key sizes, causing allocator fragmentation
3. `CONFIG SET maxmemory` was set below current usage, causing forced evictions with fragmented leftovers

**Immediate diagnosis:**
```bash
redis-cli INFO memory | grep -E "used_memory|mem_fragmentation|allocator"
```

**Short-term fix:**
```bash
redis-cli MEMORY PURGE
# Available in Redis 4+; asks the allocator to release fragmented memory back to the OS
```

**Long-term fix:**
- Enable `activedefrag yes` in Redis config (online defragmentation, ~10% CPU overhead)
- For Memorystore: file a support request or perform a maintenance-window restart
- Review your key size distribution; very variable sizes (10B to 10MB) worsen fragmentation

At 2.3×, you're wasting 57% of your allocated instance memory. Consider the effective
available memory to be only `total_memory / fragmentation_ratio` for capacity planning.

---

### Q3: What is the difference between BASIC and STANDARD_HA tier in Memorystore?

**Answer:**

**BASIC tier:**
- Single Redis node, no replica
- If the node fails, all data is lost and Redis is unavailable until it restarts
- ~30-60 second recovery time on node failure (Redis restarts on a new VM)
- No persistence — all data lost on restart
- Lower cost (~50% of STANDARD_HA)
- Appropriate for: development, non-critical caching where data loss is acceptable

**STANDARD_HA tier:**
- Primary node + replica node in a different zone
- Automatic failover: if the primary fails, the replica is promoted in < 1 second
  (typically 200-500ms, nearly imperceptible to applications)
- No persistence — data is replicated in-memory only, not to disk
- ~2× cost of BASIC
- SLA: 99.9% monthly uptime
- Appropriate for: any production cache where availability matters

**Key caveat:** Neither tier persists data to disk. A Redis restart (for maintenance,
upgrade, or failover) causes the new instance to start empty. Design your application
to handle a cold cache gracefully — the cache-aside pattern handles this naturally
(fallback to database on miss).

---

### Q4: How do you implement a rate limiter in Redis that is immune to race conditions?

**Answer:**

The naive implementation — GET the counter, increment locally, SET it back — has a race
condition: two pods can GET the same value simultaneously and both think they're under the limit.

The correct patterns:

**Pattern 1: INCR with EXPIRE (simple, approximate)**
```python
def is_rate_limited(key: str, limit: int, window_sec: int) -> bool:
    pipe = r.pipeline()
    pipe.incr(key)
    pipe.expire(key, window_sec)
    count, _ = pipe.execute()
    return count > limit
# Limitation: INCR and EXPIRE are not atomic together.
# If the process crashes after INCR but before EXPIRE, the key never expires.
# Fix: use SET with NX and EX flags on first creation.
```

**Pattern 2: Sorted Set sliding window (precise, more memory)**
```python
# As shown in Section 5 — ZADD/ZREMRANGEBYSCORE in a pipeline
# This is atomic (pipeline executes as a sequence) and gives millisecond precision
```

**Pattern 3: Lua script (true atomicity)**
```lua
-- Executed atomically on the Redis server
local current = redis.call('INCR', KEYS[1])
if current == 1 then
  redis.call('EXPIRE', KEYS[1], ARGV[1])
end
if current > tonumber(ARGV[2]) then
  return 0
end
return 1
```

For a payments platform, the sorted set sliding window is preferred: it prevents
burst attacks (a client can't send 100 requests in the first millisecond of a fixed window),
is accurate to the millisecond, and the Lua script or pipeline execution makes it race-free.

---

### Q5: A developer suggests using Redis as the primary store for payment transactions to avoid database latency. How do you respond?

**Answer:**

This is a well-intentioned but dangerous idea. Redis should never be the primary store for
financial transaction data. Here is why:

**No durability guarantees:**
Memorystore has no persistence. A Redis restart — for maintenance, node failure, or upgrade —
loses all data. A payment recorded only in Redis is silently lost.

**No ACID transactions:**
Redis has MULTI/EXEC (optimistic locking), but it does not provide the serializable isolation
that financial transactions require. Two concurrent debit operations can both succeed even
if the account balance is insufficient.

**Audit trail requirements:**
PCI-DSS and FCA regulations require an immutable, auditable record of every transaction.
Redis has no write-ahead log or audit trail. You cannot reconstruct what happened after
a failure.

**The correct architecture:**
```
1. PostgreSQL (Cloud SQL): source of truth for all transactions
   ─ ACID, PITR, audit logs, foreign keys, constraints
2. Redis (Memorystore): cache layer for read-heavy queries
   ─ Account balance cache (30s TTL)
   ─ Idempotency keys (24h TTL, deduplication only)
   ─ Rate limiting counters
   ─ Session/token cache
3. Never: use Redis as the authoritative store for any financial data
```

The right response is: "Redis is a cache and coordination layer, not a database. The
transaction must be written to PostgreSQL first, then the cache can be updated."
