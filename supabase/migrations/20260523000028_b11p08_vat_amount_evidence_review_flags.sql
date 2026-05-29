-- B11·P08 — Input/Output VAT amounts, evidence flags, accountant-review flag
-- =====================================================================
-- Enriches draft_ledger_entries with:
--   * input_vat_reclaimable_flag/_amount, output_vat_due_flag/_amount
--   * vies_value_basis_eur (when vies_relevant=true; Stage-1 EUR-only)
--   * requires_invoice / requires_receipt / requires_contract
--   * requires_accountant_review + accountant_review_reason
-- Side-effects: review_issues for review-flag cases (POSSIBLE_TAX_VAT_ISSUE)
-- and evidence mismatches (MISSING_DOCUMENTS).
--
-- Two manual-override RPCs gated to OWNER/ADMIN via _ledger_assert_owner_or_admin.
--
-- 6 audit actions (DRAFT_LEDGER_ENTRY subject):
--   LEDGER_VAT_AMOUNTS_COMPUTED       (SYSTEM, always)
--   LEDGER_EVIDENCE_FLAGS_SET         (SYSTEM, always)
--   LEDGER_ACCOUNTANT_REVIEW_FLAGGED  (SYSTEM, when review=true)
--   LEDGER_MISSING_REQUIRED_EVIDENCE_RAISED (SYSTEM, when invoice required but receipt matched)
--   LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_APPLIED  (USER)
--   LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_CLEARED  (USER)
--
-- VAT amount placement rules (avoids double-counting):
--   * DOMESTIC_CYPRUS_VAT OUT-side: amount on PRIMARY's input_vat_reclaimable
--   * DOMESTIC_CYPRUS_VAT IN-side : amount on PRIMARY's output_vat_due
--   * EU_REVERSE_CHARGE / IMPORT_OR_ACQUISITION OUT-side: PRIMARY rows = 0;
--     amounts on the paired VAT_RECLAIM (input) + VAT_OUTPUT (credit) rows
--   * EU_REVERSE_CHARGE IN-side supplier, EXEMPT, NO_VAT, OUTSIDE_SCOPE, UNKNOWN: all zero
--
-- Source preference for VAT amount:
--   1. p_document_extracted_vat_amount (highest fidelity)
--   2. Rate-derived: gross × cyprus_vat_rate_for_category(category)
--   3. Zero for EXEMPT/NO_VAT/OUTSIDE_SCOPE/UNKNOWN
--
-- Evidence flags per spec table; €15 cutoff for OUT_EXPENSE invoice-vs-receipt
-- (sub-doc allows per-business override).
--
-- Deferred:
--   * vies_value_basis_eur for non-EUR bookkeeping
--   * Mixed-rate invoice per-line breakdown (B09 line_items finalisation)
--   * ROUNDING derived entry (sub-doc threshold)
--   * Cross-period adjustment routing (B03 P11)
--   * Receipt/invoice cutoff per-business override (sub-doc)
--   * Severity mapping table for all 7 review triggers (sub-doc)
-- =====================================================================

BEGIN;

-- 1. IMMUTABLE helpers ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.cyprus_vat_rate_for_category(p_category text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN lower(coalesce(p_category,'')) IN ('financial_services','education','healthcare','insurance') THEN 0
    WHEN lower(coalesce(p_category,'')) IN ('subscriptions','it_software') THEN 0.05
    ELSE 0.19
  END;
$$;

CREATE OR REPLACE FUNCTION public.round_half_up(p_value numeric, p_decimals int DEFAULT 2)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT round(p_value, p_decimals);
$$;

CREATE OR REPLACE FUNCTION public.infer_evidence_flags(
  p_transaction_type public.transaction_type_enum,
  p_gross_amount numeric
) RETURNS table(requires_invoice boolean, requires_receipt boolean, requires_contract boolean)
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_transaction_type = 'OUT_EXPENSE'      AND p_gross_amount >= 15 THEN true
    WHEN p_transaction_type = 'IN_INCOME'                                 THEN true
    WHEN p_transaction_type = 'PAYROLL_OR_TEAM_PAYMENT'                  THEN true
    ELSE false END AS requires_invoice,
  CASE
    WHEN p_transaction_type = 'OUT_EXPENSE' AND p_gross_amount < 15 THEN true
    ELSE false END AS requires_receipt,
  CASE
    WHEN p_transaction_type IN ('LOAN_OR_SHAREHOLDER_MOVEMENT','PAYROLL_OR_TEAM_PAYMENT') THEN true
    ELSE false END AS requires_contract;
$$;


-- 2. Permission helper ----------------------------------------------------
CREATE OR REPLACE FUNCTION public._ledger_assert_owner_or_admin(
  p_actor_user_id uuid, p_business_id uuid
) RETURNS public.user_role LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_role public.user_role;
BEGIN
  SELECT role INTO v_role FROM public.business_user_roles
   WHERE user_id = p_actor_user_id AND business_id = p_business_id AND status='ACTIVE'
   LIMIT 1;
  IF v_role IS NULL OR v_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'INSUFFICIENT_PRIVILEGE' USING errcode='42501';
  END IF;
  RETURN v_role;
END;
$$;


-- 3. compute_vat_and_evidence_flags ---------------------------------------
CREATE OR REPLACE FUNCTION public.compute_vat_and_evidence_flags(
  p_organization_id uuid, p_business_id uuid,
  p_draft_ledger_entry_id uuid,
  p_workflow_run_id uuid,
  p_document_extracted_vat_amount numeric DEFAULT NULL,
  p_matched_evidence_kind text DEFAULT NULL,
  p_actor_user_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp AS $$
DECLARE
  v_vat_treatment public.vat_treatment_enum;
  v_entry_kind public.ledger_entry_kind_enum;
  v_parent_txn_id uuid;
  v_debit_acct text; v_credit_acct text;
  v_debit_amount numeric; v_credit_amount numeric;
  v_vies_relevant boolean;
  v_existing_review boolean;
  v_existing_reason text;
  v_direction public.transaction_direction_enum;
  v_txn_type public.transaction_type_enum;
  v_tag text;
  v_gross numeric;
  v_biz_vat_registered boolean;
  v_category text;
  v_rate numeric;
  v_vat_amount numeric := 0;
  v_input_flag boolean := false;
  v_input_amt numeric := 0;
  v_output_flag boolean := false;
  v_output_amt numeric := 0;
  v_vies_value_basis numeric := NULL;
  v_evidence record;
  v_review boolean := false;
  v_reason text;
  v_review_issue_id uuid;
  v_missing_evidence_id uuid;
  v_is_primary boolean;
BEGIN
  SELECT vat_treatment, entry_kind, parent_transaction_id,
         debit_account_code, credit_account_code, debit_amount, credit_amount,
         vies_relevant, requires_accountant_review, accountant_review_reason
    INTO v_vat_treatment, v_entry_kind, v_parent_txn_id,
         v_debit_acct, v_credit_acct, v_debit_amount, v_credit_amount,
         v_vies_relevant, v_existing_review, v_existing_reason
    FROM public.draft_ledger_entries WHERE id = p_draft_ledger_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DRAFT_LEDGER_ENTRY_NOT_FOUND' USING errcode='check_violation';
  END IF;

  IF v_parent_txn_id IS NOT NULL THEN
    SELECT direction, transaction_type, user_tag, abs(amount)
      INTO v_direction, v_txn_type, v_tag, v_gross
      FROM public.transactions WHERE id = v_parent_txn_id;
  ELSE
    v_gross := COALESCE(v_debit_amount, v_credit_amount, 0);
  END IF;

  SELECT vat_registered INTO v_biz_vat_registered FROM public.business_entities WHERE id = p_business_id;
  SELECT category INTO v_category FROM public.chart_of_accounts
    WHERE business_id = p_business_id AND code = COALESCE(v_debit_acct, v_credit_acct);
  v_is_primary := (v_entry_kind = 'PRIMARY');

  IF v_vat_treatment IN ('EXEMPT','NO_VAT','OUTSIDE_SCOPE','UNKNOWN') THEN
    v_vat_amount := 0;
  ELSE
    IF p_document_extracted_vat_amount IS NOT NULL THEN
      v_vat_amount := public.round_half_up(p_document_extracted_vat_amount, 2);
    ELSE
      v_rate := public.cyprus_vat_rate_for_category(v_category);
      v_vat_amount := public.round_half_up(v_gross * v_rate, 2);
    END IF;
  END IF;

  IF v_vat_treatment = 'DOMESTIC_CYPRUS_VAT' THEN
    IF v_direction = 'OUT' AND v_is_primary AND v_biz_vat_registered THEN
      v_input_flag := true; v_input_amt := v_vat_amount;
    ELSIF v_direction = 'IN' AND v_is_primary AND v_biz_vat_registered THEN
      v_output_flag := true; v_output_amt := v_vat_amount;
    END IF;
  ELSIF v_vat_treatment IN ('EU_REVERSE_CHARGE','IMPORT_OR_ACQUISITION') AND v_direction = 'OUT' THEN
    IF v_entry_kind = 'VAT_RECLAIM' THEN
      v_input_flag := true; v_input_amt := v_vat_amount;
    ELSIF v_entry_kind = 'VAT_OUTPUT' THEN
      v_output_flag := true; v_output_amt := v_vat_amount;
    END IF;
  END IF;

  IF v_vies_relevant THEN
    v_vies_value_basis := v_gross;
  END IF;

  SELECT * INTO v_evidence FROM public.infer_evidence_flags(v_txn_type, v_gross);

  v_review := v_existing_review;
  v_reason := v_existing_reason;
  IF v_vat_treatment = 'UNKNOWN' THEN
    v_review := true;
    v_reason := COALESCE(v_reason || '; ', '') || 'VAT treatment could not be determined.';
  END IF;

  UPDATE public.draft_ledger_entries
    SET input_vat_reclaimable_flag = v_input_flag,
        input_vat_reclaimable_amount = v_input_amt,
        output_vat_due_flag = v_output_flag,
        output_vat_due_amount = v_output_amt,
        vies_value_basis_eur = v_vies_value_basis,
        requires_invoice = v_evidence.requires_invoice,
        requires_receipt = v_evidence.requires_receipt,
        requires_contract = v_evidence.requires_contract,
        requires_accountant_review = v_review,
        accountant_review_reason = v_reason,
        last_recomputed_at = clock_timestamp()
   WHERE id = p_draft_ledger_entry_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_VAT_AMOUNTS_COMPUTED',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=p_draft_ledger_entry_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='vat_amounts_evidence', p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('treatment',v_vat_treatment,'input_flag',v_input_flag,'input_amount',v_input_amt,
                                       'output_flag',v_output_flag,'output_amount',v_output_amt,
                                       'vies_value_basis_eur',v_vies_value_basis,'entry_kind',v_entry_kind),
    p_reason:=NULL, p_request_context:=p_context);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_EVIDENCE_FLAGS_SET',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=p_draft_ledger_entry_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='vat_amounts_evidence', p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('requires_invoice',v_evidence.requires_invoice,
                                       'requires_receipt',v_evidence.requires_receipt,
                                       'requires_contract',v_evidence.requires_contract,
                                       'gross_amount',v_gross,'transaction_type',v_txn_type),
    p_reason:=NULL, p_request_context:=p_context);

  IF v_review THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id, draft_ledger_entry_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, v_parent_txn_id, p_draft_ledger_entry_id,
      'ledger.requires_accountant_review',
      'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
      CASE WHEN v_vat_treatment = 'UNKNOWN' THEN 'HIGH'::public.review_issue_severity_enum
           ELSE 'MEDIUM'::public.review_issue_severity_enum END,
      'Ledger entry needs accountant review',
      'The VAT treatment or evidence requirements for this entry need accountant attention. Review the reason and confirm or correct.',
      'Review and confirm or correct the entry',
      jsonb_build_object('reason', v_reason, 'treatment', v_vat_treatment)
    ) RETURNING id INTO v_review_issue_id;

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_ACCOUNTANT_REVIEW_FLAGGED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=p_draft_ledger_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='vat_amounts_evidence', p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('reason', v_reason, 'review_issue_id', v_review_issue_id),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  IF v_evidence.requires_invoice
     AND p_matched_evidence_kind IS NOT NULL
     AND upper(p_matched_evidence_kind) <> 'INVOICE' THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id, draft_ledger_entry_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, v_parent_txn_id, p_draft_ledger_entry_id,
      'ledger.missing_required_evidence',
      'MISSING_DOCUMENTS'::public.review_issue_group_enum,
      'HIGH'::public.review_issue_severity_enum,
      'Required invoice missing',
      'This entry requires an invoice but the matched evidence is a different document type. Upload or attach the correct invoice.',
      'Attach the required invoice',
      jsonb_build_object('required','INVOICE','matched',p_matched_evidence_kind)
    ) RETURNING id INTO v_missing_evidence_id;

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_MISSING_REQUIRED_EVIDENCE_RAISED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=p_draft_ledger_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='vat_amounts_evidence', p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('required','INVOICE','matched',p_matched_evidence_kind,
                                         'review_issue_id', v_missing_evidence_id),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'input_vat_reclaimable_flag', v_input_flag,
    'input_vat_reclaimable_amount', v_input_amt,
    'output_vat_due_flag', v_output_flag,
    'output_vat_due_amount', v_output_amt,
    'vies_value_basis_eur', v_vies_value_basis,
    'requires_invoice', v_evidence.requires_invoice,
    'requires_receipt', v_evidence.requires_receipt,
    'requires_contract', v_evidence.requires_contract,
    'requires_accountant_review', v_review,
    'accountant_review_reason', v_reason,
    'review_issue_id', v_review_issue_id,
    'missing_evidence_review_issue_id', v_missing_evidence_id);
END;
$$;


-- 4. Manual override apply / clear ----------------------------------------
CREATE OR REPLACE FUNCTION public.apply_vat_treatment_manual_override(
  p_organization_id uuid, p_business_id uuid,
  p_draft_ledger_entry_id uuid,
  p_new_treatment public.vat_treatment_enum,
  p_reason text,
  p_actor_user_id uuid,
  p_workflow_run_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp AS $$
DECLARE v_role public.user_role; v_old_treatment public.vat_treatment_enum;
BEGIN
  v_role := public._ledger_assert_owner_or_admin(p_actor_user_id, p_business_id);
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING errcode='check_violation';
  END IF;
  SELECT vat_treatment INTO v_old_treatment FROM public.draft_ledger_entries WHERE id = p_draft_ledger_entry_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_LEDGER_ENTRY_NOT_FOUND' USING errcode='check_violation'; END IF;
  UPDATE public.draft_ledger_entries
    SET vat_treatment = p_new_treatment,
        manual_override_by = p_actor_user_id,
        manual_override_reason = p_reason,
        manual_override_at = clock_timestamp(),
        last_recomputed_at = clock_timestamp()
   WHERE id = p_draft_ledger_entry_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_APPLIED',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
    p_subject_id:=p_draft_ledger_entry_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL, p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object('treatment', v_old_treatment),
    p_after_state:=jsonb_build_object('treatment', p_new_treatment, 'reason', p_reason, 'workflow_run_id', p_workflow_run_id),
    p_reason:=p_reason, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','OVERRIDDEN','old_treatment',v_old_treatment,'new_treatment',p_new_treatment);
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_vat_treatment_manual_override(
  p_organization_id uuid, p_business_id uuid,
  p_draft_ledger_entry_id uuid,
  p_actor_user_id uuid,
  p_workflow_run_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp AS $$
DECLARE v_role public.user_role; v_was_overridden boolean;
BEGIN
  v_role := public._ledger_assert_owner_or_admin(p_actor_user_id, p_business_id);
  SELECT (manual_override_by IS NOT NULL) INTO v_was_overridden FROM public.draft_ledger_entries WHERE id = p_draft_ledger_entry_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_LEDGER_ENTRY_NOT_FOUND' USING errcode='check_violation'; END IF;
  IF NOT v_was_overridden THEN
    RETURN jsonb_build_object('decision','NOOP','reason','not_overridden');
  END IF;
  UPDATE public.draft_ledger_entries
    SET manual_override_by = NULL, manual_override_reason = NULL, manual_override_at = NULL,
        last_recomputed_at = clock_timestamp()
   WHERE id = p_draft_ledger_entry_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_CLEARED',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
    p_subject_id:=p_draft_ledger_entry_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL, p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('cleared_by', p_actor_user_id, 'workflow_run_id', p_workflow_run_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','CLEARED');
END;
$$;


-- 5. Privileges -----------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public._ledger_assert_owner_or_admin(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.compute_vat_and_evidence_flags(uuid, uuid, uuid, uuid, numeric, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_vat_treatment_manual_override(uuid, uuid, uuid, public.vat_treatment_enum, text, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.clear_vat_treatment_manual_override(uuid, uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.compute_vat_and_evidence_flags(uuid, uuid, uuid, uuid, numeric, text, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_vat_treatment_manual_override(uuid, uuid, uuid, public.vat_treatment_enum, text, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.clear_vat_treatment_manual_override(uuid, uuid, uuid, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cyprus_vat_rate_for_category(text) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.round_half_up(numeric, int) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.infer_evidence_flags(public.transaction_type_enum, numeric) TO authenticated, service_role, anon;

COMMIT;
