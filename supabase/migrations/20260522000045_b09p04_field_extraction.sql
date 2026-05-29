-- B09·P04 — Field Extraction (Deterministic + AI Fallback) — DB scaffold.
-- Three-layer pattern: Layer 1 deterministic templates → Layer 2 Tier 2 LLM
-- (LOCAL_LLM) → Layer 3 Tier 3 LLM (EXTERNAL_LLM). The Python orchestrator
-- owns regex template matching, LLM dispatch, and per-field validation; this
-- migration delivers the registry, lifecycle RPCs, and audit wiring.
--
-- Audit family DOCUMENT_EXTRACTION:
--   DOCUMENT_EXTRACTION_LAYER1_MATCHED
--   DOCUMENT_EXTRACTION_TIER2_INVOKED
--   DOCUMENT_EXTRACTION_TIER2_LOW_CONFIDENCE
--   DOCUMENT_EXTRACTION_TIER3_INVOKED
--   DOCUMENT_EXTRACTION_RESULT
--   DOCUMENT_EXTRACTION_FAILED
--   DOCUMENT_FIELD_VALIDATION_FAILED

-- 1. document_extraction_templates -------------------------------------------

CREATE TABLE IF NOT EXISTS public.document_extraction_templates (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  template_name       text NOT NULL,
  version             text NOT NULL,
  document_type       public.document_type_enum NOT NULL DEFAULT 'INVOICE',
  supplier_hint       text,
  pattern_jsonb       jsonb NOT NULL,
  required_fields     text[] NOT NULL,
  priority            integer NOT NULL DEFAULT 100,
  enabled             boolean NOT NULL DEFAULT true,
  retired_at          timestamptz,
  retired_by_user_id  uuid,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id  uuid,
  CONSTRAINT det_name_format        CHECK (template_name ~ '^[a-z][a-z0-9_]+$'),
  CONSTRAINT det_version_nonempty   CHECK (length(trim(version)) > 0),
  CONSTRAINT det_pattern_object     CHECK (jsonb_typeof(pattern_jsonb) = 'object'),
  CONSTRAINT det_required_nonempty  CHECK (array_length(required_fields, 1) >= 1),
  CONSTRAINT det_priority_nonneg    CHECK (priority >= 0)
);

-- Only one active row per (template_name, version) at a time; re-registering
-- after retirement is allowed.
CREATE UNIQUE INDEX IF NOT EXISTS det_active_unique
  ON public.document_extraction_templates (template_name, version)
  WHERE retired_at IS NULL;

CREATE INDEX IF NOT EXISTS det_lookup
  ON public.document_extraction_templates (document_type, enabled, priority DESC)
  WHERE retired_at IS NULL;

ALTER TABLE public.document_extraction_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS det_select ON public.document_extraction_templates;
CREATE POLICY det_select ON public.document_extraction_templates FOR SELECT USING (true);
DROP POLICY IF EXISTS det_no_insert ON public.document_extraction_templates;
CREATE POLICY det_no_insert ON public.document_extraction_templates FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS det_no_update ON public.document_extraction_templates;
CREATE POLICY det_no_update ON public.document_extraction_templates FOR UPDATE USING (false);
DROP POLICY IF EXISTS det_no_delete ON public.document_extraction_templates;
CREATE POLICY det_no_delete ON public.document_extraction_templates FOR DELETE USING (false);


-- 2. business_ai_config additions --------------------------------------------

ALTER TABLE public.business_ai_config
  ADD COLUMN IF NOT EXISTS extraction_layer2_confidence_threshold numeric NOT NULL DEFAULT 0.75,
  ADD COLUMN IF NOT EXISTS extraction_layer3_enabled boolean NOT NULL DEFAULT true;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
    WHERE t.relname='business_ai_config' AND c.conname='bac_layer2_threshold_range_chk'
  ) THEN
    ALTER TABLE public.business_ai_config
      ADD CONSTRAINT bac_layer2_threshold_range_chk
      CHECK (extraction_layer2_confidence_threshold BETWEEN 0 AND 1);
  END IF;
END$$;


-- 3. documents.extraction_layer_used -----------------------------------------

ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS extraction_layer_used public.document_extraction_layer_enum;


-- 4. Prompt seeds ------------------------------------------------------------
-- Regex-safe prompt ids (word-prefix, not number-prefix per the prompt_id
-- gotcha). Placeholders; actual prompt text is filled in Stage-6.

INSERT INTO public.prompt_registry (
  prompt_id, version, purpose, input_schema, output_schema, ai_tier,
  prompt_template_text, content_hash, registered_by_user_id
) VALUES
  (
    'document.extract_invoice_fields.tier2',
    '0.1.0-placeholder',
    'Tier 2 extraction of canonical invoice fields from OCR output (local LLM).',
    '{"ocr_text": "string", "document_type": "string", "business_context": "object", "hint_fields": "object?"}'::jsonb,
    '{"extracted_fields": "object", "confidence_per_field": "object", "avg_confidence": "number"}'::jsonb,
    'LOCAL_LLM',
    '/* placeholder — replaced in Stage-6 */',
    encode(sha256('document.extract_invoice_fields.tier2:0.1.0-placeholder'::bytea), 'hex'),
    NULL
  ),
  (
    'document.extract_invoice_fields.tier3',
    '0.1.0-placeholder',
    'Tier 3 extraction of canonical invoice fields from OCR output (Anthropic Claude).',
    '{"ocr_text": "string", "document_type": "string", "business_context": "object", "hint_fields": "object?"}'::jsonb,
    '{"extracted_fields": "object", "confidence_per_field": "object", "avg_confidence": "number"}'::jsonb,
    'EXTERNAL_LLM',
    '/* placeholder — replaced in Stage-6 */',
    encode(sha256('document.extract_invoice_fields.tier3:0.1.0-placeholder'::bytea), 'hex'),
    NULL
  )
ON CONFLICT DO NOTHING;


-- 5. record_document_extraction_layer1 ---------------------------------------

CREATE OR REPLACE FUNCTION public.record_document_extraction_layer1(
  p_document_id        uuid,
  p_template_name      text,
  p_template_version   text,
  p_extracted_fields   jsonb,
  p_context            jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_result_id       uuid;
  v_confidence      jsonb := '{}'::jsonb;
  v_key             text;
BEGIN
  IF p_extracted_fields IS NULL OR jsonb_typeof(p_extracted_fields) <> 'object' THEN
    RAISE EXCEPTION 'EXTRACTED_FIELDS_OBJECT_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.documents WHERE id = p_document_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','DOCUMENT_NOT_FOUND','document_id',p_document_id);
  END IF;

  -- Build confidence_per_field = {key: 1.0} for every key present
  FOR v_key IN SELECT jsonb_object_keys(p_extracted_fields) LOOP
    v_confidence := v_confidence || jsonb_build_object(v_key, 1.0);
  END LOOP;

  INSERT INTO public.document_extraction_results (
    organization_id, business_id, document_id, extraction_layer,
    extracted_fields, confidence_per_field, started_at, completed_at,
    prompt_version, succeeded
  ) VALUES (
    v_organization_id, v_business_id, p_document_id, 'DETERMINISTIC',
    p_extracted_fields, v_confidence, clock_timestamp(), clock_timestamp(),
    NULL, true
  )
  RETURNING id INTO v_result_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_EXTRACTION_LAYER1_MATCHED',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=p_document_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='document_extraction',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'result_id',v_result_id,
      'template_name',p_template_name,
      'template_version',p_template_version,
      'field_count',(SELECT count(*) FROM jsonb_object_keys(p_extracted_fields))
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','result_id',v_result_id,
    'extraction_layer','DETERMINISTIC','document_id',p_document_id
  );
END;
$$;


-- 6. record_document_extraction_tier2_attempt --------------------------------

CREATE OR REPLACE FUNCTION public.record_document_extraction_tier2_attempt(
  p_document_id              uuid,
  p_extracted_fields         jsonb,
  p_confidence_per_field     jsonb,
  p_avg_confidence           numeric,
  p_prompt_version           text,
  p_ai_gateway_invocation_id uuid    DEFAULT NULL,
  p_context                  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_threshold       numeric;
  v_result_id       uuid;
  v_below_threshold boolean;
BEGIN
  IF p_prompt_version IS NULL OR length(trim(p_prompt_version)) = 0 THEN
    RAISE EXCEPTION 'PROMPT_VERSION_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','DOCUMENT_NOT_FOUND','document_id',p_document_id);
  END IF;

  SELECT extraction_layer2_confidence_threshold INTO v_threshold
  FROM public.business_ai_config WHERE business_id = v_business_id;
  -- If no config row, treat threshold as the default 0.75
  IF v_threshold IS NULL THEN v_threshold := 0.75; END IF;

  INSERT INTO public.document_extraction_results (
    organization_id, business_id, document_id, extraction_layer,
    extracted_fields, confidence_per_field, started_at, completed_at,
    prompt_version, succeeded
  ) VALUES (
    v_organization_id, v_business_id, p_document_id, 'TIER2_AI',
    COALESCE(p_extracted_fields,'{}'::jsonb),
    COALESCE(p_confidence_per_field,'{}'::jsonb),
    clock_timestamp(), clock_timestamp(),
    p_prompt_version, true
  )
  RETURNING id INTO v_result_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_EXTRACTION_TIER2_INVOKED',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=p_document_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='document_extraction',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'result_id',v_result_id,
      'prompt_version',p_prompt_version,
      'avg_confidence',p_avg_confidence,
      'threshold',v_threshold,
      'gateway_invocation_id',p_ai_gateway_invocation_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  v_below_threshold := (p_avg_confidence IS NOT NULL AND p_avg_confidence < v_threshold);
  IF v_below_threshold THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='DOCUMENT_EXTRACTION_TIER2_LOW_CONFIDENCE',
      p_subject_type:='DOCUMENT'::audit.subject_type_enum,
      p_subject_id:=p_document_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='document_extraction',
      p_organization_id:=v_organization_id, p_business_id:=v_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'result_id',v_result_id,
        'avg_confidence',p_avg_confidence,
        'threshold',v_threshold,
        'note','escalation to Tier 3 required (explicit, not silent)'
      ),
      p_reason:=NULL, p_request_context:=p_context
    );
  END IF;

  RETURN jsonb_build_object(
    'decision','RECORDED','result_id',v_result_id,
    'extraction_layer','TIER2_AI','below_threshold',v_below_threshold,
    'threshold',v_threshold,'document_id',p_document_id
  );
END;
$$;


-- 7. record_document_extraction_tier3_attempt --------------------------------

CREATE OR REPLACE FUNCTION public.record_document_extraction_tier3_attempt(
  p_document_id              uuid,
  p_extracted_fields         jsonb,
  p_confidence_per_field     jsonb,
  p_prompt_version           text,
  p_ai_gateway_invocation_id uuid    DEFAULT NULL,
  p_context                  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_result_id       uuid;
BEGIN
  IF p_prompt_version IS NULL OR length(trim(p_prompt_version)) = 0 THEN
    RAISE EXCEPTION 'PROMPT_VERSION_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','DOCUMENT_NOT_FOUND','document_id',p_document_id);
  END IF;

  INSERT INTO public.document_extraction_results (
    organization_id, business_id, document_id, extraction_layer,
    extracted_fields, confidence_per_field, started_at, completed_at,
    prompt_version, succeeded
  ) VALUES (
    v_organization_id, v_business_id, p_document_id, 'TIER3_AI',
    COALESCE(p_extracted_fields,'{}'::jsonb),
    COALESCE(p_confidence_per_field,'{}'::jsonb),
    clock_timestamp(), clock_timestamp(),
    p_prompt_version, true
  )
  RETURNING id INTO v_result_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_EXTRACTION_TIER3_INVOKED',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=p_document_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='document_extraction',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'result_id',v_result_id,
      'prompt_version',p_prompt_version,
      'gateway_invocation_id',p_ai_gateway_invocation_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','result_id',v_result_id,
    'extraction_layer','TIER3_AI','document_id',p_document_id
  );
END;
$$;


-- 8. finalize_document_extraction --------------------------------------------

CREATE OR REPLACE FUNCTION public.finalize_document_extraction(
  p_document_id          uuid,
  p_winning_layer        public.document_extraction_layer_enum,
  p_extracted_fields     jsonb,
  p_confidence_per_field jsonb,
  p_context              jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_transition_env  jsonb;
BEGIN
  IF jsonb_typeof(COALESCE(p_extracted_fields,'{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'EXTRACTED_FIELDS_OBJECT_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','DOCUMENT_NOT_FOUND','document_id',p_document_id);
  END IF;

  -- Denormalize known fields onto the documents row (conditional on key presence)
  UPDATE public.documents SET
    supplier_name        = COALESCE(p_extracted_fields->>'supplier_name',        supplier_name),
    supplier_address     = COALESCE(p_extracted_fields->>'supplier_address',     supplier_address),
    supplier_country     = COALESCE((p_extracted_fields->>'supplier_country')::char(2), supplier_country),
    supplier_vat_number  = COALESCE(p_extracted_fields->>'supplier_vat_number',  supplier_vat_number),
    invoice_number       = COALESCE(p_extracted_fields->>'invoice_number',       invoice_number),
    invoice_date         = COALESCE((p_extracted_fields->>'invoice_date')::date, invoice_date),
    due_date             = COALESCE((p_extracted_fields->>'due_date')::date,     due_date),
    service_period_start = COALESCE((p_extracted_fields->>'service_period_start')::date, service_period_start),
    service_period_end   = COALESCE((p_extracted_fields->>'service_period_end')::date,   service_period_end),
    amount_subtotal      = COALESCE((p_extracted_fields->>'amount_subtotal')::numeric, amount_subtotal),
    amount_total         = COALESCE((p_extracted_fields->>'amount_total')::numeric,    amount_total),
    currency             = COALESCE((p_extracted_fields->>'currency')::char(3),  currency),
    vat_amount           = COALESCE((p_extracted_fields->>'vat_amount')::numeric, vat_amount),
    vat_rate             = COALESCE((p_extracted_fields->>'vat_rate')::numeric,   vat_rate),
    payment_reference    = COALESCE(p_extracted_fields->>'payment_reference',    payment_reference),
    client_name          = COALESCE(p_extracted_fields->>'client_name',          client_name),
    line_items           = CASE
                             WHEN p_extracted_fields ? 'line_items'
                              AND jsonb_typeof(p_extracted_fields->'line_items') = 'array'
                             THEN p_extracted_fields->'line_items'
                             ELSE line_items
                           END,
    extraction_layer_used           = p_winning_layer,
    extraction_confidence_per_field = COALESCE(p_confidence_per_field, '{}'::jsonb),
    updated_at = clock_timestamp()
  WHERE id = p_document_id;

  v_transition_env := public.transition_document(
    p_document_id  => p_document_id,
    p_target_state => 'EXTRACTED'::public.document_extraction_status_enum,
    p_reason       => 'field_extraction_finalized',
    p_context      => jsonb_build_object('winning_layer', p_winning_layer) || COALESCE(p_context,'{}'::jsonb)
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_EXTRACTION_RESULT',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=p_document_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='document_extraction',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'winning_layer',p_winning_layer,
      'field_count',(SELECT count(*) FROM jsonb_object_keys(COALESCE(p_extracted_fields,'{}'::jsonb))),
      'transition',v_transition_env
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','FINALIZED','document_id',p_document_id,
    'winning_layer',p_winning_layer,'transition',v_transition_env
  );
END;
$$;


-- 9. record_document_extraction_failed ---------------------------------------

CREATE OR REPLACE FUNCTION public.record_document_extraction_failed(
  p_document_id     uuid,
  p_reason          text,
  p_workflow_run_id uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_review_issue_id uuid;
BEGIN
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','DOCUMENT_NOT_FOUND','document_id',p_document_id);
  END IF;

  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id, document_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action
  ) VALUES (
    v_organization_id, v_business_id, p_workflow_run_id, p_document_id,
    'document.extraction_failed',
    'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
    'HIGH'::public.review_issue_severity_enum,
    'We could not extract details from this document',
    'All extraction layers failed for this document. Reason: ' || p_reason,
    'Review the document manually and either correct the fields or dismiss it'
  )
  RETURNING id INTO v_review_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_EXTRACTION_FAILED',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=p_document_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='document_extraction',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'review_issue_id',v_review_issue_id,
      'reason',p_reason
    ),
    p_reason:=p_reason, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','FAILED','document_id',p_document_id,
    'review_issue_id',v_review_issue_id
  );
END;
$$;


-- 10. record_field_validation_failed -----------------------------------------

CREATE OR REPLACE FUNCTION public.record_field_validation_failed(
  p_document_id     uuid,
  p_field_name      text,
  p_reason          text,
  p_workflow_run_id uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_review_issue_id uuid;
BEGIN
  IF p_field_name IS NULL OR length(trim(p_field_name)) = 0 THEN
    RAISE EXCEPTION 'FIELD_NAME_REQUIRED' USING errcode='check_violation';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','DOCUMENT_NOT_FOUND','document_id',p_document_id);
  END IF;

  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id, document_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action,
    card_payload_json
  ) VALUES (
    v_organization_id, v_business_id, p_workflow_run_id, p_document_id,
    'document.field_validation_failed',
    'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
    'MEDIUM'::public.review_issue_severity_enum,
    'Extracted field failed validation: ' || p_field_name,
    'The field "' || p_field_name || '" was extracted but failed validation. Reason: ' || p_reason,
    'Open the document, verify the field, and either correct or confirm the value',
    jsonb_build_object('field_name', p_field_name, 'reason', p_reason)
  )
  RETURNING id INTO v_review_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_FIELD_VALIDATION_FAILED',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=p_document_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='document_extraction',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'review_issue_id',v_review_issue_id,
      'field_name',p_field_name,
      'reason',p_reason
    ),
    p_reason:=p_reason, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','document_id',p_document_id,
    'field_name',p_field_name,
    'review_issue_id',v_review_issue_id
  );
END;
$$;


-- 11. Privilege grants -------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.record_document_extraction_layer1(uuid, text, text, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_document_extraction_tier2_attempt(uuid, jsonb, jsonb, numeric, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_document_extraction_tier3_attempt(uuid, jsonb, jsonb, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.finalize_document_extraction(uuid, public.document_extraction_layer_enum, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_document_extraction_failed(uuid, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_field_validation_failed(uuid, text, text, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.record_document_extraction_layer1(uuid, text, text, jsonb, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_document_extraction_tier2_attempt(uuid, jsonb, jsonb, numeric, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_document_extraction_tier3_attempt(uuid, jsonb, jsonb, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finalize_document_extraction(uuid, public.document_extraction_layer_enum, jsonb, jsonb, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_document_extraction_failed(uuid, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_field_validation_failed(uuid, text, text, uuid, jsonb) TO authenticated, service_role;

GRANT SELECT ON public.document_extraction_templates TO authenticated, anon;
