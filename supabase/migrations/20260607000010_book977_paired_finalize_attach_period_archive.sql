-- =============================================================================
-- BOOK-977 — paired OUT/IN finalize: attach to the period's existing archive.
-- =============================================================================
-- OUT_MONTHLY and IN_MONTHLY are a paired pair for one period. Once OUT finalizes
-- it creates the period's *original* archive package; when the paired IN run is
-- then finalized, execute_lock_sequence tried to construct a second original
-- package for the same period and hit unique constraint
-- archive_packages_original_per_period → finalization.object_lock_failed. So the
-- second side of every period could never finalize.
--
-- Fix (option a): when an original archive already exists for this period (the
-- paired sibling finalized first), finalize this run by *attaching* to that
-- package — transition AWAITING_APPROVAL → FINALIZING → FINALIZED and link
-- archive_package_id — instead of constructing a duplicate. The first side still
-- builds + verifies + locks the period archive as before. Body otherwise verbatim.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.execute_lock_sequence(p_run_id uuid, p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'archive', 'pg_temp'
AS $function$
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
  v_existing_pkg uuid;
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

  -- BOOK-977: the paired sibling (OUT/IN) already created this period's original
  -- archive package; finalize by attaching to it rather than constructing a
  -- duplicate (archive_packages_original_per_period).
  SELECT id INTO v_existing_pkg FROM public.archive_packages
   WHERE business_id = v_run.business_id
     AND period_start = v_period_start AND period_end = v_period_end
     AND original_finalization = true
   ORDER BY created_at LIMIT 1;
  IF v_existing_pkg IS NOT NULL THEN
    IF v_run.status = 'AWAITING_APPROVAL'::public.workflow_run_status_enum THEN
      v_t := public.transition_run(p_run_id, 'FINALIZING'::public.workflow_run_status_enum,
               p_actor_user_id, 'lock_sequence_started (paired period archive exists)', true, p_context);
      IF NOT (v_t->>'ok')::boolean THEN
        RETURN jsonb_build_object('decision','ERROR','reason','TRANSITION_FAILED','detail', v_t);
      END IF;
    END IF;
    v_t := public.transition_run(p_run_id, 'FINALIZED'::public.workflow_run_status_enum,
             p_actor_user_id, 'lock_sequence_committed (attached to period archive)', true, p_context);
    IF NOT (v_t->>'ok')::boolean THEN
      RETURN jsonb_build_object('decision','ERROR','reason','TRANSITION_FAILED','detail', v_t);
    END IF;
    PERFORM set_config('app.transition_run_active', 'true', true);
    UPDATE public.workflow_runs SET archive_package_id = v_existing_pkg WHERE id = p_run_id;
    PERFORM set_config('app.transition_run_active', 'false', true);
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_ATTACHED_TO_PERIOD_ARCHIVE',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_system:='finalization_lock_sequence',
      p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
      p_after_state:=jsonb_build_object('run_id', p_run_id, 'archive_package_id', v_existing_pkg,
        'period_start', v_period_start, 'period_end', v_period_end, 'paired_attach', true),
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','COMMITTED','archive_package_id', v_existing_pkg,
                              'attached_to_period_archive', true, 'manifest_version', 1);
  END IF;

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
    PERFORM public._emit_finalization_failure(p_run_id, v_run.business_id, v_run.organization_id,
              2, 'evidence_hash_mismatch', false, p_context);
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_LOCK_ROLLED_BACK',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_system:='finalization_lock_sequence',
      p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
      p_after_state:=jsonb_build_object('failing_step', 2, 'reason', 'EVIDENCE_HASH_MISMATCH',
                                         'review_issue_id', v_issue_id, 'detail', v_hash_check));
    PERFORM public._emit_persistent_failure(p_run_id, v_run.business_id, v_run.organization_id,
              'evidence_hash_mismatch', 'BLOCKING', v_issue_id, p_context);
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
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_OBJECT_LOCK_APPLIED',
        p_subject_type:='ARCHIVE_PACKAGE'::audit.subject_type_enum, p_subject_id:=v_pkg_id,
        p_actor_system:='finalization_lock_sequence',
        p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
        p_after_state:=jsonb_build_object('archive_package_id', v_pkg_id, 'retention_window_years', 6));
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
      PERFORM public._emit_finalization_failure(p_run_id, v_run.business_id, v_run.organization_id,
                COALESCE(v_failing_step, 0),
                CASE COALESCE(v_failing_step, 0)
                  WHEN 5 THEN 'object_lock_failed'
                  WHEN 6 THEN 'state_transition_conflict'
                  ELSE 'lock_sequence_failed'
                END,
                true,
                p_context);
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
    PERFORM public._emit_persistent_failure(p_run_id, v_run.business_id, v_run.organization_id,
              'object_lock_failed', 'HIGH', v_issue_id, p_context);
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
$function$;
