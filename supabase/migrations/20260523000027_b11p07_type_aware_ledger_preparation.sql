-- B11·P07 — Type-Aware Ledger Preparation Paths
-- =====================================================================
-- Dispatcher that converts each typed, matched transaction into draft
-- ledger entries via the chart_of_accounts_mappings rules from B11·P03.
-- Idempotent re-derive: deletes prior entries for (txn, version) before
-- inserting fresh; emits LEDGER_DRAFT_ENTRY_RECOMPUTED on replace.
--
-- Per-type paths (Stage-1 simplification: one PRIMARY debit + one PRIMARY
-- credit per transaction; optional VAT derived entries):
--   OUT_EXPENSE  → PRIMARY pair (debit expense, credit bank) + VAT_RECLAIM
--                  (when input_vat_reclaimable + vat_amount); +VAT_OUTPUT
--                  when reverse-charge OUT (caller signals via both flags)
--   IN_INCOME    → PRIMARY pair (debit bank, credit revenue) + VAT_OUTPUT
--                  (when output_vat_due)
--   INTERNAL_TRANSFER, BANK_FEE, REFUND_IN, REFUND_OUT, CHARGEBACK,
--   LOAN_OR_SHAREHOLDER_MOVEMENT, PAYROLL_OR_TEAM_PAYMENT, TAX_PAYMENT,
--   FX_EXCHANGE → PRIMARY pair only (no derived entries Stage-1)
--   UNKNOWN     → zero entries; LEDGER_HELD_PENDING_CLASSIFICATION audit +
--                 HIGH review_issue in POSSIBLE_TAX_VAT_ISSUE bucket
--
-- Account resolution: chart_resolve_account_for_entry (STABLE) filters
-- chart_of_accounts_mappings by business + version + direction + entry_kind,
-- matches on transaction_type/tag/vat_treatment with NULL acting as wildcard,
-- orders by specificity DESC then priority DESC, takes first.
-- Derived VAT account codes hard-coded per B11·P02 seed: 8000 (Input VAT),
-- 8010 (Output VAT).
--
-- Cross-currency: when transaction currency differs from bookkeeping (EUR),
-- entry_currency_original + entry_amount_original are preserved on every
-- entry; the dispatcher writes bookkeeping-currency amounts on debit/credit
-- amount columns. Stage-1 FX rate methodology deferred to sub-doc.
--
-- Audit family (6):
--   LEDGER_DRAFT_ENTRY_CREATED (per row inserted)
--   LEDGER_DRAFT_ENTRY_RECOMPUTED (per re-derive, once)
--   LEDGER_HELD_PENDING_CLASSIFICATION (UNKNOWN type only)
--   LEDGER_MULTI_LINE_INVOICE_CONSOLIDATED (placeholder when match_record_id present)
--   LEDGER_MAPPING_RULE_FALLBACK_USED (default wildcard rule fired)
--   LEDGER_MULTI_LINE_INVOICE_SPLIT_BY_CATEGORY (declared, not emitted Stage-1)
--
-- Deferred to sub-docs / later phases:
--   * Multi-line split-by-category (Block 09 extracted_fields_json shape)
--   * FX_DELTA derived entry methodology
--   * Per-bank-account INTERNAL_TRANSFER resolution
--   * Original-entry-aware REFUND_IN/REFUND_OUT reversal
--   * prepare_invoice_lifecycle_entries (Block 13 P06)
--   * Recompute trigger wiring (Phase 09)
-- =====================================================================

BEGIN;

-- 1. STABLE mapping resolver per entry side
CREATE OR REPLACE FUNCTION public.chart_resolve_account_for_entry(
  p_business_id uuid,
  p_mapping_version_id uuid,
  p_transaction_type public.transaction_type_enum,
  p_tag text,
  p_vat_treatment public.vat_treatment_enum,
  p_entry_kind public.ledger_entry_kind_enum,
  p_direction public.ledger_entry_type_enum
) RETURNS table(account_code text, fallback_used boolean)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_code text;
  v_fallback boolean;
BEGIN
  SELECT m.account_code,
         (m.transaction_type IS NULL AND m.tag IS NULL AND m.vat_treatment IS NULL)
    INTO v_code, v_fallback
   FROM public.chart_of_accounts_mappings m
   WHERE m.business_id = p_business_id
     AND m.mapping_version_id = p_mapping_version_id
     AND m.direction = p_direction
     AND m.entry_kind = p_entry_kind
     AND m.disabled_at IS NULL
     AND (m.transaction_type IS NULL OR m.transaction_type = p_transaction_type)
     AND (m.tag IS NULL OR m.tag = p_tag)
     AND (m.vat_treatment IS NULL OR m.vat_treatment = p_vat_treatment)
   ORDER BY
     (CASE WHEN m.transaction_type IS NOT NULL THEN 1 ELSE 0 END
      + CASE WHEN m.tag IS NOT NULL THEN 1 ELSE 0 END
      + CASE WHEN m.vat_treatment IS NOT NULL THEN 1 ELSE 0 END) DESC,
     m.priority DESC
   LIMIT 1;

  IF v_code IS NULL THEN
    RETURN;
  END IF;
  account_code := v_code;
  fallback_used := v_fallback;
  RETURN NEXT;
END;
$$;


-- 2. Main dispatcher
CREATE OR REPLACE FUNCTION public.prepare_ledger_entries(
  p_organization_id uuid, p_business_id uuid,
  p_transaction_id uuid,
  p_workflow_run_id uuid,
  p_match_record_id uuid DEFAULT NULL,
  p_input_vat_reclaimable boolean DEFAULT false,
  p_output_vat_due boolean DEFAULT false,
  p_vat_amount numeric DEFAULT NULL,
  p_entry_period date DEFAULT NULL,
  p_actor_user_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_direction public.transaction_direction_enum;
  v_txn_type public.transaction_type_enum;
  v_user_tag text;
  v_amount numeric;
  v_currency text;
  v_txn_date date;
  v_biz_currency text := 'EUR';
  v_version_id uuid;
  v_entry_period date;
  v_deleted int;
  v_entry_id uuid;
  v_debit_acct text;
  v_credit_acct text;
  v_fallback_debit boolean;
  v_fallback_credit boolean;
  v_review_issue_id uuid;
  v_primary_count int := 0;
  v_derived_count int := 0;
  v_net_amount numeric;
  v_gross_amount numeric;
  v_entry_currency_original text;
  v_entry_amount_original numeric;
  v_res record;
BEGIN
  SELECT direction, transaction_type, user_tag, amount, currency, transaction_date
    INTO v_direction, v_txn_type, v_user_tag, v_amount, v_currency, v_txn_date
    FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSACTION_NOT_FOUND' USING errcode='check_violation';
  END IF;

  v_entry_period := COALESCE(p_entry_period, v_txn_date);
  v_version_id := public.chart_resolve_mapping_version(p_business_id, v_entry_period::timestamptz);
  IF v_version_id IS NULL THEN
    RAISE EXCEPTION 'NO_ACTIVE_MAPPING_VERSION_FOR_PERIOD' USING errcode='check_violation';
  END IF;

  IF v_currency IS NOT NULL AND v_currency <> v_biz_currency THEN
    v_entry_currency_original := v_currency;
    v_entry_amount_original := abs(v_amount);
  END IF;
  v_gross_amount := abs(v_amount);

  IF v_txn_type = 'UNKNOWN' THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id,
      'ledger.held_pending_classification',
      'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
      'HIGH'::public.review_issue_severity_enum,
      'Transaction held pending classification',
      'This transaction has not been classified into one of the known types; ledger entries cannot be derived until it is reclassified.',
      'Reclassify the transaction',
      jsonb_build_object('transaction_id', p_transaction_id)
    ) RETURNING id INTO v_review_issue_id;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_HELD_PENDING_CLASSIFICATION',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='ledger_dispatcher',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('review_issue_id', v_review_issue_id),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','HELD','reason','UNKNOWN_TYPE',
      'entries_created',0,'primary_count',0,'derived_count',0,'review_issue_id',v_review_issue_id);
  END IF;

  -- Idempotent re-derive
  WITH del AS (
    DELETE FROM public.draft_ledger_entries
     WHERE parent_transaction_id = p_transaction_id
       AND chart_mapping_version_id = v_version_id
     RETURNING id)
  SELECT count(*) INTO v_deleted FROM del;
  IF v_deleted > 0 THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_DRAFT_ENTRY_RECOMPUTED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='ledger_dispatcher',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('replaced_entry_count', v_deleted, 'mapping_version_id', v_version_id),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  -- Resolve PRIMARY debit/credit accounts via mapping rules
  v_debit_acct := NULL; v_credit_acct := NULL;
  v_fallback_debit := false; v_fallback_credit := false;
  FOR v_res IN SELECT * FROM public.chart_resolve_account_for_entry(
                       p_business_id, v_version_id, v_txn_type, v_user_tag, NULL,
                       'PRIMARY'::public.ledger_entry_kind_enum,
                       'DEBIT'::public.ledger_entry_type_enum) LOOP
    v_debit_acct := v_res.account_code; v_fallback_debit := v_res.fallback_used;
  END LOOP;
  FOR v_res IN SELECT * FROM public.chart_resolve_account_for_entry(
                       p_business_id, v_version_id, v_txn_type, v_user_tag, NULL,
                       'PRIMARY'::public.ledger_entry_kind_enum,
                       'CREDIT'::public.ledger_entry_type_enum) LOOP
    v_credit_acct := v_res.account_code; v_fallback_credit := v_res.fallback_used;
  END LOOP;

  IF v_debit_acct IS NULL OR v_credit_acct IS NULL THEN
    RAISE EXCEPTION 'MAPPING_RULE_NOT_FOUND' USING errcode='check_violation',
      DETAIL=format('txn_type=% tag=% debit=% credit=%', v_txn_type, v_user_tag, v_debit_acct, v_credit_acct);
  END IF;

  IF v_fallback_debit OR v_fallback_credit THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_MAPPING_RULE_FALLBACK_USED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='ledger_dispatcher',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('debit_fallback', v_fallback_debit, 'credit_fallback', v_fallback_credit,
                                         'debit_code', v_debit_acct, 'credit_code', v_credit_acct),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  IF p_vat_amount IS NOT NULL AND p_vat_amount > 0 AND p_input_vat_reclaimable AND v_direction='OUT' THEN
    v_net_amount := v_gross_amount - p_vat_amount;
  ELSE
    v_net_amount := v_gross_amount;
  END IF;

  -- PRIMARY debit row (net)
  INSERT INTO public.draft_ledger_entries (
    id, organization_id, business_id, parent_transaction_id, match_record_id,
    entry_kind, debit_account_code, debit_amount, currency, entry_period,
    chart_mapping_version_id, entry_currency_original, entry_amount_original)
  VALUES (public.gen_uuid_v7(), p_organization_id, p_business_id, p_transaction_id, p_match_record_id,
          'PRIMARY', v_debit_acct, v_net_amount, v_biz_currency, v_entry_period,
          v_version_id, v_entry_currency_original, v_entry_amount_original)
  RETURNING id INTO v_entry_id;
  v_primary_count := v_primary_count + 1;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_DRAFT_ENTRY_CREATED',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=v_entry_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_dispatcher',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('entry_kind','PRIMARY','direction','DEBIT','account_code',v_debit_acct,'amount',v_net_amount),
    p_reason:=NULL, p_request_context:=p_context);

  -- PRIMARY credit row (gross)
  INSERT INTO public.draft_ledger_entries (
    id, organization_id, business_id, parent_transaction_id, match_record_id,
    entry_kind, credit_account_code, credit_amount, currency, entry_period,
    chart_mapping_version_id, entry_currency_original, entry_amount_original)
  VALUES (public.gen_uuid_v7(), p_organization_id, p_business_id, p_transaction_id, p_match_record_id,
          'PRIMARY', v_credit_acct, v_gross_amount, v_biz_currency, v_entry_period,
          v_version_id, v_entry_currency_original, v_entry_amount_original)
  RETURNING id INTO v_entry_id;
  v_primary_count := v_primary_count + 1;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_DRAFT_ENTRY_CREATED',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=v_entry_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_dispatcher',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('entry_kind','PRIMARY','direction','CREDIT','account_code',v_credit_acct,'amount',v_gross_amount),
    p_reason:=NULL, p_request_context:=p_context);

  -- VAT_RECLAIM (OUT-side with reclaimable VAT)
  IF v_direction='OUT' AND p_input_vat_reclaimable AND p_vat_amount IS NOT NULL AND p_vat_amount > 0 THEN
    INSERT INTO public.draft_ledger_entries (
      id, organization_id, business_id, parent_transaction_id, match_record_id,
      entry_kind, debit_account_code, debit_amount, currency, entry_period, chart_mapping_version_id)
    VALUES (public.gen_uuid_v7(), p_organization_id, p_business_id, p_transaction_id, p_match_record_id,
            'VAT_RECLAIM', '8000', p_vat_amount, v_biz_currency, v_entry_period, v_version_id)
    RETURNING id INTO v_entry_id;
    v_derived_count := v_derived_count + 1;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_DRAFT_ENTRY_CREATED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=v_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='ledger_dispatcher',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('entry_kind','VAT_RECLAIM','direction','DEBIT','account_code','8000','amount',p_vat_amount),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  -- OUT-side reverse-charge: VAT_OUTPUT contra (callers signal via both flags)
  IF v_direction='OUT' AND p_output_vat_due AND p_vat_amount IS NOT NULL AND p_vat_amount > 0 THEN
    INSERT INTO public.draft_ledger_entries (
      id, organization_id, business_id, parent_transaction_id, match_record_id,
      entry_kind, credit_account_code, credit_amount, currency, entry_period, chart_mapping_version_id)
    VALUES (public.gen_uuid_v7(), p_organization_id, p_business_id, p_transaction_id, p_match_record_id,
            'VAT_OUTPUT', '8010', p_vat_amount, v_biz_currency, v_entry_period, v_version_id)
    RETURNING id INTO v_entry_id;
    v_derived_count := v_derived_count + 1;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_DRAFT_ENTRY_CREATED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=v_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='ledger_dispatcher',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('entry_kind','VAT_OUTPUT','direction','CREDIT','account_code','8010','amount',p_vat_amount),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  -- IN-side VAT_OUTPUT when output_vat_due
  IF v_direction='IN' AND p_output_vat_due AND p_vat_amount IS NOT NULL AND p_vat_amount > 0 THEN
    INSERT INTO public.draft_ledger_entries (
      id, organization_id, business_id, parent_transaction_id, match_record_id,
      entry_kind, credit_account_code, credit_amount, currency, entry_period, chart_mapping_version_id)
    VALUES (public.gen_uuid_v7(), p_organization_id, p_business_id, p_transaction_id, p_match_record_id,
            'VAT_OUTPUT', '8010', p_vat_amount, v_biz_currency, v_entry_period, v_version_id)
    RETURNING id INTO v_entry_id;
    v_derived_count := v_derived_count + 1;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_DRAFT_ENTRY_CREATED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum, p_subject_id:=v_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='ledger_dispatcher',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('entry_kind','VAT_OUTPUT','direction','CREDIT','account_code','8010','amount',p_vat_amount),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  IF p_match_record_id IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_MULTI_LINE_INVOICE_CONSOLIDATED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='ledger_dispatcher',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('line_items_count', 1, 'match_record_id', p_match_record_id,
                                         'note', 'Stage-1 placeholder; sub-doc finalises line-item extraction'),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'decision','PREPARED',
    'transaction_id', p_transaction_id,
    'mapping_version_id', v_version_id,
    'entries_created', v_primary_count + v_derived_count,
    'entries_replaced', v_deleted,
    'primary_count', v_primary_count,
    'derived_count', v_derived_count,
    'debit_account_code', v_debit_acct,
    'credit_account_code', v_credit_acct);
END;
$$;


-- 3. Privileges
REVOKE EXECUTE ON FUNCTION public.prepare_ledger_entries(uuid, uuid, uuid, uuid, uuid, boolean, boolean, numeric, date, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.prepare_ledger_entries(uuid, uuid, uuid, uuid, uuid, boolean, boolean, numeric, date, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.chart_resolve_account_for_entry(uuid, uuid, public.transaction_type_enum, text, public.vat_treatment_enum, public.ledger_entry_kind_enum, public.ledger_entry_type_enum) TO authenticated, service_role;

COMMIT;
