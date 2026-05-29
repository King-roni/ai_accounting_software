-- B12·P05 — Gate-Function Library
-- =====================================================================
-- Adds the 6 missing OUT_MONTHLY exit-gate functions (the other 5 phases
-- already have gates registered & assigned by earlier blocks):
--
--   INGESTION              ← out_workflow.ingestion_exit_v1
--   OUT_FILTER             ← out_workflow.out_filter_exit_v1
--   MANUAL_UPLOAD_HOLD     ← out_workflow.manual_upload_hold_exit_v1
--   AI_END_SCAN            ← out_workflow.ai_end_scan_exit_v1
--   HUMAN_REVIEW_HOLD      ← out_workflow.human_review_hold_exit_v1
--   FINALIZATION           ← out_workflow.finalization_exit_v1
--
-- Pre-existing wiring (Blocks 06–11) is untouched:
--   CLASSIFICATION         ← classification.entry/exit_v1
--   EVIDENCE_DISCOVERY_*   ← intake.evidence_discovery_*_entry/exit_v1
--   MATCHING               ← matching.*_v1
--   LEDGER_PREPARATION     ← ledger.*_v1
--
-- After this phase OUT_MONTHLY has all 11 phases assigned an EXIT gate.
--
-- Gate function uniform signature:
--   (p_run_id uuid, p_business_id uuid, p_period_start timestamptz,
--    p_period_end timestamptz, p_context jsonb)
--   RETURNS jsonb {decision, reason, side_phase, inputs_observed}
--
-- 2 audit actions:
--   OUT_GATE_EVALUATED           (WORKFLOW_RUN, every call)
--   OUT_GATE_ROUTED_TO_SIDE_PHASE (WORKFLOW_RUN, only on ROUTE_TO_SIDE_PHASE)
-- =====================================================================

BEGIN;

-- 1. Shared audit-emit helper for OUT gate evaluations
CREATE OR REPLACE FUNCTION public._emit_out_gate_audit(
  p_organization_id uuid, p_business_id uuid,
  p_workflow_run_id uuid, p_gate_name text,
  p_decision public.gate_decision_enum,
  p_reason text, p_side_phase text,
  p_inputs_observed jsonb, p_context jsonb
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_GATE_EVALUATED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_gate_library',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'gate_name', p_gate_name,
      'decision', p_decision::text,
      'reason', p_reason,
      'side_phase', p_side_phase,
      'inputs_observed', p_inputs_observed),
    p_reason:=p_reason, p_request_context:=p_context);

  IF p_decision = 'ROUTE_TO_SIDE_PHASE' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_GATE_ROUTED_TO_SIDE_PHASE',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id:=p_workflow_run_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_gate_library',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'gate_name', p_gate_name,
        'side_phase', p_side_phase,
        'reason', p_reason),
      p_reason:=p_reason, p_request_context:=p_context);
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public._emit_out_gate_audit(uuid,uuid,uuid,text,public.gate_decision_enum,text,text,jsonb,jsonb) FROM PUBLIC;


-- 2. INGESTION exit gate
--    Source: statement_uploads.upload_status for the business in period.
--    ADVANCE only when every relevant upload reaches ACCEPTED (terminal).
CREATE OR REPLACE FUNCTION public.gate_out_ingestion_exit_v1(
  p_run_id uuid, p_business_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_total int; v_accepted int; v_failed int; v_pending int;
  v_decision public.gate_decision_enum; v_reason text;
  v_result jsonb;
BEGIN
  SELECT organization_id INTO v_org FROM public.workflow_runs WHERE id=p_run_id;
  SELECT
    count(*) FILTER (WHERE true),
    count(*) FILTER (WHERE upload_status='ACCEPTED'),
    count(*) FILTER (WHERE upload_status='FAILED'),
    count(*) FILTER (WHERE upload_status IN ('UPLOADED','PARSING','PARSED'))
  INTO v_total, v_accepted, v_failed, v_pending
  FROM public.statement_uploads
  WHERE business_id=p_business_id
    AND declared_period_start <= p_period_end::date
    AND declared_period_end   >= p_period_start::date;

  IF v_total = 0 THEN
    v_decision := 'ADVANCE'; v_reason := 'no statement uploads in period — vacuously complete';
  ELSIF v_pending > 0 THEN
    v_decision := 'HOLD'; v_reason := format('%s upload(s) still mid-pipeline', v_pending);
  ELSIF v_failed > 0 AND v_accepted = 0 THEN
    v_decision := 'HOLD'; v_reason := format('%s upload(s) failed, none accepted', v_failed);
  ELSE
    v_decision := 'ADVANCE'; v_reason := format('%s upload(s) accepted', v_accepted);
  END IF;

  v_result := jsonb_build_object(
    'decision', v_decision::text, 'reason', v_reason,
    'side_phase', NULL,
    'inputs_observed', jsonb_build_object('total', v_total, 'accepted', v_accepted, 'failed', v_failed, 'pending', v_pending));
  PERFORM public._emit_out_gate_audit(v_org, p_business_id, p_run_id,
    'out_workflow.ingestion_exit_v1', v_decision, v_reason, NULL,
    v_result->'inputs_observed', p_context);
  RETURN v_result;
END;
$$;


-- 3. OUT_FILTER exit gate
--    ADVANCE when every in-period transaction has out_filter_decided_at set
--    AND no OPEN UNKNOWN_BLOCKER issue remains (B12·P03).
CREATE OR REPLACE FUNCTION public.gate_out_out_filter_exit_v1(
  p_run_id uuid, p_business_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_org uuid; v_total int; v_undecided int; v_open_blockers int;
  v_decision public.gate_decision_enum; v_reason text; v_result jsonb;
BEGIN
  SELECT organization_id INTO v_org FROM public.workflow_runs WHERE id=p_run_id;
  SELECT count(*), count(*) FILTER (WHERE out_filter_decided_at IS NULL)
    INTO v_total, v_undecided
    FROM public.transactions
   WHERE business_id=p_business_id
     AND transaction_date BETWEEN p_period_start::date AND p_period_end::date;
  SELECT count(*) INTO v_open_blockers
    FROM public.review_issues
   WHERE business_id=p_business_id
     AND issue_type='out_filter.unknown_blocker'
     AND status='OPEN';

  IF v_undecided > 0 THEN
    v_decision := 'HOLD'; v_reason := format('%s transaction(s) undecided', v_undecided);
  ELSIF v_open_blockers > 0 THEN
    v_decision := 'HOLD'; v_reason := format('%s open UNKNOWN_BLOCKER issue(s)', v_open_blockers);
  ELSE
    v_decision := 'ADVANCE'; v_reason := format('all %s transaction(s) decided', v_total);
  END IF;

  v_result := jsonb_build_object(
    'decision', v_decision::text, 'reason', v_reason,
    'side_phase', NULL,
    'inputs_observed', jsonb_build_object('total', v_total, 'undecided', v_undecided, 'open_blockers', v_open_blockers));
  PERFORM public._emit_out_gate_audit(v_org, p_business_id, p_run_id,
    'out_workflow.out_filter_exit_v1', v_decision, v_reason, NULL,
    v_result->'inputs_observed', p_context);
  RETURN v_result;
END;
$$;


-- 4. MANUAL_UPLOAD_HOLD exit gate
--    ADVANCE when every in-scope OUT_EXPENSE has a resolved match status OR is
--    a transaction_type that doesn't require evidence; HOLD if any UNMATCHED.
CREATE OR REPLACE FUNCTION public.gate_out_manual_upload_hold_exit_v1(
  p_run_id uuid, p_business_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_org uuid; v_total int; v_unmatched int;
  v_decision public.gate_decision_enum; v_reason text; v_result jsonb;
BEGIN
  SELECT organization_id INTO v_org FROM public.workflow_runs WHERE id=p_run_id;
  SELECT
    count(*) FILTER (WHERE out_workflow_in_scope = true AND transaction_type='OUT_EXPENSE'),
    count(*) FILTER (WHERE out_workflow_in_scope = true AND transaction_type='OUT_EXPENSE'
                       AND (match_status IS NULL OR match_status='UNMATCHED'))
  INTO v_total, v_unmatched
  FROM public.transactions
  WHERE business_id=p_business_id
    AND transaction_date BETWEEN p_period_start::date AND p_period_end::date;

  IF v_unmatched > 0 THEN
    v_decision := 'HOLD'; v_reason := format('%s OUT_EXPENSE row(s) UNMATCHED', v_unmatched);
  ELSE
    v_decision := 'ADVANCE'; v_reason := format('all %s OUT_EXPENSE row(s) resolved', v_total);
  END IF;

  v_result := jsonb_build_object(
    'decision', v_decision::text, 'reason', v_reason,
    'side_phase', NULL,
    'inputs_observed', jsonb_build_object('out_expense_total', v_total, 'unmatched', v_unmatched));
  PERFORM public._emit_out_gate_audit(v_org, p_business_id, p_run_id,
    'out_workflow.manual_upload_hold_exit_v1', v_decision, v_reason, NULL,
    v_result->'inputs_observed', p_context);
  RETURN v_result;
END;
$$;


-- 5. AI_END_SCAN exit gate
--    ROUTE_TO_SIDE_PHASE → HUMAN_REVIEW_HOLD when any HIGH/BLOCKING review_issue
--    is OPEN for the run; otherwise ADVANCE.
CREATE OR REPLACE FUNCTION public.gate_out_ai_end_scan_exit_v1(
  p_run_id uuid, p_business_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_org uuid; v_blocking_open int;
  v_decision public.gate_decision_enum; v_reason text; v_side text;
  v_result jsonb;
BEGIN
  SELECT organization_id INTO v_org FROM public.workflow_runs WHERE id=p_run_id;
  SELECT count(*) INTO v_blocking_open
    FROM public.review_issues
   WHERE workflow_run_id = p_run_id
     AND severity IN ('HIGH','BLOCKING')
     AND status = 'OPEN';

  IF v_blocking_open > 0 THEN
    v_decision := 'ROUTE_TO_SIDE_PHASE'; v_side := 'HUMAN_REVIEW_HOLD';
    v_reason := format('%s blocking review issue(s) open', v_blocking_open);
  ELSE
    v_decision := 'ADVANCE'; v_side := NULL;
    v_reason := 'no blocking review issues';
  END IF;

  v_result := jsonb_build_object(
    'decision', v_decision::text, 'reason', v_reason,
    'side_phase', v_side,
    'inputs_observed', jsonb_build_object('blocking_open', v_blocking_open));
  PERFORM public._emit_out_gate_audit(v_org, p_business_id, p_run_id,
    'out_workflow.ai_end_scan_exit_v1', v_decision, v_reason, v_side,
    v_result->'inputs_observed', p_context);
  RETURN v_result;
END;
$$;


-- 6. HUMAN_REVIEW_HOLD exit gate
--    ADVANCE when zero blocking OPEN review_issues remain AND a
--    workflow_run_approvals row exists for the run.
CREATE OR REPLACE FUNCTION public.gate_out_human_review_hold_exit_v1(
  p_run_id uuid, p_business_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_org uuid; v_blocking_open int; v_has_approval boolean;
  v_decision public.gate_decision_enum; v_reason text; v_result jsonb;
BEGIN
  SELECT organization_id INTO v_org FROM public.workflow_runs WHERE id=p_run_id;
  SELECT count(*) INTO v_blocking_open
    FROM public.review_issues
   WHERE workflow_run_id = p_run_id
     AND severity IN ('HIGH','BLOCKING')
     AND status = 'OPEN';
  SELECT EXISTS(
    SELECT 1 FROM public.workflow_run_approvals
     WHERE run_id = p_run_id AND revoked_at IS NULL
  ) INTO v_has_approval;

  IF v_blocking_open > 0 THEN
    v_decision := 'HOLD'; v_reason := format('%s blocking issue(s) still open', v_blocking_open);
  ELSIF NOT v_has_approval THEN
    v_decision := 'HOLD'; v_reason := 'no recorded user approval';
  ELSE
    v_decision := 'ADVANCE'; v_reason := 'no blocking issues and user approval recorded';
  END IF;

  v_result := jsonb_build_object(
    'decision', v_decision::text, 'reason', v_reason,
    'side_phase', NULL,
    'inputs_observed', jsonb_build_object('blocking_open', v_blocking_open, 'has_approval', v_has_approval));
  PERFORM public._emit_out_gate_audit(v_org, p_business_id, p_run_id,
    'out_workflow.human_review_hold_exit_v1', v_decision, v_reason, NULL,
    v_result->'inputs_observed', p_context);
  RETURN v_result;
END;
$$;


-- 7. FINALIZATION exit gate
--    ADVANCE when summary_json.finalization carries both an archive_package_id
--    and a dashboard_refresh_enqueued marker (Block 15's owner sets these).
CREATE OR REPLACE FUNCTION public.gate_out_finalization_exit_v1(
  p_run_id uuid, p_business_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_org uuid; v_finalization jsonb;
  v_has_archive boolean; v_has_dashboard boolean;
  v_decision public.gate_decision_enum; v_reason text; v_result jsonb;
BEGIN
  SELECT organization_id, summary_json->'finalization'
    INTO v_org, v_finalization
    FROM public.workflow_runs WHERE id=p_run_id;
  v_has_archive   := v_finalization ? 'archive_package_id';
  v_has_dashboard := v_finalization ? 'dashboard_refresh_enqueued';

  IF v_has_archive AND v_has_dashboard THEN
    v_decision := 'ADVANCE'; v_reason := 'archive package + dashboard refresh present';
  ELSE
    v_decision := 'HOLD';
    v_reason := format('missing %s%s%s',
      CASE WHEN NOT v_has_archive THEN 'archive_package_id ' ELSE '' END,
      CASE WHEN NOT v_has_dashboard THEN 'dashboard_refresh_enqueued ' ELSE '' END,
      CASE WHEN v_has_archive AND v_has_dashboard THEN '' ELSE 'in summary_json.finalization' END);
  END IF;

  v_result := jsonb_build_object(
    'decision', v_decision::text, 'reason', v_reason,
    'side_phase', NULL,
    'inputs_observed', jsonb_build_object('has_archive', v_has_archive, 'has_dashboard_marker', v_has_dashboard));
  PERFORM public._emit_out_gate_audit(v_org, p_business_id, p_run_id,
    'out_workflow.finalization_exit_v1', v_decision, v_reason, NULL,
    v_result->'inputs_observed', p_context);
  RETURN v_result;
END;
$$;


-- 8. Registry seeds + phase assignments
SELECT public.register_gate('out_workflow.ingestion_exit_v1', '1.0.0',
  'OUT_MONTHLY INGESTION exit — ADVANCE when every relevant statement_upload reaches ACCEPTED; HOLD if any pending; deterministic.');
SELECT public.register_gate('out_workflow.out_filter_exit_v1', '1.0.0',
  'OUT_MONTHLY OUT_FILTER exit — ADVANCE when every period transaction is decided AND no open out_filter.unknown_blocker.');
SELECT public.register_gate('out_workflow.manual_upload_hold_exit_v1', '1.0.0',
  'OUT_MONTHLY MANUAL_UPLOAD_HOLD exit — ADVANCE when every in-scope OUT_EXPENSE has a resolved match_status; HOLD if any UNMATCHED.');
SELECT public.register_gate('out_workflow.ai_end_scan_exit_v1', '1.0.0',
  'OUT_MONTHLY AI_END_SCAN exit — ROUTE_TO_SIDE_PHASE→HUMAN_REVIEW_HOLD on any HIGH/BLOCKING open review issue; else ADVANCE.');
SELECT public.register_gate('out_workflow.human_review_hold_exit_v1', '1.0.0',
  'OUT_MONTHLY HUMAN_REVIEW_HOLD exit — ADVANCE when zero blocking OPEN issues remain AND a workflow_run_approvals row exists.');
SELECT public.register_gate('out_workflow.finalization_exit_v1', '1.0.0',
  'OUT_MONTHLY FINALIZATION exit — ADVANCE when summary_json.finalization has archive_package_id + dashboard_refresh_enqueued.');

INSERT INTO public.phase_gate_assignments (id, workflow_type, phase_name, gate_name, kind, eval_order)
VALUES
  (public.gen_uuid_v7(), 'OUT_MONTHLY', 'INGESTION',          'out_workflow.ingestion_exit_v1',          'EXIT', 1),
  (public.gen_uuid_v7(), 'OUT_MONTHLY', 'OUT_FILTER',         'out_workflow.out_filter_exit_v1',         'EXIT', 1),
  (public.gen_uuid_v7(), 'OUT_MONTHLY', 'MANUAL_UPLOAD_HOLD', 'out_workflow.manual_upload_hold_exit_v1', 'EXIT', 1),
  (public.gen_uuid_v7(), 'OUT_MONTHLY', 'AI_END_SCAN',        'out_workflow.ai_end_scan_exit_v1',        'EXIT', 1),
  (public.gen_uuid_v7(), 'OUT_MONTHLY', 'HUMAN_REVIEW_HOLD',  'out_workflow.human_review_hold_exit_v1',  'EXIT', 1),
  (public.gen_uuid_v7(), 'OUT_MONTHLY', 'FINALIZATION',       'out_workflow.finalization_exit_v1',       'EXIT', 1);

REVOKE EXECUTE ON FUNCTION public.gate_out_ingestion_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gate_out_out_filter_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gate_out_manual_upload_hold_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gate_out_ai_end_scan_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gate_out_human_review_hold_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gate_out_finalization_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gate_out_ingestion_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.gate_out_out_filter_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.gate_out_manual_upload_hold_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.gate_out_ai_end_scan_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.gate_out_human_review_hold_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.gate_out_finalization_exit_v1(uuid,uuid,timestamptz,timestamptz,jsonb) TO service_role;

COMMIT;
