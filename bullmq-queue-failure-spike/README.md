# BullMQ Queue Failure Spike

Local, reproducible experiments that answer: **what actually happens to your jobs when a BullMQ worker crashes, the event loop blocks, or Redis restarts?**

Run in a local Linux test environment with Redis 7.2.4, Node 22, and BullMQ 6. Nothing deployed to production — all results are from controlled, repeatable harness runs.

---

## The Problem

Job queues promise "at-least-once" delivery. But what does that mean in practice?

- If a worker dies mid-job, does the side effect run **twice**?
- If the event loop blocks, does BullMQ re-run the job **while the first is still alive**?
- If Redis restarts, are enqueued jobs **gone**?
- Does "job completed" actually mean the **effect happened**?

This spike answers each of those with data.

---

## Scenarios & Results

### Worker Crash Variants (S1 / S3)

30 jobs, 2 workers (concurrency 5), worker 1 SIGKILL'd while 5 jobs are in-flight, worker 2 starts 500ms later.

| Variant | Description | Duplicates | Missing effects | Failed |
|---|---|---|---|---|
| **A** — No guard | Effect written at job start, then job waits 1.5s | **5 duplicate effects** | 0 | 0 |
| **B** — Redis SADD guard | Same as A, but checks a Redis SET before writing the effect | **0** | 0 | 0 |
| **C** — `maxStalledCount=0` | Stalled jobs are failed immediately, never retried | 0 | 0 | **5 failed** |
| **D** — Blocked event loop | Worker blocks for 6s (lock is 3s), no kill | **1 duplicate** | 0 | 0 |
| **E** — Non-atomic guard | Guard (SADD) set, then 1.5s wait, then effect — kill lands in the wait | 0 | **5 missing** | 0 |
| **F** — Atomic Lua guard+effect | Guard and effect in one Redis Lua script | **0** | **0** | 0 |

> **Key insight from E**: The job status says "completed", but the effect never happened. `completed ≠ done`.

> **Key insight from D**: No crash needed — a blocked event loop alone causes BullMQ to re-run a job while the original is still executing.

### Redis Persistence (S2 / S2b)

200 jobs enqueued, Redis SIGKILL'd, then restarted from the same data directory.

| Persistence config | Jobs lost |
|---|---|
| AOF `everysec` | **0 / 200** |
| AOF `always` | **0 / 200** |
| RDB default save rules (no manual SAVE) | **200 / 200** — total loss |
| RDB + explicit `SAVE` after all 200 enqueued | **0 / 200** |
| RDB + `SAVE` after first 100 only | **100 / 200** |
| No persistence | **200 / 200** — total loss |

> **Key insight**: "Persistence configured" ≠ "data snapshotted." RDB save rules (`3600 1 300 100 60 10000`) don't trigger for 200 fast writes — everything is lost.

---

## Observability Dashboard

`obs.js` exports Prometheus metrics from the orchestrator process (not the workers, so killing workers can't reset counters). A Grafana dashboard visualises:

- `spike_attempts_started` — processor starts including re-runs
- `spike_jobs_started_more_than_once` — jobs with duplicate starts
- `spike_jobs_with_duplicate_effect` — effects written more than once
- `spike_jobs_started_without_effect` — started but effect never written
- `spike_recovery_seconds` — time from kill to all jobs terminal

Screenshot: `results/dashboard.png`

---

## How to Run

### Prerequisites

- Linux (tested on Ubuntu)
- Node.js 22
- Redis 7.2.4 built from source: [download tarball](https://download.redis.io/releases/redis-7.2.4.tar.gz), then `make`

### Run experiments

```bash
export SPIKE_REDIS_BIN=/path/to/redis-server

cd bullmq-queue-failure-spike
npm ci

node s1.js          # Variants A, B, C, D (5 trials each)
node s2.js          # Redis persistence tests
node s2b.js         # RDB baseline (SAVE timing)
node s3.js          # Variants E, F (guard windows)

# Rerun just variant D:
ONLY_D=1 node s1.js
```

Results are written to `./out/` as JSON files.

### Run the dashboard (optional)

```bash
node obs.js         # Prometheus exporter on :9101
```

Requires Prometheus 3.15.0 and Grafana 11.2.0 Linux binaries. Ports: exporter 9101, Prometheus 9190, Grafana 3300. Config files are in `observability/`.

---

## File Map

```
bullmq-queue-failure-spike/
├── bullmq-queue-failure-spike/
│   ├── common.js              # Redis start/stop, connection factory, helpers
│   ├── worker.js              # Parameterised BullMQ worker (crash, block, guard, txn modes)
│   ├── s1.js                  # Scenarios A, B, C, D — crash + blocked event loop
│   ├── s2.js                  # Redis persistence: AOF vs RDB vs none
│   ├── s2b.js                 # RDB baseline: explicit SAVE timing experiments
│   ├── s3.js                  # Scenarios E, F — guard windows + atomic Lua
│   ├── obs.js                 # Prometheus exporter for live dashboard
│   ├── package.json           # bullmq 6.3.15, ioredis 6.0.0, prom-client 15.1.3
│   ├── observability/
│   │   ├── prometheus.yml
│   │   ├── grafana.ini
│   │   ├── d.yaml / ds.yaml   # Grafana provisioning
│   │   └── grafana-dashboards/
│   │       └── spike.json     # Full Grafana dashboard definition
│   └── results/
│       ├── results.md         # Full trial tables, caveats, definitions
│       ├── dashboard.png      # Dashboard screenshot
│       └── raw/               # Raw JSON from each run
└── extras/
    ├── BullMQ_spike_results_final.pdf
    ├── AWS_Builder_Center_article_draft_v3.txt
    └── LinkedIn_post_draft_v3.txt
```

---

## Caveats

- **Single machine.** Redis and workers are killed with SIGKILL (process kill). This is NOT a machine or power failure — OS page-cache buffers survive a process kill, so fsync-level AOF loss (up to 1s on power failure) is NOT tested.
- **5 trials per variant.** Counts were identical across trials; timings varied by ≤0.1s.
- **Variant F is Redis-only.** The atomic guard+effect only works because both are Redis operations. An external system (payment API, email, database) cannot be made atomic with a Redis guard — it needs the external system to honour an idempotency key.
- **Not tested**: Kafka, RabbitMQ, retries with backoff, Redis connection loss without restart, multi-node Redis.

Full caveats and raw data: [`results/results.md`](bullmq-queue-failure-spike/results/results.md)
