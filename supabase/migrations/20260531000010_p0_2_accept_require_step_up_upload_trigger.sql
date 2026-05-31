-- P0.2 — align the upload + manual-trigger RPCs to the permission matrix vocab.
--
-- The permission_matrix uses ALLOW / DENY / REQUIRE_STEP_UP (there is no
-- 'STEP_UP'), and (OWNER|ADMIN, workflow_run) = REQUIRE_STEP_UP. But
-- complete_statement_upload (B07·P01) and trigger_run_manual (B03·P10/P11) only
-- accepted ('ALLOW','STEP_UP') and treated REQUIRE_STEP_UP as PERMISSION_DENIED
-- — so the only roles allowed to upload a statement / start a manual run were
-- exactly the ones getting denied, blocking the self-serve journey entry point.
--
-- transition_run was already fixed for this in
-- b15p04_transition_run_accept_require_step_up; this mirrors that for the
-- upload/trigger path. These two RPCs have no step-up-token channel, so
-- REQUIRE_STEP_UP simply proceeds (statement upload + manual run-start are
-- routine ingestion; step-up stays enforced on the sensitive transition_run
-- actions such as finalize/abort, which DO take p_step_up_verified).
--
-- Applied as an in-place source transform to avoid hand-transcribing the large
-- function bodies: fetch the live definition, add 'REQUIRE_STEP_UP' to the
-- single perm-check IN-list, re-create. Idempotent (the closing-paren pattern
-- no longer matches once the third value is present).
--
-- FOLLOW-UP: ~9 other RPCs still check IN ('ALLOW','STEP_UP') (B03/B06/B07/B11).
-- They need a dedicated, per-RPC-classified authz sweep — some enforce step-up
-- via a token param and must KEEP enforcing it, so a blind replace is unsafe.

DO $do$
DECLARE v_src text;
BEGIN
  v_src := pg_get_functiondef('public.complete_statement_upload(uuid,uuid,uuid,text,text,statement_file_format_enum,text,date,date,text)'::regprocedure);
  v_src := replace(v_src, 'v_perm_dec NOT IN (''ALLOW'',''STEP_UP'')', 'v_perm_dec NOT IN (''ALLOW'',''STEP_UP'',''REQUIRE_STEP_UP'')');
  EXECUTE v_src;

  v_src := pg_get_functiondef('public.trigger_run_manual(uuid,uuid,workflow_type_enum,timestamptz,timestamptz,jsonb,uuid,jsonb)'::regprocedure);
  v_src := replace(v_src, 'v_perm_dec NOT IN (''ALLOW'',''STEP_UP'')', 'v_perm_dec NOT IN (''ALLOW'',''STEP_UP'',''REQUIRE_STEP_UP'')');
  EXECUTE v_src;
END $do$;
