-- =============================================================================
-- Pretest readiness fix (2026-06-01) — REQUIRE_STEP_UP stale-vocab sweep (H1)
-- =============================================================================
-- 8 SECURITY DEFINER RPCs guard with `v_perm_dec NOT IN ('ALLOW','STEP_UP')`
-- and reject otherwise. The permission_matrix vocab is {ALLOW, DENY,
-- REQUIRE_STEP_UP} — there is no bare 'STEP_UP'. So when can_perform returns
-- REQUIRE_STEP_UP these RPCs wrongly reject ("unexpected can_perform
-- decision"). transition_run / out|in_workflow_user_approval already use the
-- correct `NOT IN ('ALLOW','STEP_UP','REQUIRE_STEP_UP')` form.
--
-- Affected: request_statement_upload (active-but-orphaned), activate_redaction_policy,
-- deploy_prompt, rollback_prompt, register_prompt, grant_cost_ceiling_override,
-- update_business_ai_config, update_business_cost_ceiling (latent).
--
-- Rather than transcribe 8 large bodies (error-prone), rewrite each in place:
-- fetch pg_get_functiondef, replace the single guard literal, re-create. Each
-- body has exactly one occurrence (verified). Aborts if the pattern is missing
-- (signature drift) and asserts zero stale occurrences remain across public.*.
-- =============================================================================

DO $$
DECLARE
  v_names text[] := ARRAY[
    'request_statement_upload','activate_redaction_policy','deploy_prompt','rollback_prompt',
    'register_prompt','grant_cost_ceiling_override','update_business_ai_config','update_business_cost_ceiling'];
  v_name  text;
  v_oid   oid;
  v_def   text;
  v_new   text;
  v_fixed int := 0;
  v_stale_old constant text := 'NOT IN (''ALLOW'',''STEP_UP'')';
  v_stale_new constant text := 'NOT IN (''ALLOW'',''STEP_UP'',''REQUIRE_STEP_UP'')';
BEGIN
  FOREACH v_name IN ARRAY v_names LOOP
    FOR v_oid IN
      SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_name
    LOOP
      v_def := pg_get_functiondef(v_oid);
      IF position(v_stale_old IN v_def) = 0 THEN
        RAISE EXCEPTION 'require_step_up_sweep: stale guard not found in %(%) — signature drift?', v_name, v_oid;
      END IF;
      v_new := replace(v_def, v_stale_old, v_stale_new);
      EXECUTE v_new;
      v_fixed := v_fixed + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'require_step_up_sweep: rewrote % function definition(s)', v_fixed;

  -- Regression guard: no public function may retain the stale 2-arg form.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND pg_get_functiondef(p.oid) LIKE '%NOT IN (''ALLOW'',''STEP_UP'')%'
  ) THEN
    RAISE EXCEPTION 'require_step_up_sweep: stale STEP_UP guard still present in some public function';
  END IF;
END $$;
