-- B08·P06 — Per-Business Custom Tags
--
-- Schema extensions: retired_at lifecycle + case-insensitive uniqueness.
-- 5 spec-canonical CRUD RPCs (Owner-only via can_perform, Mitigation A).

-- Replace B08·P01's case-sensitive UNIQUE(business_id, tag_name) with a
-- partial UNIQUE that's case-insensitive AND excludes retired rows (so
-- retired names can be reused).
ALTER TABLE public.business_custom_tags
  DROP CONSTRAINT IF EXISTS business_custom_tags_business_name_uq;

ALTER TABLE public.business_custom_tags
  ADD COLUMN IF NOT EXISTS retired_at         timestamptz,
  ADD COLUMN IF NOT EXISTS retired_by_user_id uuid REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS retirement_reason  text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'business_custom_tags_retired_chk') THEN
    ALTER TABLE public.business_custom_tags
      ADD CONSTRAINT business_custom_tags_retired_chk
        CHECK ((retired_at IS NULL) = (retirement_reason IS NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'business_custom_tags_name_length') THEN
    ALTER TABLE public.business_custom_tags
      ADD CONSTRAINT business_custom_tags_name_length
        CHECK (length(tag_name) BETWEEN 1 AND 60);
  END IF;
END$$;

CREATE UNIQUE INDEX IF NOT EXISTS business_custom_tags_active_name_uq
  ON public.business_custom_tags (business_id, LOWER(tag_name))
  WHERE retired_at IS NULL;

-- ============================================================================
-- create_custom_tag
-- ============================================================================
CREATE OR REPLACE FUNCTION public.create_custom_tag(
  p_actor_user_id          uuid,
  p_business_id            uuid,
  p_organization_id        uuid,
  p_tag_name               text,
  p_mapped_transaction_type public.transaction_type_enum
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_decision text;
  v_can jsonb;
  v_tag_id uuid := public.gen_uuid_v7();
  v_audit_row audit.audit_events;
  v_default_collides boolean;
  v_active_taxonomy public.tag_taxonomy_versions;
BEGIN
  IF p_business_id IS NULL OR p_organization_id IS NULL
     OR p_tag_name IS NULL OR p_mapped_transaction_type IS NULL THEN
    RAISE EXCEPTION 'create_custom_tag: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_tag_name) < 1 OR length(p_tag_name) > 60 THEN
    RAISE EXCEPTION 'create_custom_tag: tag_name length must be 1..60 (got %)', length(p_tag_name) USING ERRCODE='22023';
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'business_custom_tag', 'CREATE',
    jsonb_build_object('business_id', p_business_id, 'tag_name', p_tag_name,
                       'mapped_transaction_type', p_mapped_transaction_type::text),
    p_business_id, p_organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'CUSTOM_TAG_MUTATION_DENIED',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id => p_business_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => p_organization_id, p_business_id => p_business_id,
      p_reason => format('policy %s for CREATE custom tag %s', v_decision, p_tag_name),
      p_after_state => jsonb_build_object('decision', v_decision, 'tag_name', p_tag_name));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
      'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  -- Collision with platform default taxonomy (case-insensitive)
  SELECT * INTO v_active_taxonomy FROM public.get_active_taxonomy_for_business(p_business_id);
  IF FOUND THEN
    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_active_taxonomy.definition) AS entry
      WHERE LOWER(entry->>'tag_name') = LOWER(p_tag_name)
    ) INTO v_default_collides;
    IF v_default_collides THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'COLLIDES_WITH_DEFAULT_TAXONOMY',
        'tag_name', p_tag_name);
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.business_custom_tags
      (id, organization_id, business_id, tag_name, mapped_transaction_type,
       created_at, created_by_user_id)
    VALUES
      (v_tag_id, p_organization_id, p_business_id, p_tag_name, p_mapped_transaction_type,
       clock_timestamp(), p_actor_user_id);
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DUPLICATE_CUSTOM_TAG_NAME',
      'tag_name', p_tag_name);
  END;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CUSTOM_TAG_CREATED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => p_business_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => p_organization_id, p_business_id => p_business_id,
    p_after_state => jsonb_build_object(
      'custom_tag_id', v_tag_id,
      'tag_name', p_tag_name,
      'mapped_transaction_type', p_mapped_transaction_type::text),
    p_reason => format('custom tag created: %s → %s', p_tag_name, p_mapped_transaction_type::text));

  RETURN jsonb_build_object('ok', true,
    'custom_tag_id', v_tag_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.create_custom_tag(uuid, uuid, uuid, text, public.transaction_type_enum) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.create_custom_tag(uuid, uuid, uuid, text, public.transaction_type_enum) TO service_role;

-- ============================================================================
-- rename_custom_tag
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rename_custom_tag(
  p_actor_user_id uuid,
  p_custom_tag_id uuid,
  p_new_tag_name  text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tag public.business_custom_tags%ROWTYPE;
  v_can jsonb; v_decision text;
  v_audit_row audit.audit_events;
  v_active_taxonomy public.tag_taxonomy_versions;
  v_default_collides boolean;
BEGIN
  IF p_custom_tag_id IS NULL OR p_new_tag_name IS NULL THEN
    RAISE EXCEPTION 'rename_custom_tag: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_new_tag_name) < 1 OR length(p_new_tag_name) > 60 THEN
    RAISE EXCEPTION 'rename_custom_tag: new_tag_name length must be 1..60 (got %)', length(p_new_tag_name) USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tag FROM public.business_custom_tags WHERE id = p_custom_tag_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rename_custom_tag: tag % not found', p_custom_tag_id USING ERRCODE='02000';
  END IF;
  IF v_tag.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAG_RETIRED',
      'custom_tag_id', p_custom_tag_id);
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'business_custom_tag', 'RENAME',
    jsonb_build_object('custom_tag_id', p_custom_tag_id, 'new_tag_name', p_new_tag_name),
    v_tag.business_id, v_tag.organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'CUSTOM_TAG_MUTATION_DENIED',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id => v_tag.business_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
      p_reason => format('policy %s for RENAME custom tag %s', v_decision, p_custom_tag_id),
      p_after_state => jsonb_build_object('decision', v_decision, 'custom_tag_id', p_custom_tag_id));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
      'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  -- Default-taxonomy collision check on the new name
  SELECT * INTO v_active_taxonomy FROM public.get_active_taxonomy_for_business(v_tag.business_id);
  IF FOUND THEN
    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_active_taxonomy.definition) AS entry
      WHERE LOWER(entry->>'tag_name') = LOWER(p_new_tag_name)
    ) INTO v_default_collides;
    IF v_default_collides THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'COLLIDES_WITH_DEFAULT_TAXONOMY',
        'new_tag_name', p_new_tag_name);
    END IF;
  END IF;

  BEGIN
    UPDATE public.business_custom_tags
      SET tag_name = p_new_tag_name
      WHERE id = p_custom_tag_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DUPLICATE_CUSTOM_TAG_NAME',
      'new_tag_name', p_new_tag_name);
  END;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CUSTOM_TAG_RENAMED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => v_tag.business_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
    p_before_state => jsonb_build_object('tag_name', v_tag.tag_name),
    p_after_state => jsonb_build_object(
      'custom_tag_id', p_custom_tag_id,
      'previous_tag_name', v_tag.tag_name,
      'new_tag_name', p_new_tag_name,
      'mapped_transaction_type', v_tag.mapped_transaction_type::text),
    p_reason => format('custom tag renamed: %s → %s', v_tag.tag_name, p_new_tag_name));

  RETURN jsonb_build_object('ok', true,
    'custom_tag_id', p_custom_tag_id,
    'previous_tag_name', v_tag.tag_name,
    'new_tag_name', p_new_tag_name,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.rename_custom_tag(uuid, uuid, text) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.rename_custom_tag(uuid, uuid, text) TO service_role;

-- ============================================================================
-- remap_custom_tag
-- ============================================================================
CREATE OR REPLACE FUNCTION public.remap_custom_tag(
  p_actor_user_id              uuid,
  p_custom_tag_id              uuid,
  p_new_mapped_transaction_type public.transaction_type_enum,
  p_remap_reason               text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tag public.business_custom_tags%ROWTYPE;
  v_can jsonb; v_decision text;
  v_audit_row audit.audit_events;
BEGIN
  IF p_custom_tag_id IS NULL OR p_new_mapped_transaction_type IS NULL OR p_remap_reason IS NULL THEN
    RAISE EXCEPTION 'remap_custom_tag: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_remap_reason) < 1 OR length(p_remap_reason) > 1000 THEN
    RAISE EXCEPTION 'remap_custom_tag: remap_reason length must be 1..1000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tag FROM public.business_custom_tags WHERE id = p_custom_tag_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remap_custom_tag: tag % not found', p_custom_tag_id USING ERRCODE='02000';
  END IF;
  IF v_tag.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAG_RETIRED', 'custom_tag_id', p_custom_tag_id);
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'business_custom_tag', 'REMAP',
    jsonb_build_object('custom_tag_id', p_custom_tag_id,
                       'new_mapped_transaction_type', p_new_mapped_transaction_type::text),
    v_tag.business_id, v_tag.organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'CUSTOM_TAG_MUTATION_DENIED',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id => v_tag.business_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
      p_reason => format('policy %s for REMAP custom tag %s', v_decision, p_custom_tag_id),
      p_after_state => jsonb_build_object('decision', v_decision, 'custom_tag_id', p_custom_tag_id));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
      'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  IF v_tag.mapped_transaction_type = p_new_mapped_transaction_type THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'custom_tag_id', p_custom_tag_id,
      'mapped_transaction_type', v_tag.mapped_transaction_type::text);
  END IF;

  UPDATE public.business_custom_tags
    SET mapped_transaction_type = p_new_mapped_transaction_type
    WHERE id = p_custom_tag_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CUSTOM_TAG_REMAPPED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => v_tag.business_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
    p_before_state => jsonb_build_object(
      'mapped_transaction_type', v_tag.mapped_transaction_type::text),
    p_after_state => jsonb_build_object(
      'custom_tag_id', p_custom_tag_id,
      'tag_name', v_tag.tag_name,
      'previous_mapped_transaction_type', v_tag.mapped_transaction_type::text,
      'new_mapped_transaction_type', p_new_mapped_transaction_type::text,
      'remap_reason', p_remap_reason),
    p_reason => format('custom tag remapped: %s %s → %s (%s)',
                       v_tag.tag_name, v_tag.mapped_transaction_type::text,
                       p_new_mapped_transaction_type::text, left(p_remap_reason, 200)));

  RETURN jsonb_build_object('ok', true,
    'custom_tag_id', p_custom_tag_id,
    'previous_mapped_transaction_type', v_tag.mapped_transaction_type::text,
    'new_mapped_transaction_type', p_new_mapped_transaction_type::text,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.remap_custom_tag(uuid, uuid, public.transaction_type_enum, text) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.remap_custom_tag(uuid, uuid, public.transaction_type_enum, text) TO service_role;

-- ============================================================================
-- retire_custom_tag
-- ============================================================================
CREATE OR REPLACE FUNCTION public.retire_custom_tag(
  p_actor_user_id     uuid,
  p_custom_tag_id     uuid,
  p_retirement_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tag public.business_custom_tags%ROWTYPE;
  v_can jsonb; v_decision text;
  v_audit_row audit.audit_events;
BEGIN
  IF p_custom_tag_id IS NULL OR p_retirement_reason IS NULL THEN
    RAISE EXCEPTION 'retire_custom_tag: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_retirement_reason) < 1 OR length(p_retirement_reason) > 1000 THEN
    RAISE EXCEPTION 'retire_custom_tag: retirement_reason length must be 1..1000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tag FROM public.business_custom_tags WHERE id = p_custom_tag_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'retire_custom_tag: tag % not found', p_custom_tag_id USING ERRCODE='02000';
  END IF;
  IF v_tag.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'custom_tag_id', p_custom_tag_id, 'retired_at', v_tag.retired_at);
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'business_custom_tag', 'RETIRE',
    jsonb_build_object('custom_tag_id', p_custom_tag_id),
    v_tag.business_id, v_tag.organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'CUSTOM_TAG_MUTATION_DENIED',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id => v_tag.business_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
      p_reason => format('policy %s for RETIRE custom tag %s', v_decision, p_custom_tag_id),
      p_after_state => jsonb_build_object('decision', v_decision, 'custom_tag_id', p_custom_tag_id));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
      'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  UPDATE public.business_custom_tags
    SET retired_at = clock_timestamp(),
        retired_by_user_id = p_actor_user_id,
        retirement_reason = p_retirement_reason
    WHERE id = p_custom_tag_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CUSTOM_TAG_RETIRED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => v_tag.business_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
    p_after_state => jsonb_build_object(
      'custom_tag_id', p_custom_tag_id,
      'tag_name', v_tag.tag_name,
      'mapped_transaction_type', v_tag.mapped_transaction_type::text,
      'retirement_reason', p_retirement_reason),
    p_reason => format('custom tag retired: %s (%s)', v_tag.tag_name, left(p_retirement_reason, 200)));

  RETURN jsonb_build_object('ok', true,
    'custom_tag_id', p_custom_tag_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.retire_custom_tag(uuid, uuid, text) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.retire_custom_tag(uuid, uuid, text) TO service_role;

-- ============================================================================
-- restore_custom_tag
-- ============================================================================
CREATE OR REPLACE FUNCTION public.restore_custom_tag(
  p_actor_user_id uuid,
  p_custom_tag_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tag public.business_custom_tags%ROWTYPE;
  v_can jsonb; v_decision text;
  v_audit_row audit.audit_events;
  v_name_now_taken boolean;
BEGIN
  IF p_custom_tag_id IS NULL THEN
    RAISE EXCEPTION 'restore_custom_tag: p_custom_tag_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tag FROM public.business_custom_tags WHERE id = p_custom_tag_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'restore_custom_tag: tag % not found', p_custom_tag_id USING ERRCODE='02000';
  END IF;
  IF v_tag.retired_at IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'custom_tag_id', p_custom_tag_id);
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'business_custom_tag', 'RESTORE',
    jsonb_build_object('custom_tag_id', p_custom_tag_id),
    v_tag.business_id, v_tag.organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'CUSTOM_TAG_MUTATION_DENIED',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id => v_tag.business_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
      p_reason => format('policy %s for RESTORE custom tag %s', v_decision, p_custom_tag_id),
      p_after_state => jsonb_build_object('decision', v_decision, 'custom_tag_id', p_custom_tag_id));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
      'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.business_custom_tags
    WHERE business_id = v_tag.business_id
      AND LOWER(tag_name) = LOWER(v_tag.tag_name)
      AND id <> p_custom_tag_id
      AND retired_at IS NULL
  ) INTO v_name_now_taken;
  IF v_name_now_taken THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NAME_NOW_TAKEN',
      'tag_name', v_tag.tag_name);
  END IF;

  UPDATE public.business_custom_tags
    SET retired_at = NULL,
        retired_by_user_id = NULL,
        retirement_reason = NULL
    WHERE id = p_custom_tag_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CUSTOM_TAG_RESTORED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => v_tag.business_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tag.organization_id, p_business_id => v_tag.business_id,
    p_after_state => jsonb_build_object(
      'custom_tag_id', p_custom_tag_id,
      'tag_name', v_tag.tag_name,
      'mapped_transaction_type', v_tag.mapped_transaction_type::text),
    p_reason => format('custom tag restored: %s', v_tag.tag_name));

  RETURN jsonb_build_object('ok', true,
    'custom_tag_id', p_custom_tag_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.restore_custom_tag(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.restore_custom_tag(uuid, uuid) TO service_role;
