-- B06·P06 — Tier 2 (Local LLM) Integration
--
-- Mirror of B06·P05's record_ai_tier3_event with a 6-action allowlist:
--   TIER_2_INVOKED                 — every call that reaches the local LLM
--   TIER_2_RESPONSE_RECEIVED       — local LLM returned a parsed response
--   TIER_2_FAILED                  — HTTP / transport / circuit-open failure
--   TIER_2_HEALTH_CHECK_FAILED     — health probe failed
--   TIER_2_CIRCUIT_BREAKER_OPENED  — emitted exactly once per CLOSED→OPEN
--   TIER_2_BYPASS_ATTEMPT_BLOCKED  — runtime bypass guard tripped
--
-- The Python LocalLlmClient calls this RPC via the Supabase service-role
-- channel. Action allowlist enforced server-side so the Python layer cannot
-- invent ad-hoc TIER_2_* events.

CREATE OR REPLACE FUNCTION public.record_ai_tier2_event(
  p_action         text,
  p_business_id    uuid,
  p_invocation_id  uuid DEFAULT NULL,
  p_actor_user_id  uuid DEFAULT NULL,
  p_payload        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_allowed text[] := ARRAY[
    'TIER_2_INVOKED',
    'TIER_2_RESPONSE_RECEIVED',
    'TIER_2_FAILED',
    'TIER_2_HEALTH_CHECK_FAILED',
    'TIER_2_CIRCUIT_BREAKER_OPENED',
    'TIER_2_BYPASS_ATTEMPT_BLOCKED'
  ];
  v_biz          public.business_entities%ROWTYPE;
  v_audit_kind   audit.actor_kind_enum;
  v_actor_system text;
  v_audit_row    audit.audit_events;
BEGIN
  IF p_action IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'record_ai_tier2_event: p_action and p_business_id required'
      USING ERRCODE = '22000';
  END IF;
  IF NOT (p_action = ANY(v_allowed)) THEN
    RAISE EXCEPTION 'record_ai_tier2_event: invalid action % (allowed: %)',
      p_action, v_allowed USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(COALESCE(p_payload, '{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'record_ai_tier2_event: p_payload must be a JSON object'
      USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ai_tier2_event: business % not found', p_business_id
      USING ERRCODE = '22023';
  END IF;

  IF p_actor_user_id IS NULL THEN
    v_audit_kind := 'SYSTEM'::audit.actor_kind_enum;
    v_actor_system := 'tier2_dispatcher';
  ELSE
    v_audit_kind := 'USER'::audit.actor_kind_enum;
    v_actor_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => v_audit_kind,
    p_action          => p_action,
    p_subject_type    => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
    p_subject_id      => p_invocation_id,
    p_actor_user_id   => p_actor_user_id,
    p_actor_system    => v_actor_system,
    p_organization_id => v_biz.organization_id,
    p_business_id     => p_business_id,
    p_reason          => format('%s for gateway invocation %s', p_action, p_invocation_id),
    p_after_state     => COALESCE(p_payload, '{}'::jsonb) ||
                          jsonb_build_object('invocation_id', p_invocation_id)
  );

  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id,
                            'action', p_action);
END;
$function$;
COMMENT ON FUNCTION public.record_ai_tier2_event(text, uuid, uuid, uuid, jsonb) IS
  'Tier 2 (local LLM) audit emission RPC. Validates p_action against the canonical TIER_2_* allowlist, then emits one audit row tied to the gateway invocation. Called from the Python ai_integrations.local_llm_client. SYSTEM actor (actor_system=''tier2_dispatcher'') when p_actor_user_id IS NULL.';

REVOKE EXECUTE ON FUNCTION public.record_ai_tier2_event(text, uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_ai_tier2_event(text, uuid, uuid, uuid, jsonb) TO service_role;
