-- B15·P04 fix-up: review_issue_at_least_one_entity_chk requires one of 6 entity FKs.
-- The hash-mismatch and lock-sequence-failed INSERTs were setting workflow_run_id
-- only, which doesn't satisfy the constraint. Anchor on the first transaction in
-- the run's period (or a client_id fallback) when emitting these run-level issues.

CREATE OR REPLACE FUNCTION public.execute_lock_sequence(
  p_run_id uuid, p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, archive, pg_temp
AS $$
DECLARE
  v_run public.workflow_runs;
  v_pkg_id uuid;
  v_locked_count int;
  v_hash_check jsonb;
  v_lock_result jsonb;
  v_attempt int := 0;
  v_max_attempts constant int := 2;
  v_committed boolean := false;
  v_last_error text;
  v_failing_step int;
  v_t jsonb;
  v_period_start date;
  v_period_end date;
  v_issue_id uuid;
  v_anchor_txn_id uuid;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','ERROR','reason','RUN_NOT_FOUND'); END IF;

  IF v_run.status = 'FINALIZED'::public.workflow_run_status_enum THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_NO_OP_ALREADY_FINALIZED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_system:='finalization_lock_sequence',
      p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
      p_after_state:=jsonb_build_object('archive_package_id', v_run.archive_package_id));
    RETURN jsonb_build_object('decision','NO_OP','reason','ALREADY_FINALIZED',
                              'archive_package_id', v_run.archive_package_id);
  END IF;

  v_period_start := v_run.period_start::date;
  v_period_end   := v_run.period_end::date;
  SELECT id INTO v_anchor_txn_id FROM public.transactions
   WHERE business_id = v_run.business_id
     AND transaction_date BETWEEN v_period_start AND v_period_end
   ORDER BY id LIMIT 1;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_LOCK_STARTED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='finalization_lock_sequence',
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_after_state:=jsonb_build_object('run_id', p_run_id,
      'period_start', v_period_start, 'period_end', v_period_end,
      'actor_user_id', p_actor_user_id),
    p_request_context:=p_context);

  v_hash_check := public._verify_evidence_hashes(p_run_id, v_run.business_id, v_run.period_start, v_run.period_end);
  IF NOT (v_hash_check->>'ok')::boolean THEN
    INSERT INTO public.review_issues (organization_id, business_id, workflow_run_id, transaction_id,
      client_id, issue_type, issue_group, severity, plain_language_title, plain_language_description,
      card_payload_json, status)
    VALUES (v_run.organization_id, v_run.business_id, p_run_id, v_anchor_txn_id, NULL,
            'finalization.evidence_hash_mismatch',
            'MISSING_DOCUMENTS'::public.review_issue_group_enum,
            'BLOCKING'::public.review_issue_severity_enum,
            'Evidence hashes failed verification',
            'One or more documents or evidence PDFs have missing or malformed file hashes; cannot finalize.',
            v_hash_check, 'OPEN'::public.review_issue_status_enum)
    RETURNING id INTO v_issue_id;
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_LOCK_ROLLED_BACK',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_system:='finalization_lock_sequence',
      p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
      p_after_state:=jsonb_build_object('failing_step', 2, 'reason', 'EVIDENCE_HASH_MISMATCH',
                                         'review_issue_id', v_issue_id, 'detail', v_hash_check));
    RETURN jsonb_build_object('decision','BLOCKED','reason','EVIDENCE_HASH_MISMATCH',
                              'review_issue_id', v_issue_id, 'detail', v_hash_check);
  END IF;

  FOR v_attempt IN 1..v_max_attempts LOOP
    IF v_attempt = 2 THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_LOCK_RETRY_FIRED',
        p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
        p_actor_system:='finalization_lock_sequence',
        p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
        p_after_state:=jsonb_build_object('attempt', 2, 'last_error', v_last_error));
    END IF;
    BEGIN
      SELECT status INTO v_run.status FROM public.workflow_runs WHERE id = p_run_id;
      IF v_run.status = 'AWAITING_APPROVAL'::public.workflow_run_status_enum THEN
        v_t := public.transition_run(p_run_id, 'FINALIZING'::public.workflow_run_status_enum,
                                     p_actor_user_id, 'lock_sequence_started', true, p_context);
        IF NOT (v_t->>'ok')::boolean THEN
          RAISE EXCEPTION 'TRANSITION_FAILED: % %', v_t->>'reason', v_t->>'message' USING ERRCODE='P0001';
        END IF;
      END IF;
      v_pkg_id := public._construct_archive_bundle_stub(p_run_id, v_run.business_id,
                    v_run.organization_id, v_period_start, v_period_end, p_actor_user_id);
      v_locked_count := public._promote_to_locked_ledger(p_run_id, v_run.business_id,
                          v_run.organization_id, v_period_start, v_period_end, v_pkg_id);
      v_lock_result := public._apply_object_lock_stub(v_pkg_id, v_attempt, p_context);
      IF NOT (v_lock_result->>'ok')::boolean THEN
        v_failing_step := 5;
        RAISE EXCEPTION 'OBJECT_LOCK_FAILED: %', v_lock_result->>'mode' USING ERRCODE='P0001';
      END IF;
      v_t := public.transition_run(p_run_id, 'FINALIZED'::public.workflow_run_status_enum,
                                   p_actor_user_id, 'lock_sequence_committed', true, p_context);
      IF NOT (v_t->>'ok')::boolean THEN
        v_failing_step := 6;
        RAISE EXCEPTION 'TRANSITION_FAILED: % %', v_t->>'reason', v_t->>'message' USING ERRCODE='P0001';
      END IF;
      PERFORM set_config('app.transition_run_active', 'true', true);
      UPDATE public.workflow_runs SET archive_package_id = v_pkg_id WHERE id = p_run_id;
      PERFORM set_config('app.transition_run_active', 'false', true);
      v_committed := true;
      EXIT;
    EXCEPTION WHEN OTHERS THEN
      v_last_error := SQLERRM;
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_LOCK_ROLLED_BACK',
        p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
        p_actor_system:='finalization_lock_sequence',
        p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
        p_after_state:=jsonb_build_object('attempt', v_attempt,
                                           'failing_step', COALESCE(v_failing_step, 0),
                                           'error', v_last_error));
      SELECT status INTO v_run.status FROM public.workflow_runs WHERE id = p_run_id;
      IF v_run.status = 'FINALIZING'::public.workflow_run_status_enum THEN
        v_t := public.transition_run(p_run_id, 'AWAITING_APPROVAL'::public.workflow_run_status_enum,
                                     p_actor_user_id, 'lock_sequence_rolled_back', true, p_context);
      END IF;
      DELETE FROM public.archive_manifests WHERE archive_package_id = v_pkg_id;
      DELETE FROM public.archive_packages  WHERE id                = v_pkg_id;
      v_pkg_id := NULL;
    END;
  END LOOP;

  IF NOT v_committed THEN
    INSERT INTO public.review_issues (organization_id, business_id, workflow_run_id, transaction_id,
      client_id, issue_type, issue_group, severity, plain_language_title, plain_language_description,
      card_payload_json, status)
    VALUES (v_run.organization_id, v_run.business_id, p_run_id, v_anchor_txn_id,
            (SELECT id FROM public.clients WHERE business_id=v_run.business_id ORDER BY id LIMIT 1),
            'finalization.object_lock_failed',
            'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
            'HIGH'::public.review_issue_severity_enum,
            'Lock sequence failed after retry',
            'The finalization lock sequence failed twice; please contact support.',
            jsonb_build_object('last_error', v_last_error),
            'OPEN'::public.review_issue_status_enum)
    RETURNING id INTO v_issue_id;
    RETURN jsonb_build_object('decision','FAILED','reason','LOCK_SEQUENCE_EXHAUSTED',
                              'last_error', v_last_error, 'review_issue_id', v_issue_id);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_LOCK_COMMITTED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='finalization_lock_sequence',
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_after_state:=jsonb_build_object('run_id', p_run_id, 'archive_package_id', v_pkg_id,
      'manifest_version', 1, 'principal_user_id', p_actor_user_id,
      'locked_ledger_count', v_locked_count));

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='ARCHIVE_PROMOTION_COMPLETED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='finalization_lock_sequence',
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_after_state:=jsonb_build_object('archive_package_id', v_pkg_id, 'manifest_version_number', 1,
      'business_id', v_run.business_id,
      'period_start', v_period_start, 'period_end', v_period_end));

  RETURN jsonb_build_object('decision','COMMITTED', 'archive_package_id', v_pkg_id,
                            'locked_ledger_count', v_locked_count, 'manifest_version', 1);
END;
$$;
