-- B08·P08 fix-up #3 (step 2 of 2)
-- Rewrite snapshot_taxonomy, admin_create_default_taxonomy_version,
-- admin_retire_default_taxonomy_version, assign_taxonomy_version_to_business
-- to match the real audit.emit_audit signature (row-returning; p_after_state JSONB;
-- enum-typed actor_kind & subject_type) and the new TAG_TAXONOMY_VERSION /
-- BUSINESS_TAG_TAXONOMY_ASSIGNMENT subject_type values.

CREATE OR REPLACE FUNCTION public.snapshot_taxonomy(
  p_workflow_run_id uuid,
  p_user_id         uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run            public.workflow_runs%ROWTYPE;
  v_assignment     public.business_tag_taxonomy_assignments%ROWTYPE;
  v_version        public.tag_taxonomy_versions%ROWTYPE;
  v_custom_tags    jsonb;
  v_snapshot       jsonb;
  v_audit_row      audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

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

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'TAG_TAXONOMY_SNAPSHOT_CAPTURED',
    p_subject_type    => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id      => v_run.id,
    p_actor_user_id   => p_user_id,
    p_organization_id => v_run.organization_id,
    p_business_id     => v_run.business_id,
    p_after_state     => jsonb_build_object(
                           'taxonomy_version_id',    v_version.id,
                           'taxonomy_version_label', v_version.version_label,
                           'custom_tag_count',       jsonb_array_length(v_custom_tags)
                         ),
    p_reason          => format('taxonomy snapshot captured: run=%s version=%s', v_run.id, v_version.version_label)
  );

  RETURN jsonb_build_object(
    'ok',                  true,
    'already_captured',    false,
    'workflow_run_id',     v_run.id,
    'taxonomy_version_id', v_version.id,
    'audit_event_id',      v_audit_row.id
  );
END$fn$;

REVOKE ALL ON FUNCTION public.snapshot_taxonomy(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.snapshot_taxonomy(uuid, uuid) TO service_role;


CREATE OR REPLACE FUNCTION public.admin_create_default_taxonomy_version(
  p_version_label text,
  p_definition    jsonb,
  p_user_id       uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_new_id              uuid := public.gen_uuid_v7();
  v_prev_default        public.tag_taxonomy_versions%ROWTYPE;
  v_audit_created       audit.audit_events%ROWTYPE;
  v_audit_superseded    audit.audit_events%ROWTYPE;
BEGIN
  IF p_version_label IS NULL OR length(trim(p_version_label)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'VERSION_LABEL_REQUIRED');
  END IF;
  IF p_definition IS NULL OR jsonb_typeof(p_definition) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEFINITION_MUST_BE_ARRAY');
  END IF;

  SELECT * INTO v_prev_default
    FROM public.tag_taxonomy_versions
   WHERE is_default = true
   LIMIT 1;

  IF FOUND THEN
    UPDATE public.tag_taxonomy_versions
       SET is_default = false,
           retired_at = COALESCE(retired_at, clock_timestamp())
     WHERE id = v_prev_default.id;

    v_audit_superseded := audit.emit_audit(
      p_actor_kind    => 'USER'::audit.actor_kind_enum,
      p_action        => 'TAG_TAXONOMY_VERSION_RETIRED',
      p_subject_type  => 'TAG_TAXONOMY_VERSION'::audit.subject_type_enum,
      p_subject_id    => v_prev_default.id,
      p_actor_user_id => p_user_id,
      p_after_state   => jsonb_build_object(
                           'version_label',       v_prev_default.version_label,
                           'superseded_by_label', p_version_label,
                           'reason',              'SUPERSEDED'
                         ),
      p_reason        => format('taxonomy version superseded: %s by %s', v_prev_default.version_label, p_version_label)
    );
  END IF;

  INSERT INTO public.tag_taxonomy_versions(id, version_label, definition, is_default, created_at)
  VALUES (v_new_id, p_version_label, p_definition, true, clock_timestamp());

  v_audit_created := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'TAG_TAXONOMY_VERSION_CREATED',
    p_subject_type  => 'TAG_TAXONOMY_VERSION'::audit.subject_type_enum,
    p_subject_id    => v_new_id,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'version_label',         p_version_label,
                         'superseded_version_id', v_prev_default.id
                       ),
    p_reason        => format('new default taxonomy created: %s', p_version_label)
  );

  RETURN jsonb_build_object(
    'ok',                        true,
    'taxonomy_version_id',       v_new_id,
    'superseded_version_id',     v_prev_default.id,
    'audit_event_id',            v_audit_created.id,
    'audit_superseded_event_id', v_audit_superseded.id
  );
END$fn$;

REVOKE ALL ON FUNCTION public.admin_create_default_taxonomy_version(text, jsonb, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_default_taxonomy_version(text, jsonb, uuid) TO service_role;


CREATE OR REPLACE FUNCTION public.admin_retire_default_taxonomy_version(
  p_taxonomy_version_id uuid,
  p_user_id             uuid,
  p_retirement_reason   text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_version    public.tag_taxonomy_versions%ROWTYPE;
  v_audit_row  audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_version FROM public.tag_taxonomy_versions WHERE id = p_taxonomy_version_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_NOT_FOUND');
  END IF;
  IF v_version.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ALREADY_RETIRED');
  END IF;
  IF v_version.is_default THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'CANNOT_RETIRE_ACTIVE_DEFAULT');
  END IF;

  UPDATE public.tag_taxonomy_versions
     SET retired_at = clock_timestamp()
   WHERE id = p_taxonomy_version_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'TAG_TAXONOMY_VERSION_RETIRED',
    p_subject_type  => 'TAG_TAXONOMY_VERSION'::audit.subject_type_enum,
    p_subject_id    => p_taxonomy_version_id,
    p_actor_user_id => p_user_id,
    p_after_state   => jsonb_build_object(
                         'version_label',     v_version.version_label,
                         'retirement_reason', p_retirement_reason,
                         'reason',            'EXPLICIT_RETIRE'
                       ),
    p_reason        => COALESCE(p_retirement_reason, format('explicit retire of %s', v_version.version_label))
  );

  RETURN jsonb_build_object('ok', true, 'taxonomy_version_id', p_taxonomy_version_id, 'audit_event_id', v_audit_row.id);
END$fn$;

REVOKE ALL ON FUNCTION public.admin_retire_default_taxonomy_version(uuid, uuid, text) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_retire_default_taxonomy_version(uuid, uuid, text) TO service_role;


CREATE OR REPLACE FUNCTION public.assign_taxonomy_version_to_business(
  p_organization_id     uuid,
  p_business_id         uuid,
  p_taxonomy_version_id uuid,
  p_user_id             uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_version        public.tag_taxonomy_versions%ROWTYPE;
  v_assignment_id  uuid := public.gen_uuid_v7();
  v_audit_row      audit.audit_events%ROWTYPE;
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

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'TAG_TAXONOMY_VERSION_ASSIGNED_TO_BUSINESS',
    p_subject_type    => 'BUSINESS_TAG_TAXONOMY_ASSIGNMENT'::audit.subject_type_enum,
    p_subject_id      => v_assignment_id,
    p_actor_user_id   => p_user_id,
    p_organization_id => p_organization_id,
    p_business_id     => p_business_id,
    p_after_state     => jsonb_build_object(
                           'taxonomy_version_id',    p_taxonomy_version_id,
                           'taxonomy_version_label', v_version.version_label
                         ),
    p_reason          => format('assigned taxonomy %s to business %s', v_version.version_label, p_business_id)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'assignment_id', v_assignment_id,
    'taxonomy_version_id', p_taxonomy_version_id,
    'audit_event_id', v_audit_row.id
  );
END$fn$;

REVOKE ALL ON FUNCTION public.assign_taxonomy_version_to_business(uuid, uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.assign_taxonomy_version_to_business(uuid, uuid, uuid, uuid) TO service_role;
