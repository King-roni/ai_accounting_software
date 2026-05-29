-- B07·P05 — Fix-up: apply direction sign to transactions.amount
--
-- transactions has CHECK transactions_amount_direction_chk:
--   direction='IN'  → amount > 0
--   direction='OUT' → amount < 0
--   direction='BOTH'→ unconstrained
--
-- statement_normalized_rows.amount is the absolute value (CHECK > 0), so the
-- dedup engine must apply the sign when materialising into transactions:
-- OUT rows store -amount, IN/BOTH rows store +amount.
--
-- The original 20260522000017 migration inserted the unsigned amount, which
-- the CHECK rejects for any OUT-direction NEW row. Forward-only fix.

CREATE OR REPLACE FUNCTION public.classify_and_record_dedup_row(
  p_dedup_run_id uuid, p_normalized_row_id uuid,
  p_soft_window_days int DEFAULT 30, p_amount_tolerance_cents int DEFAULT 1,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run public.statement_dedup_runs%ROWTYPE;
  v_norm public.statement_normalized_rows%ROWTYPE;
  v_existing_class public.statement_dedup_row_classifications%ROWTYPE;
  v_match_exact public.transactions%ROWTYPE;
  v_match_within public.statement_dedup_row_classifications%ROWTYPE;
  v_match_soft public.transactions%ROWTYPE;
  v_classification_id uuid := public.gen_uuid_v7();
  v_transaction_id uuid;
  v_review_issue_id uuid;
  v_matched_tx_id uuid;
  v_within_batch boolean := false;
  v_dedup_status public.transaction_dedup_status_enum;
  v_audit_action text;
  v_source_row_index int;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
  v_card_payload jsonb; v_issue_type text; v_title text; v_description text;
  v_signed_amount numeric;
  v_signed_match_amount numeric;
BEGIN
  IF p_dedup_run_id IS NULL OR p_normalized_row_id IS NULL THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.statement_dedup_runs WHERE id = p_dedup_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: dedup_run % not found', p_dedup_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_dedup_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEDUP_NOT_STARTED', 'current_status', v_run.status::text);
  END IF;
  SELECT * INTO v_existing_class FROM public.statement_dedup_row_classifications
    WHERE dedup_run_id = p_dedup_run_id AND normalized_row_id = p_normalized_row_id;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'dedup_status', v_existing_class.dedup_status::text,
      'transaction_id', v_existing_class.transaction_id,
      'review_issue_id', v_existing_class.review_issue_id,
      'matched_transaction_id', v_existing_class.matched_transaction_id);
  END IF;
  SELECT * INTO v_norm FROM public.statement_normalized_rows WHERE id = p_normalized_row_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: normalized_row % not found', p_normalized_row_id USING ERRCODE='02000';
  END IF;
  IF v_norm.statement_upload_id <> v_run.statement_upload_id THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: normalized_row belongs to a different upload (% vs %)',
      v_norm.statement_upload_id, v_run.statement_upload_id USING ERRCODE='22023';
  END IF;

  -- Apply direction sign: transactions stores negative for OUT, positive for
  -- IN. statement_normalized_rows.amount is the abs value (CHECK > 0).
  v_signed_amount := CASE v_norm.direction
                       WHEN 'OUT'::public.transaction_direction_enum THEN -v_norm.amount
                       ELSE v_norm.amount
                     END;

  SELECT * INTO v_match_exact FROM public.transactions
    WHERE business_id = v_run.business_id AND bank_account_id = v_run.bank_account_id
      AND source_row_hash = v_norm.source_row_hash LIMIT 1;
  IF FOUND THEN
    v_dedup_status := 'DUPLICATE_EXACT'; v_matched_tx_id := v_match_exact.id;
    v_audit_action := 'TRANSACTION_DEDUP_EXACT_DUPLICATE';
  ELSE
    SELECT c.* INTO v_match_within FROM public.statement_dedup_row_classifications c
      JOIN public.statement_normalized_rows n ON n.id = c.normalized_row_id
      WHERE c.dedup_run_id = p_dedup_run_id AND c.dedup_status = 'NEW'
        AND n.source_row_hash = v_norm.source_row_hash LIMIT 1;
    IF FOUND THEN
      v_dedup_status := 'DUPLICATE_EXACT'; v_matched_tx_id := v_match_within.transaction_id;
      v_within_batch := true; v_audit_action := 'TRANSACTION_DEDUP_EXACT_DUPLICATE';
    ELSE
      SELECT * INTO v_match_soft FROM public.transactions
        WHERE business_id = v_run.business_id AND bank_account_id = v_run.bank_account_id
          AND transaction_fingerprint = v_norm.transaction_fingerprint LIMIT 1;
      IF FOUND THEN
        v_matched_tx_id := v_match_soft.id;
        -- Compare on absolute amounts (the matched tx is signed, the staged
        -- normalized row is unsigned)
        IF abs(v_match_soft.transaction_date - v_norm.transaction_date) <= p_soft_window_days
           AND abs(round((abs(v_match_soft.amount) - v_norm.amount) * 100)::int) <= p_amount_tolerance_cents THEN
          v_dedup_status := 'DUPLICATE_PROBABLE'; v_audit_action := 'TRANSACTION_DEDUP_PROBABLE_DUPLICATE';
        ELSE
          v_dedup_status := 'NEEDS_REVIEW'; v_audit_action := 'TRANSACTION_DEDUP_NEEDS_REVIEW';
        END IF;
      ELSE
        v_dedup_status := 'NEW'; v_audit_action := 'TRANSACTION_DEDUP_NEW';
      END IF;
    END IF;
  END IF;

  SELECT COALESCE(MIN(p.source_row_index), 0) INTO v_source_row_index
    FROM public.statement_parsed_rows p WHERE p.id = ANY (v_norm.parsed_row_ids);

  IF v_dedup_status = 'NEW' THEN
    v_transaction_id := public.gen_uuid_v7();
    INSERT INTO public.transactions
      (id, organization_id, business_id, bank_account_id, statement_upload_id,
       source_row_index, source_row_hash, transaction_fingerprint,
       transaction_date, booking_date, amount, currency, direction,
       transaction_type, normalized_description, counterparty_name,
       counterparty_identifier_masked, counterparty_identifier_encrypted, reference,
       fx_paired_legs, dedup_status, secondary_tags,
       classification_status, match_status, ledger_status, review_status,
       created_at, updated_at)
    VALUES
      (v_transaction_id, v_run.organization_id, v_run.business_id, v_run.bank_account_id,
       v_run.statement_upload_id, v_source_row_index, v_norm.source_row_hash, v_norm.transaction_fingerprint,
       v_norm.transaction_date, v_norm.booking_date, v_signed_amount, v_norm.currency, v_norm.direction,
       COALESCE(v_norm.transaction_type_candidate, 'UNKNOWN'::public.transaction_type_enum),
       v_norm.normalized_description, v_norm.counterparty_name,
       v_norm.counterparty_identifier_masked, v_norm.counterparty_identifier_encrypted, v_norm.reference,
       v_norm.fx_paired_legs, 'NEW'::public.transaction_dedup_status_enum, '[]'::jsonb,
       'PENDING'::public.transaction_classification_status_enum,
       'UNMATCHED'::public.transaction_match_status_enum,
       'PENDING'::public.transaction_ledger_status_enum,
       'NONE'::public.transaction_review_status_enum,
       clock_timestamp(), clock_timestamp());
  ELSIF v_dedup_status IN ('DUPLICATE_PROBABLE','NEEDS_REVIEW') THEN
    v_review_issue_id := public.gen_uuid_v7();
    IF v_dedup_status = 'DUPLICATE_PROBABLE' THEN
      v_issue_type := 'bank_pipeline.duplicate_probable';
      v_title := 'Possible duplicate bank statement row';
      v_description := format('A row in this statement upload matches an existing transaction (fingerprint %s). Confirm whether to keep the new row, mark it as a duplicate, or edit and confirm.',
                              left(v_norm.transaction_fingerprint, 12));
    ELSE
      v_issue_type := 'bank_pipeline.duplicate_needs_review';
      v_title := 'Ambiguous duplicate bank statement row';
      v_description := format('A row in this statement upload has the same fingerprint as an existing transaction but differs in date or amount beyond the auto-dedup tolerance. Manual review required.');
    END IF;
    v_card_payload := jsonb_build_object(
      'normalized_row_id', v_norm.id, 'statement_upload_id', v_run.statement_upload_id,
      'source_row_index', v_source_row_index,
      'candidate', jsonb_build_object(
        'transaction_date', v_norm.transaction_date, 'amount', v_norm.amount,
        'currency', v_norm.currency, 'direction', v_norm.direction::text,
        'description', v_norm.normalized_description, 'counterparty', v_norm.counterparty_name),
      'matched_transaction', jsonb_build_object(
        'id', v_match_soft.id, 'transaction_date', v_match_soft.transaction_date,
        'amount', v_match_soft.amount, 'currency', v_match_soft.currency),
      'dedup_status', v_dedup_status::text);
    INSERT INTO public.review_issues
      (id, organization_id, business_id, workflow_run_id, transaction_id,
       issue_type, issue_group, severity,
       plain_language_title, plain_language_description,
       card_payload_json, card_content_tier_used, card_content_fallback_applied,
       status, created_at, updated_at)
    VALUES
      (v_review_issue_id, v_run.organization_id, v_run.business_id, v_run.workflow_run_id,
       v_matched_tx_id,
       v_issue_type, 'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
       'MEDIUM'::public.review_issue_severity_enum,
       v_title, v_description,
       v_card_payload, 'NONE'::public.review_issue_card_content_tier_enum, false,
       'OPEN'::public.review_issue_status_enum,
       clock_timestamp(), clock_timestamp());
  END IF;

  INSERT INTO public.statement_dedup_row_classifications
    (id, dedup_run_id, normalized_row_id, dedup_status,
     transaction_id, review_issue_id, matched_transaction_id,
     matched_within_batch, classified_at)
  VALUES
    (v_classification_id, p_dedup_run_id, p_normalized_row_id, v_dedup_status,
     v_transaction_id, v_review_issue_id, v_matched_tx_id,
     v_within_batch, clock_timestamp());

  IF v_dedup_status = 'NEW' THEN
    UPDATE public.statement_dedup_runs SET new_count = new_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  ELSIF v_dedup_status = 'DUPLICATE_EXACT' THEN
    UPDATE public.statement_dedup_runs SET exact_duplicate_count = exact_duplicate_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  ELSIF v_dedup_status = 'DUPLICATE_PROBABLE' THEN
    UPDATE public.statement_dedup_runs SET probable_duplicate_count = probable_duplicate_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  ELSIF v_dedup_status = 'NEEDS_REVIEW' THEN
    UPDATE public.statement_dedup_runs SET needs_review_count = needs_review_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  END IF;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_dedup';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => v_audit_action,
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state => jsonb_build_object(
      'dedup_run_id', v_run.id, 'normalized_row_id', v_norm.id,
      'transaction_id', v_transaction_id, 'review_issue_id', v_review_issue_id,
      'matched_transaction_id', v_matched_tx_id, 'matched_within_batch', v_within_batch,
      'dedup_status', v_dedup_status::text, 'source_row_index', v_source_row_index,
      'transaction_fingerprint', v_norm.transaction_fingerprint,
      'signed_amount', v_signed_amount),
    p_reason => format('dedup: %s (row %s)', v_dedup_status::text, v_source_row_index));

  RETURN jsonb_build_object('ok', true,
    'dedup_status', v_dedup_status::text,
    'transaction_id', v_transaction_id,
    'review_issue_id', v_review_issue_id,
    'matched_transaction_id', v_matched_tx_id,
    'matched_within_batch', v_within_batch,
    'audit_event_id', v_audit_row.id);
END;
$function$;
