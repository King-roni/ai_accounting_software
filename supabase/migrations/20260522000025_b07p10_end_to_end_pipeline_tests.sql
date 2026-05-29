-- B07·P10 — End-to-End Pipeline Tests (registry + run-record + audit scaffolding)
--
-- The bulk of B07·P10's work is test infrastructure: filesystem fixture
-- content (curated CSV/PDF + expected JSON per fixture), recorded Document AI
-- responses, Python test runner, CI wiring — all orchestrator/Stage-4. SQL
-- ships the registry + per-run record + 4 spec-canonical audit events so every
-- CI invocation leaves an auditable trail.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pipeline_fixture_run_status_enum') THEN
    CREATE TYPE public.pipeline_fixture_run_status_enum AS ENUM ('RAN','PASSED','FAILED');
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.pipeline_fixtures (
  name                   text PRIMARY KEY,
  format                 public.statement_file_format_enum NOT NULL,
  description            text,
  registered_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  registered_by_user_id  uuid REFERENCES public.users(id),
  removed_at             timestamptz,
  removed_by_user_id     uuid REFERENCES public.users(id),
  removal_reason         text,
  updated_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pipeline_fixtures_name_lower_snake CHECK (name ~ '^[a-z][a-z0-9_]*$'),
  CONSTRAINT pipeline_fixtures_removed_chk CHECK (
    (removed_at IS NULL) = (removal_reason IS NULL)
  )
);

REVOKE ALL ON public.pipeline_fixtures FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.pipeline_fixtures TO service_role;

CREATE TABLE IF NOT EXISTS public.pipeline_fixture_runs (
  id                uuid PRIMARY KEY,
  fixture_name      text NOT NULL REFERENCES public.pipeline_fixtures(name) ON DELETE RESTRICT,
  test_run_id       text NOT NULL,
  status            public.pipeline_fixture_run_status_enum NOT NULL DEFAULT 'RAN',
  duration_ms       int,
  failure_summary   jsonb,
  started_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at      timestamptz,
  actor_user_id     uuid REFERENCES public.users(id),
  CONSTRAINT pipeline_fixture_runs_test_run_id_nonempty CHECK (length(test_run_id) > 0),
  CONSTRAINT pipeline_fixture_runs_passed_has_duration CHECK (
    (status = 'PASSED') = (duration_ms IS NOT NULL AND failure_summary IS NULL AND completed_at IS NOT NULL)
  ),
  CONSTRAINT pipeline_fixture_runs_failed_has_summary CHECK (
    (status = 'FAILED') = (failure_summary IS NOT NULL AND completed_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS pipeline_fixture_runs_fixture_idx
  ON public.pipeline_fixture_runs (fixture_name, started_at DESC);
CREATE INDEX IF NOT EXISTS pipeline_fixture_runs_test_run_idx
  ON public.pipeline_fixture_runs (test_run_id);

REVOKE ALL ON public.pipeline_fixture_runs FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.pipeline_fixture_runs TO service_role;

-- ============================================================================
-- Seed 10 fixtures (per spec)
-- ============================================================================
INSERT INTO public.pipeline_fixtures (name, format, description)
VALUES
  ('revolut_csv_clean_month', 'CSV', 'Typical 80-row month with mixed transaction types — happy path.'),
  ('revolut_csv_with_fx', 'CSV', 'Includes Revolut FX exchange paired-leg cases (out-leg + in-leg + fee).'),
  ('revolut_csv_truncated', 'CSV', 'Partial upload — file truncated mid-row. Exercises B07·P08 partial-upload path.'),
  ('revolut_csv_overlap_with_prior', 'CSV', 'Re-import of overlapping date range — dedup path (exact duplicates from prior upload).'),
  ('revolut_csv_within_batch_duplicate', 'CSV', 'Same row appears twice in one CSV — within-batch dedup.'),
  ('revolut_csv_outside_period', 'CSV', 'Mixed: some rows within declared period, some outside — POSSIBLE_WRONG_MATCH issues.'),
  ('revolut_csv_all_outside_period', 'CSV', 'Every row outside declared period — HIGH NEEDS_CONFIRMATION issue.'),
  ('revolut_csv_zero_amount_rows', 'CSV', 'Zero-amount rows — rejected by normalization with NORMALIZATION_FAILED audit.'),
  ('revolut_pdf_clean_month', 'PDF', 'PDF path through Document AI (uses recorded mock response — Stage-4 sub-doc tracks recording).'),
  ('revolut_pdf_low_confidence', 'PDF', 'Document AI returns low-confidence rows — flag_low_confidence_parsed_row path.')
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- record_pipeline_fixture_ran
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_pipeline_fixture_ran(
  p_fixture_name text,
  p_test_run_id  text,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_fixture public.pipeline_fixtures%ROWTYPE;
  v_run_id  uuid := public.gen_uuid_v7();
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_fixture_name IS NULL OR p_test_run_id IS NULL OR length(p_test_run_id) = 0 THEN
    RAISE EXCEPTION 'record_pipeline_fixture_ran: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_fixture FROM public.pipeline_fixtures WHERE name = p_fixture_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_NOT_FOUND', 'fixture_name', p_fixture_name);
  END IF;
  IF v_fixture.removed_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_REMOVED',
      'fixture_name', p_fixture_name, 'removed_at', v_fixture.removed_at);
  END IF;

  INSERT INTO public.pipeline_fixture_runs
    (id, fixture_name, test_run_id, status, started_at, actor_user_id)
  VALUES
    (v_run_id, p_fixture_name, p_test_run_id, 'RAN', clock_timestamp(), p_actor_user_id);

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'pipeline_fixture_runner';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'PIPELINE_FIXTURE_RAN',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => v_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_after_state => jsonb_build_object(
      'fixture_run_id', v_run_id,
      'fixture_name',   p_fixture_name,
      'test_run_id',    p_test_run_id,
      'format',         v_fixture.format::text),
    p_reason => format('pipeline fixture ran: %s (test_run=%s)', p_fixture_name, p_test_run_id));
  RETURN jsonb_build_object('ok', true,
    'fixture_run_id', v_run_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_pipeline_fixture_ran(text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pipeline_fixture_ran(text, text, uuid) TO service_role;

-- ============================================================================
-- record_pipeline_fixture_passed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_pipeline_fixture_passed(
  p_fixture_run_id uuid,
  p_duration_ms    int,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run public.pipeline_fixture_runs%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_fixture_run_id IS NULL OR p_duration_ms IS NULL THEN
    RAISE EXCEPTION 'record_pipeline_fixture_passed: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_duration_ms < 0 THEN
    RAISE EXCEPTION 'record_pipeline_fixture_passed: duration_ms must be >= 0' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.pipeline_fixture_runs WHERE id = p_fixture_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_pipeline_fixture_passed: fixture_run % not found', p_fixture_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'RAN'::public.pipeline_fixture_run_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_IN_RAN_STATE',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.pipeline_fixture_runs
    SET status = 'PASSED'::public.pipeline_fixture_run_status_enum,
        duration_ms = p_duration_ms,
        completed_at = clock_timestamp()
    WHERE id = p_fixture_run_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'pipeline_fixture_runner';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'PIPELINE_FIXTURE_PASSED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_fixture_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_after_state => jsonb_build_object(
      'fixture_run_id', p_fixture_run_id,
      'fixture_name',   v_run.fixture_name,
      'test_run_id',    v_run.test_run_id,
      'duration_ms',    p_duration_ms),
    p_reason => format('pipeline fixture %s passed in %s ms', v_run.fixture_name, p_duration_ms));
  RETURN jsonb_build_object('ok', true,
    'fixture_run_id', p_fixture_run_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_pipeline_fixture_passed(uuid, int, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pipeline_fixture_passed(uuid, int, uuid) TO service_role;

-- ============================================================================
-- record_pipeline_fixture_failed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_pipeline_fixture_failed(
  p_fixture_run_id  uuid,
  p_failure_summary jsonb,
  p_duration_ms     int DEFAULT NULL,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run public.pipeline_fixture_runs%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_fixture_run_id IS NULL OR p_failure_summary IS NULL THEN
    RAISE EXCEPTION 'record_pipeline_fixture_failed: required params missing' USING ERRCODE='22000';
  END IF;
  IF jsonb_typeof(p_failure_summary) <> 'object' THEN
    RAISE EXCEPTION 'record_pipeline_fixture_failed: failure_summary must be an object' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.pipeline_fixture_runs WHERE id = p_fixture_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_pipeline_fixture_failed: fixture_run % not found', p_fixture_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'RAN'::public.pipeline_fixture_run_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_IN_RAN_STATE',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.pipeline_fixture_runs
    SET status = 'FAILED'::public.pipeline_fixture_run_status_enum,
        failure_summary = p_failure_summary,
        duration_ms = p_duration_ms,
        completed_at = clock_timestamp()
    WHERE id = p_fixture_run_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'pipeline_fixture_runner';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'PIPELINE_FIXTURE_FAILED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_fixture_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_after_state => jsonb_build_object(
      'fixture_run_id',  p_fixture_run_id,
      'fixture_name',    v_run.fixture_name,
      'test_run_id',     v_run.test_run_id,
      'duration_ms',     p_duration_ms,
      'failure_summary', p_failure_summary),
    p_reason => format('pipeline fixture %s FAILED', v_run.fixture_name));
  RETURN jsonb_build_object('ok', true,
    'fixture_run_id', p_fixture_run_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_pipeline_fixture_failed(uuid, jsonb, int, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pipeline_fixture_failed(uuid, jsonb, int, uuid) TO service_role;

-- ============================================================================
-- record_pipeline_fixture_removed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_pipeline_fixture_removed(
  p_fixture_name   text,
  p_removal_reason text,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_fixture public.pipeline_fixtures%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_fixture_name IS NULL OR p_removal_reason IS NULL THEN
    RAISE EXCEPTION 'record_pipeline_fixture_removed: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_removal_reason) = 0 OR length(p_removal_reason) > 2000 THEN
    RAISE EXCEPTION 'record_pipeline_fixture_removed: removal_reason length must be 1..2000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_fixture FROM public.pipeline_fixtures WHERE name = p_fixture_name FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_NOT_FOUND', 'fixture_name', p_fixture_name);
  END IF;
  IF v_fixture.removed_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'fixture_name', p_fixture_name,
      'removed_at',   v_fixture.removed_at);
  END IF;

  UPDATE public.pipeline_fixtures
    SET removed_at = clock_timestamp(),
        removed_by_user_id = p_actor_user_id,
        removal_reason = p_removal_reason,
        updated_at = clock_timestamp()
    WHERE name = p_fixture_name;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'pipeline_fixture_runner';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'PIPELINE_FIXTURE_REMOVED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => NULL,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_after_state => jsonb_build_object(
      'fixture_name',    p_fixture_name,
      'removal_reason',  p_removal_reason,
      'removed_by_user_id', p_actor_user_id),
    p_reason => format('pipeline fixture %s removed: %s',
                       p_fixture_name, left(p_removal_reason, 200)));
  RETURN jsonb_build_object('ok', true,
    'fixture_name', p_fixture_name,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_pipeline_fixture_removed(text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pipeline_fixture_removed(text, text, uuid) TO service_role;
