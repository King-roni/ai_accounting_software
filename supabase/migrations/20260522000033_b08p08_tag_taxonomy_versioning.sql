-- B08·P08 Tag Taxonomy Versioning
-- Adds classification_taxonomy_snapshot to workflow_runs and lifecycle RPCs.

-- 1. Schema additions ---------------------------------------------------------

ALTER TABLE public.workflow_runs
  ADD COLUMN IF NOT EXISTS classification_taxonomy_snapshot jsonb NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'wfr_classification_taxonomy_snapshot_shape_chk'
       AND conrelid = 'public.workflow_runs'::regclass
  ) THEN
    ALTER TABLE public.workflow_runs
      ADD CONSTRAINT wfr_classification_taxonomy_snapshot_shape_chk
      CHECK (
        classification_taxonomy_snapshot IS NULL
        OR (
          (classification_taxonomy_snapshot ? 'taxonomy_version_id')
          AND (classification_taxonomy_snapshot ? 'taxonomy_version_label')
          AND (classification_taxonomy_snapshot ? 'taxonomy_definition')
          AND (classification_taxonomy_snapshot ? 'custom_tags')
          AND (classification_taxonomy_snapshot ? 'captured_at')
        )
      );
  END IF;
END$$;

-- Immutability: snapshot can only transition NULL → non-NULL, never be rewritten.
CREATE OR REPLACE FUNCTION public.workflow_runs_snapshot_immutable_tg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.classification_taxonomy_snapshot IS NOT NULL
     AND NEW.classification_taxonomy_snapshot IS DISTINCT FROM OLD.classification_taxonomy_snapshot THEN
    RAISE EXCEPTION 'workflow_runs.classification_taxonomy_snapshot is immutable once captured (run %)', OLD.id
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END$$;

DROP TRIGGER IF EXISTS workflow_runs_snapshot_immutable_tg ON public.workflow_runs;
CREATE TRIGGER workflow_runs_snapshot_immutable_tg
  BEFORE UPDATE OF classification_taxonomy_snapshot ON public.workflow_runs
  FOR EACH ROW
  EXECUTE FUNCTION public.workflow_runs_snapshot_immutable_tg();


-- 2. snapshot_taxonomy RPC ----------------------------------------------------

CREATE OR REPLACE FUNCTION public.snapshot_taxonomy(
  p_workflow_run_id uuid,
  p_user_id         uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run            public.workflow_runs%ROWTYPE;
  v_assignment     public.business_tag_taxonomy_assignments%ROWTYPE;
  v_version        public.tag_taxonomy_versions%ROWTYPE;
  v_custom_tags    jsonb;
  v_snapshot       jsonb;
  v_audit_event_id uuid;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  -- Idempotent: already captured → return prior envelope unchanged
  IF v_run.classification_taxonomy_snapshot IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok',                true,
      'already_captured',  true,
      'workflow_run_id',   v_run.id,
      'taxonomy_version_id', v_run.classification_taxonomy_snapshot->>'taxonomy_version_id'
    );
  END IF;

  SELECT * INTO v_assignment
    FROM public.business_tag_taxonomy_assignments
   WHERE business_id = v_run.business_id
   ORDER BY assigned_at DESC
   LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_TAXONOMY_ASSIGNMENT_FOR_BUSINESS');
  END IF;

  SELECT * INTO v_version FROM public.tag_taxonomy_versions WHERE id = v_assignment.tag_taxonomy_version_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_NOT_FOUND');
  END IF;

  -- Defensive copy of definition + active custom tags
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'id',                      ct.id,
                    'name',                    ct.tag_name,
                    'mapped_transaction_type', ct.mapped_transaction_type
                  ) ORDER BY ct.tag_name), '[]'::jsonb)
    INTO v_custom_tags
    FROM public.business_custom_tags ct
   WHERE ct.business_id = v_run.business_id
     AND ct.retired_at IS NULL;

  v_snapshot := jsonb_build_object(
    'taxonomy_version_id',    v_version.id,
    'taxonomy_version_label', v_version.version_label,
    'taxonomy_definition',    v_version.definition,
    'custom_tags',            v_custom_tags,
    'captured_at',            clock_timestamp()
  );

  UPDATE public.workflow_runs
     SET classification_taxonomy_snapshot = v_snapshot,
         tag_taxonomy_version_id          = v_version.id,
         updated_at                       = clock_timestamp()
   WHERE id = v_run.id;

  v_audit_event_id := audit.emit_audit(
    p_organization_id  => v_run.organization_id,
    p_business_id      => v_run.business_id,
    p_action           => 'TAG_TAXONOMY_SNAPSHOT_CAPTURED',
    p_actor_kind       => 'USER',
    p_actor_user_id    => p_user_id,
    p_actor_system     => NULL,
    p_subject_type     => 'WORKFLOW_RUN',
    p_subject_id       => v_run.id,
    p_payload          => jsonb_build_object(
                            'taxonomy_version_id',    v_version.id,
                            'taxonomy_version_label', v_version.version_label,
                            'custom_tag_count',       jsonb_array_length(v_custom_tags)
                          )
  );

  RETURN jsonb_build_object(
    'ok',                  true,
    'already_captured',    false,
    'workflow_run_id',     v_run.id,
    'taxonomy_version_id', v_version.id,
    'audit_event_id',      v_audit_event_id
  );
END$$;

REVOKE ALL ON FUNCTION public.snapshot_taxonomy(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.snapshot_taxonomy(uuid, uuid) TO service_role;


-- 3. resolve_tag_name (STABLE helper) -----------------------------------------

CREATE OR REPLACE FUNCTION public.resolve_tag_name(
  p_workflow_run_id uuid,
  p_tag_id          uuid
) RETURNS text
LANGUAGE sql
STABLE
AS $$
  WITH snap AS (
    SELECT classification_taxonomy_snapshot AS s
      FROM public.workflow_runs
     WHERE id = p_workflow_run_id
       AND classification_taxonomy_snapshot IS NOT NULL
  ),
  custom AS (
    SELECT (ct->>'name') AS name
      FROM snap, jsonb_array_elements((snap.s->'custom_tags')) ct
     WHERE (ct->>'id')::uuid = p_tag_id
     LIMIT 1
  ),
  defn AS (
    SELECT (tag->>'label') AS name
      FROM snap, jsonb_array_elements((snap.s->'taxonomy_definition'->'tags')) tag
     WHERE (tag->>'id')::uuid = p_tag_id
     LIMIT 1
  )
  SELECT COALESCE((SELECT name FROM custom),
                  (SELECT name FROM defn),
                  '(unknown tag)');
$$;


-- 4. Platform-admin lifecycle RPCs --------------------------------------------

-- 4a. create new default taxonomy version
CREATE OR REPLACE FUNCTION public.admin_create_default_taxonomy_version(
  p_version_label text,
  p_definition    jsonb,
  p_user_id       uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_version_id     uuid := public.gen_uuid_v7();
  v_audit_event_id uuid;
BEGIN
  IF p_version_label IS NULL OR length(trim(p_version_label)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'VERSION_LABEL_REQUIRED');
  END IF;
  IF p_definition IS NULL OR jsonb_typeof(p_definition) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEFINITION_MUST_BE_OBJECT');
  END IF;

  INSERT INTO public.tag_taxonomy_versions(id, version_label, definition, is_default, created_at)
  VALUES (v_version_id, p_version_label, p_definition, true, clock_timestamp());

  v_audit_event_id := audit.emit_audit(
    p_organization_id  => NULL,
    p_business_id      => NULL,
    p_action           => 'TAG_TAXONOMY_VERSION_CREATED',
    p_actor_kind       => 'USER',
    p_actor_user_id    => p_user_id,
    p_actor_system     => NULL,
    p_subject_type     => 'TAG_TAXONOMY_VERSION',
    p_subject_id       => v_version_id,
    p_payload          => jsonb_build_object('version_label', p_version_label)
  );

  RETURN jsonb_build_object('ok', true, 'taxonomy_version_id', v_version_id, 'audit_event_id', v_audit_event_id);
END$$;

REVOKE ALL ON FUNCTION public.admin_create_default_taxonomy_version(text, jsonb, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_default_taxonomy_version(text, jsonb, uuid) TO service_role;


-- 4b. retire a default taxonomy version (refuses if it would leave zero defaults)
CREATE OR REPLACE FUNCTION public.admin_retire_default_taxonomy_version(
  p_taxonomy_version_id uuid,
  p_user_id             uuid,
  p_retirement_reason   text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_version        public.tag_taxonomy_versions%ROWTYPE;
  v_remaining      int;
  v_audit_event_id uuid;
BEGIN
  SELECT * INTO v_version FROM public.tag_taxonomy_versions WHERE id = p_taxonomy_version_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_NOT_FOUND');
  END IF;
  IF NOT v_version.is_default THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_A_DEFAULT_VERSION');
  END IF;
  IF v_version.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ALREADY_RETIRED');
  END IF;

  SELECT count(*) INTO v_remaining
    FROM public.tag_taxonomy_versions
   WHERE is_default = true AND retired_at IS NULL AND id <> p_taxonomy_version_id;
  IF v_remaining = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'CANNOT_RETIRE_ONLY_DEFAULT');
  END IF;

  UPDATE public.tag_taxonomy_versions
     SET retired_at = clock_timestamp()
   WHERE id = p_taxonomy_version_id;

  v_audit_event_id := audit.emit_audit(
    p_organization_id  => NULL,
    p_business_id      => NULL,
    p_action           => 'TAG_TAXONOMY_VERSION_RETIRED',
    p_actor_kind       => 'USER',
    p_actor_user_id    => p_user_id,
    p_actor_system     => NULL,
    p_subject_type     => 'TAG_TAXONOMY_VERSION',
    p_subject_id       => p_taxonomy_version_id,
    p_payload          => jsonb_build_object(
                            'version_label',      v_version.version_label,
                            'retirement_reason',  p_retirement_reason
                          )
  );

  RETURN jsonb_build_object('ok', true, 'taxonomy_version_id', p_taxonomy_version_id, 'audit_event_id', v_audit_event_id);
END$$;

REVOKE ALL ON FUNCTION public.admin_retire_default_taxonomy_version(uuid, uuid, text) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_retire_default_taxonomy_version(uuid, uuid, text) TO service_role;


-- 4c. assign a taxonomy version to a business (new assignment row)
CREATE OR REPLACE FUNCTION public.assign_taxonomy_version_to_business(
  p_organization_id     uuid,
  p_business_id         uuid,
  p_taxonomy_version_id uuid,
  p_user_id             uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_version        public.tag_taxonomy_versions%ROWTYPE;
  v_assignment_id  uuid := public.gen_uuid_v7();
  v_audit_event_id uuid;
BEGIN
  SELECT * INTO v_version FROM public.tag_taxonomy_versions WHERE id = p_taxonomy_version_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_NOT_FOUND');
  END IF;
  IF v_version.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_RETIRED');
  END IF;

  INSERT INTO public.business_tag_taxonomy_assignments(
    id, organization_id, business_id, tag_taxonomy_version_id, assigned_at, assigned_by_user_id
  ) VALUES (
    v_assignment_id, p_organization_id, p_business_id, p_taxonomy_version_id, clock_timestamp(), p_user_id
  );

  v_audit_event_id := audit.emit_audit(
    p_organization_id  => p_organization_id,
    p_business_id      => p_business_id,
    p_action           => 'TAG_TAXONOMY_VERSION_ASSIGNED_TO_BUSINESS',
    p_actor_kind       => 'USER',
    p_actor_user_id    => p_user_id,
    p_actor_system     => NULL,
    p_subject_type     => 'BUSINESS_TAG_TAXONOMY_ASSIGNMENT',
    p_subject_id       => v_assignment_id,
    p_payload          => jsonb_build_object(
                            'taxonomy_version_id',    p_taxonomy_version_id,
                            'taxonomy_version_label', v_version.version_label
                          )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'assignment_id', v_assignment_id,
    'taxonomy_version_id', p_taxonomy_version_id,
    'audit_event_id', v_audit_event_id
  );
END$$;

REVOKE ALL ON FUNCTION public.assign_taxonomy_version_to_business(uuid, uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.assign_taxonomy_version_to_business(uuid, uuid, uuid, uuid) TO service_role;
