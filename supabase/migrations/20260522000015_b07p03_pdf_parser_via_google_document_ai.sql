-- B07·P03 — PDF Parser via Google Document AI
--
-- Ships the SQL contract for the PDF parsing path. The Python Document AI
-- client (EU processor, getSecret-fetched credentials, Privacy Gateway
-- dispatch, table extraction, ParsedRow column mapping) lands with the
-- orchestrator. SQL delivers:
--
--   1. Extends statement_parse_runs with OCR fields (NULL for CSV runs)
--   2. Extends statement_parsed_rows with confidence fields (NULL for CSV)
--   3. Adds pdf_low_confidence_threshold to business_ai_config (default 0.85)
--   4. New enum: pdf_ocr_error_category_enum
--   5. RPCs:
--      - record_pdf_ocr_started   (emits STATEMENT_PDF_OCR_STARTED)
--      - record_pdf_ocr_completed (emits STATEMENT_PDF_OCR_COMPLETED with page_count + cost)
--      - record_pdf_ocr_failed    (emits STATEMENT_PDF_OCR_FAILED with transient flag)
--      - record_pdf_parsed_row    (wraps row insert + confidence columns)
--      - flag_low_confidence_parsed_row (emits STATEMENT_PDF_PARSE_LOW_CONFIDENCE_ROW)
--   6. Seed Revolut PDF parser at (REVOLUT, PDF, 1.0.0)
--
-- Orchestrator-deferral: the Python parser at cyprus_bookkeeping_api.parsers
-- .revolut_pdf:parse calls record_pdf_ocr_started → external Document AI HTTP
-- via Privacy Gateway (B06·P02) → record_pdf_ocr_completed → record_ai_usage
-- (B06·P07, separate call) → N × record_pdf_parsed_row → M × flag_low_
-- confidence_parsed_row → complete_statement_parse. Persistent OCR failure
-- path: record_pdf_ocr_failed(transient=false) → fail_statement_parse.
-- Transient: record_pdf_ocr_failed(transient=true), caller backs off and
-- retries (B03·P08 retry policy).

-- ============================================================================
-- 1. New enum
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pdf_ocr_error_category_enum') THEN
    CREATE TYPE public.pdf_ocr_error_category_enum AS ENUM (
      'DOC_AI_5XX',
      'DOC_AI_4XX',
      'EMPTY_EXTRACTION',
      'UNSUPPORTED_PDF',
      'CORRUPTED_FILE',
      'CREDENTIALS_MISSING',
      'TIMEOUT'
    );
  END IF;
END$$;

-- ============================================================================
-- 2. Extend statement_parse_runs with OCR fields
-- ============================================================================
ALTER TABLE public.statement_parse_runs
  ADD COLUMN IF NOT EXISTS ocr_processor_id      text,
  ADD COLUMN IF NOT EXISTS ocr_processor_version text,
  ADD COLUMN IF NOT EXISTS ocr_page_count        int,
  ADD COLUMN IF NOT EXISTS ocr_cost_cents        int,
  ADD COLUMN IF NOT EXISTS ocr_artifact_path     text,
  ADD COLUMN IF NOT EXISTS ocr_started_at        timestamptz,
  ADD COLUMN IF NOT EXISTS ocr_completed_at      timestamptz;

-- Constraints: nonneg page/cost; lifecycle pairing.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'statement_parse_runs_ocr_page_count_nonneg') THEN
    ALTER TABLE public.statement_parse_runs
      ADD CONSTRAINT statement_parse_runs_ocr_page_count_nonneg
        CHECK (ocr_page_count IS NULL OR ocr_page_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'statement_parse_runs_ocr_cost_nonneg') THEN
    ALTER TABLE public.statement_parse_runs
      ADD CONSTRAINT statement_parse_runs_ocr_cost_nonneg
        CHECK (ocr_cost_cents IS NULL OR ocr_cost_cents >= 0);
  END IF;
  -- If completed_at set, started_at must also be set
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'statement_parse_runs_ocr_lifecycle_chk') THEN
    ALTER TABLE public.statement_parse_runs
      ADD CONSTRAINT statement_parse_runs_ocr_lifecycle_chk
        CHECK (ocr_completed_at IS NULL OR ocr_started_at IS NOT NULL);
  END IF;
END$$;

-- ============================================================================
-- 3. Extend statement_parsed_rows with confidence fields
-- ============================================================================
ALTER TABLE public.statement_parsed_rows
  ADD COLUMN IF NOT EXISTS extraction_confidence_per_field jsonb,
  ADD COLUMN IF NOT EXISTS parser_confidence text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'statement_parsed_rows_parser_confidence_chk') THEN
    ALTER TABLE public.statement_parsed_rows
      ADD CONSTRAINT statement_parsed_rows_parser_confidence_chk
        CHECK (parser_confidence IS NULL OR parser_confidence IN ('HIGH','LOW'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'statement_parsed_rows_confidence_obj_chk') THEN
    ALTER TABLE public.statement_parsed_rows
      ADD CONSTRAINT statement_parsed_rows_confidence_obj_chk
        CHECK (extraction_confidence_per_field IS NULL
               OR jsonb_typeof(extraction_confidence_per_field) = 'object');
  END IF;
END$$;

-- ============================================================================
-- 4. Extend business_ai_config with pdf_low_confidence_threshold
-- ============================================================================
ALTER TABLE public.business_ai_config
  ADD COLUMN IF NOT EXISTS pdf_low_confidence_threshold numeric(3,2) NOT NULL DEFAULT 0.85;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'business_ai_config_pdf_threshold_range') THEN
    ALTER TABLE public.business_ai_config
      ADD CONSTRAINT business_ai_config_pdf_threshold_range
        CHECK (pdf_low_confidence_threshold BETWEEN 0.50 AND 1.00);
  END IF;
END$$;

-- ============================================================================
-- 5. RPC: record_pdf_ocr_started
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_pdf_ocr_started(
  p_parse_run_id        uuid,
  p_processor_id        text,
  p_processor_version   text,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_parse_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_parse_run_id IS NULL OR p_processor_id IS NULL OR p_processor_version IS NULL THEN
    RAISE EXCEPTION 'record_pdf_ocr_started: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.statement_parse_runs WHERE id = p_parse_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_pdf_ocr_started: parse_run % not found', p_parse_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_parse_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSE_RUN_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;
  IF v_run.ocr_started_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'OCR_ALREADY_STARTED',
      'ocr_started_at', v_run.ocr_started_at);
  END IF;
  IF v_run.parser_file_format <> 'PDF'::public.statement_file_format_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSE_RUN_NOT_PDF',
      'parser_file_format', v_run.parser_file_format::text);
  END IF;

  UPDATE public.statement_parse_runs
    SET ocr_processor_id      = p_processor_id,
        ocr_processor_version = p_processor_version,
        ocr_started_at        = clock_timestamp(),
        updated_at            = clock_timestamp()
    WHERE id = p_parse_run_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_pdf_parser';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PDF_OCR_STARTED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state  => jsonb_build_object(
      'parse_run_id',          v_run.id,
      'ocr_processor_id',      p_processor_id,
      'ocr_processor_version', p_processor_version),
    p_reason => format('Document AI OCR started: processor=%s version=%s',
                       p_processor_id, p_processor_version));

  RETURN jsonb_build_object('ok', true,
    'parse_run_id',          v_run.id,
    'ocr_processor_id',      p_processor_id,
    'ocr_processor_version', p_processor_version,
    'audit_event_id',        v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_pdf_ocr_started(uuid, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pdf_ocr_started(uuid, text, text, uuid) TO service_role;

-- ============================================================================
-- 6. RPC: record_pdf_ocr_completed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_pdf_ocr_completed(
  p_parse_run_id     uuid,
  p_page_count       int,
  p_cost_cents       int,
  p_artifact_path    text DEFAULT NULL,
  p_actor_user_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_parse_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_parse_run_id IS NULL OR p_page_count IS NULL OR p_cost_cents IS NULL THEN
    RAISE EXCEPTION 'record_pdf_ocr_completed: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_page_count < 0 OR p_cost_cents < 0 THEN
    RAISE EXCEPTION 'record_pdf_ocr_completed: page_count and cost_cents must be >= 0' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.statement_parse_runs WHERE id = p_parse_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_pdf_ocr_completed: parse_run % not found', p_parse_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.ocr_started_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'OCR_NOT_STARTED');
  END IF;
  IF v_run.ocr_completed_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'OCR_ALREADY_COMPLETED',
      'ocr_completed_at', v_run.ocr_completed_at);
  END IF;

  UPDATE public.statement_parse_runs
    SET ocr_page_count    = p_page_count,
        ocr_cost_cents    = p_cost_cents,
        ocr_artifact_path = p_artifact_path,
        ocr_completed_at  = clock_timestamp(),
        updated_at        = clock_timestamp()
    WHERE id = p_parse_run_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_pdf_parser';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PDF_OCR_COMPLETED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state  => jsonb_build_object(
      'parse_run_id',          v_run.id,
      'ocr_processor_id',      v_run.ocr_processor_id,
      'ocr_processor_version', v_run.ocr_processor_version,
      'page_count',            p_page_count,
      'cost_cents',            p_cost_cents,
      'ocr_artifact_path',     p_artifact_path),
    p_reason => format('Document AI OCR completed: %s page(s), %s cents',
                       p_page_count, p_cost_cents));

  RETURN jsonb_build_object('ok', true,
    'parse_run_id',          v_run.id,
    'page_count',            p_page_count,
    'cost_cents',            p_cost_cents,
    'ocr_processor_id',      v_run.ocr_processor_id,
    'ocr_processor_version', v_run.ocr_processor_version,
    'audit_event_id',        v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_pdf_ocr_completed(uuid, int, int, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pdf_ocr_completed(uuid, int, int, text, uuid) TO service_role;

-- ============================================================================
-- 7. RPC: record_pdf_ocr_failed
-- ============================================================================
-- Does NOT change parse_run status — caller decides retry (transient) vs
-- fail_statement_parse (persistent) based on the `transient` flag.
CREATE OR REPLACE FUNCTION public.record_pdf_ocr_failed(
  p_parse_run_id     uuid,
  p_error_category   public.pdf_ocr_error_category_enum,
  p_transient        boolean,
  p_error_message    text,
  p_actor_user_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_parse_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_parse_run_id IS NULL OR p_error_category IS NULL OR p_transient IS NULL
     OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'record_pdf_ocr_failed: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'record_pdf_ocr_failed: error_message length must be 1..2000 (got %)',
      length(p_error_message) USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.statement_parse_runs WHERE id = p_parse_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_pdf_ocr_failed: parse_run % not found', p_parse_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.ocr_started_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'OCR_NOT_STARTED');
  END IF;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_pdf_parser';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PDF_OCR_FAILED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state  => jsonb_build_object(
      'parse_run_id',          v_run.id,
      'ocr_processor_id',      v_run.ocr_processor_id,
      'ocr_processor_version', v_run.ocr_processor_version,
      'error_category',        p_error_category::text,
      'transient',             p_transient,
      'error_message',         p_error_message),
    p_reason => format('Document AI OCR failed (%s, transient=%s): %s',
                       p_error_category::text, p_transient, left(p_error_message, 200)));

  RETURN jsonb_build_object('ok', true,
    'parse_run_id',   v_run.id,
    'error_category', p_error_category::text,
    'transient',      p_transient,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_pdf_ocr_failed(uuid, public.pdf_ocr_error_category_enum, boolean, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pdf_ocr_failed(uuid, public.pdf_ocr_error_category_enum, boolean, text, uuid) TO service_role;

-- ============================================================================
-- 8. RPC: record_pdf_parsed_row
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_pdf_parsed_row(
  p_parse_run_id                    uuid,
  p_source_row_index                int,
  p_provider_native                 jsonb,
  p_date_text                       text,
  p_amount_text                     text,
  p_currency                        text,
  p_direction_hint                  public.parsed_row_direction_hint_enum,
  p_parser_confidence               text,
  p_extraction_confidence_per_field jsonb DEFAULT NULL,
  p_description_text                text  DEFAULT NULL,
  p_reference_text                  text  DEFAULT NULL,
  p_counterparty_text               text  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run    public.statement_parse_runs%ROWTYPE;
  v_row_id uuid := public.gen_uuid_v7();
BEGIN
  IF p_parse_run_id IS NULL OR p_source_row_index IS NULL
     OR p_provider_native IS NULL OR p_date_text IS NULL
     OR p_amount_text IS NULL OR p_currency IS NULL
     OR p_parser_confidence IS NULL THEN
    RAISE EXCEPTION 'record_pdf_parsed_row: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_parser_confidence NOT IN ('HIGH','LOW') THEN
    RAISE EXCEPTION 'record_pdf_parsed_row: parser_confidence must be HIGH or LOW (got %)', p_parser_confidence
      USING ERRCODE='22023';
  END IF;
  IF p_extraction_confidence_per_field IS NOT NULL
     AND jsonb_typeof(p_extraction_confidence_per_field) <> 'object' THEN
    RAISE EXCEPTION 'record_pdf_parsed_row: extraction_confidence_per_field must be an object'
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_run FROM public.statement_parse_runs WHERE id = p_parse_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_pdf_parsed_row: parse_run % not found', p_parse_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_parse_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSE_RUN_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;
  IF v_run.parser_file_format <> 'PDF'::public.statement_file_format_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSE_RUN_NOT_PDF',
      'parser_file_format', v_run.parser_file_format::text);
  END IF;

  BEGIN
    INSERT INTO public.statement_parsed_rows
      (id, parse_run_id, statement_upload_id, source_row_index, provider_native,
       date_text, amount_text, currency, description_text, reference_text,
       counterparty_text, direction_hint, extraction_confidence_per_field,
       parser_confidence, created_at)
    VALUES
      (v_row_id, p_parse_run_id, v_run.statement_upload_id, p_source_row_index,
       p_provider_native, p_date_text, p_amount_text, p_currency,
       p_description_text, p_reference_text, p_counterparty_text,
       p_direction_hint, p_extraction_confidence_per_field,
       p_parser_confidence, clock_timestamp());
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DUPLICATE_ROW_INDEX',
      'parse_run_id', p_parse_run_id, 'source_row_index', p_source_row_index);
  END;

  UPDATE public.statement_parse_runs
    SET row_count  = row_count + 1,
        updated_at = clock_timestamp()
    WHERE id = p_parse_run_id;

  RETURN jsonb_build_object('ok', true, 'parsed_row_id', v_row_id,
    'parser_confidence', p_parser_confidence);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_pdf_parsed_row(uuid, int, jsonb, text, text, text, public.parsed_row_direction_hint_enum, text, jsonb, text, text, text) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_pdf_parsed_row(uuid, int, jsonb, text, text, text, public.parsed_row_direction_hint_enum, text, jsonb, text, text, text) TO service_role;

-- ============================================================================
-- 9. RPC: flag_low_confidence_parsed_row
-- ============================================================================
CREATE OR REPLACE FUNCTION public.flag_low_confidence_parsed_row(
  p_parsed_row_id            uuid,
  p_fields_below_threshold   text[],
  p_threshold                numeric,
  p_actor_user_id            uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row        public.statement_parsed_rows%ROWTYPE;
  v_run        public.statement_parse_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_parsed_row_id IS NULL OR p_fields_below_threshold IS NULL
     OR p_threshold IS NULL THEN
    RAISE EXCEPTION 'flag_low_confidence_parsed_row: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_threshold < 0 OR p_threshold > 1 THEN
    RAISE EXCEPTION 'flag_low_confidence_parsed_row: threshold must be in [0,1] (got %)', p_threshold
      USING ERRCODE='22023';
  END IF;
  IF array_length(p_fields_below_threshold, 1) IS NULL THEN
    RAISE EXCEPTION 'flag_low_confidence_parsed_row: fields_below_threshold must not be empty'
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_row FROM public.statement_parsed_rows WHERE id = p_parsed_row_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'flag_low_confidence_parsed_row: row % not found', p_parsed_row_id USING ERRCODE='02000';
  END IF;
  IF v_row.parser_confidence IS DISTINCT FROM 'LOW' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ROW_NOT_LOW_CONFIDENCE',
      'parser_confidence', v_row.parser_confidence);
  END IF;
  SELECT * INTO v_run FROM public.statement_parse_runs WHERE id = v_row.parse_run_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_pdf_parser';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PDF_PARSE_LOW_CONFIDENCE_ROW',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_row.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state  => jsonb_build_object(
      'parsed_row_id',           v_row.id,
      'parse_run_id',            v_row.parse_run_id,
      'statement_upload_id',     v_row.statement_upload_id,
      'source_row_index',        v_row.source_row_index,
      'fields_below_threshold',  to_jsonb(p_fields_below_threshold),
      'threshold',               p_threshold),
    p_reason => format('PDF parsed row %s: %s field(s) below threshold %s',
                       v_row.source_row_index,
                       array_length(p_fields_below_threshold, 1),
                       p_threshold));

  RETURN jsonb_build_object('ok', true,
    'parsed_row_id', v_row.id,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.flag_low_confidence_parsed_row(uuid, text[], numeric, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.flag_low_confidence_parsed_row(uuid, text[], numeric, uuid) TO service_role;

-- ============================================================================
-- 10. Seed Revolut PDF parser
-- ============================================================================
INSERT INTO public.statement_parser_registry
  (provider, file_format, version, parser_module_ref, is_active, notes,
   registered_by_user_id, registered_at, updated_at)
VALUES
  ('REVOLUT', 'PDF'::public.statement_file_format_enum, '1.0.0',
   'cyprus_bookkeeping_api.parsers.revolut_pdf:parse',
   true,
   'Revolut PDF parser via Google Document AI (EU region). Processor config + ParsedRow column mapping per Stage-4 sub-docs.',
   NULL, clock_timestamp(), clock_timestamp())
ON CONFLICT (provider, file_format, version) DO NOTHING;
