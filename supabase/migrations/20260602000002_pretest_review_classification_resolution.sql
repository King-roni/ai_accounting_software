-- =============================================================================
-- Pretest fix (2026-06-02) — C1: review-queue can resolve classification issues
-- =============================================================================
-- apply_resolution_action had no CONFIRM_CLASSIFICATION branch, and
-- classification.needs_confirmation only allowed CONFIRM_MATCH/REJECT_MATCH —
-- whose handlers are no-ops when match_record_id IS NULL (classification issues
-- carry no match_record). So "confirming" a classification closed the issue but
-- left the transaction at NEEDS_CONFIRMATION → the finalization data gates never
-- truly cleared, and there was no honest in-app confirm path.
--
-- (1) apply_resolution_action: add a CONFIRM_CLASSIFICATION branch →
--     record_classification_user_confirmed (sets the txn CONFIRMED), and route
--     REJECT_MATCH on a classification issue → record_classification_user_rejected.
-- (2) issue_type_registry: classification.needs_confirmation now allows
--     CONFIRM_CLASSIFICATION (replacing the misused CONFIRM_MATCH).
-- Body otherwise verbatim from the live definition.
-- =============================================================================

-- The registry's allowed-actions CHECK predates the CONFIRM_CLASSIFICATION enum
-- value (added 20260601000010); widen it so the registry can reference it.
ALTER TABLE public.issue_type_registry
  DROP CONSTRAINT issue_type_registry_actions_enum_valid_chk;
ALTER TABLE public.issue_type_registry
  ADD CONSTRAINT issue_type_registry_actions_enum_valid_chk
  CHECK ((allowed_resolution_actions <@ ARRAY[
    'UPLOAD_DOCUMENT'::text, 'CONFIRM_MATCH'::text, 'REJECT_MATCH'::text, 'CHANGE_TAG'::text,
    'CHANGE_TRANSACTION_TYPE'::text, 'MARK_AS_INTERNAL_TRANSFER'::text, 'MARK_AS_BANK_FEE'::text,
    'MARK_AS_NON_DEDUCTIBLE'::text, 'MARK_AS_NO_INVOICE_AVAILABLE'::text, 'ADD_EXPLANATION_NOTE'::text,
    'SEND_TO_ACCOUNTANT_REVIEW'::text, 'IGNORE_WITH_REASON'::text, 'RERUN_SCAN_AFTER_CHANGE'::text,
    'CONFIRM_CLASSIFICATION'::text]));

CREATE OR REPLACE FUNCTION public.apply_resolution_action(p_actor_user_id uuid, p_issue_id uuid, p_action resolution_action_kind_enum, p_payload jsonb DEFAULT '{}'::jsonb, p_note text DEFAULT NULL::text, p_context jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
DECLARE
  v_issue       record;
  v_reg         record;
  v_perm        jsonb;
  v_guard       jsonb;
  v_status_after public.review_issue_status_enum;
  v_keeps_open   boolean := false;
  v_terminal     public.review_issue_status_enum := 'RESOLVED'::public.review_issue_status_enum;
  v_downstream   text;
  v_action_text  text := p_action::text;
  v_assign_result jsonb;
  v_rescan_result jsonb;
BEGIN
  SELECT id, organization_id, business_id, transaction_id, document_id, match_record_id,
         draft_ledger_entry_id, invoice_id, client_id, workflow_run_id,
         issue_type, issue_group, severity, status, assigned_to
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND'); END IF;

  v_guard := public._check_form_factor_guard('APPLY_RESOLUTION_ACTION', p_context);
  IF (v_guard->>'decision') = 'DENY' THEN RETURN v_guard; END IF;

  SELECT issue_type, allowed_resolution_actions, producing_block
    INTO v_reg FROM public.issue_type_registry WHERE issue_type = v_issue.issue_type;

  IF v_issue.status IN ('RESOLVED'::public.review_issue_status_enum,
                        'DISMISSED'::public.review_issue_status_enum,
                        'AUTO_RESOLVED_BY_RESCAN'::public.review_issue_status_enum) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_NOOP',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('attempted_action', v_action_text, 'current_status', v_issue.status::text),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_ALREADY_CLOSED',
                              'status_after', v_issue.status::text, 'noop', true);
  END IF;

  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_QUEUE_RESOLVE', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_PERMISSION',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('attempted_action', v_action_text, 'reason_code', v_perm->>'reason_code'),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  IF v_reg.allowed_resolution_actions IS NULL OR NOT (v_action_text = ANY(v_reg.allowed_resolution_actions)) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_DISALLOWED_ACTION',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('attempted_action', v_action_text,
                                         'allowed', v_reg.allowed_resolution_actions),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ACTION_NOT_ALLOWED_FOR_ISSUE_TYPE');
  END IF;

  IF p_action = 'IGNORE_WITH_REASON'::public.resolution_action_kind_enum
     AND v_issue.severity = 'BLOCKING'::public.review_issue_severity_enum THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_BLOCKING_DISMISSAL',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('severity', v_issue.severity::text),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','BLOCKING_CANNOT_BE_DISMISSED');
  END IF;

  CASE p_action
    WHEN 'CONFIRM_CLASSIFICATION'::public.resolution_action_kind_enum THEN
      v_downstream := 'public.record_classification_user_confirmed';
      IF v_issue.transaction_id IS NOT NULL THEN
        PERFORM public.record_classification_user_confirmed(
          p_issue_id, v_issue.transaction_id, p_actor_user_id);
      END IF;
    WHEN 'CONFIRM_MATCH'::public.resolution_action_kind_enum THEN
      v_downstream := 'public.user_confirm_match';
      IF v_issue.match_record_id IS NOT NULL THEN
        PERFORM public.user_confirm_match(v_issue.match_record_id, p_actor_user_id,
                                          COALESCE(p_payload->>'counterparty_signature',''), p_context);
      END IF;
    WHEN 'REJECT_MATCH'::public.resolution_action_kind_enum THEN
      IF v_issue.match_record_id IS NOT NULL THEN
        v_downstream := 'public.user_reject_match';
        PERFORM public.user_reject_match(v_issue.match_record_id, p_actor_user_id,
                                         COALESCE(p_payload->>'rejection_reason','user_rejected'), p_context);
      ELSIF v_issue.transaction_id IS NOT NULL AND v_issue.issue_type LIKE 'classification.%' THEN
        v_downstream := 'public.record_classification_user_rejected';
        PERFORM public.record_classification_user_rejected(
          p_issue_id, v_issue.transaction_id, p_actor_user_id, NULL);
      END IF;
    WHEN 'MARK_AS_NO_INVOICE_AVAILABLE'::public.resolution_action_kind_enum THEN
      IF COALESCE(p_payload->>'reason','') = '' THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
      END IF;
      v_downstream := 'public.out_workflow_document_exception';
      IF v_issue.workflow_run_id IS NOT NULL AND v_issue.transaction_id IS NOT NULL THEN
        PERFORM public.out_workflow_document_exception(
          v_issue.organization_id, v_issue.business_id, v_issue.workflow_run_id,
          v_issue.transaction_id, p_payload->>'reason', p_actor_user_id, p_context);
      END IF;
    WHEN 'CHANGE_TAG'::public.resolution_action_kind_enum THEN
      v_downstream := 'transactions.tag UPDATE (Block 08 path — Stage-1 stub)';
    WHEN 'CHANGE_TRANSACTION_TYPE'::public.resolution_action_kind_enum,
         'MARK_AS_INTERNAL_TRANSFER'::public.resolution_action_kind_enum,
         'MARK_AS_BANK_FEE'::public.resolution_action_kind_enum THEN
      v_downstream := 'transactions.transaction_type UPDATE (Block 08 path — Stage-1 stub)';
    WHEN 'MARK_AS_NON_DEDUCTIBLE'::public.resolution_action_kind_enum THEN
      v_downstream := 'draft_ledger_entries non-deductible UPDATE (Block 11 path — Stage-1 stub)';
    WHEN 'UPLOAD_DOCUMENT'::public.resolution_action_kind_enum THEN
      v_downstream := 'intake.manual_upload_handler (Block 09 — Stage-1 stub)';
    WHEN 'ADD_EXPLANATION_NOTE'::public.resolution_action_kind_enum THEN
      IF COALESCE(p_note,'') = '' THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','NOTE_REQUIRED');
      END IF;
      v_keeps_open := true;
      v_downstream := 'review_issues.resolution_note UPDATE';
    WHEN 'SEND_TO_ACCOUNTANT_REVIEW'::public.resolution_action_kind_enum THEN
      IF (p_payload->>'assigned_to') IS NULL THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','ASSIGNED_TO_REQUIRED');
      END IF;
      v_keeps_open := true;
      v_downstream := 'public.review_queue_assign';
      v_assign_result := public.review_queue_assign(
        p_actor_user_id, p_issue_id,
        (p_payload->>'assigned_to')::uuid, p_context);
      IF (v_assign_result->>'decision') <> 'ALLOW' THEN RETURN v_assign_result; END IF;
    WHEN 'IGNORE_WITH_REASON'::public.resolution_action_kind_enum THEN
      IF COALESCE(p_note,'') = '' THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
      END IF;
      v_terminal := 'DISMISSED'::public.review_issue_status_enum;
      v_downstream := 'review_issues.status → DISMISSED';
    WHEN 'RERUN_SCAN_AFTER_CHANGE'::public.resolution_action_kind_enum THEN
      v_keeps_open := true;
      v_downstream := 'public.rescan_manually';
      IF v_issue.workflow_run_id IS NOT NULL THEN
        PERFORM public.rescan_manually(v_issue.workflow_run_id, p_actor_user_id, p_context);
      END IF;
  END CASE;

  IF v_keeps_open THEN
    v_status_after := v_issue.status;
    IF p_action = 'ADD_EXPLANATION_NOTE'::public.resolution_action_kind_enum THEN
      UPDATE public.review_issues
         SET resolution_note = p_note, updated_at = clock_timestamp()
       WHERE id = p_issue_id;
    END IF;
  ELSE
    v_status_after := v_terminal;
    UPDATE public.review_issues
       SET status            = v_terminal,
           resolution_action = p_action,
           resolution_note   = p_note,
           resolved_at       = clock_timestamp(),
           resolved_by       = p_actor_user_id,
           updated_at        = clock_timestamp()
     WHERE id = p_issue_id;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_RESOLUTION_APPLIED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('status', v_issue.status::text,
                                        'assigned_to', v_issue.assigned_to),
    p_after_state:=jsonb_build_object(
      'action', v_action_text, 'status', v_status_after::text,
      'downstream_rpc', v_downstream, 'payload', p_payload,
      'note_present', p_note IS NOT NULL,
      'actor_was_assignee', v_issue.assigned_to IS NOT NULL AND v_issue.assigned_to = p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  IF NOT v_keeps_open THEN
    BEGIN
      v_rescan_result := public.rescan_for_resolved_issue(
        p_issue_id, v_issue.workflow_run_id, p_actor_user_id, p_context);
    EXCEPTION WHEN OTHERS THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
        p_action:='REVIEW_RESCAN_REVALIDATION_FAILED',
        p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
        p_subject_id:=p_issue_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='review_queue_dispatcher',
        p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM,
          'context', 'invoked from apply_resolution_action terminal path'),
        p_reason:=NULL, p_request_context:=p_context);
    END;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='REVIEW_GATE_REEVALUATION_REQUESTED',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='review_queue_dispatcher',
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('triggering_resolution_issue_id', p_issue_id,
                                         'triggering_workflow_run_id', v_issue.workflow_run_id),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'decision', 'ALLOW', 'action', v_action_text,
    'status_after', v_status_after::text, 'downstream_rpc', v_downstream,
    'gate_reevaluation_triggered', NOT v_keeps_open, 'rescan', v_rescan_result);
END;
$function$;

-- classification.needs_confirmation: allow the honest confirm/reject actions.
UPDATE public.issue_type_registry
   SET allowed_resolution_actions =
     ARRAY['CONFIRM_CLASSIFICATION','REJECT_MATCH','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']::public.resolution_action_kind_enum[]
 WHERE issue_type = 'classification.needs_confirmation';
