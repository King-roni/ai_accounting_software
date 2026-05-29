-- B07·P08 — Partial Upload Handling & Period Validation
--
-- The detection logic (CSV truncation signals, PDF confidence thresholds,
-- missing-page heuristics) is Python — orchestrator-deferred. SQL ships the
-- 5 registration RPCs + 1 preview helper + 1 column addition.
--
-- Spec mapping:
--   - record_partial_upload_detected      → HIGH MISSING_DOCUMENTS issue
--   - record_row_outside_declared_period  → MEDIUM POSSIBLE_WRONG_MATCH issue (per row)
--   - record_declared_period_mismatch     → HIGH NEEDS_CONFIRMATION issue
--   - exclude_transaction_from_period     → resolution action; sets period_excluded_at
--   - get_statement_upload_preview        → UX-hook helper for Block 14/16
--
-- review_issues entity anchor: upload-level issues anchor to the lowest-
-- source_row_index transaction of the upload (satisfies
-- review_issue_at_least_one_entity_chk). Orchestrator must invoke these RPCs
-- after at least one transaction has been inserted (post-dedupe).

-- ============================================================================
-- 1. Add period_excluded_at column to transactions
-- ============================================================================
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS period_excluded_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_transactions_period_excluded
  ON public.transactions (statement_upload_id)
  WHERE period_excluded_at IS NOT NULL;

-- ============================================================================
-- 2. RPC: record_partial_upload_detected
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_partial_upload_detected(
  p_statement_upload_id  uuid,
  p_workflow_run_id      uuid,
  p_parse_warning_summary jsonb,
  p_anchor_transaction_id uuid DEFAULT NULL,
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload     public.statement_uploads%ROWTYPE;
  v_anchor     uuid := p_anchor_transaction_id;
  v_existing   uuid;
  v_review_id  uuid := public.gen_uuid_v7();
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_statement_upload_id IS NULL OR p_workflow_run_id IS NULL
     OR p_parse_warning_summary IS NULL THEN
    RAISE EXCEPTION 'record_partial_upload_detected: required params missing' USING ERRCODE='22000';
  END IF;
  IF jsonb_typeof(p_parse_warning_summary) <> 'object' THEN
    RAISE EXCEPTION 'record_partial_upload_detected: parse_warning_summary must be an object' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_partial_upload_detected: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;

  -- Idempotency: existing partial_upload issue for this upload?
  SELECT id INTO v_existing FROM public.review_issues
    WHERE business_id = v_upload.business_id
      AND issue_type = 'bank_pipeline.partial_upload'
      AND card_payload_json->>'statement_upload_id' = p_statement_upload_id::text
    LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'review_issue_id', v_existing);
  END IF;

  IF v_anchor IS NULL THEN
    SELECT id INTO v_anchor FROM public.transactions
      WHERE statement_upload_id = p_statement_upload_id
      ORDER BY source_row_index ASC
      LIMIT 1;
  END IF;
  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_TRANSACTIONS_TO_ANCHOR',
      'statement_upload_id', p_statement_upload_id);
  END IF;

  -- Append to parse_warnings (jsonb array of warning objects).
  UPDATE public.statement_uploads
    SET parse_warnings = COALESCE(parse_warnings, '[]'::jsonb) || jsonb_build_array(p_parse_warning_summary),
        updated_at = clock_timestamp()
    WHERE id = p_statement_upload_id;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_id, v_upload.organization_id, v_upload.business_id, p_workflow_run_id, v_anchor,
     'bank_pipeline.partial_upload',
     'MISSING_DOCUMENTS'::public.review_issue_group_enum,
     'HIGH'::public.review_issue_severity_enum,
     'Partial upload detected — some rows could not be read',
     'The bank statement appears to be incomplete or truncated. The pipeline processed the rows it could read. Review the warning summary and choose: re-upload the complete file, accept what was processed, or contact support.',
     jsonb_build_object(
       'statement_upload_id',   p_statement_upload_id,
       'anchor_transaction_id', v_anchor,
       'parse_warning_summary', p_parse_warning_summary),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'bank_pipeline_partial_upload';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PARTIAL_UPLOAD_DETECTED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id => p_statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_after_state => jsonb_build_object(
      'statement_upload_id',   p_statement_upload_id,
      'review_issue_id',       v_review_id,
      'anchor_transaction_id', v_anchor,
      'parse_warning_summary', p_parse_warning_summary),
    p_reason => format('partial upload detected on %s: %s warning(s)',
                       p_statement_upload_id,
                       coalesce(jsonb_array_length(p_parse_warning_summary->'warnings'), 0)));

  RETURN jsonb_build_object('ok', true,
    'review_issue_id', v_review_id,
    'anchor_transaction_id', v_anchor,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_partial_upload_detected(uuid, uuid, jsonb, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_partial_upload_detected(uuid, uuid, jsonb, uuid, uuid) TO service_role;

-- ============================================================================
-- 3. RPC: record_row_outside_declared_period
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_row_outside_declared_period(
  p_transaction_id  uuid,
  p_workflow_run_id uuid,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx         public.transactions%ROWTYPE;
  v_upload     public.statement_uploads%ROWTYPE;
  v_existing   uuid;
  v_review_id  uuid := public.gen_uuid_v7();
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_workflow_run_id IS NULL THEN
    RAISE EXCEPTION 'record_row_outside_declared_period: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_row_outside_declared_period: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = v_tx.statement_upload_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_row_outside_declared_period: upload % not found', v_tx.statement_upload_id USING ERRCODE='02000';
  END IF;

  IF v_tx.transaction_date BETWEEN v_upload.declared_period_start AND v_upload.declared_period_end THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ROW_WITHIN_DECLARED_PERIOD',
      'transaction_date', v_tx.transaction_date,
      'declared_period_start', v_upload.declared_period_start,
      'declared_period_end',   v_upload.declared_period_end);
  END IF;

  SELECT id INTO v_existing FROM public.review_issues
    WHERE transaction_id = p_transaction_id
      AND issue_type = 'bank_pipeline.row_outside_declared_period'
    LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'review_issue_id', v_existing);
  END IF;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_id, v_tx.organization_id, v_tx.business_id, p_workflow_run_id, p_transaction_id,
     'bank_pipeline.row_outside_declared_period',
     'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
     'MEDIUM'::public.review_issue_severity_enum,
     'Transaction date is outside the declared statement period',
     format('This transaction (dated %s) falls outside the declared statement period (%s to %s). Confirm to include it, or exclude it from this period — either way the row remains in the database.',
            v_tx.transaction_date, v_upload.declared_period_start, v_upload.declared_period_end),
     jsonb_build_object(
       'transaction_id',         p_transaction_id,
       'statement_upload_id',    v_upload.id,
       'transaction_date',       v_tx.transaction_date,
       'declared_period_start',  v_upload.declared_period_start,
       'declared_period_end',    v_upload.declared_period_end),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'bank_pipeline_period_validation';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_ROW_OUTSIDE_DECLARED_PERIOD',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id',         p_transaction_id,
      'statement_upload_id',    v_upload.id,
      'review_issue_id',        v_review_id,
      'transaction_date',       v_tx.transaction_date,
      'declared_period_start',  v_upload.declared_period_start,
      'declared_period_end',    v_upload.declared_period_end),
    p_reason => format('row %s dated %s outside declared period [%s, %s]',
                       p_transaction_id, v_tx.transaction_date,
                       v_upload.declared_period_start, v_upload.declared_period_end));

  RETURN jsonb_build_object('ok', true,
    'review_issue_id', v_review_id,
    'audit_event_id',  v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_row_outside_declared_period(uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_row_outside_declared_period(uuid, uuid, uuid) TO service_role;

-- ============================================================================
-- 4. RPC: record_declared_period_mismatch
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_declared_period_mismatch(
  p_statement_upload_id   uuid,
  p_workflow_run_id       uuid,
  p_total_row_count       int,
  p_outside_period_count  int,
  p_anchor_transaction_id uuid DEFAULT NULL,
  p_actor_user_id         uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload     public.statement_uploads%ROWTYPE;
  v_anchor     uuid := p_anchor_transaction_id;
  v_existing   uuid;
  v_review_id  uuid := public.gen_uuid_v7();
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum; v_system text;
BEGIN
  IF p_statement_upload_id IS NULL OR p_workflow_run_id IS NULL
     OR p_total_row_count IS NULL OR p_outside_period_count IS NULL THEN
    RAISE EXCEPTION 'record_declared_period_mismatch: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_total_row_count <= 0 OR p_outside_period_count <> p_total_row_count THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_ALL_OUTSIDE_PERIOD',
      'total_row_count', p_total_row_count,
      'outside_period_count', p_outside_period_count);
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_declared_period_mismatch: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;

  SELECT id INTO v_existing FROM public.review_issues
    WHERE business_id = v_upload.business_id
      AND issue_type = 'bank_pipeline.declared_period_mismatch'
      AND card_payload_json->>'statement_upload_id' = p_statement_upload_id::text
    LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true, 'review_issue_id', v_existing);
  END IF;

  IF v_anchor IS NULL THEN
    SELECT id INTO v_anchor FROM public.transactions
      WHERE statement_upload_id = p_statement_upload_id
      ORDER BY source_row_index ASC LIMIT 1;
  END IF;
  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_TRANSACTIONS_TO_ANCHOR');
  END IF;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_id, v_upload.organization_id, v_upload.business_id, p_workflow_run_id, v_anchor,
     'bank_pipeline.declared_period_mismatch',
     'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
     'HIGH'::public.review_issue_severity_enum,
     'All rows are outside the declared statement period',
     format('Every parsed row in this statement falls outside the declared period (%s to %s). The declared period was likely wrong. Re-declare the period and re-trigger ingestion, or accept the data as-is for a different period.',
            v_upload.declared_period_start, v_upload.declared_period_end),
     jsonb_build_object(
       'statement_upload_id',    p_statement_upload_id,
       'total_row_count',        p_total_row_count,
       'outside_period_count',   p_outside_period_count,
       'declared_period_start',  v_upload.declared_period_start,
       'declared_period_end',    v_upload.declared_period_end,
       'anchor_transaction_id',  v_anchor),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'bank_pipeline_period_validation';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_DECLARED_PERIOD_MISMATCH',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id => p_statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_after_state => jsonb_build_object(
      'statement_upload_id',    p_statement_upload_id,
      'review_issue_id',        v_review_id,
      'total_row_count',        p_total_row_count,
      'outside_period_count',   p_outside_period_count,
      'declared_period_start',  v_upload.declared_period_start,
      'declared_period_end',    v_upload.declared_period_end),
    p_reason => format('all %s rows outside declared period [%s, %s]',
                       p_total_row_count, v_upload.declared_period_start, v_upload.declared_period_end));

  RETURN jsonb_build_object('ok', true,
    'review_issue_id', v_review_id,
    'audit_event_id',  v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_declared_period_mismatch(uuid, uuid, int, int, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_declared_period_mismatch(uuid, uuid, int, int, uuid, uuid) TO service_role;

-- ============================================================================
-- 5. RPC: exclude_transaction_from_period (resolution action)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.exclude_transaction_from_period(
  p_transaction_id  uuid,
  p_exclusion_reason text,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx         public.transactions%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_exclusion_reason IS NULL THEN
    RAISE EXCEPTION 'exclude_transaction_from_period: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_exclusion_reason) = 0 OR length(p_exclusion_reason) > 2000 THEN
    RAISE EXCEPTION 'exclude_transaction_from_period: exclusion_reason length must be 1..2000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exclude_transaction_from_period: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF v_tx.period_excluded_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'period_excluded_at', v_tx.period_excluded_at);
  END IF;

  UPDATE public.transactions
    SET period_excluded_at = clock_timestamp(),
        updated_at = clock_timestamp()
    WHERE id = p_transaction_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'bank_pipeline_period_validation';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'TRANSACTION_EXCLUDED_FROM_PERIOD',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id',     p_transaction_id,
      'statement_upload_id', v_tx.statement_upload_id,
      'period_excluded_at', clock_timestamp(),
      'exclusion_reason',   p_exclusion_reason),
    p_reason => format('transaction %s excluded from declared period: %s',
                       p_transaction_id, left(p_exclusion_reason, 200)));

  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.exclude_transaction_from_period(uuid, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.exclude_transaction_from_period(uuid, text, uuid) TO service_role;

-- ============================================================================
-- 6. Helper: get_statement_upload_preview
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_statement_upload_preview(
  p_statement_upload_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload                public.statement_uploads%ROWTYPE;
  v_first_date            date;
  v_last_date             date;
  v_total_count           int;
  v_outside_period_count  int;
  v_warning_count         int;
BEGIN
  IF p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'get_statement_upload_preview: p_statement_upload_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'get_statement_upload_preview: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;
  SELECT min(transaction_date), max(transaction_date), count(*),
         count(*) FILTER (WHERE transaction_date < v_upload.declared_period_start
                             OR transaction_date > v_upload.declared_period_end)
    INTO v_first_date, v_last_date, v_total_count, v_outside_period_count
    FROM public.transactions
    WHERE statement_upload_id = p_statement_upload_id;
  v_warning_count := COALESCE(jsonb_array_length(v_upload.parse_warnings), 0);

  RETURN jsonb_build_object(
    'statement_upload_id',         v_upload.id,
    'upload_status',               v_upload.upload_status::text,
    'declared_period_start',       v_upload.declared_period_start,
    'declared_period_end',         v_upload.declared_period_end,
    'first_transaction_date',      v_first_date,
    'last_transaction_date',       v_last_date,
    'total_transaction_count',     COALESCE(v_total_count, 0),
    'outside_period_count',        COALESCE(v_outside_period_count, 0),
    'partial_upload_warning_count', v_warning_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_statement_upload_preview(uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.get_statement_upload_preview(uuid) TO service_role;
