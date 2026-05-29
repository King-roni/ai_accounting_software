-- B13·P08 fix-up: filter_in_transactions was creating a new blocker review_issue
-- on every re-run for the same UNKNOWN+IN transaction. Guard with an EXISTS check
-- so re-runs don't accumulate duplicate blockers.

CREATE OR REPLACE FUNCTION public.filter_in_transactions(
  p_organization_id uuid,
  p_business_id     uuid,
  p_workflow_run_id uuid,
  p_period_start    date,
  p_period_end      date,
  p_actor_user_id   uuid DEFAULT NULL,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_txn record;
  v_rule jsonb;
  v_should_include boolean;
  v_requires_blocking boolean;
  v_prev_in_scope boolean;
  v_was_decided boolean;
  v_review_issue_id uuid;
  v_already_blocked boolean;
  v_included int := 0;
  v_excluded int := 0;
  v_unknown_blockers int := 0;
  v_transitioned int := 0;
  v_per_type jsonb := '{}'::jsonb;
  v_type_key text;
  v_current_count int;
  v_transitioned_ids uuid[] := '{}';
BEGIN
  FOR v_txn IN
    SELECT id, transaction_type, direction, in_workflow_in_scope, in_filter_decided_at
      FROM public.transactions
     WHERE business_id = p_business_id
       AND transaction_date BETWEEN p_period_start AND p_period_end
  LOOP
    v_rule := public.get_in_workflow_evidence_rule(v_txn.transaction_type, v_txn.direction);
    v_should_include    := COALESCE((v_rule->>'in_filter_includes')::boolean, false);
    v_requires_blocking := COALESCE((v_rule->>'requires_blocking_review')::boolean, false);
    v_prev_in_scope     := v_txn.in_workflow_in_scope;
    v_was_decided       := v_txn.in_filter_decided_at IS NOT NULL;

    IF v_requires_blocking THEN
      SELECT EXISTS (
        SELECT 1 FROM public.review_issues
         WHERE workflow_run_id = p_workflow_run_id
           AND transaction_id = v_txn.id
           AND issue_type = 'in_filter.unknown_positive_blocker'
           AND status IN ('OPEN','SNOOZED')
      ) INTO v_already_blocked;
      IF NOT v_already_blocked THEN
        INSERT INTO public.review_issues (
          organization_id, business_id, workflow_run_id, transaction_id,
          issue_type, issue_group, severity,
          plain_language_title, plain_language_description, recommended_action,
          card_payload_json
        ) VALUES (
          p_organization_id, p_business_id, p_workflow_run_id, v_txn.id,
          'in_filter.unknown_positive_blocker',
          'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
          'HIGH'::public.review_issue_severity_enum,
          'Incoming transaction needs reclassification',
          'This transaction has direction=IN (incoming money) but is classified as UNKNOWN. The IN workflow cannot match it against an invoice or produce ledger entries until it is reclassified into one of the known IN-side types.',
          'Reclassify the transaction (IN_INCOME, REFUND_IN, INTERNAL_TRANSFER, or LOAN_OR_SHAREHOLDER_MOVEMENT with IN direction).',
          jsonb_build_object('transaction_id', v_txn.id, 'workflow_run_id', p_workflow_run_id)
        ) RETURNING id INTO v_review_issue_id;
        PERFORM audit.emit_audit(
          p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_FILTER_UNKNOWN_POSITIVE_BLOCKER_RAISED',
          p_subject_type:='TRANSACTION'::audit.subject_type_enum, p_subject_id:=v_txn.id,
          p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:='in_filter',
          p_organization_id:=p_organization_id, p_business_id:=p_business_id,
          p_before_state:=NULL,
          p_after_state :=jsonb_build_object('review_issue_id', v_review_issue_id, 'workflow_run_id', p_workflow_run_id),
          p_reason:=NULL, p_request_context:=p_context);
        v_unknown_blockers := v_unknown_blockers + 1;
      END IF;
    END IF;

    IF v_was_decided AND v_prev_in_scope <> v_should_include THEN
      v_transitioned := v_transitioned + 1;
      v_transitioned_ids := v_transitioned_ids || v_txn.id;
    END IF;

    UPDATE public.transactions
       SET in_workflow_in_scope = v_should_include,
           in_filter_decided_at = clock_timestamp(),
           in_filter_decided_by_run_id = p_workflow_run_id,
           updated_at = clock_timestamp()
     WHERE id = v_txn.id;

    IF v_should_include THEN v_included := v_included + 1;
    ELSE v_excluded := v_excluded + 1; END IF;

    v_type_key := v_txn.transaction_type::text;
    v_current_count := COALESCE((v_per_type->>v_type_key)::int, 0);
    v_per_type := v_per_type || jsonb_build_object(v_type_key, v_current_count + 1);
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_FILTER_RAN',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:='in_filter',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'included_count', v_included, 'excluded_count', v_excluded,
      'unknown_blockers_raised', v_unknown_blockers, 'transitioned_count', v_transitioned,
      'per_type_counts', v_per_type,
      'period_start', p_period_start, 'period_end', p_period_end),
    p_reason:=NULL, p_request_context:=p_context);

  IF v_transitioned > 0 THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_FILTER_SCOPE_TRANSITIONED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_workflow_run_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:='in_filter',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object(
        'transitioned_count', v_transitioned,
        'transitioned_ids', to_jsonb(v_transitioned_ids)),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'decision','RAN',
    'included_count', v_included, 'excluded_count', v_excluded,
    'unknown_blockers_raised', v_unknown_blockers, 'transitioned_count', v_transitioned,
    'per_type_counts', v_per_type);
END;
$function$;
