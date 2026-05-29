-- B08·P04 — AI Fallback Classifier (Layer 3)
--
-- Gateway dispatch / Tier 2 → Tier 3 escalation is Python — orchestrator.
-- SQL ships:
--   1. business_ai_config.classification_layer3_enabled per-business toggle
--   2. calibrate_ai_classification_confidence helper
--   3. 5 spec-canonical audit RPCs
--   4. 2 placeholder prompt seeds (Stage-4 refreshes with real content)

ALTER TABLE public.business_ai_config
  ADD COLUMN IF NOT EXISTS classification_layer3_enabled boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.calibrate_ai_classification_confidence(
  p_raw_confidence numeric,
  p_tier           public.ai_tier_enum
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE p_tier
    WHEN 'LOCAL_LLM'::public.ai_tier_enum    THEN (p_raw_confidence * 0.85)::numeric
    WHEN 'EXTERNAL_LLM'::public.ai_tier_enum THEN (p_raw_confidence * 0.95)::numeric
    ELSE p_raw_confidence
  END;
$function$;
REVOKE ALL ON FUNCTION public.calibrate_ai_classification_confidence(numeric, public.ai_tier_enum) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.calibrate_ai_classification_confidence(numeric, public.ai_tier_enum) TO service_role, authenticated;

-- ============================================================================
-- record_ai_classification_invoked
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ai_classification_invoked(
  p_transaction_id        uuid,
  p_gateway_invocation_id uuid,
  p_tier                  public.ai_tier_enum,
  p_prompt_id             text,
  p_actor_user_id         uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_gateway_invocation_id IS NULL
     OR p_tier IS NULL OR p_prompt_id IS NULL THEN
    RAISE EXCEPTION 'record_ai_classification_invoked: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_tier NOT IN ('LOCAL_LLM'::public.ai_tier_enum, 'EXTERNAL_LLM'::public.ai_tier_enum) THEN
    RAISE EXCEPTION 'record_ai_classification_invoked: tier must be LOCAL_LLM or EXTERNAL_LLM' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ai_classification_invoked: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer3';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CLASSIFICATION_INVOKED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'gateway_invocation_id', p_gateway_invocation_id,
      'tier', p_tier::text,
      'prompt_id', p_prompt_id),
    p_reason => format('AI classification invoked: tier=%s prompt=%s tx=%s',
                       p_tier::text, p_prompt_id, p_transaction_id));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ai_classification_invoked(uuid, uuid, public.ai_tier_enum, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ai_classification_invoked(uuid, uuid, public.ai_tier_enum, text, uuid) TO service_role;

-- ============================================================================
-- record_ai_classification_tier2_low_confidence
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ai_classification_tier2_low_confidence(
  p_transaction_id   uuid,
  p_tier2_confidence numeric,
  p_threshold        numeric,
  p_actor_user_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_tier2_confidence IS NULL OR p_threshold IS NULL THEN
    RAISE EXCEPTION 'record_ai_classification_tier2_low_confidence: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_tier2_confidence < 0 OR p_tier2_confidence > 1
     OR p_threshold < 0 OR p_threshold > 1 THEN
    RAISE EXCEPTION 'record_ai_classification_tier2_low_confidence: confidence and threshold must be in [0,1]' USING ERRCODE='22023';
  END IF;
  IF p_tier2_confidence >= p_threshold THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'THRESHOLD_NOT_BREACHED',
      'tier2_confidence', p_tier2_confidence, 'threshold', p_threshold);
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ai_classification_tier2_low_confidence: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer3';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CLASSIFICATION_TIER2_LOW_CONFIDENCE',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'tier2_confidence', p_tier2_confidence,
      'threshold', p_threshold,
      'gap', (p_threshold - p_tier2_confidence)),
    p_reason => format('AI classification tier 2 below threshold: %s < %s on tx %s',
                       p_tier2_confidence, p_threshold, p_transaction_id));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ai_classification_tier2_low_confidence(uuid, numeric, numeric, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ai_classification_tier2_low_confidence(uuid, numeric, numeric, uuid) TO service_role;

-- ============================================================================
-- record_ai_classification_tier3_invoked
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ai_classification_tier3_invoked(
  p_transaction_id        uuid,
  p_gateway_invocation_id uuid,
  p_escalation_reason     text,
  p_actor_user_id         uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_gateway_invocation_id IS NULL OR p_escalation_reason IS NULL THEN
    RAISE EXCEPTION 'record_ai_classification_tier3_invoked: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ai_classification_tier3_invoked: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer3';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CLASSIFICATION_TIER3_INVOKED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'gateway_invocation_id', p_gateway_invocation_id,
      'escalation_reason', p_escalation_reason),
    p_reason => format('AI classification escalated to Tier 3: %s', left(p_escalation_reason, 200)));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ai_classification_tier3_invoked(uuid, uuid, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ai_classification_tier3_invoked(uuid, uuid, text, uuid) TO service_role;

-- ============================================================================
-- record_ai_classification_result
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ai_classification_result(
  p_transaction_id          uuid,
  p_gateway_invocation_id   uuid,
  p_tier                    public.ai_tier_enum,
  p_suggested_type          public.transaction_type_enum,
  p_raw_confidence          numeric,
  p_calibrated_confidence   numeric,
  p_suggested_tag           text DEFAULT NULL,
  p_reasoning_short         text DEFAULT NULL,
  p_actor_user_id           uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_gateway_invocation_id IS NULL
     OR p_tier IS NULL OR p_suggested_type IS NULL
     OR p_raw_confidence IS NULL OR p_calibrated_confidence IS NULL THEN
    RAISE EXCEPTION 'record_ai_classification_result: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_raw_confidence < 0 OR p_raw_confidence > 1
     OR p_calibrated_confidence < 0 OR p_calibrated_confidence > 1 THEN
    RAISE EXCEPTION 'record_ai_classification_result: confidences must be in [0,1] (raw=%, calibrated=%)',
      p_raw_confidence, p_calibrated_confidence USING ERRCODE='22023';
  END IF;
  IF p_tier NOT IN ('LOCAL_LLM'::public.ai_tier_enum, 'EXTERNAL_LLM'::public.ai_tier_enum) THEN
    RAISE EXCEPTION 'record_ai_classification_result: tier must be LOCAL_LLM or EXTERNAL_LLM' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ai_classification_result: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer3';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CLASSIFICATION_RESULT',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'gateway_invocation_id', p_gateway_invocation_id,
      'tier', p_tier::text,
      'suggested_type', p_suggested_type::text,
      'suggested_tag', p_suggested_tag,
      'raw_confidence', p_raw_confidence,
      'calibrated_confidence', p_calibrated_confidence,
      'reasoning_short', p_reasoning_short),
    p_reason => format('AI classification result: tier=%s type=%s calibrated=%s',
                       p_tier::text, p_suggested_type::text, p_calibrated_confidence));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'suggested_type', p_suggested_type::text,
    'calibrated_confidence', p_calibrated_confidence,
    'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ai_classification_result(uuid, uuid, public.ai_tier_enum, public.transaction_type_enum, numeric, numeric, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ai_classification_result(uuid, uuid, public.ai_tier_enum, public.transaction_type_enum, numeric, numeric, text, text, uuid) TO service_role;

-- ============================================================================
-- record_ai_classification_failed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ai_classification_failed(
  p_transaction_id         uuid,
  p_workflow_run_id        uuid,
  p_error_category         text,
  p_error_message          text,
  p_gateway_invocation_id  uuid DEFAULT NULL,
  p_actor_user_id          uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_review_id uuid := public.gen_uuid_v7();
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_workflow_run_id IS NULL
     OR p_error_category IS NULL OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'record_ai_classification_failed: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_error_category NOT IN ('SCHEMA_VIOLATION','MODEL_ERROR','COST_CEILING_REACHED','GATEWAY_TIMEOUT','LAYER3_DISABLED','OTHER') THEN
    RAISE EXCEPTION 'record_ai_classification_failed: unknown error_category %', p_error_category USING ERRCODE='22023';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'record_ai_classification_failed: error_message length must be 1..2000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ai_classification_failed: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_id, v_tx.organization_id, v_tx.business_id, p_workflow_run_id, p_transaction_id,
     'classification.ai_fallback_failed',
     'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
     'MEDIUM'::public.review_issue_severity_enum,
     'AI classification could not propose a type',
     format('The AI fallback classifier (Layer 3) was unable to suggest a transaction type (%s). Please classify this transaction manually.', p_error_category),
     jsonb_build_object(
       'transaction_id',          p_transaction_id,
       'gateway_invocation_id',   p_gateway_invocation_id,
       'error_category',          p_error_category,
       'error_message',           p_error_message),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer3';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CLASSIFICATION_FAILED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id',          p_transaction_id,
      'review_issue_id',         v_review_id,
      'gateway_invocation_id',   p_gateway_invocation_id,
      'error_category',          p_error_category,
      'error_message',           p_error_message),
    p_reason => format('AI classification failed on tx %s: %s — %s',
                       p_transaction_id, p_error_category, left(p_error_message, 200)));

  RETURN jsonb_build_object('ok', true,
    'transaction_id',  p_transaction_id,
    'review_issue_id', v_review_id,
    'audit_event_id',  v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ai_classification_failed(uuid, uuid, text, text, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ai_classification_failed(uuid, uuid, text, text, uuid, uuid) TO service_role;

-- ============================================================================
-- Placeholder prompt seeds (Stage-4 refreshes with real templates + test corpora)
-- ============================================================================
INSERT INTO public.prompt_registry
  (prompt_id, version, purpose, input_schema, output_schema, ai_tier,
   prompt_template_text, content_hash, registered_by_user_id, registered_at)
VALUES
  ('classification.classify_transaction.tier2', '0.1.0-placeholder',
   'Tier 2 transaction classifier — Stage-4 will refresh with real template + corpus',
   jsonb_build_object('type','object','required', jsonb_build_array('transaction'),
     'properties', jsonb_build_object('transaction', jsonb_build_object('type','object'))),
   jsonb_build_object('type','object','required', jsonb_build_array('suggested_type','confidence'),
     'properties', jsonb_build_object(
       'suggested_type', jsonb_build_object('type','string'),
       'suggested_tag',  jsonb_build_object('type','string'),
       'confidence',     jsonb_build_object('type','number','minimum',0,'maximum',1),
       'reasoning_short', jsonb_build_object('type','string','maxLength',280))),
   'LOCAL_LLM'::public.ai_tier_enum,
   'PLACEHOLDER — Stage-4 sub-doc Classification prompt design will replace.',
   encode(extensions.digest('PLACEHOLDER — Stage-4 sub-doc Classification prompt design will replace.', 'sha256'), 'hex'),
   NULL, clock_timestamp()),
  ('classification.classify_transaction.tier3', '0.1.0-placeholder',
   'Tier 3 transaction classifier (richer model fallback) — Stage-4 will refresh',
   jsonb_build_object('type','object','required', jsonb_build_array('transaction'),
     'properties', jsonb_build_object('transaction', jsonb_build_object('type','object'))),
   jsonb_build_object('type','object','required', jsonb_build_array('suggested_type','confidence'),
     'properties', jsonb_build_object(
       'suggested_type', jsonb_build_object('type','string'),
       'suggested_tag',  jsonb_build_object('type','string'),
       'confidence',     jsonb_build_object('type','number','minimum',0,'maximum',1),
       'reasoning_short', jsonb_build_object('type','string','maxLength',280))),
   'EXTERNAL_LLM'::public.ai_tier_enum,
   'PLACEHOLDER — Stage-4 sub-doc Classification prompt design will replace.',
   encode(extensions.digest('PLACEHOLDER — Stage-4 sub-doc Classification prompt design will replace.', 'sha256'), 'hex'),
   NULL, clock_timestamp())
ON CONFLICT (prompt_id, version) DO NOTHING;
