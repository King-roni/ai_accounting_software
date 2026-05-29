-- B08·P08 fix-up: tag_taxonomy_versions.definition is a JSONB array (CHECK jsonb_typeof='array').
-- Adjust resolve_tag_name + admin_create_default_taxonomy_version to match.

CREATE OR REPLACE FUNCTION public.resolve_tag_name(
  p_workflow_run_id uuid,
  p_tag_id          uuid
) RETURNS text
LANGUAGE sql
STABLE
AS $rs$
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
      FROM snap, jsonb_array_elements((snap.s->'taxonomy_definition')) tag
     WHERE (tag->>'id')::uuid = p_tag_id
     LIMIT 1
  )
  SELECT COALESCE((SELECT name FROM custom),
                  (SELECT name FROM defn),
                  '(unknown tag)');
$rs$;

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
  v_version_id     uuid := public.gen_uuid_v7();
  v_audit_event_id uuid;
BEGIN
  IF p_version_label IS NULL OR length(trim(p_version_label)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'VERSION_LABEL_REQUIRED');
  END IF;
  IF p_definition IS NULL OR jsonb_typeof(p_definition) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEFINITION_MUST_BE_ARRAY');
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
END$fn$;

REVOKE ALL ON FUNCTION public.admin_create_default_taxonomy_version(text, jsonb, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_default_taxonomy_version(text, jsonb, uuid) TO service_role;
