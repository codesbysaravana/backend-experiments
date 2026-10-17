/**
 * Common utilities and Redis lifecycle helpers for BullMQ failure spike experiments.
 */

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const IORedis = require('ioredis');

// Path to redis-server binary and test output directory
const RS = process.env.SPIKE_REDIS_BIN || 'redis-server';
const OUT = process.env.SPIKE_OUT || path.join(__dirname, 'out');

// Ensure output directory exists
if (!fs.existsSync(OUT)) {
  fs.mkdirSync(OUT, { recursive: true });
}

/**
 * Pause execution for specified milliseconds.
 * @param {number} ms - Milliseconds to sleep.
 * @returns {Promise<void>}
 */
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Start an isolated Redis instance on a dedicated port and directory.
 * @param {number} port - Port to listen on.
 * @param {string} dir - Directory for Redis working files (RDB/AOF).
 * @param {string[]} extraArgs - Additional CLI arguments to pass to redis-server.
 * @returns {Promise<import('child_process').ChildProcess>} - Spawned Redis process.
 */
const startRedis = async (port, dir, extraArgs = []) => {
  // Wipe and recreate clean working directory
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });

  const defaultArgs = [
    '--port', String(port),
    '--dir', dir,
    '--daemonize', 'no',
    '--save', '',
    '--appendonly', 'no',
    ...extraArgs,
  ];

  const redisProcess = spawn(RS, defaultArgs, { stdio: 'ignore' });

  // Poll until Redis responds to PING (up to 10 seconds)
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const probe = new IORedis(port, {
        lazyConnect: true,
        maxRetriesPerRequest: 1,
      });
      await probe.connect();
      await probe.ping();
      probe.disconnect();
      return redisProcess;
    } catch {
      await sleep(100);
    }
  }

  redisProcess.kill('SIGKILL');
  throw new Error(`Failed to start Redis server on port ${port} using binary "${RS}"`);
};

/**
 * Create an ioredis client instance configured for BullMQ.
 * BullMQ requires maxRetriesPerRequest: null.
 * @param {number} port - Redis port.
 * @returns {IORedis}
 */
const conn = (port) => {
  const client = new IORedis(port, { maxRetriesPerRequest: null });
  // Suppress unhandled error logs when test harness deliberately sends SIGKILL to Redis
  client.on('error', () => {});
  return client;
};

module.exports = {
  OUT,
  RS,
  sleep,
  startRedis,
  conn,
};
