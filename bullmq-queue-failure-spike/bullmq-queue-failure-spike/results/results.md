# Results: BullMQ queue failure spike (local Linux test environment)

Run in a local Linux test environment. Not AWS, and not run by Priyan personally. Pending his review. Nothing here is a cloud result.

## Versions (read from binaries / package metadata)
Redis 7.2.4 (built from source, `redis-server --version`), Node v22.23.3, bullmq 6.3.15, ioredis 6.0.0, prom-client 15.1.3 (see package-lock.json), Prometheus 3.15.0, Grafana 11.2.0.

## Caveats (read first)
- Single machine. Redis and workers are killed with SIGKILL (process kill). This is NOT a machine or power failure: OS page-cache buffers survive a process kill, so fsync-level loss (AOF everysec's up-to-1s window on power loss) is NOT tested.
- 5 trials per configuration (D: 5 trials of 1 job). Counts of re-runs, duplicates and missing effects were identical across trials; timings varied slightly (for example A 9.7 to 9.8 s). This is no variance or statistical claim.
- Not tested: Kafka, RabbitMQ, retries with backoff, Redis connection loss without restart, multi-node Redis.
- Variants A and E differ in WHEN the kill lands relative to the effect (A after, E before), so A vs E is not a controlled head-to-head. The Redis SADD guard before the effect (B/E) is NOT a reliable idempotency fix: see E. Variant F makes guard+effect atomic only because the "effect" is a write into the same Redis. An effect in an external system (payment, email, DB) cannot be made atomic with a Redis guard this way; it needs an idempotency key honoured by that system.
- maxStalledCount 0 (variant C) produces visible failed jobs, not silent loss.

## Effective settings
S1/S3: lockDuration 3000 ms, stalledInterval 1000 ms, maxStalledCount per variant (A,B,E,F: 1; C: 0), worker concurrency 5, 2 workers, SIGKILL of worker 1 while its 5 jobs are active, worker 2 started 500 ms later, job bodies wait 1.5 s as defined below. Redis for S1/S3: no persistence (`--save '' --appendonly no`). S2: `--save ''` plus AOF always / everysec / none, or RDB rules below.

## Trial definitions
- S1/S3 common: 30 jobs, 2 workers (concurrency 5), worker 1 SIGKILLed once 5 jobs have started (while they are in flight), worker 2 started 500 ms later. Every job start is appended to a start log. The "effect" is an append of the job id to a local effect-log file (variant F: a push to a Redis list, see below). Counts of duplicate and missing effects come from these logs.
- A: no guard, maxStalledCount 1. The effect is written at job start, then the job body waits 1.5 s before returning, so the kill lands after the effect was written. B: as A, but a Redis SADD guard is checked before the effect. C: as A with maxStalledCount 0.
- D: 1 job, worker 1 (concurrency 1) blocks its event loop for 6 s before writing the effect and returning; lockDuration 3 s, stalledInterval 1 s, maxStalledCount 1; second worker started 1 s later; no kill; the harness waits 5 s extra after terminal state.
- E: Redis SADD guard first, then a 1.5 s wait, then the effect-log append. The kill lands in that wait, between guard and effect, so the re-run finds the guard set and skips the effect. maxStalledCount 1.
- F: a Redis Lua script does the SADD guard and the push to a Redis list as one atomic step at job start, then the job waits 1.5 s. Kill timing as in A. maxStalledCount 1. This models an effect in the same Redis only.
- S2: 200 jobs enqueued, Redis SIGKILLed 0 ms or 2000 ms after the last enqueue and restarted with the same data dir; "lost" = 200 minus waiting jobs after restart.
- S2b (RDB baseline, save rules `3600 1 300 100 60 10000`): SAVE after all 200 / SAVE after first 100 / no SAVE.

## Raw trial table
| Scenario | Variant | Trial | jobs | completed | failed | started >1x | duplicate effects | started, no effect | s to terminal |
|---|---|---|---|---|---|---|---|---|---|
| S1 | A_noguard_maxStalled1 | 1 | 30 | 30 | 0 | 5 | 5 | 0 | 9.7 |
| S1 | A_noguard_maxStalled1 | 2 | 30 | 30 | 0 | 5 | 5 | 0 | 9.8 |
| S1 | A_noguard_maxStalled1 | 3 | 30 | 30 | 0 | 5 | 5 | 0 | 9.8 |
| S1 | A_noguard_maxStalled1 | 4 | 30 | 30 | 0 | 5 | 5 | 0 | 9.8 |
| S1 | A_noguard_maxStalled1 | 5 | 30 | 30 | 0 | 5 | 5 | 0 | 9.8 |
| S1 | B_guard_maxStalled1 | 1 | 30 | 30 | 0 | 5 | 0 | 0 | 9.8 |
| S1 | B_guard_maxStalled1 | 2 | 30 | 30 | 0 | 5 | 0 | 0 | 9.8 |
| S1 | B_guard_maxStalled1 | 3 | 30 | 30 | 0 | 5 | 0 | 0 | 9.8 |
| S1 | B_guard_maxStalled1 | 4 | 30 | 30 | 0 | 5 | 0 | 0 | 9.8 |
| S1 | B_guard_maxStalled1 | 5 | 30 | 30 | 0 | 5 | 0 | 0 | 9.8 |
| S1 | C_noguard_maxStalled0 | 1 | 30 | 25 | 5 | 0 | 0 | 0 | 8.3 |
| S1 | C_noguard_maxStalled0 | 2 | 30 | 25 | 5 | 0 | 0 | 0 | 8.3 |
| S1 | C_noguard_maxStalled0 | 3 | 30 | 25 | 5 | 0 | 0 | 0 | 8.3 |
| S1 | C_noguard_maxStalled0 | 4 | 30 | 25 | 5 | 0 | 0 | 0 | 8.3 |
| S1 | C_noguard_maxStalled0 | 5 | 30 | 25 | 5 | 0 | 0 | 0 | 8.3 |
| S1 (D rerun) | D_blocked_event_loop_1job | 1 | 1 | 1 | 0 | 1 | 1 | 0 | 8.5 |
| S1 (D rerun) | D_blocked_event_loop_1job | 2 | 1 | 1 | 0 | 1 | 1 | 0 | 8.5 |
| S1 (D rerun) | D_blocked_event_loop_1job | 3 | 1 | 1 | 0 | 1 | 1 | 0 | 8.5 |
| S1 (D rerun) | D_blocked_event_loop_1job | 4 | 1 | 1 | 0 | 1 | 1 | 0 | 8.4 |
| S1 (D rerun) | D_blocked_event_loop_1job | 5 | 1 | 1 | 0 | 1 | 1 | 0 | 8.4 |
| S3 | E_nonatomic_guard_crash_between_guard_and_effect | 1 | 30 | 30 | 0 | 5 | 0 | 5 | 11.6 |
| S3 | E_nonatomic_guard_crash_between_guard_and_effect | 2 | 30 | 30 | 0 | 5 | 0 | 5 | 11.6 |
| S3 | E_nonatomic_guard_crash_between_guard_and_effect | 3 | 30 | 30 | 0 | 5 | 0 | 5 | 11.6 |
| S3 | E_nonatomic_guard_crash_between_guard_and_effect | 4 | 30 | 30 | 0 | 5 | 0 | 5 | 11.6 |
| S3 | E_nonatomic_guard_crash_between_guard_and_effect | 5 | 30 | 30 | 0 | 5 | 0 | 5 | 11.6 |
| S3 | F_atomic_guard_plus_effect_in_redis_lua | 1 | 30 | 30 | 0 | 5 | 0 | 0 | 9.7 |
| S3 | F_atomic_guard_plus_effect_in_redis_lua | 2 | 30 | 30 | 0 | 5 | 0 | 0 | 9.8 |
| S3 | F_atomic_guard_plus_effect_in_redis_lua | 3 | 30 | 30 | 0 | 5 | 0 | 0 | 9.8 |
| S3 | F_atomic_guard_plus_effect_in_redis_lua | 4 | 30 | 30 | 0 | 5 | 0 | 0 | 9.7 |
| S3 | F_atomic_guard_plus_effect_in_redis_lua | 5 | 30 | 30 | 0 | 5 | 0 | 0 | 9.7 |

## Error and event strings (S1 D rerun; trial 1 shown, the same event types appeared in each trial, count of stalled lines may vary)

`stalled j0 | stalled j0 | error Missing lock for job j0. moveToFinished | error Missing lock for job j0. moveToFinished`

Stalled-job failures in C: `job stalled more than allowable limit` (5 of 30 jobs, all trials).

## Redis restart (S2, SIGKILL then restart)
| config | kill after ms | trial | enqueued | waiting after restart | lost |
|---|---|---|---|---|---|
| aof_everysec | 0 | 1 | 200 | 200 | 0 |
| aof_everysec | 0 | 2 | 200 | 200 | 0 |
| aof_everysec | 0 | 3 | 200 | 200 | 0 |
| aof_everysec | 0 | 4 | 200 | 200 | 0 |
| aof_everysec | 0 | 5 | 200 | 200 | 0 |
| aof_everysec | 2000 | 1 | 200 | 200 | 0 |
| aof_everysec | 2000 | 2 | 200 | 200 | 0 |
| aof_everysec | 2000 | 3 | 200 | 200 | 0 |
| aof_everysec | 2000 | 4 | 200 | 200 | 0 |
| aof_everysec | 2000 | 5 | 200 | 200 | 0 |
| aof_always | 0 | 1 | 200 | 200 | 0 |
| aof_always | 0 | 2 | 200 | 200 | 0 |
| aof_always | 0 | 3 | 200 | 200 | 0 |
| aof_always | 0 | 4 | 200 | 200 | 0 |
| aof_always | 0 | 5 | 200 | 200 | 0 |
| aof_always | 2000 | 1 | 200 | 200 | 0 |
| aof_always | 2000 | 2 | 200 | 200 | 0 |
| aof_always | 2000 | 3 | 200 | 200 | 0 |
| aof_always | 2000 | 4 | 200 | 200 | 0 |
| aof_always | 2000 | 5 | 200 | 200 | 0 |
| rdb_default_save | 0 | 1 | 200 | 0 | 200 |
| rdb_default_save | 0 | 2 | 200 | 0 | 200 |
| rdb_default_save | 0 | 3 | 200 | 0 | 200 |
| rdb_default_save | 0 | 4 | 200 | 0 | 200 |
| rdb_default_save | 0 | 5 | 200 | 0 | 200 |
| rdb_default_save | 2000 | 1 | 200 | 0 | 200 |
| rdb_default_save | 2000 | 2 | 200 | 0 | 200 |
| rdb_default_save | 2000 | 3 | 200 | 0 | 200 |
| rdb_default_save | 2000 | 4 | 200 | 0 | 200 |
| rdb_default_save | 2000 | 5 | 200 | 0 | 200 |
| no_persistence | 0 | 1 | 200 | 0 | 200 |
| no_persistence | 0 | 2 | 200 | 0 | 200 |
| no_persistence | 0 | 3 | 200 | 0 | 200 |
| no_persistence | 0 | 4 | 200 | 0 | 200 |
| no_persistence | 0 | 5 | 200 | 0 | 200 |
| no_persistence | 2000 | 1 | 200 | 0 | 200 |
| no_persistence | 2000 | 2 | 200 | 0 | 200 |
| no_persistence | 2000 | 3 | 200 | 0 | 200 |
| no_persistence | 2000 | 4 | 200 | 0 | 200 |
| no_persistence | 2000 | 5 | 200 | 0 | 200 |

## RDB baseline (S2b)
| config | trial | enqueued | rdb file existed before kill | changes since last save | waiting after restart | lost |
|---|---|---|---|---|---|---|
| rdb_default_save_SAVE_after_all_200 | 1 | 200 | True | 0 | 200 | 0 |
| rdb_default_save_SAVE_after_all_200 | 2 | 200 | True | 0 | 200 | 0 |
| rdb_default_save_SAVE_after_all_200 | 3 | 200 | True | 0 | 200 | 0 |
| rdb_default_save_SAVE_after_all_200 | 4 | 200 | True | 0 | 200 | 0 |
| rdb_default_save_SAVE_after_all_200 | 5 | 200 | True | 0 | 200 | 0 |
| rdb_default_save_SAVE_after_first_100 | 1 | 200 | True | 1000 | 100 | 100 |
| rdb_default_save_SAVE_after_first_100 | 2 | 200 | True | 1000 | 100 | 100 |
| rdb_default_save_SAVE_after_first_100 | 3 | 200 | True | 1000 | 100 | 100 |
| rdb_default_save_SAVE_after_first_100 | 4 | 200 | True | 1000 | 100 | 100 |
| rdb_default_save_SAVE_after_first_100 | 5 | 200 | True | 1000 | 100 | 100 |
| rdb_default_save_no_SAVE | 1 | 200 | False | 2004 | 0 | 200 |
| rdb_default_save_no_SAVE | 2 | 200 | False | 2004 | 0 | 200 |
| rdb_default_save_no_SAVE | 3 | 200 | False | 2004 | 0 | 200 |
| rdb_default_save_no_SAVE | 4 | 200 | False | 2004 | 0 | 200 |
| rdb_default_save_no_SAVE | 5 | 200 | False | 2004 | 0 | 200 |

## Summary
- A: restarted jobs ran their effect twice (5 duplicates per trial). B: duplicates suppressed, but E shows the guard can lose the effect entirely.
- E: killing the worker between SADD and the effect leaves the guard set and the effect never written: 5 jobs completed with no effect, every trial. Completed status does not imply the effect happened.
- F: atomic guard+effect: 0 duplicates, 0 missing (same-Redis simulation only).
- C: stalled jobs fail visibly (5 failed, 0 re-runs).
- D: a blocked event loop past the lock duration makes BullMQ re-run the job while the first worker is still alive: duplicate effect and "Missing lock" errors when the first worker tries to finish.
- Redis restart: AOF everysec and always lost 0/200 under process kill; RDB with default-style rules and no snapshot lost 200/200; RDB with a SAVE before kill lost 0, SAVE after only the first 100 lost 100; no persistence lost 200/200. "Configured" is not "snapshotted".

## Correction provenance
The first S1 run of variant D stopped observing at about 3.4 s, before stalled detection, and is invalid; it is kept only as `raw/s1_first_run_D_rows_STALE.json` and is excluded from the table above. The rerun (wait extended by 5 s) replaces it.

## Metrics aggregation
Dashboard metrics come from the orchestrator process (obs.js, using trial() in s3.js), which survives worker kills. On each tick it reads durable evidence: (1) the start log file written by workers at each job start (attempts started, jobs started more than once); (2) the effect evidence, which is the effect-log file for variants A, C and E, and the Redis list `effects:q` for variant F only (duplicate effects = jobs appearing more than once; started-without-effect = distinct started job ids minus distinct effect ids); (3) BullMQ job counts (completed, failed, waiting plus active) from the queue. Worker processes export nothing, so killing them cannot reset counters or hide attempts or duplicate effects. `spike_worker_kills_total` is a counter in the orchestrator. The "started without effect" gauge is transient while jobs are in flight; its final value is the result. The dashboard screenshot comes from a separate observability run (one trial per variant: A 9.8 s, C 8.4 s, E 11.6 s, F 9.8 s), so its timings can differ slightly from the trial table (for example C 8.3 s in a table run). The table has all trials. E and F count effects at different places (file vs Redis list), so their comparison is between separate simulations, not a controlled head-to-head.
