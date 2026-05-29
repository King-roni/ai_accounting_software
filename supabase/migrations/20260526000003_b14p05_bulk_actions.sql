-- B14·P05 — Bulk Actions
-- =====================================================================
-- Two-phase token-bearing protocol:
--   bulk_preview      : classify candidates → freeze WILL_APPLY set in token
--   bulk_apply_action : redeem token → iterate dispatcher per row (partial OK)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.bulk_preview(
  p_actor_user_id uuid,
  p_business_id   uuid,
  p_action_kind   public.resolution_action_kind_enum,
  p_issue_ids     uuid[],
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_perm           jsonb;
  v_org            uuid;
  v_action_text    text := p_action_kind::text;
  v_will_apply     uuid[] := '{}';
  v_summary        jsonb;
  v_token_id       uuid;
  v_bucket         public.review_issue_group_enum := NULL;
  v_cnt_will_apply         int := 0;
  v_cnt_skip_closed        int := 0;
  v_cnt_skip_diff_bucket   int := 0;
  v_cnt_skip_diff_business int := 0;
  v_cnt_skip_not_allowed   int := 0;
  v_cnt_skip_blocking      int := 0;
  v_cnt_not_found          int := 0;
  v_rec record;
BEGIN
  IF p_issue_ids IS NULL OR cardinality(p_issue_ids) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','EMPTY_ISSUE_IDS');
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
    SELECT ri.id, ri.business_id, ri.issue_group, ri.severity, ri.status,
           itr.allowed_resolution_actions
      FROM unnest(p_issue_ids) WITH ORDINALITY AS u(id, ord)
      JOIN public.review_issues ri ON ri.id = u.id
      LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type
     WHERE ri.business_id = p_business_id
       AND ri.status = 'OPEN'::public.review_issue_status_enum
     ORDER BY u.ord
     LIMIT 1
  LOOP
    v_bucket := v_rec.issue_group;
  END LOOP;

  FOR v_rec IN
    SELECT u.id AS candidate_id,
           ri.id AS ri_id,
           ri.business_id, ri.issue_group, ri.severity, ri.status,
           itr.allowed_resolution_actions
      FROM unnest(p_issue_ids) WITH ORDINALITY AS u(id, ord)
      LEFT JOIN public.review_issues ri ON ri.id = u.id
      LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type
     ORDER BY u.ord
  LOOP
    IF v_rec.ri_id IS NULL THEN
      v_cnt_not_found := v_cnt_not_found + 1;
      CONTINUE;
    END IF;
    IF v_rec.business_id <> p_business_id THEN
      v_cnt_skip_diff_business := v_cnt_skip_diff_business + 1;
      CONTINUE;
    END IF;
    IF v_rec.status <> 'OPEN'::public.review_issue_status_enum THEN
      v_cnt_skip_closed := v_cnt_skip_closed + 1;
      CONTINUE;
    END IF;
    IF v_bucket IS NOT NULL AND v_rec.issue_group <> v_bucket THEN
      v_cnt_skip_diff_bucket := v_cnt_skip_diff_bucket + 1;
      CONTINUE;
    END IF;
    IF v_rec.allowed_resolution_actions IS NULL
       OR NOT (v_action_text = ANY(v_rec.allowed_resolution_actions)) THEN
      v_cnt_skip_not_allowed := v_cnt_skip_not_allowed + 1;
      CONTINUE;
    END IF;
    IF p_action_kind = 'IGNORE_WITH_REASON'::public.resolution_action_kind_enum
       AND v_rec.severity = 'BLOCKING'::public.review_issue_severity_enum THEN
      v_cnt_skip_blocking := v_cnt_skip_blocking + 1;
      CONTINUE;
    END IF;
    v_will_apply := v_will_apply || v_rec.ri_id;
    v_cnt_will_apply := v_cnt_will_apply + 1;
  END LOOP;

  v_summary := jsonb_build_object(
    'will_apply', v_cnt_will_apply,
    'skip_already_closed', v_cnt_skip_closed,
    'skip_different_bucket', v_cnt_skip_diff_bucket,
    'skip_different_business', v_cnt_skip_diff_business,
    'skip_not_allowed_for_issue_type', v_cnt_skip_not_allowed,
    'skip_blocking_dismissal', v_cnt_skip_blocking,
    'not_found', v_cnt_not_found);

  IF v_cnt_will_apply = 0 THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_BULK_PREVIEW_REQUESTED',
      p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
      p_subject_id:=public.gen_uuid_v7(),
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_org, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'action_kind', v_action_text, 'token_created', false, 'summary', v_summary),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','NO_APPLICABLE_ISSUES',
                              'summary', v_summary);
  END IF;

  INSERT INTO public.bulk_preview_tokens (
    organization_id, business_id, actor_user_id,
    action_kind, affected_issue_ids
  ) VALUES (
    v_org, p_business_id, p_actor_user_id,
    v_action_text, v_will_apply
  ) RETURNING id INTO v_token_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_BULK_PREVIEW_REQUESTED',
    p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
    p_subject_id:=v_token_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_org, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'action_kind', v_action_text, 'token_id', v_token_id,
      'bucket', v_bucket::text, 'summary', v_summary),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'token_id', v_token_id,
    'bucket', v_bucket::text,
    'will_apply_count', v_cnt_will_apply,
    'summary', v_summary);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bulk_preview(uuid, uuid, public.resolution_action_kind_enum, uuid[], jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.bulk_preview(uuid, uuid, public.resolution_action_kind_enum, uuid[], jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.bulk_apply_action(
  p_actor_user_id uuid,
  p_token_id      uuid,
  p_action_payload jsonb DEFAULT '{}'::jsonb,
  p_note          text  DEFAULT NULL,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_token         record;
  v_action        public.resolution_action_kind_enum;
  v_org           uuid;
  v_id            uuid;
  v_dispatch      jsonb;
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
    INTO v_token
    FROM public.bulk_preview_tokens
   WHERE id = p_token_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_NOT_FOUND');
  END IF;

  IF v_token.actor_user_id <> p_actor_user_id THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_ACTOR_MISMATCH');
  END IF;

  IF v_token.consumed_at IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_BULK_CONFIRMATION_TOKEN_REPLAY_REJECTED',
      p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
      p_subject_id:=p_token_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_token.organization_id, p_business_id:=v_token.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('token_id', p_token_id,
                                         'consumed_at', v_token.consumed_at),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_ALREADY_CONSUMED');
  END IF;

  IF v_token.expires_at <= clock_timestamp() THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_BULK_CONFIRMATION_TOKEN_EXPIRED',
      p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
      p_subject_id:=p_token_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_token.organization_id, p_business_id:=v_token.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('token_id', p_token_id,
                                         'expires_at', v_token.expires_at),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','TOKEN_EXPIRED');
  END IF;

  v_action := v_token.action_kind::public.resolution_action_kind_enum;
  v_org    := v_token.organization_id;
  v_requested := cardinality(v_token.affected_issue_ids);

  UPDATE public.bulk_preview_tokens
     SET consumed_at = clock_timestamp()
   WHERE id = p_token_id;

  FOREACH v_id IN ARRAY v_token.affected_issue_ids LOOP
    BEGIN
      v_dispatch := public.apply_resolution_action(
        p_actor_user_id, v_id, v_action,
        COALESCE(p_action_payload, '{}'::jsonb),
        p_note, p_context);
      IF (v_dispatch->>'decision') = 'ALLOW' THEN
        v_applied_ids := v_applied_ids || v_id;
        v_applied_count := v_applied_count + 1;
      ELSE
        v_skipped := v_skipped || jsonb_build_object(
          'issue_id', v_id,
          'reason_code', v_dispatch->>'reason_code');
        v_skipped_count := v_skipped_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures || jsonb_build_object(
        'issue_id', v_id,
        'sqlstate', SQLSTATE,
        'message', SQLERRM);
      v_failed_count := v_failed_count + 1;
    END;
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_BULK_APPLIED',
    p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
    p_subject_id:=p_token_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_org, p_business_id:=v_token.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'token_id', p_token_id,
      'action_kind', v_action::text,
      'requested', v_requested,
      'applied', v_applied_count,
      'skipped', v_skipped_count,
      'failed', v_failed_count),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'token_id', p_token_id,
    'action_kind', v_action::text,
    'requested', v_requested,
    'applied', v_applied_count,
    'applied_ids', to_jsonb(v_applied_ids),
    'skipped_count', v_skipped_count,
    'skipped', v_skipped,
    'failed_count', v_failed_count,
    'failures', v_failures);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bulk_apply_action(uuid, uuid, jsonb, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.bulk_apply_action(uuid, uuid, jsonb, text, jsonb) TO service_role, authenticated;


CREATE OR REPLACE VIEW public.v_bulk_preview_token_status AS
  SELECT
    bpt.id, bpt.organization_id, bpt.business_id, bpt.actor_user_id,
    bpt.action_kind, bpt.affected_issue_ids,
    bpt.created_at, bpt.expires_at, bpt.consumed_at,
    cardinality(bpt.affected_issue_ids) AS affected_count,
    CASE
      WHEN bpt.consumed_at IS NOT NULL THEN 'CONSUMED'
      WHEN bpt.expires_at <= clock_timestamp() THEN 'EXPIRED'
      ELSE 'PENDING'
    END AS status
  FROM public.bulk_preview_tokens bpt;

COMMENT ON VIEW public.v_bulk_preview_token_status IS
  'B14·P05 read model: per token, status PENDING/CONSUMED/EXPIRED and affected_count for the result modal.';
