# Tenancy Schema Definition

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Full column definitions, data types, constraints, and ENUM declarations for the six core tenancy tables: `organizations`, `users`, `business_entities`, `bank_accounts`, `organization_users`, and `business_user_roles`. Every downstream block that performs a JOIN or RLS policy evaluation against these tables binds to the shapes defined here. The schema is instantiated via Supabase CLI migrations; column additions require a new migration, never in-place ALTER during production deployments.

---

## ENUM definitions

```sql
CREATE TYPE user_role      AS ENUM ('OWNER','ADMIN','BOOKKEEPER','ACCOUNTANT','REVIEWER','READ_ONLY');
CREATE TYPE business_status AS ENUM ('ACTIVE','INACTIVE','ARCHIVED');
CREATE TYPE account_status  AS ENUM ('ACTIVE','INACTIVE','ARCHIVED');
CREATE TYPE org_status      AS ENUM ('ACTIVE','INACTIVE');
CREATE TYPE accounting_method AS ENUM ('ACCRUAL'); -- CASH reserved post-MVP
CREATE TYPE vat_period_type   AS ENUM ('QUARTERLY','MONTHLY','ANNUAL');
```

ENUMs are database-level constraints. Application code must treat all sets as closed and hard-fail on unknown values.

---

## Table: `organizations`

```sql
CREATE TABLE organizations (
  id                uuid        NOT NULL DEFAULT gen_uuid_v7(),
  name              text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 255),
  status            org_status  NOT NULL DEFAULT 'ACTIVE',
  deleted_at        timestamptz,          -- GDPR erasure; set by the erasure pipeline
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT organizations_pkey PRIMARY KEY (id)
);

CREATE INDEX idx_organizations_status ON organizations (status);
```

Notes: UUID v7 PK per `data_layer_conventions_policy`. `deleted_at` is the GDPR hard-delete marker per `soft_delete_vs_status_policy`; identity records use `deleted_at` for erasure compatibility. `status` and `deleted_at` are independent: an org may be INACTIVE while awaiting erasure scheduling. Trigger `set_updated_at` maintains `updated_at` on every mutation. Audit events: `TENANCY_ORG_CREATED` (LOW), `TENANCY_ORG_DEACTIVATED` on status → INACTIVE (MEDIUM), `GDPR_ERASURE_REQUESTED` on `deleted_at` set (HIGH — GDPR pipeline).

---

## Table: `users`

Profile extension of Supabase's `auth.users`. Does not duplicate auth credentials; carries display and preference fields only.

```sql
-- Canonical DDL: see user_schema.md (Block 02, Layer 2 elaboration). tenancy_schema_definition covers the Phase 01 tenancy baseline; the full users table definition is owned by user_schema.md.
```

Notes: UUID v7 PK. No `organization_id` column — users are platform-level; scoped to organizations via `organization_users`. `deleted_at` per `soft_delete_vs_status_policy`. `mfa_enabled` is a cached flag from Block 02 Phase 03; authoritative state lives in Supabase Auth. Audit events: `TENANCY_USER_CREATED` (LOW), `GDPR_ERASURE_REQUESTED` on `deleted_at` set (HIGH — GDPR pipeline).

---

## Table: `business_entities`

```sql
-- Canonical DDL: see business_schema.md (Block 02, Layer 2 elaboration). tenancy_schema_definition covers the Phase 01 tenancy baseline; the full business_entities table definition is owned by business_schema.md.
```

Notes: `organization_id` is the tenancy column. `status` ENUM governs the operational lifecycle per `soft_delete_vs_status_policy`; `deleted_at` is GDPR-pipeline-only. `accounting_method` is locked to `'ACCRUAL'` in MVP (Stage 1 decision); the ENUM is shaped for post-MVP `CASH` addition without a migration.

Audit events: `TENANCY_BUSINESS_CREATED` (LOW), `TENANCY_BUSINESS_DEACTIVATED` on → INACTIVE (MEDIUM), `TENANCY_BUSINESS_ARCHIVED` on → ARCHIVED (HIGH).

---

## Table: `bank_accounts`

```sql
CREATE TABLE bank_accounts (
  id                          uuid           NOT NULL DEFAULT gen_uuid_v7(),
  organization_id             uuid           NOT NULL,
  business_id                 uuid           NOT NULL,
  provider                    text           NOT NULL, -- e.g. 'REVOLUT', 'ALPHA_BANK'
  account_name                text           NOT NULL,
  currency                    char(3)        NOT NULL DEFAULT 'EUR',
  masked_iban                 text,          -- last 4 chars displayed in UI; no sensitive data
  iban_encrypted              bytea,         -- ciphertext via Block 05 pgcrypto; NULL until Block 05 lands
  account_number_encrypted    bytea,         -- ciphertext via Block 05 pgcrypto
  status                      account_status NOT NULL DEFAULT 'ACTIVE',
  created_at                  timestamptz    NOT NULL DEFAULT now(),
  updated_at                  timestamptz    NOT NULL DEFAULT now(),

  CONSTRAINT bank_accounts_pkey       PRIMARY KEY (id),
  CONSTRAINT bank_accounts_org_fk     FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT bank_accounts_business_fk FOREIGN KEY (business_id) REFERENCES business_entities(id) ON DELETE RESTRICT
);

CREATE INDEX idx_bank_accounts_business_id ON bank_accounts (business_id);
CREATE INDEX idx_bank_accounts_org_status  ON bank_accounts (organization_id, status);
```

Notes: Both `organization_id` and `business_id` present; RLS uses both per `rls_policy_template`. Encrypted columns are `bytea` holding Vault-key ciphertext — Block 05 owns encryption. No `deleted_at`; bank accounts are business data per `soft_delete_vs_status_policy`. Mobile clients are rejected at this surface per `mobile_write_rejection_endpoints`.

Audit events: `TENANCY_BANK_ACCOUNT_ADDED` (LOW), `TENANCY_BANK_ACCOUNT_DEACTIVATED` on → INACTIVE (MEDIUM).

---

## Table: `organization_users`

```sql
CREATE TABLE organization_users (
  id              uuid        NOT NULL DEFAULT gen_uuid_v7(),
  organization_id uuid        NOT NULL,
  user_id         uuid        NOT NULL,
  joined_at       timestamptz NOT NULL DEFAULT now(),
  status          account_status NOT NULL DEFAULT 'ACTIVE',
  deleted_at      timestamptz,  -- removal from org (GDPR-adjacent; kept for audit trail)
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT organization_users_pkey    PRIMARY KEY (id),
  CONSTRAINT organization_users_org_fk  FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT organization_users_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,
  CONSTRAINT organization_users_unique  UNIQUE (organization_id, user_id)
);

CREATE INDEX idx_org_users_org_id  ON organization_users (organization_id, status);
CREATE INDEX idx_org_users_user_id ON organization_users (user_id);
```

Notes: `deleted_at` marks hard removal (Owner/Admin); retained for audit trail. RLS filters via `deleted_at IS NULL`. `status` handles suspension without full removal.

Audit events: `INVITATION_ACCEPTED` on creation (LOW), `TENANCY_MEMBER_REMOVED` on `deleted_at` set (MEDIUM).

---

## Table: `business_user_roles`

```sql
CREATE TABLE business_user_roles (
  id           uuid        NOT NULL DEFAULT gen_uuid_v7(),
  organization_id uuid     NOT NULL,
  business_id  uuid        NOT NULL,
  user_id      uuid        NOT NULL,
  role         user_role   NOT NULL,
  assigned_at  timestamptz NOT NULL DEFAULT now(),
  assigned_by  uuid        NOT NULL,  -- FK to users(id)
  status       account_status NOT NULL DEFAULT 'ACTIVE',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT business_user_roles_pkey       PRIMARY KEY (id),
  CONSTRAINT business_user_roles_org_fk     FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT business_user_roles_business_fk FOREIGN KEY (business_id) REFERENCES business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT business_user_roles_user_fk    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,
  CONSTRAINT business_user_roles_assigner_fk FOREIGN KEY (assigned_by) REFERENCES users(id) ON DELETE RESTRICT,
  CONSTRAINT business_user_roles_unique     UNIQUE (business_id, user_id)
  -- one active role per (user, business) pair; status = 'INACTIVE' for historical rows
);

CREATE INDEX idx_bur_business_user ON business_user_roles (business_id, user_id, status);
CREATE INDEX idx_bur_org_id        ON business_user_roles (organization_id);
CREATE INDEX idx_bur_user_id       ON business_user_roles (user_id, status);
```

Notes: UNIQUE on `(business_id, user_id)`; role changes create a new row and set the prior row to `status = 'INACTIVE'` — historical rows are retained. `assigned_by` captures the granting principal. `auth.can_perform()` reads this table per `permission_matrix`. Mobile clients are rejected at write surfaces per `mobile_write_rejection_endpoints`.

Audit events: `TENANCY_ROLE_GRANTED` (LOW), `TENANCY_ROLE_CHANGED` (MEDIUM), `TENANCY_ROLE_REVOKED` on → INACTIVE (MEDIUM).

---

## RLS note

All six tables have RLS enabled via `ALTER TABLE <table> ENABLE ROW LEVEL SECURITY`. The policy SQL templates are defined in `rls_policy_template`. The helper functions (`current_org()`, `current_user_businesses()`, `current_user_role()`) are defined in `rls_helper_functions`. No table is accessible to unauthenticated Postgres roles except via the service-role key (internal tooling only; not exposed via the API gateway).

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PKs, SHA-256 hex encoding, canonical JSON
- `audit_log_policies` — event naming convention (`TENANCY_*`, `GDPR_*`, `INVITATION_*` domains)
- `audit_event_taxonomy` — canonical event catalogue; all events emitted here must appear there
- `rls_policy_template` — SELECT/INSERT/UPDATE/DELETE policy SQL using these column names
- `rls_helper_functions` — `current_org()`, `current_user_businesses()`, `current_user_role()`
- `soft_delete_vs_status_policy` — when to use `deleted_at` vs `status` ENUM
- `permission_matrix` — `business_user_roles` is the storage layer for the permission matrix
- `Docs/phases/02_tenancy_and_access/01_schema_scaffolding.md` — phase that instantiates these tables
- `Docs/phases/02_tenancy_and_access/05_row_level_security_policies.md` — RLS phase
