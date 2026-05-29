-- B10·P08 — Income Matching Variant
-- =====================================================================
-- IN-side matching scaffold. Same scoring engine (P02), different candidate
-- set (internal Invoice records, owned by Block 13). Block 13's Invoice
-- table + lifecycle functions (invoice.markPaid / markPartiallyPaid /
-- markOverpaid) DO NOT EXIST yet — this phase delivers:
--   * income_match_outcome_enum (7 outcomes from the spec)
--   * transactions.income_match_outcome + matched_invoice_id (uuid, NO FK
--     until Block 13 ships the invoices table; orchestrator-validated)
--   * business_ai_config.income_partial_payment_min_percent (default 5%)
--   * compute_income_match_outcome IMMUTABLE helper (per-pair amount logic)
--   * apply_income_match chokepoint RPC (records outcome + emits audit +
--     raises review_issue per the spec's auto-confirm rules)
--   * record_invoice_lifecycle_transitioned / *_failed RPCs (cross-block
--     contract — orchestrator calls these after invoking B13's lifecycle)
-- When B13 ships, a follow-up migration adds the FK on matched_invoice_id
-- and wires the actual invoice.markPaid calls.
-- =====================================================================

BEGIN;

-- 1. income_match_outcome_enum ----------------------------------------------

CREATE TYPE public.income_match_outcome_enum AS ENUM (
  'FULL_MATCH',
  'PARTIAL_PAYMENT',
  'OVERPAYMENT',
  'MULTIPLE_INVOICES_ONE_PAYMENT',
  'ONE_INVOICE_MULTIPLE_PAYMENTS',
  'NO_MATCH',
  'POSSIBLE_REFUND_OR_TRANSFER'
);

COMMENT ON TYPE public.income_match_outcome_enum IS
  'IN-side matching outcomes per Block 10 Phase 08. NO_MATCH means no invoice candidate above threshold; the other six map to lifecycle calls into Block 13''s Invoice Generator.';


-- 2. transactions columns ---------------------------------------------------

ALTER TABLE public.transactions
  ADD COLUMN income_match_outcome public.income_match_outcome_enum,
  ADD COLUMN matched_invoice_id   uuid;

COMMENT ON COLUMN public.transactions.income_match_outcome IS
  'IN-side matching outcome. NULL for OUT-side transactions and for IN-side transactions not yet processed.';

COMMENT ON COLUMN public.transactions.matched_invoice_id IS
  'Invoice the income matcher associated with this transaction. NO FK — Block 13 owns the invoices table and will add the FK in a follow-up migration. Orchestrator-validated until then.';


-- 3. business_ai_config column ----------------------------------------------

ALTER TABLE public.business_ai_config
  ADD COLUMN income_partial_payment_min_percent numeric NOT NULL DEFAULT 0.05
    CHECK (income_partial_payment_min_percent > 0 AND income_partial_payment_min_percent <= 1);

COMMENT ON COLUMN public.business_ai_config.income_partial_payment_min_percent IS
  'Minimum percentage of invoice total below which a partial payment is treated as NO_MATCH noise. Default 0.05 (5%) per spec.';


-- 4. compute_income_match_outcome (IMMUTABLE) -------------------------------

CREATE OR REPLACE FUNCTION public.compute_income_match_outcome(
  p_txn_amount      numeric,
  p_invoice_total   numeric,
  p_tolerance       numeric DEFAULT 0.01,
  p_min_percent     numeric DEFAULT 0.05
)
RETURNS text LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_invoice_total IS NULL OR p_invoice_total <= 0 THEN 'NO_MATCH'
    WHEN abs(abs(p_txn_amount) - p_invoice_total) <= p_tolerance THEN 'FULL_MATCH'
    WHEN abs(p_txn_amount) > p_invoice_total + p_tolerance THEN 'OVERPAYMENT'
    WHEN abs(p_txn_amount) >= p_invoice_total * p_min_percent THEN 'PARTIAL_PAYMENT'
    ELSE 'NO_MATCH'
  END;
$$;

COMMENT ON FUNCTION public.compute_income_match_outcome(numeric, numeric, numeric, numeric) IS
  'Per-pair amount comparison: FULL_MATCH / OVERPAYMENT / PARTIAL_PAYMENT / NO_MATCH. Multi-invoice / multi-payment / refund detection is orchestrator concern (more context needed than amount alone).';


-- 5. apply_income_match (chokepoint) ----------------------------------------

CREATE OR REPLACE FUNCTION public.apply_income_match(
  p_transaction_id      uuid,
  p_invoice_id          uuid,
  p_outcome             public.income_match_outcome_enum,
  p_workflow_run_id     uuid,
  p_has_reference_match boolean DEFAULT false,
  p_actor_user_id       uuid    DEFAULT NULL,
  p_context             jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_direction       public.transaction_direction_enum;
  v_new_match_status public.transaction_match_status_enum;
  v_review_issue_id uuid;
  v_review_group    public.review_issue_group_enum;
  v_review_severity public.review_issue_severity_enum;
  v_review_title    text;
  v_review_desc     text;
  v_review_action   text;
  v_audit_action    text;
BEGIN
  SELECT organization_id, business_id, direction
    INTO v_organization_id, v_business_id, v_direction
  FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','TRANSACTION_NOT_FOUND','transaction_id',p_transaction_id);
  END IF;

  -- Decide match_status + review_issue shape per spec
  CASE p_outcome
    WHEN 'FULL_MATCH' THEN
      v_audit_action := 'INCOME_MATCHING_OUTCOME_FULL_MATCH';
      IF p_has_reference_match THEN
        v_new_match_status := 'MATCHED_AUTO_CONFIRMED';
      ELSE
        v_new_match_status := 'MATCHED_PROPOSED';
        v_review_group   := 'NEEDS_CONFIRMATION';
        v_review_severity:= 'MEDIUM';
        v_review_title   := 'Confirm income match';
        v_review_desc    := 'The amount matches an outstanding invoice but the payment reference does not. Please confirm this is the right invoice.';
        v_review_action  := 'Review and confirm or reject the matched invoice';
      END IF;

    WHEN 'PARTIAL_PAYMENT' THEN
      v_audit_action := 'INCOME_MATCHING_OUTCOME_PARTIAL_PAYMENT';
      v_new_match_status := 'MATCHED_PROPOSED';
      v_review_group   := 'NEEDS_CONFIRMATION';
      v_review_severity:= 'MEDIUM';
      v_review_title   := 'Partial payment on invoice';
      v_review_desc    := 'This incoming payment is less than the invoice total. Confirm to mark the invoice as partially paid.';
      v_review_action  := 'Confirm partial payment allocation';

    WHEN 'OVERPAYMENT' THEN
      v_audit_action := 'INCOME_MATCHING_OUTCOME_OVERPAYMENT';
      v_new_match_status := 'MATCHED_PROPOSED';
      v_review_group   := 'NEEDS_CONFIRMATION';
      v_review_severity:= 'MEDIUM';
      v_review_title   := 'Overpayment received';
      v_review_desc    := 'This payment exceeds the invoice total. Confirm to mark the invoice as overpaid, and choose whether to issue a credit note for the surplus.';
      v_review_action  := 'Confirm overpayment and decide on credit note';

    WHEN 'MULTIPLE_INVOICES_ONE_PAYMENT' THEN
      v_audit_action := 'INCOME_MATCHING_OUTCOME_MULTIPLE_INVOICES_ONE_PAYMENT';
      v_new_match_status := 'MATCHED_PROPOSED';
      v_review_group   := 'NEEDS_CONFIRMATION';
      v_review_severity:= 'MEDIUM';
      v_review_title   := 'One payment covers multiple invoices';
      v_review_desc    := 'Several outstanding invoices sum to this payment amount. Confirm the allocation across invoices (Stage 1 always requires user confirmation).';
      v_review_action  := 'Confirm multi-invoice allocation';

    WHEN 'ONE_INVOICE_MULTIPLE_PAYMENTS' THEN
      v_audit_action := 'INCOME_MATCHING_OUTCOME_ONE_INVOICE_MULTIPLE_PAYMENTS';
      v_new_match_status := 'MATCHED_AUTO_CONFIRMED';

    WHEN 'NO_MATCH' THEN
      v_audit_action := 'INCOME_MATCHING_OUTCOME_NO_MATCH';
      v_new_match_status := 'UNMATCHED';

    WHEN 'POSSIBLE_REFUND_OR_TRANSFER' THEN
      v_audit_action := 'INCOME_MATCHING_OUTCOME_POSSIBLE_REFUND_OR_TRANSFER';
      v_new_match_status := 'MATCHED_PROPOSED';
      v_review_group   := 'POSSIBLE_WRONG_MATCH';
      v_review_severity:= 'MEDIUM';
      v_review_title   := 'Possible refund or internal transfer';
      v_review_desc    := 'This incoming amount looks like a refund of a prior outgoing payment, or an internal transfer between own accounts. Consider reclassifying the transaction type.';
      v_review_action  := 'Confirm invoice match, or reclassify as REFUND_IN / INTERNAL_TRANSFER';
  END CASE;

  UPDATE public.transactions
    SET income_match_outcome = p_outcome,
        matched_invoice_id   = CASE WHEN p_outcome = 'NO_MATCH' THEN NULL ELSE p_invoice_id END,
        match_status         = v_new_match_status,
        updated_at           = clock_timestamp()
  WHERE id = p_transaction_id;

  IF v_review_group IS NOT NULL THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      v_organization_id, v_business_id, p_workflow_run_id, p_transaction_id,
      'income_matching.' || lower(p_outcome::text),
      v_review_group, v_review_severity,
      v_review_title, v_review_desc, v_review_action,
      jsonb_build_object(
        'outcome', p_outcome,
        'invoice_id', p_invoice_id,
        'has_reference_match', p_has_reference_match
      )
    ) RETURNING id INTO v_review_issue_id;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:=v_audit_action,
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='income_matching_engine',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'outcome', p_outcome,
      'invoice_id', p_invoice_id,
      'has_reference_match', p_has_reference_match,
      'new_match_status', v_new_match_status,
      'review_issue_id', v_review_issue_id,
      'workflow_run_id', p_workflow_run_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision', CASE WHEN v_new_match_status = 'MATCHED_AUTO_CONFIRMED' THEN 'AUTO_CONFIRMED'
                     WHEN v_new_match_status = 'UNMATCHED' THEN 'NO_MATCH'
                     ELSE 'NEEDS_REVIEW' END,
    'transaction_id', p_transaction_id,
    'invoice_id', CASE WHEN p_outcome = 'NO_MATCH' THEN NULL ELSE p_invoice_id END,
    'outcome', p_outcome,
    'match_status', v_new_match_status,
    'review_issue_id', v_review_issue_id
  );
END;
$$;


-- 6. record_invoice_lifecycle_transitioned ---------------------------------

CREATE OR REPLACE FUNCTION public.record_invoice_lifecycle_transitioned(
  p_organization_id uuid,
  p_business_id     uuid,
  p_invoice_id      uuid,
  p_new_status      text,
  p_transaction_id  uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='INVOICE_LIFECYCLE_TRANSITIONED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='income_matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'invoice_id', p_invoice_id,
      'new_status', p_new_status,
      'transaction_id', p_transaction_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED',
    'invoice_id', p_invoice_id,
    'new_status', p_new_status,
    'transaction_id', p_transaction_id
  );
END;
$$;


-- 7. record_invoice_lifecycle_transition_failed ----------------------------

CREATE OR REPLACE FUNCTION public.record_invoice_lifecycle_transition_failed(
  p_organization_id uuid,
  p_business_id     uuid,
  p_invoice_id      uuid,
  p_transaction_id  uuid,
  p_error_payload   jsonb,
  p_workflow_run_id uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_review_issue_id uuid;
BEGIN
  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id, transaction_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action,
    card_payload_json
  ) VALUES (
    p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id,
    'income_matching.invoice_lifecycle_failed',
    'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
    'HIGH'::public.review_issue_severity_enum,
    'Invoice could not be updated after match',
    'The matching engine identified the right invoice but the lifecycle update (mark as paid/partially paid/overpaid) failed. Please review the match and the invoice state.',
    'Reconcile the match and the invoice state manually',
    jsonb_build_object(
      'invoice_id', p_invoice_id,
      'transaction_id', p_transaction_id,
      'error', p_error_payload
    )
  ) RETURNING id INTO v_review_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='INVOICE_LIFECYCLE_TRANSITION_FAILED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='income_matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'invoice_id', p_invoice_id,
      'transaction_id', p_transaction_id,
      'error', p_error_payload,
      'review_issue_id', v_review_issue_id,
      'workflow_run_id', p_workflow_run_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED_FAILURE',
    'invoice_id', p_invoice_id,
    'transaction_id', p_transaction_id,
    'review_issue_id', v_review_issue_id
  );
END;
$$;


-- 8. Privileges -------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.apply_income_match(uuid, uuid, public.income_match_outcome_enum, uuid, boolean, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_invoice_lifecycle_transitioned(uuid, uuid, uuid, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_invoice_lifecycle_transition_failed(uuid, uuid, uuid, uuid, jsonb, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.apply_income_match(uuid, uuid, public.income_match_outcome_enum, uuid, boolean, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_invoice_lifecycle_transitioned(uuid, uuid, uuid, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_invoice_lifecycle_transition_failed(uuid, uuid, uuid, uuid, jsonb, uuid, jsonb) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.compute_income_match_outcome(numeric, numeric, numeric, numeric) TO authenticated, service_role, anon;

COMMIT;
