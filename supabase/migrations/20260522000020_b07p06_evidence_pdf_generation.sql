-- B07·P06 — Evidence PDF Generation
--
-- The Python PDF renderer (Puppeteer/WeasyPrint/ReactPDF + the actual layout)
-- is orchestrator-deferred. SQL ships the registration RPCs + lifecycle audit
-- + the upload's PARSED → ACCEPTED transition gate.
--
-- evidence_pdfs already exists (B04·P02) with UNIQUE (transaction_id, file_hash)
-- + file_hash sha256-hex CHECK + FK to transactions. This phase only adds RPCs.
--
-- Coverage rule: only NEW dedup_status transactions need evidence PDFs.
-- DUPLICATE_EXACT silently rejects (no transactions row exists). PROBABLE /
-- NEEDS_REVIEW haven't been inserted into transactions yet — they need user
-- resolution first. So the accept gate counts NEW only.

-- ============================================================================
-- 1. RPC: record_evidence_pdf_generated
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_evidence_pdf_generated(
  p_transaction_id     uuid,
  p_file_id            text,
  p_file_hash          text,
  p_version            bigint DEFAULT 1,
  p_actor_user_id      uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx          public.transactions%ROWTYPE;
  v_evidence_id uuid := public.gen_uuid_v7();
  v_inserted    boolean;
  v_existing    public.evidence_pdfs%ROWTYPE;
  v_audit_row   audit.audit_events;
  v_kind        audit.actor_kind_enum;
  v_system      text;
  v_action      text;
BEGIN
  IF p_transaction_id IS NULL OR p_file_id IS NULL OR p_file_hash IS NULL THEN
    RAISE EXCEPTION 'record_evidence_pdf_generated: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_version IS NULL OR p_version < 1 THEN
    RAISE EXCEPTION 'record_evidence_pdf_generated: version must be >= 1 (got %)', p_version USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_evidence_pdf_generated: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;

  INSERT INTO public.evidence_pdfs
    (id, organization_id, business_id, transaction_id, file_id, file_hash,
     generated_from_transaction_version, generated_at, created_at)
  VALUES
    (v_evidence_id, v_tx.organization_id, v_tx.business_id, p_transaction_id,
     p_file_id, p_file_hash, p_version, clock_timestamp(), clock_timestamp())
  ON CONFLICT (transaction_id, file_hash) DO NOTHING
  RETURNING id INTO v_evidence_id;

  IF v_evidence_id IS NULL THEN
    -- Replay — look up the existing row
    SELECT * INTO v_existing FROM public.evidence_pdfs
      WHERE transaction_id = p_transaction_id AND file_hash = p_file_hash;
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'evidence_pdf_id', v_existing.id,
      'version', v_existing.generated_from_transaction_version);
  END IF;

  v_action := CASE WHEN p_version = 1 THEN 'EVIDENCE_PDF_GENERATED'
                   ELSE 'EVIDENCE_PDF_REGENERATED' END;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'evidence_pdf_generator';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => v_action,
    p_subject_type => 'EVIDENCE_PDF'::audit.subject_type_enum,
    p_subject_id   => v_evidence_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'evidence_pdf_id',  v_evidence_id,
      'transaction_id',   p_transaction_id,
      'file_id',          p_file_id,
      'file_hash',        p_file_hash,
      'version',          p_version),
    p_reason => format('evidence PDF v%s for transaction %s (hash %s)',
                       p_version, p_transaction_id, left(p_file_hash, 12)));

  RETURN jsonb_build_object('ok', true,
    'evidence_pdf_id', v_evidence_id,
    'version',         p_version,
    'audit_event_id',  v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_evidence_pdf_generated(uuid, text, text, bigint, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_evidence_pdf_generated(uuid, text, text, bigint, uuid) TO service_role;

-- ============================================================================
-- 2. RPC: record_evidence_pdf_generation_failed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_evidence_pdf_generation_failed(
  p_transaction_id  uuid,
  p_workflow_run_id uuid,
  p_error_category  text,
  p_error_message   text,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx              public.transactions%ROWTYPE;
  v_review_issue_id uuid := public.gen_uuid_v7();
  v_audit_row       audit.audit_events;
  v_kind            audit.actor_kind_enum;
  v_system          text;
BEGIN
  IF p_transaction_id IS NULL OR p_workflow_run_id IS NULL
     OR p_error_category IS NULL OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'record_evidence_pdf_generation_failed: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'record_evidence_pdf_generation_failed: error_message length must be 1..2000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_evidence_pdf_generation_failed: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_issue_id, v_tx.organization_id, v_tx.business_id, p_workflow_run_id, p_transaction_id,
     'bank_pipeline.evidence_pdf_generation_failed',
     'MISSING_DOCUMENTS'::public.review_issue_group_enum,
     'HIGH'::public.review_issue_severity_enum,
     'Evidence PDF could not be generated',
     format('Generating the evidence PDF for this transaction failed (%s). The transaction is otherwise intact; an operator can retry the PDF generation from the transaction view.',
            p_error_category),
     jsonb_build_object(
       'transaction_id', p_transaction_id,
       'error_category', p_error_category,
       'error_message',  p_error_message),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'evidence_pdf_generator';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'EVIDENCE_PDF_GENERATION_FAILED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id   => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id',   p_transaction_id,
      'review_issue_id',  v_review_issue_id,
      'error_category',   p_error_category,
      'error_message',    p_error_message),
    p_reason => format('evidence PDF generation failed for transaction %s: %s — %s',
                       p_transaction_id, p_error_category, left(p_error_message, 200)));

  RETURN jsonb_build_object('ok', true,
    'transaction_id',   p_transaction_id,
    'review_issue_id',  v_review_issue_id,
    'audit_event_id',   v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_evidence_pdf_generation_failed(uuid, uuid, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_evidence_pdf_generation_failed(uuid, uuid, text, text, uuid) TO service_role;

-- ============================================================================
-- 3. RPC: accept_statement_upload  (PARSED → ACCEPTED gate)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.accept_statement_upload(
  p_statement_upload_id uuid,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload      public.statement_uploads%ROWTYPE;
  v_expected    int;
  v_with_pdf    int;
  v_missing     int;
  v_audit_row   audit.audit_events;
  v_kind        audit.actor_kind_enum;
  v_system      text;
BEGIN
  IF p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'accept_statement_upload: p_statement_upload_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads
    WHERE id = p_statement_upload_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'accept_statement_upload: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;
  IF v_upload.upload_status = 'ACCEPTED'::public.statement_upload_status_enum THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'current_status', 'ACCEPTED');
  END IF;
  IF v_upload.upload_status <> 'PARSED'::public.statement_upload_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'UPLOAD_NOT_IN_PARSED_STATE',
      'current_status', v_upload.upload_status::text);
  END IF;

  -- Count NEW transactions for this upload + count those with at least one
  -- evidence_pdfs row.
  SELECT count(*) INTO v_expected FROM public.transactions
    WHERE statement_upload_id = v_upload.id
      AND dedup_status = 'NEW'::public.transaction_dedup_status_enum;
  SELECT count(DISTINCT t.id) INTO v_with_pdf FROM public.transactions t
    JOIN public.evidence_pdfs e ON e.transaction_id = t.id
    WHERE t.statement_upload_id = v_upload.id
      AND t.dedup_status = 'NEW'::public.transaction_dedup_status_enum;
  v_missing := v_expected - v_with_pdf;

  IF v_missing > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INCOMPLETE_EVIDENCE_COVERAGE',
      'expected_count', v_expected, 'with_pdf_count', v_with_pdf, 'missing_count', v_missing);
  END IF;

  UPDATE public.statement_uploads
    SET upload_status = 'ACCEPTED'::public.statement_upload_status_enum,
        updated_at    = clock_timestamp()
    WHERE id = v_upload.id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'evidence_pdf_generator';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_UPLOAD_ACCEPTED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_upload.id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_before_state => jsonb_build_object('upload_status', 'PARSED'),
    p_after_state  => jsonb_build_object(
      'upload_status',    'ACCEPTED',
      'new_tx_count',     v_expected,
      'evidence_pdf_count', v_with_pdf),
    p_reason => format('upload accepted: %s NEW transactions all have evidence PDFs', v_expected));

  RETURN jsonb_build_object('ok', true,
    'statement_upload_id', v_upload.id,
    'new_tx_count',        v_expected,
    'evidence_pdf_count',  v_with_pdf,
    'audit_event_id',      v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.accept_statement_upload(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.accept_statement_upload(uuid, uuid) TO service_role;
