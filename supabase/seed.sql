-- supabase/seed.sql
--
-- Local-dev only seed. Loaded automatically by `supabase db reset` against
-- a local Supabase stack. NOT applied to staging or production
-- (per Docs/phases/02_tenancy_and_access/01_schema_scaffolding.md: "no
-- production seed") and NOT applied via the MCP apply_migration flow.
--
-- Contents: one organization + one user + one business + one bank account,
-- linked end-to-end. Lets a developer hit the operational tables with
-- realistic foreign keys without going through Supabase Auth.

-- Safety guard: refuse to run if any tenancy rows already exist. Prevents
-- accidental re-seed on a populated dev DB. Bypass with TRUNCATE first.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.organizations) THEN
    RAISE NOTICE 'seed.sql skipped: organizations table is non-empty.';
    RETURN;
  END IF;
END$$;

DO $$
DECLARE
  v_org_id      uuid;
  v_user_id     uuid;
  v_business_id uuid;
BEGIN
  -- 1. Organization
  INSERT INTO public.organizations (name)
    VALUES ('Local Dev Co')
    RETURNING id INTO v_org_id;

  -- 2. User profile (auth_user_id deliberately NULL — local-dev row not tied to a Supabase Auth user)
  INSERT INTO public.users (email, display_name, email_verified)
    VALUES ('dev@localhost.test', 'Local Dev User', true)
    RETURNING id INTO v_user_id;

  -- 3. Org membership
  INSERT INTO public.organization_users (organization_id, user_id)
    VALUES (v_org_id, v_user_id);

  -- 4. Business
  INSERT INTO public.business_entities (
    organization_id, display_name, legal_name, country_code, currency,
    timezone, fiscal_year_start_month, accounting_method,
    vat_registered, vat_number, vat_period_type,
    created_by_user_id, is_active
  ) VALUES (
    v_org_id, 'Demo Bookkeeping Ltd', 'Demo Bookkeeping Limited',
    'CY', 'EUR', 'Asia/Nicosia', 1, 'ACCRUAL',
    true, 'CY10000001L', 'QUARTERLY',
    v_user_id, true
  ) RETURNING id INTO v_business_id;

  -- 5. Owner role on that business
  INSERT INTO public.business_user_roles (
    organization_id, business_id, user_id, role, assigned_by
  ) VALUES (
    v_org_id, v_business_id, v_user_id, 'OWNER', v_user_id
  );

  -- 6. One bank account
  INSERT INTO public.bank_accounts (
    organization_id, business_id, provider, account_name, currency, masked_iban
  ) VALUES (
    v_org_id, v_business_id, 'REVOLUT', 'Operating EUR', 'EUR', '****0001'
  );

  RAISE NOTICE 'Seed complete: org=%, user=%, business=%', v_org_id, v_user_id, v_business_id;
END$$;
