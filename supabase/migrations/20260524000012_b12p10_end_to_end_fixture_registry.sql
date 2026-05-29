-- B12·P10 — End-to-End OUT Workflow Fixture Registry
-- =====================================================================
-- DB-side fixture catalogue for OUT_MONTHLY + OUT_ADJUSTMENT regression
-- coverage. Follows the Block 10/11 P10 precedent (matching/ledger fixture
-- registries) — schema + seed lives in the DB; the actual fixture-runner
-- executor lives in Block 03's app-layer engine (TS) and is wired up by
-- a separate Phase 4 sub-doc effort.
--
-- 3 audit actions:
--   OUT_WORKFLOW_FIXTURE_RAN     (every run_fixture invocation)
--   OUT_WORKFLOW_FIXTURE_PASSED  (app-layer runner emits)
--   OUT_WORKFLOW_FIXTURE_FAILED  (app-layer runner emits)
-- =====================================================================

BEGIN;

CREATE TABLE public.out_workflow_fixture_registry (
  id                        uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_name              text NOT NULL UNIQUE,
  category                  text NOT NULL,
  description               text NOT NULL,
  workflow_type             public.workflow_type_enum NOT NULL,
  expected_terminal_state   public.workflow_run_status_enum,
  expected_audit_actions    text[]  NOT NULL DEFAULT '{}',
  covers_phase_names        text[]  NOT NULL DEFAULT '{}',
  covers_invariants         text[]  NOT NULL DEFAULT '{}',
  fixture_paths             jsonb   NOT NULL DEFAULT '{}'::jsonb,
  notes                     text,
  created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT out_workflow_fixture_registry_category_chk CHECK (
    category IN ('clean_monthly','manual_upload_hold','human_review_hold',
                 'config_short_circuit','paired_out_in','triggers',
                 'adjustment','failure_mode')),
  CONSTRAINT out_workflow_fixture_registry_paths_chk CHECK (
    fixture_paths <> '{}'::jsonb),
  CONSTRAINT out_workflow_fixture_registry_audits_chk CHECK (
    array_length(expected_audit_actions, 1) >= 1)
);
CREATE INDEX out_workflow_fixture_registry_category_idx
  ON public.out_workflow_fixture_registry (category);

COMMENT ON TABLE public.out_workflow_fixture_registry IS
  'B12·P10 fixture catalogue: every OUT regression fixture has one row pinning the expected audit actions, run-state terminus, invariants covered, and the JSON file paths the app-layer runner loads.';


-- list_out_workflow_fixtures(category) -> SETOF rows
CREATE OR REPLACE FUNCTION public.list_out_workflow_fixtures(p_category text DEFAULT NULL)
RETURNS SETOF public.out_workflow_fixture_registry LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT * FROM public.out_workflow_fixture_registry
   WHERE p_category IS NULL OR category = p_category
   ORDER BY category, fixture_name;
$$;
REVOKE EXECUTE ON FUNCTION public.list_out_workflow_fixtures(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.list_out_workflow_fixtures(text) TO service_role, authenticated;


-- Stub runner — real runtime executor lives in Block 03's app-layer engine
CREATE OR REPLACE FUNCTION public.out_workflow_run_fixture(
  p_fixture_name text,
  p_organization_id uuid DEFAULT NULL,
  p_actor_user_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_row public.out_workflow_fixture_registry%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.out_workflow_fixture_registry
   WHERE fixture_name = p_fixture_name;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.run_fixture: unknown fixture %', p_fixture_name USING ERRCODE='02000';
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_WORKFLOW_FIXTURE_RAN',
    p_subject_type:='BUSINESS'::audit.subject_type_enum,
    p_subject_id:=COALESCE(p_organization_id, v_row.id),
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_fixture_runner',
    p_organization_id:=p_organization_id, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'fixture_name', v_row.fixture_name,
      'category', v_row.category,
      'workflow_type', v_row.workflow_type::text,
      'expected_terminal_state', v_row.expected_terminal_state::text,
      'covers_invariants', v_row.covers_invariants,
      'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'status','PENDING_IMPLEMENTATION',
    'reason','runtime executor lives in Block 03 app-layer engine (TS); DB-side stub records the audit only',
    'fixture_name', v_row.fixture_name,
    'category', v_row.category,
    'workflow_type', v_row.workflow_type::text,
    'expected_terminal_state', v_row.expected_terminal_state::text,
    'expected_audit_actions', v_row.expected_audit_actions);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_run_fixture(text,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_run_fixture(text,uuid,uuid,jsonb) TO service_role;


-- Seed: 31 fixtures across 8 categories (spec exact enumeration)

-- CLEAN MONTHLY (1)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES (
  'out_monthly_clean_happy_path', 'clean_monthly',
  '50 OUT-side txns mixed types, all matched cleanly, no issues, user approves, run finalizes',
  'OUT_MONTHLY', 'FINALIZED',
  ARRAY['OUT_WORKFLOW_RUN_STARTED_MANUALLY','OUT_GATE_EVALUATED','OUT_HUMAN_REVIEW_HOLD_ENTERED','OUT_HUMAN_REVIEW_APPROVAL_RECORDED','OUT_HUMAN_REVIEW_HOLD_CLEARED'],
  ARRAY['INGESTION','CLASSIFICATION','OUT_FILTER','EVIDENCE_DISCOVERY_EMAIL','EVIDENCE_DISCOVERY_DRIVE','MATCHING','LEDGER_PREPARATION','AI_END_SCAN','HUMAN_REVIEW_HOLD','FINALIZATION'],
  ARRAY['STATE_MACHINE_CREATED_RUNNING_AWAITING_APPROVAL_FINALIZING_FINALIZED','NO_SIDE_PHASES_ENTERED'],
  jsonb_build_object('input', ARRAY['business_state.json','input_statement_upload.json','input_documents.json','recorded_ai_responses.json'],
                     'expected', ARRAY['expected_workflow_run_state_machine.json','expected_phase_outputs.json','expected_archive_bundle_manifest.json']));

-- MANUAL_UPLOAD_HOLD (6)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state, expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('out_monthly_held_unmatched_evidence','manual_upload_hold',
 '3 OUT_EXPENSE rows with NO_MATCH; run enters MANUAL_UPLOAD_HOLD; verify ROUTE_TO_SIDE_PHASE',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_GATE_ROUTED_TO_SIDE_PHASE','OUT_MANUAL_UPLOAD_HOLD_ENTERED'],
 ARRAY['MATCHING','MANUAL_UPLOAD_HOLD'],
 ARRAY['ROUTE_ON_NO_MATCH','REVIEW_HOLD_RUN_STATE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_documents.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_manual_upload_resolves_hold','manual_upload_hold',
 'User invokes upload_invoice for each held row; matcher runs; gate clears; run resumes',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_MANUAL_UPLOAD_INVOICE_UPLOADED','OUT_MANUAL_UPLOAD_HOLD_CLEARED'],
 ARRAY['MANUAL_UPLOAD_HOLD','LEDGER_PREPARATION'],
 ARRAY['UPLOAD_FLIPS_MATCH_STATUS','GATE_CLEARS_AFTER_RESOLUTION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_documents.json','input_user_uploads.json'],'expected',ARRAY['expected_phase_outputs.json','expected_archive_bundle_manifest.json'])),
('out_monthly_exception_documented_resolves_hold','manual_upload_hold',
 'User invokes document_exception with reason; match_status=EXCEPTION_DOCUMENTED; gate clears',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED','OUT_MANUAL_UPLOAD_HOLD_CLEARED'],
 ARRAY['MANUAL_UPLOAD_HOLD','LEDGER_PREPARATION'],
 ARRAY['EXCEPTION_FLIPS_MATCH_STATUS','REASON_MANDATORY'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_documents.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_reminder_fires_after_seven_days','manual_upload_hold',
 'Held run + 7d simulated clock advance fires reminder ordinal=1; +7d more fires ordinal=2; no auto-action',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_MANUAL_UPLOAD_REMINDER_SENT'],
 ARRAY['MANUAL_UPLOAD_HOLD'],
 ARRAY['ENTRY_ANCHORED_CADENCE','NO_AUTO_ACTION','ORDINAL_MONOTONIC'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_clock_advances.json'],'expected',ARRAY['expected_reminder_log.json'])),
('out_monthly_reminder_suppressed_when_disabled','manual_upload_hold',
 'manual_upload_hold_reminder_enabled=false; +30d clock advance; zero reminders fire',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_MANUAL_UPLOAD_REMINDER_SENT'],
 ARRAY['MANUAL_UPLOAD_HOLD'],
 ARRAY['REMINDER_SUPPRESSION_HONORS_CONFIG'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_clock_advances.json'],'expected',ARRAY['expected_reminder_log.json'])),
('out_monthly_re_enters_manual_upload_hold_after_recompute','manual_upload_hold',
 'Hold cleared; downstream recompute discovers new NO_MATCH; re-routes; cadence resets from re-entry',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_MANUAL_UPLOAD_HOLD_CLEARED','OUT_MANUAL_UPLOAD_HOLD_RE_ENTERED'],
 ARRAY['MANUAL_UPLOAD_HOLD','LEDGER_PREPARATION'],
 ARRAY['RE_ENTRY_RESETS_CADENCE','DELETES_PRIOR_REMINDERS'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_chart_change.json'],'expected',ARRAY['expected_reminder_log.json']));

-- HUMAN_REVIEW_HOLD (6)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state, expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('out_monthly_held_blocking_high_issue','human_review_hold',
 'AI_END_SCAN produces 1 HIGH issue in Possible Tax/VAT Issue bucket; enters HUMAN_REVIEW_HOLD',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_GATE_ROUTED_TO_SIDE_PHASE','OUT_HUMAN_REVIEW_HOLD_ENTERED'],
 ARRAY['AI_END_SCAN','HUMAN_REVIEW_HOLD'],
 ARRAY['ROUTE_ON_HIGH_ISSUE','AWAITING_APPROVAL_RUN_STATE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_user_resolves_and_approves','human_review_hold',
 'User resolves issue + records approval; gate clears; run finalizes',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_HUMAN_REVIEW_APPROVAL_RECORDED','OUT_HUMAN_REVIEW_HOLD_CLEARED'],
 ARRAY['HUMAN_REVIEW_HOLD','FINALIZATION'],
 ARRAY['APPROVAL_REQUIRED','GATE_DUAL_CONDITION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json','expected_archive_bundle_manifest.json'])),
('out_monthly_approval_required_even_with_no_issues','human_review_hold',
 'Zero issues; run still enters HUMAN_REVIEW_HOLD; user approves; finalizes',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_HUMAN_REVIEW_HOLD_ENTERED','OUT_HUMAN_REVIEW_APPROVAL_RECORDED','OUT_HUMAN_REVIEW_HOLD_CLEARED'],
 ARRAY['HUMAN_REVIEW_HOLD','FINALIZATION'],
 ARRAY['APPROVAL_ALWAYS_REQUIRED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_approval_revoked_re_holds','human_review_hold',
 'User approves then revokes; gate flips back to HOLD; run remains AWAITING_APPROVAL',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_HUMAN_REVIEW_APPROVAL_RECORDED','OUT_HUMAN_REVIEW_APPROVAL_REVOKED'],
 ARRAY['HUMAN_REVIEW_HOLD'],
 ARRAY['REVOKE_REOPENS_GATE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_new_blocking_issue_post_approval_stales_approval','human_review_hold',
 'User approves; AI_END_SCAN rerun produces new HIGH issue; STALENESS fires; gate flips to HOLD',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_HUMAN_REVIEW_APPROVAL_RECORDED','OUT_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED'],
 ARRAY['HUMAN_REVIEW_HOLD','AI_END_SCAN'],
 ARRAY['STALENESS_DETECTION','APPROVAL_NOT_AUTO_REVOKED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_reclassification.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_approval_denied_for_accountant','human_review_hold',
 'Accountant role attempts approval; denied via WORKFLOW_APPROVE permission check',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_HUMAN_REVIEW_HOLD_ENTERED'],
 ARRAY['HUMAN_REVIEW_HOLD'],
 ARRAY['PERMISSION_GATE_HONORED','DENIED_ENVELOPE_RETURNED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_role_assignments.json'],'expected',ARRAY['expected_phase_outputs.json']));

-- CONFIG_SHORT_CIRCUIT (3)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state, expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('out_monthly_email_finder_disabled','config_short_circuit',
 'evidence_discovery_email_enabled=false; EVIDENCE_DISCOVERY_EMAIL entered + immediately skipped',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG'],
 ARRAY['EVIDENCE_DISCOVERY_EMAIL'],
 ARRAY['CONFIG_SHORT_CIRCUIT','DRIVE_AND_MANUAL_STILL_RUN'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_out_config.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_drive_finder_disabled','config_short_circuit',
 'evidence_discovery_drive_enabled=false; same shape as email-disabled',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG'],
 ARRAY['EVIDENCE_DISCOVERY_DRIVE'],
 ARRAY['CONFIG_SHORT_CIRCUIT'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_out_config.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('out_monthly_auto_start_disabled','config_short_circuit',
 'Statement Upload event fires; auto_start=false → suppressed; user manual start creates run normally',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_WORKFLOW_AUTO_START_SUPPRESSED','OUT_WORKFLOW_RUN_STARTED_MANUALLY'],
 ARRAY['INGESTION'],
 ARRAY['SUPPRESSION_HONORS_CONFIG','MANUAL_FALLBACK'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_out_config.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json']));

-- PAIRED_OUT_IN (3)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state, expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('paired_out_in_clean_run','paired_out_in',
 'Single Statement Upload triggers both OUT_MONTHLY + IN_MONTHLY; INGESTION fires once; paired linkage on both',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_WORKFLOW_PAIRED_RUN_LINKED','OUT_WORKFLOW_SHARED_PHASE_DEDUP_APPLIED'],
 ARRAY['INGESTION','CLASSIFICATION'],
 ARRAY['PAIRED_RUN_LINKAGE','SHARED_PHASE_DEDUP'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_documents.json','input_invoices.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('paired_out_in_internal_transfer_dedup','paired_out_in',
 'INTERNAL_TRANSFER txn; both runs reach LEDGER_PREPARATION; exactly 1 PRIMARY dle row across both',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_FILTER_INCLUDED_TRANSACTION'],
 ARRAY['OUT_FILTER','LEDGER_PREPARATION'],
 ARRAY['INTERNAL_TRANSFER_DEDUP','BOTH_FILTERS_INCLUDE','BLOCK11_DISPATCHER_DEDUPES'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_internal_transfer_fixture.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('paired_out_finalizes_before_in','paired_out_in',
 'OUT finalizes while IN held in MANUAL_UPLOAD_HOLD; OUT FINALIZATION succeeds independently',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_HUMAN_REVIEW_HOLD_CLEARED'],
 ARRAY['FINALIZATION'],
 ARRAY['NO_CROSS_RUN_GATE','INDEPENDENT_FINALIZATION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_documents.json'],'expected',ARRAY['expected_phase_outputs.json']));

-- TRIGGERS (4)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state, expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('manual_trigger_duplicate_rejected','triggers',
 'User manually starts; while first RUNNING, second start same period → REJECTED ALREADY_ACTIVE',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_WORKFLOW_RUN_STARTED_MANUALLY','OUT_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED'],
 ARRAY['INGESTION'],
 ARRAY['ACTIVE_RUN_DEDUP'],
 jsonb_build_object('input',ARRAY['business_state.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('event_trigger_dedup_on_duplicate_event','triggers',
 'Same STATEMENT_UPLOAD_COMPLETED event arrives twice; only 1 run created; DEDUPLICATED fires',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_WORKFLOW_RUN_STARTED_BY_EVENT','OUT_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED'],
 ARRAY['INGESTION'],
 ARRAY['EVENT_REPLAY_DEDUP'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_event_replay.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('manual_trigger_for_finalized_period_rejected','triggers',
 'User attempts manual start for finalized period; REJECTED_PERIOD_FINALIZED',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED'],
 ARRAY['INGESTION'],
 ARRAY['PERIOD_FINALIZED_BLOCKS_RESTART'],
 jsonb_build_object('input',ARRAY['business_state.json','input_user_actions.json','input_prior_finalized_run.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('manual_trigger_denied_for_read_only','triggers',
 'Read-only role attempts start; denied via WORKFLOW_TRIGGER permission',
 'OUT_MONTHLY', NULL,
 ARRAY['OUT_WORKFLOW_RUN_STARTED_MANUALLY'],
 ARRAY['INGESTION'],
 ARRAY['PERMISSION_GATE_HONORED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_user_actions.json','input_role_assignments.json'],'expected',ARRAY['expected_phase_outputs.json']));

-- ADJUSTMENT (5)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state, expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('adjustment_clean_path','adjustment',
 'CORRECT_VAT_TREATMENT against finalized period; 5-phase ADJUSTMENT runs to completion',
 'OUT_ADJUSTMENT','FINALIZED',
 ARRAY['OUT_ADJUSTMENT_RUN_CREATED','OUT_ADJUSTMENT_INTAKE_COMPLETED','OUT_ADJUSTMENT_INTERLEAVED_INTO_ARCHIVE'],
 ARRAY['ADJUSTMENT_INTAKE','ADJUSTMENT_LEDGER_PREP','ADJUSTMENT_AI_REVIEW','ADJUSTMENT_HUMAN_REVIEW','ADJUSTMENT_FINALIZATION'],
 ARRAY['DELTA_KIND_VALIDATED','REASON_MANDATORY','ADDITIVE_INTERLEAVE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json','expected_archive_bundle_manifest.json'])),
('adjustment_does_not_modify_original_entries','adjustment',
 'Hash-compare: original LOCKED draft_ledger_entries identical before/after adjustment',
 'OUT_ADJUSTMENT','FINALIZED',
 ARRAY['OUT_ADJUSTMENT_RUN_CREATED','OUT_ADJUSTMENT_INTERLEAVED_INTO_ARCHIVE'],
 ARRAY['ADJUSTMENT_LEDGER_PREP','ADJUSTMENT_FINALIZATION'],
 ARRAY['ADDITIVE_ONLY','ORIGINAL_LOCKED_HASH_UNCHANGED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json'],'expected',ARRAY['expected_phase_outputs.json','expected_original_hash_unchanged.json'])),
('adjustment_concurrent_with_monthly_run','adjustment',
 'OUT_ADJUSTMENT for period 1 + OUT_MONTHLY for period 3 active simultaneously; both progress',
 'OUT_ADJUSTMENT','FINALIZED',
 ARRAY['OUT_ADJUSTMENT_RUN_CREATED','OUT_WORKFLOW_RUN_STARTED_MANUALLY'],
 ARRAY['ADJUSTMENT_INTAKE','INGESTION'],
 ARRAY['CONCURRENCY_PER_TYPE_PERIOD','BOTH_RUN_IDS_TRACEABLE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_statement_upload.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('adjustment_rejected_for_retention_expired','adjustment',
 'Attempt adjustment on 7-year-old period; REJECTED_RETENTION_EXPIRED',
 'OUT_ADJUSTMENT', NULL,
 ARRAY['OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED'],
 ARRAY['ADJUSTMENT_INTAKE'],
 ARRAY['SIX_YEAR_RETENTION_CAP'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('adjustment_rejected_for_unfinalized_parent','adjustment',
 'Attempt adjustment against RUNNING parent; REJECTED_PARENT_NOT_FINALIZED',
 'OUT_ADJUSTMENT', NULL,
 ARRAY['OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED'],
 ARRAY['ADJUSTMENT_INTAKE'],
 ARRAY['PARENT_MUST_BE_FINALIZED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json']));

-- FAILURE_MODE (3)
INSERT INTO public.out_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state, expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('transient_failure_retry_then_success','failure_mode',
 'Email finder times out twice then succeeds; bounded retries; run continues without holding',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_GATE_EVALUATED'],
 ARRAY['EVIDENCE_DISCOVERY_EMAIL'],
 ARRAY['BOUNDED_RETRY_PATTERN','NO_HOLD_ON_TRANSIENT'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json','input_transient_failures.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('permanent_failure_holds_phase','failure_mode',
 'Persistent OCR failure raises HIGH review issue; LEDGER_PHASE_HOLDING fires; user resolves manually',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_GATE_EVALUATED'],
 ARRAY['LEDGER_PREPARATION'],
 ARRAY['PERMANENT_FAILURE_HOLDS','MANUAL_RECOVERY'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_permanent_failures.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('crash_mid_phase_resumes','failure_mode',
 'Crash during MATCHING; engine resumes from last persisted phase boundary; idempotency prevents double-writes',
 'OUT_MONTHLY','FINALIZED',
 ARRAY['OUT_GATE_EVALUATED'],
 ARRAY['MATCHING'],
 ARRAY['CRASH_RECOVERY','IDEMPOTENCY_KEY_PROTECTION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_crash_point.json'],'expected',ARRAY['expected_phase_outputs.json']));

COMMIT;
