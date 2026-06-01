-- =============================================================================
-- Pretest readiness (2026-06-01) — REQUIRE_STEP_UP regression sentinel (H1 guard)
-- =============================================================================
-- list_stale_step_up_guard_functions() returns the name of any public function
-- whose body still guards with the stale 2-arg `NOT IN ('ALLOW','STEP_UP')`
-- form (missing 'REQUIRE_STEP_UP'). After 20260601000012 this must be empty.
-- api/tests/test_step_up_vocab_guard.py calls it (service role) and asserts so,
-- catching any NEW function that reintroduces the bug. Excludes itself (its body
-- contains the search pattern as a string literal). EXECUTE restricted off PUBLIC.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.list_stale_step_up_guard_functions()
 RETURNS TABLE(function_name text)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog', 'pg_temp'
AS $$
  SELECT p.proname::text
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname <> 'list_stale_step_up_guard_functions'
    AND pg_get_functiondef(p.oid) LIKE '%NOT IN (''ALLOW'',''STEP_UP'')%'
  ORDER BY 1;
$$;

REVOKE ALL ON FUNCTION public.list_stale_step_up_guard_functions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_stale_step_up_guard_functions() TO service_role;
