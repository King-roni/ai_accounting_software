-- B09·P10 (part 2/2) — Intake fixture registry + runs lifecycle.
-- DB scaffold for golden-file regression testing of the Block 09 intake
-- pipeline. Filesystem fixture content + Python runner + CI wiring are
-- Stage-6 follow-ups (mirrors B07·P10 and B08·P10).
--
-- Audit family INTAKE_FIXTURE (subject_type=INTAKE_FIXTURE, SYSTEM actor,
-- actor_system='intake_fixture'):
--   INTAKE_FIXTURE_RAN       (always emitted on pass/fail)
--   INTAKE_FIXTURE_PASSED
--   INTAKE_FIXTURE_FAILED    (diff_summary in after_state)

-- 1. intake_fixtures registry ------------------------------------------------

CREATE TABLE IF NOT EXISTS public.intake_fixtures (
  name                    text PRIMARY KEY,
  fixture_hash            text NOT NULL,
  description             text NOT NULL,
  manifest                jsonb NOT NULL,
  registered_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  registered_by_user_id   uuid,
  retired_at              timestamptz,
  retired_by_user_id      uuid,
  retired_reason          text,
  CONSTRAINT if_name_format       CHECK (name ~ '^[a-z][a-z0-9_]+$'),
  CONSTRAINT if_hash_format       CHECK (fixture_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT if_description_nonempty CHECK (length(trim(description)) > 0),
  CONSTRAINT if_manifest_array    CHECK (jsonb_typeof(manifest) = 'array'),
  CONSTRAINT if_retired_pairing   CHECK (
    (retired_at IS NULL AND retired_reason IS NULL)
    OR (retired_at IS NOT NULL AND retired_reason IS NOT NULL AND length(trim(retired_reason)) > 0)
  )
);

ALTER TABLE public.intake_fixtures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS if_select ON public.intake_fixtures;
CREATE POLICY if_select ON public.intake_fixtures FOR SELECT USING (true);
DROP POLICY IF EXISTS if_no_insert ON public.intake_fixtures;
CREATE POLICY if_no_insert ON public.intake_fixtures FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS if_no_update ON public.intake_fixtures;
CREATE POLICY if_no_update ON public.intake_fixtures FOR UPDATE USING (false);
DROP POLICY IF EXISTS if_no_delete ON public.intake_fixtures;
CREATE POLICY if_no_delete ON public.intake_fixtures FOR DELETE USING (false);


-- 2. intake_fixture_runs lifecycle -------------------------------------------

CREATE TABLE IF NOT EXISTS public.intake_fixture_runs (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_name    text NOT NULL,
  fixture_hash    text NOT NULL,
  status          text NOT NULL,
  diff_summary    jsonb,
  ran_by_user_id  uuid,
  ran_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ifr_status_chk CHECK (status IN ('PASSED','FAILED')),
  CONSTRAINT ifr_hash_format CHECK (fixture_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT ifr_diff_pairing CHECK (
    (status = 'PASSED' AND diff_summary IS NULL)
    OR (status = 'FAILED' AND diff_summary IS NOT NULL AND jsonb_typeof(diff_summary) = 'object')
  ),
  CONSTRAINT ifr_fixture_fk FOREIGN KEY (fixture_name) REFERENCES public.intake_fixtures(name) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ifr_by_fixture
  ON public.intake_fixture_runs (fixture_name, ran_at DESC);
CREATE INDEX IF NOT EXISTS ifr_by_status
  ON public.intake_fixture_runs (status, ran_at DESC);

ALTER TABLE public.intake_fixture_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ifr_select ON public.intake_fixture_runs;
CREATE POLICY ifr_select ON public.intake_fixture_runs FOR SELECT USING (true);
DROP POLICY IF EXISTS ifr_no_insert ON public.intake_fixture_runs;
CREATE POLICY ifr_no_insert ON public.intake_fixture_runs FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS ifr_no_update ON public.intake_fixture_runs;
CREATE POLICY ifr_no_update ON public.intake_fixture_runs FOR UPDATE USING (false);
DROP POLICY IF EXISTS ifr_no_delete ON public.intake_fixture_runs;
CREATE POLICY ifr_no_delete ON public.intake_fixture_runs FOR DELETE USING (false);


-- 3. register_intake_fixture -------------------------------------------------

CREATE OR REPLACE FUNCTION public.register_intake_fixture(
  p_fixture_name           text,
  p_fixture_hash           text,
  p_description            text,
  p_manifest               jsonb,
  p_registered_by_user_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_existing_hash text;
  v_run_count     int;
BEGIN
  IF p_fixture_name IS NULL OR p_fixture_name !~ '^[a-z][a-z0-9_]+$' THEN
    RAISE EXCEPTION 'FIXTURE_NAME_INVALID_FORMAT' USING errcode='check_violation';
  END IF;
  IF p_fixture_hash IS NULL OR p_fixture_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'FIXTURE_HASH_INVALID_FORMAT' USING errcode='check_violation';
  END IF;

  SELECT fixture_hash INTO v_existing_hash
  FROM public.intake_fixtures WHERE name = p_fixture_name FOR UPDATE;

  IF FOUND THEN
    IF v_existing_hash = p_fixture_hash THEN
      -- Idempotent re-register: update description/manifest only
      UPDATE public.intake_fixtures
        SET description = p_description,
            manifest    = p_manifest
      WHERE name = p_fixture_name;
      RETURN jsonb_build_object(
        'decision','REGISTERED','fixture_name',p_fixture_name,
        'fixture_hash',p_fixture_hash,'is_new',false
      );
    END IF;

    -- Hash changed: only allow if NO runs have been recorded against this name
    SELECT count(*) INTO v_run_count FROM public.intake_fixture_runs WHERE fixture_name = p_fixture_name;
    IF v_run_count > 0 THEN
      RETURN jsonb_build_object(
        'decision','REJECTED','reason','FIXTURE_LOCKED_BY_RUNS',
        'fixture_name',p_fixture_name,
        'existing_hash',v_existing_hash,'attempted_hash',p_fixture_hash,
        'run_count',v_run_count
      );
    END IF;

    -- Hash change allowed (zero runs); update in place
    UPDATE public.intake_fixtures
      SET fixture_hash = p_fixture_hash,
          description  = p_description,
          manifest     = p_manifest
    WHERE name = p_fixture_name;
    RETURN jsonb_build_object(
      'decision','REGISTERED','fixture_name',p_fixture_name,
      'fixture_hash',p_fixture_hash,'is_new',false,
      'note','hash_changed_before_any_runs'
    );
  END IF;

  -- First registration
  INSERT INTO public.intake_fixtures (
    name, fixture_hash, description, manifest, registered_by_user_id
  ) VALUES (
    p_fixture_name, p_fixture_hash, p_description, p_manifest, p_registered_by_user_id
  );

  RETURN jsonb_build_object(
    'decision','REGISTERED','fixture_name',p_fixture_name,
    'fixture_hash',p_fixture_hash,'is_new',true
  );
END;
$$;


-- 4. record_intake_fixture_pass ----------------------------------------------

CREATE OR REPLACE FUNCTION public.record_intake_fixture_pass(
  p_fixture_name   text,
  p_fixture_hash   text,
  p_ran_by_user_id uuid    DEFAULT NULL,
  p_context        jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_registry_hash text;
  v_run_id        uuid;
BEGIN
  SELECT fixture_hash INTO v_registry_hash
  FROM public.intake_fixtures WHERE name = p_fixture_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','FIXTURE_NOT_FOUND','fixture_name',p_fixture_name);
  END IF;
  IF v_registry_hash <> p_fixture_hash THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','FIXTURE_HASH_MISMATCH',
      'fixture_name',p_fixture_name,
      'registry_hash',v_registry_hash,'received_hash',p_fixture_hash
    );
  END IF;

  INSERT INTO public.intake_fixture_runs (
    fixture_name, fixture_hash, status, ran_by_user_id
  ) VALUES (
    p_fixture_name, p_fixture_hash, 'PASSED', p_ran_by_user_id
  )
  RETURNING id INTO v_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='INTAKE_FIXTURE_RAN',
    p_subject_type:='INTAKE_FIXTURE'::audit.subject_type_enum,
    p_subject_id:=NULL,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='intake_fixture',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'fixture_name',p_fixture_name,'fixture_hash',p_fixture_hash,
      'run_id',v_run_id,'status','PASSED'
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='INTAKE_FIXTURE_PASSED',
    p_subject_type:='INTAKE_FIXTURE'::audit.subject_type_enum,
    p_subject_id:=NULL,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='intake_fixture',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'fixture_name',p_fixture_name,'fixture_hash',p_fixture_hash,'run_id',v_run_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','fixture_name',p_fixture_name,
    'run_id',v_run_id,'status','PASSED'
  );
END;
$$;


-- 5. record_intake_fixture_failure -------------------------------------------

CREATE OR REPLACE FUNCTION public.record_intake_fixture_failure(
  p_fixture_name   text,
  p_fixture_hash   text,
  p_diff_summary   jsonb,
  p_ran_by_user_id uuid    DEFAULT NULL,
  p_context        jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_registry_hash text;
  v_run_id        uuid;
BEGIN
  IF p_diff_summary IS NULL OR jsonb_typeof(p_diff_summary) <> 'object' THEN
    RAISE EXCEPTION 'DIFF_SUMMARY_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;

  SELECT fixture_hash INTO v_registry_hash
  FROM public.intake_fixtures WHERE name = p_fixture_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','FIXTURE_NOT_FOUND','fixture_name',p_fixture_name);
  END IF;
  IF v_registry_hash <> p_fixture_hash THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','FIXTURE_HASH_MISMATCH',
      'fixture_name',p_fixture_name,
      'registry_hash',v_registry_hash,'received_hash',p_fixture_hash
    );
  END IF;

  INSERT INTO public.intake_fixture_runs (
    fixture_name, fixture_hash, status, diff_summary, ran_by_user_id
  ) VALUES (
    p_fixture_name, p_fixture_hash, 'FAILED', p_diff_summary, p_ran_by_user_id
  )
  RETURNING id INTO v_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='INTAKE_FIXTURE_RAN',
    p_subject_type:='INTAKE_FIXTURE'::audit.subject_type_enum,
    p_subject_id:=NULL,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='intake_fixture',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'fixture_name',p_fixture_name,'fixture_hash',p_fixture_hash,
      'run_id',v_run_id,'status','FAILED'
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='INTAKE_FIXTURE_FAILED',
    p_subject_type:='INTAKE_FIXTURE'::audit.subject_type_enum,
    p_subject_id:=NULL,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='intake_fixture',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'fixture_name',p_fixture_name,'fixture_hash',p_fixture_hash,
      'run_id',v_run_id,'diff_summary',p_diff_summary
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','fixture_name',p_fixture_name,
    'run_id',v_run_id,'status','FAILED'
  );
END;
$$;


-- 6. retire_intake_fixture ---------------------------------------------------

CREATE OR REPLACE FUNCTION public.retire_intake_fixture(
  p_fixture_name        text,
  p_retired_reason      text,
  p_retired_by_user_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_already_retired_at timestamptz;
BEGIN
  IF p_retired_reason IS NULL OR length(trim(p_retired_reason)) = 0 THEN
    RAISE EXCEPTION 'RETIRED_REASON_REQUIRED' USING errcode='check_violation';
  END IF;
  SELECT retired_at INTO v_already_retired_at
  FROM public.intake_fixtures WHERE name = p_fixture_name FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','FIXTURE_NOT_FOUND','fixture_name',p_fixture_name);
  END IF;
  IF v_already_retired_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','ALREADY_RETIRED',
      'fixture_name',p_fixture_name,'retired_at',v_already_retired_at
    );
  END IF;

  UPDATE public.intake_fixtures
    SET retired_at = clock_timestamp(),
        retired_by_user_id = p_retired_by_user_id,
        retired_reason = p_retired_reason
  WHERE name = p_fixture_name;

  RETURN jsonb_build_object(
    'decision','RETIRED','fixture_name',p_fixture_name,'reason',p_retired_reason
  );
END;
$$;


-- 7. get_intake_fixture_drift_summary ----------------------------------------

CREATE OR REPLACE FUNCTION public.get_intake_fixture_drift_summary()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total       int;
  v_active      int;
  v_retired     int;
  v_30d_pass    int;
  v_30d_fail    int;
  v_never_passed int;
BEGIN
  SELECT count(*) INTO v_total FROM public.intake_fixtures;
  SELECT count(*) INTO v_active FROM public.intake_fixtures WHERE retired_at IS NULL;
  SELECT count(*) INTO v_retired FROM public.intake_fixtures WHERE retired_at IS NOT NULL;
  SELECT count(*) INTO v_30d_pass FROM public.intake_fixture_runs
    WHERE status='PASSED' AND ran_at >= clock_timestamp() - interval '30 days';
  SELECT count(*) INTO v_30d_fail FROM public.intake_fixture_runs
    WHERE status='FAILED' AND ran_at >= clock_timestamp() - interval '30 days';
  SELECT count(*) INTO v_never_passed
  FROM public.intake_fixtures f
  WHERE f.retired_at IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.intake_fixture_runs r
      WHERE r.fixture_name = f.name AND r.status = 'PASSED'
    );

  RETURN jsonb_build_object(
    'total_fixtures',       v_total,
    'active_count',         v_active,
    'retired_count',        v_retired,
    'last_30d_pass',        v_30d_pass,
    'last_30d_fail',        v_30d_fail,
    'fixtures_never_passed',v_never_passed
  );
END;
$$;


-- 8. Privilege grants --------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.register_intake_fixture(text, text, text, jsonb, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_intake_fixture_pass(text, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_intake_fixture_failure(text, text, jsonb, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.retire_intake_fixture(text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_intake_fixture_drift_summary() FROM PUBLIC;

GRANT  EXECUTE ON FUNCTION public.register_intake_fixture(text, text, text, jsonb, uuid) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.record_intake_fixture_pass(text, text, uuid, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.record_intake_fixture_failure(text, text, jsonb, uuid, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.retire_intake_fixture(text, text, uuid) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.get_intake_fixture_drift_summary() TO authenticated, service_role, anon;

GRANT SELECT ON public.intake_fixtures      TO authenticated, anon;
GRANT SELECT ON public.intake_fixture_runs  TO authenticated, anon;
