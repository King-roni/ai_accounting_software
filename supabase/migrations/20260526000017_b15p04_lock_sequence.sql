-- B15·P04 — The Lock Sequence
-- 8-step atomic finalization: AWAITING_APPROVAL → FINALIZING → FINALIZED
-- with archive package + locked ledger + canonical audit pair.

ALTER TABLE public.workflow_runs
  ADD COLUMN IF NOT EXISTS archive_package_id uuid REFERENCES public.archive_packages(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS workflow_runs_archive_package_id_idx
  ON public.workflow_runs (archive_package_id);

INSERT INTO public.permission_matrix (role, surface, decision) VALUES
  ('OWNER',      'workflow_run', 'REQUIRE_STEP_UP'),
  ('ADMIN',      'workflow_run', 'REQUIRE_STEP_UP'),
  ('BOOKKEEPER', 'workflow_run', 'DENY'),
  ('ACCOUNTANT', 'workflow_run', 'DENY'),
  ('REVIEWER',   'workflow_run', 'DENY'),
  ('READ_ONLY',  'workflow_run', 'DENY')
ON CONFLICT (role, surface) DO UPDATE SET decision = EXCLUDED.decision;

INSERT INTO public.issue_type_registry (issue_type, default_group, default_severity,
  allowed_resolution_actions, producing_block, plain_language_template_ref,
  validity_check_fn_ref, registered_at)
VALUES
  ('finalization.evidence_hash_mismatch',
   'MISSING_DOCUMENTS'::public.review_issue_group_enum,
   'BLOCKING'::public.review_issue_severity_enum,
   ARRAY['ADD_EXPLANATION_NOTE','RERUN_SCAN_AFTER_CHANGE']::public.resolution_action_kind_enum[],
   'B15', 'review_queue.card_content_default', NULL, clock_timestamp()),
  ('finalization.lock_sequence_failed',
   'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
   'HIGH'::public.review_issue_severity_enum,
   ARRAY['ADD_EXPLANATION_NOTE','RERUN_SCAN_AFTER_CHANGE']::public.resolution_action_kind_enum[],
   'B15', 'review_queue.card_content_default', NULL, clock_timestamp()),
  ('finalization.object_lock_failed',
   'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
   'HIGH'::public.review_issue_severity_enum,
   ARRAY['ADD_EXPLANATION_NOTE','RERUN_SCAN_AFTER_CHANGE']::public.resolution_action_kind_enum[],
   'B15', 'review_queue.card_content_default', NULL, clock_timestamp())
ON CONFLICT (issue_type) DO NOTHING;

CREATE OR REPLACE FUNCTION public._verify_evidence_hashes(
  p_run_id uuid, p_business_id uuid, p_period_start timestamptz, p_period_end timestamptz
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_bad_docs int; v_bad_pdfs int;
BEGIN
  SELECT count(*) INTO v_bad_docs
    FROM public.match_records mr
    JOIN public.documents d ON d.id = mr.document_id
    JOIN public.transactions t ON t.id = mr.transaction_id
   WHERE t.business_id = p_business_id
     AND t.transaction_date BETWEEN p_period_start::date AND p_period_end::date
     AND (d.document_hash IS NULL OR d.document_hash !~ '^[0-9a-f]{64}$');

  SELECT count(*) INTO v_bad_pdfs
    FROM public.evidence_pdfs e
    JOIN public.transactions t ON t.id = e.transaction_id
   WHERE t.business_id = p_business_id
     AND t.transaction_date BETWEEN p_period_start::date AND p_period_end::date
     AND (e.file_hash IS NULL OR e.file_hash !~ '^[0-9a-f]{64}$');

  IF v_bad_docs + v_bad_pdfs = 0 THEN
    RETURN jsonb_build_object('ok', true);
  END IF;
  RETURN jsonb_build_object('ok', false,
    'bad_document_hashes', v_bad_docs,
    'bad_evidence_pdf_hashes', v_bad_pdfs);
END;
$$;

CREATE OR REPLACE FUNCTION public._construct_archive_bundle_stub(
  p_run_id uuid, p_business_id uuid, p_organization_id uuid,
  p_period_start date, p_period_end date, p_started_by uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_pkg_id uuid := public.gen_uuid_v7();
  v_manifest_id uuid := public.gen_uuid_v7();
  v_bundle_hash text;
  v_manifest_hash text;
BEGIN
  SELECT encode(digest(coalesce(string_agg(t.transaction_fingerprint, '' ORDER BY t.id), '')
                       || p_run_id::text, 'sha256'), 'hex')
    INTO v_bundle_hash
    FROM public.transactions t
   WHERE t.business_id = p_business_id
     AND t.transaction_date BETWEEN p_period_start AND p_period_end;
  v_bundle_hash := coalesce(v_bundle_hash, repeat('0', 64));

  INSERT INTO public.archive_packages (id, organization_id, business_id, workflow_run_id,
    period_start, period_end, package_storage_object_id, bundle_hash_anchor,
    created_by_user_id, step_up_auth_used, original_finalization)
  VALUES (v_pkg_id, p_organization_id, p_business_id, p_run_id,
          p_period_start, p_period_end,
          format('archive/%s/%s/v1.zip', p_business_id, p_run_id),
          v_bundle_hash, p_started_by, true, true);

  v_manifest_hash := encode(digest(v_pkg_id::text || '|v1|' || v_bundle_hash, 'sha256'), 'hex');
  INSERT INTO public.archive_manifests (id, organization_id, business_id, archive_package_id,
    manifest_version_number, manifest_storage_object_id, manifest_hash,
    produced_by_run_id, produced_by_approval_id)
  VALUES (v_manifest_id, p_organization_id, p_business_id, v_pkg_id,
          1, format('archive/%s/%s/manifest_v1.json', p_business_id, p_run_id),
          v_manifest_hash, p_run_id,
          public.latest_qualifying_step_up_approval(p_business_id, p_run_id));

  RETURN v_pkg_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._promote_to_locked_ledger(
  p_run_id uuid, p_business_id uuid, p_organization_id uuid,
  p_period_start date, p_period_end date, p_archive_package_id uuid
) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, archive, pg_temp
AS $$
DECLARE v_count int;
BEGIN
  PERFORM set_config('app.original_lock_active', '1', true);
  WITH dle_in_period AS (
    SELECT dle.* FROM public.draft_ledger_entries dle
      JOIN public.transactions t ON t.id = dle.parent_transaction_id
     WHERE t.business_id = p_business_id
       AND t.transaction_date BETWEEN p_period_start AND p_period_end
  ),
  ins AS (
    INSERT INTO archive.locked_ledger_entries (
      id, organization_id, business_id, parent_transaction_id, match_record_id,
      entry_kind, debit_account_code, credit_account_code, debit_amount, credit_amount,
      currency, entry_period, counterparty_country, counterparty_vat_number, vat_treatment,
      input_vat_reclaimable_flag, input_vat_reclaimable_amount, output_vat_due_flag,
      output_vat_due_amount, reverse_charge_relevant, vies_relevant, requires_contract,
      requires_invoice, requires_receipt, requires_accountant_review, accountant_review_reason,
      chart_mapping_version_id, vat_rate_table_version, status, created_at, last_recomputed_at,
      entry_currency_original, entry_amount_original, vies_period, vies_value_basis_eur,
      vat_treatment_explanation, manual_override_by, manual_override_reason, manual_override_at,
      archive_package_id, archive_manifest_version)
    SELECT id, organization_id, business_id, parent_transaction_id, match_record_id,
           entry_kind, debit_account_code, credit_account_code, debit_amount, credit_amount,
           currency, entry_period, counterparty_country, counterparty_vat_number, vat_treatment,
           input_vat_reclaimable_flag, input_vat_reclaimable_amount, output_vat_due_flag,
           output_vat_due_amount, reverse_charge_relevant, vies_relevant, requires_contract,
           requires_invoice, requires_receipt, requires_accountant_review, accountant_review_reason,
           chart_mapping_version_id, vat_rate_table_version, status, created_at, last_recomputed_at,
           entry_currency_original, entry_amount_original, vies_period, vies_value_basis_eur,
           vat_treatment_explanation, manual_override_by, manual_override_reason, manual_override_at,
           p_archive_package_id, 1
      FROM dle_in_period
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM ins;
  PERFORM set_config('app.original_lock_active', '0', true);
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public._apply_object_lock_stub(
  p_archive_package_id uuid, p_attempt int, p_context jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_mode text;
BEGIN
  v_mode := COALESCE(p_context->>'simulate_step_5_failure', '');
  IF v_mode = 'PERSISTENT' THEN
    RETURN jsonb_build_object('ok', false, 'mode', 'PERSISTENT');
  ELSIF v_mode = 'TRANSIENT' AND p_attempt = 1 THEN
    RETURN jsonb_build_object('ok', false, 'mode', 'TRANSIENT');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

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
    INSERT INTO public.review_issues (organization_id, business_id, workflow_run_id, client_id,
      issue_type, issue_group, severity, plain_language_title, plain_language_description,
      card_payload_json, status)
    VALUES (v_run.organization_id, v_run.business_id, p_run_id, NULL,
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
          RAISE EXCEPTION 'TRANSITION_FAILED: % %', v_t->>'reason', v_t->>'message'
            USING ERRCODE='P0001';
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
        RAISE EXCEPTION 'TRANSITION_FAILED: % %', v_t->>'reason', v_t->>'message'
          USING ERRCODE='P0001';
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
    INSERT INTO public.review_issues (organization_id, business_id, workflow_run_id, client_id,
      issue_type, issue_group, severity, plain_language_title, plain_language_description,
      card_payload_json, status)
    VALUES (v_run.organization_id, v_run.business_id, p_run_id, NULL,
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

INSERT INTO public.tool_registry (tool_name, version, input_schema, output_schema,
  side_effect, ai_tier, failure_semantics, description, registered_at)
VALUES (
  'finalization.execute_lock_sequence', '1.0.0',
  jsonb_build_object('run_id','uuid','actor_user_id','uuid','context','jsonb'),
  jsonb_build_object('decision','text','archive_package_id','uuid','locked_ledger_count','int'),
  'WRITES_RUN_STATE'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'FATAL_ON_FIRST_FAIL'::public.tool_failure_semantics_enum,
  'Block 15 Phase 04: 8-step atomic lock sequence — promotes a run from AWAITING_APPROVAL to FINALIZED with archive package + locked ledger + audit pair.',
  clock_timestamp()
) ON CONFLICT (tool_name) DO UPDATE
  SET version = EXCLUDED.version, description = EXCLUDED.description,
      side_effect = EXCLUDED.side_effect, ai_tier = EXCLUDED.ai_tier,
      failure_semantics = EXCLUDED.failure_semantics, updated_at = clock_timestamp();
