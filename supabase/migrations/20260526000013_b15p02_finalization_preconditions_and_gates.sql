-- B15·P02 — Finalization Preconditions & Gate Function Library
-- =====================================================================
-- 8 individual gates + 1 composite. Each takes (p_run_id uuid) and
-- returns a GateResult-shaped jsonb. The composite short-circuits on
-- the first HOLD and emits FINALIZATION_PRECONDITIONS_PASSED or
-- FINALIZATION_PRECONDITIONS_FAILED.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.gate_finalization_transactions_processed(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_pending int;
  v_failed  int;
BEGIN
  SELECT business_id, workflow_type::text AS wtype, period_start, period_end
    INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','transactions_processed',
                              'payload', jsonb_build_object('reason','RUN_NOT_FOUND'));
  END IF;
  SELECT count(*) FILTER (WHERE classification_status = 'PENDING'),
         count(*) FILTER (WHERE classification_status = 'FAILED')
    INTO v_pending, v_failed
    FROM public.transactions
   WHERE business_id = v_run.business_id
     AND transaction_date BETWEEN v_run.period_start AND v_run.period_end;
  IF v_pending = 0 AND v_failed = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','transactions_processed');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','transactions_processed',
    'payload', jsonb_build_object('pending', v_pending, 'failed', v_failed));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_no_unknown_types(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_unknown int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','no_unknown_types',
                              'payload', jsonb_build_object('reason','RUN_NOT_FOUND'));
  END IF;
  SELECT count(*) INTO v_unknown FROM public.transactions
   WHERE business_id = v_run.business_id
     AND transaction_date BETWEEN v_run.period_start AND v_run.period_end
     AND transaction_type = 'UNKNOWN'::public.transaction_type_enum;
  IF v_unknown = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','no_unknown_types');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','no_unknown_types',
    'payload', jsonb_build_object('unknown_count', v_unknown));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_evidence_satisfied(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_unmatched int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','evidence_satisfied',
                              'payload', jsonb_build_object('reason','RUN_NOT_FOUND'));
  END IF;
  SELECT count(*) INTO v_unmatched FROM public.transactions
   WHERE business_id = v_run.business_id
     AND transaction_date BETWEEN v_run.period_start AND v_run.period_end
     AND direction = 'OUT'
     AND transaction_type = 'OUT_EXPENSE'::public.transaction_type_enum
     AND COALESCE(out_workflow_in_scope, true) = true
     AND match_status NOT IN (
       'MATCHED_CONFIRMED'::public.transaction_match_status_enum,
       'MATCHED_AUTO_CONFIRMED'::public.transaction_match_status_enum,
       'MATCHED_AUTO_HIGH_CONFIDENCE'::public.transaction_match_status_enum,
       'EXCEPTION_DOCUMENTED'::public.transaction_match_status_enum,
       'NO_MATCH_REQUIRED'::public.transaction_match_status_enum);
  IF v_unmatched = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','evidence_satisfied');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','evidence_satisfied',
    'payload', jsonb_build_object('unmatched_out_expense_count', v_unmatched));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_draft_ledger_entries_complete(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_txns_without_entries int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','draft_ledger_entries_complete',
                              'payload', jsonb_build_object('reason','RUN_NOT_FOUND'));
  END IF;
  SELECT count(*) INTO v_txns_without_entries FROM public.transactions t
   WHERE t.business_id = v_run.business_id
     AND t.transaction_date BETWEEN v_run.period_start AND v_run.period_end
     AND t.transaction_type <> 'UNKNOWN'::public.transaction_type_enum
     AND NOT EXISTS (SELECT 1 FROM public.draft_ledger_entries dle
                      WHERE dle.parent_transaction_id = t.id);
  IF v_txns_without_entries = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','draft_ledger_entries_complete');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','draft_ledger_entries_complete',
    'payload', jsonb_build_object('txns_without_entries_count', v_txns_without_entries));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_vat_classifications_complete(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_null_vat int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','vat_classifications_complete',
                              'payload', jsonb_build_object('reason','RUN_NOT_FOUND'));
  END IF;
  SELECT count(*) INTO v_null_vat
    FROM public.draft_ledger_entries dle
    JOIN public.transactions t ON t.id = dle.parent_transaction_id
   WHERE t.business_id = v_run.business_id
     AND t.transaction_date BETWEEN v_run.period_start AND v_run.period_end
     AND dle.vat_treatment IS NULL;
  IF v_null_vat = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','vat_classifications_complete');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','vat_classifications_complete',
    'payload', jsonb_build_object('null_vat_count', v_null_vat));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_zero_blocking_issues(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_blocking int;
BEGIN
  SELECT count(*) INTO v_blocking FROM public.v_blocking_issues
   WHERE workflow_run_id = p_run_id;
  IF v_blocking = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','zero_blocking_issues');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','zero_blocking_issues',
    'payload', jsonb_build_object('blocking_count', v_blocking));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_approval_recorded(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_approval record;
BEGIN
  SELECT id, approval_method::text AS m, revoked_at
    INTO v_approval FROM public.workflow_run_approvals
   WHERE run_id = p_run_id
   ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','approval_recorded',
      'payload', jsonb_build_object('reason','NO_APPROVAL_FOUND'));
  END IF;
  IF v_approval.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('decision','HOLD','gate','approval_recorded',
      'payload', jsonb_build_object('reason','APPROVAL_REVOKED','approval_id', v_approval.id));
  END IF;
  IF v_approval.m <> 'STEP_UP' THEN
    RETURN jsonb_build_object('decision','HOLD','gate','approval_recorded',
      'payload', jsonb_build_object('reason','APPROVAL_NOT_STEP_UP',
                                     'approval_method', v_approval.m));
  END IF;
  RETURN jsonb_build_object('decision','ADVANCE','gate','approval_recorded',
    'payload', jsonb_build_object('approval_id', v_approval.id));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_audit_log_quiescent(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE v_recent int;
BEGIN
  SELECT count(*) INTO v_recent FROM audit.audit_events
   WHERE subject_type = 'WORKFLOW_RUN'::audit.subject_type_enum
     AND subject_id = p_run_id
     AND created_at > clock_timestamp() - interval '5 seconds';
  IF v_recent = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','audit_log_quiescent');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','audit_log_quiescent',
    'payload', jsonb_build_object('recent_events_count', v_recent,
                                   'settle_window_seconds', 5));
END;
$$;


CREATE OR REPLACE FUNCTION public.gate_finalization_preconditions_satisfied(
  p_run_id uuid,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run record;
  v_result jsonb;
  v_gate_seq text[] := ARRAY[
    'gate_finalization_transactions_processed',
    'gate_finalization_no_unknown_types',
    'gate_finalization_evidence_satisfied',
    'gate_finalization_draft_ledger_entries_complete',
    'gate_finalization_vat_classifications_complete',
    'gate_finalization_zero_blocking_issues',
    'gate_finalization_approval_recorded',
    'gate_finalization_audit_log_quiescent'
  ];
  v_gate text;
BEGIN
  SELECT id, organization_id, business_id INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','failing_gate','run_not_found',
                              'failure_payload', jsonb_build_object('run_id', p_run_id));
  END IF;

  FOREACH v_gate IN ARRAY v_gate_seq LOOP
    EXECUTE format('SELECT public.%I($1)', v_gate) INTO v_result USING p_run_id;
    IF (v_result->>'decision') <> 'ADVANCE' THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
        p_action:='FINALIZATION_PRECONDITIONS_FAILED',
        p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
        p_subject_id:=p_run_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='finalization_gate_composite',
        p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object('failing_gate', v_gate,
                                           'failure_payload', v_result->'payload'),
        p_reason:=NULL, p_request_context:=p_context);
      RETURN jsonb_build_object('decision','HOLD','failing_gate', v_gate,
                                'failure_payload', v_result->'payload');
    END IF;
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='FINALIZATION_PRECONDITIONS_PASSED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='finalization_gate_composite',
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('all_gates_passed', true,
                                       'gate_count', cardinality(v_gate_seq)),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ADVANCE','all_gates_passed', true);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.gate_finalization_preconditions_satisfied(uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.gate_finalization_preconditions_satisfied(uuid, jsonb) TO service_role;


INSERT INTO public.gate_registry (gate_name, version, description, registered_at, updated_at) VALUES
('gate.finalization.transactions_processed','1.0.0','B15·P02: every txn in run period has classification_status NOT IN (PENDING, FAILED).',clock_timestamp(),clock_timestamp()),
('gate.finalization.no_unknown_types','1.0.0','B15·P02: no transactions with transaction_type=UNKNOWN in the run period.',clock_timestamp(),clock_timestamp()),
('gate.finalization.evidence_satisfied','1.0.0','B15·P02: every in-scope OUT_EXPENSE has match_status IN (MATCHED_*, EXCEPTION_DOCUMENTED, NO_MATCH_REQUIRED).',clock_timestamp(),clock_timestamp()),
('gate.finalization.draft_ledger_entries_complete','1.0.0','B15·P02: every in-scope non-UNKNOWN transaction has at least one draft_ledger_entries row.',clock_timestamp(),clock_timestamp()),
('gate.finalization.vat_classifications_complete','1.0.0','B15·P02: every draft_ledger_entries row in the run has vat_treatment NOT NULL.',clock_timestamp(),clock_timestamp()),
('gate.finalization.zero_blocking_issues','1.0.0','B15·P02: zero v_blocking_issues for the run (severity HIGH/BLOCKING AND status=OPEN).',clock_timestamp(),clock_timestamp()),
('gate.finalization.approval_recorded','1.0.0','B15·P02: workflow_run_approvals row exists, not revoked, approval_method=STEP_UP.',clock_timestamp(),clock_timestamp()),
('gate.finalization.audit_log_quiescent','1.0.0','B15·P02: no WORKFLOW_RUN-subject audit events for the run in the last 5 seconds.',clock_timestamp(),clock_timestamp()),
('gate.finalization.preconditions_satisfied','1.0.0','B15·P02 composite: runs the 8 individual gates in order, short-circuits on first HOLD.',clock_timestamp(),clock_timestamp())
ON CONFLICT (gate_name) DO NOTHING;


SELECT public.register_issue_type(
  'finalization.approval_missing_or_not_step_up',
  'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
  'HIGH'::public.review_issue_severity_enum,
  ARRAY['ADD_EXPLANATION_NOTE','RERUN_SCAN_AFTER_CHANGE'],
  'finalization', 'review_queue.card_content_default');
SELECT public.register_issue_type(
  'finalization.audit_log_pending_writes',
  'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
  'HIGH'::public.review_issue_severity_enum,
  ARRAY['ADD_EXPLANATION_NOTE','RERUN_SCAN_AFTER_CHANGE'],
  'finalization', 'review_queue.card_content_default');
SELECT public.register_issue_type(
  'finalization.vat_classification_missing',
  'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
  'HIGH'::public.review_issue_severity_enum,
  ARRAY['CHANGE_TAG','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW'],
  'finalization', 'review_queue.card_content_default');


CREATE OR REPLACE VIEW public.v_finalization_readiness AS
  SELECT wr.id AS workflow_run_id,
         wr.organization_id, wr.business_id, wr.workflow_type::text AS workflow_type,
         wr.period_start, wr.period_end, wr.status::text AS run_status,
         (public.gate_finalization_preconditions_satisfied(wr.id))->>'decision' = 'ADVANCE' AS is_ready_to_finalize,
         (public.gate_finalization_preconditions_satisfied(wr.id))->>'failing_gate'        AS failing_gate
    FROM public.workflow_runs wr;

COMMENT ON VIEW public.v_finalization_readiness IS
  'B15·P02 diagnostic: per workflow_run, is the composite finalization gate ADVANCE-ready, and if not, which gate held.';
