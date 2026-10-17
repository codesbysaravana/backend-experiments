/**
 * Live Observability Exporter & Scenario Orchestrator.
 *
 * Exposes Prometheus metrics on port 9101 derived directly from durable evidence
 * (durable log files and Redis state) so metrics survive worker SIGKILLs.
 *
 * Runs 4 live scenario variants for visualization on the Grafana dashboard:
 * 1. A_no_guard: Standard worker killed mid-flight (duplicate execution)
 * 2. C_maxStalled0: maxStalledCount=0 (immediate visible failure, no duplicate)
 * 3. E_nonatomic_guard: Crash in between SADD guard and effect (silent loss)
 * 4. F_atomic_guard_and_effect: Atomic Redis Lua script (guaranteed exactly-once)
 */

const http = require('http');
const client = require('prom-client');
const { trial } = require('./s3');
const { sleep } = require('./common');

const EXPORTER_PORT = 9101;
const registry = new client.Registry();
const LABEL_NAMES = ['variant'];

/**
 * Factory helper for Prometheus gauges.
 * @param {string} name - Metric name.
 * @param {string} help - Metric description.
 * @returns {client.Gauge}
 */
const createGauge = (name, help) => new client.Gauge({
  name,
  help,
  labelNames: LABEL_NAMES,
  registers: [registry],
});

const metrics = {
  starts: createGauge(
    'spike_attempts_started',
    'Processor starts (attempts incl. re-runs), derived from start log',
  ),
  restarted: createGauge(
    'spike_jobs_started_more_than_once',
    'Jobs whose processor started more than once',
  ),
  dupEff: createGauge(
    'spike_jobs_with_duplicate_effect',
    'Jobs whose effect was written more than once',
  ),
  missing: createGauge(
    'spike_jobs_started_without_effect',
    'Jobs started but with no effect written (transient in-flight or lost)',
  ),
  completed: createGauge(
    'spike_jobs_completed',
    'BullMQ completed set size',
  ),
  failed: createGauge(
    'spike_jobs_failed',
    'BullMQ failed set size',
  ),
  pending: createGauge(
    'spike_jobs_waiting_or_active',
    'BullMQ waiting plus active job count',
  ),
  recovery: createGauge(
    'spike_recovery_seconds',
    'Seconds from worker kill until all jobs reach terminal state',
  ),
};

const killsCounter = new client.Counter({
  name: 'spike_worker_kills_total',
  help: 'Total SIGKILL signals sent to workers by the test harness',
  labelNames: LABEL_NAMES,
  registers: [registry],
});

// HTTP server for Prometheus scrape endpoint (/metrics)
const server = http.createServer(async (req, res) => {
  if (req.url === '/metrics' || req.url === '/') {
    res.setHeader('Content-Type', registry.contentType);
    res.end(await registry.metrics());
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
});

server.listen(EXPORTER_PORT, () => {
  console.log(`Prometheus metrics exporter listening on http://localhost:${EXPORTER_PORT}/metrics`);
});

/**
 * Real-time event hook called by the trial runner during execution.
 * @param {object} event - State update or kill event.
 */
const metricsHook = (event) => {
  if (event.kill) {
    killsCounter.inc({ variant: event.variant });
    return;
  }

  const labels = { variant: event.variant };
  metrics.starts.set(labels, event.starts);
  metrics.restarted.set(labels, event.restarted);
  metrics.dupEff.set(labels, event.dupEff);
  metrics.missing.set(labels, event.missing);
  metrics.completed.set(labels, event.completed);
  metrics.failed.set(labels, event.failed);
  metrics.pending.set(labels, event.pending);

  if (event.recovery !== undefined) {
    metrics.recovery.set(labels, event.recovery);
  }
};

// Scenario execution loop
(async () => {
  console.log('Waiting 8 seconds for Prometheus scraper to establish initial baseline...');
  await sleep(8000);

  const testVariants = [
    ['A_no_guard', 1, '0', 'crash'],
    ['C_maxStalled0', 0, '0', 'crash'],
    ['E_nonatomic_guard', 1, '0', 'guardwin'],
    ['F_atomic_guard_and_effect', 1, '0', 'txn'],
  ];

  for (const [name, maxStalled, guard, mode] of testVariants) {
    console.log(`\n--- Running Observability Scenario: ${name} ---`);
    const result = await trial(name, maxStalled, guard, mode, 30, 1, metricsHook, 6800);
    console.log('Scenario Result:', JSON.stringify(result, null, 2));
    await sleep(5000);
  }

  console.log('\nAll scenarios completed. Exporter will remain active for dashboard inspection (25m timeout).');
  setTimeout(() => process.exit(0), 1500000);
})();
