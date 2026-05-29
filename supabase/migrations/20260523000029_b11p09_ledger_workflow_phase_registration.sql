-- B11·P09 — LEDGER_DRAFT Workflow Phase Registration
-- =====================================================================
-- Wires Block 11 phases P04-P08 + the AI explanation tool into the workflow
-- engine. Per B09·P09 / B10·P09 / B11·P01 naming-alignment precedent:
--   * Spec name: LEDGER_PREPARATION
--   * DB name (existing): LEDGER_DRAFT (OUT_MONTHLY phase_order=8 + IN_MONTHLY=8)
--   * Aligned with DB; audit family stays LEDGER_PHASE_* per spec.
--
-- Deliverables:
--   * 7 tool seeds (3 READ_ONLY proposers, 3 WRITES_RUN_STATE deterministic,
--     1 WRITES_RUN_STATE + EXTERNAL_LLM RETRYABLE for the AI explanation)
--   * 2 gate seeds (entry + exit)
--   * 14 phase_tool_expectations rows (7 tools × 2 workflow types)
--   * 4 phase_gate_assignments rows (ENTRY+EXIT × OUT+IN)
--   * STABLE evaluate_ledger_exit_gate (covers transactions w/ ≥1 draft entry
--     OR a LEDGER_HELD_PENDING_CLASSIFICATION audit for the run)
--   * 3 phase-event RPCs: record_ledger_phase_started / _completed / _holding
--     emitting LEDGER_PHASE_STARTED / _COMPLETED / _HOLDING
--
-- In-memory pipeline (per spec): steps 1-3 are READ_ONLY proposers that
-- compute in-memory results consumed by step 4 (ledger.prepare_entries),
-- which is the single writer for draft_ledger_entries rows. Steps 5-6
-- enrich the persisted rows in-place; step 7 (AI explanations) runs once
-- per batch after the per-transaction loop.
-- =====================================================================

BEGIN;

-- 1. Tool seeds (7) -------------------------------------------------------
SELECT public.register_tool(
  p_tool_name=>'ledger.resolve_counterparty', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('workflow_run_id','uuid','transaction_id','uuid','match_record_id','uuid|null','doc_country','text|null','doc_vat_number','text|null','doc_extraction_layer','text|null','iban_country_candidate','char(2)|null'),
  p_output_schema=>jsonb_build_object('counterparty_country','char(2)|null','counterparty_vat_number','text|null','source','text','confidence','text','evidence_pointer','jsonb','review_issue_ids','jsonb','writeback_applied','bool'),
  p_side_effect=>'READ_ONLY'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'ledger.resolve_counterparty.dedup_key_v1',
  p_description=>'P04 resolver — proposer pattern (in-memory result; persisted later by ledger.prepare_entries)',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'ledger.classify_vat', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('workflow_run_id','uuid','draft_ledger_entry_id','uuid'),
  p_output_schema=>jsonb_build_object('treatment','vat_treatment_enum','decided_by_rule_id','text','supporting_signals','jsonb','requires_accountant_review','bool','accountant_review_reason','text|null'),
  p_side_effect=>'READ_ONLY'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'ledger.classify_vat.dedup_key_v1',
  p_description=>'P05 VAT classifier — rules-only, deterministic; AI never invoked here (Principle 3)',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'ledger.compute_reverse_charge_vies', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('workflow_run_id','uuid','draft_ledger_entry_id','uuid'),
  p_output_schema=>jsonb_build_object('reverse_charge_relevant','bool','vies_relevant','bool','vies_period','text|null','supporting_signals','jsonb'),
  p_side_effect=>'READ_ONLY'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'ledger.compute_reverse_charge_vies.dedup_key_v1',
  p_description=>'P06 reverse-charge + VIES booleans (in-memory; persisted later)',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'ledger.prepare_entries', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('workflow_run_id','uuid','transaction_id','uuid','match_record_id','uuid|null','input_vat_reclaimable','bool','output_vat_due','bool','vat_amount','numeric|null','entry_period','date|null'),
  p_output_schema=>jsonb_build_object('decision','text','entries_created','int','entries_replaced','int','primary_count','int','derived_count','int','mapping_version_id','uuid'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'ledger.prepare_entries.dedup_key_v1',
  p_description=>'P07 dispatcher — single creator of draft_ledger_entries; delete-and-replace per (txn, version) ensures idempotency',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'ledger.compute_vat_and_evidence_flags', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('workflow_run_id','uuid','draft_ledger_entry_id','uuid','document_extracted_vat_amount','numeric|null','matched_evidence_kind','text|null'),
  p_output_schema=>jsonb_build_object('input_vat_reclaimable_flag','bool','input_vat_reclaimable_amount','numeric','output_vat_due_flag','bool','output_vat_due_amount','numeric','vies_value_basis_eur','numeric|null','requires_invoice','bool','requires_receipt','bool','requires_contract','bool','requires_accountant_review','bool'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'ledger.compute_vat_and_evidence_flags.dedup_key_v1',
  p_description=>'P08 VAT amount calculator + evidence flag setter; placement rules avoid double-counting across PRIMARY/derived rows',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'ledger.flag_for_review', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('workflow_run_id','uuid','draft_ledger_entry_id','uuid'),
  p_output_schema=>jsonb_build_object('requires_accountant_review','bool','review_issue_ids','jsonb'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'ledger.flag_for_review.dedup_key_v1',
  p_description=>'P08 accountant-review-flag pass + review-issue producer (POSSIBLE_TAX_VAT_ISSUE + MISSING_DOCUMENTS buckets)',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'ledger.generate_vat_explanations', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('workflow_run_id','uuid','draft_ledger_entry_ids','uuid[]'),
  p_output_schema=>jsonb_build_object('generated_count','int','fallback_count','int'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'EXTERNAL_LLM'::ai_tier_enum,
  p_failure_semantics=>'RETRYABLE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'ledger.generate_vat_explanations.dedup_key_v1',
  p_description=>'Block 06 P10 plain-language pipeline (Tier 2 default, Tier 3 escalation); deterministic fallback on AI failure',
  p_retry_max_attempts=>3, p_retry_backoff_base_ms=>1000, p_retry_backoff_max_ms=>10000);


-- 2. Gate seeds (2) -------------------------------------------------------
SELECT public.register_gate('ledger.entry_matching_and_classification_complete_v1','1.0.0',
  'Entry: MATCH (OUT) / INCOME_MATCHING (IN) and CLASSIFY phases done; every transaction in scope has match_status');
SELECT public.register_gate('ledger.exit_all_in_scope_entries_drafted_or_held_v1','1.0.0',
  'Exit: every in-scope transaction has at least 1 draft_ledger_entries row OR a LEDGER_HELD_PENDING_CLASSIFICATION audit for the run');


-- 3. phase_tool_expectations ----------------------------------------------
INSERT INTO public.phase_tool_expectations (workflow_type, phase_name, tool_name, permitted_side_effects, required)
VALUES
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.resolve_counterparty',           ARRAY['READ_ONLY']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.classify_vat',                   ARRAY['READ_ONLY']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.compute_reverse_charge_vies',    ARRAY['READ_ONLY']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.prepare_entries',                ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.compute_vat_and_evidence_flags', ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.flag_for_review',                ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.generate_vat_explanations',      ARRAY['WRITES_RUN_STATE','CALLS_EXTERNAL_API']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.resolve_counterparty',           ARRAY['READ_ONLY']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.classify_vat',                   ARRAY['READ_ONLY']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.compute_reverse_charge_vies',    ARRAY['READ_ONLY']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.prepare_entries',                ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.compute_vat_and_evidence_flags', ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.flag_for_review',                ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.generate_vat_explanations',      ARRAY['WRITES_RUN_STATE','CALLS_EXTERNAL_API']::public.side_effect_class_enum[], true)
ON CONFLICT DO NOTHING;


-- 4. phase_gate_assignments -----------------------------------------------
INSERT INTO public.phase_gate_assignments (workflow_type, phase_name, gate_name, kind, eval_order)
VALUES
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.entry_matching_and_classification_complete_v1','ENTRY',1),
  ('OUT_MONTHLY','LEDGER_DRAFT','ledger.exit_all_in_scope_entries_drafted_or_held_v1','EXIT',1),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.entry_matching_and_classification_complete_v1','ENTRY',1),
  ('IN_MONTHLY', 'LEDGER_DRAFT','ledger.exit_all_in_scope_entries_drafted_or_held_v1','EXIT',1)
ON CONFLICT DO NOTHING;


-- 5. STABLE exit gate evaluator -------------------------------------------
CREATE OR REPLACE FUNCTION public.evaluate_ledger_exit_gate(p_workflow_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_business_id uuid; v_period_start timestamptz; v_period_end timestamptz;
  v_total_txns int; v_drafted_or_held int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_business_id, v_period_start, v_period_end
    FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  SELECT count(*) INTO v_total_txns FROM public.transactions
   WHERE business_id = v_business_id
     AND transaction_date BETWEEN v_period_start::date AND v_period_end::date;

  SELECT count(DISTINCT t.id) INTO v_drafted_or_held
    FROM public.transactions t
   WHERE t.business_id = v_business_id
     AND t.transaction_date BETWEEN v_period_start::date AND v_period_end::date
     AND (
       EXISTS (SELECT 1 FROM public.draft_ledger_entries d
                 WHERE d.parent_transaction_id = t.id)
       OR EXISTS (SELECT 1 FROM audit.audit_events e
                    WHERE e.subject_id = t.id
                      AND e.action = 'LEDGER_HELD_PENDING_CLASSIFICATION')
     );

  IF v_total_txns = 0 THEN
    RETURN jsonb_build_object('satisfied', true, 'reason', 'NO_TRANSACTIONS_IN_PERIOD');
  ELSIF v_drafted_or_held < v_total_txns THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'TRANSACTIONS_WITHOUT_DRAFT_OR_HELD',
                              'total', v_total_txns, 'drafted_or_held', v_drafted_or_held);
  ELSE
    RETURN jsonb_build_object('satisfied', true, 'total', v_total_txns, 'drafted_or_held', v_drafted_or_held);
  END IF;
END;
$$;


-- 6. Phase-event RPCs -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_ledger_phase_started(
  p_workflow_run_id uuid, p_phase_name text, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_org uuid; v_biz uuid;
BEGIN
  SELECT organization_id, business_id INTO v_org, v_biz FROM public.workflow_runs WHERE id=p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_PHASE_STARTED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_phase', p_organization_id:=v_org, p_business_id:=v_biz,
    p_before_state:=NULL, p_after_state:=jsonb_build_object('phase_name',p_phase_name),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','RECORDED','workflow_run_id',p_workflow_run_id,'phase_name',p_phase_name);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ledger_phase_completed(
  p_workflow_run_id uuid, p_phase_name text, p_status_counts jsonb, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_org uuid; v_biz uuid;
BEGIN
  IF p_status_counts IS NULL OR jsonb_typeof(p_status_counts) <> 'object' THEN
    RAISE EXCEPTION 'STATUS_COUNTS_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id INTO v_org, v_biz FROM public.workflow_runs WHERE id=p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_PHASE_COMPLETED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_phase', p_organization_id:=v_org, p_business_id:=v_biz,
    p_before_state:=NULL, p_after_state:=jsonb_build_object('phase_name',p_phase_name,'status_counts',p_status_counts),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','RECORDED','workflow_run_id',p_workflow_run_id,'phase_name',p_phase_name);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ledger_phase_holding(
  p_workflow_run_id uuid, p_phase_name text, p_reason text,
  p_review_issue_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_org uuid; v_biz uuid;
BEGIN
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id INTO v_org, v_biz FROM public.workflow_runs WHERE id=p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='LEDGER_PHASE_HOLDING',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='ledger_phase', p_organization_id:=v_org, p_business_id:=v_biz,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('phase_name',p_phase_name,'review_issue_id',p_review_issue_id,'hold_reason',p_reason),
    p_reason:=p_reason, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','RECORDED','workflow_run_id',p_workflow_run_id,'phase_name',p_phase_name);
END;
$$;


-- 7. Privileges -----------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.record_ledger_phase_started(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_ledger_phase_completed(uuid, text, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_ledger_phase_holding(uuid, text, text, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.record_ledger_phase_started(uuid, text, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.record_ledger_phase_completed(uuid, text, jsonb, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.record_ledger_phase_holding(uuid, text, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.evaluate_ledger_exit_gate(uuid) TO authenticated, service_role;

COMMIT;
