-- B14·P08 — Re-Scan on Resolution
-- =====================================================================
-- Targeted rescan: every terminal resolution kicks off a one-hop entity
-- sweep over OPEN issues sharing transaction_id / document_id /
-- match_record_id with the resolved issue. Per-issue revalidation runs
-- inside savepoints (failures isolated to LOW follow-ups). Manual mode
-- (rescan_manually) widens scope to all OPEN issues in a workflow_run.
-- Recursion guard prevents re-scan from triggering another re-scan.
-- =====================================================================

SELECT public.register_issue_type(
  'review_queue.rescan_revalidation_failed',
  'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
  'LOW'::public.review_issue_severity_enum,
  ARRAY['ADD_EXPLANATION_NOTE','RERUN_SCAN_AFTER_CHANGE','IGNORE_WITH_REASON'],
  'review_queue',
  'review_queue.card_content_default'
);

UPDATE public.issue_type_registry
   SET validity_check_fn_ref = 'classification.unknown_type_validity'
 WHERE issue_type = 'classification.unknown_type';


CREATE OR REPLACE FUNCTION public._revalidate_issue_default(
  p_issue_id uuid,
  p_context  jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN jsonb_build_object('still_valid', true, 'reason', 'default_check_no_auto_close');
END;
$$;


CREATE OR REPLACE FUNCTION public._revalidate_issue_classification_unknown(
  p_issue_id uuid,
  p_context  jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_txn_id uuid;
  v_status text;
BEGIN
  SELECT transaction_id INTO v_txn_id FROM public.review_issues WHERE id = p_issue_id;
  IF v_txn_id IS NULL THEN
    RETURN jsonb_build_object('still_valid', true, 'reason', 'no_transaction_anchor');
  END IF;
  SELECT classification_status::text INTO v_status FROM public.transactions WHERE id = v_txn_id;
  IF v_status IS NULL THEN
    RETURN jsonb_build_object('still_valid', true, 'reason', 'transaction_not_found');
  END IF;
  IF v_status = 'PENDING' OR v_status = 'NEEDS_CONFIRMATION' THEN
    RETURN jsonb_build_object('still_valid', true, 'classification_status', v_status);
  END IF;
  RETURN jsonb_build_object(
    'still_valid', false,
    'action', 'AUTO_CLOSE',
    'reason', 'classification_status_no_longer_unknown',
    'classification_status', v_status);
END;
$$;


CREATE OR REPLACE FUNCTION public._dispatch_validity_check(
  p_issue_id uuid,
  p_fn_ref   text,
  p_context  jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_fn_ref IS NULL OR p_fn_ref = 'default' THEN
    RETURN public._revalidate_issue_default(p_issue_id, p_context);
  ELSIF p_fn_ref = 'classification.unknown_type_validity' THEN
    RETURN public._revalidate_issue_classification_unknown(p_issue_id, p_context);
  END IF;
  RETURN jsonb_build_object('still_valid', true, 'reason', 'unknown_validity_fn_ref',
                            'fn_ref', p_fn_ref);
END;
$$;


CREATE OR REPLACE FUNCTION public.rescan_for_resolved_issue(
  p_resolved_issue_id uuid,
  p_run_id            uuid DEFAULT NULL,
  p_actor_user_id     uuid DEFAULT NULL,
  p_context           jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_resolved      record;
  v_affected_ids  uuid[] := '{}';
  v_aff           record;
  v_check         jsonb;
  v_rescanned     int := 0;
  v_auto_closed   int := 0;
  v_severity_chg  int := 0;
  v_failures      int := 0;
  v_new_severity  public.review_issue_severity_enum;
  v_fail_id       uuid;
BEGIN
  IF COALESCE((p_context->>'is_rescan_recursion')::boolean, false) THEN
    RETURN jsonb_build_object('decision','ALLOW','noop',true,'reason','RECURSION_GUARD');
  END IF;

  SELECT id, organization_id, business_id,
         transaction_id, document_id, match_record_id, workflow_run_id
    INTO v_resolved FROM public.review_issues WHERE id = p_resolved_issue_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','RESOLVED_ISSUE_NOT_FOUND');
  END IF;

  SELECT array_agg(id) INTO v_affected_ids
    FROM (
      SELECT DISTINCT id FROM public.review_issues
       WHERE business_id = v_resolved.business_id
         AND status = 'OPEN'::public.review_issue_status_enum
         AND id <> p_resolved_issue_id
         AND (
           (v_resolved.transaction_id IS NOT NULL AND transaction_id = v_resolved.transaction_id) OR
           (v_resolved.document_id    IS NOT NULL AND document_id    = v_resolved.document_id) OR
           (v_resolved.match_record_id IS NOT NULL AND match_record_id = v_resolved.match_record_id)
         )
    ) sub;
  v_affected_ids := COALESCE(v_affected_ids, '{}');

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='REVIEW_RESCAN_TRIGGERED_AUTOMATICALLY',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_resolved_issue_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='review_queue_rescan',
    p_organization_id:=v_resolved.organization_id, p_business_id:=v_resolved.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'triggering_resolved_issue_id', p_resolved_issue_id,
      'workflow_run_id', COALESCE(p_run_id, v_resolved.workflow_run_id),
      'affected_count', cardinality(v_affected_ids)),
    p_reason:=NULL, p_request_context:=p_context);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='REVIEW_RESCAN_AFFECTED_SET_COMPUTED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_resolved_issue_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='review_queue_rescan',
    p_organization_id:=v_resolved.organization_id, p_business_id:=v_resolved.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'affected_issue_ids', to_jsonb(v_affected_ids),
      'count', cardinality(v_affected_ids)),
    p_reason:=NULL, p_request_context:=p_context);

  FOR v_aff IN
    SELECT ri.id, ri.organization_id, ri.business_id, ri.issue_type,
           ri.status, ri.severity,
           itr.validity_check_fn_ref
      FROM public.review_issues ri
      LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type
     WHERE ri.id = ANY(v_affected_ids)
     FOR UPDATE
  LOOP
    BEGIN
      v_rescanned := v_rescanned + 1;

      IF COALESCE((p_context->>'simulate_revalidation_failure')::boolean, false) THEN
        RAISE EXCEPTION 'simulated revalidation failure' USING ERRCODE = 'XX000';
      END IF;

      v_check := public._dispatch_validity_check(v_aff.id, v_aff.validity_check_fn_ref, p_context);

      IF (v_check->>'still_valid')::boolean = false
         AND (v_check->>'action') = 'AUTO_CLOSE' THEN
        UPDATE public.review_issues
           SET status = 'AUTO_RESOLVED_BY_RESCAN'::public.review_issue_status_enum,
               auto_resolution_trigger_issue_id = p_resolved_issue_id,
               resolved_at = clock_timestamp(),
               updated_at  = clock_timestamp()
         WHERE id = v_aff.id;
        v_auto_closed := v_auto_closed + 1;
        PERFORM audit.emit_audit(
          p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
          p_action:='REVIEW_RESCAN_ISSUE_AUTO_RESOLVED',
          p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
          p_subject_id:=v_aff.id,
          p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
          p_actor_system:='review_queue_rescan',
          p_organization_id:=v_aff.organization_id, p_business_id:=v_aff.business_id,
          p_before_state:=jsonb_build_object('status', v_aff.status::text),
          p_after_state:=jsonb_build_object(
            'status','AUTO_RESOLVED_BY_RESCAN',
            'triggering_resolved_issue_id', p_resolved_issue_id,
            'check_result', v_check),
          p_reason:=NULL, p_request_context:=p_context);
      ELSIF (v_check ? 'new_severity') THEN
        v_new_severity := (v_check->>'new_severity')::public.review_issue_severity_enum;
        IF v_new_severity <> v_aff.severity THEN
          IF v_aff.status = 'SNOOZED'::public.review_issue_status_enum
             AND v_new_severity IN ('HIGH'::public.review_issue_severity_enum,
                                    'BLOCKING'::public.review_issue_severity_enum) THEN
            PERFORM public.auto_clear_snooze_on_severity_elevation(v_aff.id, v_new_severity, p_context);
          ELSE
            UPDATE public.review_issues
               SET severity = v_new_severity, updated_at = clock_timestamp()
             WHERE id = v_aff.id;
          END IF;
          v_severity_chg := v_severity_chg + 1;
          PERFORM audit.emit_audit(
            p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
            p_action:='REVIEW_RESCAN_ISSUE_SEVERITY_CHANGED',
            p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
            p_subject_id:=v_aff.id,
            p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
            p_actor_system:='review_queue_rescan',
            p_organization_id:=v_aff.organization_id, p_business_id:=v_aff.business_id,
            p_before_state:=jsonb_build_object('severity', v_aff.severity::text),
            p_after_state:=jsonb_build_object(
              'severity', v_new_severity::text,
              'triggering_resolved_issue_id', p_resolved_issue_id),
            p_reason:=NULL, p_request_context:=p_context);
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures + 1;
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
        p_action:='REVIEW_RESCAN_REVALIDATION_FAILED',
        p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
        p_subject_id:=v_aff.id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='review_queue_rescan',
        p_organization_id:=v_aff.organization_id, p_business_id:=v_aff.business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object(
          'sqlstate', SQLSTATE, 'message', SQLERRM,
          'triggering_resolved_issue_id', p_resolved_issue_id),
        p_reason:=NULL, p_request_context:=p_context);
      INSERT INTO public.review_issues (
        organization_id, business_id, workflow_run_id,
        transaction_id, document_id, match_record_id, draft_ledger_entry_id,
        invoice_id, client_id,
        issue_type, issue_group, severity,
        plain_language_title, plain_language_description, recommended_action,
        card_payload_json, card_content_generated_at,
        card_content_tier_used, card_content_fallback_applied, status
      ) SELECT
        ri.organization_id, ri.business_id, ri.workflow_run_id,
        ri.transaction_id, ri.document_id, ri.match_record_id, ri.draft_ledger_entry_id,
        ri.invoice_id, ri.client_id,
        'review_queue.rescan_revalidation_failed',
        'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
        'LOW'::public.review_issue_severity_enum,
        'Rescan revalidation failed',
        'A targeted rescan could not revalidate this issue. Re-run scan manually or document via note.',
        'RERUN_SCAN_AFTER_CHANGE',
        jsonb_build_object('failed_issue_id', v_aff.id, 'sqlstate', SQLSTATE),
        clock_timestamp(),
        'NONE'::public.review_issue_card_content_tier_enum,
        false,
        'OPEN'::public.review_issue_status_enum
        FROM public.review_issues ri WHERE ri.id = v_aff.id
        RETURNING id INTO v_fail_id;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'triggering_resolved_issue_id', p_resolved_issue_id,
    'affected_count', cardinality(v_affected_ids),
    'rescanned', v_rescanned,
    'auto_resolved', v_auto_closed,
    'severity_changes', v_severity_chg,
    'failures', v_failures);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.rescan_for_resolved_issue(uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rescan_for_resolved_issue(uuid, uuid, uuid, jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.rescan_manually(
  p_run_id        uuid,
  p_actor_user_id uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run         record;
  v_aff         record;
  v_check       jsonb;
  v_rescanned   int := 0;
  v_auto_closed int := 0;
  v_severity_chg int := 0;
  v_failures    int := 0;
BEGIN
  SELECT id, organization_id, business_id INTO v_run
    FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','WORKFLOW_RUN_NOT_FOUND');
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_RESCAN_TRIGGERED_MANUALLY',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('workflow_run_id', p_run_id, 'mode', 'manual_widened'),
    p_reason:=NULL, p_request_context:=p_context);

  FOR v_aff IN
    SELECT ri.id, ri.organization_id, ri.business_id, ri.issue_type,
           ri.status, ri.severity,
           itr.validity_check_fn_ref
      FROM public.review_issues ri
      LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type
     WHERE ri.workflow_run_id = p_run_id
       AND ri.status = 'OPEN'::public.review_issue_status_enum
     FOR UPDATE
  LOOP
    BEGIN
      v_rescanned := v_rescanned + 1;
      v_check := public._dispatch_validity_check(v_aff.id, v_aff.validity_check_fn_ref, p_context);
      IF (v_check->>'still_valid')::boolean = false
         AND (v_check->>'action') = 'AUTO_CLOSE' THEN
        UPDATE public.review_issues
           SET status = 'AUTO_RESOLVED_BY_RESCAN'::public.review_issue_status_enum,
               auto_resolution_trigger_issue_id = v_aff.id,
               resolved_at = clock_timestamp(),
               updated_at = clock_timestamp()
         WHERE id = v_aff.id;
        v_auto_closed := v_auto_closed + 1;
        PERFORM audit.emit_audit(
          p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
          p_action:='REVIEW_RESCAN_ISSUE_AUTO_RESOLVED',
          p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
          p_subject_id:=v_aff.id,
          p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
          p_actor_system:='review_queue_rescan_manual',
          p_organization_id:=v_aff.organization_id, p_business_id:=v_aff.business_id,
          p_before_state:=jsonb_build_object('status', v_aff.status::text),
          p_after_state:=jsonb_build_object('status','AUTO_RESOLVED_BY_RESCAN',
                                             'mode','manual_widened',
                                             'check_result', v_check),
          p_reason:=NULL, p_request_context:=p_context);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'workflow_run_id', p_run_id,
    'rescanned', v_rescanned,
    'auto_resolved', v_auto_closed,
    'severity_changes', v_severity_chg,
    'failures', v_failures);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.rescan_manually(uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rescan_manually(uuid, uuid, jsonb) TO service_role, authenticated;


-- apply_resolution_action refactor: invoke rescan on terminal resolutions
-- and route RERUN_SCAN_AFTER_CHANGE through rescan_manually. Full body
-- persisted in the applied migration.

CREATE OR REPLACE FUNCTION public.apply_resolution_action(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_action        public.resolution_action_kind_enum,
  p_payload       jsonb DEFAULT '{}'::jsonb,
  p_note          text  DEFAULT NULL,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue       record;
  v_reg         record;
  v_perm        jsonb;
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
    WHEN 'CONFIRM_MATCH'::public.resolution_action_kind_enum THEN
      v_downstream := 'public.user_confirm_match';
      IF v_issue.match_record_id IS NOT NULL THEN
        PERFORM public.user_confirm_match(v_issue.match_record_id, p_actor_user_id,
                                          COALESCE(p_payload->>'counterparty_signature',''), p_context);
      END IF;
    WHEN 'REJECT_MATCH'::public.resolution_action_kind_enum THEN
      v_downstream := 'public.user_reject_match';
      IF v_issue.match_record_id IS NOT NULL THEN
        PERFORM public.user_reject_match(v_issue.match_record_id, p_actor_user_id,
                                         COALESCE(p_payload->>'rejection_reason','user_rejected'), p_context);
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
      'action', v_action_text,
      'status', v_status_after::text,
      'downstream_rpc', v_downstream,
      'payload', p_payload,
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
        p_after_state:=jsonb_build_object(
          'sqlstate', SQLSTATE, 'message', SQLERRM,
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
    'decision', 'ALLOW',
    'action', v_action_text,
    'status_after', v_status_after::text,
    'downstream_rpc', v_downstream,
    'gate_reevaluation_triggered', NOT v_keeps_open,
    'rescan', v_rescan_result);
END;
$$;
