-- ============================================================
-- EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- for gen_random_uuid()

-- ============================================================
-- SHARED TRIGGER FUNCTION
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = clock_timestamp();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255),
    is_platform_admin BOOLEAN NOT NULL DEFAULT FALSE,
    email_verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX users_email_lower_idx
    ON users (lower(email)) WHERE deleted_at IS NULL;

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- USER IDENTITIES (OAuth)
-- ============================================================
CREATE TABLE user_identities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider VARCHAR(50) NOT NULL CHECK (provider IN ('github','google')),
    provider_user_id VARCHAR(255) NOT NULL,
    encrypted_token TEXT,
    iv VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (provider, provider_user_id)
);
CREATE INDEX idx_user_identities_user_id ON user_identities(user_id);

CREATE TRIGGER update_user_identities_updated_at
    BEFORE UPDATE ON user_identities
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- ORGANIZATIONS
-- ============================================================
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(255) UNIQUE NOT NULL CHECK (slug ~ '^[a-z0-9-]{3,63}$'),
    type VARCHAR(50) NOT NULL CHECK (type IN ('PERSONAL','TEAM')),
    owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,   -- FIX: every org has an owner
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    -- composite unique key, used by child composite FKs
    UNIQUE (id, owner_user_id)
);
CREATE UNIQUE INDEX organizations_personal_owner_idx
    ON organizations(owner_user_id) WHERE type = 'PERSONAL';

CREATE TRIGGER update_organizations_updated_at
    BEFORE UPDATE ON organizations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- ROLES & PERMISSIONS
-- ============================================================
CREATE TABLE roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name VARCHAR(50) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (org_id, name)
);
CREATE UNIQUE INDEX roles_global_name_idx ON roles(name) WHERE org_id IS NULL;

CREATE TRIGGER update_roles_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- roles.org_id immutable
CREATE OR REPLACE FUNCTION roles_org_immutable() RETURNS trigger AS $$
BEGIN
    IF NEW.org_id IS DISTINCT FROM OLD.org_id THEN
        RAISE EXCEPTION 'roles.org_id is immutable';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER roles_org_immutable
    BEFORE UPDATE OF org_id ON roles
    FOR EACH ROW EXECUTE FUNCTION roles_org_immutable();

CREATE TABLE permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) UNIQUE NOT NULL CHECK (name ~ '^[a-z_]+:[a-z_]+$'),
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE role_permissions (
    role_id UUID REFERENCES roles(id) ON DELETE CASCADE,
    permission_id UUID REFERENCES permissions(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (role_id, permission_id)
);
CREATE INDEX idx_role_permissions_permission_id ON role_permissions(permission_id);

-- ============================================================
-- ORGANIZATION MEMBERS
-- ============================================================
CREATE TABLE organization_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    status VARCHAR(50) NOT NULL CHECK (status IN ('PENDING','ACTIVE','DECLINED')),
    invited_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (org_id, user_id)
);
CREATE INDEX idx_org_members_user_id ON organization_members(user_id);
CREATE INDEX idx_org_members_role_id ON organization_members(role_id);

CREATE TRIGGER update_organization_members_updated_at
    BEFORE UPDATE ON organization_members
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- prevent cross-org role leak
CREATE OR REPLACE FUNCTION check_role_org_match()
RETURNS TRIGGER AS $$
DECLARE
    role_org_id UUID;
BEGIN
    SELECT org_id INTO role_org_id FROM roles WHERE id = NEW.role_id FOR KEY SHARE;
    IF role_org_id IS NOT NULL AND role_org_id != NEW.org_id THEN
        RAISE EXCEPTION 'Role does not belong to this organization';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_role_org_match
    BEFORE INSERT OR UPDATE ON organization_members
    FOR EACH ROW EXECUTE FUNCTION check_role_org_match();

-- ============================================================
-- INVITATIONS
-- ============================================================
CREATE TABLE invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL,
    role_id UUID NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    token_hash VARCHAR(255) NOT NULL,
    invited_by UUID REFERENCES users(id) ON DELETE SET NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX invitations_token_hash_uk ON invitations(token_hash);
CREATE INDEX idx_invitations_org_id ON invitations(org_id);
CREATE INDEX idx_invitations_email  ON invitations(lower(email));

CREATE TRIGGER update_invitations_updated_at
    BEFORE UPDATE ON invitations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER enforce_invite_role_org_match
    BEFORE INSERT OR UPDATE ON invitations
    FOR EACH ROW EXECUTE FUNCTION check_role_org_match();

-- ============================================================
-- BILLING
-- ============================================================
CREATE TABLE plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key VARCHAR(50) NOT NULL UNIQUE CHECK (key ~ '^[a-z_]+$'),
    name VARCHAR(100) NOT NULL,
    price_cents INTEGER NOT NULL DEFAULT 0 CHECK (price_cents >= 0),
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    billing_interval VARCHAR(20) NOT NULL DEFAULT 'MONTHLY'
        CHECK (billing_interval IN ('MONTHLY','YEARLY')),
    provider_price_id VARCHAR(255),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TRIGGER update_plans_updated_at
    BEFORE UPDATE ON plans FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE plan_features (
    plan_id UUID NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    feature_key VARCHAR(100) NOT NULL,
    limit_value BIGINT NOT NULL CHECK (limit_value >= 0),
    PRIMARY KEY (plan_id, feature_key)
);

CREATE TABLE payment_providers (
    key VARCHAR(50) PRIMARY KEY
);
INSERT INTO payment_providers (key) VALUES ('stripe');

CREATE TABLE subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL UNIQUE REFERENCES organizations(id) ON DELETE RESTRICT,
    plan_id UUID NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE','PAST_DUE','CANCELED')),
    provider VARCHAR(50) REFERENCES payment_providers(key),
    provider_customer_id VARCHAR(255),
    provider_subscription_id VARCHAR(255) UNIQUE,
    current_period_end TIMESTAMPTZ,
    cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (provider IS NOT NULL OR provider_subscription_id IS NULL),
    UNIQUE (id, org_id)                         -- FIX: target for tenancy-safe payments FK
);
CREATE INDEX idx_subscriptions_plan_id  ON subscriptions(plan_id);
CREATE INDEX idx_subscriptions_customer ON subscriptions(provider, provider_customer_id);

CREATE TRIGGER update_subscriptions_updated_at
    BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    subscription_id UUID,
    amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','SUCCEEDED','FAILED','REFUNDED')),
    provider VARCHAR(50) NOT NULL DEFAULT 'stripe' REFERENCES payment_providers(key),
    provider_payment_id VARCHAR(255),
    idempotency_key VARCHAR(255) NOT NULL UNIQUE,
    failure_reason TEXT,
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (provider, provider_payment_id),
    -- FIX: a payment's subscription must belong to the same org
    CONSTRAINT payments_subscription_org_fk
        FOREIGN KEY (subscription_id, org_id)
        REFERENCES subscriptions (id, org_id) ON DELETE RESTRICT
);
CREATE INDEX idx_payments_org_id          ON payments(org_id, created_at DESC);
CREATE INDEX idx_payments_subscription_id ON payments(subscription_id);

CREATE TRIGGER update_payments_updated_at
    BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE webhook_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider VARCHAR(50) NOT NULL DEFAULT 'stripe' REFERENCES payment_providers(key),
    provider_event_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'RECEIVED'
        CHECK (status IN ('RECEIVED','PROCESSED','FAILED')),
    attempts INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMPTZ,
    UNIQUE (provider, provider_event_id)
);
CREATE INDEX idx_webhook_events_pending
    ON webhook_events(received_at) WHERE status <> 'PROCESSED';

-- ============================================================
-- PROJECTS / ENVIRONMENTS / SERVICES / BUILDS / DEPLOYMENTS
-- ============================================================
CREATE TABLE projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(63) NOT NULL CHECK (slug ~ '^[a-z0-9-]{3,63}$'),
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE','ARCHIVED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    -- composite key for tenancy-safe child FKs
    UNIQUE (id, org_id)
);
CREATE UNIQUE INDEX projects_org_slug_idx
    ON projects(org_id, slug) WHERE deleted_at IS NULL;

CREATE TRIGGER update_projects_updated_at
    BEFORE UPDATE ON projects FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE environments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL,
    org_id UUID NOT NULL,                       -- denormalized for tenancy
    name VARCHAR(63) NOT NULL CHECK (name ~ '^[a-z0-9-]{1,63}$'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    UNIQUE (id, org_id),
    CONSTRAINT environments_project_org_fk
        FOREIGN KEY (project_id, org_id)
        REFERENCES projects (id, org_id) ON DELETE RESTRICT
);
CREATE INDEX idx_environments_org_id ON environments(org_id);
CREATE UNIQUE INDEX environments_project_name_live_idx
    ON environments(project_id, name) WHERE deleted_at IS NULL;

CREATE TRIGGER update_environments_updated_at
    BEFORE UPDATE ON environments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    environment_id UUID NOT NULL,
    org_id UUID NOT NULL,                       -- denormalized
    name VARCHAR(63) NOT NULL CHECK (name ~ '^[a-z0-9-]{1,63}$'),
    tech_stack VARCHAR(100),
    install_command TEXT,
    build_command TEXT,
    start_command TEXT,
    ci_provider VARCHAR(50) NOT NULL DEFAULT 'GITHUB_ACTIONS'
        CHECK (ci_provider IN ('GITHUB_ACTIONS','JENKINS','CODEBUILD')),
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE','PAUSED')),
    active_deployment_id UUID,                  -- FK added at end (circular)
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    UNIQUE (id, org_id),
    UNIQUE (id, environment_id),
    CONSTRAINT services_env_org_fk
        FOREIGN KEY (environment_id, org_id)
        REFERENCES environments (id, org_id) ON DELETE RESTRICT
);
CREATE INDEX idx_services_org_id ON services(org_id);
CREATE UNIQUE INDEX services_env_name_live_idx
    ON services(environment_id, name) WHERE deleted_at IS NULL;

CREATE TRIGGER update_services_updated_at
    BEFORE UPDATE ON services FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE builds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL,
    org_id UUID NOT NULL,
    provider VARCHAR(50) NOT NULL
        CHECK (provider IN ('GITHUB_ACTIONS','JENKINS','CODEBUILD')),
    external_build_id VARCHAR(255),
    commit_hash VARCHAR(40),
    commit_message TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'QUEUED'
        CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELED')),
    logs_url TEXT,
    error_message TEXT,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (id, service_id),
    UNIQUE (provider, external_build_id),
    CONSTRAINT builds_service_org_fk
        FOREIGN KEY (service_id, org_id)
        REFERENCES services (id, org_id) ON DELETE RESTRICT
);
CREATE INDEX idx_builds_service_created ON builds(service_id, created_at DESC);

CREATE TABLE deployments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL,
    org_id UUID NOT NULL,
    build_id UUID,
    rollback_of_deployment_id UUID,
    trigger_type VARCHAR(50) NOT NULL
        CHECK (trigger_type IN ('WEBHOOK','MANUAL','ROLLBACK')),
    triggered_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    commit_hash VARCHAR(40),
    runtime_ref JSONB,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','DEPLOYING','LIVE','FAILED','SUPERSEDED')),
    logs_url TEXT,
    error_message TEXT,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (id, service_id),
    CONSTRAINT deployments_service_org_fk
        FOREIGN KEY (service_id, org_id)
        REFERENCES services (id, org_id) ON DELETE RESTRICT,
    CONSTRAINT deployments_build_same_service_fk
        FOREIGN KEY (build_id, service_id)
        REFERENCES builds (id, service_id) ON DELETE RESTRICT,
    CONSTRAINT deployments_rollback_same_service_fk
        FOREIGN KEY (rollback_of_deployment_id, service_id)
        REFERENCES deployments (id, service_id) ON DELETE RESTRICT
);
CREATE INDEX idx_deployments_service_created ON deployments(service_id, created_at DESC);
CREATE INDEX idx_deployments_build_id        ON deployments(build_id);
CREATE INDEX idx_deployments_org_id          ON deployments(org_id);
CREATE UNIQUE INDEX deployments_one_live
    ON deployments(service_id) WHERE status = 'LIVE';

CREATE TRIGGER update_deployments_updated_at
    BEFORE UPDATE ON deployments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- circular FK: services.active_deployment_id -> deployments (same service only)
ALTER TABLE services
    ADD CONSTRAINT fk_services_active_deployment
    FOREIGN KEY (active_deployment_id, id) REFERENCES deployments (id, service_id)
    ON DELETE RESTRICT;   -- FIX: active deployment must belong to this same service (and so the same org)
CREATE INDEX idx_services_active_deployment ON services(active_deployment_id);

-- ============================================================
-- GITHUB INSTALLATIONS
-- ============================================================
CREATE TABLE github_installations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    installation_id BIGINT NOT NULL UNIQUE,
    account_login VARCHAR(255) NOT NULL,
    account_type VARCHAR(20) NOT NULL
        CHECK (account_type IN ('User','Organization')),
    installed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    suspended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (id, org_id)
);
CREATE INDEX idx_github_installations_org_id ON github_installations(org_id);

-- ============================================================
-- GIT CONNECTIONS
-- ============================================================
CREATE TABLE git_connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL,
    org_id UUID NOT NULL,
    installation_id UUID,
    repo_owner VARCHAR(255) NOT NULL,
    repo_name VARCHAR(255) NOT NULL,
    branch VARCHAR(255) NOT NULL DEFAULT 'main',
    root_directory VARCHAR(255) NOT NULL DEFAULT '/',
    is_autodeploy_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (service_id),
    CONSTRAINT git_conn_service_org_fk
        FOREIGN KEY (service_id, org_id)
        REFERENCES services (id, org_id) ON DELETE CASCADE,
    CONSTRAINT git_conn_installation_org_fk
        FOREIGN KEY (installation_id, org_id)
        REFERENCES github_installations (id, org_id) ON DELETE RESTRICT
);
CREATE INDEX idx_git_connections_repo         ON git_connections(repo_owner, repo_name, branch);
CREATE INDEX idx_git_connections_installation ON git_connections(installation_id);

CREATE TRIGGER update_git_connections_updated_at
    BEFORE UPDATE ON git_connections FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- ENVIRONMENT VARIABLES
-- ============================================================
CREATE TABLE environment_variables (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL,
    environment_id UUID NOT NULL,
    key VARCHAR(255) NOT NULL,
    encrypted_value TEXT NOT NULL,
    iv VARCHAR(255) NOT NULL,
    is_buildtime BOOLEAN NOT NULL DEFAULT TRUE,
    is_runtime BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (service_id, environment_id, key),
    -- environment must belong to the service's environment
    CONSTRAINT env_vars_service_env_fk
        FOREIGN KEY (service_id, environment_id)
        REFERENCES services (id, environment_id) ON DELETE CASCADE
);
CREATE INDEX idx_env_vars_lookup ON environment_variables(service_id, environment_id);

CREATE TRIGGER update_environment_variables_updated_at
    BEFORE UPDATE ON environment_variables FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- AUDIT LOGS (append-only)
-- ============================================================
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID,                                   -- intentionally no FK
    actor_type VARCHAR(20) NOT NULL
        CHECK (actor_type IN ('USER','SYSTEM','WEBHOOK','API_KEY')),
    actor_id UUID,
    action VARCHAR(100) NOT NULL CHECK (action ~ '^[a-z_]+\.[a-z_]+$'),
    resource_type VARCHAR(100),
    resource_id UUID,
    ip_address INET,
    user_agent TEXT,
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_audit_org_created ON audit_logs(org_id, created_at DESC);
CREATE INDEX idx_audit_actor       ON audit_logs(actor_id, created_at DESC);
CREATE INDEX idx_audit_resource    ON audit_logs(resource_type, resource_id);

CREATE OR REPLACE FUNCTION audit_logs_immutable() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_logs is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_logs_no_update
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION audit_logs_immutable();

CREATE TRIGGER audit_logs_no_truncate
    BEFORE TRUNCATE ON audit_logs
    FOR EACH STATEMENT EXECUTE FUNCTION audit_logs_immutable();