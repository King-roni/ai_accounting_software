-- B14·P07 — Snooze + Cross-Run Carry-Forward
-- =====================================================================
-- Snooze is a non-closing parked state for LOW/MEDIUM issues.
-- HIGH/BLOCKING cannot be snoozed (rejected); if a re-scan elevates a
-- snoozed MEDIUM to HIGH, the snooze auto-clears.
-- Cross-run carry-forward: unsnooze_at_run_start is the FIRST tool of
-- the FIRST phase of every workflow run (INGESTION for OUT/IN_MONTHLY,
-- ADJUSTMENT_INTAKE for OUT/IN_ADJUSTMENT). Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.snooze_apply(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_snooze_reason text,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue   record;
  v_perm    jsonb;
BEGIN
  SELECT id, organization_id, business_id, severity, status
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;

  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_QUEUE_RESOLVE', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  IF v_issue.status <> 'OPEN'::public.review_issue_status_enum THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_STATUS',
                              'current_status', v_issue.status::text);
  END IF;

  IF v_issue.severity IN ('HIGH'::public.review_issue_severity_enum,
                          'BLOCKING'::public.review_issue_severity_enum) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_SNOOZE_REJECTED_SEVERITY',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('severity', v_issue.severity::text),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','SEVERITY_NOT_SNOOZABLE',
                              'severity', v_issue.severity::text);
  END IF;

  IF COALESCE(trim(p_snooze_reason), '') = '' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_SNOOZE_REJECTED_REASON_REQUIRED',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL, p_after_state:=jsonb_build_object('reason_present', false),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
  END IF;

  UPDATE public.review_issues
     SET status = 'SNOOZED'::public.review_issue_status_enum,
         snoozed_at = clock_timestamp(),
         snoozed_by = p_actor_user_id,
         snooze_reason = trim(p_snooze_reason),
         snoozed_until = NULL,
         updated_at = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_SNOOZED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('status', v_issue.status::text),
    p_after_state:=jsonb_build_object('status', 'SNOOZED',
                                       'snooze_reason', trim(p_snooze_reason),
                                       'severity', v_issue.severity::text),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW',
                            'status_after','SNOOZED',
                            'issue_id', p_issue_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.snooze_apply(uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.snooze_apply(uuid, uuid, text, jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.unsnooze_apply(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue   record;
  v_perm    jsonb;
BEGIN
  SELECT id, organization_id, business_id, status, snooze_reason, snoozed_at, snoozed_by
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;
  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_QUEUE_RESOLVE', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;
  IF v_issue.status <> 'SNOOZED'::public.review_issue_status_enum THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_SNOOZED',
                              'current_status', v_issue.status::text);
  END IF;

  UPDATE public.review_issues
     SET status = 'OPEN'::public.review_issue_status_enum,
         snoozed_at = NULL, snoozed_by = NULL,
         snooze_reason = NULL, snoozed_until = NULL,
         updated_at = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_UNSNOOZED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('status','SNOOZED',
                                        'was_snoozed_at', v_issue.snoozed_at,
                                        'snooze_reason', v_issue.snooze_reason),
    p_after_state:=jsonb_build_object('status','OPEN', 'manual', true),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW', 'status_after','OPEN', 'manual', true);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.unsnooze_apply(uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.unsnooze_apply(uuid, uuid, jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.unsnooze_at_run_start(
  p_workflow_run_id uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run   record;
  v_row   record;
  v_count int := 0;
BEGIN
  SELECT id, organization_id, business_id, workflow_type
    INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','WORKFLOW_RUN_NOT_FOUND');
  END IF;

  FOR v_row IN
    SELECT id, snoozed_at, snooze_reason, snoozed_by
      FROM public.review_issues
     WHERE business_id = v_run.business_id
       AND status = 'SNOOZED'::public.review_issue_status_enum
     ORDER BY snoozed_at NULLS LAST
     FOR UPDATE
  LOOP
    UPDATE public.review_issues
       SET status = 'OPEN'::public.review_issue_status_enum,
           snoozed_at = NULL, snoozed_by = NULL,
           snooze_reason = NULL, snoozed_until = NULL,
           updated_at = clock_timestamp()
     WHERE id = v_row.id;

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='REVIEW_UNSNOOZED',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=v_row.id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='review_queue_unsnooze_at_run_start',
      p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
      p_before_state:=jsonb_build_object('status','SNOOZED',
                                          'was_snoozed_at', v_row.snoozed_at,
                                          'snooze_reason', v_row.snooze_reason,
                                          'snoozed_by', v_row.snoozed_by),
      p_after_state:=jsonb_build_object('status','OPEN',
                                         'unsnoozed_by_run_id', p_workflow_run_id,
                                         'unsnoozed_at', clock_timestamp(),
                                         'manual', false),
      p_reason:=NULL, p_request_context:=p_context);
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'unsnoozed_count', v_count,
    'workflow_run_id', p_workflow_run_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.unsnooze_at_run_start(uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.unsnooze_at_run_start(uuid, jsonb) TO service_role;


CREATE OR REPLACE FUNCTION public.auto_clear_snooze_on_severity_elevation(
  p_issue_id    uuid,
  p_new_severity public.review_issue_severity_enum,
  p_context     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue record;
BEGIN
  SELECT id, organization_id, business_id, status, severity, snoozed_at, snooze_reason, snoozed_by
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;
  IF v_issue.status <> 'SNOOZED'::public.review_issue_status_enum THEN
    RETURN jsonb_build_object('decision','ALLOW','noop',true,'reason','NOT_SNOOZED');
  END IF;
  IF p_new_severity NOT IN ('HIGH'::public.review_issue_severity_enum,
                            'BLOCKING'::public.review_issue_severity_enum) THEN
    RETURN jsonb_build_object('decision','ALLOW','noop',true,'reason','SEVERITY_NOT_ELEVATED_BEYOND_SNOOZABLE');
  END IF;

  UPDATE public.review_issues
     SET status = 'OPEN'::public.review_issue_status_enum,
         severity = p_new_severity,
         snoozed_at = NULL, snoozed_by = NULL,
         snooze_reason = NULL, snoozed_until = NULL,
         updated_at = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='REVIEW_SNOOZE_AUTO_CLEARED_SEVERITY_ELEVATED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='review_queue_snooze_auto_clear',
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('status','SNOOZED',
                                        'severity', v_issue.severity::text,
                                        'was_snoozed_at', v_issue.snoozed_at,
                                        'snooze_reason', v_issue.snooze_reason),
    p_after_state:=jsonb_build_object('status','OPEN',
                                       'severity', p_new_severity::text),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW',
                            'status_after','OPEN',
                            'severity_after', p_new_severity::text);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.auto_clear_snooze_on_severity_elevation(uuid, public.review_issue_severity_enum, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.auto_clear_snooze_on_severity_elevation(uuid, public.review_issue_severity_enum, jsonb) TO service_role;


INSERT INTO public.tool_registry (
  tool_name, version, input_schema, output_schema,
  side_effect, ai_tier, failure_semantics,
  retry_max_attempts, retry_backoff_base_ms, retry_backoff_max_ms,
  description, registered_at, updated_at
) VALUES (
  'review_queue.unsnooze_at_run_start', '1.0.0',
  jsonb_build_object('type','object','required', ARRAY['workflow_run_id'],
                     'properties', jsonb_build_object(
                       'workflow_run_id', jsonb_build_object('type','string','format','uuid'))),
  jsonb_build_object('type','object','required', ARRAY['decision','unsnoozed_count'],
                     'properties', jsonb_build_object(
                       'decision', jsonb_build_object('type','string'),
                       'unsnoozed_count', jsonb_build_object('type','integer'))),
  'WRITES_RUN_STATE'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum,
  1, 100, 100,
  'B14·P07: cross-run carry-forward — flip all SNOOZED issues for the run''s business back to OPEN. First tool of the first phase of every workflow run.',
  clock_timestamp(), clock_timestamp()
) ON CONFLICT (tool_name) DO NOTHING;

INSERT INTO public.phase_tool_expectations (
  workflow_type, phase_name, tool_name, permitted_side_effects, required
) VALUES
  ('OUT_MONTHLY'::public.workflow_type_enum, 'INGESTION', 'review_queue.unsnooze_at_run_start',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_MONTHLY'::public.workflow_type_enum, 'INGESTION', 'review_queue.unsnooze_at_run_start',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_ADJUSTMENT'::public.workflow_type_enum, 'ADJUSTMENT_INTAKE', 'review_queue.unsnooze_at_run_start',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('IN_ADJUSTMENT'::public.workflow_type_enum, 'ADJUSTMENT_INTAKE', 'review_queue.unsnooze_at_run_start',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true);


CREATE OR REPLACE FUNCTION public.bulk_snooze_preview(
  p_actor_user_id uuid,
  p_business_id   uuid,
  p_snooze_reason text,
  p_issue_ids     uuid[],
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_perm           jsonb;
  v_org            uuid;
  v_will_apply     uuid[] := '{}';
  v_summary        jsonb;
  v_token_id       uuid;
  v_cnt_will_apply         int := 0;
  v_cnt_skip_closed        int := 0;
  v_cnt_skip_diff_business int := 0;
  v_cnt_skip_severity      int := 0;
  v_cnt_not_found          int := 0;
  v_rec record;
BEGIN
  IF p_issue_ids IS NULL OR cardinality(p_issue_ids) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','EMPTY_ISSUE_IDS');
  END IF;
  IF COALESCE(trim(p_snooze_reason), '') = '' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
  END IF;
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','UNKNOWN_BUSINESS');
  END IF;
  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_QUEUE_RESOLVE', 'EXECUTE',
                               '{}'::jsonb, p_business_id, v_org);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  FOR v_rec IN
    SELECT u.id AS candidate_id, ri.id AS ri_id, ri.business_id, ri.severity, ri.status
      FROM unnest(p_issue_ids) WITH ORDINALITY AS u(id, ord)
      LEFT JOIN public.review_issues ri ON ri.id = u.id
     ORDER BY u.ord
  LOOP
    IF v_rec.ri_id IS NULL THEN v_cnt_not_found := v_cnt_not_found + 1; CONTINUE; END IF;
    IF v_rec.business_id <> p_business_id THEN v_cnt_skip_diff_business := v_cnt_skip_diff_business + 1; CONTINUE; END IF;
    IF v_rec.status <> 'OPEN'::public.review_issue_status_enum THEN v_cnt_skip_closed := v_cnt_skip_closed + 1; CONTINUE; END IF;
    IF v_rec.severity IN ('HIGH'::public.review_issue_severity_enum,
                          'BLOCKING'::public.review_issue_severity_enum) THEN
      v_cnt_skip_severity := v_cnt_skip_severity + 1; CONTINUE;
    END IF;
    v_will_apply := v_will_apply || v_rec.ri_id;
    v_cnt_will_apply := v_cnt_will_apply + 1;
  END LOOP;

  v_summary := jsonb_build_object(
    'will_apply', v_cnt_will_apply,
    'skip_already_closed', v_cnt_skip_closed,
    'skip_different_business', v_cnt_skip_diff_business,
    'skip_snooze_severity_restricted', v_cnt_skip_severity,
    'not_found', v_cnt_not_found);

  IF v_cnt_will_apply = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NO_APPLICABLE_ISSUES','summary', v_summary);
  END IF;

  INSERT INTO public.bulk_preview_tokens (
    organization_id, business_id, actor_user_id, action_kind, affected_issue_ids
  ) VALUES (v_org, p_business_id, p_actor_user_id, 'SNOOZE', v_will_apply)
  RETURNING id INTO v_token_id;

  RETURN jsonb_build_object(
    'decision','ALLOW', 'token_id', v_token_id,
    'will_apply_count', v_cnt_will_apply,
    'summary', v_summary, 'snooze_reason', trim(p_snooze_reason));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bulk_snooze_preview(uuid, uuid, text, uuid[], jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.bulk_snooze_preview(uuid, uuid, text, uuid[], jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.bulk_snooze_apply(
  p_actor_user_id uuid,
  p_token_id      uuid,
  p_snooze_reason text,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_token         record;
  v_id            uuid;
  v_disp          jsonb;
  v_applied_ids   uuid[] := '{}';
  v_skipped       jsonb := '[]'::jsonb;
  v_failures      jsonb := '[]'::jsonb;
  v_requested     int;
  v_applied_count int := 0;
  v_skipped_count int := 0;
  v_failed_count  int := 0;
BEGIN
  SELECT id, organization_id, business_id, actor_user_id, action_kind,
         affected_issue_ids, created_at, expires_at, consumed_at
    INTO v_token FROM public.bulk_preview_tokens WHERE id = p_token_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_NOT_FOUND'); END IF;
  IF v_token.action_kind <> 'SNOOZE' THEN RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_NOT_SNOOZE'); END IF;
  IF v_token.actor_user_id <> p_actor_user_id THEN RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_ACTOR_MISMATCH'); END IF;
  IF v_token.consumed_at IS NOT NULL THEN RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_ALREADY_CONSUMED'); END IF;
  IF v_token.expires_at <= clock_timestamp() THEN RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_EXPIRED'); END IF;
  IF COALESCE(trim(p_snooze_reason), '') = '' THEN RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED'); END IF;

  v_requested := cardinality(v_token.affected_issue_ids);
  UPDATE public.bulk_preview_tokens SET consumed_at = clock_timestamp() WHERE id = p_token_id;

  FOREACH v_id IN ARRAY v_token.affected_issue_ids LOOP
    BEGIN
      v_disp := public.snooze_apply(p_actor_user_id, v_id, p_snooze_reason, p_context);
      IF (v_disp->>'decision') = 'ALLOW' THEN
        v_applied_ids := v_applied_ids || v_id; v_applied_count := v_applied_count + 1;
      ELSE
        v_skipped := v_skipped || jsonb_build_object('issue_id', v_id, 'reason_code', v_disp->>'reason_code');
        v_skipped_count := v_skipped_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures || jsonb_build_object('issue_id', v_id, 'sqlstate', SQLSTATE, 'message', SQLERRM);
      v_failed_count := v_failed_count + 1;
    END;
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_BULK_SNOOZE_APPLIED',
    p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
    p_subject_id:=p_token_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_token.organization_id, p_business_id:=v_token.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'token_id', p_token_id, 'requested', v_requested,
      'applied', v_applied_count, 'skipped', v_skipped_count, 'failed', v_failed_count),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'requested', v_requested, 'applied', v_applied_count, 'applied_ids', to_jsonb(v_applied_ids),
    'skipped_count', v_skipped_count, 'skipped', v_skipped,
    'failed_count', v_failed_count, 'failures', v_failures);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bulk_snooze_apply(uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.bulk_snooze_apply(uuid, uuid, text, jsonb) TO service_role, authenticated;


CREATE OR REPLACE VIEW public.v_active_review_queue AS
  SELECT ri.id, ri.organization_id, ri.business_id, ri.workflow_run_id,
         ri.issue_type, ri.issue_group, ri.severity, ri.status,
         ri.plain_language_title, ri.plain_language_description, ri.recommended_action,
         ri.assigned_to, ri.assigned_at, ri.assigned_by,
         ri.created_at, ri.updated_at,
         itr.allowed_resolution_actions
    FROM public.review_issues ri
    LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type
   WHERE ri.status = 'OPEN'::public.review_issue_status_enum;

COMMENT ON VIEW public.v_active_review_queue IS
  'B14·P07 default queue view: OPEN issues only (SNOOZED/RESOLVED/DISMISSED/AUTO_RESOLVED_BY_RESCAN excluded).';

CREATE OR REPLACE VIEW public.v_snoozed_review_queue AS
  SELECT ri.id, ri.organization_id, ri.business_id, ri.workflow_run_id,
         ri.issue_type, ri.issue_group, ri.severity,
         ri.snoozed_at, ri.snoozed_by, ri.snooze_reason, ri.snoozed_until,
         ri.plain_language_title, ri.plain_language_description, ri.recommended_action,
         ri.created_at, ri.updated_at
    FROM public.review_issues ri
   WHERE ri.status = 'SNOOZED'::public.review_issue_status_enum;

COMMENT ON VIEW public.v_snoozed_review_queue IS
  'B14·P07 snoozed sub-tab view: SNOOZED rows only.';
