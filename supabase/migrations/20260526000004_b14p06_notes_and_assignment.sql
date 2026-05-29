-- B14·P06 — Notes & Assignment
-- =====================================================================
-- First-class notes_update + assignment APIs sibling to the P04
-- dispatcher. Both paths converge on review_issues.resolution_note and
-- review_issues.assigned_to/at/by. The dispatcher's SEND_TO_ACCOUNTANT_REVIEW
-- branch now delegates to review_queue_assign so the REVIEW_ASSIGN gate
-- and assignee role validation apply uniformly.
--
-- Recursion-gap fix for the notification-failure issue: its own creation
-- path bypasses the AI card-content pipeline (canonical structured text,
-- not "fallback"), is NEVER assigned, and routes to all Owners via the
-- in-app inbox only. No email channel is invoked.
-- =====================================================================

CREATE TABLE public.notification_inbox (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  recipient_user_id   uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id         uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  kind                text NOT NULL,
  payload             jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  delivered_at        timestamptz,
  read_at             timestamptz,
  CONSTRAINT notification_inbox_kind_nonempty_chk CHECK (length(trim(kind)) > 0)
);

CREATE INDEX notification_inbox_recipient_created_idx
  ON public.notification_inbox (recipient_user_id, created_at DESC);
CREATE INDEX notification_inbox_recipient_unread_idx
  ON public.notification_inbox (recipient_user_id) WHERE read_at IS NULL;

COMMENT ON TABLE public.notification_inbox IS
  'B14·P06: per-user in-app inbox for assignment notifications, etc. Email channel is a separate concern handled app-layer.';

ALTER TABLE public.notification_inbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_inbox FORCE  ROW LEVEL SECURITY;

CREATE POLICY notification_inbox_select_own ON public.notification_inbox
  FOR SELECT TO authenticated
  USING (recipient_user_id = (SELECT u.id FROM public.users u WHERE u.auth_user_id = auth.uid()));
CREATE POLICY notification_inbox_deny_write_insert ON public.notification_inbox
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY notification_inbox_deny_write_update ON public.notification_inbox
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY notification_inbox_deny_write_delete ON public.notification_inbox
  FOR DELETE TO authenticated USING (false);


SELECT public.register_issue_type(
  'review_queue.notification_dispatch_failed',
  'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
  'HIGH'::public.review_issue_severity_enum,
  ARRAY['ADD_EXPLANATION_NOTE','RERUN_SCAN_AFTER_CHANGE','IGNORE_WITH_REASON'],
  'review_queue',
  'review_queue.card_content_default'
);


CREATE OR REPLACE FUNCTION public.notes_update(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_notes_text    text,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue   record;
  v_perm    jsonb;
  v_before  text;
  v_after   text;
BEGIN
  SELECT id, organization_id, business_id, resolution_note
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;

  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_QUEUE_RESOLVE', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  v_before := v_issue.resolution_note;
  v_after  := NULLIF(p_notes_text, '');

  UPDATE public.review_issues
     SET resolution_note = v_after,
         updated_at = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_NOTE_UPDATED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('resolution_note', v_before),
    p_after_state:=jsonb_build_object('resolution_note', v_after),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW',
                            'before', v_before, 'after', v_after, 'issue_id', p_issue_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.notes_update(uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.notes_update(uuid, uuid, text, jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.dispatch_assignment_notification(
  p_issue_id        uuid,
  p_assignee_user_id uuid,
  p_simulate_failure boolean DEFAULT false,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue       record;
  v_inbox_id    uuid;
  v_failure_id  uuid;
  v_owner       record;
BEGIN
  SELECT id, organization_id, business_id,
         transaction_id, document_id, match_record_id, draft_ledger_entry_id,
         invoice_id, client_id, workflow_run_id, issue_type
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;

  IF p_simulate_failure THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='REVIEW_ASSIGNMENT_NOTIFICATION_FAILED',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='notification_dispatcher',
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'channels_failed', ARRAY['in_app','email'],
        'attempted_assignee', p_assignee_user_id,
        'reason', 'simulated'),
      p_reason:=NULL, p_request_context:=p_context);

    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id,
      transaction_id, document_id, match_record_id, draft_ledger_entry_id,
      invoice_id, client_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json, card_content_generated_at,
      card_content_tier_used, card_content_fallback_applied, status
    ) VALUES (
      v_issue.organization_id, v_issue.business_id, v_issue.workflow_run_id,
      v_issue.transaction_id, v_issue.document_id, v_issue.match_record_id, v_issue.draft_ledger_entry_id,
      v_issue.invoice_id, v_issue.client_id,
      'review_queue.notification_dispatch_failed',
      'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
      'HIGH'::public.review_issue_severity_enum,
      'Assignment notification failed',
      'A notification for an assignment could not be delivered. Re-run scan to retry, or document the cause.',
      'RERUN_SCAN_AFTER_CHANGE',
      jsonb_build_object('originating_issue_id', p_issue_id,
                         'attempted_assignee_user_id', p_assignee_user_id),
      clock_timestamp(),
      'NONE'::public.review_issue_card_content_tier_enum,
      false,
      'OPEN'::public.review_issue_status_enum
    ) RETURNING id INTO v_failure_id;

    FOR v_owner IN
      SELECT bur.user_id
        FROM public.business_user_roles bur
       WHERE bur.business_id = v_issue.business_id
         AND bur.role = 'OWNER'::public.user_role
    LOOP
      INSERT INTO public.notification_inbox (
        recipient_user_id, organization_id, business_id,
        kind, payload
      ) VALUES (
        v_owner.user_id, v_issue.organization_id, v_issue.business_id,
        'REVIEW_NOTIFICATION_FAILURE',
        jsonb_build_object(
          'failure_issue_id', v_failure_id,
          'originating_issue_id', p_issue_id,
          'attempted_assignee_user_id', p_assignee_user_id));
    END LOOP;

    RETURN jsonb_build_object(
      'decision','ALLOW',
      'delivered', false,
      'failure_issue_id', v_failure_id);
  END IF;

  INSERT INTO public.notification_inbox (
    recipient_user_id, organization_id, business_id,
    kind, payload, delivered_at
  ) VALUES (
    p_assignee_user_id, v_issue.organization_id, v_issue.business_id,
    'REVIEW_ASSIGNMENT',
    jsonb_build_object('issue_id', p_issue_id, 'issue_type', v_issue.issue_type),
    clock_timestamp()
  ) RETURNING id INTO v_inbox_id;

  UPDATE public.review_issues
     SET assignment_notification_sent_at = clock_timestamp(),
         updated_at = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='REVIEW_ASSIGNMENT_NOTIFICATION_DISPATCHED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='notification_dispatcher',
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'inbox_id', v_inbox_id,
      'assignee_user_id', p_assignee_user_id,
      'channels_succeeded', ARRAY['in_app'],
      'channels_failed', ARRAY[]::text[]),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW', 'delivered', true, 'inbox_id', v_inbox_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.dispatch_assignment_notification(uuid, uuid, boolean, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.dispatch_assignment_notification(uuid, uuid, boolean, jsonb) TO service_role;


CREATE OR REPLACE FUNCTION public.review_queue_assign(
  p_actor_user_id    uuid,
  p_issue_id         uuid,
  p_assignee_user_id uuid,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue            record;
  v_perm             jsonb;
  v_assignee_role    public.user_role;
  v_prior_assignee   uuid;
  v_audit_action     text;
  v_disp             jsonb;
BEGIN
  SELECT id, organization_id, business_id, assigned_to
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;

  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_ASSIGN', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  SELECT bur.role INTO v_assignee_role
    FROM public.business_user_roles bur
   WHERE bur.user_id = p_assignee_user_id
     AND bur.business_id = v_issue.business_id;
  IF v_assignee_role IS NULL OR v_assignee_role NOT IN ('BOOKKEEPER'::public.user_role, 'ACCOUNTANT'::public.user_role) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_ASSIGNMENT_REJECTED_INVALID_ASSIGNEE',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'attempted_assignee', p_assignee_user_id,
        'attempted_assignee_role', v_assignee_role::text),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_ASSIGNEE',
                              'assignee_role', v_assignee_role::text);
  END IF;

  v_prior_assignee := v_issue.assigned_to;
  v_audit_action := CASE WHEN v_prior_assignee IS NULL
                         THEN 'REVIEW_ASSIGNMENT_CREATED'
                         ELSE 'REVIEW_ASSIGNMENT_REASSIGNED' END;

  UPDATE public.review_issues
     SET assigned_to = p_assignee_user_id,
         assigned_by = p_actor_user_id,
         assigned_at = clock_timestamp(),
         assignment_notification_sent_at = NULL,
         updated_at = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:=v_audit_action,
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('assigned_to', v_prior_assignee),
    p_after_state:=jsonb_build_object('assigned_to', p_assignee_user_id,
                                       'assignee_role', v_assignee_role::text),
    p_reason:=NULL, p_request_context:=p_context);

  v_disp := public.dispatch_assignment_notification(
    p_issue_id, p_assignee_user_id,
    COALESCE((p_context->>'simulate_notification_failure')::boolean, false),
    p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'audit_action', v_audit_action,
    'prior_assignee', v_prior_assignee,
    'new_assignee', p_assignee_user_id,
    'notification', v_disp);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.review_queue_assign(uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.review_queue_assign(uuid, uuid, uuid, jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.review_queue_reassign(
  p_actor_user_id    uuid,
  p_issue_id         uuid,
  p_new_assignee_user_id uuid,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_prior_assignee uuid;
BEGIN
  SELECT assigned_to INTO v_prior_assignee
    FROM public.review_issues WHERE id = p_issue_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;
  IF v_prior_assignee IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NO_PRIOR_ASSIGNMENT');
  END IF;

  RETURN public.review_queue_assign(p_actor_user_id, p_issue_id, p_new_assignee_user_id, p_context);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.review_queue_reassign(uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.review_queue_reassign(uuid, uuid, uuid, jsonb) TO service_role, authenticated;


CREATE OR REPLACE FUNCTION public.review_queue_clear_assignment(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue       record;
  v_perm        jsonb;
BEGIN
  SELECT id, organization_id, business_id, assigned_to
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;
  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_ASSIGN', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;
  IF v_issue.assigned_to IS NULL THEN
    RETURN jsonb_build_object('decision','ALLOW','noop',true,'reason','ALREADY_UNASSIGNED');
  END IF;

  UPDATE public.review_issues
     SET assigned_to = NULL,
         assigned_by = NULL,
         assigned_at = NULL,
         assignment_notification_sent_at = NULL,
         updated_at = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_ASSIGNMENT_CLEARED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('assigned_to', v_issue.assigned_to),
    p_after_state:=jsonb_build_object('assigned_to', NULL),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW', 'prior_assignee', v_issue.assigned_to);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.review_queue_clear_assignment(uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.review_queue_clear_assignment(uuid, uuid, jsonb) TO service_role, authenticated;


CREATE OR REPLACE VIEW public.v_assignee_inbox AS
  SELECT ri.id              AS review_issue_id,
         ri.organization_id, ri.business_id,
         ri.assigned_to, ri.assigned_at, ri.assigned_by,
         ri.issue_type, ri.issue_group, ri.severity, ri.status,
         ri.plain_language_title, ri.plain_language_description, ri.recommended_action,
         ri.created_at, ri.updated_at,
         itr.allowed_resolution_actions
    FROM public.review_issues ri
    LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type
   WHERE ri.assigned_to IS NOT NULL
     AND ri.status = 'OPEN'::public.review_issue_status_enum;

COMMENT ON VIEW public.v_assignee_inbox IS
  'B14·P06 "Assigned to me" projection: OPEN review_issues with assigned_to populated. Block 16 dashboard filters this by current_user.';


-- Refactor P04's SEND_TO_ACCOUNTANT_REVIEW branch: replace the inline
-- UPDATE with a call to review_queue_assign so the REVIEW_ASSIGN gate
-- and assignee role/business validation apply. Full function body
-- below (replayed verbatim with only the SEND_TO_ACCOUNTANT_REVIEW
-- branch changed and one new field 'actor_was_assignee' in the
-- REVIEW_RESOLUTION_APPLIED after_state for non-assignee resolution
-- tracking).

CREATE OR REPLACE FUNCTION public.apply_resolution_action(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_action        public.resolution_action_kind_enum,
  p_payload       jsonb DEFAULT '{}'::jsonb,
  p_note          text  DEFAULT NULL,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue       record;
  v_reg         record;
  v_perm        jsonb;
  v_status_after public.review_issue_status_enum;
  v_keeps_open   boolean := false;
  v_terminal     public.review_issue_status_enum := 'RESOLVED'::public.review_issue_status_enum;
  v_downstream   text;
  v_action_text  text := p_action::text;
  v_assign_result jsonb;
BEGIN
  SELECT id, organization_id, business_id, transaction_id, document_id, match_record_id,
         draft_ledger_entry_id, invoice_id, client_id, workflow_run_id,
         issue_type, issue_group, severity, status, assigned_to
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;

  SELECT issue_type, allowed_resolution_actions, producing_block
    INTO v_reg FROM public.issue_type_registry WHERE issue_type = v_issue.issue_type;

  IF v_issue.status IN ('RESOLVED'::public.review_issue_status_enum,
                        'DISMISSED'::public.review_issue_status_enum,
                        'AUTO_RESOLVED_BY_RESCAN'::public.review_issue_status_enum) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_NOOP',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('attempted_action', v_action_text, 'current_status', v_issue.status::text),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_ALREADY_CLOSED',
                              'status_after', v_issue.status::text, 'noop', true);
  END IF;

  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_QUEUE_RESOLVE', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_PERMISSION',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('attempted_action', v_action_text, 'reason_code', v_perm->>'reason_code'),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  IF v_reg.allowed_resolution_actions IS NULL OR NOT (v_action_text = ANY(v_reg.allowed_resolution_actions)) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_DISALLOWED_ACTION',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('attempted_action', v_action_text,
                                         'allowed', v_reg.allowed_resolution_actions),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ACTION_NOT_ALLOWED_FOR_ISSUE_TYPE');
  END IF;

  IF p_action = 'IGNORE_WITH_REASON'::public.resolution_action_kind_enum
     AND v_issue.severity = 'BLOCKING'::public.review_issue_severity_enum THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_RESOLUTION_REJECTED_BLOCKING_DISMISSAL',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('severity', v_issue.severity::text),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','BLOCKING_CANNOT_BE_DISMISSED');
  END IF;

  CASE p_action
    WHEN 'CONFIRM_MATCH'::public.resolution_action_kind_enum THEN
      v_downstream := 'public.user_confirm_match';
      IF v_issue.match_record_id IS NOT NULL THEN
        PERFORM public.user_confirm_match(v_issue.match_record_id, p_actor_user_id,
                                          COALESCE(p_payload->>'counterparty_signature',''), p_context);
      END IF;
    WHEN 'REJECT_MATCH'::public.resolution_action_kind_enum THEN
      v_downstream := 'public.user_reject_match';
      IF v_issue.match_record_id IS NOT NULL THEN
        PERFORM public.user_reject_match(v_issue.match_record_id, p_actor_user_id,
                                         COALESCE(p_payload->>'rejection_reason','user_rejected'), p_context);
      END IF;
    WHEN 'MARK_AS_NO_INVOICE_AVAILABLE'::public.resolution_action_kind_enum THEN
      IF COALESCE(p_payload->>'reason','') = '' THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
      END IF;
      v_downstream := 'public.out_workflow_document_exception';
      IF v_issue.workflow_run_id IS NOT NULL AND v_issue.transaction_id IS NOT NULL THEN
        PERFORM public.out_workflow_document_exception(
          v_issue.organization_id, v_issue.business_id, v_issue.workflow_run_id,
          v_issue.transaction_id, p_payload->>'reason', p_actor_user_id, p_context);
      END IF;
    WHEN 'CHANGE_TAG'::public.resolution_action_kind_enum THEN
      v_downstream := 'transactions.tag UPDATE (Block 08 path — Stage-1 stub)';
    WHEN 'CHANGE_TRANSACTION_TYPE'::public.resolution_action_kind_enum,
         'MARK_AS_INTERNAL_TRANSFER'::public.resolution_action_kind_enum,
         'MARK_AS_BANK_FEE'::public.resolution_action_kind_enum THEN
      v_downstream := 'transactions.transaction_type UPDATE (Block 08 path — Stage-1 stub)';
    WHEN 'MARK_AS_NON_DEDUCTIBLE'::public.resolution_action_kind_enum THEN
      v_downstream := 'draft_ledger_entries non-deductible UPDATE (Block 11 path — Stage-1 stub)';
    WHEN 'UPLOAD_DOCUMENT'::public.resolution_action_kind_enum THEN
      v_downstream := 'intake.manual_upload_handler (Block 09 — Stage-1 stub)';
    WHEN 'ADD_EXPLANATION_NOTE'::public.resolution_action_kind_enum THEN
      IF COALESCE(p_note,'') = '' THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','NOTE_REQUIRED');
      END IF;
      v_keeps_open := true;
      v_downstream := 'review_issues.resolution_note UPDATE';
    WHEN 'SEND_TO_ACCOUNTANT_REVIEW'::public.resolution_action_kind_enum THEN
      IF (p_payload->>'assigned_to') IS NULL THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','ASSIGNED_TO_REQUIRED');
      END IF;
      v_keeps_open := true;
      v_downstream := 'public.review_queue_assign';
      v_assign_result := public.review_queue_assign(
        p_actor_user_id, p_issue_id,
        (p_payload->>'assigned_to')::uuid, p_context);
      IF (v_assign_result->>'decision') <> 'ALLOW' THEN
        RETURN v_assign_result;
      END IF;
    WHEN 'IGNORE_WITH_REASON'::public.resolution_action_kind_enum THEN
      IF COALESCE(p_note,'') = '' THEN
        RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
      END IF;
      v_terminal := 'DISMISSED'::public.review_issue_status_enum;
      v_downstream := 'review_issues.status → DISMISSED';
    WHEN 'RERUN_SCAN_AFTER_CHANGE'::public.resolution_action_kind_enum THEN
      v_keeps_open := true;
      v_downstream := 'Phase 08 affected-issues re-scan (manual)';
      PERFORM audit.emit_audit(
        p_actor_kind:='USER'::audit.actor_kind_enum,
        p_action:='REVIEW_RESCAN_TRIGGERED_MANUALLY',
        p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
        p_subject_id:=p_issue_id,
        p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
        p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object('triggered_by_resolution', true),
        p_reason:=NULL, p_request_context:=p_context);
  END CASE;

  IF v_keeps_open THEN
    v_status_after := v_issue.status;
    IF p_action = 'ADD_EXPLANATION_NOTE'::public.resolution_action_kind_enum THEN
      UPDATE public.review_issues
         SET resolution_note = p_note, updated_at = clock_timestamp()
       WHERE id = p_issue_id;
    END IF;
  ELSE
    v_status_after := v_terminal;
    UPDATE public.review_issues
       SET status            = v_terminal,
           resolution_action = p_action,
           resolution_note   = p_note,
           resolved_at       = clock_timestamp(),
           resolved_by       = p_actor_user_id,
           updated_at        = clock_timestamp()
     WHERE id = p_issue_id;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_RESOLUTION_APPLIED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object('status', v_issue.status::text,
                                        'assigned_to', v_issue.assigned_to),
    p_after_state:=jsonb_build_object(
      'action', v_action_text,
      'status', v_status_after::text,
      'downstream_rpc', v_downstream,
      'payload', p_payload,
      'note_present', p_note IS NOT NULL,
      'actor_was_assignee', v_issue.assigned_to IS NOT NULL AND v_issue.assigned_to = p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  IF NOT v_keeps_open THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='REVIEW_GATE_REEVALUATION_REQUESTED',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='review_queue_dispatcher',
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('triggering_resolution_issue_id', p_issue_id,
                                         'triggering_workflow_run_id', v_issue.workflow_run_id),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'decision', 'ALLOW',
    'action', v_action_text,
    'status_after', v_status_after::text,
    'downstream_rpc', v_downstream,
    'gate_reevaluation_triggered', NOT v_keeps_open);
END;
$$;
