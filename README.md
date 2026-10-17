# Backend Experiments

A collection of hands-on backend engineering experiments, each exploring a specific failure mode, scaling challenge, or operational procedure. Every experiment was built from scratch, run locally or on AWS, and documented with raw results.

---

## Experiments

| # | Experiment | What it tests | Stack |
|---|---|---|---|
| 1 | [BullMQ Queue Failure Spike](#1-bullmq-queue-failure-spike) | Job queue behaviour under worker crashes, blocked event loops, and Redis restarts | Node.js, BullMQ, Redis, Prometheus, Grafana |
| 2 | [Netty Scaling](#2-netty-scaling) | Building a bare-metal HTTP server targeting 1M req/s | Java 21, Netty, Micrometer, Prometheus |
| 3 | [Postgres Disaster Recovery](#3-postgres-disaster-recovery) | Full backup, replication, and incident recovery for Postgres | Postgres 16, pgBackRest, S3, ELK Stack, Grafana |

---

## 1. BullMQ Queue Failure Spike

**Directory**: [`bullmq-queue-failure-spike/`](bullmq-queue-failure-spike/)

**Question**: What actually happens to your jobs when a BullMQ worker dies mid-flight, the event loop blocks, or Redis restarts?

### Why

Job queues promise "at-least-once" delivery, but the edge cases matter: duplicate side effects, silently lost work, and the gap between "job completed" and "effect actually happened." This experiment creates controlled failures and measures the real outcomes.

### Scenarios

| Variant | What happens | Key finding |
|---|---|---|
| **A** — No guard, `maxStalledCount=1` | Worker SIGKILL mid-job, replacement picks up stalled jobs | 5/30 jobs ran their side effect **twice** (duplicates) |
| **B** — Redis SADD guard | Same crash, but a Redis SET check before the effect | 0 duplicate effects — but see variant E |
| **C** — `maxStalledCount=0` | Stalled jobs are failed, never retried | 5/30 jobs **failed visibly**, 0 duplicates, 0 silent loss |
| **D** — Blocked event loop | Worker blocks for 6s (lock is 3s), no kill needed | BullMQ re-runs the job **while the first is still alive** — duplicate effect + `Missing lock` errors |
| **E** — Non-atomic guard (crash between guard and effect) | SADD guard succeeds, then worker dies before writing the effect | 5/30 jobs **completed with no effect** — "completed" ≠ "done" |
| **F** — Atomic guard + effect (Redis Lua) | Guard and effect in a single Lua script | 0 duplicates, 0 missing — but only works when the effect is in Redis itself |

### Redis Persistence Tests

| Config | Jobs lost after SIGKILL + restart |
|---|---|
| AOF `everysec` | **0 / 200** |
| AOF `always` | **0 / 200** |
| RDB (default save rules, no manual SAVE) | **200 / 200** — total loss |
| RDB + explicit `SAVE` after all 200 | **0 / 200** |
| No persistence | **200 / 200** — total loss |

> **Takeaway**: "Persistence configured" ≠ "data snapshotted." RDB save rules don't trigger fast enough for small batches — your data is gone if Redis dies before the first snapshot.

### Observability

A Prometheus exporter (`obs.js`) exposes live metrics during each scenario. A Grafana dashboard (`observability/grafana-dashboards/spike.json`) visualises attempts started, duplicate effects, missing effects, and recovery time in real time.

### How to run

```bash
# Prerequisites: Linux, Node 22, Redis 7.2.4 built from source
export SPIKE_REDIS_BIN=/path/to/redis-server

cd bullmq-queue-failure-spike/bullmq-queue-failure-spike
npm ci

# Run scenarios
node s1.js          # Variants A, B, C, D
node s2.js          # Redis persistence tests
node s2b.js         # RDB baseline tests
node s3.js          # Variants E, F (guard windows)

# Dashboard (optional)
node obs.js         # Prometheus exporter on :9101
```

### File map

```
bullmq-queue-failure-spike/
├── common.js          # Redis start/stop helpers, connection factory
├── worker.js          # Parameterised BullMQ worker (all modes)
├── s1.js              # Scenarios A, B, C, D (crash + blocked event loop)
├── s2.js              # Redis persistence: AOF vs RDB vs none
├── s2b.js             # RDB baseline: explicit SAVE timing
├── s3.js              # Scenarios E, F (guard window + atomic Lua)
├── obs.js             # Prometheus metrics exporter for live dashboard
├── observability/     # Grafana dashboards, Prometheus config
├── results/           # Raw JSON, result tables, dashboard screenshot
└── extras/            # Article drafts, PDF of results
```

---

## 2. Netty Scaling

**Directory**: [`nettyscaling/`](nettyscaling/)

**Question**: How do you build a bare-metal HTTP server in Java and push it toward 1M requests/second on AWS?

### Why

Frameworks like Spring Boot add layers of abstraction. This experiment strips everything away to understand the reactor pattern from the socket level up: boss groups, worker groups, event loops, channel pipelines, and how they map to actual CPU cores and TCP connections.

### What's built

A Netty 4 HTTP server with:

- **1 boss thread** accepting connections, **N worker threads** (one per CPU core) handling I/O
- An `HttpServerCodec` for decoding raw bytes into HTTP request objects
- A custom `HttpServerHandler` that serves responses and exposes a `/metrics` endpoint
- **Micrometer + Prometheus** integration — `http_requests_total` counter scraped every 5 seconds
- HTTP/1.1 keep-alive for connection reuse under load

### Architecture

```
Client (wrk) ──TCP──▶ Boss Group (1 thread, accepts connections)
                            │
                     ┌──────┴──────┐
                     ▼             ▼
              Worker Group    Worker Group   ... (N = CPU cores)
                │                   │
          ┌─────┴─────┐       ┌────┴─────┐
          ▼           ▼       ▼          ▼
    HttpServerCodec  Handler  HttpServerCodec  Handler
    (decode bytes)   (respond) (decode bytes)  (respond)
```

### AWS Benchmarking Setup

| Purpose | Instance | Count |
|---|---|---|
| Server (Netty app) | `c6i.4xlarge` (16 vCPU) | 2–3 |
| Load generator (wrk) | `c6i.2xlarge` (8 vCPU) | 1 |

- **Spot instances** for all (benchmark, not production)
- **NLB** (Network Load Balancer) — Layer 4, no HTTP overhead
- **Cluster Placement Group** — co-located instances, minimal latency
- Same VPC, same AZ — no cross-AZ latency or charges
- **Estimated cost**: ~$5–8 for a 4-hour session on spot pricing

### How to run

```bash
# Prerequisites: Java 21, Gradle
cd nettyscaling
./gradlew run          # Starts server on port 8000

# Load test (from a separate machine or WSL)
wrk -t4 -c100 -d10s http://localhost:8000

# Prometheus scraping
# prometheus.yml is preconfigured for :8000/metrics
```

### File map

```
nettyscaling/
├── app/
│   ├── build.gradle                           # Netty 4.1, Micrometer Prometheus
│   └── src/main/java/org/example/
│       ├── App.java                           # Server bootstrap, boss/worker groups
│       └── HttpServerHandler.java             # Request handler + /metrics endpoint
├── prometheus.yml                             # Scrape config for Netty + node_exporter
├── guide_lines.txt                            # Step-by-step AWS benchmarking checklist
└── justText.txt                               # Notes on Netty concepts and WSL networking
```

---

## 3. Postgres Disaster Recovery

**Directory**: [`recovery/`](recovery/)

**Question**: When your production Postgres goes down — a dropped table, a dead primary — can you actually recover? How fast? How much data do you lose?

### Why

Backups you've never restored aren't backups. This experiment builds the full disaster-recovery stack from scratch and simulates two real incidents to measure RTO (recovery time) and RPO (data loss).

### What's built

A complete production-grade Postgres setup:

- **Postgres 16** with data checksums, WAL archiving, and `pg_stat_statements`
- **pgBackRest** backing up to S3 (full + differential + WAL archiving, zstd compression)
- **Streaming replication** to a hot standby replica
- **Monitoring**: Prometheus + Grafana (TPS, replication lag, WAL archiving, query performance)
- **Log pipeline**: Filebeat → Elasticsearch → Kibana (query-level audit logs)
- **Load generator** (`load_generator.js`) continuously inserting users, orgs, and projects with Faker

### Schema

A 30+ table production-style schema covering:

| Section | Tables |
|---|---|
| **Users & Auth** | `users`, `user_sessions` |
| **Organizations** | `organizations`, `organization_members`, `teams`, `team_members` |
| **IAM (RBAC + ABAC)** | `roles`, `permissions`, `role_permissions`, `user_roles`, `team_roles`, `resource_grants`, `invitations` |
| **Deployment platform** | `projects`, `pipelines`, `builds`, `deployments`, `custom_domains`, `project_environment_variables`, `resources` |
| **Billing** | `plans`, `plan_features`, `subscriptions`, `subscription_changes`, `usage_records`, `credits`, `invoices`, `invoice_line_items`, `payment_methods`, `payments`, `webhook_events` |
| **Audit** | `audit_logs` (append-only) |

All tables use UUID primary keys, with proper FK constraints, check constraints, partial indexes, and a deferred circular FK (`projects.active_deployment_id → deployments.id`).

### Simulated Incidents

#### Incident A — Accidental `DROP TABLE`

1. Record the timestamp
2. `DROP TABLE deployments CASCADE;` on the live primary
3. Stop the load generator
4. **PITR restore** with pgBackRest to a separate instance (`--type=time --target=<timestamp>`)
5. Dump the recovered table, replay it into the live primary
6. Re-add the FK constraint
7. Verify: row counts, orphaned references, data integrity

**Metrics recorded**: detection time, RTO, RPO, failed requests during window.

#### Incident B — Primary Lost

Two recovery paths tested and compared:

| Path | Method |
|---|---|
| **Promote replica** | `pg_ctlcluster promote` → replica becomes the new primary |
| **Restore from S3** | Fresh instance → `pgbackrest restore` → start |

**Metrics recorded**: RTO, RPO, failed requests, operational complexity.

#### Bonus Tests

- **WAL replay time**: 10 min vs 60 min of load → how much longer is the restore?
- **Network partition**: `iptables` block between primary and replica → watch replication lag spike and catch up
- **Corruption detection**: `dd` corrupt bytes into a data file → data checksums catch it on read

### Monitoring & Alerts

| Dashboard | Panels |
|---|---|
| **Postgres Overview** | TPS, active connections, cache hit ratio, tuple ops |
| **WAL & Backups** | Archiving rate, failures, last backup age, WAL size |
| **Replication** | Lag (bytes + time), replica state |
| **Query Performance** | p50/p95/p99 from `pg_stat_statements` |
| **Incident** | RTO clock, failed request counter, row count comparison |

### How to run

```bash
# Prerequisites: Node.js, Docker, an AWS account

cd recovery

# 1. Start ELK stack locally
docker compose up -d

# 2. Load the schema into your Postgres instance
psql -h <HOST> -U postgres -d postgres -f schema.sql

# 3. Run the load generator
npm ci
node load_generator.js
```

Full setup instructions (EC2, pgBackRest, replication, monitoring) are in [`execution_plan.md`](recovery/execution_plan.md).

### File map

```
recovery/
├── schema.sql                         # Full 30+ table production schema (614 lines)
├── execution_plan.md                  # Step-by-step guide: infra → Postgres → pgBackRest → replica → monitoring → incidents
├── load_generator.js                  # Continuous INSERT load (users, orgs, projects) with Faker
├── docker-compose.yml                 # Elasticsearch + Kibana + Filebeat
├── filebeat.yml                       # Log shipper config (CloudWatch → Elasticsearch)
├── checksum.md                        # Notes on Postgres data checksums and pgBackRest
├── iso_logging_compliance_plan.md     # ISO 27001 logging architecture (Filebeat → ELK → S3 WORM)
├── logs_sending.txt                   # Working notes on RDS logging, Kibana setup, Client vs Pool
└── package.json                       # pg, @faker-js/faker
```

---

## Tech Stack Summary

| Layer | Tools used |
|---|---|
| **Languages** | Java 21, JavaScript (Node.js 22) |
| **Job queue** | BullMQ 6, Redis 7.2.4 |
| **Networking** | Netty 4.1, NIO event loops |
| **Database** | PostgreSQL 16, pgBackRest, streaming replication |
| **Observability** | Prometheus, Grafana, Micrometer, prom-client |
| **Logging** | Elasticsearch 8.10, Kibana 8.10, Filebeat 8.10 |
| **Infra** | AWS EC2 (spot), S3, NLB, Docker |
| **Load testing** | wrk, custom Node.js generators |

---

## Repo Structure

```
backend-experiments/
├── bullmq-queue-failure-spike/    # Experiment 1: BullMQ failure modes
├── nettyscaling/                  # Experiment 2: Netty high-throughput server
├── recovery/                      # Experiment 3: Postgres disaster recovery
└── README.md                      # This file
```

---

## License

These are personal learning experiments. Use them however you like.
