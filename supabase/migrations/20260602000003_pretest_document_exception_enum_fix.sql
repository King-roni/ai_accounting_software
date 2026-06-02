-- =============================================================================
-- Pretest fix (2026-06-02) — C1b: out_workflow_document_exception invalid enum
-- =============================================================================
-- out_workflow_document_exception (the downstream of MARK_AS_NO_INVOICE_AVAILABLE)
-- wrote review_issues.resolution_action = 'exception_documented', which is NOT a
-- member of resolution_action_kind_enum → 22P02, so resolving a missing-document
-- issue in the review queue (apply_resolution_action) failed with a 400. Use the
-- valid action value that triggered it. Body otherwise verbatim.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.out_workflow_document_exception(p_organization_id uuid, p_business_id uuid, p_run_id uuid, p_transaction_id uuid, p_exception_reason text, p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
DECLARE
  v_prior public.transaction_match_status_enum;
  v_closed_issues int;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.document_exception: actor_user_id required' USING ERRCODE='22000';
  END IF;
  IF p_exception_reason IS NULL OR length(btrim(p_exception_reason)) = 0 THEN
    RAISE EXCEPTION 'out_workflow.document_exception: exception_reason required and must be non-empty' USING ERRCODE='22000';
  END IF;

  SELECT match_status INTO v_prior FROM public.transactions
    WHERE id=p_transaction_id AND business_id=p_business_id;

  UPDATE public.transactions
     SET match_status = 'EXCEPTION_DOCUMENTED'::public.transaction_match_status_enum,
         exception_reason = btrim(p_exception_reason),
         exception_documented_by = p_actor_user_id,
         exception_documented_at = v_now,
         updated_at = v_now
   WHERE id = p_transaction_id;

  UPDATE public.review_issues
     SET status = 'RESOLVED'::public.review_issue_status_enum,
         resolution_action = 'MARK_AS_NO_INVOICE_AVAILABLE'::public.resolution_action_kind_enum,
         resolution_note = format('Exception documented: %s', btrim(p_exception_reason)),
         resolved_by = p_actor_user_id,
         resolved_at = v_now,
         updated_at = v_now
   WHERE transaction_id = p_transaction_id
     AND issue_group = 'MISSING_DOCUMENTS'::public.review_issue_group_enum
     AND status = 'OPEN'::public.review_issue_status_enum;
  GET DIAGNOSTICS v_closed_issues = ROW_COUNT;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_manual_upload_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object('match_status', v_prior::text),
    p_after_state:=jsonb_build_object(
      'match_status', 'EXCEPTION_DOCUMENTED',
      'exception_reason', btrim(p_exception_reason),
      'exception_documented_by', p_actor_user_id,
      'exception_documented_at', v_now,
      'workflow_run_id', p_run_id,
      'closed_review_issue_count', v_closed_issues),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','APPLIED', 'transaction_id', p_transaction_id,
    'closed_review_issue_count', v_closed_issues);
END;
$function$;
