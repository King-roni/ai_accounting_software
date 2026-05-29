-- B08·P08 fix-up #2: tag_taxonomy_versions enforces a partial unique on is_default=true
-- ("one_default" index). Creating a new default must atomically supersede the current one.
-- admin_retire_default_taxonomy_version must refuse to retire the active default
-- (no succession path) and refuse re-retirement.

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
  v_audit_created_id    uuid;
  v_audit_superseded_id uuid;
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

    v_audit_superseded_id := audit.emit_audit(
      p_organization_id  => NULL,
      p_business_id      => NULL,
      p_action           => 'TAG_TAXONOMY_VERSION_RETIRED',
      p_actor_kind       => 'USER',
      p_actor_user_id    => p_user_id,
      p_actor_system     => NULL,
      p_subject_type     => 'TAG_TAXONOMY_VERSION',
      p_subject_id       => v_prev_default.id,
      p_payload          => jsonb_build_object(
                              'version_label',       v_prev_default.version_label,
                              'superseded_by_label', p_version_label,
                              'reason',              'SUPERSEDED'
                            )
    );
  END IF;

  INSERT INTO public.tag_taxonomy_versions(id, version_label, definition, is_default, created_at)
  VALUES (v_new_id, p_version_label, p_definition, true, clock_timestamp());

  v_audit_created_id := audit.emit_audit(
    p_organization_id  => NULL,
    p_business_id      => NULL,
    p_action           => 'TAG_TAXONOMY_VERSION_CREATED',
    p_actor_kind       => 'USER',
    p_actor_user_id    => p_user_id,
    p_actor_system     => NULL,
    p_subject_type     => 'TAG_TAXONOMY_VERSION',
    p_subject_id       => v_new_id,
    p_payload          => jsonb_build_object(
                            'version_label',      p_version_label,
                            'superseded_version_id', v_prev_default.id
                          )
  );

  RETURN jsonb_build_object(
    'ok',                       true,
    'taxonomy_version_id',      v_new_id,
    'superseded_version_id',    v_prev_default.id,
    'audit_event_id',           v_audit_created_id,
    'audit_superseded_event_id', v_audit_superseded_id
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
  v_version        public.tag_taxonomy_versions%ROWTYPE;
  v_audit_event_id uuid;
BEGIN
  SELECT * INTO v_version FROM public.tag_taxonomy_versions WHERE id = p_taxonomy_version_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_NOT_FOUND');
  END IF;
  IF v_version.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ALREADY_RETIRED');
  END IF;
  IF v_version.is_default THEN
    -- The active default cannot be retired without succession.
    -- Use admin_create_default_taxonomy_version to introduce a new default
    -- (which auto-retires this one).
    RETURN jsonb_build_object('ok', false, 'reason', 'CANNOT_RETIRE_ACTIVE_DEFAULT');
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
                            'version_label',     v_version.version_label,
                            'retirement_reason', p_retirement_reason,
                            'reason',            'EXPLICIT_RETIRE'
                          )
  );

  RETURN jsonb_build_object('ok', true, 'taxonomy_version_id', p_taxonomy_version_id, 'audit_event_id', v_audit_event_id);
END$fn$;

REVOKE ALL ON FUNCTION public.admin_retire_default_taxonomy_version(uuid, uuid, text) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_retire_default_taxonomy_version(uuid, uuid, text) TO service_role;
