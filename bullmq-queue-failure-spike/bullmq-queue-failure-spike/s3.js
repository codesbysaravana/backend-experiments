/**
 * Scenario 3 Harness: Guard Race Conditions & Atomicity.
 *
 * Compares two approaches to idempotency guards under worker crashes:
 * - Variant E (Non-atomic guard): Worker marks guard via SADD, but crashes before writing effect.
 *   Result: Guard succeeds, but effect was NEVER written (silent loss!).
 * - Variant F (Atomic Lua script): Guard and effect executed atomically in Redis Lua.
 *   Result: Guaranteed exactly-once side-effect execution.
 *
 * Exports:
 * - trial / runTrial: Reusable trial runner with optional real-time metrics hook (used by obs.js).
 */

const { Queue } = require('bullmq');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const {
  startRedis,
  conn,
  sleep,
  OUT,
} = require('./common');

const LOCK_DURATION = 3000;
const STALLED_INTERVAL = 1000;

/**
 * Read non-empty lines from a text file.
 * @param {string} filePath - Path to file.
 * @returns {string[]}
 */
const readLines = (filePath) => {
  if (!fs.existsSync(filePath)) {
    return [];
  }
  return fs.readFileSync(filePath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
};

/**
 * Count duplicate occurrences in an array.
 * @param {string[]} array - List of items.
 * @returns {number}
 */
const countDuplicates = (array) => {
  const counts = {};
  array.forEach((item) => {
    counts[item] = (counts[item] || 0) + 1;
  });
  return Object.values(counts).filter((count) => count > 1).length;
};

/**
 * Execute a single trial with real-time metric reporting hook.
 * @param {string} name - Variant name.
 * @param {number} maxStalledCount - Max stalled count for BullMQ.
 * @param {string} guardFlag - Guard mode flag.
 * @param {string} mode - 'guardwin' or 'txn'.
 * @param {number} jobCount - Total jobs to enqueue.
 * @param {number} trialIndex - Trial index number.
 * @param {Function} [hook] - Optional observability callback for metric updates.
 * @param {number} [portBase=6600] - Base Redis port.
 * @returns {Promise<object>}
 */
async function trial(
  name,
  maxStalledCount,
  guardFlag,
  mode,
  jobCount,
  trialIndex,
  hook,
  portBase = 6600,
) {
  const port = portBase + trialIndex;
  const trialDir = path.join(OUT, `${name}_${trialIndex}`);
  const redisProcess = await startRedis(port, path.join(trialDir, 'redis'));

  const queue = new Queue('q', { connection: conn(port) });
  const redisClient = conn(port);

  // Pre-populate queue
  for (let i = 0; i < jobCount; i += 1) {
    await queue.add('job', { i }, { jobId: `j${i}` });
  }

  const spawnWorker = () => spawn(
    'node',
    [
      path.join(__dirname, 'worker.js'),
      String(port),
      'q',
      String(LOCK_DURATION),
      String(STALLED_INTERVAL),
      String(maxStalledCount),
      guardFlag,
      trialDir,
      mode,
    ],
    { stdio: 'ignore' },
  );

  const startsLog = path.join(trialDir, 'starts.log');
  const effectsLog = path.join(trialDir, 'effects.log');

  // Retrieve effects either from Redis list (for Lua txn) or file log
  const getEffects = async () => {
    if (mode === 'txn') {
      return redisClient.lrange('effects:q', 0, -1);
    }
    return readLines(effectsLog);
  };

  // Broadcast real-time metrics to Prometheus collector if hook is supplied
  const emitMetrics = async (extra = {}) => {
    if (!hook) {
      return;
    }
    const counts = await queue.getJobCounts('completed', 'failed', 'waiting', 'active');
    const starts = readLines(startsLog);
    const effects = await getEffects();

    hook({
      variant: name,
      jobs: jobCount,
      starts: starts.length,
      restarted: countDuplicates(starts),
      dupEff: countDuplicates(effects),
      missing: Math.max(0, starts.length ? new Set(starts).size - new Set(effects).size : 0),
      completed: counts.completed,
      failed: counts.failed,
      pending: counts.waiting + counts.active,
      ...extra,
    });
  };

  const worker1 = spawnWorker();
  let worker2;

  // Wait for at least 5 starts, then kill worker 1 mid-flight
  while (readLines(startsLog).length < 5) {
    await sleep(50);
  }

  const timeOfKill = Date.now();
  worker1.kill('SIGKILL');
  if (hook) {
    hook({ kill: 1, variant: name });
  }

  await sleep(500);
  worker2 = spawnWorker();

  let finalCounts = { completed: 0, failed: 0, waiting: 0, active: 0 };
  for (let attempt = 0; attempt < 1800; attempt += 1) {
    finalCounts = await queue.getJobCounts('completed', 'failed', 'waiting', 'active');
    await emitMetrics();
    if (finalCounts.completed + finalCounts.failed === jobCount && finalCounts.active === 0) {
      break;
    }
    await sleep(200);
  }

  const endTime = Date.now();
  const starts = readLines(startsLog);
  const effects = await getEffects();

  const result = {
    variant: name,
    trial: trialIndex,
    jobs: jobCount,
    completed: finalCounts.completed,
    failed: finalCounts.failed,
    still_waiting_or_active: finalCounts.waiting + finalCounts.active,
    jobs_started_more_than_once: countDuplicates(starts),
    jobs_with_duplicate_effect: countDuplicates(effects),
    jobs_with_no_effect: jobCount - new Set(effects).size,
    seconds_to_all_terminal: Number(((endTime - timeOfKill) / 1000).toFixed(1)),
  };

  await emitMetrics({ recovery: result.seconds_to_all_terminal });

  // Teardown
  worker1.kill('SIGKILL');
  if (worker2) {
    worker2.kill('SIGKILL');
  }
  await queue.close();
  redisClient.disconnect();
  redisProcess.kill('SIGKILL');
  await sleep(300);

  return result;
}

module.exports = {
  trial,
  runTrial: trial,
};

// Runner when executed directly
if (require.main === module) {
  (async () => {
    const allResults = [];
    const variants = [
      ['E_nonatomic_guard_crash_between_guard_and_effect', 1, '0', 'guardwin', 30],
      ['F_atomic_guard_plus_effect_in_redis_lua', 1, '0', 'txn', 30],
    ];

    for (const [name, maxStalled, guard, mode, count] of variants) {
      for (let trialIndex = 1; trialIndex <= 5; trialIndex += 1) {
        try {
          const result = await trial(name, maxStalled, guard, mode, count, trialIndex);
          allResults.push(result);
          console.log(JSON.stringify(result));
        } catch (err) {
          console.error('HARNESS_FAIL', name, trialIndex, err.message);
          allResults.push({
            variant: name,
            trial: trialIndex,
            harness_failure: err.message,
          });
        }
        fs.writeFileSync(
          path.join(OUT, 's3.json'),
          JSON.stringify(allResults, null, 2),
        );
      }
    }

    process.exit(0);
  })();
}
