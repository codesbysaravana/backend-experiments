-- =============================================================================
-- db_next.sql — Full Production Schema (Merged)
-- Scope: Auth, Orgs, Teams, IAM (RBAC+ABAC), Core Deployment, Billing
-- PK strategy: UUID throughout (gen_random_uuid — Postgres 13+)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- provides gen_random_uuid()

-- =============================================================================
-- SECTION 1: USERS & AUTH
-- =============================================================================

CREATE TABLE users (
id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
name                        VARCHAR(255) NOT NULL,
email                       VARCHAR(255) NOT NULL UNIQUE,
password_hash               TEXT,

-- GitHub OAuth (tokens encrypted at rest — AES-256-GCM)
github_id                   VARCHAR(255) UNIQUE,
github_username             VARCHAR(255),
github_access_token_enc     TEXT,        -- ciphertext
github_access_token_iv      VARCHAR(64), -- initialisation vector

-- Google OAuth
google_id                   VARCHAR(255) UNIQUE,
google_access_token_enc     TEXT,
google_access_token_iv      VARCHAR(64),

-- Account state
is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
deleted_at                  TIMESTAMP,   -- soft-delete: NULL = alive

created_at                  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at                  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP

);

-- Enables server-side JWT revocation, multi-device logout, stolen-token detection.
CREATE TABLE user_sessions (
id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
user_id              UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

-- Store the HASH of the refresh token — never the raw value
refresh_token_hash   TEXT NOT NULL UNIQUE,

device_info          TEXT,        -- User-Agent string
ip_address           VARCHAR(45), -- IPv4 or IPv6

expires_at           TIMESTAMP NOT NULL,
revoked_at           TIMESTAMP,   -- NULL = session still valid

created_at           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP

);

-- =============================================================================
-- SECTION 2: ORGANIZATIONS & TEAMS
-- =============================================================================

CREATE TABLE organizations (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
name            VARCHAR(255) NOT NULL,
slug            VARCHAR(255) NOT NULL UNIQUE,
type            VARCHAR(50) NOT NULL DEFAULT 'STARTUP'
CHECK (type IN ('STARTUP', 'SMB', 'ENTERPRISE', 'AGENCY', 'PERSONAL')),
status          VARCHAR(50) NOT NULL DEFAULT 'ACTIVE'
CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
billing_email   VARCHAR(255),
deleted_at      TIMESTAMP,
created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE organization_members (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
status          VARCHAR(50) NOT NULL DEFAULT 'ACTIVE'
CHECK (status IN ('INVITED', 'ACTIVE', 'REMOVED')),
created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
UNIQUE (org_id, user_id)
);

CREATE TABLE teams (
id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id      UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
name        VARCHAR(255) NOT NULL,
created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
deleted_at  TIMESTAMP
);

CREATE TABLE team_members (
team_id     UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
PRIMARY KEY (team_id, user_id)
);

-- =============================================================================
-- SECTION 3: IAM — RBAC + ABAC
-- =============================================================================

-- Roles can be system-wide (org_id IS NULL) or org-scoped.
CREATE TABLE roles (
id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id      UUID REFERENCES organizations(id) ON DELETE CASCADE, -- NULL = system role
name        VARCHAR(100) NOT NULL,
description TEXT,
is_system   BOOLEAN NOT NULL DEFAULT FALSE,
created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Org invitations — scoped to a role from the start.
CREATE TABLE invitations (
id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id      UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
email       VARCHAR(255) NOT NULL,
role_id     UUID NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
invited_by  UUID REFERENCES users(id) ON DELETE SET NULL,
status      VARCHAR(50) NOT NULL DEFAULT 'PENDING'
CHECK (status IN ('PENDING', 'ACCEPTED', 'EXPIRED', 'REVOKED')),
expires_at  TIMESTAMP NOT NULL,
created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Atomic permission units. e.g. resource_type='deployment', action='trigger'
CREATE TABLE permissions (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
resource_type   VARCHAR(100) NOT NULL, -- 'project', 'deployment', 'invoice', ...
action          VARCHAR(100) NOT NULL, -- 'read', 'write', 'delete', 'deploy', ...
description     TEXT,
UNIQUE (resource_type, action)
);

CREATE TABLE role_permissions (
role_id         UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
permission_id   UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
PRIMARY KEY (role_id, permission_id)
);

-- A user's role within a specific org (RBAC).
CREATE TABLE user_roles (
id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
org_id      UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
role_id     UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
UNIQUE (user_id, org_id, role_id)
);

-- A team's role within an org.
CREATE TABLE team_roles (
team_id     UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
role_id     UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
PRIMARY KEY (team_id, role_id)
);

-- Fine-grained resource-level grants (the ABAC layer).
-- conditions JSONB lets you express attribute rules: {"region":"APAC"}, ownership, etc.
CREATE TABLE resource_grants (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
subject_type    VARCHAR(20) NOT NULL CHECK (subject_type IN ('USER', 'TEAM', 'ROLE')),
subject_id      UUID NOT NULL,
resource_type   VARCHAR(100) NOT NULL,
resource_id     UUID NOT NULL,
permission_id   UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
conditions      JSONB,       -- optional attribute/ownership rules
expires_at      TIMESTAMP,
created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- SECTION 4: CORE DEPLOYMENT
-- =============================================================================

-- Generic resource entity — the anchor for RBAC access checks.
-- Projects, pipelines, etc. register here so resource_grants can gate them.
CREATE TABLE resources (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
type            VARCHAR(100) NOT NULL,  -- 'project', 'pipeline', 'deployment'
name            VARCHAR(255) NOT NULL,
owner_team_id   UUID REFERENCES teams(id) ON DELETE SET NULL,
created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
deleted_at      TIMESTAMP
);

CREATE TABLE projects (
id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
user_id                     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
org_id                      UUID REFERENCES organizations(id) ON DELETE CASCADE,
resource_id                 UUID REFERENCES resources(id) ON DELETE SET NULL, -- RBAC link

-- Identity
name                        VARCHAR(255) NOT NULL,
slug                        VARCHAR(255),  -- URL-safe label, e.g. "my-api"

-- GitHub source
repo_url                    TEXT NOT NULL,
github_repo_owner           VARCHAR(255),
github_repo_name            VARCHAR(255),
github_webhook_id           VARCHAR(255),
github_workflow_installed   BOOLEAN NOT NULL DEFAULT FALSE,
branch                      VARCHAR(255) NOT NULL DEFAULT 'main',

-- Build config
language                    VARCHAR(100),
framework                   VARCHAR(100),
install_command             TEXT,
build_command               TEXT,

-- Infra identifiers — permanent handles for the ECS service
ecs_service_name            TEXT,
ecs_task_family             TEXT,

-- Canonical public URL (set when first deployment succeeds)
live_url                    VARCHAR(255),

-- FK to the deployment currently serving traffic (circular — resolved below via ALTER)
active_deployment_id        UUID,

-- Lifecycle
status                      VARCHAR(50) NOT NULL DEFAULT 'ACTIVE'
                                CHECK (status IN ('ACTIVE', 'PAUSED', 'DELETED')),
deleted_at                  TIMESTAMP,

last_deployed_at            TIMESTAMP,
created_at                  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at                  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP

);

-- One encrypted blob per project (AES-256-GCM).
-- The full key=value map is serialised → encrypted → stored as one payload.
-- updated_by_user_id gives a basic "who last touched secrets" trail.
CREATE TABLE project_environment_variables (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE UNIQUE,
encrypted_payload   TEXT NOT NULL,   -- base64(AES-256-GCM ciphertext of JSON env map)
iv                  VARCHAR(64) NOT NULL,
updated_by_user_id  UUID REFERENCES users(id) ON DELETE SET NULL,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- CI/CD pipeline wired to a project (e.g. a GitHub Actions workflow file).
CREATE TABLE pipelines (
id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
project_id              UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
provider                VARCHAR(100) NOT NULL
CHECK (provider IN ('GITHUB_ACTIONS', 'GITLAB_CI', 'MANUAL')),
external_pipeline_id    VARCHAR(255),  -- GitHub workflow file name / numeric ID
external_pipeline_name  VARCHAR(255),
status                  VARCHAR(50) NOT NULL DEFAULT 'ACTIVE'
CHECK (status IN ('ACTIVE', 'DISABLED')),
created_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- A single CI build run triggered by a pipeline.
CREATE TABLE builds (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
pipeline_id         UUID NOT NULL REFERENCES pipelines(id) ON DELETE CASCADE,
project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE, -- direct FK for queries

-- Source context
commit_hash         VARCHAR(40),
commit_message      TEXT,
triggered_by        VARCHAR(50) NOT NULL DEFAULT 'WEBHOOK'
                        CHECK (triggered_by IN ('WEBHOOK', 'MANUAL', 'API', 'RETRY')),

-- External CI reference
external_build_id   VARCHAR(255),  -- GitHub Actions run_id
build_number        INTEGER,
build_url           TEXT,          -- Link to Actions run page
logs_url            TEXT,          -- S3 URL for stored log output

-- Lifecycle
status              VARCHAR(50) NOT NULL DEFAULT 'QUEUED'
                        CHECK (status IN ('QUEUED', 'BUILDING', 'SUCCESS', 'FAILED', 'CANCELLED')),
error_message       TEXT,
duration_ms         BIGINT,        -- ms from started_at to completed_at

started_at          TIMESTAMP,
completed_at        TIMESTAMP,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP

);

-- Each push to ECS is a versioned deployment record.
-- Rollback = point projects.active_deployment_id at a prior row.
CREATE TABLE deployments (
id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
project_id               UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
build_id                 UUID REFERENCES builds(id) ON DELETE SET NULL,
triggered_by_user_id     UUID REFERENCES users(id) ON DELETE SET NULL,

-- Source snapshot
commit_hash              VARCHAR(40),
commit_message           TEXT,

-- ECS state snapshot — what was actually pushed to AWS
ecs_task_definition_arn  TEXT,    -- e.g. arn:aws:ecs:…:task-definition/app:42
ecs_task_revision        INTEGER,
live_url                 VARCHAR(255),

-- Lifecycle
status                   VARCHAR(50) NOT NULL DEFAULT 'PENDING'
                             CHECK (status IN (
                                 'PENDING', 'IN_PROGRESS', 'SUCCESS',
                                 'FAILED', 'CANCELLED', 'ROLLED_BACK'
                             )),
error_message            TEXT,
started_at               TIMESTAMP,
finished_at              TIMESTAMP,
created_at               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP

);

-- Resolve the circular FK: projects.active_deployment_id → deployments.id.
-- DEFERRABLE so both rows can be inserted in the same transaction.
ALTER TABLE projects
ADD CONSTRAINT fk_projects_active_deployment
FOREIGN KEY (active_deployment_id)
REFERENCES deployments(id)
ON DELETE SET NULL
DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE custom_domains (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
domain          VARCHAR(255) NOT NULL UNIQUE,

-- DNS lifecycle
dns_status      VARCHAR(50) NOT NULL DEFAULT 'PENDING'
                    CHECK (dns_status IN ('PENDING', 'VERIFYING', 'VERIFIED', 'FAILED')),
dns_verified_at TIMESTAMP,

-- SSL lifecycle (ACM or Let's Encrypt)
ssl_status      VARCHAR(50) NOT NULL DEFAULT 'PENDING'
                    CHECK (ssl_status IN ('PENDING', 'PROVISIONING', 'ACTIVE', 'FAILED')),
ssl_issued_at   TIMESTAMP,
ssl_expires_at  TIMESTAMP,

created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP

);

-- =============================================================================
-- SECTION 5: BILLING
-- =============================================================================

CREATE TABLE plans (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
name                VARCHAR(100) NOT NULL,  -- 'FREE', 'PRO', 'MAX', 'ENTERPRISE'
price               DECIMAL(10,2) NOT NULL DEFAULT 0,
currency            CHAR(3) NOT NULL DEFAULT 'USD',
billing_interval    VARCHAR(20) NOT NULL DEFAULT 'MONTHLY'
CHECK (billing_interval IN ('MONTHLY', 'YEARLY')),
is_active           BOOLEAN NOT NULL DEFAULT TRUE,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE plan_features (
plan_id         UUID NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
feature_key     VARCHAR(100) NOT NULL,  -- 'api_calls', 'storage_gb', 'team_members'
limit_value     BIGINT NOT NULL,
PRIMARY KEY (plan_id, feature_key)
);

CREATE TABLE subscriptions (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id              UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE UNIQUE,
plan_id             UUID NOT NULL REFERENCES plans(id),
status              VARCHAR(50) NOT NULL DEFAULT 'TRIALING'
CHECK (status IN ('TRIALING', 'ACTIVE', 'PAST_DUE', 'CANCELED')),
trial_ends_at       TIMESTAMP,
started_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
current_period_end  TIMESTAMP,
canceled_at         TIMESTAMP,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Proration / plan-change history ledger. Never overwrite plan_id in subscriptions.
CREATE TABLE subscription_changes (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
subscription_id     UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
from_plan_id        UUID REFERENCES plans(id) ON DELETE SET NULL,
to_plan_id          UUID REFERENCES plans(id) ON DELETE SET NULL,
prorated_amount     DECIMAL(10,2),
currency            CHAR(3) NOT NULL DEFAULT 'USD',
effective_at        TIMESTAMP NOT NULL,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Metered usage ingestion. idempotency_key prevents double-counting on retries.
CREATE TABLE usage_records (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id              UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
feature_key         VARCHAR(100) NOT NULL,
quantity            BIGINT NOT NULL,
period_start        TIMESTAMP NOT NULL,
period_end          TIMESTAMP NOT NULL,
idempotency_key     VARCHAR(255) NOT NULL UNIQUE,  -- dedup on ingest
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE credits (
id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id      UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
amount      DECIMAL(10,2) NOT NULL,
currency    CHAR(3) NOT NULL DEFAULT 'USD',
reason      VARCHAR(255),  -- 'refund', 'goodwill', 'promo'
expires_at  TIMESTAMP,
created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE invoices (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id              UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
subscription_id     UUID REFERENCES subscriptions(id) ON DELETE SET NULL,
status              VARCHAR(50) NOT NULL DEFAULT 'DRAFT'
CHECK (status IN ('DRAFT', 'OPEN', 'PAID', 'VOID', 'UNCOLLECTIBLE')),
subtotal            DECIMAL(10,2) NOT NULL DEFAULT 0,
tax_amount          DECIMAL(10,2) NOT NULL DEFAULT 0,
discount_amount     DECIMAL(10,2) NOT NULL DEFAULT 0,
total               DECIMAL(10,2) NOT NULL DEFAULT 0,
currency            CHAR(3) NOT NULL DEFAULT 'USD',
due_at              TIMESTAMP,
paid_at             TIMESTAMP,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE invoice_line_items (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
invoice_id      UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
description     VARCHAR(255) NOT NULL,
amount          DECIMAL(10,2) NOT NULL,
quantity        INT NOT NULL DEFAULT 1,
type            VARCHAR(50) NOT NULL
CHECK (type IN ('SUBSCRIPTION', 'USAGE', 'ADJUSTMENT', 'TAX')),
created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Tokenised only — no raw card data ever stored.
CREATE TABLE payment_methods (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
provider        VARCHAR(50) NOT NULL DEFAULT 'stripe',
provider_ref    VARCHAR(255) NOT NULL,  -- Stripe payment_method id
type            VARCHAR(50) NOT NULL
CHECK (type IN ('CARD', 'BANK_ACCOUNT')),
is_default      BOOLEAN NOT NULL DEFAULT FALSE,
created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
deleted_at      TIMESTAMP
);

-- idempotency_key is non-negotiable: prevents double-charging on Stripe retries.
CREATE TABLE payments (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
invoice_id          UUID NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
payment_method_id   UUID REFERENCES payment_methods(id) ON DELETE SET NULL,
amount              DECIMAL(10,2) NOT NULL,
currency            CHAR(3) NOT NULL DEFAULT 'USD',
status              VARCHAR(50) NOT NULL DEFAULT 'PENDING'
CHECK (status IN ('PENDING', 'SUCCEEDED', 'FAILED', 'REFUNDED')),
provider_reference  VARCHAR(255),   -- Stripe charge / payment_intent id
idempotency_key     VARCHAR(255) NOT NULL UNIQUE,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Stripe webhook dedup + audit trail.
-- provider_event_id UNIQUE prevents double-processing replayed callbacks.
CREATE TABLE webhook_events (
id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
provider            VARCHAR(50) NOT NULL DEFAULT 'stripe',
provider_event_id   VARCHAR(255) NOT NULL UNIQUE,
event_type          VARCHAR(100) NOT NULL,
payload             JSONB,
processed_at        TIMESTAMP,
created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- SECTION 6: UNIFIED AUDIT LOG
-- Covers both IAM events (role.assigned, permission.revoked) and
-- platform events (deployment.triggered, envvar.updated, domain.added).
-- Append-only — no UPDATE or DELETE should ever run against this table.
-- =============================================================================

CREATE TABLE audit_logs (
id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
org_id          UUID REFERENCES organizations(id) ON DELETE SET NULL,

-- Actor (NULL = system-initiated)
actor_id        UUID REFERENCES users(id) ON DELETE SET NULL,
ip_address      VARCHAR(45),

-- What happened
action          VARCHAR(100) NOT NULL,  -- 'deployment.triggered', 'role.assigned', ...
resource_type   VARCHAR(100),           -- 'project', 'deployment', 'role', 'invoice', ...
resource_id     UUID,

-- Narrower scope helpers (nullable — IAM actions may not be project-scoped)
project_id      UUID REFERENCES projects(id) ON DELETE SET NULL,

-- Structured context: commit hash, old/new status, changed field, etc.
metadata        JSONB,

created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP

);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- users
CREATE INDEX idx_users_email                    ON users(email);
CREATE INDEX idx_users_github_id                ON users(github_id);
CREATE INDEX idx_users_google_id                ON users(google_id);
CREATE INDEX idx_users_deleted_at               ON users(deleted_at) WHERE deleted_at IS NOT NULL;

-- user_sessions
CREATE INDEX idx_sessions_user_id               ON user_sessions(user_id);
CREATE INDEX idx_sessions_expires_at            ON user_sessions(expires_at);

-- organizations
CREATE INDEX idx_orgs_slug                      ON organizations(slug);
CREATE INDEX idx_orgs_status                    ON organizations(status);

-- organization_members
CREATE INDEX idx_org_members_org_id             ON organization_members(org_id);
CREATE INDEX idx_org_members_user_id            ON organization_members(user_id);

-- teams
CREATE INDEX idx_teams_org_id                   ON teams(org_id);

-- invitations
CREATE INDEX idx_invitations_org_id             ON invitations(org_id);
CREATE INDEX idx_invitations_email              ON invitations(email);

-- IAM
CREATE INDEX idx_user_roles_user_id             ON user_roles(user_id);
CREATE INDEX idx_user_roles_org_id              ON user_roles(org_id);
CREATE INDEX idx_resource_grants_subject        ON resource_grants(subject_type, subject_id);
CREATE INDEX idx_resource_grants_resource       ON resource_grants(resource_type, resource_id);

-- resources
CREATE INDEX idx_resources_org_id               ON resources(org_id);
CREATE INDEX idx_resources_type                 ON resources(type);

-- projects
CREATE INDEX idx_projects_user_id               ON projects(user_id);
CREATE INDEX idx_projects_org_id                ON projects(org_id);
CREATE INDEX idx_projects_status                ON projects(status);
CREATE INDEX idx_projects_slug                  ON projects(slug);
CREATE INDEX idx_projects_deleted_at            ON projects(deleted_at) WHERE deleted_at IS NOT NULL;

-- env vars (one row per project — unique enforced on table, index for lookup)
CREATE INDEX idx_env_vars_project_id            ON project_environment_variables(project_id);

-- pipelines
CREATE INDEX idx_pipelines_project_id           ON pipelines(project_id);

-- builds
CREATE INDEX idx_builds_pipeline_id             ON builds(pipeline_id);
CREATE INDEX idx_builds_project_id              ON builds(project_id);
CREATE INDEX idx_builds_status                  ON builds(status);
CREATE INDEX idx_builds_commit_hash             ON builds(commit_hash);

-- deployments
CREATE INDEX idx_deployments_project_id         ON deployments(project_id);
CREATE INDEX idx_deployments_build_id           ON deployments(build_id);
CREATE INDEX idx_deployments_status             ON deployments(status);

-- custom_domains
CREATE INDEX idx_custom_domains_project_id      ON custom_domains(project_id);

-- subscriptions
CREATE INDEX idx_subscriptions_org_id           ON subscriptions(org_id);
CREATE INDEX idx_subscription_changes_sub_id    ON subscription_changes(subscription_id);

-- usage_records
CREATE INDEX idx_usage_records_org_id           ON usage_records(org_id);
CREATE INDEX idx_usage_records_period           ON usage_records(org_id, period_start, period_end);

-- invoices
CREATE INDEX idx_invoices_org_id                ON invoices(org_id);
CREATE INDEX idx_invoices_status                ON invoices(status);

-- payments
CREATE INDEX idx_payments_invoice_id            ON payments(invoice_id);

-- webhook_events
CREATE INDEX idx_webhook_events_type            ON webhook_events(event_type);

-- audit_logs
CREATE INDEX idx_audit_logs_actor_id            ON audit_logs(actor_id);
CREATE INDEX idx_audit_logs_org_id              ON audit_logs(org_id);
CREATE INDEX idx_audit_logs_project_id          ON audit_logs(project_id);
CREATE INDEX idx_audit_logs_action              ON audit_logs(action);
CREATE INDEX idx_audit_logs_created_at          ON audit_logs(created_at DESC);
CREATE INDEX idx_audit_logs_resource            ON audit_logs(resource_type, resource_id);