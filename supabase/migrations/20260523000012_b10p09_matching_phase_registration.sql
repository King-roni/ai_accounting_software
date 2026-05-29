-- B10·P09 — MATCHING + INCOME_MATCHING Workflow Phase Registration
-- =====================================================================
-- Wires Block 10 matching engine (P02-P07) and IN-side variant (P08) into
-- the workflow engine.
--
-- Naming alignment (per B09·P09 precedent):
--   OUT side: spec calls it MATCHING; DB has existing 'MATCH' phase at
--             phase_order=6 of OUT_MONTHLY → we align with DB name.
--   IN side:  no matching-equivalent phase exists → INSERT 'INCOME_MATCHING'
--             at phase_order=7 of IN_MONTHLY (between CLASSIFY and
--             LEDGER_DRAFT). Shifts downstream phases (LEDGER_DRAFT,
--             REVIEW_QUEUE_GATE, USER_REVIEW, ARCHIVE_PROMOTION) up by 1.
--             Two-step large-offset shift to navigate around both the
--             unique(workflow_type, phase_order) constraint and the
--             wpd_phase_order_nonneg CHECK constraint.
--
-- Audit family names per spec: MATCHING_PHASE_* (OUT) and
-- INCOME_MATCHING_PHASE_* (IN); a single set of phase-event RPCs is
-- parameterized by p_event_family.
-- =====================================================================

BEGIN;

-- 1. Insert INCOME_MATCHING into IN_MONTHLY (shift downstream phases up) ---

UPDATE public.workflow_phase_definitions
   SET phase_order = phase_order + 100
 WHERE workflow_type = 'IN_MONTHLY' AND phase_order >= 7;
UPDATE public.workflow_phase_definitions
   SET phase_order = phase_order - 99
 WHERE workflow_type = 'IN_MONTHLY' AND phase_order >= 107;

INSERT INTO public.workflow_phase_definitions
  (workflow_type, phase_order, phase_name, optional, description, is_shared_with_pair)
VALUES
  ('IN_MONTHLY', 7, 'INCOME_MATCHING', false,
   'Match IN-side transactions to outstanding Invoice records (B10·P08); transitions invoice lifecycle states; raises review issues for ambiguous outcomes.',
   false);

-- 2. Tool seeds (5 tools) --------------------------------------------------

SELECT public.register_tool(
  p_tool_name              => 'matching.score_pair',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object(
    'workflow_run_id','uuid','transaction_id','uuid','document_id','uuid','signal_breakdown','jsonb'
  ),
  p_output_schema          => jsonb_build_object(
    'decision','text','match_record_id','uuid','match_level','match_level_enum'
  ),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'matching.score_pair.dedup_key_v1',
  p_description            => 'Score a (transaction, document) pair via P02 + P06 rejection check + P03 auto-confirm rule; idempotent via P06 unique constraint',
  p_retry_max_attempts     => 1,
  p_retry_backoff_base_ms  => 100,
  p_retry_backoff_max_ms   => 100
);

SELECT public.register_tool(
  p_tool_name              => 'matching.detect_split_payments',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object('workflow_run_id','uuid','transaction_ids','uuid[]'),
  p_output_schema          => jsonb_build_object('group_count','int','review_issue_count','int'),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'matching.detect_split_payments.dedup_key_v1',
  p_description            => 'Run P04 combinatorial split-payment detection over remaining unmatched transactions; deterministic ordering ensures idempotency',
  p_retry_max_attempts     => 1,
  p_retry_backoff_base_ms  => 100,
  p_retry_backoff_max_ms   => 100
);

SELECT public.register_tool(
  p_tool_name              => 'matching.detect_duplicates',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object('workflow_run_id','uuid','organization_id','uuid','business_id','uuid'),
  p_output_schema          => jsonb_build_object('pattern_a_count','int','pattern_b_count','int','review_issue_count','int'),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'matching.detect_duplicates.dedup_key_v1',
  p_description            => 'Run P05 pattern detection (A and B) at phase exit; raises review issues; idempotent',
  p_retry_max_attempts     => 1,
  p_retry_backoff_base_ms  => 100,
  p_retry_backoff_max_ms   => 100
);

SELECT public.register_tool(
  p_tool_name              => 'matching.generate_reasons',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object('workflow_run_id','uuid','match_record_ids','uuid[]'),
  p_output_schema          => jsonb_build_object('generated_count','int','fallback_count','int'),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'EXTERNAL_LLM'::ai_tier_enum,
  p_failure_semantics      => 'RETRYABLE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'matching.generate_reasons.dedup_key_v1',
  p_description            => 'Run P07 plain-language match-reason generation; Tier 2 default with Tier 3 escalation; deterministic fallback on AI failure',
  p_retry_max_attempts     => 3,
  p_retry_backoff_base_ms  => 1000,
  p_retry_backoff_max_ms   => 10000
);

SELECT public.register_tool(
  p_tool_name              => 'matching.income_match_outcome',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object(
    'workflow_run_id','uuid','transaction_id','uuid','invoice_id','uuid',
    'outcome','income_match_outcome_enum','has_reference_match','bool'
  ),
  p_output_schema          => jsonb_build_object(
    'decision','text','match_status','transaction_match_status_enum','review_issue_id','uuid'
  ),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'matching.income_match_outcome.dedup_key_v1',
  p_description            => 'Run P08 IN-side outcome computation; updates transactions.income_match_outcome + matched_invoice_id; orchestrator follows up with Block 13 lifecycle call',
  p_retry_max_attempts     => 1,
  p_retry_backoff_base_ms  => 100,
  p_retry_backoff_max_ms   => 100
);


-- 3. Gate seeds (4 gates) --------------------------------------------------

SELECT public.register_gate(
  'matching.entry_evidence_discovery_complete_v1', '1.0.0',
  'Entry: EVIDENCE_DISCOVERY phases done; at least one OUT_EXPENSE transaction in run');
SELECT public.register_gate(
  'matching.exit_all_out_expense_match_status_set_v1', '1.0.0',
  'Exit: every OUT_EXPENSE transaction in run has match_status set; duplicate-detection pass complete');
SELECT public.register_gate(
  'income_matching.entry_classification_complete_v1', '1.0.0',
  'Entry: CLASSIFY phase done; at least one IN-side transaction in run');
SELECT public.register_gate(
  'income_matching.exit_all_in_match_status_set_v1', '1.0.0',
  'Exit: every IN-side transaction in run has match_status set; duplicate-detection pass complete');


-- 4. phase_tool_expectations ------------------------------------------------

INSERT INTO public.phase_tool_expectations
  (workflow_type, phase_name, tool_name, permitted_side_effects, required)
VALUES
  ('OUT_MONTHLY', 'MATCH', 'matching.score_pair',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'MATCH', 'matching.detect_split_payments',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'MATCH', 'matching.detect_duplicates',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'MATCH', 'matching.generate_reasons',
    ARRAY['WRITES_RUN_STATE','CALLS_EXTERNAL_API']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'INCOME_MATCHING', 'matching.income_match_outcome',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'INCOME_MATCHING', 'matching.detect_split_payments',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'INCOME_MATCHING', 'matching.detect_duplicates',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY', 'INCOME_MATCHING', 'matching.generate_reasons',
    ARRAY['WRITES_RUN_STATE','CALLS_EXTERNAL_API']::public.side_effect_class_enum[], true)
ON CONFLICT DO NOTHING;


-- 5. phase_gate_assignments -------------------------------------------------

INSERT INTO public.phase_gate_assignments
  (workflow_type, phase_name, gate_name, kind, eval_order)
VALUES
  ('OUT_MONTHLY', 'MATCH', 'matching.entry_evidence_discovery_complete_v1', 'ENTRY', 1),
  ('OUT_MONTHLY', 'MATCH', 'matching.exit_all_out_expense_match_status_set_v1', 'EXIT', 1),
  ('IN_MONTHLY', 'INCOME_MATCHING', 'income_matching.entry_classification_complete_v1', 'ENTRY', 1),
  ('IN_MONTHLY', 'INCOME_MATCHING', 'income_matching.exit_all_in_match_status_set_v1', 'EXIT', 1)
ON CONFLICT DO NOTHING;


-- 6. STABLE gate evaluators -------------------------------------------------

CREATE OR REPLACE FUNCTION public.evaluate_matching_exit_gate(p_workflow_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_business_id uuid; v_period_start timestamptz; v_period_end timestamptz;
  v_unset_n int;
BEGIN
  SELECT business_id, period_start, period_end INTO v_business_id, v_period_start, v_period_end
    FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;
  SELECT count(*) INTO v_unset_n FROM public.transactions
   WHERE business_id = v_business_id
     AND transaction_type = 'OUT_EXPENSE'
     AND transaction_date BETWEEN v_period_start::date AND v_period_end::date
     AND match_status IS NULL;
  IF v_unset_n > 0 THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'OUT_EXPENSE_MATCH_STATUS_UNSET', 'unset_count', v_unset_n);
  END IF;
  RETURN jsonb_build_object('satisfied', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.evaluate_income_matching_exit_gate(p_workflow_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_business_id uuid; v_period_start timestamptz; v_period_end timestamptz;
  v_unset_n int;
BEGIN
  SELECT business_id, period_start, period_end INTO v_business_id, v_period_start, v_period_end
    FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;
  SELECT count(*) INTO v_unset_n FROM public.transactions
   WHERE business_id = v_business_id
     AND direction = 'IN'
     AND transaction_date BETWEEN v_period_start::date AND v_period_end::date
     AND income_match_outcome IS NULL;
  IF v_unset_n > 0 THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'IN_INCOME_MATCH_OUTCOME_UNSET', 'unset_count', v_unset_n);
  END IF;
  RETURN jsonb_build_object('satisfied', true);
END;
$$;


-- 7. Phase-event RPCs (parameterized by p_event_family) --------------------

CREATE OR REPLACE FUNCTION public.record_matching_phase_started(
  p_workflow_run_id uuid,
  p_event_family    text,
  p_phase_name      text,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_organization_id uuid; v_business_id uuid;
BEGIN
  IF p_event_family NOT IN ('MATCHING','INCOME_MATCHING') THEN
    RAISE EXCEPTION 'EVENT_FAMILY_INVALID' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id INTO v_organization_id, v_business_id
    FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:=p_event_family || '_PHASE_STARTED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('phase_name', p_phase_name),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN jsonb_build_object('decision','RECORDED','workflow_run_id',p_workflow_run_id,
                            'event_family',p_event_family,'phase_name',p_phase_name);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_matching_phase_completed(
  p_workflow_run_id uuid,
  p_event_family    text,
  p_phase_name      text,
  p_status_counts   jsonb,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_organization_id uuid; v_business_id uuid;
BEGIN
  IF p_event_family NOT IN ('MATCHING','INCOME_MATCHING') THEN
    RAISE EXCEPTION 'EVENT_FAMILY_INVALID' USING errcode='check_violation';
  END IF;
  IF p_status_counts IS NULL OR jsonb_typeof(p_status_counts) <> 'object' THEN
    RAISE EXCEPTION 'STATUS_COUNTS_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id INTO v_organization_id, v_business_id
    FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:=p_event_family || '_PHASE_COMPLETED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('phase_name', p_phase_name, 'status_counts', p_status_counts),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN jsonb_build_object('decision','RECORDED','workflow_run_id',p_workflow_run_id,
                            'event_family',p_event_family,'phase_name',p_phase_name);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_matching_phase_holding(
  p_workflow_run_id uuid,
  p_event_family    text,
  p_phase_name      text,
  p_reason          text,
  p_review_issue_id uuid    DEFAULT NULL,
  p_context         jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_organization_id uuid; v_business_id uuid;
BEGIN
  IF p_event_family NOT IN ('MATCHING','INCOME_MATCHING') THEN
    RAISE EXCEPTION 'EVENT_FAMILY_INVALID' USING errcode='check_violation';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id INTO v_organization_id, v_business_id
    FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:=p_event_family || '_PHASE_HOLDING',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('phase_name', p_phase_name, 'review_issue_id', p_review_issue_id, 'hold_reason', p_reason),
    p_reason:=p_reason, p_request_context:=p_context
  );
  RETURN jsonb_build_object('decision','RECORDED','workflow_run_id',p_workflow_run_id,
                            'event_family',p_event_family,'phase_name',p_phase_name);
END;
$$;


-- 8. Privileges -------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.record_matching_phase_started(uuid, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_matching_phase_completed(uuid, text, text, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_matching_phase_holding(uuid, text, text, text, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.record_matching_phase_started(uuid, text, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_matching_phase_completed(uuid, text, text, jsonb, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_matching_phase_holding(uuid, text, text, text, uuid, jsonb) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.evaluate_matching_exit_gate(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.evaluate_income_matching_exit_gate(uuid) TO authenticated, service_role;

COMMIT;
