-- B09·P03 — OCR Pipeline (DB scaffold)
-- Lifecycle table + RPCs for Google Document AI OCR dispatch.
-- The actual processor invocation (DOCX→PDF conversion, byte-level IBAN
-- redaction, the gateway call) lives in the Python application layer; this
-- migration delivers the database scaffolding that records lifecycle and
-- emits audit events.
--
-- Audit family: DOCUMENT_OCR_STARTED, DOCUMENT_OCR_COMPLETED,
-- DOCUMENT_OCR_FAILED, DOCUMENT_FORMAT_REJECTED_UNSUPPORTED,
-- DOCUMENT_FORMAT_CONVERTED.

-- 1. Enums -------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='document_input_format_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.document_input_format_enum AS ENUM ('PDF','DOCX','JPG','PNG','HEIC','OTHER');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='document_ocr_run_status_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.document_ocr_run_status_enum AS ENUM ('STARTED','SUCCEEDED','FAILED','FORMAT_REJECTED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='document_ocr_error_category_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.document_ocr_error_category_enum AS ENUM (
      'TRANSIENT_API_ERROR','UNSUPPORTED_FORMAT','NO_EXTRACTABLE_CONTENT',
      'CORRUPTED_FILE','TIMEOUT','OTHER'
    );
  END IF;
END$$;


-- 2. document_ocr_runs -------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.document_ocr_runs (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id             uuid NOT NULL,
  business_id                 uuid NOT NULL,
  document_id                 uuid NOT NULL,
  processor_id                text NOT NULL,
  input_format                public.document_input_format_enum NOT NULL,
  was_converted               boolean NOT NULL DEFAULT false,
  status                      public.document_ocr_run_status_enum NOT NULL,
  page_count                  integer,
  confidence_summary          jsonb NOT NULL DEFAULT '{}'::jsonb,
  cost_estimate               numeric,
  compute_seconds             numeric,
  cost_currency               text,
  error_category              public.document_ocr_error_category_enum,
  error_summary               text,
  is_transient_error          boolean,
  detected_format             text,
  ai_gateway_invocation_id    uuid,
  ai_usage_record_id          uuid,
  ai_payload_artifact_id      uuid,
  review_issue_id             uuid,
  prompt_version              text,
  started_at                  timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at                timestamptz,
  failed_at                   timestamptz,
  CONSTRAINT docr_processor_nonempty CHECK (length(trim(processor_id)) > 0),
  CONSTRAINT docr_confidence_object  CHECK (jsonb_typeof(confidence_summary) = 'object'),
  CONSTRAINT docr_page_count_positive CHECK (page_count IS NULL OR page_count >= 0),
  CONSTRAINT docr_succeeded_pairing CHECK (
    (status <> 'SUCCEEDED')
    OR (page_count IS NOT NULL AND completed_at IS NOT NULL)
  ),
  CONSTRAINT docr_failed_pairing CHECK (
    (status <> 'FAILED')
    OR (
      error_category IS NOT NULL
      AND error_summary IS NOT NULL
      AND length(trim(error_summary)) > 0
      AND is_transient_error IS NOT NULL
      AND failed_at IS NOT NULL
    )
  ),
  CONSTRAINT docr_format_rejected_pairing CHECK (
    (status <> 'FORMAT_REJECTED')
    OR (
      detected_format IS NOT NULL
      AND error_summary IS NOT NULL
      AND length(trim(error_summary)) > 0
      AND failed_at IS NOT NULL
    )
  ),
  CONSTRAINT docr_org_fk      FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT docr_business_fk FOREIGN KEY (business_id)
    REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT docr_document_fk FOREIGN KEY (document_id)
    REFERENCES public.documents(id) ON DELETE RESTRICT,
  CONSTRAINT docr_gateway_fk  FOREIGN KEY (ai_gateway_invocation_id)
    REFERENCES public.ai_gateway_invocations(id) ON DELETE RESTRICT,
  CONSTRAINT docr_usage_fk    FOREIGN KEY (ai_usage_record_id)
    REFERENCES public.ai_usage_records(id) ON DELETE RESTRICT,
  CONSTRAINT docr_artifact_fk FOREIGN KEY (ai_payload_artifact_id)
    REFERENCES public.processing_artifacts(id) ON DELETE RESTRICT,
  CONSTRAINT docr_review_fk   FOREIGN KEY (review_issue_id)
    REFERENCES public.review_issues(id) ON DELETE RESTRICT
);

-- Idempotency: at most one STARTED run per document at any time
CREATE UNIQUE INDEX IF NOT EXISTS docr_one_started_per_doc
  ON public.document_ocr_runs (document_id) WHERE status = 'STARTED';

CREATE INDEX IF NOT EXISTS docr_by_doc
  ON public.document_ocr_runs (business_id, document_id);
CREATE INDEX IF NOT EXISTS docr_by_status
  ON public.document_ocr_runs (status, started_at DESC);

ALTER TABLE public.document_ocr_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS docr_select ON public.document_ocr_runs;
CREATE POLICY docr_select ON public.document_ocr_runs
  FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS docr_no_insert ON public.document_ocr_runs;
CREATE POLICY docr_no_insert ON public.document_ocr_runs FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS docr_no_update ON public.document_ocr_runs;
CREATE POLICY docr_no_update ON public.document_ocr_runs FOR UPDATE USING (false);
DROP POLICY IF EXISTS docr_no_delete ON public.document_ocr_runs;
CREATE POLICY docr_no_delete ON public.document_ocr_runs FOR DELETE USING (false);


-- 3. business_ai_config.ocr_low_confidence_threshold -------------------------

ALTER TABLE public.business_ai_config
  ADD COLUMN IF NOT EXISTS ocr_low_confidence_threshold numeric NOT NULL DEFAULT 0.85;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
    WHERE t.relname='business_ai_config' AND c.conname='bac_ocr_threshold_range_chk'
  ) THEN
    ALTER TABLE public.business_ai_config
      ADD CONSTRAINT bac_ocr_threshold_range_chk
      CHECK (ocr_low_confidence_threshold BETWEEN 0 AND 1);
  END IF;
END$$;


-- 4. begin_document_ocr_run --------------------------------------------------

CREATE OR REPLACE FUNCTION public.begin_document_ocr_run(
  p_document_id              uuid,
  p_processor_id             text,
  p_input_format             public.document_input_format_enum,
  p_was_converted            boolean DEFAULT false,
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
  v_current_status  public.document_extraction_status_enum;
  v_run_id          uuid;
BEGIN
  SELECT organization_id, business_id, extraction_status
    INTO v_organization_id, v_business_id, v_current_status
  FROM public.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision', 'REJECTED',
      'reason',   'DOCUMENT_NOT_FOUND',
      'document_id', p_document_id
    );
  END IF;

  IF v_current_status <> 'INGESTED' THEN
    RETURN jsonb_build_object(
      'decision',       'REJECTED',
      'reason',         'DOCUMENT_NOT_INGESTED',
      'document_id',    p_document_id,
      'current_status', v_current_status
    );
  END IF;

  INSERT INTO public.document_ocr_runs (
    organization_id, business_id, document_id, processor_id,
    input_format, was_converted, status, ai_gateway_invocation_id
  ) VALUES (
    v_organization_id, v_business_id, p_document_id, p_processor_id,
    p_input_format, p_was_converted, 'STARTED', p_ai_gateway_invocation_id
  )
  RETURNING id INTO v_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
    p_action           := 'DOCUMENT_OCR_STARTED',
    p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
    p_subject_id       := p_document_id,
    p_actor_user_id    := NULL,
    p_actor_role       := NULL,
    p_actor_session_id := NULL,
    p_actor_system     := 'document_ocr',
    p_organization_id  := v_organization_id,
    p_business_id      := v_business_id,
    p_before_state     := NULL,
    p_after_state      := jsonb_build_object(
      'run_id',         v_run_id,
      'processor_id',   p_processor_id,
      'input_format',   p_input_format,
      'was_converted',  p_was_converted
    ),
    p_reason           := NULL,
    p_request_context  := p_context
  );

  IF p_was_converted THEN
    PERFORM audit.emit_audit(
      p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
      p_action           := 'DOCUMENT_FORMAT_CONVERTED',
      p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
      p_subject_id       := p_document_id,
      p_actor_user_id    := NULL,
      p_actor_role       := NULL,
      p_actor_session_id := NULL,
      p_actor_system     := 'document_ocr',
      p_organization_id  := v_organization_id,
      p_business_id      := v_business_id,
      p_before_state     := NULL,
      p_after_state      := jsonb_build_object(
        'run_id',       v_run_id,
        'input_format', p_input_format,
        'note',         'attachment converted before OCR dispatch'
      ),
      p_reason           := NULL,
      p_request_context  := p_context
    );
  END IF;

  RETURN jsonb_build_object(
    'decision',    'STARTED',
    'run_id',      v_run_id,
    'document_id', p_document_id
  );
END;
$$;


-- 5. complete_document_ocr_run -----------------------------------------------

CREATE OR REPLACE FUNCTION public.complete_document_ocr_run(
  p_run_id                  uuid,
  p_page_count              integer,
  p_extracted_fields        jsonb,
  p_confidence_per_field    jsonb,
  p_confidence_summary      jsonb,
  p_prompt_version          text,
  p_cost_estimate           numeric DEFAULT NULL,
  p_compute_seconds         numeric DEFAULT NULL,
  p_cost_currency           text    DEFAULT NULL,
  p_ai_usage_record_id      uuid    DEFAULT NULL,
  p_ai_payload_artifact_id  uuid    DEFAULT NULL,
  p_context                 jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_document_id     uuid;
  v_current_status  public.document_ocr_run_status_enum;
  v_transition_env  jsonb;
BEGIN
  SELECT organization_id, business_id, document_id, status
    INTO v_organization_id, v_business_id, v_document_id, v_current_status
  FROM public.document_ocr_runs
  WHERE id = p_run_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision', 'REJECTED',
      'reason',   'OCR_RUN_NOT_FOUND',
      'run_id',   p_run_id
    );
  END IF;

  IF v_current_status <> 'STARTED' THEN
    RETURN jsonb_build_object(
      'decision',       'REJECTED',
      'reason',         'OCR_RUN_NOT_STARTED',
      'run_id',         p_run_id,
      'current_status', v_current_status
    );
  END IF;

  UPDATE public.document_ocr_runs
     SET status                  = 'SUCCEEDED',
         page_count              = p_page_count,
         confidence_summary      = COALESCE(p_confidence_summary, '{}'::jsonb),
         cost_estimate           = p_cost_estimate,
         compute_seconds         = p_compute_seconds,
         cost_currency           = p_cost_currency,
         ai_usage_record_id      = p_ai_usage_record_id,
         ai_payload_artifact_id  = p_ai_payload_artifact_id,
         prompt_version          = p_prompt_version,
         completed_at            = clock_timestamp()
   WHERE id = p_run_id;

  INSERT INTO public.document_extraction_results (
    organization_id, business_id, document_id, extraction_layer,
    extracted_fields, confidence_per_field, started_at, completed_at,
    prompt_version, succeeded
  ) VALUES (
    v_organization_id, v_business_id, v_document_id, 'TIER3_AI',
    COALESCE(p_extracted_fields, '{}'::jsonb),
    COALESCE(p_confidence_per_field, '{}'::jsonb),
    clock_timestamp(), clock_timestamp(),
    p_prompt_version, true
  );

  v_transition_env := public.transition_document(
    p_document_id  => v_document_id,
    p_target_state => 'EXTRACTED'::public.document_extraction_status_enum,
    p_reason       => 'ocr_completed',
    p_context      => jsonb_build_object('run_id', p_run_id) || COALESCE(p_context, '{}'::jsonb)
  );

  PERFORM audit.emit_audit(
    p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
    p_action           := 'DOCUMENT_OCR_COMPLETED',
    p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
    p_subject_id       := v_document_id,
    p_actor_user_id    := NULL,
    p_actor_role       := NULL,
    p_actor_session_id := NULL,
    p_actor_system     := 'document_ocr',
    p_organization_id  := v_organization_id,
    p_business_id      := v_business_id,
    p_before_state     := NULL,
    p_after_state      := jsonb_build_object(
      'run_id',             p_run_id,
      'page_count',         p_page_count,
      'confidence_summary', COALESCE(p_confidence_summary, '{}'::jsonb),
      'cost_estimate',      p_cost_estimate,
      'compute_seconds',    p_compute_seconds,
      'transition',         v_transition_env
    ),
    p_reason           := NULL,
    p_request_context  := p_context
  );

  RETURN jsonb_build_object(
    'decision',    'COMPLETED',
    'run_id',      p_run_id,
    'document_id', v_document_id,
    'transition',  v_transition_env
  );
END;
$$;


-- 6. fail_document_ocr_run ---------------------------------------------------

CREATE OR REPLACE FUNCTION public.fail_document_ocr_run(
  p_run_id          uuid,
  p_error_category  public.document_ocr_error_category_enum,
  p_error_summary   text,
  p_is_transient    boolean,
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
  v_document_id     uuid;
  v_current_status  public.document_ocr_run_status_enum;
BEGIN
  IF p_error_summary IS NULL OR length(trim(p_error_summary)) = 0 THEN
    RAISE EXCEPTION 'OCR_ERROR_SUMMARY_REQUIRED'
      USING errcode = 'check_violation';
  END IF;

  SELECT organization_id, business_id, document_id, status
    INTO v_organization_id, v_business_id, v_document_id, v_current_status
  FROM public.document_ocr_runs
  WHERE id = p_run_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision', 'REJECTED',
      'reason',   'OCR_RUN_NOT_FOUND',
      'run_id',   p_run_id
    );
  END IF;

  IF v_current_status <> 'STARTED' THEN
    RETURN jsonb_build_object(
      'decision',       'REJECTED',
      'reason',         'OCR_RUN_NOT_STARTED',
      'run_id',         p_run_id,
      'current_status', v_current_status
    );
  END IF;

  UPDATE public.document_ocr_runs
     SET status              = 'FAILED',
         error_category      = p_error_category,
         error_summary       = p_error_summary,
         is_transient_error  = p_is_transient,
         failed_at           = clock_timestamp()
   WHERE id = p_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
    p_action           := 'DOCUMENT_OCR_FAILED',
    p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
    p_subject_id       := v_document_id,
    p_actor_user_id    := NULL,
    p_actor_role       := NULL,
    p_actor_session_id := NULL,
    p_actor_system     := 'document_ocr',
    p_organization_id  := v_organization_id,
    p_business_id      := v_business_id,
    p_before_state     := NULL,
    p_after_state      := jsonb_build_object(
      'run_id',             p_run_id,
      'error_category',     p_error_category,
      'error_summary',      p_error_summary,
      'is_transient_error', p_is_transient
    ),
    p_reason           := p_error_summary,
    p_request_context  := p_context
  );

  RETURN jsonb_build_object(
    'decision',           'FAILED',
    'run_id',             p_run_id,
    'document_id',        v_document_id,
    'is_transient_error', p_is_transient
  );
END;
$$;


-- 7. reject_document_format --------------------------------------------------

CREATE OR REPLACE FUNCTION public.reject_document_format(
  p_document_id     uuid,
  p_detected_format text,
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
  v_run_id          uuid;
  v_review_issue_id uuid;
BEGIN
  IF p_detected_format IS NULL OR length(trim(p_detected_format)) = 0 THEN
    RAISE EXCEPTION 'DETECTED_FORMAT_REQUIRED'
      USING errcode = 'check_violation';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'REJECTION_REASON_REQUIRED'
      USING errcode = 'check_violation';
  END IF;

  SELECT organization_id, business_id
    INTO v_organization_id, v_business_id
  FROM public.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision', 'REJECTED',
      'reason',   'DOCUMENT_NOT_FOUND',
      'document_id', p_document_id
    );
  END IF;

  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id, document_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action
  ) VALUES (
    v_organization_id, v_business_id, p_workflow_run_id, p_document_id,
    'DOCUMENT_FORMAT_UNSUPPORTED',
    'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
    'MEDIUM'::public.review_issue_severity_enum,
    'Document format not supported',
    'We could not run OCR on this file because its format (' || p_detected_format
      || ') is not supported. Please re-upload as PDF, JPG, PNG, or HEIC.',
    'Re-upload the document as PDF or image'
  )
  RETURNING id INTO v_review_issue_id;

  INSERT INTO public.document_ocr_runs (
    organization_id, business_id, document_id, processor_id,
    input_format, status, detected_format, error_summary, failed_at,
    review_issue_id
  ) VALUES (
    v_organization_id, v_business_id, p_document_id, 'format_gate',
    'OTHER'::public.document_input_format_enum, 'FORMAT_REJECTED',
    p_detected_format, p_reason, clock_timestamp(),
    v_review_issue_id
  )
  RETURNING id INTO v_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
    p_action           := 'DOCUMENT_FORMAT_REJECTED_UNSUPPORTED',
    p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
    p_subject_id       := p_document_id,
    p_actor_user_id    := NULL,
    p_actor_role       := NULL,
    p_actor_session_id := NULL,
    p_actor_system     := 'document_ocr',
    p_organization_id  := v_organization_id,
    p_business_id      := v_business_id,
    p_before_state     := NULL,
    p_after_state      := jsonb_build_object(
      'run_id',          v_run_id,
      'detected_format', p_detected_format,
      'review_issue_id', v_review_issue_id,
      'reason',          p_reason
    ),
    p_reason           := p_reason,
    p_request_context  := p_context
  );

  RETURN jsonb_build_object(
    'decision',        'REJECTED',
    'run_id',          v_run_id,
    'document_id',     p_document_id,
    'review_issue_id', v_review_issue_id
  );
END;
$$;


-- 8. Privilege grants --------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.begin_document_ocr_run(uuid, text, public.document_input_format_enum, boolean, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_document_ocr_run(uuid, integer, jsonb, jsonb, jsonb, text, numeric, numeric, text, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fail_document_ocr_run(uuid, public.document_ocr_error_category_enum, text, boolean, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reject_document_format(uuid, text, text, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.begin_document_ocr_run(uuid, text, public.document_input_format_enum, boolean, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_document_ocr_run(uuid, integer, jsonb, jsonb, jsonb, text, numeric, numeric, text, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fail_document_ocr_run(uuid, public.document_ocr_error_category_enum, text, boolean, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_document_format(uuid, text, text, uuid, jsonb) TO authenticated, service_role;
