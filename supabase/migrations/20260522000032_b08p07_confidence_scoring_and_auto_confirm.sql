-- B08·P07 — Confidence Scoring & Auto-Confirm
--
-- Enum reconciliation: spec uses AUTO_CONFIRMED, but
-- transaction_classification_status_enum has CONFIRMED. We use existing
-- CONFIRMED for both auto and user-confirmed paths; the audit events
-- CLASSIFICATION_AUTO_CONFIRMED vs CLASSIFICATION_USER_CONFIRMED distinguish.
-- Reservation note in taxonomy.

CREATE TABLE IF NOT EXISTS public.classification_auto_confirm_thresholds (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  business_id         uuid REFERENCES public.business_entities(id),
  transaction_type    public.transaction_type_enum NOT NULL,
  threshold           numeric(3,2) NOT NULL DEFAULT 0.85,
  never_auto_confirm  boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT classification_auto_confirm_thresholds_range CHECK (threshold BETWEEN 0.0 AND 1.0),
  CONSTRAINT classification_auto_confirm_thresholds_uq UNIQUE NULLS NOT DISTINCT (business_id, transaction_type)
);

REVOKE ALL ON public.classification_auto_confirm_thresholds FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.classification_auto_confirm_thresholds TO service_role, authenticated;

-- Seed 12 global defaults (NULL business_id) per spec
INSERT INTO public.classification_auto_confirm_thresholds (business_id, transaction_type, threshold, never_auto_confirm)
VALUES
  (NULL, 'INTERNAL_TRANSFER',           0.80, false),
  (NULL, 'BANK_FEE',                    0.75, false),
  (NULL, 'FX_EXCHANGE',                 0.80, false),
  (NULL, 'OUT_EXPENSE',                 0.85, false),
  (NULL, 'IN_INCOME',                   0.85, false),
  (NULL, 'REFUND_IN',                   0.85, false),
  (NULL, 'REFUND_OUT',                  0.85, false),
  (NULL, 'CHARGEBACK',                  0.85, false),
  (NULL, 'PAYROLL_OR_TEAM_PAYMENT',     0.90, false),
  (NULL, 'TAX_PAYMENT',                 0.90, false),
  (NULL, 'LOAN_OR_SHAREHOLDER_MOVEMENT',0.95, false),
  (NULL, 'UNKNOWN',                     1.00, true)
ON CONFLICT (business_id, transaction_type) DO NOTHING;

-- ============================================================================
-- get_auto_confirm_threshold
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_auto_confirm_threshold(
  p_business_id uuid,
  p_transaction_type public.transaction_type_enum
) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row public.classification_auto_confirm_thresholds%ROWTYPE;
BEGIN
  -- Per-business override
  SELECT * INTO v_row FROM public.classification_auto_confirm_thresholds
    WHERE business_id = p_business_id AND transaction_type = p_transaction_type
    LIMIT 1;
  IF FOUND THEN
    IF v_row.never_auto_confirm THEN RETURN NULL; END IF;
    RETURN v_row.threshold;
  END IF;
  -- Global default
  SELECT * INTO v_row FROM public.classification_auto_confirm_thresholds
    WHERE business_id IS NULL AND transaction_type = p_transaction_type
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_row.never_auto_confirm THEN RETURN NULL; END IF;
  RETURN v_row.threshold;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_auto_confirm_threshold(uuid, public.transaction_type_enum) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.get_auto_confirm_threshold(uuid, public.transaction_type_enum) TO service_role, authenticated;

-- ============================================================================
-- merge_layer_confidence
-- ============================================================================
CREATE OR REPLACE FUNCTION public.merge_layer_confidence(
  p_l1_conf numeric, p_l1_type public.transaction_type_enum,
  p_l2_conf numeric, p_l2_type public.transaction_type_enum,
  p_l3_conf numeric, p_l3_type public.transaction_type_enum
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  v_winner_type public.transaction_type_enum;
  v_winner_conf numeric;
  v_other_types_count int;
  v_agreeing_count int;
  v_base_conf numeric;
  v_merged numeric;
  v_boost boolean := false;
  v_penalty boolean := false;
  v_contributing text[] := '{}';
BEGIN
  IF p_l1_conf IS NULL AND p_l2_conf IS NULL AND p_l3_conf IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_LAYER_RESULTS');
  END IF;

  -- Winner = layer with highest confidence
  v_winner_conf := -1;
  IF p_l1_conf IS NOT NULL THEN
    v_contributing := v_contributing || ARRAY['L1'];
    IF p_l1_conf > v_winner_conf THEN v_winner_conf := p_l1_conf; v_winner_type := p_l1_type; END IF;
  END IF;
  IF p_l2_conf IS NOT NULL THEN
    v_contributing := v_contributing || ARRAY['L2'];
    IF p_l2_conf > v_winner_conf THEN v_winner_conf := p_l2_conf; v_winner_type := p_l2_type; END IF;
  END IF;
  IF p_l3_conf IS NOT NULL THEN
    v_contributing := v_contributing || ARRAY['L3'];
    IF p_l3_conf > v_winner_conf THEN v_winner_conf := p_l3_conf; v_winner_type := p_l3_type; END IF;
  END IF;

  -- Count layers agreeing with winner type
  v_agreeing_count := 0;
  IF p_l1_conf IS NOT NULL AND p_l1_type = v_winner_type THEN v_agreeing_count := v_agreeing_count + 1; END IF;
  IF p_l2_conf IS NOT NULL AND p_l2_type = v_winner_type THEN v_agreeing_count := v_agreeing_count + 1; END IF;
  IF p_l3_conf IS NOT NULL AND p_l3_type = v_winner_type THEN v_agreeing_count := v_agreeing_count + 1; END IF;

  -- Count distinct non-winner types
  v_other_types_count := 0;
  IF p_l1_conf IS NOT NULL AND p_l1_type <> v_winner_type THEN v_other_types_count := v_other_types_count + 1; END IF;
  IF p_l2_conf IS NOT NULL AND p_l2_type <> v_winner_type THEN v_other_types_count := v_other_types_count + 1; END IF;
  IF p_l3_conf IS NOT NULL AND p_l3_type <> v_winner_type THEN v_other_types_count := v_other_types_count + 1; END IF;

  v_base_conf := v_winner_conf;
  v_merged := v_base_conf;

  -- Multi-layer agreement boost: ≥2 layers agree on winner type
  IF v_agreeing_count >= 2 THEN
    v_merged := LEAST(0.95, v_merged + 0.10);
    v_boost := true;
  END IF;

  -- Disagreement penalty: any non-winner type present
  IF v_other_types_count >= 1 THEN
    v_merged := GREATEST(0.0, v_merged - 0.10);
    v_penalty := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'chosen_type', v_winner_type::text,
    'base_confidence', v_base_conf,
    'merged_confidence', v_merged,
    'agreement_boost_applied', v_boost,
    'disagreement_penalty_applied', v_penalty,
    'agreeing_count', v_agreeing_count,
    'other_types_count', v_other_types_count,
    'contributing_layers', to_jsonb(v_contributing));
END;
$function$;
REVOKE ALL ON FUNCTION public.merge_layer_confidence(numeric, public.transaction_type_enum, numeric, public.transaction_type_enum, numeric, public.transaction_type_enum) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.merge_layer_confidence(numeric, public.transaction_type_enum, numeric, public.transaction_type_enum, numeric, public.transaction_type_enum) TO service_role, authenticated;

-- ============================================================================
-- record_classification_auto_confirmed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_auto_confirmed(
  p_transaction_id   uuid,
  p_merged_confidence numeric,
  p_chosen_type       public.transaction_type_enum,
  p_classification_method public.classification_method_enum,
  p_chosen_tag        text DEFAULT NULL,
  p_actor_user_id     uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_threshold numeric;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_merged_confidence IS NULL OR p_chosen_type IS NULL
     OR p_classification_method IS NULL THEN
    RAISE EXCEPTION 'record_classification_auto_confirmed: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_merged_confidence < 0 OR p_merged_confidence > 1 THEN
    RAISE EXCEPTION 'record_classification_auto_confirmed: merged_confidence must be in [0,1]' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_auto_confirmed: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  v_threshold := public.get_auto_confirm_threshold(v_tx.business_id, p_chosen_type);
  IF v_threshold IS NULL OR p_merged_confidence < v_threshold THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'THRESHOLD_NOT_MET',
      'merged_confidence', p_merged_confidence,
      'threshold', v_threshold,
      'chosen_type', p_chosen_type::text);
  END IF;

  UPDATE public.transactions
    SET transaction_type = p_chosen_type,
        system_tag = COALESCE(p_chosen_tag, system_tag),
        classification_status = 'CONFIRMED'::public.transaction_classification_status_enum,
        classification_confidence = p_merged_confidence,
        classification_method = p_classification_method,
        updated_at = clock_timestamp()
    WHERE id = p_transaction_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_confidence';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'CLASSIFICATION_AUTO_CONFIRMED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'chosen_type', p_chosen_type::text,
      'chosen_tag', p_chosen_tag,
      'merged_confidence', p_merged_confidence,
      'threshold', v_threshold,
      'classification_method', p_classification_method::text),
    p_reason => format('classification auto-confirmed: tx=%s type=%s confidence=%s threshold=%s',
                       p_transaction_id, p_chosen_type::text, p_merged_confidence, v_threshold));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'chosen_type', p_chosen_type::text,
    'merged_confidence', p_merged_confidence,
    'threshold', v_threshold,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_classification_auto_confirmed(uuid, numeric, public.transaction_type_enum, public.classification_method_enum, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_auto_confirmed(uuid, numeric, public.transaction_type_enum, public.classification_method_enum, text, uuid) TO service_role;

-- ============================================================================
-- record_classification_needs_confirmation
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_needs_confirmation(
  p_transaction_id   uuid,
  p_workflow_run_id  uuid,
  p_merged_confidence numeric,
  p_chosen_type       public.transaction_type_enum,
  p_classification_method public.classification_method_enum,
  p_chosen_tag        text DEFAULT NULL,
  p_actor_user_id     uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_threshold numeric;
  v_gap numeric;
  v_severity public.review_issue_severity_enum;
  v_review_id uuid := public.gen_uuid_v7();
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_workflow_run_id IS NULL
     OR p_merged_confidence IS NULL OR p_chosen_type IS NULL
     OR p_classification_method IS NULL THEN
    RAISE EXCEPTION 'record_classification_needs_confirmation: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_merged_confidence < 0 OR p_merged_confidence > 1 THEN
    RAISE EXCEPTION 'record_classification_needs_confirmation: merged_confidence must be in [0,1]' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_needs_confirmation: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  v_threshold := public.get_auto_confirm_threshold(v_tx.business_id, p_chosen_type);
  -- never_auto_confirm types have threshold NULL; treat as gap = 1.0 (always HIGH)
  v_gap := COALESCE(v_threshold, 1.0) - p_merged_confidence;
  IF v_gap <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'CONFIDENCE_AT_OR_ABOVE_THRESHOLD',
      'merged_confidence', p_merged_confidence, 'threshold', v_threshold);
  END IF;

  -- Severity derivation per spec
  IF v_gap <= 0.10 THEN
    v_severity := 'LOW'::public.review_issue_severity_enum;
  ELSIF v_gap <= 0.30 THEN
    v_severity := 'MEDIUM'::public.review_issue_severity_enum;
  ELSE
    v_severity := 'HIGH'::public.review_issue_severity_enum;
  END IF;

  UPDATE public.transactions
    SET transaction_type = p_chosen_type,
        system_tag = COALESCE(p_chosen_tag, system_tag),
        classification_status = 'NEEDS_CONFIRMATION'::public.transaction_classification_status_enum,
        classification_confidence = p_merged_confidence,
        classification_method = p_classification_method,
        updated_at = clock_timestamp()
    WHERE id = p_transaction_id;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_id, v_tx.organization_id, v_tx.business_id, p_workflow_run_id, p_transaction_id,
     'classification.needs_confirmation',
     'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
     v_severity,
     format('Confirm or adjust the classification of this transaction'),
     format('The classifier suggests %s (confidence %s) but is below the auto-confirm threshold %s. Please confirm, override with a different type, or mark this suggestion as wrong.',
            p_chosen_type::text, p_merged_confidence, COALESCE(v_threshold::text, 'never auto-confirm')),
     jsonb_build_object(
       'transaction_id', p_transaction_id,
       'suggested_type', p_chosen_type::text,
       'suggested_tag', p_chosen_tag,
       'merged_confidence', p_merged_confidence,
       'threshold', v_threshold,
       'gap', v_gap,
       'classification_method', p_classification_method::text),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_confidence';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'CLASSIFICATION_NEEDS_CONFIRMATION',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'review_issue_id', v_review_id,
      'severity', v_severity::text,
      'chosen_type', p_chosen_type::text,
      'merged_confidence', p_merged_confidence,
      'threshold', v_threshold,
      'gap', v_gap),
    p_reason => format('classification needs confirmation: tx=%s gap=%s severity=%s',
                       p_transaction_id, v_gap, v_severity::text));

  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'review_issue_id', v_review_id,
    'severity', v_severity::text,
    'gap', v_gap,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_classification_needs_confirmation(uuid, uuid, numeric, public.transaction_type_enum, public.classification_method_enum, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_needs_confirmation(uuid, uuid, numeric, public.transaction_type_enum, public.classification_method_enum, text, uuid) TO service_role;

-- ============================================================================
-- record_classification_user_confirmed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_user_confirmed(
  p_review_issue_id uuid,
  p_transaction_id  uuid,
  p_actor_user_id   uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_review public.review_issues%ROWTYPE;
  v_audit_row audit.audit_events;
BEGIN
  IF p_review_issue_id IS NULL OR p_transaction_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'record_classification_user_confirmed: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_confirmed: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  SELECT * INTO v_review FROM public.review_issues WHERE id = p_review_issue_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_confirmed: review_issue % not found', p_review_issue_id USING ERRCODE='02000';
  END IF;

  UPDATE public.transactions
    SET classification_status = 'CONFIRMED'::public.transaction_classification_status_enum,
        updated_at = clock_timestamp()
    WHERE id = p_transaction_id;
  UPDATE public.review_issues
    SET status = 'RESOLVED'::public.review_issue_status_enum,
        resolved_by = p_actor_user_id,
        resolved_at = clock_timestamp(),
        resolution_action = 'CONFIRM',
        updated_at = clock_timestamp()
    WHERE id = p_review_issue_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CLASSIFICATION_USER_CONFIRMED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'review_issue_id', p_review_issue_id,
      'confirmed_type', v_tx.transaction_type::text),
    p_reason => format('user confirmed classification: tx=%s', p_transaction_id));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_classification_user_confirmed(uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_user_confirmed(uuid, uuid, uuid) TO service_role;

-- ============================================================================
-- record_classification_user_overridden
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_user_overridden(
  p_review_issue_id uuid,
  p_transaction_id  uuid,
  p_new_type        public.transaction_type_enum,
  p_actor_user_id   uuid,
  p_new_tag         text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_review public.review_issues%ROWTYPE;
  v_audit_row audit.audit_events;
  v_previous_type public.transaction_type_enum;
BEGIN
  IF p_review_issue_id IS NULL OR p_transaction_id IS NULL OR p_new_type IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'record_classification_user_overridden: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_overridden: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  SELECT * INTO v_review FROM public.review_issues WHERE id = p_review_issue_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_overridden: review_issue % not found', p_review_issue_id USING ERRCODE='02000';
  END IF;
  v_previous_type := v_tx.transaction_type;

  UPDATE public.transactions
    SET transaction_type = p_new_type,
        user_tag = COALESCE(p_new_tag, user_tag),
        classification_status = 'CONFIRMED'::public.transaction_classification_status_enum,
        classification_method = 'MANUAL'::public.classification_method_enum,
        updated_at = clock_timestamp()
    WHERE id = p_transaction_id;
  UPDATE public.review_issues
    SET status = 'RESOLVED'::public.review_issue_status_enum,
        resolved_by = p_actor_user_id,
        resolved_at = clock_timestamp(),
        resolution_action = 'OVERRIDE',
        updated_at = clock_timestamp()
    WHERE id = p_review_issue_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CLASSIFICATION_USER_OVERRIDDEN',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_before_state => jsonb_build_object('transaction_type', v_previous_type::text),
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'review_issue_id', p_review_issue_id,
      'previous_type', v_previous_type::text,
      'new_type', p_new_type::text,
      'new_tag', p_new_tag),
    p_reason => format('user overrode classification: tx=%s %s → %s',
                       p_transaction_id, v_previous_type::text, p_new_type::text));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'previous_type', v_previous_type::text,
    'new_type', p_new_type::text,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_classification_user_overridden(uuid, uuid, public.transaction_type_enum, uuid, text) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_user_overridden(uuid, uuid, public.transaction_type_enum, uuid, text) TO service_role;

-- ============================================================================
-- record_classification_user_rejected
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_user_rejected(
  p_review_issue_id  uuid,
  p_transaction_id   uuid,
  p_actor_user_id    uuid,
  p_vendor_memory_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_review public.review_issues%ROWTYPE;
  v_audit_row audit.audit_events;
  v_revoked jsonb;
BEGIN
  IF p_review_issue_id IS NULL OR p_transaction_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'record_classification_user_rejected: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_rejected: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  SELECT * INTO v_review FROM public.review_issues WHERE id = p_review_issue_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_rejected: review_issue % not found', p_review_issue_id USING ERRCODE='02000';
  END IF;

  UPDATE public.review_issues
    SET status = 'RESOLVED'::public.review_issue_status_enum,
        resolved_by = p_actor_user_id,
        resolved_at = clock_timestamp(),
        resolution_action = 'REJECT',
        updated_at = clock_timestamp()
    WHERE id = p_review_issue_id;

  IF p_vendor_memory_id IS NOT NULL THEN
    v_revoked := public.revoke_vendor_memory(p_vendor_memory_id, p_actor_user_id);
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CLASSIFICATION_USER_REJECTED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'review_issue_id', p_review_issue_id,
      'vendor_memory_revoked_id', p_vendor_memory_id,
      'revoke_envelope', v_revoked),
    p_reason => format('user rejected classification: tx=%s (vendor_memory_revoked=%s)',
                       p_transaction_id, p_vendor_memory_id));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'vendor_memory_revoked', p_vendor_memory_id IS NOT NULL,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_classification_user_rejected(uuid, uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_user_rejected(uuid, uuid, uuid, uuid) TO service_role;

-- ============================================================================
-- record_multi_layer_agreement_boost (telemetry)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_multi_layer_agreement_boost(
  p_transaction_id     uuid,
  p_agreeing_layers    text[],
  p_base_confidence    numeric,
  p_boosted_confidence numeric,
  p_actor_user_id      uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_agreeing_layers IS NULL
     OR p_base_confidence IS NULL OR p_boosted_confidence IS NULL THEN
    RAISE EXCEPTION 'record_multi_layer_agreement_boost: required params missing' USING ERRCODE='22000';
  END IF;
  IF COALESCE(array_length(p_agreeing_layers, 1), 0) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INSUFFICIENT_AGREEING_LAYERS');
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_multi_layer_agreement_boost: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_confidence';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'CLASSIFICATION_MULTI_LAYER_AGREEMENT_BOOST',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'agreeing_layers', to_jsonb(p_agreeing_layers),
      'base_confidence', p_base_confidence,
      'boosted_confidence', p_boosted_confidence),
    p_reason => format('multi-layer agreement boost: %s → %s',
                       p_base_confidence, p_boosted_confidence));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_multi_layer_agreement_boost(uuid, text[], numeric, numeric, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_multi_layer_agreement_boost(uuid, text[], numeric, numeric, uuid) TO service_role;

-- ============================================================================
-- record_layer_disagreement_flagged
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_layer_disagreement_flagged(
  p_transaction_id   uuid,
  p_workflow_run_id  uuid,
  p_layer_decisions  jsonb,
  p_actor_user_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_review_id uuid := public.gen_uuid_v7();
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_workflow_run_id IS NULL OR p_layer_decisions IS NULL THEN
    RAISE EXCEPTION 'record_layer_disagreement_flagged: required params missing' USING ERRCODE='22000';
  END IF;
  IF jsonb_typeof(p_layer_decisions) <> 'object' THEN
    RAISE EXCEPTION 'record_layer_disagreement_flagged: layer_decisions must be a jsonb object' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_layer_disagreement_flagged: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_id, v_tx.organization_id, v_tx.business_id, p_workflow_run_id, p_transaction_id,
     'classification.layer_disagreement',
     'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
     'LOW'::public.review_issue_severity_enum,
     'Classifier layers disagreed on this transaction',
     'The deterministic rules, vendor memory, and AI classifier returned different types for this transaction. The run proceeded with the highest-confidence answer; you can review and optionally correct.',
     jsonb_build_object(
       'transaction_id', p_transaction_id,
       'layer_decisions', p_layer_decisions),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_confidence';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'CLASSIFICATION_LAYER_DISAGREEMENT_FLAGGED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'review_issue_id', v_review_id,
      'layer_decisions', p_layer_decisions),
    p_reason => format('classifier layers disagreed on tx %s', p_transaction_id));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'review_issue_id', v_review_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_layer_disagreement_flagged(uuid, uuid, jsonb, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_layer_disagreement_flagged(uuid, uuid, jsonb, uuid) TO service_role;
