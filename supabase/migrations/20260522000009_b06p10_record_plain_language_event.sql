-- B06·P10 — Plain-Language Pipeline
--
-- Audit-emission RPC for the plain-language generation surface. Mirrors
-- record_ai_tier{2,3}_event and record_ai_usage's actor-discriminating shape.
-- The 3 events:
--   PLAIN_LANGUAGE_GENERATED       — successful (title, description) render
--   PLAIN_LANGUAGE_GENERATION_FAILED — Tier-2 failure or output schema violation
--   PLAIN_LANGUAGE_FALLBACK_USED   — caller fell back to raw issue_type rendering
--
-- Subject is the workflow run (not the gateway invocation): a single plain-
-- language render can serve multiple downstream consumers (review queue,
-- matching engine, exports), so binding the audit to the run rather than to
-- one specific gateway call gives reviewers the right reconstruction unit.

CREATE OR REPLACE FUNCTION public.record_plain_language_event(
  p_action          text,
  p_business_id     uuid,
  p_workflow_run_id uuid    DEFAULT NULL,
  p_actor_user_id   uuid    DEFAULT NULL,
  p_payload         jsonb   DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_allowed text[] := ARRAY[
    'PLAIN_LANGUAGE_GENERATED',
    'PLAIN_LANGUAGE_GENERATION_FAILED',
    'PLAIN_LANGUAGE_FALLBACK_USED'
  ];
  v_biz          public.business_entities%ROWTYPE;
  v_audit_kind   audit.actor_kind_enum;
  v_actor_system text;
  v_audit_row    audit.audit_events;
BEGIN
  IF p_action IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'record_plain_language_event: p_action and p_business_id required'
      USING ERRCODE = '22000';
  END IF;
  IF NOT (p_action = ANY(v_allowed)) THEN
    RAISE EXCEPTION 'record_plain_language_event: invalid action % (allowed: %)',
      p_action, v_allowed USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(COALESCE(p_payload, '{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'record_plain_language_event: p_payload must be a JSON object'
      USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_plain_language_event: business % not found', p_business_id
      USING ERRCODE = '22023';
  END IF;

  IF p_actor_user_id IS NULL THEN
    v_audit_kind   := 'SYSTEM'::audit.actor_kind_enum;
    v_actor_system := 'plain_language';
  ELSE
    v_audit_kind   := 'USER'::audit.actor_kind_enum;
    v_actor_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => v_audit_kind,
    p_action          => p_action,
    p_subject_type    => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id      => p_workflow_run_id,
    p_actor_user_id   => p_actor_user_id,
    p_actor_system    => v_actor_system,
    p_organization_id => v_biz.organization_id,
    p_business_id     => p_business_id,
    p_reason          => format('%s for workflow run %s',
                                 p_action, p_workflow_run_id),
    p_after_state     => COALESCE(p_payload, '{}'::jsonb) ||
                          jsonb_build_object('workflow_run_id', p_workflow_run_id)
  );

  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id,
                            'action', p_action);
END;
$function$;
COMMENT ON FUNCTION public.record_plain_language_event(text, uuid, uuid, uuid, jsonb) IS
  'Plain-language generation audit RPC. Validates p_action against the 3-event allowlist and emits one audit row scoped to the workflow run. Called from the Python plain-language adapter (deferred) after each generate_plain_language call.';

REVOKE EXECUTE ON FUNCTION public.record_plain_language_event(text, uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_plain_language_event(text, uuid, uuid, uuid, jsonb) TO service_role;
