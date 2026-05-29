-- ============================================================================
-- B02·P05 Row-Level Security baseline
-- ============================================================================
-- Implements the three-layer isolation contract at the database layer:
--   1. Helper functions extracting principal context (current_org,
--      current_user_id, current_user_businesses, current_user_role).
--   2. Postgres mirror of the B02·P04 (15 surface × 6 role) permission matrix.
--   3. ENABLE + FORCE ROW LEVEL SECURITY on every tenant-scoped table, with
--      policies derived from rls_policy_template.md.
--
-- Recursion-safety note: each helper is SECURITY DEFINER with a locked
-- search_path. The sub-doc rls_helper_functions.md prefers SECURITY INVOKER
-- on a privilege-escalation concern, but each function body is hard-locked
-- to current-user-only lookups (filters by auth.uid() or by current_user_id()),
-- so it can never enumerate another user's rows even when executed with the
-- function-owner's privileges. The DEFINER posture is what lets RLS policies
-- on users / business_user_roles / organization_users call these helpers
-- without recursive policy evaluation.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Helper: current_org()
-- Canonical: read `org_id` from the Supabase JWT claim populated by an Auth
-- hook (deferred to B02·P09). Fallback for MVP / pre-hook deployments: look
-- up the single ACTIVE organization the auth user belongs to. Returns NULL
-- if neither is available — every RLS policy using it then denies rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_org()
  RETURNS uuid
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, auth, pg_temp
AS $$
  -- NULLIF the raw setting BEFORE the jsonb cast so empty claims short-circuit
  -- safely (''::jsonb raises). NULLIF on the extracted value also handles an
  -- explicit empty-string org_id in the claim.
  SELECT COALESCE(
    NULLIF(
      NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'org_id',
      ''
    )::uuid,
    (
      SELECT ou.organization_id
      FROM public.organization_users ou
      JOIN public.users u ON u.id = ou.user_id
      WHERE u.auth_user_id = auth.uid()
        AND ou.status = 'ACTIVE'
        AND ou.deleted_at IS NULL
      ORDER BY ou.joined_at ASC
      LIMIT 1
    )
  );
$$;

-- ---------------------------------------------------------------------------
-- Helper: current_user_id() — internal public.users.id (not auth.users.id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_user_id()
  RETURNS uuid
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, auth, pg_temp
AS $$
  SELECT u.id
  FROM public.users u
  WHERE u.auth_user_id = auth.uid()
    AND u.is_active = true
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Helper: current_user_businesses() — uuid[] of business_ids the caller has
-- an ACTIVE role on within their current org. NULL when the user has no
-- memberships; `business_id = ANY(NULL)` evaluates to NULL (denial) which
-- is the safe default.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_user_businesses()
  RETURNS uuid[]
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, auth, pg_temp
AS $$
  SELECT array_agg(bur.business_id)
  FROM public.business_user_roles bur
  JOIN public.users u ON u.id = bur.user_id
  WHERE u.auth_user_id = auth.uid()
    AND bur.organization_id = public.current_org()
    AND bur.status = 'ACTIVE';
$$;

-- ---------------------------------------------------------------------------
-- Helper: current_user_role(business_id) — active role on the given
-- business or NULL. Used in WITH CHECK clauses to gate writes by role.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_user_role(p_business_id uuid)
  RETURNS public.user_role
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, auth, pg_temp
AS $$
  SELECT bur.role
  FROM public.business_user_roles bur
  JOIN public.users u ON u.id = bur.user_id
  WHERE u.auth_user_id = auth.uid()
    AND bur.business_id = p_business_id
    AND bur.organization_id = public.current_org()
    AND bur.status = 'ACTIVE'
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.current_org() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_businesses() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_role(uuid) TO authenticated;

-- ===========================================================================
-- Permission matrix mirror (canonical source: B02·P04 Python access module)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.permission_matrix (
  role     public.user_role NOT NULL,
  surface  text             NOT NULL,
  decision text             NOT NULL CHECK (decision IN ('ALLOW', 'DENY', 'REQUIRE_STEP_UP')),
  PRIMARY KEY (role, surface)
);

-- Seed the matrix verbatim from
-- api/src/cyprus_bookkeeping_api/access/matrix.py. A pytest parity check
-- asserts Postgres and Python stay in sync; changing one without the other
-- fails CI.
TRUNCATE TABLE public.permission_matrix;
INSERT INTO public.permission_matrix (role, surface, decision) VALUES
  ('OWNER',      'SESSION_MANAGE',           'ALLOW'),
  ('ADMIN',      'SESSION_MANAGE',           'ALLOW'),
  ('BOOKKEEPER', 'SESSION_MANAGE',           'ALLOW'),
  ('ACCOUNTANT', 'SESSION_MANAGE',           'ALLOW'),
  ('REVIEWER',   'SESSION_MANAGE',           'ALLOW'),
  ('READ_ONLY',  'SESSION_MANAGE',           'ALLOW'),
  ('OWNER',      'USER_INVITE',              'ALLOW'),
  ('ADMIN',      'USER_INVITE',              'ALLOW'),
  ('BOOKKEEPER', 'USER_INVITE',              'DENY'),
  ('ACCOUNTANT', 'USER_INVITE',              'DENY'),
  ('REVIEWER',   'USER_INVITE',              'DENY'),
  ('READ_ONLY',  'USER_INVITE',              'DENY'),
  ('OWNER',      'BUSINESS_SETTINGS_EDIT',   'ALLOW'),
  ('ADMIN',      'BUSINESS_SETTINGS_EDIT',   'ALLOW'),
  ('BOOKKEEPER', 'BUSINESS_SETTINGS_EDIT',   'DENY'),
  ('ACCOUNTANT', 'BUSINESS_SETTINGS_EDIT',   'DENY'),
  ('REVIEWER',   'BUSINESS_SETTINGS_EDIT',   'DENY'),
  ('READ_ONLY',  'BUSINESS_SETTINGS_EDIT',   'DENY'),
  ('OWNER',      'EXTERNAL_INTEGRATION',     'ALLOW'),
  ('ADMIN',      'EXTERNAL_INTEGRATION',     'ALLOW'),
  ('BOOKKEEPER', 'EXTERNAL_INTEGRATION',     'DENY'),
  ('ACCOUNTANT', 'EXTERNAL_INTEGRATION',     'DENY'),
  ('REVIEWER',   'EXTERNAL_INTEGRATION',     'DENY'),
  ('READ_ONLY',  'EXTERNAL_INTEGRATION',     'DENY'),
  ('OWNER',      'WORKFLOW_TRIGGER',         'ALLOW'),
  ('ADMIN',      'WORKFLOW_TRIGGER',         'ALLOW'),
  ('BOOKKEEPER', 'WORKFLOW_TRIGGER',         'ALLOW'),
  ('ACCOUNTANT', 'WORKFLOW_TRIGGER',         'DENY'),
  ('REVIEWER',   'WORKFLOW_TRIGGER',         'DENY'),
  ('READ_ONLY',  'WORKFLOW_TRIGGER',         'DENY'),
  ('OWNER',      'WORKFLOW_APPROVE',         'ALLOW'),
  ('ADMIN',      'WORKFLOW_APPROVE',         'ALLOW'),
  ('BOOKKEEPER', 'WORKFLOW_APPROVE',         'DENY'),
  ('ACCOUNTANT', 'WORKFLOW_APPROVE',         'DENY'),
  ('REVIEWER',   'WORKFLOW_APPROVE',         'DENY'),
  ('READ_ONLY',  'WORKFLOW_APPROVE',         'DENY'),
  ('OWNER',      'FINALIZATION',             'REQUIRE_STEP_UP'),
  ('ADMIN',      'FINALIZATION',             'REQUIRE_STEP_UP'),
  ('BOOKKEEPER', 'FINALIZATION',             'DENY'),
  ('ACCOUNTANT', 'FINALIZATION',             'DENY'),
  ('REVIEWER',   'FINALIZATION',             'DENY'),
  ('READ_ONLY',  'FINALIZATION',             'DENY'),
  ('OWNER',      'REVIEW_QUEUE_VIEW',        'ALLOW'),
  ('ADMIN',      'REVIEW_QUEUE_VIEW',        'ALLOW'),
  ('BOOKKEEPER', 'REVIEW_QUEUE_VIEW',        'ALLOW'),
  ('ACCOUNTANT', 'REVIEW_QUEUE_VIEW',        'ALLOW'),
  ('REVIEWER',   'REVIEW_QUEUE_VIEW',        'ALLOW'),
  ('READ_ONLY',  'REVIEW_QUEUE_VIEW',        'ALLOW'),
  ('OWNER',      'REVIEW_QUEUE_RESOLVE',     'ALLOW'),
  ('ADMIN',      'REVIEW_QUEUE_RESOLVE',     'ALLOW'),
  ('BOOKKEEPER', 'REVIEW_QUEUE_RESOLVE',     'ALLOW'),
  ('ACCOUNTANT', 'REVIEW_QUEUE_RESOLVE',     'ALLOW'),
  ('REVIEWER',   'REVIEW_QUEUE_RESOLVE',     'DENY'),
  ('READ_ONLY',  'REVIEW_QUEUE_RESOLVE',     'DENY'),
  ('OWNER',      'REVIEW_ASSIGN',            'ALLOW'),
  ('ADMIN',      'REVIEW_ASSIGN',            'ALLOW'),
  ('BOOKKEEPER', 'REVIEW_ASSIGN',            'DENY'),
  ('ACCOUNTANT', 'REVIEW_ASSIGN',            'DENY'),
  ('REVIEWER',   'REVIEW_ASSIGN',            'DENY'),
  ('READ_ONLY',  'REVIEW_ASSIGN',            'DENY'),
  ('OWNER',      'REVIEW_REGENERATE',        'ALLOW'),
  ('ADMIN',      'REVIEW_REGENERATE',        'ALLOW'),
  ('BOOKKEEPER', 'REVIEW_REGENERATE',        'DENY'),
  ('ACCOUNTANT', 'REVIEW_REGENERATE',        'DENY'),
  ('REVIEWER',   'REVIEW_REGENERATE',        'DENY'),
  ('READ_ONLY',  'REVIEW_REGENERATE',        'DENY'),
  ('OWNER',      'REPORT_EXPORT_BASIC',      'ALLOW'),
  ('ADMIN',      'REPORT_EXPORT_BASIC',      'ALLOW'),
  ('BOOKKEEPER', 'REPORT_EXPORT_BASIC',      'ALLOW'),
  ('ACCOUNTANT', 'REPORT_EXPORT_BASIC',      'ALLOW'),
  ('REVIEWER',   'REPORT_EXPORT_BASIC',      'DENY'),
  ('READ_ONLY',  'REPORT_EXPORT_BASIC',      'DENY'),
  ('OWNER',      'REPORT_EXPORT_FULL',       'ALLOW'),
  ('ADMIN',      'REPORT_EXPORT_FULL',       'ALLOW'),
  ('BOOKKEEPER', 'REPORT_EXPORT_FULL',       'DENY'),
  ('ACCOUNTANT', 'REPORT_EXPORT_FULL',       'ALLOW'),
  ('REVIEWER',   'REPORT_EXPORT_FULL',       'DENY'),
  ('READ_ONLY',  'REPORT_EXPORT_FULL',       'DENY'),
  ('OWNER',      'DASHBOARD_VIEW',           'ALLOW'),
  ('ADMIN',      'DASHBOARD_VIEW',           'ALLOW'),
  ('BOOKKEEPER', 'DASHBOARD_VIEW',           'ALLOW'),
  ('ACCOUNTANT', 'DASHBOARD_VIEW',           'ALLOW'),
  ('REVIEWER',   'DASHBOARD_VIEW',           'ALLOW'),
  ('READ_ONLY',  'DASHBOARD_VIEW',           'ALLOW'),
  ('OWNER',      'DASHBOARD_REFRESH_MANUAL', 'ALLOW'),
  ('ADMIN',      'DASHBOARD_REFRESH_MANUAL', 'ALLOW'),
  ('BOOKKEEPER', 'DASHBOARD_REFRESH_MANUAL', 'ALLOW'),
  ('ACCOUNTANT', 'DASHBOARD_REFRESH_MANUAL', 'ALLOW'),
  ('REVIEWER',   'DASHBOARD_REFRESH_MANUAL', 'ALLOW'),
  ('READ_ONLY',  'DASHBOARD_REFRESH_MANUAL', 'ALLOW');

-- Sanity check: 15 surfaces × 6 roles = 90 rows.
DO $check$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM public.permission_matrix;
  IF n <> 90 THEN
    RAISE EXCEPTION 'permission_matrix seed mismatch: expected 90, got %', n;
  END IF;
END;
$check$;

CREATE OR REPLACE FUNCTION public.has_permission(
  p_role public.user_role,
  p_surface text
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.permission_matrix
    WHERE role = p_role
      AND surface = p_surface
      AND decision IN ('ALLOW', 'REQUIRE_STEP_UP')
  );
$$;

GRANT SELECT ON public.permission_matrix TO authenticated;
REVOKE EXECUTE ON FUNCTION public.has_permission(public.user_role, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.has_permission(public.user_role, text) TO authenticated;
ALTER  FUNCTION public.has_permission(public.user_role, text) SET search_path = public, pg_temp;

-- Helper grants: revoke default PUBLIC execute so anon can't elicit role
-- context via REST RPC; re-grant to authenticated only.
REVOKE EXECUTE ON FUNCTION public.current_org()             FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.current_user_id()         FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.current_user_businesses() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.current_user_role(uuid)   FROM PUBLIC, anon;

-- Lock the matrix from authenticated writes (only postgres / service_role can change it).
ALTER TABLE public.permission_matrix ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permission_matrix FORCE ROW LEVEL SECURITY;
CREATE POLICY permission_matrix_select_all ON public.permission_matrix
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY permission_matrix_no_write ON public.permission_matrix
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY permission_matrix_no_update ON public.permission_matrix
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY permission_matrix_no_delete ON public.permission_matrix
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ===========================================================================
-- Enable RLS on all tenant-scoped tables
-- ===========================================================================
ALTER TABLE public.organizations         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organizations         FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.users                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users                 FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.business_entities     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_entities     FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts         FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.organization_users    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_users    FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.business_user_roles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_user_roles   FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.mfa_recovery_codes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mfa_recovery_codes    FORCE  ROW LEVEL SECURITY;

-- ===========================================================================
-- Policies
-- All writes default to RESTRICTIVE false unless explicitly granted, per the
-- "DENY ALL by default" guard from the phase DoD.
-- ===========================================================================

-- ---- organizations: org-scoped (id IS the organization_id) ----------------
CREATE POLICY organizations_select ON public.organizations
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (id = public.current_org() AND deleted_at IS NULL);
CREATE POLICY organizations_no_insert ON public.organizations
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY organizations_no_update ON public.organizations
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY organizations_no_delete ON public.organizations
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- users: own row + co-members of current org --------------------------
CREATE POLICY users_select ON public.users
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    auth_user_id = auth.uid()
    OR id IN (
      SELECT ou.user_id
      FROM public.organization_users ou
      WHERE ou.organization_id = public.current_org()
        AND ou.status = 'ACTIVE'
        AND ou.deleted_at IS NULL
    )
  );
CREATE POLICY users_update_self ON public.users
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (auth_user_id = auth.uid())
  WITH CHECK (auth_user_id = auth.uid());
CREATE POLICY users_no_insert ON public.users
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY users_no_delete ON public.users
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- business_entities: id IS the business_id ----------------------------
CREATE POLICY business_entities_select ON public.business_entities
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND id = ANY(public.current_user_businesses())
  );
CREATE POLICY business_entities_update ON public.business_entities
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (
    organization_id = public.current_org()
    AND id = ANY(public.current_user_businesses())
    AND public.current_user_role(id) IN ('OWNER', 'ADMIN')
  )
  WITH CHECK (
    organization_id = public.current_org()
    AND id = ANY(public.current_user_businesses())
    AND public.current_user_role(id) IN ('OWNER', 'ADMIN')
  );
-- INSERT can't pre-check role on the not-yet-created business — service-role only.
CREATE POLICY business_entities_no_insert ON public.business_entities
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY business_entities_no_delete ON public.business_entities
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- bank_accounts: business-scoped --------------------------------------
CREATE POLICY bank_accounts_select ON public.bank_accounts
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY bank_accounts_insert ON public.bank_accounts
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
    AND public.current_user_role(business_id) IN ('OWNER', 'ADMIN')
  );
CREATE POLICY bank_accounts_update ON public.bank_accounts
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  )
  WITH CHECK (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
    AND public.current_user_role(business_id) IN ('OWNER', 'ADMIN')
  );
CREATE POLICY bank_accounts_no_delete ON public.bank_accounts
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- organization_users: org-scoped --------------------------------------
CREATE POLICY organization_users_select ON public.organization_users
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND deleted_at IS NULL
  );
CREATE POLICY organization_users_no_insert ON public.organization_users
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY organization_users_no_update ON public.organization_users
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY organization_users_no_delete ON public.organization_users
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- business_user_roles: own rows only (inline check breaks recursion) --
CREATE POLICY business_user_roles_select_self ON public.business_user_roles
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND user_id = public.current_user_id()
  );
CREATE POLICY business_user_roles_no_insert ON public.business_user_roles
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY business_user_roles_no_update ON public.business_user_roles
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY business_user_roles_no_delete ON public.business_user_roles
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- mfa_recovery_codes: user-scoped -------------------------------------
CREATE POLICY mfa_recovery_codes_select ON public.mfa_recovery_codes
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (user_id = public.current_user_id());
CREATE POLICY mfa_recovery_codes_insert ON public.mfa_recovery_codes
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (user_id = public.current_user_id());
-- Consumption is performed by redeem_mfa_recovery_code() which is
-- SECURITY DEFINER and bypasses RLS. No direct UPDATE/DELETE for users.
CREATE POLICY mfa_recovery_codes_no_update ON public.mfa_recovery_codes
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY mfa_recovery_codes_no_delete ON public.mfa_recovery_codes
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.permission_matrix IS
'Postgres mirror of the application permission matrix (B02·P04). Seeded by migration. The pytest parity check in api/tests/test_rls_matrix_parity.py asserts Python and Postgres stay in sync; changing one without the other fails CI.';
