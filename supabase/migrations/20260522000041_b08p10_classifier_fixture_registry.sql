-- B08·P10 step 2 of 2 — classifier-fixture registry + lifecycle RPCs.

-- 1. Enum --------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='fixture_run_status_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.fixture_run_status_enum AS ENUM ('PASSED','FAILED');
  END IF;
END$$;


-- 2. Tables ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.classifier_fixtures (
  name                     text PRIMARY KEY,
  description              text NOT NULL,
  expected_files_manifest  jsonb NOT NULL,
  fixture_hash             text NOT NULL,
  registered_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  registered_by_user_id    uuid NOT NULL,
  retired_at               timestamptz,
  retired_by_user_id       uuid,
  retirement_reason        text,
  CONSTRAINT cf_name_format          CHECK (name ~ '^[a-z][a-z0-9_]+$'),
  CONSTRAINT cf_description_nonempty CHECK (length(trim(description)) > 0),
  CONSTRAINT cf_hash_format          CHECK (fixture_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT cf_manifest_array       CHECK (jsonb_typeof(expected_files_manifest) = 'array'),
  CONSTRAINT cf_retirement_paired    CHECK (
    (retired_at IS NULL AND retired_by_user_id IS NULL AND retirement_reason IS NULL)
    OR (retired_at IS NOT NULL AND retired_by_user_id IS NOT NULL
        AND retirement_reason IS NOT NULL AND length(trim(retirement_reason)) > 0)
  )
);

CREATE INDEX IF NOT EXISTS idx_classifier_fixtures_active
  ON public.classifier_fixtures(name) WHERE retired_at IS NULL;

CREATE TABLE IF NOT EXISTS public.classifier_fixture_runs (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_name        text NOT NULL REFERENCES public.classifier_fixtures(name) ON DELETE RESTRICT,
  fixture_hash        text NOT NULL,
  ran_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  run_by_user_id      uuid NOT NULL,
  status              public.fixture_run_status_enum NOT NULL,
  actual_hash         text,
  diff_summary        jsonb,
  audit_event_ran_id  uuid,
  audit_event_outcome_id uuid,
  CONSTRAINT cfr_hash_format        CHECK (fixture_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT cfr_actual_hash_format CHECK (actual_hash IS NULL OR actual_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX IF NOT EXISTS idx_classifier_fixture_runs_by_name
  ON public.classifier_fixture_runs(fixture_name, ran_at DESC);


-- 3. register_classifier_fixture ---------------------------------------------

CREATE OR REPLACE FUNCTION public.register_classifier_fixture(
  p_name                    text,
  p_description             text,
  p_expected_files_manifest jsonb,
  p_fixture_hash            text,
  p_user_id                 uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_existing  public.classifier_fixtures%ROWTYPE;
  v_audit_row audit.audit_events%ROWTYPE;
  v_past_run_count int;
BEGIN
  IF p_name IS NULL OR p_name !~ '^[a-z][a-z0-9_]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NAME_FORMAT_INVALID');
  END IF;
  IF p_description IS NULL OR length(trim(p_description)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DESCRIPTION_REQUIRED');
  END IF;
  IF p_expected_files_manifest IS NULL OR jsonb_typeof(p_expected_files_manifest) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'MANIFEST_MUST_BE_ARRAY');
  END IF;
  IF p_fixture_hash IS NULL OR p_fixture_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'HASH_FORMAT_INVALID');
  END IF;

  SELECT * INTO v_existing FROM public.classifier_fixtures WHERE name = p_name;

  IF FOUND THEN
    IF v_existing.retired_at IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_RETIRED');
    END IF;

    -- Idempotent re-registration with same hash
    IF v_existing.fixture_hash = p_fixture_hash THEN
      RETURN jsonb_build_object(
        'ok', true,
        'already_registered', true,
        'fixture_name', p_name,
        'fixture_hash', p_fixture_hash
      );
    END IF;

    -- Hash changed — refuse if any past run exists; force explicit retire-and-recreate
    SELECT count(*) INTO v_past_run_count
      FROM public.classifier_fixture_runs
     WHERE fixture_name = p_name;
    IF v_past_run_count > 0 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'FIXTURE_LOCKED_BY_RUNS',
        'past_run_count', v_past_run_count
      );
    END IF;

    -- No runs yet: allow hash update in-place
    UPDATE public.classifier_fixtures
       SET description             = p_description,
           expected_files_manifest = p_expected_files_manifest,
           fixture_hash            = p_fixture_hash,
           registered_at           = clock_timestamp(),
           registered_by_user_id   = p_user_id
     WHERE name = p_name;
  ELSE
    INSERT INTO public.classifier_fixtures(
      name, description, expected_files_manifest, fixture_hash, registered_by_user_id
    ) VALUES (
      p_name, p_description, p_expected_files_manifest, p_fixture_hash, p_user_id
    );
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'CLASSIFIER_FIXTURE_REGISTERED',
    p_subject_type  => 'CLASSIFIER_FIXTURE'::audit.subject_type_enum,
    p_subject_id    => NULL,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'fixture_name', p_name,
                         'fixture_hash', p_fixture_hash,
                         'manifest_count', jsonb_array_length(p_expected_files_manifest)
                       ),
    p_reason        => format('classifier fixture registered: %s', p_name)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'already_registered', false,
    'fixture_name', p_name,
    'fixture_hash', p_fixture_hash,
    'audit_event_id', v_audit_row.id
  );
END$fn$;

REVOKE ALL ON FUNCTION public.register_classifier_fixture(text, text, jsonb, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.register_classifier_fixture(text, text, jsonb, text, uuid) TO service_role;


-- 4. record_classifier_fixture_pass ------------------------------------------

CREATE OR REPLACE FUNCTION public.record_classifier_fixture_pass(
  p_fixture_name text,
  p_actual_hash  text,
  p_user_id      uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_fix      public.classifier_fixtures%ROWTYPE;
  v_run_id   uuid := public.gen_uuid_v7();
  v_ran      audit.audit_events%ROWTYPE;
  v_outcome  audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_fix FROM public.classifier_fixtures WHERE name = p_fixture_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_NOT_FOUND');
  END IF;
  IF v_fix.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_RETIRED');
  END IF;
  IF p_actual_hash IS NULL OR p_actual_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'HASH_FORMAT_INVALID');
  END IF;

  v_ran := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'CLASSIFIER_FIXTURE_RAN',
    p_subject_type  => 'CLASSIFIER_FIXTURE'::audit.subject_type_enum,
    p_subject_id    => NULL,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'fixture_name',     p_fixture_name,
                         'fixture_hash',     v_fix.fixture_hash,
                         'actual_hash',      p_actual_hash,
                         'outcome',          'PASSED'
                       ),
    p_reason        => format('classifier fixture ran (PASSED): %s', p_fixture_name)
  );

  v_outcome := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'CLASSIFIER_FIXTURE_PASSED',
    p_subject_type  => 'CLASSIFIER_FIXTURE'::audit.subject_type_enum,
    p_subject_id    => NULL,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'fixture_name', p_fixture_name,
                         'fixture_hash', v_fix.fixture_hash,
                         'actual_hash',  p_actual_hash
                       ),
    p_reason        => format('classifier fixture passed: %s', p_fixture_name)
  );

  INSERT INTO public.classifier_fixture_runs(
    id, fixture_name, fixture_hash, run_by_user_id, status, actual_hash,
    audit_event_ran_id, audit_event_outcome_id
  ) VALUES (
    v_run_id, p_fixture_name, v_fix.fixture_hash, p_user_id,
    'PASSED'::public.fixture_run_status_enum, p_actual_hash, v_ran.id, v_outcome.id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'run_id', v_run_id,
    'audit_event_ran_id', v_ran.id,
    'audit_event_outcome_id', v_outcome.id
  );
END$fn$;

REVOKE ALL ON FUNCTION public.record_classifier_fixture_pass(text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.record_classifier_fixture_pass(text, text, uuid) TO service_role;


-- 5. record_classifier_fixture_failure ---------------------------------------

CREATE OR REPLACE FUNCTION public.record_classifier_fixture_failure(
  p_fixture_name text,
  p_actual_hash  text,
  p_diff_summary jsonb,
  p_user_id      uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_fix      public.classifier_fixtures%ROWTYPE;
  v_run_id   uuid := public.gen_uuid_v7();
  v_ran      audit.audit_events%ROWTYPE;
  v_outcome  audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_fix FROM public.classifier_fixtures WHERE name = p_fixture_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_NOT_FOUND');
  END IF;
  IF v_fix.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_RETIRED');
  END IF;
  IF p_actual_hash IS NULL OR p_actual_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'HASH_FORMAT_INVALID');
  END IF;
  IF p_diff_summary IS NULL OR jsonb_typeof(p_diff_summary) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DIFF_SUMMARY_MUST_BE_OBJECT');
  END IF;

  v_ran := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'CLASSIFIER_FIXTURE_RAN',
    p_subject_type  => 'CLASSIFIER_FIXTURE'::audit.subject_type_enum,
    p_subject_id    => NULL,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'fixture_name',  p_fixture_name,
                         'fixture_hash',  v_fix.fixture_hash,
                         'actual_hash',   p_actual_hash,
                         'outcome',       'FAILED'
                       ),
    p_reason        => format('classifier fixture ran (FAILED): %s', p_fixture_name)
  );

  v_outcome := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'CLASSIFIER_FIXTURE_FAILED',
    p_subject_type  => 'CLASSIFIER_FIXTURE'::audit.subject_type_enum,
    p_subject_id    => NULL,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'fixture_name',  p_fixture_name,
                         'fixture_hash',  v_fix.fixture_hash,
                         'actual_hash',   p_actual_hash,
                         'diff_summary',  p_diff_summary
                       ),
    p_reason        => format('classifier fixture failed: %s', p_fixture_name)
  );

  INSERT INTO public.classifier_fixture_runs(
    id, fixture_name, fixture_hash, run_by_user_id, status, actual_hash, diff_summary,
    audit_event_ran_id, audit_event_outcome_id
  ) VALUES (
    v_run_id, p_fixture_name, v_fix.fixture_hash, p_user_id,
    'FAILED'::public.fixture_run_status_enum, p_actual_hash, p_diff_summary,
    v_ran.id, v_outcome.id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'run_id', v_run_id,
    'audit_event_ran_id', v_ran.id,
    'audit_event_outcome_id', v_outcome.id
  );
END$fn$;

REVOKE ALL ON FUNCTION public.record_classifier_fixture_failure(text, text, jsonb, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.record_classifier_fixture_failure(text, text, jsonb, uuid) TO service_role;


-- 6. retire_classifier_fixture -----------------------------------------------

CREATE OR REPLACE FUNCTION public.retire_classifier_fixture(
  p_fixture_name      text,
  p_retirement_reason text,
  p_user_id           uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_fix       public.classifier_fixtures%ROWTYPE;
  v_audit_row audit.audit_events%ROWTYPE;
BEGIN
  IF p_retirement_reason IS NULL OR length(trim(p_retirement_reason)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'REASON_REQUIRED');
  END IF;

  SELECT * INTO v_fix FROM public.classifier_fixtures WHERE name = p_fixture_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_NOT_FOUND');
  END IF;
  IF v_fix.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ALREADY_RETIRED');
  END IF;

  UPDATE public.classifier_fixtures
     SET retired_at         = clock_timestamp(),
         retired_by_user_id = p_user_id,
         retirement_reason  = p_retirement_reason
   WHERE name = p_fixture_name;

  v_audit_row := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'CLASSIFIER_FIXTURE_REMOVED',
    p_subject_type  => 'CLASSIFIER_FIXTURE'::audit.subject_type_enum,
    p_subject_id    => NULL,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'fixture_name',      p_fixture_name,
                         'retirement_reason', p_retirement_reason
                       ),
    p_reason        => p_retirement_reason
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_name', p_fixture_name,
    'audit_event_id', v_audit_row.id
  );
END$fn$;

REVOKE ALL ON FUNCTION public.retire_classifier_fixture(text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.retire_classifier_fixture(text, text, uuid) TO service_role;


-- 7. get_classifier_fixture_drift_summary ------------------------------------

CREATE OR REPLACE FUNCTION public.get_classifier_fixture_drift_summary(
  p_fixture_name text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_fix      public.classifier_fixtures%ROWTYPE;
  v_last_run public.classifier_fixture_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_fix FROM public.classifier_fixtures WHERE name = p_fixture_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FIXTURE_NOT_FOUND');
  END IF;

  SELECT * INTO v_last_run
    FROM public.classifier_fixture_runs
   WHERE fixture_name = p_fixture_name
   ORDER BY ran_at DESC
   LIMIT 1;

  RETURN jsonb_build_object(
    'ok',                true,
    'fixture_name',      p_fixture_name,
    'registered_hash',   v_fix.fixture_hash,
    'retired_at',        v_fix.retired_at,
    'last_run_at',       v_last_run.ran_at,
    'last_run_status',   v_last_run.status::text,
    'last_actual_hash',  v_last_run.actual_hash,
    'drift_detected',    CASE
                           WHEN v_last_run.id IS NULL THEN false
                           WHEN v_last_run.actual_hash IS NULL THEN false
                           ELSE v_last_run.actual_hash <> v_fix.fixture_hash
                         END
  );
END$fn$;

REVOKE ALL ON FUNCTION public.get_classifier_fixture_drift_summary(text) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_classifier_fixture_drift_summary(text) TO service_role;
