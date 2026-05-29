-- B10·P10 part 2 of 2 — Matching Fixture Registry
-- =====================================================================
-- Stage-5 DB scaffold for the end-to-end matching regression test layer.
--
-- DB-side deliverables here:
--   * matching_fixtures registry (name + side + category + path)
--   * matching_fixture_runs execution tracking (status, hashes, diff)
--   * 30 seed fixture rows (5 MATCH_LEVELS + 4 CROSS_PERIOD + 2 CROSS_CURRENCY
--     + 3 SPLIT_PAYMENT + 3 DUPLICATE_DETECTION + 3 REJECTION_MEMORY + 7
--     IN_OUTCOMES + 3 REASON_GENERATION)
--   * 4 RPCs: register_matching_fixture (idempotent), record_*_run_started,
--     record_*_run_passed, record_*_run_failed
--   * 3 audit actions emitted via RPCs (subject_type=MATCHING_FIXTURE):
--     MATCHING_FIXTURE_RAN, MATCHING_FIXTURE_PASSED, MATCHING_FIXTURE_FAILED
--
-- Out of scope (app-layer, deferred to a future stage):
--   * The actual fixture JSON files in Docs/phases/10_matching_engine/fixtures/
--   * The `runMatchingFixture(fixture_name) → FixtureResult` test runner
--   * Recorded AI response files for plain-language reason generation
--   * CI wiring (GitHub Actions workflow)
--   * Performance budget measurement (target: full suite < 90s)
-- =====================================================================

BEGIN;

-- 1. matching_fixtures registry --------------------------------------------

CREATE TABLE public.matching_fixtures (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_name    text NOT NULL,
  side            text NOT NULL,
  category        text NOT NULL,
  description     text NOT NULL,
  fixture_path    text NOT NULL,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by      uuid,
  CONSTRAINT matching_fixtures_name_unique UNIQUE (fixture_name),
  CONSTRAINT matching_fixtures_side_chk
    CHECK (side IN ('OUT','IN')),
  CONSTRAINT matching_fixtures_category_chk
    CHECK (category IN ('MATCH_LEVELS','CROSS_PERIOD','CROSS_CURRENCY',
                        'SPLIT_PAYMENT','DUPLICATE_DETECTION','REJECTION_MEMORY',
                        'IN_OUTCOMES','REASON_GENERATION'))
);

COMMENT ON TABLE public.matching_fixtures IS
  'Registry of golden fixtures for matching engine regression tests (B10·P10). Each row points to a fixture JSON bundle on disk; the actual JSON + test runner are app-layer.';


-- 2. matching_fixture_runs execution tracking ------------------------------

CREATE TABLE public.matching_fixture_runs (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_id            uuid NOT NULL REFERENCES public.matching_fixtures(id),
  run_started_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  run_completed_at      timestamptz,
  status                text NOT NULL DEFAULT 'RUNNING',
  actual_results_hash   text,
  expected_results_hash text,
  diff_summary          jsonb,
  duration_ms           int,
  triggered_by          text,
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT matching_fixture_runs_status_chk
    CHECK (status IN ('RUNNING','PASSED','FAILED','TIMED_OUT'))
);

CREATE INDEX matching_fixture_runs_fixture_idx ON public.matching_fixture_runs(fixture_id);
CREATE INDEX matching_fixture_runs_status_idx  ON public.matching_fixture_runs(status, run_started_at DESC);


-- 3. Seed initial 30 fixtures ----------------------------------------------

INSERT INTO public.matching_fixtures (fixture_name, side, category, description, fixture_path) VALUES
  -- MATCH_LEVELS (5)
  ('level_1_exact_match', 'OUT', 'MATCH_LEVELS',
   'Clean amount + currency + supplier + date → Level 1 exact match.',
   'Docs/phases/10_matching_engine/fixtures/level_1_exact_match/'),
  ('level_2_strong_with_recurring', 'OUT', 'MATCH_LEVELS',
   'Fuzzy supplier + vendor-memory 0.88 + amount-exact → auto-confirm Level 2.',
   'Docs/phases/10_matching_engine/fixtures/level_2_strong_with_recurring/'),
  ('level_2_strong_without_recurring', 'OUT', 'MATCH_LEVELS',
   'Same fuzzy supplier but vendor-memory 0.72 → MATCHED_NEEDS_CONFIRMATION.',
   'Docs/phases/10_matching_engine/fixtures/level_2_strong_without_recurring/'),
  ('level_3_weak_possible', 'OUT', 'MATCH_LEVELS',
   'Some signals align → POSSIBLE_MATCH to review queue.',
   'Docs/phases/10_matching_engine/fixtures/level_3_weak_possible/'),
  ('level_4_no_match', 'OUT', 'MATCH_LEVELS',
   'No candidate above threshold → NO_MATCH + Missing Documents review issue.',
   'Docs/phases/10_matching_engine/fixtures/level_4_no_match/'),

  -- CROSS_PERIOD (4)
  ('cross_period_invoice_one_month_old', 'OUT', 'CROSS_PERIOD',
   'Invoice issued prior month, transaction current month, within 60-day window.',
   'Docs/phases/10_matching_engine/fixtures/cross_period_invoice_one_month_old/'),
  ('cross_period_outside_window_lookback', 'OUT', 'CROSS_PERIOD',
   'Invoice from 90 days ago outside -60-day look-back; should NOT match.',
   'Docs/phases/10_matching_engine/fixtures/cross_period_outside_window_lookback/'),
  ('cross_period_invoice_after_transaction_within_window', 'OUT', 'CROSS_PERIOD',
   'Invoice issued 15 days AFTER transaction (within +30-day forward); SHOULD match.',
   'Docs/phases/10_matching_engine/fixtures/cross_period_invoice_after_transaction_within_window/'),
  ('cross_period_invoice_after_transaction_outside_window', 'OUT', 'CROSS_PERIOD',
   'Invoice issued 45 days AFTER transaction (outside +30-day forward); should NOT match.',
   'Docs/phases/10_matching_engine/fixtures/cross_period_invoice_after_transaction_outside_window/'),

  -- CROSS_CURRENCY (2)
  ('cross_currency_with_paired_leg', 'OUT', 'CROSS_CURRENCY',
   'EUR txn, USD invoice, FX paired-leg present, conversion uses bank rate.',
   'Docs/phases/10_matching_engine/fixtures/cross_currency_with_paired_leg/'),
  ('cross_currency_with_ecb_fallback', 'OUT', 'CROSS_CURRENCY',
   'Same as paired_leg but no paired leg → ECB rate used.',
   'Docs/phases/10_matching_engine/fixtures/cross_currency_with_ecb_fallback/'),

  -- SPLIT_PAYMENT (3)
  ('split_payment_two_invoices_same_supplier', 'OUT', 'SPLIT_PAYMENT',
   'High-confidence two-invoice split-payment proposal (same supplier).',
   'Docs/phases/10_matching_engine/fixtures/split_payment_two_invoices_same_supplier/'),
  ('split_payment_three_invoices_mixed_suppliers', 'OUT', 'SPLIT_PAYMENT',
   'Lower-confidence three-invoice split mixed suppliers; still surfaces.',
   'Docs/phases/10_matching_engine/fixtures/split_payment_three_invoices_mixed_suppliers/'),
  ('split_payment_candidate_set_truncation', 'OUT', 'SPLIT_PAYMENT',
   '30 candidates → narrowing to 20 → top 3 surfaced.',
   'Docs/phases/10_matching_engine/fixtures/split_payment_candidate_set_truncation/'),

  -- DUPLICATE_DETECTION (3)
  ('duplicate_pattern_a_one_doc_many_txns', 'OUT', 'DUPLICATE_DETECTION',
   'Pattern A raised: one document referenced by many unrelated transactions.',
   'Docs/phases/10_matching_engine/fixtures/duplicate_pattern_a_one_doc_many_txns/'),
  ('duplicate_pattern_b_one_txn_many_docs', 'OUT', 'DUPLICATE_DETECTION',
   'Pattern B raised: one transaction matched to many unrelated documents.',
   'Docs/phases/10_matching_engine/fixtures/duplicate_pattern_b_one_txn_many_docs/'),
  ('confirmed_split_payment_no_pattern_a', 'OUT', 'DUPLICATE_DETECTION',
   'Confirmed split-payment group does NOT raise Pattern A (suppression check).',
   'Docs/phases/10_matching_engine/fixtures/confirmed_split_payment_no_pattern_a/'),

  -- REJECTION_MEMORY (3)
  ('rejection_suppression', 'OUT', 'REJECTION_MEMORY',
   'Pair previously rejected; second run skips it; MATCHING_REJECTION_SUPPRESSED emitted.',
   'Docs/phases/10_matching_engine/fixtures/rejection_suppression/'),
  ('rejection_pair_scoped', 'OUT', 'REJECTION_MEMORY',
   '(txn1, doc1) rejected; (txn1, doc2) and (txn2, doc1) still scored.',
   'Docs/phases/10_matching_engine/fixtures/rejection_pair_scoped/'),
  ('rejection_privileged_override', 'OUT', 'REJECTION_MEMORY',
   'Owner privileged override removes memory row; step-up required; Admin denied.',
   'Docs/phases/10_matching_engine/fixtures/rejection_privileged_override/'),

  -- IN_OUTCOMES (7)
  ('in_full_match', 'IN', 'IN_OUTCOMES',
   'Exact amount + invoice number → auto-confirm; invoice → PAID.',
   'Docs/phases/10_matching_engine/fixtures/in_full_match/'),
  ('in_partial_payment', 'IN', 'IN_OUTCOMES',
   'Amount < total → PARTIALLY_PAID on user confirm.',
   'Docs/phases/10_matching_engine/fixtures/in_partial_payment/'),
  ('in_overpayment', 'IN', 'IN_OUTCOMES',
   'Amount > total → OVERPAID + credit-note review issue.',
   'Docs/phases/10_matching_engine/fixtures/in_overpayment/'),
  ('in_multiple_invoices_one_payment', 'IN', 'IN_OUTCOMES',
   'Never silently allocated (Stage 1); user confirmation in review queue.',
   'Docs/phases/10_matching_engine/fixtures/in_multiple_invoices_one_payment/'),
  ('in_one_invoice_multiple_payments', 'IN', 'IN_OUTCOMES',
   'Running-total accumulation; PAID only when total reaches invoice amount.',
   'Docs/phases/10_matching_engine/fixtures/in_one_invoice_multiple_payments/'),
  ('in_possible_refund_or_transfer', 'IN', 'IN_OUTCOMES',
   'Incoming matches prior outgoing → reclassification suggestion.',
   'Docs/phases/10_matching_engine/fixtures/in_possible_refund_or_transfer/'),
  ('in_pro_forma_filtered_out', 'IN', 'IN_OUTCOMES',
   'Pro-forma invoice not used as candidate.',
   'Docs/phases/10_matching_engine/fixtures/in_pro_forma_filtered_out/'),

  -- REASON_GENERATION (3)
  ('reason_level_1_simple', 'OUT', 'REASON_GENERATION',
   'Tier 2 produces concise reason for Level 1 match.',
   'Docs/phases/10_matching_engine/fixtures/reason_level_1_simple/'),
  ('reason_cross_currency', 'OUT', 'REASON_GENERATION',
   'Tier 3 explicitly invoked because of cross-currency complexity.',
   'Docs/phases/10_matching_engine/fixtures/reason_cross_currency/'),
  ('reason_cross_period', 'OUT', 'REASON_GENERATION',
   'Tier 3 invoked to explain time gap between transaction and invoice.',
   'Docs/phases/10_matching_engine/fixtures/reason_cross_period/');


-- 4. RPCs -------------------------------------------------------------------

-- 4.1 register_matching_fixture (idempotent)
CREATE OR REPLACE FUNCTION public.register_matching_fixture(
  p_fixture_name text,
  p_side         text,
  p_category     text,
  p_description  text,
  p_fixture_path text,
  p_actor_user_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.matching_fixtures
    (fixture_name, side, category, description, fixture_path, created_by)
  VALUES
    (p_fixture_name, p_side, p_category, p_description, p_fixture_path, p_actor_user_id)
  ON CONFLICT (fixture_name) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.matching_fixtures WHERE fixture_name = p_fixture_name;
  END IF;
  RETURN v_id;
END;
$$;

-- 4.2 record_matching_fixture_run_started
CREATE OR REPLACE FUNCTION public.record_matching_fixture_run_started(
  p_fixture_id   uuid,
  p_triggered_by text,
  p_context      jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.matching_fixtures WHERE id = p_fixture_id) THEN
    RAISE EXCEPTION 'FIXTURE_NOT_FOUND' USING errcode='check_violation';
  END IF;

  INSERT INTO public.matching_fixture_runs (fixture_id, triggered_by)
  VALUES (p_fixture_id, p_triggered_by)
  RETURNING id INTO v_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_FIXTURE_RAN',
    p_subject_type:='MATCHING_FIXTURE'::audit.subject_type_enum,
    p_subject_id:=p_fixture_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_fixture_runner',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('run_id', v_run_id, 'triggered_by', p_triggered_by),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN v_run_id;
END;
$$;

-- 4.3 record_matching_fixture_run_passed
CREATE OR REPLACE FUNCTION public.record_matching_fixture_run_passed(
  p_run_id               uuid,
  p_actual_results_hash  text,
  p_expected_results_hash text,
  p_duration_ms          int,
  p_context              jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_fixture_id uuid;
BEGIN
  IF p_duration_ms IS NULL OR p_duration_ms < 0 THEN
    RAISE EXCEPTION 'DURATION_MUST_BE_NONNEG' USING errcode='check_violation';
  END IF;

  UPDATE public.matching_fixture_runs
    SET status='PASSED',
        actual_results_hash=p_actual_results_hash,
        expected_results_hash=p_expected_results_hash,
        duration_ms=p_duration_ms,
        run_completed_at=clock_timestamp()
  WHERE id = p_run_id
  RETURNING fixture_id INTO v_fixture_id;

  IF v_fixture_id IS NULL THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_FIXTURE_PASSED',
    p_subject_type:='MATCHING_FIXTURE'::audit.subject_type_enum,
    p_subject_id:=v_fixture_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_fixture_runner',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('run_id', p_run_id, 'duration_ms', p_duration_ms,
                                       'actual_hash', p_actual_results_hash,
                                       'expected_hash', p_expected_results_hash),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object('decision','RECORDED','run_id',p_run_id,'fixture_id',v_fixture_id,'status','PASSED');
END;
$$;

-- 4.4 record_matching_fixture_run_failed
CREATE OR REPLACE FUNCTION public.record_matching_fixture_run_failed(
  p_run_id               uuid,
  p_actual_results_hash  text,
  p_expected_results_hash text,
  p_diff_summary         jsonb,
  p_duration_ms          int,
  p_context              jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_fixture_id    uuid;
  v_fixture_name  text;
  v_triggered_by  text;
BEGIN
  IF p_duration_ms IS NULL OR p_duration_ms < 0 THEN
    RAISE EXCEPTION 'DURATION_MUST_BE_NONNEG' USING errcode='check_violation';
  END IF;
  IF p_diff_summary IS NULL OR jsonb_typeof(p_diff_summary) <> 'object' THEN
    RAISE EXCEPTION 'DIFF_SUMMARY_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;

  UPDATE public.matching_fixture_runs
    SET status='FAILED',
        actual_results_hash=p_actual_results_hash,
        expected_results_hash=p_expected_results_hash,
        diff_summary=p_diff_summary,
        duration_ms=p_duration_ms,
        run_completed_at=clock_timestamp()
  WHERE id = p_run_id
  RETURNING fixture_id, triggered_by INTO v_fixture_id, v_triggered_by;

  IF v_fixture_id IS NULL THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  SELECT fixture_name INTO v_fixture_name FROM public.matching_fixtures WHERE id = v_fixture_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_FIXTURE_FAILED',
    p_subject_type:='MATCHING_FIXTURE'::audit.subject_type_enum,
    p_subject_id:=v_fixture_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_fixture_runner',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('run_id', p_run_id, 'duration_ms', p_duration_ms,
                                       'fixture_name', v_fixture_name,
                                       'triggered_by', v_triggered_by,
                                       'diff_summary', p_diff_summary,
                                       'actual_hash', p_actual_results_hash,
                                       'expected_hash', p_expected_results_hash),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object('decision','RECORDED','run_id',p_run_id,'fixture_id',v_fixture_id,
                            'fixture_name',v_fixture_name,'status','FAILED');
END;
$$;


-- 5. Privileges -------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.register_matching_fixture(text, text, text, text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_matching_fixture_run_started(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_matching_fixture_run_passed(uuid, text, text, int, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_matching_fixture_run_failed(uuid, text, text, jsonb, int, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.register_matching_fixture(text, text, text, text, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_matching_fixture_run_started(uuid, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_matching_fixture_run_passed(uuid, text, text, int, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_matching_fixture_run_failed(uuid, text, text, jsonb, int, jsonb) TO authenticated, service_role;

COMMIT;
