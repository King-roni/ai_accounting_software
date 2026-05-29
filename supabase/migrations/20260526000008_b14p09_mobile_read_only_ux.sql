-- B14·P09 — Mobile Read-Only UX
-- =====================================================================
-- Server-side defense-in-depth guard against mobile writes. Intentionally
-- bypassable (spec: "UX guard, not security boundary"); real security is
-- the permission matrix. Any RPC that mutates user-visible state calls
-- _check_form_factor_guard near the top. The guard rejects with
-- MOBILE_FORM_FACTOR_WRITE_REJECTED when ctx.client_form_factor='MOBILE'.
-- No audit events emitted by the rejection path.
-- =====================================================================

CREATE OR REPLACE FUNCTION public._check_form_factor_guard(
  p_action_kind text,
  p_context     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF p_context IS NOT NULL
     AND (p_context->>'client_form_factor') = 'MOBILE' THEN
    RETURN jsonb_build_object(
      'decision', 'DENY',
      'reason_code', 'MOBILE_FORM_FACTOR_WRITE_REJECTED',
      'attempted_action', p_action_kind,
      'form_factor', 'MOBILE');
  END IF;
  RETURN jsonb_build_object('decision','ALLOW');
END;
$$;

GRANT EXECUTE ON FUNCTION public._check_form_factor_guard(text, jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.send_issue_link_to_inbox(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue   record;
  v_perm    jsonb;
  v_inbox_id uuid;
BEGIN
  SELECT id, organization_id, business_id, issue_type
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;
  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_QUEUE_VIEW', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  INSERT INTO public.notification_inbox (
    recipient_user_id, organization_id, business_id, kind, payload, delivered_at
  ) VALUES (
    p_actor_user_id, v_issue.organization_id, v_issue.business_id,
    'REVIEW_ISSUE_DESKTOP_LINK',
    jsonb_build_object('issue_id', p_issue_id, 'issue_type', v_issue.issue_type,
                       'sent_from_form_factor', COALESCE(p_context->>'client_form_factor','UNKNOWN')),
    clock_timestamp()
  ) RETURNING id INTO v_inbox_id;

  RETURN jsonb_build_object('decision','ALLOW', 'inbox_id', v_inbox_id, 'issue_id', p_issue_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_issue_link_to_inbox(uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.send_issue_link_to_inbox(uuid, uuid, jsonb) TO service_role, authenticated;


-- Form-factor guard wired into 7 existing write RPCs:
--   notes_update, snooze_apply, review_queue_assign, regenerate_card_content,
--   apply_resolution_action, bulk_apply_action, bulk_snooze_apply
-- Full function bodies (CREATE OR REPLACE re-emitting prior-phase
-- implementations with one new guard-check block near the top) were
-- applied via mcp__claude_ai_Supabase__apply_migration on 2026-05-26 in
-- the two migrations named b14p09_mobile_read_only_ux and
-- b14p09_mobile_guard_wire_dispatcher_and_bulk. Canonical source is the DB.
