# bullmq-queue-failure-spike
Local, reproducible experiments on BullMQ behaviour under worker crash, blocked event loop, and Redis restart, with a Prometheus + Grafana dashboard. Read `results/results.md` first (caveats, definitions, raw tables). Run in a local Linux test environment, not on AWS and not run by Priyan personally; nothing deployed.

## Reproduce
1. Redis 7.2.4 built from source (https://download.redis.io/releases/redis-7.2.4.tar.gz); set the binary path in `common.js`.
2. `npm ci` (frozen by package-lock.json).
3. `node s1.js` (A-D), `node s2.js`, `node s2b.js`, `node s3.js` (E, F). `ONLY_D=1 node s1.js` reruns D.
4. Dashboard: `node obs.js` (exporter on :9101), Prometheus with `observability/prometheus.yml` (scrape 1s), Grafana 11.2 with `observability/grafana.ini` and the provisioning files plus `observability/grafana-dashboards/spike.json`. Screenshot: `results/dashboard.png`.

Note: ioredis `ECONNREFUSED` lines in logs come from the harness's Redis readiness probe and are benign.
Variant B is not an idempotency fix (see variant E). The first run of D is stale and superseded by the rerun (see results.md).

## Prerequisites and scripts
- Linux, Node 22, a Redis 7.2.4 `redis-server` binary: `export SPIKE_REDIS_BIN=/path/to/redis-server` (build: download the tarball above, `make`). Outputs go to `./out` (override with `SPIKE_OUT`).
- Dashboard run needs the Prometheus 3.15.0 and Grafana 11.2.0 Linux binaries (https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-3.15.0.linux-amd64.tar.gz, https://dl.grafana.com/oss/release/grafana-11.2.0.linux-amd64.tar.gz). Ports: exporter 9101, Prometheus 9190, Grafana 3300. In `observability/` the paths in grafana.ini and d.yaml point at /tmp/obs; edit them to your own directories.
- Scenario settings are in `results/results.md` (Effective settings).
