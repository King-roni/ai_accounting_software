-- =============================================================================
-- Pretest readiness fix (2026-06-01) — record_classification_user_confirmed
-- =============================================================================
-- Replace the invalid resolution_action literal 'CONFIRM' (not in
-- resolution_action_kind_enum → 22P02 on every call) with the valid
-- 'CONFIRM_CLASSIFICATION' added in 20260601000010. This unblocks the
-- NEEDS_CONFIRMATION → classification_exit gate → finalize path. Body is
-- otherwise byte-identical to the live definition.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_classification_user_confirmed(
  p_review_issue_id uuid, p_transaction_id uuid, p_actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_review public.review_issues%ROWTYPE;
  v_audit_row audit.audit_events;
BEGIN
  IF p_review_issue_id IS NULL OR p_transaction_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'record_classification_user_confirmed: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_confirmed: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  SELECT * INTO v_review FROM public.review_issues WHERE id = p_review_issue_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_user_confirmed: review_issue % not found', p_review_issue_id USING ERRCODE='02000';
  END IF;
  UPDATE public.transactions
    SET classification_status = 'CONFIRMED'::public.transaction_classification_status_enum,
        updated_at = clock_timestamp()
    WHERE id = p_transaction_id;
  UPDATE public.review_issues
    SET status = 'RESOLVED'::public.review_issue_status_enum,
        resolved_by = p_actor_user_id,
        resolved_at = clock_timestamp(),
        resolution_action = 'CONFIRM_CLASSIFICATION'::public.resolution_action_kind_enum,
        updated_at = clock_timestamp()
    WHERE id = p_review_issue_id;
  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'CLASSIFICATION_USER_CONFIRMED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id,
      'review_issue_id', p_review_issue_id,
      'confirmed_type', v_tx.transaction_type::text),
    p_reason => format('user confirmed classification: tx=%s', p_transaction_id));
  RETURN jsonb_build_object('ok', true, 'transaction_id', p_transaction_id, 'audit_event_id', v_audit_row.id);
END;
$function$;
