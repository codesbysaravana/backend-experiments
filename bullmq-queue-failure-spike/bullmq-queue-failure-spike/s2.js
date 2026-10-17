/**
 * Scenario 2 Harness: Redis Persistence & Process Crash Recovery.
 *
 * Evaluates job loss when the Redis server process is killed with SIGKILL
 * across different persistence strategies and kill timings:
 * - AOF everysec (fsync once per second)
 * - AOF always (fsync on every write)
 * - RDB default save schedule (3600 1, 300 100, 60 10000)
 * - No persistence (pure in-memory)
 *
 * Timings tested:
 * - delay 0ms: Redis killed immediately after enqueuing 200 jobs
 * - delay 2000ms: Redis killed 2 seconds after enqueuing
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
  RS,
} = require('./common');

const PERSISTENCE_CONFIGS = {
  aof_everysec: ['--appendonly', 'yes', '--appendfsync', 'everysec'],
  aof_always: ['--appendonly', 'yes', '--appendfsync', 'always'],
  rdb_default_save: ['--save', '3600 1 300 100 60 10000'],
  no_persistence: [],
};

const TOTAL_JOBS = 200;
const DELAYS_MS = [0, 2000];
const TRIALS_PER_CONFIG = 5;

/**
 * Restart an existing Redis directory without wiping its contents.
 * @param {number} port - Redis listening port.
 * @param {string} redisDir - Existing Redis working directory.
 * @param {string} configName - Persistence configuration name.
 * @param {string[]} originalArgs - Original startup arguments.
 * @returns {import('child_process').ChildProcess}
 */
const restartRedisExisting = (port, redisDir, configName, originalArgs) => {
  const isAof = originalArgs.includes('yes');
  const restartArgs = [
    '--port', String(port),
    '--dir', redisDir,
    '--daemonize', 'no',
    '--save', '',
    '--appendonly', isAof ? 'yes' : 'no',
  ];

  if (originalArgs.includes('--appendfsync')) {
    const fsyncIndex = originalArgs.indexOf('--appendfsync');
    restartArgs.push('--appendfsync', originalArgs[fsyncIndex + 1]);
  }

  if (configName === 'rdb_default_save') {
    restartArgs.push('--save', '3600 1 300 100 60 10000');
  }

  return spawn(RS, restartArgs, { stdio: 'ignore' });
};

// Runner
(async () => {
  const allResults = [];
  let testCounter = 0;

  for (const [configName, extraArgs] of Object.entries(PERSISTENCE_CONFIGS)) {
    for (const delayMs of DELAYS_MS) {
      for (let trial = 1; trial <= TRIALS_PER_CONFIG; trial += 1) {
        testCounter += 1;
        const port = 6500 + (testCounter % 50);
        const trialDir = path.join(OUT, `s2_${configName}_${delayMs}_${trial}`);
        const redisDir = path.join(trialDir, 'redis');

        try {
          // 1. Initial Redis start with clean directory
          let redisProcess = await startRedis(port, redisDir, extraArgs);
          const queue = new Queue('q', { connection: conn(port) });

          // 2. Enqueue batch of jobs
          for (let i = 0; i < TOTAL_JOBS; i += 1) {
            await queue.add('job', { i }, { jobId: `j${i}` });
          }

          const beforeKillCounts = await queue.getJobCounts('waiting');

          // 3. Wait configured delay and crash Redis abruptly
          await sleep(delayMs);
          redisProcess.kill('SIGKILL');
          await sleep(300);
          await queue.close();

          // 4. Restart Redis using the existing disk state
          redisProcess = restartRedisExisting(port, redisDir, configName, extraArgs);

          // 5. Connect and inspect surviving jobs
          let reconnectedQueue;
          let afterRestartCounts = { waiting: 0 };

          for (let attempt = 0; attempt < 100; attempt += 1) {
            try {
              reconnectedQueue = new Queue('q', { connection: conn(port) });
              afterRestartCounts = await reconnectedQueue.getJobCounts('waiting');
              break;
            } catch {
              await sleep(100);
            }
          }

          const result = {
            config: configName,
            kill_after_ms: delayMs,
            trial,
            enqueued: TOTAL_JOBS,
            waiting_before_kill: beforeKillCounts.waiting,
            waiting_after_restart: afterRestartCounts.waiting,
            lost: TOTAL_JOBS - afterRestartCounts.waiting,
          };

          allResults.push(result);
          console.log(JSON.stringify(result));

          // Cleanup
          if (reconnectedQueue) {
            await reconnectedQueue.close();
          }
          redisProcess.kill('SIGKILL');
          await sleep(200);
        } catch (err) {
          console.error('HARNESS_FAIL', configName, delayMs, trial, err.message);
          allResults.push({
            config: configName,
            kill_after_ms: delayMs,
            trial,
            harness_failure: err.message,
          });
        }

        fs.writeFileSync(
          path.join(OUT, 's2.json'),
          JSON.stringify(allResults, null, 2),
        );
      }
    }
  }

  process.exit(0);
})();
