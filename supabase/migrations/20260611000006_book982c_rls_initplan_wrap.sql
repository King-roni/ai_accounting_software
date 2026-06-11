-- =============================================================================
-- BOOK-982 (c) — wrap auth.uid()/current_setting() in RLS policies (initplan).
-- =============================================================================
-- The performance advisor (auth_rls_initplan) flags policies that call auth.uid()
-- or current_setting() directly in their USING/WITH CHECK expression: the planner
-- re-evaluates them once per row. Wrapping the call in a scalar subquery,
-- (select auth.uid()), makes Postgres treat it as an InitPlan evaluated ONCE per
-- query. The functions are STABLE, so this is semantically identical — only the
-- evaluation count changes.
--
-- Applied via ALTER POLICY (expression only; name / command / roles / permissive
-- are untouched), so there is no risk of altering who the policy grants to. The
-- whole block is one transaction: if any rewritten expression fails to re-parse,
-- nothing changes. Verified after: tenant-isolation impersonation still scopes
-- per-caller, and the advisor reports 0 auth_rls_initplan.
-- =============================================================================

DO $$
DECLARE r record; v_using text; v_check text;
BEGIN
  FOR r IN
    SELECT n.nspname AS sch, c.relname AS tbl, p.polname,
           pg_get_expr(p.polqual, p.polrelid)      AS q,
           pg_get_expr(p.polwithcheck, p.polrelid) AS w
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public','audit','archive','keys','analytics','secrets','auth_runtime')
      AND (COALESCE(pg_get_expr(p.polqual, p.polrelid),'')      ~ 'auth\.uid\(\)|current_setting\('
        OR COALESCE(pg_get_expr(p.polwithcheck, p.polrelid),'') ~ 'auth\.uid\(\)|current_setting\(')
      -- case-insensitive: Postgres deparses the wrap as uppercase "( SELECT …)",
      -- so guard with !~* to keep this migration idempotent on re-run/replay.
      AND COALESCE(pg_get_expr(p.polqual, p.polrelid),'')      !~* '\(\s*select\s+(auth\.uid|current_setting)'
      AND COALESCE(pg_get_expr(p.polwithcheck, p.polrelid),'') !~* '\(\s*select\s+(auth\.uid|current_setting)'
  LOOP
    v_using := r.q;
    v_check := r.w;
    IF v_using IS NOT NULL THEN
      v_using := replace(v_using, 'auth.uid()', '(select auth.uid())');
      v_using := regexp_replace(v_using, 'current_setting\(([^)]*)\)', '(select current_setting(\1))', 'g');
    END IF;
    IF v_check IS NOT NULL THEN
      v_check := replace(v_check, 'auth.uid()', '(select auth.uid())');
      v_check := regexp_replace(v_check, 'current_setting\(([^)]*)\)', '(select current_setting(\1))', 'g');
    END IF;
    IF v_using IS NOT NULL AND v_check IS NOT NULL THEN
      EXECUTE format('ALTER POLICY %I ON %I.%I USING (%s) WITH CHECK (%s)', r.polname, r.sch, r.tbl, v_using, v_check);
    ELSIF v_using IS NOT NULL THEN
      EXECUTE format('ALTER POLICY %I ON %I.%I USING (%s)', r.polname, r.sch, r.tbl, v_using);
    ELSE
      EXECUTE format('ALTER POLICY %I ON %I.%I WITH CHECK (%s)', r.polname, r.sch, r.tbl, v_check);
    END IF;
  END LOOP;
END $$;
