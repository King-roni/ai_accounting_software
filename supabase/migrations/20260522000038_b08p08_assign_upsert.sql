-- B08·P08 fix-up #4: business_tag_taxonomy_assignments has UNIQUE(business_id).
-- Reassign = UPDATE existing row; do not INSERT a second.

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
  v_assignment_id  uuid;
  v_audit_row      audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_version FROM public.tag_taxonomy_versions WHERE id = p_taxonomy_version_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_NOT_FOUND');
  END IF;
  IF v_version.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAXONOMY_VERSION_RETIRED');
  END IF;

  -- Upsert on business_id (unique). Either update existing row's version or insert new.
  SELECT id INTO v_assignment_id
    FROM public.business_tag_taxonomy_assignments
   WHERE business_id = p_business_id;

  IF FOUND THEN
    UPDATE public.business_tag_taxonomy_assignments
       SET tag_taxonomy_version_id = p_taxonomy_version_id,
           assigned_at             = clock_timestamp(),
           assigned_by_user_id     = p_user_id,
           organization_id         = p_organization_id
     WHERE id = v_assignment_id;
  ELSE
    v_assignment_id := public.gen_uuid_v7();
    INSERT INTO public.business_tag_taxonomy_assignments(
      id, organization_id, business_id, tag_taxonomy_version_id, assigned_at, assigned_by_user_id
    ) VALUES (
      v_assignment_id, p_organization_id, p_business_id, p_taxonomy_version_id, clock_timestamp(), p_user_id
    );
  END IF;

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
