-- R7.3 — notifications: feed the existing notification_inbox + read RPCs.
--
-- The notification_inbox table already exists (one producer: review-assignment
-- dispatch). It has the recipient-scoped SELECT policy and deny-all writes for
-- authenticated, so: reads are direct RLS-scoped selects; marking read needs a
-- SECURITY DEFINER RPC; and new notifications are produced by a projector the
-- worker runs each tick.
--
-- project_notifications() derives notifications idempotently from current state
-- (no need to touch the dozens of B03/B14/B16 RPCs that raise these events):
--   * open HIGH/BLOCKING review issues   → every active business member
--   * runs in REVIEW_HOLD / AWAITING_APPROVAL → every active business member
--   * COMPLETED exports                  → the requester
--   * integration tokens expiring ≤ 7d   → the connected user
-- Idempotency: one row per (recipient, kind, payload->>'source_key').

-- Insert a notification once per (recipient, kind, source_key). Returns true if inserted.
CREATE OR REPLACE FUNCTION public._emit_notification_once(
  p_recipient uuid, p_org uuid, p_business uuid,
  p_kind text, p_source_key text, p_payload jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF p_recipient IS NULL OR p_org IS NULL OR p_business IS NULL THEN
    RETURN false;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.notification_inbox
     WHERE recipient_user_id = p_recipient AND kind = p_kind
       AND payload->>'source_key' = p_source_key
  ) THEN
    RETURN false;
  END IF;
  INSERT INTO public.notification_inbox
    (recipient_user_id, organization_id, business_id, kind, payload, delivered_at)
  VALUES
    (p_recipient, p_org, p_business, p_kind,
     p_payload || jsonb_build_object('source_key', p_source_key), clock_timestamp());
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.project_notifications(
  p_lookback interval DEFAULT interval '30 days',
  p_token_window interval DEFAULT interval '7 days')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_created int := 0;
  r record; m record;
BEGIN
  -- 1) Open HIGH/BLOCKING review issues → active business members.
  FOR r IN
    SELECT id, organization_id, business_id, severity, issue_type, plain_language_title
      FROM public.review_issues
     WHERE status = 'OPEN'::public.review_issue_status_enum
       AND severity IN ('HIGH'::public.review_issue_severity_enum, 'BLOCKING'::public.review_issue_severity_enum)
       AND created_at > now() - p_lookback
  LOOP
    FOR m IN SELECT user_id FROM public.business_user_roles
              WHERE business_id = r.business_id AND status::text = 'ACTIVE'
    LOOP
      IF public._emit_notification_once(m.user_id, r.organization_id, r.business_id,
           'REVIEW_ISSUE_OPENED', r.id::text,
           jsonb_build_object('review_issue_id', r.id, 'severity', r.severity::text,
                              'issue_type', r.issue_type, 'title', r.plain_language_title,
                              'route', '/review')) THEN
        v_created := v_created + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- 2) Runs paused for review / awaiting approval → active business members.
  FOR r IN
    SELECT id, organization_id, business_id, status, workflow_type
      FROM public.workflow_runs
     WHERE status IN ('REVIEW_HOLD'::public.workflow_run_status_enum,
                      'AWAITING_APPROVAL'::public.workflow_run_status_enum)
       AND updated_at > now() - p_lookback
  LOOP
    FOR m IN SELECT user_id FROM public.business_user_roles
              WHERE business_id = r.business_id AND status::text = 'ACTIVE'
    LOOP
      IF public._emit_notification_once(m.user_id, r.organization_id, r.business_id,
           CASE WHEN r.status::text = 'AWAITING_APPROVAL' THEN 'RUN_AWAITING_APPROVAL' ELSE 'RUN_REVIEW_HOLD' END,
           r.id::text || ':' || r.status::text,
           jsonb_build_object('workflow_run_id', r.id, 'workflow_type', r.workflow_type::text,
                              'status', r.status::text, 'route', '/runs')) THEN
        v_created := v_created + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- 3) Completed exports → the requester.
  FOR r IN
    SELECT id, organization_id, business_id, requested_by_user_id, export_kind, format
      FROM public.exports
     WHERE status = 'COMPLETED'::public.export_status_enum
       AND completed_at > now() - p_lookback
  LOOP
    IF public._emit_notification_once(r.requested_by_user_id, r.organization_id, r.business_id,
         'EXPORT_READY', r.id::text,
         jsonb_build_object('export_id', r.id, 'export_kind', r.export_kind,
                            'format', r.format::text, 'route', '/reports')) THEN
      v_created := v_created + 1;
    END IF;
  END LOOP;

  -- 4) Integration tokens expiring soon → the connected user.
  FOR r IN
    SELECT id, organization_id, business_id, connected_user_id, provider, access_token_expires_at
      FROM public.business_integrations
     WHERE disconnected_at IS NULL
       AND access_token_expires_at IS NOT NULL
       AND access_token_expires_at <= now() + p_token_window
       AND access_token_expires_at > now() - p_lookback
  LOOP
    IF public._emit_notification_once(r.connected_user_id, r.organization_id, r.business_id,
         'INTEGRATION_TOKEN_EXPIRING',
         r.id::text || ':' || to_char(r.access_token_expires_at, 'YYYY-MM-DD'),
         jsonb_build_object('integration_id', r.id, 'provider', r.provider::text,
                            'expires_at', r.access_token_expires_at, 'route', '/account')) THEN
      v_created := v_created + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'created', v_created);
END;
$function$;

-- Mark one / all of the caller's notifications read (writes are deny-all for
-- authenticated, so this SECURITY DEFINER RPC is the only path). The recipient
-- is derived from the session — callers can't touch another user's inbox.
CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_uid uuid := public.current_user_id(); v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'UNAUTHENTICATED'); END IF;
  UPDATE public.notification_inbox
     SET read_at = COALESCE(read_at, clock_timestamp())
   WHERE id = p_notification_id AND recipient_user_id = v_uid
   RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', v_id IS NOT NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_uid uuid := public.current_user_id(); v_n int;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'UNAUTHENTICATED'); END IF;
  WITH upd AS (
    UPDATE public.notification_inbox SET read_at = clock_timestamp()
     WHERE recipient_user_id = v_uid AND read_at IS NULL
     RETURNING 1)
  SELECT count(*) INTO v_n FROM upd;
  RETURN jsonb_build_object('ok', true, 'marked', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.project_notifications(interval, interval) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated;
