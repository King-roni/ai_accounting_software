-- B14·P08 fix-up: FOR UPDATE doesn't work on the nullable side of a LEFT
-- JOIN, so the registry-joined SELECT inside both rescan functions needs
-- "FOR UPDATE OF ri" scoped to the review_issues alias. The original
-- migration emitted plain FOR UPDATE which Postgres rejects with 0A000
-- at runtime. Re-emit both functions with the corrected lock target.

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
     FOR UPDATE OF ri
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
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','WORKFLOW_RUN_NOT_FOUND'); END IF;

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
     FOR UPDATE OF ri
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
