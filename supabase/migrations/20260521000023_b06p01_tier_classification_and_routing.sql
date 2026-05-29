-- B06·P01 — Tier Classification & Routing (migration 2 of 2)
--
-- Builds:
--   1. business_ai_config table (one row per business; tier 2 / tier 3 opt-out flags).
--      Designed to be extended by Phase 08 with cost-ceiling columns.
--   2. ai_tier_canonical_label() — spec-canonical TIER_1_NONE / TIER_2_LOCAL_LLM / TIER_3_EXTERNAL_LLM.
--   3. model_id_for_tier() — placeholder model ids until B06·P05/P06 wire real providers.
--   4. route_ai_call() — SECURITY DEFINER routing decision. Returns jsonb envelope.
--      Emits AI_TIER_ROUTED on ALLOW, AI_TIER_BLOCKED on per-business opt-out.
--      Explicit-no-silent-escalation: never auto-escalates Tier 2 → Tier 3.
--   5. update_business_ai_config() — Owner-only UPSERT RPC. Emits AI_TIER_CONFIG_UPDATED
--      on success, AI_TIER_CONFIG_UPDATE_REJECTED on policy failure (Mitigation A).
--
-- Migration 1 added BUSINESS_AI_CONFIG to audit.subject_type_enum.

-- ============================================================================
-- 1. business_ai_config table
-- ============================================================================
CREATE TABLE public.business_ai_config (
  id                 uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  business_id        uuid NOT NULL UNIQUE REFERENCES public.business_entities(id),
  tier2_enabled      boolean NOT NULL DEFAULT true,
  tier3_enabled      boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_by_user_id uuid REFERENCES public.users(id)
);
COMMENT ON TABLE public.business_ai_config IS
  'Per-business AI tier configuration. One row per business. Tier 1 (deterministic logic) is always available; only Tier 2 / Tier 3 are flag-blockable. Phase 08 extends this table with cost-ceiling columns so all per-business AI policy lives in one row per business.';

REVOKE ALL ON public.business_ai_config FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.business_ai_config TO service_role;

-- ============================================================================
-- 2. ai_tier_canonical_label
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_tier_canonical_label(t public.ai_tier_enum)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE t
           WHEN 'NONE'::public.ai_tier_enum         THEN 'TIER_1_NONE'
           WHEN 'LOCAL_LLM'::public.ai_tier_enum    THEN 'TIER_2_LOCAL_LLM'
           WHEN 'EXTERNAL_LLM'::public.ai_tier_enum THEN 'TIER_3_EXTERNAL_LLM'
         END;
$$;
COMMENT ON FUNCTION public.ai_tier_canonical_label(public.ai_tier_enum) IS
  'Returns the canonical spec label (TIER_1_NONE / TIER_2_LOCAL_LLM / TIER_3_EXTERNAL_LLM) for an ai_tier_enum value.';

-- ============================================================================
-- 3. model_id_for_tier
-- ============================================================================
CREATE OR REPLACE FUNCTION public.model_id_for_tier(t public.ai_tier_enum)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE t
           WHEN 'NONE'::public.ai_tier_enum         THEN NULL
           WHEN 'LOCAL_LLM'::public.ai_tier_enum    THEN 'local-llm-default'
           WHEN 'EXTERNAL_LLM'::public.ai_tier_enum THEN 'anthropic-claude-eu-zero-retention'
         END;
$$;
COMMENT ON FUNCTION public.model_id_for_tier(public.ai_tier_enum) IS
  'Default model id for a tier. Placeholder until B06·P05 (Anthropic) and B06·P06 (local LLM) wire real providers and per-tool overrides. Tier 1 returns NULL.';

-- ============================================================================
-- 4. route_ai_call
-- ============================================================================
CREATE OR REPLACE FUNCTION public.route_ai_call(
  p_tool_name        text,
  p_business_id      uuid,
  p_workflow_run_id  uuid DEFAULT NULL,
  p_calling_phase    text DEFAULT NULL,
  p_actor_user_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tool         public.tool_registry%ROWTYPE;
  v_cfg          public.business_ai_config%ROWTYPE;
  v_biz          public.business_entities%ROWTYPE;
  v_tier         public.ai_tier_enum;
  v_tier_label   text;
  v_model_id     text;
  v_tier_enabled boolean;
  v_decision     text;
  v_routing_reason text;
  v_audit_action text;
  v_audit_kind   audit.actor_kind_enum;
  v_actor_system text;
  v_audit_row    audit.audit_events;
BEGIN
  IF p_tool_name IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'route_ai_call: p_tool_name and p_business_id are required'
      USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision',       'ERROR',
      'error_code',     'BUSINESS_NOT_FOUND',
      'message',        format('business %s not found', p_business_id),
      'audit_event_id', NULL
    );
  END IF;

  SELECT * INTO v_tool FROM public.tool_registry WHERE tool_name = p_tool_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision',       'ERROR',
      'error_code',     'TOOL_NOT_FOUND',
      'message',        format('tool %s not registered', p_tool_name),
      'audit_event_id', NULL
    );
  END IF;

  v_tier       := v_tool.ai_tier;
  v_tier_label := public.ai_tier_canonical_label(v_tier);

  SELECT * INTO v_cfg FROM public.business_ai_config WHERE business_id = p_business_id;
  -- absent row = all tiers enabled (default policy, spec §Deliverables)

  IF v_tier = 'NONE'::public.ai_tier_enum THEN
    v_decision       := 'ALLOW';
    v_routing_reason := 'TIER_1_NO_AI';
    v_model_id       := NULL;
  ELSIF v_tier = 'LOCAL_LLM'::public.ai_tier_enum THEN
    v_tier_enabled := COALESCE(v_cfg.tier2_enabled, true);
    IF v_tier_enabled THEN
      v_decision       := 'ALLOW';
      v_routing_reason := 'TIER_MATCHED';
      v_model_id       := public.model_id_for_tier(v_tier);
    ELSE
      v_decision       := 'BLOCK';
      v_routing_reason := 'TIER_2_DISABLED_FOR_BUSINESS';
      v_model_id       := NULL;
    END IF;
  ELSIF v_tier = 'EXTERNAL_LLM'::public.ai_tier_enum THEN
    v_tier_enabled := COALESCE(v_cfg.tier3_enabled, true);
    IF v_tier_enabled THEN
      v_decision       := 'ALLOW';
      v_routing_reason := 'TIER_MATCHED';
      v_model_id       := public.model_id_for_tier(v_tier);
    ELSE
      v_decision       := 'BLOCK';
      v_routing_reason := 'TIER_3_DISABLED_FOR_BUSINESS';
      v_model_id       := NULL;
    END IF;
  ELSE
    RAISE EXCEPTION 'route_ai_call: unknown ai_tier %', v_tier USING ERRCODE = '22023';
  END IF;

  v_audit_action := CASE v_decision WHEN 'ALLOW' THEN 'AI_TIER_ROUTED' ELSE 'AI_TIER_BLOCKED' END;

  IF p_actor_user_id IS NULL THEN
    v_audit_kind   := 'SYSTEM'::audit.actor_kind_enum;
    v_actor_system := 'ai_router';
  ELSE
    v_audit_kind   := 'USER'::audit.actor_kind_enum;
    v_actor_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => v_audit_kind,
    p_action          => v_audit_action,
    p_subject_type    => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id      => p_workflow_run_id,
    p_actor_user_id   => p_actor_user_id,
    p_actor_system    => v_actor_system,
    p_organization_id => v_biz.organization_id,
    p_business_id     => p_business_id,
    p_reason          => format('tool=%s tier=%s decision=%s reason=%s',
                                 p_tool_name, v_tier_label, v_decision, v_routing_reason),
    p_after_state     => jsonb_build_object(
      'tool_name',       p_tool_name,
      'tier',            v_tier::text,
      'tier_label',      v_tier_label,
      'decision',        v_decision,
      'routing_reason',  v_routing_reason,
      'model_id',        v_model_id,
      'calling_phase',   p_calling_phase,
      'workflow_run_id', p_workflow_run_id
    )
  );

  RETURN jsonb_build_object(
    'decision',       v_decision,
    'tier',           v_tier::text,
    'tier_label',     v_tier_label,
    'model_id',       v_model_id,
    'prompt_version', NULL,
    'routing_reason', v_routing_reason,
    'audit_event_id', v_audit_row.id
  );
END;
$function$;
COMMENT ON FUNCTION public.route_ai_call(text, uuid, uuid, text, uuid) IS
  'Routes an AI tool invocation to a tier (or BLOCKs it per business opt-out). Returns jsonb envelope with decision, tier, tier_label, model_id, prompt_version (NULL until B06·P04), routing_reason, audit_event_id. Emits AI_TIER_ROUTED on ALLOW, AI_TIER_BLOCKED on opt-out. Never silently escalates Tier 2 to Tier 3 — calling phase decides on explicit retry.';

REVOKE EXECUTE ON FUNCTION public.route_ai_call(text, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.route_ai_call(text, uuid, uuid, text, uuid) TO service_role;

-- ============================================================================
-- 5. update_business_ai_config
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_business_ai_config(
  p_actor_user_id uuid,
  p_business_id   uuid,
  p_tier2_enabled boolean,
  p_tier3_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_biz         public.business_entities%ROWTYPE;
  v_perm        jsonb;
  v_perm_dec    text;
  v_before      public.business_ai_config%ROWTYPE;
  v_after       public.business_ai_config%ROWTYPE;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
BEGIN
  IF p_actor_user_id IS NULL OR p_business_id IS NULL
     OR p_tier2_enabled IS NULL OR p_tier3_enabled IS NULL THEN
    RAISE EXCEPTION 'update_business_ai_config: required params missing'
      USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    v_reject_code := 'BUSINESS_NOT_FOUND';
    v_reject_msg  := format('business %s not found', p_business_id);
  END IF;

  IF v_reject_code IS NULL THEN
    v_perm := public.can_perform(
      p_actor_user_id   => p_actor_user_id,
      p_surface         => 'business_ai_config',
      p_action          => 'update',
      p_resource        => jsonb_build_object('business_id', p_business_id),
      p_business_id     => p_business_id,
      p_organization_id => v_biz.organization_id
    );
    v_perm_dec := v_perm->>'decision';
    IF v_perm_dec = 'DENY' THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('actor lacks permission business_ai_config:update (reason=%s)',
                               v_perm->>'reason_code');
    ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind      => 'USER'::audit.actor_kind_enum,
      p_action          => 'AI_TIER_CONFIG_UPDATE_REJECTED',
      p_subject_type    => 'BUSINESS_AI_CONFIG'::audit.subject_type_enum,
      p_subject_id      => NULL,
      p_actor_user_id   => p_actor_user_id,
      p_business_id     => p_business_id,
      p_organization_id => v_biz.organization_id,
      p_reason          => v_reject_msg,
      p_after_state     => jsonb_build_object(
        'rejection_code', v_reject_code,
        'business_id',    p_business_id,
        'requested',      jsonb_build_object(
                            'tier2_enabled', p_tier2_enabled,
                            'tier3_enabled', p_tier3_enabled
                          )
      )
    );
    RETURN jsonb_build_object(
      'ok',             false,
      'reason',         v_reject_code,
      'message',        v_reject_msg,
      'audit_event_id', v_audit_row.id
    );
  END IF;

  SELECT * INTO v_before FROM public.business_ai_config WHERE business_id = p_business_id;

  INSERT INTO public.business_ai_config (
    business_id, tier2_enabled, tier3_enabled, updated_by_user_id, updated_at
  ) VALUES (
    p_business_id, p_tier2_enabled, p_tier3_enabled, p_actor_user_id, clock_timestamp()
  )
  ON CONFLICT (business_id) DO UPDATE
    SET tier2_enabled      = EXCLUDED.tier2_enabled,
        tier3_enabled      = EXCLUDED.tier3_enabled,
        updated_by_user_id = EXCLUDED.updated_by_user_id,
        updated_at         = EXCLUDED.updated_at
  RETURNING * INTO v_after;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'AI_TIER_CONFIG_UPDATED',
    p_subject_type    => 'BUSINESS_AI_CONFIG'::audit.subject_type_enum,
    p_subject_id      => v_after.id,
    p_actor_user_id   => p_actor_user_id,
    p_business_id     => p_business_id,
    p_organization_id => v_biz.organization_id,
    p_before_state    => CASE WHEN v_before.id IS NOT NULL THEN
                           jsonb_build_object(
                             'tier2_enabled', v_before.tier2_enabled,
                             'tier3_enabled', v_before.tier3_enabled
                           )
                         ELSE NULL END,
    p_after_state     => jsonb_build_object(
      'config_id',     v_after.id,
      'business_id',   p_business_id,
      'tier2_enabled', v_after.tier2_enabled,
      'tier3_enabled', v_after.tier3_enabled,
      'first_write',   v_before.id IS NULL
    ),
    p_reason          => format('business_ai_config %s for business %s',
                                 CASE WHEN v_before.id IS NULL THEN 'created' ELSE 'updated' END,
                                 p_business_id)
  );

  RETURN jsonb_build_object(
    'ok',             true,
    'config_id',      v_after.id,
    'business_id',    p_business_id,
    'tier2_enabled',  v_after.tier2_enabled,
    'tier3_enabled',  v_after.tier3_enabled,
    'first_write',    v_before.id IS NULL,
    'audit_event_id', v_audit_row.id
  );
END;
$function$;
COMMENT ON FUNCTION public.update_business_ai_config(uuid, uuid, boolean, boolean) IS
  'Owner-only RPC to update per-business AI tier opt-out flags. UPSERT semantics (creates row on first write). Emits AI_TIER_CONFIG_UPDATED on success, AI_TIER_CONFIG_UPDATE_REJECTED on policy failure. Mitigation A: returns jsonb envelope on policy failure, never raises post-audit.';

REVOKE EXECUTE ON FUNCTION public.update_business_ai_config(uuid, uuid, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_ai_config(uuid, uuid, boolean, boolean) TO service_role;
