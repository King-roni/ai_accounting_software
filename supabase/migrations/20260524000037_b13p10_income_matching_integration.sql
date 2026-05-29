-- ============================================================================
-- Block 13 Phase 10 — Income Matching Integration & Multi-Invoice Allocation
-- Helper: get_in_workflow_match_candidates
-- RPCs: in_workflow_apply_income_match_outcome, in_workflow_confirm_multi_invoice_allocation,
--       in_workflow_reject_multi_invoice_allocation
-- Tool registry: 3 entries; phase_tool_expectations for IN_MONTHLY/INCOME_MATCHING + HUMAN_REVIEW_HOLD
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_in_workflow_match_candidates(
  p_business_id uuid,
  p_period_start date,
  p_period_end   date,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_txns jsonb;
  v_inv  jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'transaction_id', t.id, 'amount', t.amount, 'currency', t.currency,
    'transaction_date', t.transaction_date, 'transaction_type', t.transaction_type::text,
    'direction', t.direction::text
  ) ORDER BY t.transaction_date), '[]'::jsonb) INTO v_txns
  FROM public.transactions t
  WHERE t.business_id = p_business_id
    AND t.transaction_date BETWEEN p_period_start AND p_period_end
    AND t.in_workflow_in_scope = true
    AND t.transaction_type IN ('IN_INCOME','REFUND_IN');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'invoice_id', i.id, 'invoice_number', i.invoice_number,
    'lifecycle_status', i.lifecycle_status::text,
    'currency', i.currency, 'total_amount', i.total_amount,
    'issue_date', i.issue_date, 'due_date', i.due_date,
    'client_id', i.client_id
  ) ORDER BY i.issue_date), '[]'::jsonb) INTO v_inv
  FROM public.invoices i
  WHERE i.business_id = p_business_id
    AND i.invoice_type = 'TAX'
    AND i.lifecycle_status IN ('SENT','PAYMENT_EXPECTED','PARTIALLY_PAID','OVERPAID');

  RETURN jsonb_build_object(
    'decision','RAN',
    'transactions', v_txns,
    'invoice_candidates', v_inv
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_apply_income_match_outcome(
  p_organization_id uuid,
  p_business_id     uuid,
  p_workflow_run_id uuid,
  p_transaction_id  uuid,
  p_invoice_id      uuid,
  p_income_outcome  public.income_outcome_enum,
  p_allocated_amount numeric,
  p_paid_at         timestamptz,
  p_match_score     numeric DEFAULT 0.9,
  p_match_signals   jsonb DEFAULT '{}'::jsonb,
  p_proposed_allocations jsonb DEFAULT NULL,
  p_has_exact_reference boolean DEFAULT false,
  p_actor_user_id   uuid DEFAULT NULL,
  p_actor_system    text DEFAULT 'income_matcher',
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_txn public.transactions%ROWTYPE;
  v_inv public.invoices%ROWTYPE;
  v_match_id uuid := gen_uuid_v7();
  v_review_id uuid;
  v_lifecycle_result jsonb;
  v_match_status public.match_record_status_enum;
  v_match_level public.match_level_enum := 'STRONG_PROBABLE';
  v_match_method public.match_method_enum := 'DETERMINISTIC_RULE';
BEGIN
  SELECT * INTO v_txn FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','TRANSACTION_NOT_FOUND'); END IF;

  IF p_invoice_id IS NOT NULL THEN
    SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id;
    IF v_inv.invoice_type = 'PRO_FORMA' THEN
      RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_MATCHABLE');
    END IF;
  END IF;

  IF p_income_outcome = 'FULL_MATCH' THEN
    IF p_has_exact_reference THEN
      v_match_status := 'MATCHED_AUTO_HIGH_CONFIDENCE'::public.match_record_status_enum;
      v_match_level  := 'EXACT'::public.match_level_enum;
    ELSE
      v_match_status := 'MATCHED_NEEDS_CONFIRMATION'::public.match_record_status_enum;
    END IF;
  ELSIF p_income_outcome IN ('PARTIAL_PAYMENT','OVERPAYMENT') THEN
    v_match_status := 'MATCHED_NEEDS_CONFIRMATION'::public.match_record_status_enum;
  ELSIF p_income_outcome IN ('MULTIPLE_INVOICES_ONE_PAYMENT','POSSIBLE_REFUND_OR_TRANSFER') THEN
    v_match_status := 'POSSIBLE_MATCH'::public.match_record_status_enum;
  ELSIF p_income_outcome = 'ONE_INVOICE_MULTIPLE_PAYMENTS' THEN
    v_match_status := 'MATCHED_AUTO_HIGH_CONFIDENCE'::public.match_record_status_enum;
  ELSIF p_income_outcome = 'NO_MATCH' THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id,
      issue_type, issue_group, severity, plain_language_title, plain_language_description, recommended_action
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id,
      'income_matching.no_match',
      'MISSING_DOCUMENTS'::public.review_issue_group_enum,
      'HIGH'::public.review_issue_severity_enum,
      'Incoming payment with no matching invoice',
      'A payment was received but no matching invoice could be located. Either create an invoice and re-match, or mark this as non-invoice income.',
      'Create an invoice for this payment or reclassify as non-invoice income.'
    ) RETURNING id INTO v_review_id;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_INCOME_MATCHING_INVOKED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum, p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('outcome','NO_MATCH','review_issue_id', v_review_id),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','ALLOW','outcome','NO_MATCH','review_issue_id', v_review_id);
  END IF;

  IF p_invoice_id IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_ID_REQUIRED_FOR_OUTCOME');
  END IF;
  INSERT INTO public.match_records (
    id, organization_id, business_id, transaction_id, invoice_id,
    match_level, match_method, match_score, match_signals, match_status,
    split_payment_flag, requires_user_confirmation,
    matched_by_system, income_outcome
  ) VALUES (
    v_match_id, p_organization_id, p_business_id, p_transaction_id, p_invoice_id,
    v_match_level, v_match_method, p_match_score, COALESCE(p_match_signals, '{}'::jsonb), v_match_status,
    (p_income_outcome = 'MULTIPLE_INVOICES_ONE_PAYMENT'),
    (v_match_status IN ('MATCHED_NEEDS_CONFIRMATION','POSSIBLE_MATCH')),
    p_actor_system, p_income_outcome
  );

  IF p_income_outcome = 'FULL_MATCH' AND p_has_exact_reference THEN
    v_lifecycle_result := public.invoice_mark_paid(
      p_invoice_id, p_transaction_id, p_allocated_amount, p_paid_at,
      v_match_id, p_actor_user_id, p_actor_system, p_context);
  ELSIF p_income_outcome = 'FULL_MATCH' OR p_income_outcome = 'PARTIAL_PAYMENT' OR p_income_outcome = 'OVERPAYMENT' THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id, match_record_id, invoice_id,
      issue_type, issue_group, severity, plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id, v_match_id, p_invoice_id,
      'income_matching.' || lower(p_income_outcome::text),
      'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
      'MEDIUM'::public.review_issue_severity_enum,
      'Payment needs confirmation',
      format('Income match outcome: %s — please review and confirm.', p_income_outcome),
      'Confirm or reject the match.',
      jsonb_build_object(
        'outcome', p_income_outcome::text,
        'transaction_id', p_transaction_id,
        'invoice_id', p_invoice_id,
        'allocated_amount', p_allocated_amount,
        'match_record_id', v_match_id)
    ) RETURNING id INTO v_review_id;
    IF p_income_outcome = 'OVERPAYMENT' THEN
      INSERT INTO public.review_issues (
        organization_id, business_id, workflow_run_id, transaction_id, match_record_id, invoice_id,
        issue_type, issue_group, severity, plain_language_title, plain_language_description, recommended_action
      ) VALUES (
        p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id, v_match_id, p_invoice_id,
        'income_matching.overpayment_credit_note_required',
        'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
        'HIGH'::public.review_issue_severity_enum,
        'Overpayment received — credit note required',
        'The payment exceeds the invoice total. Issue a credit note for the surplus or refund.',
        'Issue a credit note for the surplus.'
      );
    END IF;
  ELSIF p_income_outcome = 'MULTIPLE_INVOICES_ONE_PAYMENT' THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id, match_record_id, invoice_id,
      issue_type, issue_group, severity, plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id, v_match_id, p_invoice_id,
      'income_matching.multiple_invoices_one_payment',
      'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
      'MEDIUM'::public.review_issue_severity_enum,
      'Payment may cover multiple invoices',
      'One payment may be allocated across multiple invoices. Please confirm the allocation or reject.',
      'Confirm the proposed allocation or edit it.',
      jsonb_build_object(
        'outcome', 'MULTIPLE_INVOICES_ONE_PAYMENT',
        'transaction_id', p_transaction_id,
        'proposed_allocations', COALESCE(p_proposed_allocations, '[]'::jsonb),
        'match_record_id', v_match_id)
    ) RETURNING id INTO v_review_id;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_MULTI_INVOICE_ALLOCATION_PROPOSED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum, p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('match_record_id', v_match_id,
                                          'proposed_allocations', COALESCE(p_proposed_allocations, '[]'::jsonb),
                                          'review_issue_id', v_review_id),
      p_reason:=NULL, p_request_context:=p_context);
  ELSIF p_income_outcome = 'POSSIBLE_REFUND_OR_TRANSFER' THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id, match_record_id, invoice_id,
      issue_type, issue_group, severity, plain_language_title, plain_language_description, recommended_action
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id, v_match_id, p_invoice_id,
      'income_matching.possible_refund_or_transfer',
      'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
      'MEDIUM'::public.review_issue_severity_enum,
      'Payment may be a refund or transfer',
      'The matcher could not determine whether this is income, a refund, or a transfer. Please reclassify.',
      'Reclassify transaction (REFUND_IN, INTERNAL_TRANSFER, or confirm as IN_INCOME).'
    ) RETURNING id INTO v_review_id;
  ELSIF p_income_outcome = 'ONE_INVOICE_MULTIPLE_PAYMENTS' THEN
    v_lifecycle_result := public.invoice_mark_partially_paid(
      p_invoice_id, p_transaction_id, p_allocated_amount, p_paid_at,
      v_match_id, p_actor_user_id, p_actor_system, p_context);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_INCOME_MATCHING_INVOKED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum, p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'outcome', p_income_outcome::text,
      'match_record_id', v_match_id,
      'invoice_id', p_invoice_id,
      'allocated_amount', p_allocated_amount,
      'review_issue_id', v_review_id,
      'lifecycle_result', v_lifecycle_result),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'outcome', p_income_outcome::text,
    'match_record_id', v_match_id,
    'review_issue_id', v_review_id,
    'lifecycle_result', v_lifecycle_result);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_confirm_multi_invoice_allocation(
  p_actor_user_id uuid,
  p_transaction_id uuid,
  p_match_record_id uuid,
  p_allocations    jsonb,
  p_was_edited     boolean DEFAULT false,
  p_context        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_txn public.transactions%ROWTYPE;
  v_match public.match_records%ROWTYPE;
  v_decision jsonb;
  v_alloc jsonb;
  v_sum_allocated numeric(18,2) := 0;
  v_inv public.invoices%ROWTYPE;
  v_cumulative numeric(18,2);
  v_remaining numeric(18,2);
  v_lifecycle_result jsonb;
  v_applied jsonb := '[]'::jsonb;
  v_tolerance numeric := 0.02;
  v_action_name text;
BEGIN
  SELECT * INTO v_txn FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','TRANSACTION_NOT_FOUND'); END IF;
  SELECT * INTO v_match FROM public.match_records WHERE id = p_match_record_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','MATCH_RECORD_NOT_FOUND'); END IF;

  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'CONFIRM_ALLOCATION',
    jsonb_build_object('transaction_id', p_transaction_id), v_txn.business_id, v_txn.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;

  IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ALLOCATIONS_REQUIRED');
  END IF;

  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_sum_allocated := v_sum_allocated + (v_alloc->>'amount')::numeric;
    SELECT * INTO v_inv FROM public.invoices WHERE id = (v_alloc->>'invoice_id')::uuid;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND','invoice_id', v_alloc->>'invoice_id');
    END IF;
    IF v_inv.invoice_type <> 'TAX' THEN
      RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_MATCHABLE','invoice_id', v_inv.id);
    END IF;
    IF v_inv.lifecycle_status NOT IN ('SENT','PAYMENT_EXPECTED','PARTIALLY_PAID','OVERPAID') THEN
      RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_ELIGIBLE','invoice_id', v_inv.id, 'lifecycle_status', v_inv.lifecycle_status::text);
    END IF;
    SELECT COALESCE(SUM(allocated_amount), 0)::numeric(18,2) INTO v_cumulative
      FROM public.invoice_payment_allocations
     WHERE invoice_id = v_inv.id
       AND allocation_kind NOT IN ('REFUND','OVERPAYMENT_SURPLUS');
    v_remaining := (v_inv.total_amount - v_cumulative)::numeric(18,2);
    IF (v_alloc->>'amount')::numeric > v_remaining + v_tolerance THEN
      RETURN jsonb_build_object('decision','DENY','reason_code','ALLOCATION_EXCEEDS_REMAINING',
        'invoice_id', v_inv.id, 'remaining', v_remaining, 'requested', (v_alloc->>'amount')::numeric);
    END IF;
  END LOOP;

  IF abs(v_sum_allocated - v_txn.amount) > v_tolerance THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ALLOCATION_SUM_MISMATCH',
      'sum_allocated', v_sum_allocated, 'transaction_amount', v_txn.amount);
  END IF;

  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    SELECT * INTO v_inv FROM public.invoices WHERE id = (v_alloc->>'invoice_id')::uuid FOR UPDATE;
    SELECT COALESCE(SUM(allocated_amount), 0)::numeric(18,2) INTO v_cumulative
      FROM public.invoice_payment_allocations
     WHERE invoice_id = v_inv.id
       AND allocation_kind NOT IN ('REFUND','OVERPAYMENT_SURPLUS');
    v_remaining := (v_inv.total_amount - v_cumulative)::numeric(18,2);
    IF (v_alloc->>'amount')::numeric >= v_remaining - 0.01 THEN
      v_lifecycle_result := public.invoice_mark_paid(
        v_inv.id, p_transaction_id, (v_alloc->>'amount')::numeric, clock_timestamp(),
        p_match_record_id, p_actor_user_id, NULL, p_context);
    ELSE
      v_lifecycle_result := public.invoice_mark_partially_paid(
        v_inv.id, p_transaction_id, (v_alloc->>'amount')::numeric, clock_timestamp(),
        p_match_record_id, p_actor_user_id, NULL, p_context);
    END IF;
    v_applied := v_applied || jsonb_build_object(
      'invoice_id', v_inv.id, 'amount', (v_alloc->>'amount')::numeric,
      'lifecycle_result', v_lifecycle_result);
  END LOOP;

  UPDATE public.match_records
     SET match_status = 'MATCHED_CONFIRMED'::public.match_record_status_enum,
         user_confirmation_status = 'CONFIRMED',
         confirmed_by = p_actor_user_id,
         confirmed_at = clock_timestamp(),
         updated_at = clock_timestamp()
   WHERE id = p_match_record_id;

  v_action_name := CASE WHEN p_was_edited THEN 'IN_MULTI_INVOICE_ALLOCATION_EDITED_AND_CONFIRMED'
                                          ELSE 'IN_MULTI_INVOICE_ALLOCATION_CONFIRMED' END;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:=v_action_name,
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum, p_subject_id:=p_match_record_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_txn.organization_id, p_business_id:=v_txn.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'transaction_id', p_transaction_id,
      'match_record_id', p_match_record_id,
      'allocations_applied', v_applied,
      'was_edited', p_was_edited),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW','match_record_id', p_match_record_id,
    'allocations_applied', v_applied);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_reject_multi_invoice_allocation(
  p_actor_user_id   uuid,
  p_match_record_id uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_match public.match_records%ROWTYPE;
  v_decision jsonb;
BEGIN
  SELECT * INTO v_match FROM public.match_records WHERE id = p_match_record_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','MATCH_RECORD_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'REJECT_ALLOCATION',
    jsonb_build_object('match_record_id', p_match_record_id),
    v_match.business_id, v_match.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  UPDATE public.match_records
     SET match_status = 'REJECTED_MATCH'::public.match_record_status_enum,
         user_confirmation_status = 'REJECTED',
         confirmed_by = p_actor_user_id,
         confirmed_at = clock_timestamp(),
         updated_at = clock_timestamp()
   WHERE id = p_match_record_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_MULTI_INVOICE_ALLOCATION_REJECTED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum, p_subject_id:=p_match_record_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_match.organization_id, p_business_id:=v_match.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('match_record_id', p_match_record_id, 'status','REJECTED_MATCH'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','match_record_id', p_match_record_id);
END;
$function$;

INSERT INTO public.tool_registry (
  tool_name, version, input_schema, output_schema,
  side_effect, ai_tier, failure_semantics, dedup_key_generator_ref,
  description, retry_max_attempts, retry_backoff_base_ms, retry_backoff_max_ms
) VALUES
('in_workflow.apply_income_match_outcome', '1.0.0',
  '{"organization_id":"uuid","business_id":"uuid","workflow_run_id":"uuid","transaction_id":"uuid","invoice_id":"uuid","income_outcome":"income_outcome_enum","allocated_amount":"numeric","paid_at":"timestamptz"}'::jsonb,
  '{"decision":"text","outcome":"text","match_record_id":"uuid","review_issue_id":"uuid","lifecycle_result":"jsonb"}'::jsonb,
  'WRITES_RUN_STATE'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum,
  'in_workflow.apply_income_match_outcome.dedup_key_v1',
  'Block 13 P10 — applies Block 10 P08 income-match outcome: inserts match_records, raises review_issues, calls invoice_mark_* per outcome.',
  1, 100, 100),
('in_workflow.confirm_multi_invoice_allocation', '1.0.0',
  '{"actor_user_id":"uuid","transaction_id":"uuid","match_record_id":"uuid","allocations":"jsonb"}'::jsonb,
  '{"decision":"text","match_record_id":"uuid","allocations_applied":"jsonb"}'::jsonb,
  'WRITES_RUN_STATE'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum,
  'in_workflow.confirm_multi_invoice_allocation.dedup_key_v1',
  'Block 13 P10 — user-confirms multi-invoice allocation: validates invariants, calls invoice_mark_paid/partially_paid per allocation.',
  1, 100, 100),
('in_workflow.get_match_candidates', '1.0.0',
  '{"business_id":"uuid","period_start":"date","period_end":"date"}'::jsonb,
  '{"decision":"text","transactions":"jsonb","invoice_candidates":"jsonb"}'::jsonb,
  'READ_ONLY'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum,
  'in_workflow.get_match_candidates.dedup_key_v1',
  'Block 13 P10 — returns the IN-side match candidate set: eligible transactions + TAX invoice candidates (no pro-forma; no terminal lifecycles).',
  1, 100, 100)
ON CONFLICT (tool_name) DO NOTHING;

INSERT INTO public.phase_tool_expectations (workflow_type, phase_name, tool_name, permitted_side_effects, required)
VALUES
  ('IN_MONTHLY', 'INCOME_MATCHING', 'in_workflow.apply_income_match_outcome',
   ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'INCOME_MATCHING', 'in_workflow.get_match_candidates',
   ARRAY['READ_ONLY']::public.side_effect_class_enum[], false),
  ('IN_MONTHLY', 'HUMAN_REVIEW_HOLD', 'in_workflow.confirm_multi_invoice_allocation',
   ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], false);
