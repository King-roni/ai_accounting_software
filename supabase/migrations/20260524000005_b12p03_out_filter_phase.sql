-- B12·P03 — OUT_FILTER Phase
-- =====================================================================
-- Adds the in-scope marker columns to transactions (also adds the IN_FILTER
-- columns Block 13 will need), registers the OUT_FILTER tool, and defines
-- the filter_out_transactions deterministic RPC that switches on
-- transaction.type via the out_workflow_evidence_rules catalog from B12·P02.
--
-- Spec rule: INTERNAL_TRANSFER passes both filters (both flags become true);
-- Block 11 P07's dispatcher dedupes the ledger entry via its delete-and-replace
-- per (txn, version) contract.
--
-- UNKNOWN is surface-and-block: in_scope=true + HIGH POSSIBLE_WRONG_MATCH
-- review_issue + OUT_FILTER_UNKNOWN_BLOCKER_RAISED audit.
--
-- 4 audit actions:
--   OUT_FILTER_RAN                       (WORKFLOW_RUN, end-of-run summary)
--   OUT_FILTER_INCLUDED_TRANSACTION      (TRANSACTION, per included row)
--   OUT_FILTER_UNKNOWN_BLOCKER_RAISED    (TRANSACTION)
--   OUT_FILTER_SCOPE_TRANSITIONED        (TRANSACTION, only on flag flip after a prior decision)
-- =====================================================================

BEGIN;

-- 1. transactions columns
ALTER TABLE public.transactions
  ADD COLUMN out_workflow_in_scope        boolean NOT NULL DEFAULT false,
  ADD COLUMN in_workflow_in_scope         boolean NOT NULL DEFAULT false,
  ADD COLUMN out_filter_decided_at        timestamptz,
  ADD COLUMN out_filter_decided_by_run_id uuid REFERENCES public.workflow_runs(id),
  ADD COLUMN in_filter_decided_at         timestamptz,
  ADD COLUMN in_filter_decided_by_run_id  uuid REFERENCES public.workflow_runs(id);

CREATE INDEX transactions_business_out_scope_idx ON public.transactions (business_id)
  WHERE out_workflow_in_scope = true;
CREATE INDEX transactions_business_in_scope_idx ON public.transactions (business_id)
  WHERE in_workflow_in_scope = true;

COMMENT ON COLUMN public.transactions.out_workflow_in_scope IS
  'Set by OUT_FILTER (B12·P03) when the row is OUT-relevant per the type-aware evidence rules.';
COMMENT ON COLUMN public.transactions.in_workflow_in_scope IS
  'Set by IN_FILTER (Block 13) when the row is IN-relevant. INTERNAL_TRANSFER rows have BOTH flags true by design (dedup at Block 11 P07).';


-- 2. Register the OUT_FILTER tool
SELECT public.register_tool(
  p_tool_name=>'out_workflow.filter_out_transactions', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('business_id','uuid','period_start','date','period_end','date','workflow_run_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','included_count','int','excluded_count','int','unknown_count','int','transitioned_count','int'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.filter_out_transactions.dedup_key_v1',
  p_description=>'OUT_FILTER deterministic phase tool — marks OUT-relevant transactions via out_workflow_in_scope; switches on transaction.type only',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);


-- 3. Filter RPC
CREATE OR REPLACE FUNCTION public.filter_out_transactions(
  p_organization_id uuid, p_business_id uuid,
  p_workflow_run_id uuid,
  p_period_start date, p_period_end date,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_txn record;
  v_rule jsonb;
  v_should_include boolean;
  v_prev_in_scope boolean;
  v_was_decided boolean;
  v_review_issue_id uuid;
  v_included int := 0;
  v_excluded int := 0;
  v_unknown int := 0;
  v_transitioned int := 0;
  v_per_type jsonb := '{}'::jsonb;
  v_type_key text;
  v_current_count int;
BEGIN
  FOR v_txn IN
    SELECT id, transaction_type, direction, out_workflow_in_scope, out_filter_decided_at
      FROM public.transactions
     WHERE business_id = p_business_id
       AND transaction_date BETWEEN p_period_start AND p_period_end
  LOOP
    v_rule := public.get_out_workflow_evidence_rule(v_txn.transaction_type, v_txn.direction);
    v_should_include := COALESCE((v_rule->>'out_filter_includes')::boolean, false);
    v_prev_in_scope  := v_txn.out_workflow_in_scope;
    v_was_decided    := v_txn.out_filter_decided_at IS NOT NULL;

    IF v_txn.transaction_type = 'UNKNOWN' THEN
      v_should_include := true;
      INSERT INTO public.review_issues (
        organization_id, business_id, workflow_run_id, transaction_id,
        issue_type, issue_group, severity,
        plain_language_title, plain_language_description, recommended_action,
        card_payload_json
      ) VALUES (
        p_organization_id, p_business_id, p_workflow_run_id, v_txn.id,
        'out_filter.unknown_blocker',
        'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
        'HIGH'::public.review_issue_severity_enum,
        'Transaction needs reclassification before OUT workflow can advance',
        'This transaction has not been classified into one of the known types; the OUT workflow cannot produce meaningful ledger entries until it is reclassified.',
        'Reclassify the transaction',
        jsonb_build_object('transaction_id', v_txn.id, 'workflow_run_id', p_workflow_run_id)
      ) RETURNING id INTO v_review_issue_id;
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_FILTER_UNKNOWN_BLOCKER_RAISED',
        p_subject_type:='TRANSACTION'::audit.subject_type_enum, p_subject_id:=v_txn.id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='out_filter',
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object('review_issue_id', v_review_issue_id, 'workflow_run_id', p_workflow_run_id),
        p_reason:=NULL, p_request_context:=p_context);
      v_unknown := v_unknown + 1;
    END IF;

    IF v_was_decided AND v_prev_in_scope <> v_should_include THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_FILTER_SCOPE_TRANSITIONED',
        p_subject_type:='TRANSACTION'::audit.subject_type_enum, p_subject_id:=v_txn.id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='out_filter',
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=jsonb_build_object('out_workflow_in_scope', v_prev_in_scope),
        p_after_state:=jsonb_build_object('out_workflow_in_scope', v_should_include,
                                           'transaction_type', v_txn.transaction_type),
        p_reason:=NULL, p_request_context:=p_context);
      v_transitioned := v_transitioned + 1;
    END IF;

    UPDATE public.transactions
       SET out_workflow_in_scope = v_should_include,
           out_filter_decided_at = clock_timestamp(),
           out_filter_decided_by_run_id = p_workflow_run_id,
           updated_at = clock_timestamp()
     WHERE id = v_txn.id;

    IF v_should_include THEN
      v_included := v_included + 1;
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_FILTER_INCLUDED_TRANSACTION',
        p_subject_type:='TRANSACTION'::audit.subject_type_enum, p_subject_id:=v_txn.id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='out_filter',
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object('transaction_type', v_txn.transaction_type,
                                           'direction', v_txn.direction,
                                           'workflow_run_id', p_workflow_run_id),
        p_reason:=NULL, p_request_context:=p_context);
    ELSE
      v_excluded := v_excluded + 1;
    END IF;

    v_type_key := v_txn.transaction_type::text;
    v_current_count := COALESCE((v_per_type->>v_type_key)::int, 0);
    v_per_type := v_per_type || jsonb_build_object(v_type_key, v_current_count + 1);
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_FILTER_RAN',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_filter',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'included_count', v_included, 'excluded_count', v_excluded,
      'unknown_count', v_unknown, 'transitioned_count', v_transitioned,
      'per_type_counts', v_per_type,
      'period_start', p_period_start, 'period_end', p_period_end),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','RAN',
    'included_count', v_included, 'excluded_count', v_excluded,
    'unknown_count', v_unknown, 'transitioned_count', v_transitioned,
    'per_type_counts', v_per_type);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.filter_out_transactions(uuid, uuid, uuid, date, date, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.filter_out_transactions(uuid, uuid, uuid, date, date, uuid, jsonb) TO service_role;

COMMIT;
