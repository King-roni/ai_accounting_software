-- B11·P06 — Reverse Charge & VIES Relevance
-- =====================================================================
-- Pure derivation phase. Reads Phase 04 (counterparty_country, vat_number) +
-- Phase 05 (vat_treatment) outputs already persisted on draft_ledger_entries;
-- derives the two compliance booleans + vies_period; persists; emits 3 audits.
--
-- reverse_charge_relevant: true when
--   (treatment ∈ {EU_REVERSE_CHARGE, IMPORT_OR_ACQUISITION} AND direction=OUT)
--   OR (treatment = EU_REVERSE_CHARGE AND direction=IN)
--
-- vies_relevant: true ONLY when direction=IN AND treatment=EU_REVERSE_CHARGE
--   AND counterparty in EU AND counterparty VAT format-valid AND business VAT-registered
--
-- vies_period: when vies_relevant → to_char(entry_period, 'YYYY-MM'); else NULL
--
-- Audit (subject_type=DRAFT_LEDGER_ENTRY, actor_kind=SYSTEM):
--   * LEDGER_REVERSE_CHARGE_FLAGGED
--   * LEDGER_VIES_RELEVANCE_DECIDED
--   * LEDGER_VIES_VAT_NUMBER_MISSING_RAISED (when IN-side EU EU_REVERSE_CHARGE
--     would be VIES-eligible but counterparty VAT number is missing/invalid)
--
-- Deferred:
--   * vies_value_basis_eur (Phase 08 owns)
--   * VAT_RECLAIM / VAT_OUTPUT derived entries on OUT-side reverse charge (Phase 07)
--   * VIES_VAT_NUMBER_MISSING_OR_INVALID review_issue (Phase 08 emits; only audit here)
--   * VIES-online validity check (Stage 2+)
--   * Quarterly VIES eligibility (sub-doc)
--   * Non-EUR bookkeeping currency
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.compute_reverse_charge_and_vies(
  p_organization_id uuid, p_business_id uuid,
  p_draft_ledger_entry_id uuid,
  p_workflow_run_id uuid,
  p_actor_user_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp AS $$
DECLARE
  v_vat_treatment public.vat_treatment_enum;
  v_counterparty_country char(2);
  v_counterparty_vat text;
  v_entry_period date;
  v_parent_txn_id uuid;
  v_debit_amount numeric;
  v_credit_amount numeric;
  v_direction public.transaction_direction_enum;
  v_biz_vat_registered boolean;
  v_reverse_charge boolean;
  v_vies boolean;
  v_vies_period text;
  v_vat_valid boolean;
  v_signals jsonb;
BEGIN
  SELECT vat_treatment, counterparty_country, counterparty_vat_number, entry_period,
         parent_transaction_id, debit_amount, credit_amount
    INTO v_vat_treatment, v_counterparty_country, v_counterparty_vat, v_entry_period,
         v_parent_txn_id, v_debit_amount, v_credit_amount
    FROM public.draft_ledger_entries WHERE id = p_draft_ledger_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DRAFT_LEDGER_ENTRY_NOT_FOUND' USING errcode='check_violation';
  END IF;

  IF v_parent_txn_id IS NOT NULL THEN
    SELECT direction INTO v_direction FROM public.transactions WHERE id = v_parent_txn_id;
  ELSE
    v_direction := CASE WHEN v_debit_amount IS NOT NULL THEN 'OUT'::public.transaction_direction_enum
                        ELSE 'IN'::public.transaction_direction_enum END;
  END IF;

  SELECT vat_registered INTO v_biz_vat_registered FROM public.business_entities WHERE id = p_business_id;

  v_vat_valid := v_counterparty_vat IS NOT NULL
                AND public.validate_vat_number_format(v_counterparty_country, v_counterparty_vat);

  v_reverse_charge :=
    (v_vat_treatment IN ('EU_REVERSE_CHARGE','IMPORT_OR_ACQUISITION') AND v_direction = 'OUT')
    OR
    (v_vat_treatment = 'EU_REVERSE_CHARGE' AND v_direction = 'IN');

  v_vies := v_direction = 'IN'
            AND v_vat_treatment = 'EU_REVERSE_CHARGE'
            AND public.is_eu_member_state(v_counterparty_country)
            AND v_vat_valid
            AND v_biz_vat_registered = true;

  v_vies_period := CASE WHEN v_vies THEN to_char(v_entry_period, 'YYYY-MM') ELSE NULL END;

  UPDATE public.draft_ledger_entries
    SET reverse_charge_relevant = v_reverse_charge,
        vies_relevant = v_vies,
        vies_period = v_vies_period,
        last_recomputed_at = clock_timestamp()
   WHERE id = p_draft_ledger_entry_id;

  v_signals := jsonb_build_object(
    'vat_treatment', v_vat_treatment, 'direction', v_direction,
    'counterparty_country', v_counterparty_country,
    'counterparty_vat_present', v_counterparty_vat IS NOT NULL,
    'counterparty_vat_format_valid', v_vat_valid,
    'business_vat_registered', v_biz_vat_registered);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='LEDGER_REVERSE_CHARGE_FLAGGED',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
    p_subject_id:=p_draft_ledger_entry_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='reverse_charge_vies',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('reverse_charge_relevant', v_reverse_charge, 'signals', v_signals),
    p_reason:=NULL, p_request_context:=p_context);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='LEDGER_VIES_RELEVANCE_DECIDED',
    p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
    p_subject_id:=p_draft_ledger_entry_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='reverse_charge_vies',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('vies_relevant', v_vies, 'vies_period', v_vies_period, 'signals', v_signals),
    p_reason:=NULL, p_request_context:=p_context);

  IF v_direction = 'IN' AND v_vat_treatment = 'EU_REVERSE_CHARGE'
     AND public.is_eu_member_state(v_counterparty_country) AND v_biz_vat_registered = true
     AND NOT v_vat_valid THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_VIES_VAT_NUMBER_MISSING_RAISED',
      p_subject_type:='DRAFT_LEDGER_ENTRY'::audit.subject_type_enum,
      p_subject_id:=p_draft_ledger_entry_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='reverse_charge_vies',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'counterparty_country', v_counterparty_country,
        'counterparty_vat_raw', v_counterparty_vat,
        'reason', 'EU IN-side reverse-charge entry would be VIES-eligible but counterparty VAT number is missing or format-invalid'),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'reverse_charge_relevant', v_reverse_charge,
    'vies_relevant', v_vies,
    'vies_period', v_vies_period,
    'supporting_signals', v_signals
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.compute_reverse_charge_and_vies(uuid, uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.compute_reverse_charge_and_vies(uuid, uuid, uuid, uuid, uuid, jsonb) TO service_role;

COMMIT;
