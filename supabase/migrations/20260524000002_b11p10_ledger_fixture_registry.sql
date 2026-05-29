-- B11·P10 part 2 of 2 — End-to-End Ledger Tests registry + run-tracking
-- =====================================================================
-- Stage-5 DB scaffold for the LEDGER_PREPARATION regression test layer.
-- Same pattern as B09·P10 (intake fixtures) and B10·P10 (matching fixtures).
--
-- DB-side deliverables:
--   * LEDGER_FIXTURE added to audit.subject_type_enum (Migration 1)
--   * ledger_fixtures registry (name + category + path)
--   * ledger_fixture_runs execution tracking (status/hashes/diff)
--   * 43 seed fixtures across 9 categories per spec
--   * 4 RPCs: register_ledger_fixture (idempotent), record_*_run_started,
--     record_*_run_passed, record_*_run_failed
--   * 3 audit actions: LEDGER_FIXTURE_RAN / _PASSED / _FAILED
--
-- Out of scope (app-layer, deferred):
--   * 43 fixture JSON bundles in Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/<name>/
--   * runLedgerFixture(name) → FixtureResult test runner
--   * Recorded AI response files for ledger.generate_vat_explanations
--   * CI wiring (GitHub Actions, merge-blocking failures)
--   * 90s performance budget measurement
-- =====================================================================

BEGIN;

-- 1. ledger_fixtures registry ---------------------------------------------

CREATE TABLE public.ledger_fixtures (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_name    text NOT NULL,
  category        text NOT NULL,
  description     text NOT NULL,
  fixture_path    text NOT NULL,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by      uuid,
  CONSTRAINT ledger_fixtures_name_unique UNIQUE (fixture_name),
  CONSTRAINT ledger_fixtures_category_chk
    CHECK (category IN ('VAT_TREATMENTS','TRANSACTION_TYPES','VIES_EXPORT','MULTI_LINE',
                        'CHART_VERSION_PIN','ACCOUNTANT_REVIEW','MANUAL_OVERRIDE',
                        'AI_EXPLANATION_FALLBACK','VAT_AMOUNT_SOURCES'))
);

COMMENT ON TABLE public.ledger_fixtures IS
  'Registry of golden fixtures for LEDGER_PREPARATION end-to-end regression tests (B11·P10). Actual JSON bundles + test runner are app-layer.';


-- 2. ledger_fixture_runs --------------------------------------------------

CREATE TABLE public.ledger_fixture_runs (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_id            uuid NOT NULL REFERENCES public.ledger_fixtures(id),
  run_started_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  run_completed_at      timestamptz,
  status                text NOT NULL DEFAULT 'RUNNING',
  actual_results_hash   text,
  expected_results_hash text,
  diff_summary          jsonb,
  duration_ms           int,
  triggered_by          text,
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ledger_fixture_runs_status_chk
    CHECK (status IN ('RUNNING','PASSED','FAILED','TIMED_OUT'))
);

CREATE INDEX ledger_fixture_runs_fixture_idx ON public.ledger_fixture_runs (fixture_id);
CREATE INDEX ledger_fixture_runs_status_idx  ON public.ledger_fixture_runs (status, run_started_at DESC);


-- 3. Seed 43 fixtures across 9 categories ---------------------------------

INSERT INTO public.ledger_fixtures (fixture_name, category, description, fixture_path) VALUES
  -- VAT_TREATMENTS (9)
  ('vat_domestic_cyprus_b2b_expense','VAT_TREATMENTS','Domestic CY supplier with valid CY VAT → DOMESTIC_CYPRUS_VAT; input VAT from document.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_domestic_cyprus_b2b_expense/'),
  ('vat_eu_reverse_charge_service_out','VAT_TREATMENTS','EU (DE) supplier + valid VAT + service → EU_REVERSE_CHARGE OUT; PRIMARY + paired VAT_RECLAIM+VAT_OUTPUT (net zero).','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_eu_reverse_charge_service_out/'),
  ('vat_eu_reverse_charge_service_in','VAT_TREATMENTS','EU (FR) customer + valid VAT + service → EU_REVERSE_CHARGE IN; vies_relevant=true; vies_period populated.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_eu_reverse_charge_service_in/'),
  ('vat_import_or_acquisition_eu_goods','VAT_TREATMENTS','EU supplier + goods tag → IMPORT_OR_ACQUISITION.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_import_or_acquisition_eu_goods/'),
  ('vat_non_eu_service','VAT_TREATMENTS','US supplier + service tag → NON_EU_SERVICE.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_non_eu_service/'),
  ('vat_exempt','VAT_TREATMENTS','Financial services category → EXEMPT; both VAT amounts 0.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_exempt/'),
  ('vat_no_vat_business_not_registered','VAT_TREATMENTS','Business not VAT-registered → NO_VAT for OUT entries.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_no_vat_business_not_registered/'),
  ('vat_outside_scope_internal_transfer','VAT_TREATMENTS','INTERNAL_TRANSFER → OUTSIDE_SCOPE.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_outside_scope_internal_transfer/'),
  ('vat_unknown_unresolved_country','VAT_TREATMENTS','Phase 04 returns null country → UNKNOWN + accountant_review + Possible Tax/VAT Issue.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_unknown_unresolved_country/'),

  -- TRANSACTION_TYPES (13)
  ('type_out_expense','TRANSACTION_TYPES','OUT_EXPENSE basic path.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_out_expense/'),
  ('type_in_income','TRANSACTION_TYPES','IN_INCOME basic path.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_in_income/'),
  ('type_internal_transfer','TRANSACTION_TYPES','INTERNAL_TRANSFER between own accounts.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_internal_transfer/'),
  ('type_fx_exchange','TRANSACTION_TYPES','FX_EXCHANGE with FX_DELTA derived entry.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_fx_exchange/'),
  ('type_bank_fee','TRANSACTION_TYPES','BANK_FEE charges.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_bank_fee/'),
  ('type_refund_in','TRANSACTION_TYPES','REFUND_IN reversing an earlier OUT_EXPENSE.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_refund_in/'),
  ('type_refund_out','TRANSACTION_TYPES','REFUND_OUT reversing an earlier IN_INCOME.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_refund_out/'),
  ('type_chargeback','TRANSACTION_TYPES','CHARGEBACK with fee leg.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_chargeback/'),
  ('type_loan_or_shareholder_movement','TRANSACTION_TYPES','LOAN_OR_SHAREHOLDER_MOVEMENT with requires_contract=true.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_loan_or_shareholder_movement/'),
  ('type_payroll_contractor','TRANSACTION_TYPES','PAYROLL contractor with requires_invoice + requires_contract.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_payroll_contractor/'),
  ('type_payroll_employee','TRANSACTION_TYPES','PAYROLL employee (no evidence flags).','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_payroll_employee/'),
  ('type_tax_payment','TRANSACTION_TYPES','TAX_PAYMENT to tax authority.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_tax_payment/'),
  ('type_unknown_held','TRANSACTION_TYPES','UNKNOWN type → no entries + held audit + HIGH review_issue.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/type_unknown_held/'),

  -- VIES_EXPORT (2)
  ('vies_export_two_eu_customers_consolidate','VIES_EXPORT','3 IN-side EU_REVERSE_CHARGE entries across 2 customers; per-entry flags verified.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vies_export_two_eu_customers_consolidate/'),
  ('vies_missing_vat_number_excludes_from_export','VIES_EXPORT','IN-side EU_REVERSE_CHARGE with missing VAT → vies_relevant=false + LEDGER_VIES_VAT_NUMBER_MISSING_RAISED.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vies_missing_vat_number_excludes_from_export/'),

  -- MULTI_LINE (2)
  ('multiline_consolidate_same_category','MULTI_LINE','AWS-style 12-line invoice all IT & Software → one consolidated PRIMARY + CONSOLIDATED audit.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/multiline_consolidate_same_category/'),
  ('multiline_split_by_category','MULTI_LINE','Invoice with 2 lines mapping to different categories → 2 PRIMARY entries + SPLIT_BY_CATEGORY audit.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/multiline_split_by_category/'),

  -- CHART_VERSION_PIN (2)
  ('chart_version_replay','CHART_VERSION_PIN','Finalize period 1 with chart v1; user customizes to v2; re-render period 1 → identical output; entries still pinned to v1.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/chart_version_replay/'),
  ('chart_version_recompute_in_draft','CHART_VERSION_PIN','Period 2 in DRAFT; user customizes to v3; recompute uses v3.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/chart_version_recompute_in_draft/'),

  -- ACCOUNTANT_REVIEW (6)
  ('review_unknown_treatment','ACCOUNTANT_REVIEW','vat_treatment=UNKNOWN → severity HIGH review_issue.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/review_unknown_treatment/'),
  ('review_tag_mismatch','ACCOUNTANT_REVIEW','Phase 05 NON_EU_SERVICE but tag = physical_goods_import → MEDIUM review_issue.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/review_tag_mismatch/'),
  ('review_cross_period_adjustment','ACCOUNTANT_REVIEW','Matched invoice in finalized period → HIGH review_issue mentioning adjustment-run path.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/review_cross_period_adjustment/'),
  ('review_reverse_charge_plausible_no_vat_number','ACCOUNTANT_REVIEW','EU country + missing VAT number → MEDIUM review_issue.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/review_reverse_charge_plausible_no_vat_number/'),
  ('review_disabled_account_in_mapping','ACCOUNTANT_REVIEW','Phase 03 disabled-account semantics → review mentioning successor.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/review_disabled_account_in_mapping/'),
  ('review_missing_required_evidence','ACCOUNTANT_REVIEW','OUT_EXPENSE >= €15 with only receipt → MISSING_REQUIRED_EVIDENCE in Missing Documents bucket.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/review_missing_required_evidence/'),

  -- MANUAL_OVERRIDE (4)
  ('manual_override_owner_changes_treatment','MANUAL_OVERRIDE','Owner overrides UNKNOWN → EXEMPT; audit verified; subsequent classifier run honors override.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/manual_override_owner_changes_treatment/'),
  ('manual_override_admin_allowed','MANUAL_OVERRIDE','Admin override succeeds.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/manual_override_admin_allowed/'),
  ('manual_override_bookkeeper_denied','MANUAL_OVERRIDE','Bookkeeper override denied with INSUFFICIENT_PRIVILEGE.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/manual_override_bookkeeper_denied/'),
  ('manual_override_cleared_then_classifier_decides','MANUAL_OVERRIDE','Owner clears override; next classifier run produces rules-derived result.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/manual_override_cleared_then_classifier_decides/'),

  -- AI_EXPLANATION_FALLBACK (1)
  ('vat_explanation_ai_failure_falls_back','AI_EXPLANATION_FALLBACK','Recorded AI response is timeout → deterministic fallback string + LEDGER_VAT_EXPLANATION_FALLBACK_APPLIED audit + LOW review.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_explanation_ai_failure_falls_back/'),

  -- VAT_AMOUNT_SOURCES (4)
  ('vat_amount_from_document','VAT_AMOUNT_SOURCES','Invoice has explicit VAT line → calculator uses it directly.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_amount_from_document/'),
  ('vat_amount_from_rate_derivation','VAT_AMOUNT_SOURCES','Invoice has no VAT line → calculator uses Cyprus standard rate per pinned version.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_amount_from_rate_derivation/'),
  ('vat_amount_mixed_rate_invoice','VAT_AMOUNT_SOURCES','Multi-rate invoice; per P07 split-vs-consolidate the breakdown is correct.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_amount_mixed_rate_invoice/'),
  ('vat_amount_rounding_paired_entries','VAT_AMOUNT_SOURCES','Reverse-charge OUT-side; ROUNDING derived entry fires for ±0.02 cumulative delta.','Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/vat_amount_rounding_paired_entries/');


-- 4. RPCs (4) -------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.register_ledger_fixture(
  p_fixture_name text, p_category text, p_description text, p_fixture_path text,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.ledger_fixtures (fixture_name, category, description, fixture_path, created_by)
  VALUES (p_fixture_name, p_category, p_description, p_fixture_path, p_actor_user_id)
  ON CONFLICT (fixture_name) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.ledger_fixtures WHERE fixture_name = p_fixture_name;
  END IF;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ledger_fixture_run_started(
  p_fixture_id uuid, p_triggered_by text, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_run_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.ledger_fixtures WHERE id = p_fixture_id) THEN
    RAISE EXCEPTION 'FIXTURE_NOT_FOUND' USING errcode='check_violation';
  END IF;
  INSERT INTO public.ledger_fixture_runs (fixture_id, triggered_by)
  VALUES (p_fixture_id, p_triggered_by) RETURNING id INTO v_run_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_FIXTURE_RAN',
    p_subject_type:='LEDGER_FIXTURE'::audit.subject_type_enum, p_subject_id:=p_fixture_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_fixture_runner', p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('run_id', v_run_id, 'triggered_by', p_triggered_by),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN v_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ledger_fixture_run_passed(
  p_run_id uuid, p_actual_results_hash text, p_expected_results_hash text,
  p_duration_ms int, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_fixture_id uuid;
BEGIN
  IF p_duration_ms IS NULL OR p_duration_ms < 0 THEN
    RAISE EXCEPTION 'DURATION_MUST_BE_NONNEG' USING errcode='check_violation';
  END IF;
  UPDATE public.ledger_fixture_runs
    SET status='PASSED', actual_results_hash=p_actual_results_hash, expected_results_hash=p_expected_results_hash,
        duration_ms=p_duration_ms, run_completed_at=clock_timestamp()
  WHERE id = p_run_id RETURNING fixture_id INTO v_fixture_id;
  IF v_fixture_id IS NULL THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_FIXTURE_PASSED',
    p_subject_type:='LEDGER_FIXTURE'::audit.subject_type_enum, p_subject_id:=v_fixture_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_fixture_runner', p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('run_id', p_run_id, 'duration_ms', p_duration_ms,
                                       'actual_hash', p_actual_results_hash, 'expected_hash', p_expected_results_hash),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','RECORDED','run_id',p_run_id,'fixture_id',v_fixture_id,'status','PASSED');
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ledger_fixture_run_failed(
  p_run_id uuid, p_actual_results_hash text, p_expected_results_hash text,
  p_diff_summary jsonb, p_duration_ms int, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_fixture_id uuid; v_fixture_name text; v_triggered_by text;
BEGIN
  IF p_duration_ms IS NULL OR p_duration_ms < 0 THEN
    RAISE EXCEPTION 'DURATION_MUST_BE_NONNEG' USING errcode='check_violation';
  END IF;
  IF p_diff_summary IS NULL OR jsonb_typeof(p_diff_summary) <> 'object' THEN
    RAISE EXCEPTION 'DIFF_SUMMARY_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;
  UPDATE public.ledger_fixture_runs
    SET status='FAILED', actual_results_hash=p_actual_results_hash, expected_results_hash=p_expected_results_hash,
        diff_summary=p_diff_summary, duration_ms=p_duration_ms, run_completed_at=clock_timestamp()
  WHERE id = p_run_id RETURNING fixture_id, triggered_by INTO v_fixture_id, v_triggered_by;
  IF v_fixture_id IS NULL THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;
  SELECT fixture_name INTO v_fixture_name FROM public.ledger_fixtures WHERE id = v_fixture_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_FIXTURE_FAILED',
    p_subject_type:='LEDGER_FIXTURE'::audit.subject_type_enum, p_subject_id:=v_fixture_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_fixture_runner', p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('run_id', p_run_id, 'duration_ms', p_duration_ms,
                                       'fixture_name', v_fixture_name, 'triggered_by', v_triggered_by,
                                       'diff_summary', p_diff_summary,
                                       'actual_hash', p_actual_results_hash, 'expected_hash', p_expected_results_hash),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','RECORDED','run_id',p_run_id,'fixture_id',v_fixture_id,'fixture_name',v_fixture_name,'status','FAILED');
END;
$$;


-- 5. Privileges -----------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.register_ledger_fixture(text, text, text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_ledger_fixture_run_started(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_ledger_fixture_run_passed(uuid, text, text, int, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_ledger_fixture_run_failed(uuid, text, text, jsonb, int, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.register_ledger_fixture(text, text, text, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_ledger_fixture_run_started(uuid, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_ledger_fixture_run_passed(uuid, text, text, int, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_ledger_fixture_run_failed(uuid, text, text, jsonb, int, jsonb) TO authenticated, service_role;

COMMIT;
