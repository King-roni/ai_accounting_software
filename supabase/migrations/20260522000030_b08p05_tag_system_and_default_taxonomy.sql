-- B08·P05 — Tag System & Default Taxonomy
--
-- Tag-assignment logic (Layer 1/2/3 → primary tag, fallback to type default)
-- is Python orchestrator. SQL ships:
--   1. Default Cyprus taxonomy seed (17 entries; is_default=true)
--   2. get_active_taxonomy_for_business + get_default_tag_for_type helpers
--   3. validate_tag_against_taxonomy (active taxonomy + business custom tags)
--   4. 4 spec-canonical audit RPCs
--
-- The secondary_tags update path is the only direct write to transactions
-- in this phase (analytics-only metadata, no ledger effect per spec).

INSERT INTO public.tag_taxonomy_versions (id, version_label, definition, is_default, created_at)
VALUES
  (public.gen_uuid_v7(), 'cyprus-default-2026-05',
   jsonb_build_array(
     jsonb_build_object('tag_name','Software & subscriptions',     'transaction_type','OUT_EXPENSE',                  'is_type_default', true),
     jsonb_build_object('tag_name','Office expenses',              'transaction_type','OUT_EXPENSE',                  'is_type_default', false),
     jsonb_build_object('tag_name','Travel & transport',           'transaction_type','OUT_EXPENSE',                  'is_type_default', false),
     jsonb_build_object('tag_name','Marketing & advertising',      'transaction_type','OUT_EXPENSE',                  'is_type_default', false),
     jsonb_build_object('tag_name','Professional services',        'transaction_type','OUT_EXPENSE',                  'is_type_default', false),
     jsonb_build_object('tag_name','Contractor payment',           'transaction_type','PAYROLL_OR_TEAM_PAYMENT',       'is_type_default', true),
     jsonb_build_object('tag_name','Team member invoice',          'transaction_type','PAYROLL_OR_TEAM_PAYMENT',       'is_type_default', false),
     jsonb_build_object('tag_name','Bank fees',                    'transaction_type','BANK_FEE',                     'is_type_default', true),
     jsonb_build_object('tag_name','Tax payment',                  'transaction_type','TAX_PAYMENT',                  'is_type_default', true),
     jsonb_build_object('tag_name','Internal transfer',            'transaction_type','INTERNAL_TRANSFER',             'is_type_default', true),
     jsonb_build_object('tag_name','Currency exchange',            'transaction_type','FX_EXCHANGE',                  'is_type_default', true),
     jsonb_build_object('tag_name','Customer payment',             'transaction_type','IN_INCOME',                    'is_type_default', true),
     jsonb_build_object('tag_name','Refund received',              'transaction_type','REFUND_IN',                    'is_type_default', true),
     jsonb_build_object('tag_name','Refund issued',                'transaction_type','REFUND_OUT',                   'is_type_default', true),
     jsonb_build_object('tag_name','Chargeback',                   'transaction_type','CHARGEBACK',                   'is_type_default', true),
     jsonb_build_object('tag_name','Loan / shareholder movement',  'transaction_type','LOAN_OR_SHAREHOLDER_MOVEMENT',  'is_type_default', true),
     jsonb_build_object('tag_name','Unknown',                      'transaction_type','UNKNOWN',                      'is_type_default', true)
   ),
   true, clock_timestamp())
ON CONFLICT (version_label) DO NOTHING;

-- ============================================================================
-- get_active_taxonomy_for_business — returns assigned row, else platform default
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_active_taxonomy_for_business(
  p_business_id uuid
) RETURNS public.tag_taxonomy_versions
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT v.*
  FROM public.business_tag_taxonomy_assignments a
  JOIN public.tag_taxonomy_versions v ON v.id = a.tag_taxonomy_version_id
  WHERE a.business_id = p_business_id
  UNION ALL
  SELECT *
  FROM public.tag_taxonomy_versions
  WHERE is_default = true
    AND NOT EXISTS (
      SELECT 1 FROM public.business_tag_taxonomy_assignments
      WHERE business_id = p_business_id
    )
  LIMIT 1;
$function$;
REVOKE ALL ON FUNCTION public.get_active_taxonomy_for_business(uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.get_active_taxonomy_for_business(uuid) TO service_role, authenticated;

-- ============================================================================
-- get_default_tag_for_type — per-type default tag from the active taxonomy
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_default_tag_for_type(
  p_business_id      uuid,
  p_transaction_type public.transaction_type_enum
) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_active_taxonomy public.tag_taxonomy_versions;
  v_tag text;
BEGIN
  SELECT * INTO v_active_taxonomy FROM public.get_active_taxonomy_for_business(p_business_id);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT (entry->>'tag_name') INTO v_tag
    FROM jsonb_array_elements(v_active_taxonomy.definition) AS entry
    WHERE entry->>'transaction_type' = p_transaction_type::text
      AND COALESCE((entry->>'is_type_default')::boolean, false) = true
    LIMIT 1;
  RETURN v_tag;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_default_tag_for_type(uuid, public.transaction_type_enum) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.get_default_tag_for_type(uuid, public.transaction_type_enum) TO service_role, authenticated;

-- ============================================================================
-- validate_tag_against_taxonomy — active taxonomy + business custom tags
-- ============================================================================
CREATE OR REPLACE FUNCTION public.validate_tag_against_taxonomy(
  p_business_id      uuid,
  p_tag_name         text,
  p_transaction_type public.transaction_type_enum
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_active public.tag_taxonomy_versions;
  v_entry_matches_type boolean;
  v_custom_match text;
BEGIN
  IF p_business_id IS NULL OR p_tag_name IS NULL OR p_transaction_type IS NULL THEN
    RAISE EXCEPTION 'validate_tag_against_taxonomy: required params missing' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_active FROM public.get_active_taxonomy_for_business(p_business_id);
  IF FOUND THEN
    SELECT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_active.definition) AS entry
      WHERE entry->>'tag_name' = p_tag_name
        AND entry->>'transaction_type' = p_transaction_type::text
    ) INTO v_entry_matches_type;
    IF v_entry_matches_type THEN
      RETURN jsonb_build_object('valid', true, 'source', 'TAXONOMY',
        'taxonomy_version_id', v_active.id);
    END IF;
  END IF;

  -- Custom tag fallback
  SELECT tag_name INTO v_custom_match FROM public.business_custom_tags
    WHERE business_id = p_business_id
      AND tag_name = p_tag_name
      AND mapped_transaction_type = p_transaction_type;
  IF v_custom_match IS NOT NULL THEN
    RETURN jsonb_build_object('valid', true, 'source', 'CUSTOM');
  END IF;

  RETURN jsonb_build_object('valid', false,
    'reason', 'TAG_NOT_IN_TAXONOMY_OR_CUSTOM',
    'tag_name', p_tag_name,
    'transaction_type', p_transaction_type::text);
END;
$function$;
REVOKE ALL ON FUNCTION public.validate_tag_against_taxonomy(uuid, text, public.transaction_type_enum) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.validate_tag_against_taxonomy(uuid, text, public.transaction_type_enum) TO service_role, authenticated;

-- ============================================================================
-- record_tag_assigned
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_tag_assigned(
  p_transaction_id uuid,
  p_primary_tag    text,
  p_source         public.classification_method_enum,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_validation jsonb;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_primary_tag IS NULL OR p_source IS NULL THEN
    RAISE EXCEPTION 'record_tag_assigned: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_tag_assigned: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  v_validation := public.validate_tag_against_taxonomy(v_tx.business_id, p_primary_tag, v_tx.transaction_type);
  IF (v_validation->>'valid')::bool IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'TAG_NOT_VALID_FOR_TYPE',
      'validation', v_validation);
  END IF;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'tag_system';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'TAG_ASSIGNED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'primary_tag', p_primary_tag,
      'source', p_source::text,
      'tag_source', v_validation->>'source'),
    p_reason => format('tag assigned: tx=%s tag=%s source=%s', p_transaction_id, p_primary_tag, p_source::text));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'primary_tag', p_primary_tag,
    'tag_source', v_validation->>'source',
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_tag_assigned(uuid, text, public.classification_method_enum, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_tag_assigned(uuid, text, public.classification_method_enum, uuid) TO service_role;

-- ============================================================================
-- record_secondary_tag_added — direct UPDATE of transactions.secondary_tags
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_secondary_tag_added(
  p_transaction_id uuid,
  p_tag_name       text,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_already boolean;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_tag_name IS NULL OR length(p_tag_name) = 0 THEN
    RAISE EXCEPTION 'record_secondary_tag_added: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_secondary_tag_added: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(v_tx.secondary_tags, '[]'::jsonb)) AS t WHERE t = p_tag_name)
    INTO v_already;
  IF v_already THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'transaction_id', p_transaction_id, 'tag_name', p_tag_name);
  END IF;

  UPDATE public.transactions
    SET secondary_tags = COALESCE(secondary_tags, '[]'::jsonb) || jsonb_build_array(p_tag_name),
        updated_at = clock_timestamp()
    WHERE id = p_transaction_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'tag_system';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'SECONDARY_TAG_ADDED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'tag_name', p_tag_name),
    p_reason => format('secondary tag added: tx=%s tag=%s', p_transaction_id, p_tag_name));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'tag_name', p_tag_name,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_secondary_tag_added(uuid, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_secondary_tag_added(uuid, text, uuid) TO service_role;

-- ============================================================================
-- record_tag_overridden_by_user
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_tag_overridden_by_user(
  p_transaction_id uuid,
  p_previous_tag   text,
  p_new_tag        text,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_validation jsonb;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_previous_tag IS NULL OR p_new_tag IS NULL THEN
    RAISE EXCEPTION 'record_tag_overridden_by_user: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_tag_overridden_by_user: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  v_validation := public.validate_tag_against_taxonomy(v_tx.business_id, p_new_tag, v_tx.transaction_type);
  IF (v_validation->>'valid')::bool IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NEW_TAG_NOT_VALID_FOR_TYPE',
      'validation', v_validation);
  END IF;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'tag_system';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'TAG_OVERRIDDEN_BY_USER',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_before_state => jsonb_build_object('primary_tag', p_previous_tag),
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'previous_tag', p_previous_tag,
      'new_tag', p_new_tag,
      'tag_source', v_validation->>'source'),
    p_reason => format('tag overridden by user: tx=%s %s → %s',
                       p_transaction_id, p_previous_tag, p_new_tag));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'previous_tag', p_previous_tag, 'new_tag', p_new_tag,
    'tag_source', v_validation->>'source',
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_tag_overridden_by_user(uuid, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_tag_overridden_by_user(uuid, text, text, uuid) TO service_role;

-- ============================================================================
-- record_tag_default_fallback_used  (telemetry)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_tag_default_fallback_used(
  p_transaction_id   uuid,
  p_transaction_type public.transaction_type_enum,
  p_fallback_tag     text,
  p_actor_user_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_transaction_type IS NULL OR p_fallback_tag IS NULL THEN
    RAISE EXCEPTION 'record_tag_default_fallback_used: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_tag_default_fallback_used: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'tag_system';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'TAG_DEFAULT_FALLBACK_USED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'transaction_type', p_transaction_type::text,
      'fallback_tag', p_fallback_tag),
    p_reason => format('tag default fallback used: tx=%s type=%s tag=%s',
                       p_transaction_id, p_transaction_type::text, p_fallback_tag));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'fallback_tag', p_fallback_tag,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_tag_default_fallback_used(uuid, public.transaction_type_enum, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_tag_default_fallback_used(uuid, public.transaction_type_enum, text, uuid) TO service_role;
