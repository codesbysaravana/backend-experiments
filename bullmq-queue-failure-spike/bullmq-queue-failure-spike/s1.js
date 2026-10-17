/**
 * Scenario 1 Harness: Worker Crashes & Stalled Job Detection.
 *
 * Evaluates BullMQ behavior under abrupt worker termination (SIGKILL)
 * and event loop starvation across four variants:
 * - A: No idempotency guard, maxStalledCount: 1 (Worker SIGKILL)
 * - B: SADD idempotency guard, maxStalledCount: 1 (Worker SIGKILL)
 * - C: No guard, maxStalledCount: 0 (Worker SIGKILL, immediate failure)
 * - D: Synchronously blocked event loop with 1 job (Starvation)
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
 * Count the number of unique items that appear more than once in an array.
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
 * Execute a single trial of a scenario variant.
 * @param {string} variantName - Name of the scenario variant.
 * @param {number} maxStalledCount - BullMQ maxStalledCount option.
 * @param {string} guardFlag - '1' for SADD guard, '0' otherwise.
 * @param {string} mode - 'crash' or 'block'.
 * @param {number} jobCount - Number of jobs to enqueue.
 * @param {number} trialIndex - Current trial number (1-5).
 * @returns {Promise<object>}
 */
async function runTrial(variantName, maxStalledCount, guardFlag, mode, jobCount, trialIndex) {
  const port = 6400 + trialIndex;
  const trialDir = path.join(OUT, `${variantName}_${trialIndex}`);
  const redisProcess = await startRedis(port, path.join(trialDir, 'redis'));

  const queue = new Queue('q', { connection: conn(port) });

  // Pre-populate queue with jobs
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

  let timeOfKill;
  const startTime = Date.now();
  const worker1 = spawnWorker();
  let worker2;

  const startsLog = path.join(trialDir, 'starts.log');
  const effectsLog = path.join(trialDir, 'effects.log');
  const eventsLog = path.join(trialDir, 'events.log');

  if (mode === 'block') {
    // For event loop blocking, start second worker after 1s so it can claim the stalled lock
    await sleep(1000);
    worker2 = spawnWorker();
  } else {
    // Wait until at least 5 jobs have started before killing worker 1
    while (readLines(startsLog).length < 5) {
      await sleep(50);
    }
    timeOfKill = Date.now();
    worker1.kill('SIGKILL');
    await sleep(500);
    worker2 = spawnWorker();
  }

  const benchmarkStart = timeOfKill || startTime;
  let finalState = { completed: 0, failed: 0, waiting: 0, active: 0 };

  // Poll until all jobs reach a terminal state (completed or failed)
  for (let attempt = 0; attempt < 1800; attempt += 1) {
    const counts = await queue.getJobCounts('completed', 'failed', 'waiting', 'active', 'delayed');
    finalState = counts;
    if (counts.completed + counts.failed === jobCount && counts.active === 0) {
      break;
    }
    await sleep(100);
  }

  if (mode === 'block') {
    // Allow blocked worker 1 to finish its synchronous busy-wait
    await sleep(5000);
  }

  const endTime = Date.now();
  const starts = readLines(startsLog);
  const effects = readLines(effectsLog);
  const events = readLines(eventsLog);

  const result = {
    variant: variantName,
    trial: trialIndex,
    jobs: jobCount,
    completed: finalState.completed,
    failed: finalState.failed,
    still_waiting_or_active: finalState.waiting + finalState.active,
    jobs_started_more_than_once: countDuplicates(starts),
    jobs_with_duplicate_effect: countDuplicates(effects),
    jobs_with_no_effect: jobCount - new Set(effects).size,
    seconds_to_all_terminal: Number(((endTime - benchmarkStart) / 1000).toFixed(1)),
    events: events.slice(0, 6).join(' | ').slice(0, 200),
  };

  // Teardown
  worker1.kill('SIGKILL');
  if (worker2) {
    worker2.kill('SIGKILL');
  }
  await queue.close();
  redisProcess.kill('SIGKILL');
  await sleep(300);

  return result;
}

// Runner
(async () => {
  const allResults = [];
  const variants = [];

  if (!process.env.ONLY_D) {
    variants.push(
      ['A_noguard_maxStalled1', 1, '0', 'crash', 30],
      ['B_guard_maxStalled1', 1, '1', 'crash', 30],
      ['C_noguard_maxStalled0', 0, '0', 'crash', 30],
    );
  }
  variants.push(['D_blocked_event_loop_1job', 1, '0', 'block', 1]);

  for (const [name, maxStalled, guard, mode, count] of variants) {
    for (let trial = 1; trial <= 5; trial += 1) {
      try {
        const result = await runTrial(name, maxStalled, guard, mode, count, trial);
        allResults.push(result);
        console.log(JSON.stringify(result));
        fs.writeFileSync(
          path.join(OUT, 's1.json'),
          JSON.stringify(allResults, null, 2),
        );
      } catch (err) {
        console.error('HARNESS_FAIL', name, trial, err.message);
        allResults.push({
          variant: name,
          trial,
          harness_failure: err.message,
        });
      }
    }
  }

  process.exit(0);
})();
