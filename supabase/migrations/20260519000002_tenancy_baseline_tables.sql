-- Migration: 20260519000002_tenancy_baseline_tables
-- Ticket: Plane BOOK B02P01 (47f942ce-6812-4c19-8130-d8c2bf77ae3f)
-- Block: 02 — Tenancy & Access Control
-- Phase: 01 — Schema Scaffolding (baseline)
-- Author: stage-7-1 implementation
-- Description:
--   Instantiates the six core tenancy tables and their indexes + audit
--   triggers per:
--     - Docs/sub/schemas/tenancy_schema_definition.md (Layer-2 canonical)
--     - Docs/sub/schemas/user_schema.md
--     - Docs/sub/schemas/business_schema.md
--     - Docs/sub/policies/soft_delete_vs_status_policy.md
--     - Docs/sub/policies/data_layer_conventions_policy.md
--
-- RLS DEFERRAL (waiver of supabase_migration_tooling_policy §2.4):
--   Phase 01 explicitly defers RLS to Phase 05 ("schema is open until
--   Phase 05") per Docs/phases/02_tenancy_and_access/01_schema_scaffolding.md
--   Definition of Done. The lint rule that requires
--   "CREATE TABLE + ENABLE RLS + at least one policy in the same file" is
--   suspended for this baseline migration only. The waiver is recorded in
--   supabase/README.md. Phase 05 migrations (B02·P05) will enable RLS and
--   add the policy templates from rls_policy_template + rls_helper_functions.
--
-- Lifecycle pattern notes (per soft_delete_vs_status_policy):
--   - organizations: org_status ENUM + deleted_at (identity record; GDPR
--     erasure pipeline)
--   - users: is_active boolean (per canonical user_schema.md; an
--     auth_user_id pointer is added for the auth.users link required by
--     the phase doc; users are never hard-deleted by application code)
--   - business_entities: is_active boolean (per canonical business_schema.md)
--   - bank_accounts: account_status ENUM (business data; no deleted_at)
--   - organization_users: account_status ENUM + deleted_at (identity-adjacent)
--   - business_user_roles: account_status ENUM (role-history rows retained
--     as INACTIVE; no deleted_at)

------------------------------------------------------------------------
-- Table: organizations
------------------------------------------------------------------------

CREATE TABLE public.organizations (
  id          uuid        NOT NULL DEFAULT public.gen_uuid_v7(),
  name        text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 255),
  status      public.org_status NOT NULL DEFAULT 'ACTIVE',
  deleted_at  timestamptz,        -- GDPR erasure marker; null until pipeline fires
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT organizations_pkey PRIMARY KEY (id)
);

CREATE INDEX idx_organizations_status     ON public.organizations (status);
CREATE INDEX idx_organizations_deleted_at ON public.organizations (deleted_at)
  WHERE deleted_at IS NOT NULL;

CREATE TRIGGER organizations_set_updated_at
  BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.organizations IS
  'Top-level tenancy entity. One organization owns one or more business_entities.';


------------------------------------------------------------------------
-- Table: users (profile extension of auth.users)
------------------------------------------------------------------------

CREATE TABLE public.users (
  id                uuid        NOT NULL DEFAULT public.gen_uuid_v7(),
  auth_user_id      uuid,                                       -- FK target is auth.users(id) but no hard FK across schemas
  email             text        NOT NULL,
  email_verified    boolean     NOT NULL DEFAULT false,
  email_verified_at timestamptz,
  display_name      text        CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 255),
  avatar_url        text,
  is_active         boolean     NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT users_pkey                PRIMARY KEY (id),
  CONSTRAINT users_email_unique        UNIQUE (email),
  CONSTRAINT users_auth_user_id_unique UNIQUE (auth_user_id)
);

-- Partial index for the common active-user lookup path.
CREATE INDEX idx_users_is_active ON public.users (id) WHERE is_active = true;

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.users IS
  'Platform-level user profile. Extends auth.users via auth_user_id. No password column — credentials are Supabase Auth-managed.';
COMMENT ON COLUMN public.users.auth_user_id IS
  'Pointer to auth.users(id). No hard FK across schemas (Supabase convention); uniqueness enforced. Populated by signup hook in Phase 02.';


------------------------------------------------------------------------
-- Table: business_entities
------------------------------------------------------------------------

CREATE TABLE public.business_entities (
  id                          uuid        NOT NULL DEFAULT public.gen_uuid_v7(),
  organization_id             uuid        NOT NULL,
  display_name                text        NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 255),
  legal_name                  text        CHECK (legal_name IS NULL OR char_length(legal_name) BETWEEN 1 AND 512),
  company_registration_number text,
  vat_number                  text,
  tax_authority_identifier    text,
  country_code                char(2)     NOT NULL DEFAULT 'CY' CHECK (country_code ~ '^[A-Z]{2}$'),
  currency                    char(3)     NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
  timezone                    text        NOT NULL DEFAULT 'Asia/Nicosia',
  fiscal_year_start_month     integer     NOT NULL DEFAULT 1
    CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  accounting_method           public.accounting_method NOT NULL DEFAULT 'ACCRUAL',
  vat_registered              boolean     NOT NULL DEFAULT false,
  vat_registration_date       date,
  vat_period_type             public.vat_period_type,
  created_by_user_id          uuid,
  is_active                   boolean     NOT NULL DEFAULT true,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT business_entities_pkey       PRIMARY KEY (id),
  CONSTRAINT business_entities_org_fk     FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT business_entities_creator_fk FOREIGN KEY (created_by_user_id)
    REFERENCES public.users(id) ON DELETE SET NULL
);

CREATE INDEX idx_business_entities_org_id          ON public.business_entities (organization_id);
CREATE INDEX idx_business_entities_org_is_active   ON public.business_entities (organization_id, is_active);
CREATE INDEX idx_business_entities_created_by      ON public.business_entities (created_by_user_id) WHERE created_by_user_id IS NOT NULL;

-- Platform-wide unique VAT number (allows multiple NULLs).
CREATE UNIQUE INDEX idx_business_entities_vat_number
  ON public.business_entities (vat_number)
  WHERE vat_number IS NOT NULL;

CREATE TRIGGER business_entities_set_updated_at
  BEFORE UPDATE ON public.business_entities
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.business_entities IS
  'Primary operational tenant unit. Application-layer alias: businesses. Carries Cyprus jurisdiction + fiscal config.';
COMMENT ON COLUMN public.business_entities.accounting_method IS
  'MVP locks to ACCRUAL (Stage 1 decision). ENUM shape preserves room for CASH post-MVP.';


------------------------------------------------------------------------
-- Table: bank_accounts
------------------------------------------------------------------------

CREATE TABLE public.bank_accounts (
  id                       uuid         NOT NULL DEFAULT public.gen_uuid_v7(),
  organization_id          uuid         NOT NULL,
  business_id              uuid         NOT NULL,
  provider                 text         NOT NULL,       -- e.g. 'REVOLUT', 'ALPHA_BANK'
  account_name             text         NOT NULL,
  currency                 char(3)      NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
  masked_iban              text,                        -- last 4 chars for UI; no sensitive data
  iban_encrypted           bytea,                       -- Block 05 pgcrypto ciphertext; NULL until B05 lands
  account_number_encrypted bytea,                       -- Block 05 pgcrypto ciphertext
  status                   public.account_status NOT NULL DEFAULT 'ACTIVE',
  created_at               timestamptz  NOT NULL DEFAULT now(),
  updated_at               timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT bank_accounts_pkey         PRIMARY KEY (id),
  CONSTRAINT bank_accounts_org_fk       FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT bank_accounts_business_fk  FOREIGN KEY (business_id)
    REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE INDEX idx_bank_accounts_business_id     ON public.bank_accounts (business_id);
CREATE INDEX idx_bank_accounts_org_status      ON public.bank_accounts (organization_id, status);
CREATE INDEX idx_bank_accounts_business_status ON public.bank_accounts (business_id, status);

CREATE TRIGGER bank_accounts_set_updated_at
  BEFORE UPDATE ON public.bank_accounts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.bank_accounts IS
  'Bank account registered against a business. iban_encrypted + account_number_encrypted carry Block-05 pgcrypto ciphertext once B05 lands.';


------------------------------------------------------------------------
-- Table: organization_users (membership join)
------------------------------------------------------------------------

CREATE TABLE public.organization_users (
  id              uuid        NOT NULL DEFAULT public.gen_uuid_v7(),
  organization_id uuid        NOT NULL,
  user_id         uuid        NOT NULL,
  joined_at       timestamptz NOT NULL DEFAULT now(),
  status          public.account_status NOT NULL DEFAULT 'ACTIVE',
  deleted_at      timestamptz,    -- hard removal marker (identity-adjacent; GDPR pipeline)
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT organization_users_pkey      PRIMARY KEY (id),
  CONSTRAINT organization_users_org_fk    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT organization_users_user_fk   FOREIGN KEY (user_id)
    REFERENCES public.users(id) ON DELETE RESTRICT,
  CONSTRAINT organization_users_unique    UNIQUE (organization_id, user_id)
);

CREATE INDEX idx_org_users_org_id_status ON public.organization_users (organization_id, status);
CREATE INDEX idx_org_users_user_id       ON public.organization_users (user_id);
CREATE INDEX idx_org_users_deleted_at    ON public.organization_users (deleted_at)
  WHERE deleted_at IS NOT NULL;

CREATE TRIGGER organization_users_set_updated_at
  BEFORE UPDATE ON public.organization_users
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.organization_users IS
  'User membership in an organization. Dual lifecycle pattern: status for suspension, deleted_at for hard removal (audit-trail retained).';


------------------------------------------------------------------------
-- Table: business_user_roles (per-business role assignment)
------------------------------------------------------------------------

CREATE TABLE public.business_user_roles (
  id              uuid        NOT NULL DEFAULT public.gen_uuid_v7(),
  organization_id uuid        NOT NULL,
  business_id     uuid        NOT NULL,
  user_id         uuid        NOT NULL,
  role            public.user_role NOT NULL,
  assigned_at     timestamptz NOT NULL DEFAULT now(),
  assigned_by     uuid        NOT NULL,
  status          public.account_status NOT NULL DEFAULT 'ACTIVE',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT business_user_roles_pkey        PRIMARY KEY (id),
  CONSTRAINT business_user_roles_org_fk      FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT business_user_roles_business_fk FOREIGN KEY (business_id)
    REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT business_user_roles_user_fk     FOREIGN KEY (user_id)
    REFERENCES public.users(id) ON DELETE RESTRICT,
  CONSTRAINT business_user_roles_assigner_fk FOREIGN KEY (assigned_by)
    REFERENCES public.users(id) ON DELETE RESTRICT
);

-- One ACTIVE role per (business, user). Historical INACTIVE rows are retained;
-- the partial unique index allows that.
CREATE UNIQUE INDEX idx_bur_business_user_active
  ON public.business_user_roles (business_id, user_id)
  WHERE status = 'ACTIVE';

CREATE INDEX idx_bur_business_user_status ON public.business_user_roles (business_id, user_id, status);
CREATE INDEX idx_bur_org_id               ON public.business_user_roles (organization_id);
CREATE INDEX idx_bur_user_id_status       ON public.business_user_roles (user_id, status);

CREATE TRIGGER business_user_roles_set_updated_at
  BEFORE UPDATE ON public.business_user_roles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.business_user_roles IS
  'Per-business role assignment. Role changes create a new ACTIVE row and flip the prior row to INACTIVE; history retained for audit.';
