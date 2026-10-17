# Postgres Disaster Recovery

A full disaster recovery experiment for PostgreSQL: self-managed Postgres on EC2, automated backups to S3 with pgBackRest, streaming replication, an ELK logging pipeline, and two simulated production incidents with measured RTO and RPO.

---

## The Problem

> A backup you've never restored is not a backup.

Most teams configure backups and never test them. This experiment builds the entire stack from scratch and then **breaks it on purpose** to answer:

- When someone runs `DROP TABLE` on production, how fast can you get the data back?
- When the primary server dies, how fast can you failover?
- How much data do you lose in each scenario?
- Do your data checksums actually catch corruption?

---

## What's Built

### Infrastructure

| Component | Tool | Purpose |
|---|---|---|
| **Database** | PostgreSQL 16 on EC2 (`t3.medium`) | Primary database with data checksums and WAL archiving |
| **Backup** | pgBackRest → S3 | Full + differential backups, continuous WAL archiving, PITR capability |
| **Replication** | Streaming replication to a hot standby | Near-zero-lag read replica, instant failover target |
| **Metrics** | Prometheus + Grafana | TPS, replication lag, WAL archiving rate, cache hit ratio, query performance |
| **Logs** | Filebeat → Elasticsearch → Kibana | Query-level audit logs, searchable incident history |
| **Load generator** | Node.js script with Faker | Continuous mixed INSERTs (users, orgs, projects) to simulate production traffic |

### Postgres Configuration Highlights

```ini
wal_level = replica                 # Enables WAL archiving + streaming replication
archive_mode = on                   # pgBackRest handles the archive_command
archive_command = 'pgbackrest --stanza=main archive-push %p'
log_statement = 'all'               # Every query logged (for Kibana)
shared_preload_libraries = 'pg_stat_statements'
```

Data checksums enabled at `initdb` time (`--data-checksums`) — cannot be added later without dump/restore.

---

## Schema

A 30+ table production-style schema (`schema.sql`, 614 lines) modelling a deployment platform:

| Section | Tables |
|---|---|
| **Users & Auth** | `users`, `user_sessions` (hashed refresh tokens, device tracking) |
| **Organizations** | `organizations`, `organization_members`, `teams`, `team_members` |
| **IAM (RBAC + ABAC)** | `roles`, `permissions`, `role_permissions`, `user_roles`, `team_roles`, `resource_grants`, `invitations` |
| **Deployment** | `projects`, `pipelines`, `builds`, `deployments`, `custom_domains`, `project_environment_variables`, `resources` |
| **Billing** | `plans`, `plan_features`, `subscriptions`, `subscription_changes`, `usage_records`, `credits`, `invoices`, `invoice_line_items`, `payment_methods`, `payments`, `webhook_events` |
| **Audit** | `audit_logs` (append-only, never UPDATE or DELETE) |

Design decisions:
- UUID primary keys throughout (`gen_random_uuid()`)
- Deferred circular FK: `projects.active_deployment_id → deployments.id`
- Soft deletes (`deleted_at`) on users, orgs, teams, projects
- AES-256-GCM encrypted OAuth tokens and environment variables (ciphertext + IV stored)
- Idempotency keys on `payments` and `usage_records` to prevent double-processing
- Partial indexes on soft-delete columns (`WHERE deleted_at IS NOT NULL`)

---

## Simulated Incidents

### Incident A — Accidental `DROP TABLE`

**Scenario**: Someone runs `DROP TABLE deployments CASCADE;` on the live primary.

**Recovery procedure**:

1. Note the exact timestamp (`SELECT now();`)
2. `DROP TABLE deployments CASCADE;` — kills the table, NULLs the FK in `projects`
3. Stop the load generator
4. PITR restore to a separate instance:
   ```bash
   pgbackrest --stanza=main --type=time \
     --target="2026-10-XX HH:MM:SS+05:30" \
     --target-action=promote restore
   ```
5. Dump the recovered table from the restored instance
6. Replay it into the live primary
7. Re-add the FK constraint
8. Verify: row counts match, no orphaned references

**Metrics to record**: detection time, RTO, RPO, failed requests during downtime window.

### Incident B — Primary Server Lost

**Scenario**: Primary EC2 instance is gone (`sudo shutdown now`).

Two paths compared:

| Recovery path | Steps | Expected RTO |
|---|---|---|
| **Promote replica** | `pg_ctlcluster promote` on the replica, re-point load generator | Fast (seconds) |
| **Restore from S3** | Fresh EC2 → `pgbackrest restore` → start Postgres | Slower (minutes, depends on WAL volume) |

### Bonus Tests

| Test | What it proves |
|---|---|
| **WAL replay time** | 10 min vs 60 min of load → more WAL = longer RTO |
| **Network partition** | `iptables` block between primary and replica → replication lag spikes, then catches up |
| **Corruption detection** | `dd` zero bytes into a data file → Postgres checksum catches it on read |

---

## Monitoring & Alerts

### Grafana Dashboards

| Dashboard | Panels |
|---|---|
| **Postgres Overview** | TPS (commits/s + rollbacks/s), active connections, cache hit ratio, tuple ops (inserts/updates/deletes/s) |
| **WAL & Backups** | WAL archiving rate, archive failures, last backup age, WAL size on disk |
| **Replication** | Replication lag (bytes + time), replica state |
| **Query Performance** | p50/p95/p99 from `pg_stat_statements`, slowest queries, most called |
| **Incident** | RTO clock, failed request counter, row count comparison |

### Alert Rules (Grafana)

| Alert | Condition | Severity |
|---|---|---|
| WAL archive failure | `pg_stat_archiver.failed_count` increases | Critical |
| Replication lag > 30s | `replay_lag > 30` | Warning |
| Replication lag > 5min | `replay_lag > 300` | Critical |
| Active connections > 80 | `numbackends > 80` | Warning |
| Last backup > 25h old | `backup_age_seconds > 90000` | Critical |
| Cache hit ratio < 95% | `blks_hit / (blks_hit + blks_read) < 0.95` | Warning |

---

## Logging Architecture (ISO 27001)

Three-tier pipeline designed for compliance:

```
PostgreSQL logs → Filebeat (shipper) → Elasticsearch (hot/SIEM, 30-90 days) → S3 Object Lock (cold/WORM, 1-7 years)
```

- **Filebeat** tails `/var/log/postgresql/*.log` and ships to Elasticsearch in real time
- **Elasticsearch + Kibana** for active security monitoring (brute force detection, unauthorized schema changes)
- **S3 with Object Lock** (WORM) for immutable long-term archival — nobody can delete or modify logs until retention expires

---

## How to Run

### Prerequisites

- Node.js (for the load generator)
- Docker (for the ELK stack)
- An AWS account (for EC2, S3, pgBackRest)

### Quick start (ELK + load generator)

```bash
cd recovery

# Start Elasticsearch + Kibana + Filebeat
docker compose up -d

# Load the schema into your Postgres instance
psql -h <HOST> -U postgres -d postgres -f schema.sql

# Run the load generator
npm ci
node load_generator.js
```

### Full setup

The complete step-by-step guide is in [`execution_plan.md`](execution_plan.md):

| Phase | What | Time estimate |
|---|---|---|
| Phase 0 | EC2 instance + S3 bucket + IAM role | Day 1 |
| Phase 1 | Install Postgres 16, configure WAL, load schema | Day 1 |
| Phase 2 | pgBackRest to S3, first full backup, verify WAL archiving | Day 1 |
| Phase 3 | Streaming replication to a hot standby | Day 2 |
| Phase 4 | Rewrite load generator (mixed workload, connection pool, metrics) | Day 2 |
| Phase 5 | Monitoring stack (Prometheus, Grafana, ELK) | Day 3 |
| Phase 6 | **Incident A** — DROP TABLE + PITR recovery | Day 4 |
| Phase 7 | **Incident B** — Primary failover (both paths) | Day 5 |
| Phase 8 | Bonus tests (WAL replay, partition, corruption) | Day 5+ |

---

## File Map

```
recovery/
├── schema.sql                         # Full production schema — 30+ tables, 614 lines
├── execution_plan.md                  # Complete step-by-step guide (8 phases, ~550 lines)
├── load_generator.js                  # Continuous INSERT workload (users, orgs, projects) with Faker
├── docker-compose.yml                 # Elasticsearch 8.10 + Kibana 8.10 + Filebeat 8.10
├── filebeat.yml                       # Log shipper config (CloudWatch → Elasticsearch)
├── checksum.md                        # Notes on Postgres data checksums, postgresql.conf, pgBackRest
├── iso_logging_compliance_plan.md     # ISO 27001 logging architecture (Filebeat → ELK → S3 WORM)
├── logs_sending.txt                   # Working notes: RDS logging, Kibana setup, Client vs Pool, security groups
├── package.json                       # pg 8.23, @faker-js/faker 10.6
└── package-lock.json                  # Locked dependency tree
```

---

## Key Learnings

| Topic | Lesson |
|---|---|
| **Data checksums** | Must be enabled at `initdb` time — cannot add later. Detects silent disk corruption on read. |
| **pgBackRest vs pg_dump** | pg_dump is a snapshot-only tool. pgBackRest gives you continuous WAL archiving, PITR, parallel restore, and S3 integration. |
| **PITR** | Point-in-time recovery replays WAL from the last full backup to your target timestamp. More WAL = longer replay = higher RTO. |
| **Replica promotion** | Fastest failover path. But you lose the replica — you need to rebuild replication afterward. |
| **Client vs Pool** | `pg.Client` = one connection, manual lifecycle. `pg.Pool` = connection reuse, required for concurrent load. |
| **AWS Multi-AZ** | In production, AWS RDS handles DNS failover automatically when promoting a read replica. This experiment does it manually to understand what's underneath. |
| **IAM instance profiles** | Never hardcode AWS keys. Use EC2 instance profiles — pgBackRest supports `repo1-s3-key-type=auto`. |
