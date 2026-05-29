-- B08·P03 — Layer 2 Recurring Vendor Memory
--
-- Signature normalization (regex prefix-strip, lowercase, suffix-strip,
-- identifier-append) is Python — orchestrator-deferred. SQL ships:
--   1. vendor_memory_confidence_for_count helper (tier mapping)
--   2. lookup_vendor_memory (ACTIVE row by business + signature)
--   3. confirm_vendor_memory (upsert + tier promotion at 2→3 cross)
--   4. revoke_vendor_memory (status REVOKED, idempotent)
--   5. 5 spec-canonical audit events

-- ============================================================================
-- 1. Confidence-tier helper
-- ============================================================================
CREATE OR REPLACE FUNCTION public.vendor_memory_confidence_for_count(
  p_confirmations_count int
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_confirmations_count <= 0 THEN 0.0::numeric
    WHEN p_confirmations_count = 1 THEN 0.60::numeric
    WHEN p_confirmations_count = 2 THEN 0.72::numeric
    ELSE 0.88::numeric
  END;
$function$;
REVOKE ALL ON FUNCTION public.vendor_memory_confidence_for_count(int) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.vendor_memory_confidence_for_count(int) TO service_role, authenticated;

-- ============================================================================
-- 2. lookup_vendor_memory
-- ============================================================================
CREATE OR REPLACE FUNCTION public.lookup_vendor_memory(
  p_business_id             uuid,
  p_counterparty_signature  text,
  p_actor_user_id           uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row public.recurring_vendor_memory%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
  v_confidence numeric;
BEGIN
  IF p_business_id IS NULL OR p_counterparty_signature IS NULL
     OR length(p_counterparty_signature) = 0 THEN
    RAISE EXCEPTION 'lookup_vendor_memory: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_row FROM public.recurring_vendor_memory
    WHERE business_id = p_business_id
      AND counterparty_signature = p_counterparty_signature
      AND status = 'ACTIVE'::public.vendor_memory_status_enum
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('hit', false,
      'business_id', p_business_id,
      'counterparty_signature', p_counterparty_signature);
  END IF;
  v_confidence := public.vendor_memory_confidence_for_count(v_row.confirmations_count);

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer2';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'VENDOR_MEMORY_HIT',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => p_business_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_row.organization_id, p_business_id => p_business_id,
    p_after_state => jsonb_build_object(
      'vendor_memory_id',       v_row.id,
      'business_id',            p_business_id,
      'counterparty_signature', p_counterparty_signature,
      'suggested_type',         v_row.suggested_type::text,
      'suggested_tag',          v_row.suggested_tag,
      'confirmations_count',    v_row.confirmations_count,
      'confidence',             v_confidence),
    p_reason => format('vendor memory hit: business=%s signature=%s confidence=%s',
                       p_business_id, p_counterparty_signature, v_confidence));

  RETURN jsonb_build_object(
    'hit',                    true,
    'vendor_memory_id',       v_row.id,
    'suggested_type',         v_row.suggested_type::text,
    'suggested_tag',          v_row.suggested_tag,
    'confirmations_count',    v_row.confirmations_count,
    'confidence',             v_confidence,
    'audit_event_id',         v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.lookup_vendor_memory(uuid, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.lookup_vendor_memory(uuid, text, uuid) TO service_role;

-- ============================================================================
-- 3. confirm_vendor_memory  (upsert + tier promotion at 2→3 cross)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.confirm_vendor_memory(
  p_business_id             uuid,
  p_organization_id         uuid,
  p_counterparty_signature  text,
  p_suggested_type          public.transaction_type_enum,
  p_suggested_tag           text DEFAULT NULL,
  p_actor_user_id           uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_existing public.recurring_vendor_memory%ROWTYPE;
  v_id uuid := public.gen_uuid_v7();
  v_new_count int;
  v_was_created boolean := false;
  v_promoted boolean := false;
  v_audit_row audit.audit_events;
  v_audit_promo audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_business_id IS NULL OR p_organization_id IS NULL
     OR p_counterparty_signature IS NULL OR length(p_counterparty_signature) = 0
     OR p_suggested_type IS NULL THEN
    RAISE EXCEPTION 'confirm_vendor_memory: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_existing FROM public.recurring_vendor_memory
    WHERE business_id = p_business_id
      AND counterparty_signature = p_counterparty_signature
      AND status = 'ACTIVE'::public.vendor_memory_status_enum
    FOR UPDATE;
  IF FOUND THEN
    v_new_count := v_existing.confirmations_count + 1;
    UPDATE public.recurring_vendor_memory
      SET confirmations_count = v_new_count,
          last_confirmation_at = clock_timestamp(),
          suggested_type = p_suggested_type,
          suggested_tag  = p_suggested_tag,
          updated_at = clock_timestamp()
      WHERE id = v_existing.id;
    v_id := v_existing.id;
    -- Promotion fires exactly once: when count crosses from 2 → 3
    IF v_existing.confirmations_count = 2 AND v_new_count = 3 THEN
      v_promoted := true;
    END IF;
  ELSE
    INSERT INTO public.recurring_vendor_memory
      (id, organization_id, business_id, counterparty_signature,
       suggested_type, suggested_tag, confirmations_count,
       first_seen_at, last_confirmation_at, status, created_at, updated_at)
    VALUES
      (v_id, p_organization_id, p_business_id, p_counterparty_signature,
       p_suggested_type, p_suggested_tag, 1,
       clock_timestamp(), clock_timestamp(), 'ACTIVE'::public.vendor_memory_status_enum,
       clock_timestamp(), clock_timestamp());
    v_new_count := 1;
    v_was_created := true;
  END IF;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer2';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind,
    p_action     => CASE WHEN v_was_created THEN 'VENDOR_MEMORY_CREATED' ELSE 'VENDOR_MEMORY_CONFIRMED' END,
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => p_business_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => p_organization_id, p_business_id => p_business_id,
    p_after_state => jsonb_build_object(
      'vendor_memory_id',       v_id,
      'counterparty_signature', p_counterparty_signature,
      'suggested_type',         p_suggested_type::text,
      'suggested_tag',          p_suggested_tag,
      'confirmations_count',    v_new_count,
      'was_created',            v_was_created),
    p_reason => format('vendor memory %s: %s count=%s',
                       CASE WHEN v_was_created THEN 'created' ELSE 'confirmed' END,
                       p_counterparty_signature, v_new_count));

  IF v_promoted THEN
    v_audit_promo := audit.emit_audit(
      p_actor_kind => v_kind, p_action => 'VENDOR_MEMORY_PROMOTED_TO_HIGH',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id => p_business_id,
      p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
      p_organization_id => p_organization_id, p_business_id => p_business_id,
      p_after_state => jsonb_build_object(
        'vendor_memory_id',       v_id,
        'counterparty_signature', p_counterparty_signature,
        'suggested_type',         p_suggested_type::text,
        'confirmations_count',    v_new_count,
        'new_confidence',         0.88),
      p_reason => format('vendor memory promoted to HIGH: %s reached 3 confirmations',
                         p_counterparty_signature));
  END IF;

  RETURN jsonb_build_object('ok', true,
    'vendor_memory_id',       v_id,
    'confirmations_count',    v_new_count,
    'was_created',            v_was_created,
    'promoted_to_high',       v_promoted,
    'confidence',             public.vendor_memory_confidence_for_count(v_new_count),
    'audit_event_id',         v_audit_row.id,
    'promotion_audit_event_id', CASE WHEN v_promoted THEN v_audit_promo.id ELSE NULL END);
END;
$function$;
REVOKE ALL ON FUNCTION public.confirm_vendor_memory(uuid, uuid, text, public.transaction_type_enum, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.confirm_vendor_memory(uuid, uuid, text, public.transaction_type_enum, text, uuid) TO service_role;

-- ============================================================================
-- 4. revoke_vendor_memory
-- ============================================================================
CREATE OR REPLACE FUNCTION public.revoke_vendor_memory(
  p_vendor_memory_id uuid,
  p_actor_user_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row public.recurring_vendor_memory%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_vendor_memory_id IS NULL THEN
    RAISE EXCEPTION 'revoke_vendor_memory: p_vendor_memory_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_row FROM public.recurring_vendor_memory WHERE id = p_vendor_memory_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'VENDOR_MEMORY_NOT_FOUND',
      'vendor_memory_id', p_vendor_memory_id);
  END IF;
  IF v_row.status = 'REVOKED'::public.vendor_memory_status_enum THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'vendor_memory_id', p_vendor_memory_id);
  END IF;
  UPDATE public.recurring_vendor_memory
    SET status = 'REVOKED'::public.vendor_memory_status_enum,
        updated_at = clock_timestamp()
    WHERE id = p_vendor_memory_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer2';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'VENDOR_MEMORY_REVOKED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => v_row.business_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_row.organization_id, p_business_id => v_row.business_id,
    p_after_state => jsonb_build_object(
      'vendor_memory_id',       p_vendor_memory_id,
      'counterparty_signature', v_row.counterparty_signature,
      'previous_confirmations_count', v_row.confirmations_count,
      'previous_suggested_type', v_row.suggested_type::text),
    p_reason => format('vendor memory revoked: %s (prior count=%s)',
                       v_row.counterparty_signature, v_row.confirmations_count));

  RETURN jsonb_build_object('ok', true,
    'vendor_memory_id', p_vendor_memory_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.revoke_vendor_memory(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.revoke_vendor_memory(uuid, uuid) TO service_role;
