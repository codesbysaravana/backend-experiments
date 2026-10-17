# DB Disaster Recovery Project — Execution Plan

> Self-managed Postgres on EC2, pgBackRest to S3, full observability, two simulated incidents.

---

## Phase 0: Infrastructure (EC2 + S3)

### 0A — Launch the EC2 instance

- **AMI**: Ubuntu 22.04 LTS (or Amazon Linux 2023)
- **Instance type**: `t3.medium` (2 vCPU, 4 GB) — enough for Postgres + monitoring stack
- **Storage**: 30 GB gp3 root volume (Postgres data lives here for now)
- **Security group**: Open ports:
  - `22` (SSH, your IP only)
  - `5432` (Postgres, your IP only — for the load generator on your laptop)
  - `3000` (Grafana)
  - `5601` (Kibana)
  - `9090` (Prometheus)

> [!WARNING]
> Don't open 5432 to `0.0.0.0/0`. Lock it to your IP. You'll change ISPs and forget.

### 0B — Create the S3 bucket for backups

```bash
aws s3api create-bucket \
  --bucket your-name-pgbackrest-backups \
  --region us-east-1

# Enable versioning (required for safe WAL archiving)
aws s3api put-bucket-versioning \
  --bucket your-name-pgbackrest-backups \
  --versioning-configuration Status=Enabled

# Lifecycle rule: delete backups older than 30 days
aws s3api put-bucket-lifecycle-configuration \
  --bucket your-name-pgbackrest-backups \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-old-backups",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "Expiration": {"Days": 30},
      "NoncurrentVersionExpiration": {"NoncurrentDays": 7}
    }]
  }'
```

### 0C — IAM role for the EC2 instance

Create an IAM role with **only** S3 access to your backup bucket. Attach it to the EC2 instance as an instance profile — no hardcoded keys.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::your-name-pgbackrest-backups",
      "arn:aws:s3:::your-name-pgbackrest-backups/*"
    ]
  }]
}
```

> [!IMPORTANT]
> Use the instance profile, not access keys. Your old `docker-compose.yml` had keys in plaintext — don't repeat that.

### ✅ Checkpoint
- [ ] Can SSH into the instance
- [ ] `aws s3 ls s3://your-name-pgbackrest-backups/` works from the instance (no keys, just the role)

---

## Phase 1: Install & Configure Postgres

### 1A — Install Postgres 16

```bash
sudo apt update && sudo apt upgrade -y

# Add Postgres APT repo
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt update
sudo apt install -y postgresql-16
```

### 1B — Initialize with data checksums

```bash
# Stop the auto-created cluster and reinit with checksums
sudo pg_ctlcluster 16 main stop
sudo pg_dropcluster 16 main
sudo pg_createcluster 16 main -- --data-checksums
sudo pg_ctlcluster 16 main start
```

> [!IMPORTANT]
> `--data-checksums` must be set at initdb time. Can't add later without dump/restore. This is how you detect silent corruption.

### 1C — Configure `postgresql.conf`

Edit `/etc/postgresql/16/main/postgresql.conf`:

```ini
# === Connections ===
listen_addresses = '*'
max_connections = 100

# === WAL (the whole point of this project) ===
wal_level = replica                    # enables WAL archiving + streaming replication
archive_mode = on                      # turns on WAL archiving (pgBackRest will handle the "where")
archive_command = 'pgbackrest --stanza=main archive-push %p'
max_wal_senders = 5                    # how many replication connections (replica + pgBackRest)
wal_keep_size = 256MB                  # safety net: keep WAL segments on disk in case archiving lags

# === Replication ===
hot_standby = on                       # let replicas serve read queries

# === Logging (text logs → Filebeat → Elasticsearch → Kibana) ===
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d.log'
log_statement = 'all'                  # log every query (heavy, but you need it for the project)
log_min_duration_statement = 0         # log execution time of every query
log_line_prefix = '%t [%p] %u@%d '     # timestamp, PID, user@database
log_connections = on
log_disconnections = on

# === Performance Insights ===
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
```

### 1D — Configure `pg_hba.conf`

Edit `/etc/postgresql/16/main/pg_hba.conf` — add these lines:

```
# Load generator from your laptop
host    all             postgres        YOUR_LAPTOP_IP/32       scram-sha-256

# Replication from replica EC2 (add this after you launch the replica)
host    replication     replicator      REPLICA_IP/32           scram-sha-256
```

### 1E — Create replication user & enable pg_stat_statements

```bash
sudo -u postgres psql <<SQL
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'a-strong-password-here';
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
```

### 1F — Restart and load the schema

```bash
sudo pg_ctlcluster 16 main restart

# From your laptop (or from the EC2 instance itself):
psql -h EC2_PUBLIC_IP -U postgres -d postgres -f schema.sql
```

### ✅ Checkpoint
- [ ] `SHOW wal_level;` → `replica`
- [ ] `SHOW archive_mode;` → `on`
- [ ] `SHOW data_checksums;` → `on` (run: `sudo -u postgres pg_controldata /var/lib/postgresql/16/main | grep checksum`)
- [ ] `SELECT * FROM pg_stat_statements LIMIT 1;` works
- [ ] All 30+ tables from your schema exist: `\dt` in psql

---

## Phase 2: pgBackRest to S3

### 2A — Install pgBackRest

```bash
sudo apt install -y pgbackrest
```

### 2B — Configure `/etc/pgbackrest/pgbackrest.conf`

```ini
[main]
pg1-path=/var/lib/postgresql/16/main

[global]
repo1-type=s3
repo1-s3-bucket=your-name-pgbackrest-backups
repo1-s3-region=us-east-1
repo1-s3-key-type=auto            # uses the EC2 instance profile, no keys!
repo1-path=/pgbackrest
repo1-retention-full=2            # keep 2 full backups
repo1-retention-diff=7            # keep 7 differentials

# Compression
compress-type=zst
compress-level=3

# Parallel processing
process-max=2

[global:archive-push]
compress-level=3
```

### 2C — Create the stanza and run the first backup

```bash
# Initialize the stanza (tells pgBackRest about your cluster) a config profile  
sudo -u postgres pgbackrest --stanza=main stanza-create

# Verify everything is wired up
sudo -u postgres pgbackrest --stanza=main check

# Take the first full backup
sudo -u postgres pgbackrest --stanza=main --type=full backup

# Verify it landed
sudo -u postgres pgbackrest --stanza=main info
```

### 2D — Verify WAL archiving is flowing

```bash
# Force a WAL segment switch
sudo -u postgres psql -c "SELECT pg_switch_wal();"

# Check archive status — last_archived_wal should update
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"

# Check S3 — WAL files should be appearing
aws s3 ls s3://your-name-pgbackrest-backups/pgbackrest/archive/ --recursive | tail -5
```

### ✅ Checkpoint
- [ ] `pgbackrest --stanza=main check` → no errors
- [ ] `pgbackrest --stanza=main info` shows a full backup with status "ok"
- [ ] WAL files visible in S3
- [ ] `pg_stat_archiver` shows `last_archived_wal` is recent, `failed_count` is 0

---

## Phase 3: Streaming Replication (Replica)

### 3A — Launch a second EC2 instance

Same spec as the primary. Same security group (or a new one that allows 5432 from the primary's private IP).

### 3B — Install Postgres 16 on the replica (same steps as 1A)

### 3C — Base backup from primary to replica

```bash
# On the REPLICA, stop any auto-created cluster
sudo pg_ctlcluster 16 main stop
sudo rm -rf /var/lib/postgresql/16/main/*

# Pull a base backup from the primary
sudo -u postgres pg_basebackup \
  -h PRIMARY_PRIVATE_IP \
  -U replicator \
  -D /var/lib/postgresql/16/main \
  -P -Xs -R
  # -R creates standby.signal and sets primary_conninfo automatically
```

### 3D — Start the replica

```bash
sudo pg_ctlcluster 16 main start

# Verify it's in recovery mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Should return: t
```

### 3E — Check replication status from primary

```bash
sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, replay_lsn, replay_lag FROM pg_stat_replication;"
```

### ✅ Checkpoint
- [ ] Replica shows `pg_is_in_recovery() = true`
- [ ] Primary's `pg_stat_replication` shows the replica with `state = streaming`
- [ ] Insert a row on primary → query it on replica within seconds

---

## Phase 4: Load Generator (Rewrite)

Your current load generator only does INSERTs into 3 tables. You need a realistic mixed workload. Rewrite it to include:

| Operation | What | Why |
|---|---|---|
| INSERT | users, orgs, org_members, projects, pipelines, builds, deployments | Seed data continuously |
| SELECT | JOIN across users → org_members → orgs → projects → deployments | Test read path during recovery |
| UPDATE | `deployments.status` transitions (PENDING → IN_PROGRESS → SUCCESS) | Realistic state changes |
| UPDATE | `builds.status` and `builds.duration_ms` | Realistic build lifecycle |
| DELETE | `user_sessions` (hard delete expired ones) | Test deletes during recovery |
| TRANSACTION | Insert deployment + update `projects.active_deployment_id` in one deferred txn | Exercise the circular FK |

Also add:
- **Metrics emission**: count successful/failed requests per second, log them
- **Graceful error handling**: on connection failure, retry with backoff (so you can measure "failed requests during downtime")
- **Connection pool**: switch from `Client` to `Pool` (you noted the difference in your logs_sending.txt — now use it)
- **Configurable target**: read host/port/password from `.env`, not hardcoded

---

## Phase 5: Monitoring Stack

### 5A — Install on the primary EC2 (or a third box if you have RAM)

```bash
# All of these run as Docker containers
sudo apt install -y docker.io docker-compose-plugin
sudo usermod -aG docker ubuntu
```

### 5B — docker-compose for the monitoring stack

This runs: `postgres_exporter`, `prometheus`, `grafana`, `elasticsearch`, `filebeat`, `kibana`

> [!WARNING]
> This stack wants ~6 GB RAM. On a `t3.medium` (4 GB), you'll swap. Either:
> - Use `t3.large` (8 GB) for the monitoring box
> - Or run Prometheus+Grafana on the EC2 and ELK locally on your laptop
> - Or drop Kibana and just use Grafana's log panel with Loki instead of ELK (lighter)

### 5C — Grafana dashboards to build

| Dashboard | Panels |
|---|---|
| **Postgres Overview** | TPS (commits/s + rollbacks/s), active connections, cache hit ratio, tuple ops (inserts/updates/deletes/s) |
| **WAL & Backups** | WAL archiving rate, archive failures, last backup age, WAL size on disk |
| **Replication** | Replication lag (bytes + time), replica state |
| **Query Performance** | p50/p95/p99 from pg_stat_statements, slowest queries, most called queries |
| **Incident** | A single dashboard you open during incidents: RTO clock, failed requests counter, row count comparison |

### 5D — Alerts (pick ONE place — Grafana)

| Alert | Condition | Severity |
|---|---|---|
| WAL archive failure | `pg_stat_archiver.failed_count` increases | Critical |
| Replication lag > 30s | `replay_lag > 30` | Warning |
| Replication lag > 5min | `replay_lag > 300` | Critical |
| Active connections > 80 | `numbackends > 80` | Warning |
| Last backup > 25h old | `backup_age_seconds > 90000` | Critical |
| Cache hit ratio < 95% | `blks_hit / (blks_hit + blks_read) < 0.95` | Warning |

Don't duplicate these in Kibana. Kibana is for **log search** only.

### 5E — Filebeat → Elasticsearch → Kibana

Filebeat reads from `/var/log/postgresql/postgresql-*.log` (local file, not CloudWatch this time!) and ships to Elasticsearch.

```yaml
# filebeat.yml (the new version — no more aws-cloudwatch input)
filebeat.inputs:
  - type: log
    paths:
      - /var/log/postgresql/postgresql-*.log
    multiline.pattern: '^\d{4}-\d{2}-\d{2}'
    multiline.negate: true
    multiline.match: after

output.elasticsearch:
  hosts: ["http://elasticsearch:9200"]

setup.kibana:
  host: "http://kibana:5601"
```

### ✅ Checkpoint
- [ ] Grafana shows live TPS while load generator is running
- [ ] Grafana shows replication lag (should be near zero)
- [ ] Grafana shows WAL archiving rate
- [ ] Kibana shows Postgres query logs (search for a specific table name)
- [ ] At least one alert fires in a test (stop archiving briefly, see the alert)

---

## Phase 6: Incident A — Accidental DROP TABLE

### The scenario
Someone runs `DROP TABLE deployments CASCADE;` on the primary. The `deployments` table, all its rows, the FK from `projects.active_deployment_id`, and any dependent views are gone.

### The procedure

```
1. NOTE THE TIMESTAMP — write it down to the second
   SELECT now();  -- BEFORE the drop

2. DROP TABLE deployments CASCADE;
   -- this also NULLs projects.active_deployment_id via the FK

3. STOP THE LOAD GENERATOR (note the exact time)

4. RESTORE to a separate instance using pgBackRest PITR:
   # On a fresh EC2 instance (or the replica after stopping it):
   sudo -u postgres pgbackrest --stanza=main --type=time \
     --target="2026-10-XX HH:MM:SS+05:30" \
     --target-action=promote \
     restore

5. START the restored instance, verify deployments table exists:
   SELECT count(*) FROM deployments;

6. DUMP just the deployments table from the restored instance:
   pg_dump -h RESTORED_HOST -U postgres -d postgres \
     --table=deployments --data-only -f deployments_data.sql

7. On the LIVE (broken) primary:
   -- Recreate the table structure (from your schema.sql)
   -- Load the data
   psql -h PRIMARY -U postgres -d postgres -f deployments_data.sql
   -- Re-add the FK
   ALTER TABLE projects
     ADD CONSTRAINT fk_projects_active_deployment
     FOREIGN KEY (active_deployment_id)
     REFERENCES deployments(id)
     ON DELETE SET NULL
     DEFERRABLE INITIALLY DEFERRED;

8. VERIFY:
   -- Row count matches?
   -- projects.active_deployment_id values are correct?
   -- Any orphaned references?
   SELECT p.id, p.active_deployment_id
   FROM projects p
   LEFT JOIN deployments d ON p.active_deployment_id = d.id
   WHERE p.active_deployment_id IS NOT NULL AND d.id IS NULL;
   -- ^ should return 0 rows
```

### Numbers to record
- **Detection time**: how long from DROP to "we noticed" (simulate: check Grafana)
- **RTO**: time from "we start restoring" to "table is back and load generator is green"
- **RPO**: rows in restored `deployments` vs. rows that existed at drop time
- **Failed requests**: count from load generator logs during the window

---

## Phase 7: Incident B — Primary Lost

### The scenario
The primary EC2 instance is gone (simulate: `sudo pg_ctlcluster 16 main stop` or `sudo shutdown now`).

### Option 1: Promote the replica

```bash
# On the replica:
sudo -u postgres pg_ctlcluster 16 main promote

# Verify it's no longer in recovery:
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Should return: f

# Re-point your load generator to the replica's IP
# Restart the load generator
```

### Option 2: Restore from S3 onto a fresh instance

```bash
# On a brand new EC2 instance with Postgres 16 installed:
sudo pg_ctlcluster 16 main stop
sudo rm -rf /var/lib/postgresql/16/main/*

sudo -u postgres pgbackrest --stanza=main --type=default restore
sudo pg_ctlcluster 16 main start
```

### Compare both
| Metric | Promote Replica | Restore from S3 |
|---|---|---|
| RTO | | |
| RPO | | |
| Failed requests | | |
| Complexity | | |

---

## Phase 8: Bonus Tests (Quick Wins)

### 8A — WAL replay time experiment
1. Run load generator for **10 minutes**, take an incremental backup, restore → measure replay time
2. Run load generator for **60 minutes**, take an incremental backup, restore → measure replay time
3. Record: more WAL = longer RTO

### 8B — Network partition (replication lag)
```bash
# On the primary, block traffic to the replica for 2 minutes:
sudo iptables -A OUTPUT -d REPLICA_PRIVATE_IP -j DROP

# Watch replication lag spike in Grafana
# After 2 min:
sudo iptables -D OUTPUT -d REPLICA_PRIVATE_IP -j DROP

# Watch it catch up
```

### 8C — Corruption detection (data checksums)
```bash
# Find a data file
sudo -u postgres psql -c "SELECT pg_relation_filepath('users');"
# e.g., base/16384/16385

# Stop postgres, corrupt a few bytes
sudo pg_ctlcluster 16 main stop
sudo dd if=/dev/zero of=/var/lib/postgresql/16/main/base/16384/16385 bs=1 count=8 seek=0 conv=notrunc

# Start postgres — it should still start (checksums are verified on read)
sudo pg_ctlcluster 16 main start

# Try to read the corrupted table
sudo -u postgres psql -c "SELECT * FROM users LIMIT 10;"
# Expected: WARNING: page verification failed, or ERROR with checksum mismatch
```

---

## Execution Order (Do This Sequence)

```
Day 1:  Phase 0 (infra) + Phase 1 (Postgres) + Phase 2 (pgBackRest)
Day 2:  Phase 3 (replica) + Phase 4 (load generator rewrite)
Day 3:  Phase 5 (monitoring + logging)
Day 4:  Phase 6 (Incident A) — take your time, document everything
Day 5:  Phase 7 (Incident B) — both paths if possible
Day 5+: Phase 8 (bonus tests) + write the final runbook + post
```

---

## Final Deliverables

1. **Runbook**: step-by-step commands for DROP TABLE recovery and primary failover
2. **Numbers table**: RTO, RPO, failed requests, WAL replay times
3. **Grafana screenshots**: replication lag during incidents, TPS drop, recovery
4. **Kibana screenshots**: the actual error logs during the incident
5. **Architecture diagram**: Primary → Replica, pgBackRest → S3, Filebeat → ELK, postgres_exporter → Prometheus → Grafana

> [!CAUTION]
> A backup you haven't restored is not a backup. Incident A and B ARE the project. Everything else is setup.
