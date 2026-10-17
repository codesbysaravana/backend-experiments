/**
 * Scenario 2b Harness: Explicit RDB Snapshot Baselines.
 *
 * Separates "RDB persistence configured" from "a snapshot file actually exists on disk".
 *
 * Configurations tested:
 * - SAVE after all 200 jobs enqueued (expected 0 lost)
 * - SAVE after first 100 jobs enqueued (expected 100 lost)
 * - No SAVE triggered (expected all 200 lost because default schedule hasn't elapsed)
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

const TOTAL_JOBS = 200;
const RDB_RULES = ['--save', '3600 1 300 100 60 10000'];

const CONFIGS = [
  ['rdb_default_save_SAVE_after_all_200', 200],
  ['rdb_default_save_SAVE_after_first_100', 100],
  ['rdb_default_save_no_SAVE', 0],
];

/**
 * Extract a key's value from Redis INFO persistence output.
 * @param {string} infoString - Raw INFO output.
 * @param {string} key - Field key to lookup.
 * @returns {string|null}
 */
const getPersistenceInfo = (infoString, key) => {
  const match = infoString.match(new RegExp(`${key}:(\\S+)`));
  return match ? match[1] : null;
};

// Runner
(async () => {
  const allResults = [];

  for (const [configName, snapshotAfterJob] of CONFIGS) {
    for (let trial = 1; trial <= 5; trial += 1) {
      const port = 6700 + trial;
      const trialDir = path.join(OUT, `s2b_${configName}_${trial}`);
      const redisDir = path.join(trialDir, 'redis');

      try {
        let redisProcess = await startRedis(port, redisDir, RDB_RULES);
        const queue = new Queue('q', { connection: conn(port) });
        const redisClient = conn(port);

        // Enqueue jobs, triggering synchronous SAVE at the configured threshold
        for (let i = 0; i < TOTAL_JOBS; i += 1) {
          await queue.add('job', { i }, { jobId: `j${i}` });
          if (snapshotAfterJob && (i + 1) === snapshotAfterJob) {
            await redisClient.save();
          }
        }

        // Capture snapshot metadata before killing
        const info = await redisClient.info('persistence');
        const dumpPath = path.join(redisDir, 'dump.rdb');
        const metadata = {
          rdb_last_save_time_unix: getPersistenceInfo(info, 'rdb_last_save_time'),
          rdb_changes_since_last_save: getPersistenceInfo(info, 'rdb_changes_since_last_save'),
          rdb_last_bgsave_status: getPersistenceInfo(info, 'rdb_last_bgsave_status'),
          rdb_file_exists_before_kill: fs.existsSync(dumpPath),
        };

        // Crash Redis
        redisProcess.kill('SIGKILL');
        await sleep(300);
        await queue.close();
        redisClient.disconnect();

        // Restart Redis using existing disk directory
        redisProcess = spawn(
          RS,
          [
            '--port', String(port),
            '--dir', redisDir,
            '--daemonize', 'no',
            '--appendonly', 'no',
            ...RDB_RULES,
          ],
          { stdio: 'ignore' },
        );

        // Reconnect and inspect recovered job counts
        let reconnectedQueue;
        let afterCounts = { waiting: 0 };
        for (let attempt = 0; attempt < 100; attempt += 1) {
          try {
            reconnectedQueue = new Queue('q', { connection: conn(port) });
            afterCounts = await reconnectedQueue.getJobCounts('waiting');
            break;
          } catch {
            await sleep(100);
          }
        }

        const result = {
          config: configName,
          trial,
          enqueued: TOTAL_JOBS,
          ...metadata,
          waiting_after_restart: afterCounts.waiting,
          lost: TOTAL_JOBS - afterCounts.waiting,
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
        console.error('HARNESS_FAIL', configName, trial, err.message);
        allResults.push({
          config: configName,
          trial,
          harness_failure: err.message,
        });
      }

      fs.writeFileSync(
        path.join(OUT, 's2b.json'),
        JSON.stringify(allResults, null, 2),
      );
    }
  }

  process.exit(0);
})();
