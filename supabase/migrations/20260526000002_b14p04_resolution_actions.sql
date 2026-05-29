-- B14·P04 — Resolution Actions
-- =====================================================================
-- Closed 13-value vocabulary + dispatcher RPC that routes user clicks to
-- the right downstream block. The actual state mutations live in the
-- producing blocks; B14's job is allow/deny + routing + status close +
-- canonical audit + gate-reevaluation signal.
-- =====================================================================

CREATE TYPE public.resolution_action_kind_enum AS ENUM (
  'UPLOAD_DOCUMENT',
  'CONFIRM_MATCH',
  'REJECT_MATCH',
  'CHANGE_TAG',
  'CHANGE_TRANSACTION_TYPE',
  'MARK_AS_INTERNAL_TRANSFER',
  'MARK_AS_BANK_FEE',
  'MARK_AS_NON_DEDUCTIBLE',
  'MARK_AS_NO_INVOICE_AVAILABLE',
  'ADD_EXPLANATION_NOTE',
  'SEND_TO_ACCOUNTANT_REVIEW',
  'IGNORE_WITH_REASON',
  'RERUN_SCAN_AFTER_CHANGE'
);

COMMENT ON TYPE public.resolution_action_kind_enum IS
  'B14·P04 closed 13-value resolution vocabulary.';


DROP VIEW IF EXISTS public.v_ready_to_finalize_runs;
DROP VIEW IF EXISTS public.v_blocking_issues;
DROP VIEW IF EXISTS public.v_review_issue_card;

ALTER TABLE public.review_issues
  ALTER COLUMN resolution_action
  TYPE public.resolution_action_kind_enum
  USING resolution_action::public.resolution_action_kind_enum;


UPDATE public.issue_type_registry SET allowed_resolution_actions = CASE issue_type
  WHEN 'matching.no_match_out_expense'         THEN ARRAY['UPLOAD_DOCUMENT','MARK_AS_NO_INVOICE_AVAILABLE','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW','RERUN_SCAN_AFTER_CHANGE']
  WHEN 'matching.matched_needs_confirmation'   THEN ARRAY['CONFIRM_MATCH','REJECT_MATCH','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
  WHEN 'matching.possible_match'               THEN ARRAY['CONFIRM_MATCH','REJECT_MATCH','CHANGE_TAG','ADD_EXPLANATION_NOTE']
  WHEN 'matching.split_payment_proposal'       THEN ARRAY['CONFIRM_MATCH','REJECT_MATCH','ADD_EXPLANATION_NOTE']
  WHEN 'matching.document_used_multiple_times' THEN ARRAY['CONFIRM_MATCH','REJECT_MATCH','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
  WHEN 'classification.unknown_type'           THEN ARRAY['CHANGE_TRANSACTION_TYPE','MARK_AS_INTERNAL_TRANSFER','MARK_AS_BANK_FEE','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
  WHEN 'classification.rule_conflict'          THEN ARRAY['CHANGE_TAG','CHANGE_TRANSACTION_TYPE','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
  WHEN 'dedup.possible_duplicate'              THEN ARRAY['CONFIRM_MATCH','REJECT_MATCH','ADD_EXPLANATION_NOTE']
  WHEN 'endscan.unusual_amount'                THEN ARRAY['ADD_EXPLANATION_NOTE','IGNORE_WITH_REASON','SEND_TO_ACCOUNTANT_REVIEW']
  WHEN 'endscan.large_outlier'                 THEN ARRAY['ADD_EXPLANATION_NOTE','IGNORE_WITH_REASON','SEND_TO_ACCOUNTANT_REVIEW']
  WHEN 'ledger.accountant_review_unknown_treatment' THEN ARRAY['CHANGE_TAG','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW','IGNORE_WITH_REASON']
  WHEN 'ledger.tag_mismatch_detected'          THEN ARRAY['CHANGE_TAG','ADD_EXPLANATION_NOTE']
  WHEN 'ledger.missing_required_evidence'      THEN ARRAY['UPLOAD_DOCUMENT','MARK_AS_NO_INVOICE_AVAILABLE','ADD_EXPLANATION_NOTE']
  WHEN 'ledger.vies_vat_number_missing'        THEN ARRAY['ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
  WHEN 'invoice.numbering_gap_detected'        THEN ARRAY['ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
  ELSE allowed_resolution_actions
END
WHERE issue_type IN (
  'matching.no_match_out_expense','matching.matched_needs_confirmation','matching.possible_match',
  'matching.split_payment_proposal','matching.document_used_multiple_times','classification.unknown_type',
  'classification.rule_conflict','dedup.possible_duplicate','endscan.unusual_amount','endscan.large_outlier',
  'ledger.accountant_review_unknown_treatment','ledger.tag_mismatch_detected','ledger.missing_required_evidence',
  'ledger.vies_vat_number_missing','invoice.numbering_gap_detected');

UPDATE public.issue_type_registry
   SET allowed_resolution_actions = CASE
     WHEN default_group = 'MISSING_DOCUMENTS' AND producing_block IN ('income_matching','document','bank_pipeline')
       THEN ARRAY['UPLOAD_DOCUMENT','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
     WHEN default_group = 'MISSING_DOCUMENTS'
       THEN ARRAY['UPLOAD_DOCUMENT','MARK_AS_NO_INVOICE_AVAILABLE','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
     WHEN default_group = 'NEEDS_CONFIRMATION'
       THEN ARRAY['CONFIRM_MATCH','REJECT_MATCH','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
     WHEN default_group = 'POSSIBLE_WRONG_MATCH'
       THEN ARRAY['REJECT_MATCH','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
     WHEN default_group = 'POSSIBLE_TAX_VAT_ISSUE'
       THEN ARRAY['CHANGE_TAG','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']
     WHEN default_group = 'UNUSUAL_TRANSACTION'
       THEN ARRAY['ADD_EXPLANATION_NOTE','IGNORE_WITH_REASON','SEND_TO_ACCOUNTANT_REVIEW']
     ELSE allowed_resolution_actions
   END
 WHERE 'ACKNOWLEDGE' = ANY(allowed_resolution_actions);

UPDATE public.issue_type_registry
   SET allowed_resolution_actions = ARRAY['ADD_EXPLANATION_NOTE','IGNORE_WITH_REASON']
 WHERE issue_type = 'review_queue.card_content_unavailable';


ALTER TABLE public.issue_type_registry
  ADD CONSTRAINT issue_type_registry_actions_enum_valid_chk
  CHECK (
    allowed_resolution_actions <@ ARRAY[
      'UPLOAD_DOCUMENT','CONFIRM_MATCH','REJECT_MATCH','CHANGE_TAG',
      'CHANGE_TRANSACTION_TYPE','MARK_AS_INTERNAL_TRANSFER','MARK_AS_BANK_FEE',
      'MARK_AS_NON_DEDUCTIBLE','MARK_AS_NO_INVOICE_AVAILABLE','ADD_EXPLANATION_NOTE',
      'SEND_TO_ACCOUNTANT_REVIEW','IGNORE_WITH_REASON','RERUN_SCAN_AFTER_CHANGE']::text[]
  );


CREATE OR REPLACE VIEW public.v_blocking_issues AS
  SELECT *
    FROM public.review_issues
   WHERE severity IN ('HIGH'::public.review_issue_severity_enum,
                      'BLOCKING'::public.review_issue_severity_enum)
     AND status = 'OPEN'::public.review_issue_status_enum;
COMMENT ON VIEW public.v_blocking_issues IS
  'B14·P02 canonical predicate for finalize gates: severity IN (HIGH, BLOCKING) AND status=OPEN.';

CREATE OR REPLACE VIEW public.v_ready_to_finalize_runs AS
  SELECT wr.id AS workflow_run_id, wr.organization_id, wr.business_id, wr.workflow_type,
         wr.status AS workflow_run_status, wr.period_start, wr.period_end,
         (NOT EXISTS (SELECT 1 FROM public.v_blocking_issues bi WHERE bi.workflow_run_id = wr.id)) AS is_ready_to_finalize,
         (SELECT count(*)::int FROM public.v_blocking_issues bi WHERE bi.workflow_run_id = wr.id) AS blocking_issue_count
    FROM public.workflow_runs wr;
COMMENT ON VIEW public.v_ready_to_finalize_runs IS
  'B14·P02 UI projection: per workflow_run, is_ready_to_finalize=true iff no v_blocking_issues.';

CREATE OR REPLACE VIEW public.v_review_issue_card AS
  SELECT ri.id, ri.organization_id, ri.business_id, ri.workflow_run_id,
         ri.transaction_id, ri.document_id, ri.match_record_id,
         ri.draft_ledger_entry_id, ri.invoice_id, ri.client_id,
         ri.issue_type, ri.issue_group, ri.severity, ri.status,
         ri.plain_language_title, ri.plain_language_description, ri.recommended_action,
         ri.card_payload_json,
         ri.card_content_generated_at, ri.card_content_tier_used, ri.card_content_fallback_applied,
         ri.assigned_to, ri.assigned_at, ri.assigned_by,
         ri.snoozed_at, ri.snoozed_until, ri.snooze_reason,
         ri.created_at, ri.updated_at,
         ri.resolved_at, ri.resolved_by, ri.resolution_action, ri.resolution_note,
         ri.auto_resolution_trigger_issue_id,
         itr.producing_block, itr.plain_language_template_ref,
         itr.allowed_resolution_actions, itr.default_severity, itr.default_group
    FROM public.review_issues ri
    LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type;
COMMENT ON VIEW public.v_review_issue_card IS
  'B14·P03 denormalized read model: review_issues joined to issue_type_registry.';


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
BEGIN
  SELECT id, organization_id, business_id, transaction_id, document_id, match_record_id,
         draft_ledger_entry_id, invoice_id, client_id, workflow_run_id,
         issue_type, issue_group, severity, status
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;

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
      v_downstream := 'review_issues.assigned_to UPDATE';
      UPDATE public.review_issues
         SET assigned_to = (p_payload->>'assigned_to')::uuid,
             assigned_by = p_actor_user_id,
             assigned_at = clock_timestamp(),
             updated_at  = clock_timestamp()
       WHERE id = p_issue_id;
    WHEN 'IGNORE_WITH_REASON'::public.resolution_action_kind_enum THEN
      IF COALESCE(p_note,'') = '' THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
      END IF;
      v_terminal := 'DISMISSED'::public.review_issue_status_enum;
      v_downstream := 'review_issues.status → DISMISSED';
    WHEN 'RERUN_SCAN_AFTER_CHANGE'::public.resolution_action_kind_enum THEN
      v_keeps_open := true;
      v_downstream := 'Phase 08 affected-issues re-scan (manual)';
      PERFORM audit.emit_audit(
        p_actor_kind:='USER'::audit.actor_kind_enum,
        p_action:='REVIEW_RESCAN_TRIGGERED_MANUALLY',
        p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
        p_subject_id:=p_issue_id,
        p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
        p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object('triggered_by_resolution', true),
        p_reason:=NULL, p_request_context:=p_context);
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
    p_before_state:=jsonb_build_object('status', v_issue.status::text),
    p_after_state:=jsonb_build_object(
      'action', v_action_text,
      'status', v_status_after::text,
      'downstream_rpc', v_downstream,
      'payload', p_payload,
      'note_present', p_note IS NOT NULL),
    p_reason:=NULL, p_request_context:=p_context);

  IF NOT v_keeps_open THEN
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
    'gate_reevaluation_triggered', NOT v_keeps_open);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.apply_resolution_action(uuid, uuid, public.resolution_action_kind_enum, jsonb, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.apply_resolution_action(uuid, uuid, public.resolution_action_kind_enum, jsonb, text, jsonb) TO service_role, authenticated;


CREATE OR REPLACE VIEW public.v_issue_resolution_options AS
  SELECT ri.id AS review_issue_id,
         ri.organization_id, ri.business_id,
         ri.issue_type, ri.issue_group, ri.severity, ri.status,
         itr.allowed_resolution_actions,
         CASE
           WHEN ri.severity = 'BLOCKING'::public.review_issue_severity_enum
           THEN array_remove(itr.allowed_resolution_actions, 'IGNORE_WITH_REASON')
           ELSE itr.allowed_resolution_actions
         END AS effective_actions_for_severity
    FROM public.review_issues ri
    LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type
   WHERE ri.status = 'OPEN'::public.review_issue_status_enum;

COMMENT ON VIEW public.v_issue_resolution_options IS
  'B14·P04 UI helper: per OPEN review_issue, what actions are allowed (registry) and which survive the severity filter (BLOCKING strips IGNORE_WITH_REASON).';
