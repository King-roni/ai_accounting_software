-- B11·P05 follow-up — counterparty_country and counterparty_vat_number live on
-- draft_ledger_entries (populated by Phase 04 / Phase 07), NOT on transactions.
-- (transactions stores counterparty_name + counterparty_identifier_masked/encrypted
-- and country information, but the canonicalised resolved fields land on the
-- ledger entry.) Re-creates classify_vat_treatment to read those two fields
-- from the entry.

BEGIN;

CREATE OR REPLACE FUNCTION public.classify_vat_treatment(
  p_organization_id uuid, p_business_id uuid,
  p_draft_ledger_entry_id uuid,
  p_workflow_run_id uuid,
  p_actor_user_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp AS $$
DECLARE
  v_existing_treatment public.vat_treatment_enum;
  v_existing_review boolean;
  v_manual_override_by uuid;
  v_parent_txn_id uuid;
  v_debit_code text;
  v_credit_code text;
  v_biz_country char(2);
  v_biz_vat_registered boolean;
  v_direction public.transaction_direction_enum;
  v_txn_type public.transaction_type_enum;
  v_counterparty_country char(2);
  v_counterparty_vat text;
  v_txn_tag text;
  v_category text;
  v_treatment public.vat_treatment_enum;
  v_rule_id text;
  v_review boolean := false;
  v_reason text;
  v_tag_branch text;
  v_signals jsonb;
  v_tag_mismatch boolean := false;
BEGIN
  SELECT vat_treatment, requires_accountant_review, manual_override_by, parent_transaction_id,
         debit_account_code, credit_account_code, counterparty_country, counterparty_vat_number
    INTO v_existing_treatment, v_existing_review, v_manual_override_by, v_parent_txn_id,
         v_debit_code, v_credit_code, v_counterparty_country, v_counterparty_vat
    FROM public.draft_ledger_entries WHERE id = p_draft_ledger_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DRAFT_LEDGER_ENTRY_NOT_FOUND' USING errcode='check_violation';
  END IF;

  IF v_manual_override_by IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
      p_subject_id:=p_draft_ledger_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='vat_classifier',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('treatment', v_existing_treatment, 'rule_id','MANUAL_OVERRIDE'),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object(
      'treatment', v_existing_treatment,
      'decided_by_rule_id', 'MANUAL_OVERRIDE',
      'supporting_signals', jsonb_build_object('manual_override_by', v_manual_override_by),
      'requires_accountant_review', v_existing_review,
      'accountant_review_reason', NULL);
  END IF;

  SELECT country_code, vat_registered INTO v_biz_country, v_biz_vat_registered
    FROM public.business_entities WHERE id = p_business_id;

  IF v_parent_txn_id IS NOT NULL THEN
    SELECT direction, transaction_type, user_tag
      INTO v_direction, v_txn_type, v_txn_tag
      FROM public.transactions WHERE id = v_parent_txn_id;
  END IF;

  SELECT category INTO v_category FROM public.chart_of_accounts
    WHERE business_id = p_business_id
      AND code = COALESCE(
        CASE WHEN v_direction = 'IN' THEN v_credit_code ELSE v_debit_code END,
        v_debit_code, v_credit_code);

  v_tag_branch := public.infer_service_or_goods(v_txn_tag);

  IF v_biz_vat_registered IS NULL OR v_biz_vat_registered = false THEN
    IF v_direction = 'IN' THEN
      v_treatment := 'OUTSIDE_SCOPE'; v_rule_id := 'PRE-2-IN';
    ELSE
      v_treatment := 'NO_VAT'; v_rule_id := 'PRE-2-OUT';
    END IF;
  ELSIF v_counterparty_country IS NULL THEN
    v_treatment := 'UNKNOWN'; v_rule_id := 'PRE-3-COUNTRY_UNRESOLVED';
    v_review := true; v_reason := 'Counterparty country could not be determined.';
  ELSIF v_direction = 'OUT' THEN
    IF public.is_outside_scope_transaction_type(v_txn_type) THEN
      v_treatment := 'OUTSIDE_SCOPE'; v_rule_id := 'OUT-7';
    ELSIF public.is_exempt_category(v_category) THEN
      v_treatment := 'EXEMPT'; v_rule_id := 'OUT-6';
    ELSIF v_biz_country = 'CY' AND v_counterparty_country = 'CY'
          AND v_counterparty_vat IS NOT NULL
          AND public.validate_vat_number_format(v_counterparty_country, v_counterparty_vat) THEN
      v_treatment := 'DOMESTIC_CYPRUS_VAT'; v_rule_id := 'OUT-1';
    ELSIF v_biz_country = 'CY' AND public.is_eu_member_state(v_counterparty_country)
          AND v_counterparty_country <> 'CY' AND v_counterparty_vat IS NOT NULL
          AND public.validate_vat_number_format(v_counterparty_country, v_counterparty_vat)
          AND v_tag_branch IN ('SERVICE','UNKNOWN') THEN
      v_treatment := 'EU_REVERSE_CHARGE'; v_rule_id := 'OUT-2';
    ELSIF v_biz_country = 'CY' AND public.is_eu_member_state(v_counterparty_country)
          AND v_counterparty_country <> 'CY' AND v_counterparty_vat IS NOT NULL
          AND v_tag_branch = 'GOODS' THEN
      v_treatment := 'IMPORT_OR_ACQUISITION'; v_rule_id := 'OUT-3';
    ELSIF NOT public.is_eu_member_state(v_counterparty_country) AND v_tag_branch = 'SERVICE' THEN
      v_treatment := 'NON_EU_SERVICE'; v_rule_id := 'OUT-4';
    ELSIF NOT public.is_eu_member_state(v_counterparty_country) AND v_tag_branch = 'GOODS' THEN
      v_treatment := 'IMPORT_OR_ACQUISITION'; v_rule_id := 'OUT-5';
    ELSIF v_biz_country = 'CY' AND v_counterparty_country = 'CY'
          AND (v_counterparty_vat IS NULL
               OR NOT public.validate_vat_number_format(v_counterparty_country, v_counterparty_vat)) THEN
      v_treatment := 'NO_VAT'; v_rule_id := 'OUT-8';
    ELSE
      v_treatment := 'UNKNOWN'; v_rule_id := 'OUT-residual';
      v_review := true; v_reason := 'VAT treatment rules could not select a definite branch.';
    END IF;
  ELSE
    IF public.is_outside_scope_transaction_type(v_txn_type) THEN
      v_treatment := 'OUTSIDE_SCOPE'; v_rule_id := 'IN-5';
    ELSIF public.is_exempt_category(v_category) THEN
      v_treatment := 'EXEMPT'; v_rule_id := 'IN-4';
    ELSIF v_biz_vat_registered AND v_counterparty_country = 'CY' THEN
      v_treatment := 'DOMESTIC_CYPRUS_VAT'; v_rule_id := 'IN-1';
    ELSIF public.is_eu_member_state(v_counterparty_country) AND v_counterparty_country <> 'CY'
          AND v_tag_branch IN ('SERVICE','UNKNOWN') THEN
      IF v_counterparty_vat IS NOT NULL
         AND public.validate_vat_number_format(v_counterparty_country, v_counterparty_vat) THEN
        v_treatment := 'EU_REVERSE_CHARGE'; v_rule_id := 'IN-2';
      ELSE
        v_treatment := 'UNKNOWN'; v_rule_id := 'IN-2-residual';
        v_review := true;
        v_reason := 'EU IN-side reverse-charge plausible but counterparty VAT number is missing or invalid; cannot fire IN-2 definitively.';
      END IF;
    ELSIF NOT public.is_eu_member_state(v_counterparty_country) AND v_tag_branch = 'SERVICE' THEN
      v_treatment := 'NON_EU_SERVICE'; v_rule_id := 'IN-3';
    ELSE
      v_treatment := 'UNKNOWN'; v_rule_id := 'IN-residual';
      v_review := true; v_reason := 'IN-side VAT treatment rules could not select a definite branch.';
    END IF;
  END IF;

  IF v_treatment IN ('NON_EU_SERVICE','EU_REVERSE_CHARGE') AND v_tag_branch = 'GOODS' THEN
    v_tag_mismatch := true; v_review := true;
    v_reason := COALESCE(v_reason || '; ', '') ||
                'Rule selected a service treatment (' || v_treatment::text ||
                ') but transaction tag indicates goods (' || v_txn_tag || ').';
  ELSIF v_treatment = 'IMPORT_OR_ACQUISITION' AND v_tag_branch = 'SERVICE' THEN
    v_tag_mismatch := true; v_review := true;
    v_reason := COALESCE(v_reason || '; ', '') ||
                'Rule selected IMPORT_OR_ACQUISITION but tag indicates service (' || v_txn_tag || ').';
  END IF;

  v_signals := jsonb_build_object(
    'biz_country', v_biz_country, 'biz_vat_registered', v_biz_vat_registered,
    'direction', v_direction, 'transaction_type', v_txn_type,
    'counterparty_country', v_counterparty_country,
    'counterparty_vat_present', v_counterparty_vat IS NOT NULL,
    'tag', v_txn_tag, 'tag_branch', v_tag_branch,
    'category', v_category);

  UPDATE public.draft_ledger_entries
    SET vat_treatment = v_treatment,
        requires_accountant_review = v_review,
        accountant_review_reason = v_reason,
        last_recomputed_at = clock_timestamp()
   WHERE id = p_draft_ledger_entry_id;

  IF v_tag_mismatch THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_VAT_TREATMENT_TAG_MISMATCH_DETECTED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
      p_subject_id:=p_draft_ledger_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='vat_classifier',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('treatment', v_treatment, 'tag', v_txn_tag, 'tag_branch', v_tag_branch),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  IF v_treatment = 'UNKNOWN' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_VAT_TREATMENT_UNKNOWN_RAISED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
      p_subject_id:=p_draft_ledger_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='vat_classifier',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('rule_id', v_rule_id, 'reason', v_reason, 'signals', v_signals),
      p_reason:=v_reason, p_request_context:=p_context);
  ELSE
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_VAT_TREATMENT_DECIDED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
      p_subject_id:=p_draft_ledger_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='vat_classifier',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'treatment', v_treatment, 'rule_id', v_rule_id,
        'requires_accountant_review', v_review,
        'signals', v_signals),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'treatment', v_treatment,
    'decided_by_rule_id', v_rule_id,
    'supporting_signals', v_signals,
    'requires_accountant_review', v_review,
    'accountant_review_reason', v_reason
  );
END;
$$;

COMMIT;
