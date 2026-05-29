-- ============================================================================
-- Block 13 Phase 09 — IN Gate Library + HUMAN_REVIEW_HOLD for IN side
-- 7 gate functions + 5 RPCs + tool/gate registry rows + phase_gate_assignments
-- wiring for IN_MONTHLY phases 1, 2, 4, 5, 6, 7, 8 (IN_FILTER phase 3 wired in P08).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.gate_in_workflow_ingestion_exit_v1(
  p_workflow_run_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE v_run public.workflow_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  RETURN jsonb_build_object('decision','ADVANCE');
END;
$$;

CREATE OR REPLACE FUNCTION public.gate_in_workflow_classification_exit_v1(
  p_workflow_run_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE v_run public.workflow_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  RETURN jsonb_build_object('decision','ADVANCE');
END;
$$;

CREATE OR REPLACE FUNCTION public.gate_in_workflow_income_matching_exit_v1(
  p_workflow_run_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run public.workflow_runs%ROWTYPE;
  v_unresolved_count int;
  v_unmatched_no_outcome int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  SELECT count(*) INTO v_unmatched_no_outcome
    FROM public.transactions t
   WHERE t.business_id = v_run.business_id
     AND t.transaction_date BETWEEN v_run.period_start::date AND v_run.period_end::date
     AND t.in_workflow_in_scope = true
     AND t.transaction_type IN ('IN_INCOME','REFUND_IN')
     AND NOT EXISTS (
       SELECT 1 FROM public.match_records mr
        WHERE mr.transaction_id = t.id AND mr.income_outcome IS NOT NULL
     );
  IF v_unmatched_no_outcome > 0 THEN
    RETURN jsonb_build_object('decision','HOLD','reason_code','UNMATCHED_NO_OUTCOME',
      'unmatched_count', v_unmatched_no_outcome);
  END IF;
  SELECT count(*) INTO v_unresolved_count
    FROM public.match_records mr
    JOIN public.transactions t ON t.id = mr.transaction_id
   WHERE t.business_id = v_run.business_id
     AND t.transaction_date BETWEEN v_run.period_start::date AND v_run.period_end::date
     AND t.in_workflow_in_scope = true
     AND mr.income_outcome IN ('MULTIPLE_INVOICES_ONE_PAYMENT','POSSIBLE_REFUND_OR_TRANSFER')
     AND mr.user_confirmation_status IS DISTINCT FROM 'CONFIRMED';
  IF v_unresolved_count > 0 THEN
    RETURN jsonb_build_object('decision','HOLD','reason_code','UNRESOLVED_MULTI_INVOICE',
      'unresolved_count', v_unresolved_count);
  END IF;
  RETURN jsonb_build_object('decision','ADVANCE');
END;
$$;

CREATE OR REPLACE FUNCTION public.gate_in_workflow_ledger_preparation_exit_v1(
  p_workflow_run_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run public.workflow_runs%ROWTYPE;
  v_missing_count int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  SELECT count(*) INTO v_missing_count
    FROM public.transactions t
   WHERE t.business_id = v_run.business_id
     AND t.transaction_date BETWEEN v_run.period_start::date AND v_run.period_end::date
     AND t.in_workflow_in_scope = true
     AND NOT EXISTS (
       SELECT 1 FROM public.draft_ledger_entries dle WHERE dle.parent_transaction_id = t.id
     );
  IF v_missing_count > 0 THEN
    RETURN jsonb_build_object('decision','HOLD','reason_code','MISSING_LEDGER_ENTRIES',
      'missing_count', v_missing_count);
  END IF;
  RETURN jsonb_build_object('decision','ADVANCE');
END;
$$;

CREATE OR REPLACE FUNCTION public.gate_in_workflow_ai_end_scan_exit_v1(
  p_workflow_run_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run public.workflow_runs%ROWTYPE;
  v_blocker_count int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  SELECT count(*) INTO v_blocker_count
    FROM public.review_issues
   WHERE workflow_run_id = p_workflow_run_id
     AND severity IN ('HIGH','BLOCKING')
     AND status IN ('OPEN','SNOOZED');
  IF v_blocker_count > 0 THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_GATE_ROUTED_TO_SIDE_PHASE',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_workflow_run_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:='in_workflow_gates',
      p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('gate','in_workflow.ai_end_scan_exit_v1','side_phase','HUMAN_REVIEW_HOLD','blocker_count', v_blocker_count),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','ROUTE_TO_SIDE_PHASE','side_phase','HUMAN_REVIEW_HOLD',
      'blocker_count', v_blocker_count);
  END IF;
  RETURN jsonb_build_object('decision','ADVANCE');
END;
$$;

CREATE OR REPLACE FUNCTION public.gate_in_workflow_human_review_hold_exit_v1(
  p_workflow_run_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_blocker_count int;
  v_approval_count int;
BEGIN
  SELECT count(*) INTO v_blocker_count
    FROM public.review_issues
   WHERE workflow_run_id = p_workflow_run_id
     AND severity IN ('HIGH','BLOCKING')
     AND status IN ('OPEN','SNOOZED');
  IF v_blocker_count > 0 THEN
    RETURN jsonb_build_object('decision','HOLD','reason_code','BLOCKING_ISSUES_OPEN',
      'blocker_count', v_blocker_count);
  END IF;
  SELECT count(*) INTO v_approval_count
    FROM public.workflow_run_approvals
   WHERE run_id = p_workflow_run_id AND revoked_at IS NULL;
  IF v_approval_count = 0 THEN
    RETURN jsonb_build_object('decision','HOLD','reason_code','MISSING_APPROVAL');
  END IF;
  RETURN jsonb_build_object('decision','ADVANCE');
END;
$$;

CREATE OR REPLACE FUNCTION public.gate_in_workflow_finalization_exit_v1(
  p_workflow_run_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run public.workflow_runs%ROWTYPE;
  v_unfinalized_count int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  SELECT count(*) INTO v_unfinalized_count
    FROM public.invoices
   WHERE business_id = v_run.business_id
     AND issue_date BETWEEN v_run.period_start::date AND v_run.period_end::date
     AND lifecycle_status NOT IN ('FINALIZED','EXPIRED_UNCONVERTED','CONVERTED_TO_TAX_INVOICE','DRAFT');
  IF v_unfinalized_count > 0 THEN
    RETURN jsonb_build_object('decision','HOLD','reason_code','INVOICES_NOT_FINALIZED',
      'unfinalized_count', v_unfinalized_count);
  END IF;
  RETURN jsonb_build_object('decision','ADVANCE');
END;
$$;

CREATE OR REPLACE FUNCTION public.in_workflow_user_approval(
  p_organization_id uuid,
  p_business_id     uuid,
  p_run_id          uuid,
  p_approval_method public.workflow_approval_method_enum,
  p_approval_note   text,
  p_actor_user_id   uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_can jsonb;
  v_approval_id uuid := public.gen_uuid_v7();
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'in_workflow.user_approval: actor_user_id required' USING ERRCODE='22000';
  END IF;
  v_can := public.can_perform(p_actor_user_id, 'WORKFLOW_APPROVE', 'RECORD', '{}'::jsonb, p_business_id, p_organization_id);
  IF v_can->>'decision' <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENIED','can_perform', v_can);
  END IF;
  INSERT INTO public.workflow_run_approvals (
    id, organization_id, business_id, run_id,
    approved_by, approved_at, approval_method, approval_note)
  VALUES (v_approval_id, p_organization_id, p_business_id, p_run_id,
          p_actor_user_id, v_now, p_approval_method, p_approval_note);
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='IN_HUMAN_REVIEW_APPROVAL_RECORDED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='in_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'approval_id', v_approval_id,
      'approved_by', p_actor_user_id,
      'approved_at', v_now,
      'approval_method', p_approval_method::text,
      'approval_note', p_approval_note),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','APPROVED','approval_id', v_approval_id, 'approved_at', v_now);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_user_revoke_approval(
  p_organization_id uuid,
  p_business_id     uuid,
  p_approval_id     uuid,
  p_actor_user_id   uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_can jsonb;
  v_approval public.workflow_run_approvals%ROWTYPE;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'in_workflow.user_revoke_approval: actor_user_id required' USING ERRCODE='22000';
  END IF;
  v_can := public.can_perform(p_actor_user_id, 'WORKFLOW_APPROVE', 'REVOKE', '{}'::jsonb, p_business_id, p_organization_id);
  IF v_can->>'decision' <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENIED','can_perform', v_can);
  END IF;
  SELECT * INTO v_approval FROM public.workflow_run_approvals WHERE id = p_approval_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','APPROVAL_NOT_FOUND'); END IF;
  IF v_approval.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('decision','ALLOW','reason_code','ALREADY_REVOKED','approval_id', p_approval_id);
  END IF;
  UPDATE public.workflow_run_approvals
     SET revoked_at = v_now, revoked_by = p_actor_user_id
   WHERE id = p_approval_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='IN_HUMAN_REVIEW_APPROVAL_REVOKED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=v_approval.run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='in_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object('revoked_at', NULL),
    p_after_state :=jsonb_build_object('approval_id', p_approval_id, 'revoked_at', v_now, 'revoked_by', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','REVOKED','approval_id', p_approval_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_check_approval_staleness(
  p_run_id      uuid,
  p_actor_system text DEFAULT 'in_workflow_human_review_hold',
  p_context     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_run public.workflow_runs%ROWTYPE;
  v_latest_approval_at timestamptz;
  v_newer_blocker_count int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  SELECT max(approved_at) INTO v_latest_approval_at
    FROM public.workflow_run_approvals WHERE run_id = p_run_id AND revoked_at IS NULL;
  IF v_latest_approval_at IS NULL THEN
    RETURN jsonb_build_object('decision','ALLOW','stale', false, 'reason_code','NO_ACTIVE_APPROVAL');
  END IF;
  SELECT count(*) INTO v_newer_blocker_count
    FROM public.review_issues
   WHERE workflow_run_id = p_run_id
     AND severity IN ('HIGH','BLOCKING')
     AND status IN ('OPEN','SNOOZED')
     AND created_at > v_latest_approval_at;
  IF v_newer_blocker_count > 0 THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='IN_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('latest_approval_at', v_latest_approval_at,
                                          'newer_blocker_count', v_newer_blocker_count),
      p_reason:='STALENESS', p_request_context:=p_context);
    RETURN jsonb_build_object('decision','ALLOW','stale', true, 'newer_blocker_count', v_newer_blocker_count);
  END IF;
  RETURN jsonb_build_object('decision','ALLOW','stale', false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_enter_human_review_hold(
  p_run_id      uuid,
  p_actor_system text DEFAULT 'in_workflow_engine',
  p_context     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_run public.workflow_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_HUMAN_REVIEW_HOLD_ENTERED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('run_id', p_run_id, 'phase','HUMAN_REVIEW_HOLD'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW');
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_clear_human_review_hold(
  p_run_id      uuid,
  p_actor_system text DEFAULT 'in_workflow_engine',
  p_context     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_gate jsonb;
  v_run public.workflow_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  v_gate := public.gate_in_workflow_human_review_hold_exit_v1(p_run_id, p_context);
  IF (v_gate->>'decision') <> 'ADVANCE' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_gate->>'reason_code', 'gate', v_gate);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_HUMAN_REVIEW_HOLD_CLEARED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('run_id', p_run_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW');
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_finalize_period_invoices(
  p_run_id      uuid,
  p_actor_system text DEFAULT 'in_workflow_finalization',
  p_context     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_run public.workflow_runs%ROWTYPE;
  v_inv record;
  v_result jsonb;
  v_finalized int := 0;
  v_skipped int := 0;
  v_failed int := 0;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  IF v_run.workflow_type <> 'IN_MONTHLY' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_IN_MONTHLY');
  END IF;
  FOR v_inv IN
    SELECT id, lifecycle_status FROM public.invoices
     WHERE business_id = v_run.business_id
       AND issue_date BETWEEN v_run.period_start::date AND v_run.period_end::date
       AND lifecycle_status NOT IN ('FINALIZED','EXPIRED_UNCONVERTED','CONVERTED_TO_TAX_INVOICE','DRAFT')
  LOOP
    v_result := public.invoice_mark_finalized(v_inv.id, p_run_id, clock_timestamp(), p_actor_system, p_context);
    IF (v_result->>'decision') = 'ALLOW' THEN v_finalized := v_finalized + 1;
    ELSE v_failed := v_failed + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('decision','RAN','finalized', v_finalized,
    'skipped', v_skipped, 'failed', v_failed);
END;
$function$;

INSERT INTO public.gate_registry (gate_name, version, description) VALUES
  ('in_workflow.ingestion_exit_v1',          '1.0.0', 'Block 13 P09 — IN INGESTION exit. Stage 1 stub: ADVANCE.'),
  ('in_workflow.classification_exit_v1',     '1.0.0', 'Block 13 P09 — IN CLASSIFICATION exit. Stage 1 stub: ADVANCE.'),
  ('in_workflow.income_matching_exit_v1',    '1.0.0', 'Block 13 P09 — INCOME_MATCHING exit. HOLD on UNRESOLVED_MULTI_INVOICE / POSSIBLE_REFUND_OR_TRANSFER outcomes.'),
  ('in_workflow.ledger_preparation_exit_v1', '1.0.0', 'Block 13 P09 — LEDGER_PREPARATION exit. HOLD on missing draft entries.'),
  ('in_workflow.ai_end_scan_exit_v1',        '1.0.0', 'Block 13 P09 — AI_END_SCAN exit. ROUTE_TO_SIDE_PHASE on open HIGH/BLOCKING review_issues.'),
  ('in_workflow.human_review_hold_exit_v1',  '1.0.0', 'Block 13 P09 — HUMAN_REVIEW_HOLD exit. ADVANCE iff zero blockers AND non-revoked approval row exists.'),
  ('in_workflow.finalization_exit_v1',       '1.0.0', 'Block 13 P09 — FINALIZATION exit. ADVANCE when every in-period invoice has lifecycle_status=FINALIZED.')
ON CONFLICT (gate_name) DO NOTHING;

INSERT INTO public.tool_registry (
  tool_name, version, input_schema, output_schema,
  side_effect, ai_tier, failure_semantics, dedup_key_generator_ref,
  description, retry_max_attempts, retry_backoff_base_ms, retry_backoff_max_ms
) VALUES (
  'in_workflow.finalize_period_invoices', '1.0.0',
  '{"run_id":"uuid"}'::jsonb,
  '{"decision":"text","finalized":"int","skipped":"int","failed":"int"}'::jsonb,
  'WRITES_RUN_STATE'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum,
  'in_workflow.finalize_period_invoices.dedup_key_v1',
  'Block 13 P09 — bulk-finalizes invoices in the period via invoice_mark_finalized. Invoked by Block 15 FINALIZATION sequence.',
  1, 100, 100
)
ON CONFLICT (tool_name) DO NOTHING;

INSERT INTO public.phase_gate_assignments (workflow_type, phase_name, gate_name, kind, eval_order) VALUES
  ('IN_MONTHLY', 'INGESTION',          'in_workflow.ingestion_exit_v1',          'EXIT'::public.gate_kind_enum, 1),
  ('IN_MONTHLY', 'CLASSIFICATION',     'in_workflow.classification_exit_v1',     'EXIT'::public.gate_kind_enum, 1),
  ('IN_MONTHLY', 'INCOME_MATCHING',    'in_workflow.income_matching_exit_v1',    'EXIT'::public.gate_kind_enum, 1),
  ('IN_MONTHLY', 'LEDGER_PREPARATION', 'in_workflow.ledger_preparation_exit_v1', 'EXIT'::public.gate_kind_enum, 1),
  ('IN_MONTHLY', 'AI_END_SCAN',        'in_workflow.ai_end_scan_exit_v1',        'EXIT'::public.gate_kind_enum, 1),
  ('IN_MONTHLY', 'HUMAN_REVIEW_HOLD',  'in_workflow.human_review_hold_exit_v1',  'EXIT'::public.gate_kind_enum, 1),
  ('IN_MONTHLY', 'FINALIZATION',       'in_workflow.finalization_exit_v1',       'EXIT'::public.gate_kind_enum, 1);
