# BullMQ Queue Failure Spike

Controlled, reproducible benchmarks testing BullMQ behavior under worker crashes (`SIGKILL`), event loop starvation (CPU-bound busy-wait), Redis process crashes across persistence modes (AOF vs RDB vs none), and idempotency guard race conditions.

---

## Prerequisites

1. **Node.js**: v18.0.0+ (Tested with Node v22.23 and Node v24.15).
2. **Redis Server**: Redis 7.x (`redis-server` binary).
   - **Linux / WSL (Ubuntu/Debian)**:
     ```bash
     sudo apt update && sudo apt install -y redis-server
     ```
   - **macOS**:
     ```bash
     brew install redis
     ```
   - **From Source**:
     ```bash
     curl -O https://download.redis.io/releases/redis-7.2.4.tar.gz
     tar -xzf redis-7.2.4.tar.gz
     cd redis-7.2.4 && make
     export SPIKE_REDIS_BIN="$(pwd)/src/redis-server"
     ```

---

## Installation & Linting

Navigate to this directory:
```bash
cd bullmq-queue-failure-spike/bullmq-queue-failure-spike
```

Install dependencies:
```bash
npm ci
```

Verify code linting & formatting:
```bash
npm run lint
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SPIKE_REDIS_BIN` | `redis-server` | Path or command name for the `redis-server` executable. |
| `SPIKE_OUT` | `./out` | Directory for Redis temporary data, trial logs, and result JSONs. |
| `ONLY_D` | `unset` | Set to `1` when running `s1.js` to run only Scenario D (blocked event loop). |

---

## Step-by-Step Execution Guide

### 1. Scenario 1: Worker Crashes & Stalled Job Detection
Evaluates what happens when a worker is killed mid-flight (`SIGKILL`) or when the event loop blocks:
- **Variant A**: No guard, `maxStalledCount: 1` (results in duplicate execution).
- **Variant B**: SADD guard, `maxStalledCount: 1` (prevents duplicate execution if crash occurs after effect).
- **Variant C**: No guard, `maxStalledCount: 0` (immediately fails the stalled job instead of retrying).
- **Variant D**: Event loop synchronously blocked for 6s (lock is 3s), causing BullMQ to re-assign the job to a second worker while worker 1 is still processing.

```bash
# Run all Scenario 1 variants (5 trials each)
npm run scenario:1

# Or run only Variant D (Event Loop Blocking)
npm run scenario:1:d-only
```
*Output*: Results saved to `out/s1.json`, with detailed worker logs in `out/<variant>_<trial>/`.

---

### 2. Scenario 2: Redis Process Crash & Persistence Recovery
Evaluates job loss when the Redis process crashes (`SIGKILL`) while jobs are waiting in the queue:
- **AOF `everysec`**: Fsync every second (0 jobs lost if killed after 2s).
- **AOF `always`**: Fsync per command (0 jobs lost).
- **RDB default save**: Save rules `3600 1 300 100 60 10000` (all 200 jobs lost because rule threshold was not hit).
- **No persistence**: Pure in-memory (all 200 jobs lost).

```bash
npm run scenario:2
```
*Output*: Results saved to `out/s2.json`.

---

### 3. Scenario 2b: Explicit RDB Snapshot Baselines
Separates "persistence configured" from "a snapshot file actually exists":
- Tests explicit `SAVE` after all 200 jobs, after 100 jobs, or no manual `SAVE`.

```bash
npm run scenario:2b
```
*Output*: Results saved to `out/s2b.json`.

---

### 4. Scenario 3: Guard Race Conditions & Atomicity
Exposes the critical flaw of non-atomic idempotency guards:
- **Variant E (Non-atomic guard)**: Worker writes `SADD` guard, then crashes before executing the side effect. BullMQ retries the job, but the guard blocks it. **Result: Job marked as `completed`, but side effect never happened (silent loss!).**
- **Variant F (Atomic Lua guard + effect)**: Guard and effect are executed in a single atomic Redis Lua script. Exactly-once side effect execution guaranteed.

```bash
npm run scenario:3
```
*Output*: Results saved to `out/s3.json`.

---

### 5. Live Observability Dashboard (Prometheus + Grafana)

The spike provides an orchestrator-level Prometheus exporter on port `9101` where metrics are derived from durable logs and Redis state (so worker kills never wipe metrics).

#### Step 1: Start the Exporter & Scenario Runner
```bash
npm run observability
```
This serves Prometheus metrics on `http://localhost:9101/metrics`.

#### Step 2: Start Prometheus
```bash
prometheus --config.file=observability/prometheus.yml --web.listen-address=:9190
```

#### Step 3: Start Grafana
```bash
grafana server --config observability/grafana.ini
```
Open Grafana at `http://localhost:3300`, and import the dashboard from `observability/grafana-dashboards/spike.json`. A reference screenshot of the resulting metrics dashboard is available at `results/dashboard.png`.

---

## File Structure

```
bullmq-queue-failure-spike/
├── common.js              # Redis lifecycle manager (start, stop, ping probe) & sleep helper
├── worker.js              # BullMQ worker process supporting crash, block, guardwin, and txn modes
├── s1.js                  # Scenario 1 runner: Worker crash & stalled detection (A-D)
├── s2.js                  # Scenario 2 runner: Redis persistence & restart (AOF/RDB)
├── s2b.js                 # Scenario 2b runner: Explicit RDB snapshot baseline
├── s3.js                  # Scenario 3 runner: Non-atomic vs Atomic Lua guards (E, F)
├── obs.js                 # Prometheus metrics exporter (:9101) & live trial runner
├── eslint.config.js       # ESLint flat configuration (zero errors/warnings)
├── package.json           # Dependencies and scenario execution scripts
├── results/
│   ├── results.md         # Full findings, raw data tables, and architectural insights
│   └── dashboard.png      # Screenshot of the live Grafana dashboard
└── observability/
    ├── prometheus.yml     # Prometheus scrape configuration (1s scrape interval)
    ├── grafana.ini        # Grafana server configuration
    └── grafana-dashboards/
        └── spike.json     # Grafana dashboard definition
```
