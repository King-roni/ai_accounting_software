-- B07·P07 — INGESTION Workflow Phase Registration
--
-- Wires B07·P02..P06 into the workflow engine as the INGESTION phase.
-- The actual Python tool implementations are orchestrator-deferred; this
-- migration registers the SQL contract:
--   1. 5 tool registrations via public.register_tool (B03·P03 RPC)
--   2. 2 gate registrations via public.register_gate (B03·P03 RPC)
--   3. 2 gate evaluator functions backing the gates
--   4. 3 phase-event audit RPCs
--
-- The engine's evaluateGate (B03·P05) maps gate_name → evaluator function
-- by naming convention: evaluate_<gate_local_name>.

-- ============================================================================
-- 1. Tool registrations
-- ============================================================================
SELECT public.register_tool(
  p_tool_name => 'bank_pipeline.parse_csv',
  p_version => '1.0.0',
  p_input_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('statement_upload_id'),
    'properties', jsonb_build_object(
      'statement_upload_id', jsonb_build_object('type','string','format','uuid'))),
  p_output_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('parse_run_id','row_count'),
    'properties', jsonb_build_object(
      'parse_run_id', jsonb_build_object('type','string','format','uuid'),
      'row_count',    jsonb_build_object('type','integer','minimum',0))),
  p_side_effect      => 'READ_ONLY'::public.side_effect_class_enum,
  p_ai_tier          => 'NONE'::public.ai_tier_enum,
  p_failure_semantics=> 'RETRYABLE'::public.tool_failure_semantics_enum,
  p_dedup_key_generator_ref => 'statement_upload_id',
  p_description      => 'Revolut CSV parser. Reads from Raw Upload via signed URL, calls B07·P02 RPCs (start_statement_parse → N × record_parsed_row → complete_statement_parse). Per-upload idempotent.',
  p_retry_max_attempts    => 3,
  p_retry_backoff_base_ms => 2000,
  p_retry_backoff_max_ms  => 60000);

SELECT public.register_tool(
  p_tool_name => 'bank_pipeline.parse_pdf',
  p_version => '1.0.0',
  p_input_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('statement_upload_id'),
    'properties', jsonb_build_object(
      'statement_upload_id', jsonb_build_object('type','string','format','uuid'))),
  p_output_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('parse_run_id','row_count','ocr_page_count','ocr_cost_cents'),
    'properties', jsonb_build_object(
      'parse_run_id',    jsonb_build_object('type','string','format','uuid'),
      'row_count',       jsonb_build_object('type','integer','minimum',0),
      'ocr_page_count',  jsonb_build_object('type','integer','minimum',0),
      'ocr_cost_cents',  jsonb_build_object('type','integer','minimum',0))),
  p_side_effect      => 'CALLS_EXTERNAL_API'::public.side_effect_class_enum,
  p_ai_tier          => 'EXTERNAL_LLM'::public.ai_tier_enum,
  p_failure_semantics=> 'RETRYABLE'::public.tool_failure_semantics_enum,
  p_dedup_key_generator_ref => 'statement_upload_id',
  p_description      => 'Revolut PDF parser via Google Document AI (EU region). Dispatched through B06·P02 Privacy Gateway with B06·P03 redaction. Per-upload idempotent via the OCR-already-started gates in B07·P03 RPCs.',
  p_retry_max_attempts    => 3,
  p_retry_backoff_base_ms => 5000,
  p_retry_backoff_max_ms  => 120000);

SELECT public.register_tool(
  p_tool_name => 'bank_pipeline.normalize',
  p_version => '1.0.0',
  p_input_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('statement_upload_id'),
    'properties', jsonb_build_object(
      'statement_upload_id', jsonb_build_object('type','string','format','uuid'))),
  p_output_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('normalization_run_id','normalized_count','failed_count'),
    'properties', jsonb_build_object(
      'normalization_run_id', jsonb_build_object('type','string','format','uuid'),
      'normalized_count',     jsonb_build_object('type','integer','minimum',0),
      'failed_count',         jsonb_build_object('type','integer','minimum',0),
      'fx_pair_count',        jsonb_build_object('type','integer','minimum',0),
      'ai_fallback_count',    jsonb_build_object('type','integer','minimum',0))),
  p_side_effect      => 'READ_ONLY'::public.side_effect_class_enum,
  p_ai_tier          => 'NONE'::public.ai_tier_enum,
  p_failure_semantics=> 'RETRYABLE'::public.tool_failure_semantics_enum,
  p_dedup_key_generator_ref => 'statement_upload_id',
  p_description      => 'Row normalizer. Stages NormalizedTransaction[] into statement_normalized_rows (B07·P04); does NOT insert into transactions (that is bank_pipeline.dedupe). Counterparty Tier-2 LLM fallback dispatched through B06·P02 gateway as separate AI calls (logged under ai_gateway_invocations), so this tool itself declares ai_tier=NONE.',
  p_retry_max_attempts    => 3,
  p_retry_backoff_base_ms => 2000,
  p_retry_backoff_max_ms  => 60000);

SELECT public.register_tool(
  p_tool_name => 'bank_pipeline.dedupe',
  p_version => '1.0.0',
  p_input_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('statement_upload_id','workflow_run_id'),
    'properties', jsonb_build_object(
      'statement_upload_id', jsonb_build_object('type','string','format','uuid'),
      'workflow_run_id',     jsonb_build_object('type','string','format','uuid'))),
  p_output_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('dedup_run_id','new_count','exact_duplicate_count','probable_duplicate_count','needs_review_count'),
    'properties', jsonb_build_object(
      'dedup_run_id',             jsonb_build_object('type','string','format','uuid'),
      'new_count',                jsonb_build_object('type','integer','minimum',0),
      'exact_duplicate_count',    jsonb_build_object('type','integer','minimum',0),
      'probable_duplicate_count', jsonb_build_object('type','integer','minimum',0),
      'needs_review_count',       jsonb_build_object('type','integer','minimum',0))),
  p_side_effect      => 'WRITES_RUN_STATE'::public.side_effect_class_enum,
  p_ai_tier          => 'NONE'::public.ai_tier_enum,
  p_failure_semantics=> 'RETRYABLE'::public.tool_failure_semantics_enum,
  p_dedup_key_generator_ref => 'statement_upload_id',
  p_description      => 'Dedup engine. Reads statement_normalized_rows; INSERTs NEW into transactions; creates review_issues for DUPLICATE_PROBABLE / NEEDS_REVIEW; silently rejects DUPLICATE_EXACT with audit. Per-(dedup_run_id, normalized_row_id) idempotent.',
  p_retry_max_attempts    => 3,
  p_retry_backoff_base_ms => 2000,
  p_retry_backoff_max_ms  => 60000);

SELECT public.register_tool(
  p_tool_name => 'bank_pipeline.generate_evidence_pdfs',
  p_version => '1.0.0',
  p_input_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('statement_upload_id','workflow_run_id'),
    'properties', jsonb_build_object(
      'statement_upload_id', jsonb_build_object('type','string','format','uuid'),
      'workflow_run_id',     jsonb_build_object('type','string','format','uuid'))),
  p_output_schema => jsonb_build_object(
    'type','object','required', jsonb_build_array('generated_count','failed_count'),
    'properties', jsonb_build_object(
      'generated_count', jsonb_build_object('type','integer','minimum',0),
      'failed_count',    jsonb_build_object('type','integer','minimum',0))),
  p_side_effect      => 'WRITES_RUN_STATE'::public.side_effect_class_enum,
  p_ai_tier          => 'NONE'::public.ai_tier_enum,
  p_failure_semantics=> 'RETRYABLE'::public.tool_failure_semantics_enum,
  p_dedup_key_generator_ref => 'statement_upload_id',
  p_description      => 'Evidence PDF generator. Iterates NEW transactions, renders one PDF per row (orchestrator-side), calls record_evidence_pdf_generated; per-row failures continue the batch with HIGH review_issues. Calls accept_statement_upload at the end to transition PARSED → ACCEPTED. Per-(transaction_id, file_hash) idempotent.',
  p_retry_max_attempts    => 3,
  p_retry_backoff_base_ms => 2000,
  p_retry_backoff_max_ms  => 60000);

-- ============================================================================
-- 2. Gate registrations
-- ============================================================================
SELECT public.register_gate(
  p_gate_name => 'bank_pipeline.ingestion_entry',
  p_version   => '1.0.0',
  p_description => 'INGESTION phase entry gate. Passes when the targeted statement_uploads.upload_status = UPLOADED. Evaluator: public.evaluate_ingestion_entry(statement_upload_id) → jsonb.');

SELECT public.register_gate(
  p_gate_name => 'bank_pipeline.ingestion_exit',
  p_version   => '1.0.0',
  p_description => 'INGESTION phase exit gate. Passes when statement_uploads.upload_status = ACCEPTED, AND all transactions for the upload have dedup_status set, AND every NEW transaction has at least one evidence_pdfs row. Evaluator: public.evaluate_ingestion_exit(statement_upload_id) → jsonb.');

-- ============================================================================
-- 3. Gate evaluator functions
-- ============================================================================
CREATE OR REPLACE FUNCTION public.evaluate_ingestion_entry(
  p_statement_upload_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload public.statement_uploads%ROWTYPE;
BEGIN
  IF p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'evaluate_ingestion_entry: p_statement_upload_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('passed', false, 'reason', 'STATEMENT_UPLOAD_NOT_FOUND');
  END IF;
  IF v_upload.upload_status = 'UPLOADED'::public.statement_upload_status_enum THEN
    RETURN jsonb_build_object('passed', true,
      'statement_upload_id', v_upload.id, 'upload_status', v_upload.upload_status::text);
  END IF;
  RETURN jsonb_build_object('passed', false, 'reason', 'UPLOAD_NOT_IN_UPLOADED_STATE',
    'current_status', v_upload.upload_status::text);
END;
$function$;

REVOKE ALL ON FUNCTION public.evaluate_ingestion_entry(uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.evaluate_ingestion_entry(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.evaluate_ingestion_exit(
  p_statement_upload_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload                 public.statement_uploads%ROWTYPE;
  v_new_tx_count           int;
  v_new_tx_with_pdf_count  int;
  v_missing_pdf_count      int;
BEGIN
  IF p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'evaluate_ingestion_exit: p_statement_upload_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('passed', false, 'reason', 'STATEMENT_UPLOAD_NOT_FOUND');
  END IF;
  IF v_upload.upload_status <> 'ACCEPTED'::public.statement_upload_status_enum THEN
    RETURN jsonb_build_object('passed', false, 'reason', 'UPLOAD_NOT_ACCEPTED',
      'current_status', v_upload.upload_status::text);
  END IF;

  SELECT count(*) INTO v_new_tx_count FROM public.transactions
    WHERE statement_upload_id = p_statement_upload_id
      AND dedup_status = 'NEW'::public.transaction_dedup_status_enum;
  SELECT count(DISTINCT t.id) INTO v_new_tx_with_pdf_count FROM public.transactions t
    JOIN public.evidence_pdfs e ON e.transaction_id = t.id
    WHERE t.statement_upload_id = p_statement_upload_id
      AND t.dedup_status = 'NEW'::public.transaction_dedup_status_enum;
  v_missing_pdf_count := v_new_tx_count - v_new_tx_with_pdf_count;

  IF v_missing_pdf_count > 0 THEN
    -- ACCEPTED implies coverage from B07·P06's gate; this is a belt-and-suspenders check.
    RETURN jsonb_build_object('passed', false, 'reason', 'INCOMPLETE_EVIDENCE_COVERAGE',
      'new_tx_count', v_new_tx_count,
      'new_tx_with_pdf_count', v_new_tx_with_pdf_count,
      'missing_evidence_pdf_count', v_missing_pdf_count);
  END IF;

  RETURN jsonb_build_object('passed', true,
    'statement_upload_id', v_upload.id,
    'upload_status', 'ACCEPTED',
    'new_tx_count', v_new_tx_count,
    'evidence_pdf_count', v_new_tx_with_pdf_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.evaluate_ingestion_exit(uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.evaluate_ingestion_exit(uuid) TO service_role;

-- ============================================================================
-- 4. Phase-event audit RPCs
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ingestion_phase_started(
  p_workflow_run_id     uuid,
  p_statement_upload_id uuid,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload public.statement_uploads%ROWTYPE;
  v_gate   jsonb;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_workflow_run_id IS NULL OR p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'record_ingestion_phase_started: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ingestion_phase_started: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;
  v_gate := public.evaluate_ingestion_entry(p_statement_upload_id);
  IF (v_gate->>'passed')::bool IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ENTRY_GATE_NOT_PASSED', 'gate_envelope', v_gate);
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'workflow_engine';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'INGESTION_PHASE_STARTED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id => p_statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_after_state => jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'statement_upload_id', p_statement_upload_id,
      'entry_gate', v_gate),
    p_reason => format('INGESTION phase started for upload %s', p_statement_upload_id));
  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ingestion_phase_started(uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ingestion_phase_started(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.record_ingestion_phase_completed(
  p_workflow_run_id     uuid,
  p_statement_upload_id uuid,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload public.statement_uploads%ROWTYPE;
  v_gate   jsonb;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_workflow_run_id IS NULL OR p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'record_ingestion_phase_completed: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ingestion_phase_completed: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;
  v_gate := public.evaluate_ingestion_exit(p_statement_upload_id);
  IF (v_gate->>'passed')::bool IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'EXIT_GATE_NOT_PASSED', 'gate_envelope', v_gate);
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'workflow_engine';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'INGESTION_PHASE_COMPLETED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id => p_statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_after_state => jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'statement_upload_id', p_statement_upload_id,
      'exit_gate', v_gate),
    p_reason => format('INGESTION phase completed for upload %s (new_tx=%s)',
                       p_statement_upload_id, v_gate->>'new_tx_count'));
  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id,
    'gate_envelope', v_gate);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ingestion_phase_completed(uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ingestion_phase_completed(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.record_ingestion_phase_holding(
  p_workflow_run_id     uuid,
  p_statement_upload_id uuid,
  p_holding_at_tool     text,
  p_hold_reason         text,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload public.statement_uploads%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_workflow_run_id IS NULL OR p_statement_upload_id IS NULL
     OR p_holding_at_tool IS NULL OR p_hold_reason IS NULL THEN
    RAISE EXCEPTION 'record_ingestion_phase_holding: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_hold_reason) = 0 OR length(p_hold_reason) > 2000 THEN
    RAISE EXCEPTION 'record_ingestion_phase_holding: hold_reason length must be 1..2000' USING ERRCODE='22023';
  END IF;
  IF p_holding_at_tool NOT IN ('bank_pipeline.parse_csv','bank_pipeline.parse_pdf',
                                'bank_pipeline.normalize','bank_pipeline.dedupe',
                                'bank_pipeline.generate_evidence_pdfs') THEN
    RAISE EXCEPTION 'record_ingestion_phase_holding: holding_at_tool not a known INGESTION tool (got %)', p_holding_at_tool
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ingestion_phase_holding: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'workflow_engine';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'INGESTION_PHASE_HOLDING',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id => p_statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_after_state => jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'statement_upload_id', p_statement_upload_id,
      'holding_at_tool', p_holding_at_tool,
      'hold_reason', p_hold_reason),
    p_reason => format('INGESTION phase HOLDING at %s: %s', p_holding_at_tool, left(p_hold_reason, 200)));
  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.record_ingestion_phase_holding(uuid, uuid, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ingestion_phase_holding(uuid, uuid, text, text, uuid) TO service_role;
