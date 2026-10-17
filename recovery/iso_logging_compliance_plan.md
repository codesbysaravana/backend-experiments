# ISO Compliance Logging Plan

## Objective
Establish a secure, compliant logging architecture for the production PostgreSQL database to meet ISO 27001 (and similar) compliance standards. This ensures logs are securely collected, searchable for immediate security analysis, and immutably stored for long-term auditing.

## Core Principles
1. **Security**: Logs must not reside solely on the database server where they could be tampered with.
2. **Availability**: Logs must be instantly searchable for active security monitoring and incident response (SIEM).
3. **Retention & Immutability**: Long-term logs must be stored in a WORM (Write Once, Read Many) state to prevent tampering, meeting strict audit requirements.

## Architecture Pipeline

### 1. The Shipper (Collection)
**Tool**: Filebeat (or Fluentd / Datadog Agent)
*   **Action**: Install a lightweight log agent on the database server.
*   **Mechanism**: The agent continuously monitors the local PostgreSQL log directory (e.g., `/var/log/postgresql`). As soon as a new log entry is written, the agent securely streams it to the centralized logging server.
*   **Benefit**: Offloads network transmission from the database process and ensures logs are exfiltrated immediately before a potential attacker could delete them.

### 2. Hot Storage & Analysis (SIEM)
**Tool**: Elasticsearch & Kibana (ELK Stack)
*   **Action**: Aggregate all incoming logs into a central, searchable index.
*   **Mechanism**: Elasticsearch ingests the logs, parsing them for fast querying. Kibana provides the dashboard interface.
*   **Usage**: Security teams use this to set up automated alerts (e.g., brute force login attempts, unauthorized schema changes, dropped tables).
*   **Retention**: Typically 30 to 90 days. (Hot storage is expensive, so older logs are rotated out).

### 3. Cold Storage & Archiving (The "ISO Vault")
**Tool**: AWS S3 (with Object Lock), Google Cloud Storage, or Azure Blob Storage
*   **Action**: Automate the archiving of older logs from Hot Storage into long-term, cheap storage.
*   **Mechanism**: Once logs age past the 30-90 day window in Elasticsearch, they are compressed and moved to a secure storage bucket.
*   **Compliance Requirement (WORM)**: The storage bucket MUST be configured with Object Lock (WORM). This cryptographically guarantees that no user, administrator, or attacker can modify or delete the log files until the required retention period (e.g., 1, 3, or 7 years) expires.

## Implementation Steps
- [ ] Configure PostgreSQL `postgresql.conf` to output robust audit logs locally (as noted in `execution_plan.md`: `log_statement = 'all'`).
- [ ] Deploy and configure Filebeat on the DB server to tail `/var/log/postgresql/*.log`.
- [ ] Provision Elasticsearch/Kibana cluster (or equivalent SIEM) and configure Filebeat to output to it securely.
- [ ] Provision AWS S3 Bucket with Object Lock enabled for the legally required retention policy (e.g., 3 years).
- [ ] Configure Elasticsearch Index Lifecycle Management (ILM) to automatically snapshot and roll older indices into the S3 bucket.
