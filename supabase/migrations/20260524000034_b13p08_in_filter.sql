-- ============================================================================
-- Block 13 Phase 08 — IN_FILTER Phase
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_in_workflow_evidence_rule(
  p_transaction_type public.transaction_type_enum,
  p_direction        public.transaction_direction_enum
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $function$
BEGIN
  IF p_transaction_type IN ('IN_INCOME','REFUND_IN','INTERNAL_TRANSFER') THEN
    RETURN jsonb_build_object('in_filter_includes', true, 'requires_blocking_review', false);
  END IF;
  IF p_transaction_type = 'LOAN_OR_SHAREHOLDER_MOVEMENT' THEN
    IF p_direction = 'IN' THEN
      RETURN jsonb_build_object('in_filter_includes', true, 'requires_blocking_review', false);
    END IF;
    RETURN jsonb_build_object('in_filter_includes', false, 'requires_blocking_review', false);
  END IF;
  IF p_transaction_type = 'UNKNOWN' THEN
    IF p_direction = 'IN' THEN
      RETURN jsonb_build_object('in_filter_includes', true, 'requires_blocking_review', true);
    END IF;
    RETURN jsonb_build_object('in_filter_includes', false, 'requires_blocking_review', false);
  END IF;
  RETURN jsonb_build_object('in_filter_includes', false, 'requires_blocking_review', false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.filter_in_transactions(
  p_organization_id uuid,
  p_business_id     uuid,
  p_workflow_run_id uuid,
  p_period_start    date,
  p_period_end      date,
  p_actor_user_id   uuid DEFAULT NULL,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_txn record;
  v_rule jsonb;
  v_should_include boolean;
  v_requires_blocking boolean;
  v_prev_in_scope boolean;
  v_was_decided boolean;
  v_review_issue_id uuid;
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

INSERT INTO public.tool_registry (
  tool_name, version, input_schema, output_schema,
  side_effect, ai_tier, failure_semantics, dedup_key_generator_ref,
  description, retry_max_attempts, retry_backoff_base_ms, retry_backoff_max_ms
) VALUES (
  'in_workflow.filter_in_transactions', '1.0.0',
  '{"organization_id":"uuid","business_id":"uuid","workflow_run_id":"uuid","period_start":"date","period_end":"date"}'::jsonb,
  '{"decision":"text","included_count":"int","excluded_count":"int","unknown_blockers_raised":"int","transitioned_count":"int","per_type_counts":"jsonb"}'::jsonb,
  'WRITES_RUN_STATE'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum,
  'in_workflow.filter_in_transactions.dedup_key_v1',
  'Block 13 P08 — marks IN-relevant transactions for the period. Deterministic switch on transaction_type + direction.',
  1, 100, 100
)
ON CONFLICT (tool_name) DO NOTHING;

INSERT INTO public.gate_registry (gate_name, version, description) VALUES
  ('in_workflow.in_filter_exit_v1', '1.0.0',
   'Block 13 P08 — IN_FILTER exit gate. Returns ALLOW iff every period transaction has in_filter_decided_at IS NOT NULL AND no open in_filter.unknown_positive_blocker review_issues remain.')
ON CONFLICT (gate_name) DO NOTHING;

INSERT INTO public.phase_tool_expectations (workflow_type, phase_name, tool_name, permitted_side_effects, required)
VALUES ('IN_MONTHLY', 'IN_FILTER', 'in_workflow.filter_in_transactions',
        ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true);

INSERT INTO public.phase_gate_assignments (workflow_type, phase_name, gate_name, kind, eval_order)
VALUES ('IN_MONTHLY', 'IN_FILTER', 'in_workflow.in_filter_exit_v1',
        'EXIT'::public.gate_kind_enum, 1);

CREATE OR REPLACE FUNCTION public.gate_in_workflow_in_filter_exit_v1(
  p_workflow_run_id uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_run public.workflow_runs%ROWTYPE;
  v_undecided_count int;
  v_unresolved_blocker_count int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  SELECT count(*) INTO v_undecided_count
    FROM public.transactions
   WHERE business_id = v_run.business_id
     AND transaction_date BETWEEN v_run.period_start::date AND v_run.period_end::date
     AND in_filter_decided_at IS NULL;
  IF v_undecided_count > 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','UNDECIDED_TRANSACTIONS',
      'undecided_count', v_undecided_count);
  END IF;
  SELECT count(*) INTO v_unresolved_blocker_count
    FROM public.review_issues
   WHERE workflow_run_id = p_workflow_run_id
     AND issue_type = 'in_filter.unknown_positive_blocker'
     AND status IN ('OPEN','SNOOZED');
  IF v_unresolved_blocker_count > 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','UNRESOLVED_UNKNOWN_BLOCKERS',
      'unresolved_count', v_unresolved_blocker_count);
  END IF;
  RETURN jsonb_build_object('decision','ALLOW');
END;
$function$;
