/**
 * BullMQ Worker process for failure spike scenarios.
 *
 * Simulates different execution modes:
 * - 'guardwin': Non-atomic guard test (SADD followed by sleep before writing effect).
 * - 'txn': Atomic Redis Lua transaction (SADD guard + RPUSH effect in one step).
 * - 'block': CPU-blocking event loop simulation (sync while loop blocks heartbeat).
 * - default: Standard worker with optional non-atomic SADD guard check.
 */

const { Worker } = require('bullmq');
const fs = require('fs');
const path = require('path');
const { conn, sleep } = require('./common');

const [
  portStr,
  queueName = 'q',
  lockDurationStr = '3000',
  stalledIntervalStr = '1000',
  maxStalledCountStr = '1',
  guardFlag = '0',
  logDir = '.',
  mode = 'default',
] = process.argv.slice(2);

const redisPort = Number(portStr);
const lockDuration = Number(lockDurationStr);
const stalledInterval = Number(stalledIntervalStr);
const maxStalledCount = Number(maxStalledCountStr);

// Log file paths
const startsLogPath = path.join(logDir, 'starts.log');
const effectsLogPath = path.join(logDir, 'effects.log');
const eventsLogPath = path.join(logDir, 'events.log');

// Redis client for external state and idempotency checks
const effectRedis = conn(redisPort);

/**
 * Append line safely to a specified log file.
 * @param {string} filePath - Path to destination file.
 * @param {string} content - Text content to append.
 */
const appendLog = (filePath, content) => {
  fs.appendFileSync(filePath, `${content}\n`);
};

// BullMQ Worker Processor
const worker = new Worker(
  queueName,
  async (job) => {
    // Record every attempt start to durable log
    appendLog(startsLogPath, job.id);

    // Mode: guardwin - Window between SADD guard and effect write (Scenario E)
    if (mode === 'guardwin') {
      const added = await effectRedis.sadd(`eff:${queueName}`, job.id);
      await sleep(1500); // Vulnerability window where worker may be killed
      if (added === 1) {
        appendLog(effectsLogPath, job.id);
      }
      await sleep(300);
      return 'ok';
    }

    // Mode: txn - Atomic Lua script ensuring effect and guard execute atomically (Scenario F)
    if (mode === 'txn') {
      const luaScript = `
        if redis.call('SADD', KEYS[1], ARGV[1]) == 1 then
          redis.call('RPUSH', KEYS[2], ARGV[1])
          return 1
        end
        return 0
      `;
      await effectRedis.eval(
        luaScript,
        2,
        `eff:${queueName}`,
        `effects:${queueName}`,
        job.id,
      );
      await sleep(1500);
      return 'ok';
    }

    // Mode: block - Synchronous CPU-bound blocking to trigger stall detection (Scenario D)
    if (mode === 'block') {
      if (job.attemptsStarted === 1) {
        // Block the Node.js event loop for 6 seconds (exceeds lockDuration)
        const deadline = Date.now() + 6000;
        while (Date.now() < deadline) {
          // Busy-wait to starve the event loop and prevent lock renewal
        }
        appendLog(effectsLogPath, job.id);
        return 'ok';
      }

      // Subsequent attempt
      appendLog(effectsLogPath, job.id);
      await sleep(200);
      return 'ok';
    }

    // Default mode: Standard processing with optional Redis SADD guard
    if (guardFlag === '1') {
      const added = await effectRedis.sadd(`eff:${queueName}`, job.id);
      if (added === 1) {
        appendLog(effectsLogPath, job.id);
      }
    } else {
      appendLog(effectsLogPath, job.id);
    }

    await sleep(1500);
    return 'ok';
  },
  {
    connection: conn(redisPort),
    concurrency: mode === 'block' ? 1 : 5,
    lockDuration,
    stalledInterval,
    maxStalledCount,
  },
);

// Worker Lifecycle & Stall Event Observers
worker.on('error', (err) => {
  appendLog(eventsLogPath, `error ${err.message}`);
});

worker.on('failed', (job, err) => {
  appendLog(eventsLogPath, `failed ${job ? job.id : 'unknown'} ${err.message}`);
});

worker.on('stalled', (jobId) => {
  appendLog(eventsLogPath, `stalled ${jobId}`);
});
