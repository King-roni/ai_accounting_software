-- B06·P02 — Fix-up: remove unused REDACTION_REJECTED enum values
--
-- The original B06·P02 migration (20260521000025) pre-added
-- COMPLETED_REDACTION_REJECTED to ai_gateway_invocation_status_enum and
-- REDACTION_REJECTED to ai_gateway_result_variant_enum on the assumption that
-- B06·P03 would need them. That was scope creep: P02 has no code path that
-- can reach those values, and Postgres enums cannot drop values via ALTER TYPE.
--
-- Fix: drop the table + functions + enums and recreate them without the unused
-- values. B06·P03 will add the values via ALTER TYPE ADD VALUE (with the
-- deferred-visibility two-migration split) when it actually wires the
-- redaction policy into the gateway pipeline.
--
-- Safe to drop the table: B06·P02 is pre-production, the lifecycle test
-- rolled back its fixtures, and no other migration writes to this table.

DROP FUNCTION IF EXISTS public.ai_gateway_invoke_begin(text, uuid, jsonb, uuid, text, uuid);
DROP FUNCTION IF EXISTS public.ai_gateway_invoke_finalize(uuid, text, jsonb, jsonb);

DROP TABLE IF EXISTS public.ai_gateway_invocations;

DROP TYPE IF EXISTS public.ai_gateway_invocation_status_enum;
DROP TYPE IF EXISTS public.ai_gateway_result_variant_enum;

-- ============================================================================
-- Recreated enums — without REDACTION_REJECTED variants
-- ============================================================================
CREATE TYPE public.ai_gateway_invocation_status_enum AS ENUM (
  'PREPARED',
  'COMPLETED_SUCCESS',
  'COMPLETED_SCHEMA_VIOLATION_INPUT',
  'COMPLETED_SCHEMA_VIOLATION_OUTPUT',
  'COMPLETED_TIER_BLOCKED',
  'COMPLETED_MODEL_ERROR'
);
COMMENT ON TYPE public.ai_gateway_invocation_status_enum IS
  'Lifecycle status of a gateway invocation row. PREPARED is the post-begin in-flight state; every COMPLETED_* value maps 1:1 to a spec AIResult variant. Redaction-rejected state is intentionally absent until B06·P03 adds it.';

CREATE TYPE public.ai_gateway_result_variant_enum AS ENUM (
  'SUCCESS',
  'SCHEMA_VIOLATION_INPUT',
  'SCHEMA_VIOLATION_OUTPUT',
  'TIER_BLOCKED',
  'MODEL_ERROR'
);
COMMENT ON TYPE public.ai_gateway_result_variant_enum IS
  'Canonical AIResult variant returned by the gateway (B06·P02 spec §AIResult variants). REDACTION_REJECTED is intentionally absent until B06·P03 adds it.';

-- ============================================================================
-- Recreated table (identical shape to 20260521000025)
-- ============================================================================
CREATE TABLE public.ai_gateway_invocations (
  id                 uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  business_id        uuid NOT NULL REFERENCES public.business_entities(id),
  workflow_run_id    uuid NULL,
  tool_name          text NOT NULL REFERENCES public.tool_registry(tool_name),
  tier               public.ai_tier_enum NOT NULL,
  tier_label         text NOT NULL,
  model_id           text NULL,
  prompt_version     text NULL,
  calling_phase      text NULL,
  actor_user_id      uuid NULL REFERENCES public.users(id),
  status             public.ai_gateway_invocation_status_enum NOT NULL,
  result_variant     public.ai_gateway_result_variant_enum NULL,
  input_received     jsonb NOT NULL,
  minimized_input    jsonb NULL,
  raw_response       jsonb NULL,
  validated_output   jsonb NULL,
  error_detail       jsonb NULL,
  prepared_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  finalized_at       timestamptz NULL,
  CONSTRAINT agi_terminal_state_has_variant
    CHECK ((status = 'PREPARED' AND result_variant IS NULL)
           OR (status <> 'PREPARED' AND result_variant IS NOT NULL)),
  CONSTRAINT agi_terminal_state_has_finalized_at
    CHECK ((status = 'PREPARED' AND finalized_at IS NULL)
           OR (status <> 'PREPARED' AND finalized_at IS NOT NULL))
);
COMMENT ON TABLE public.ai_gateway_invocations IS
  'One row per AI gateway invocation. Created by ai_gateway_invoke_begin (status=PREPARED) and updated by ai_gateway_invoke_finalize (status=COMPLETED_*). Rows with status=COMPLETED_SCHEMA_VIOLATION_INPUT / COMPLETED_TIER_BLOCKED are inserted directly in begin (no model dispatch occurred).';

CREATE INDEX idx_agi_business_prepared_at ON public.ai_gateway_invocations (business_id, prepared_at DESC);
CREATE INDEX idx_agi_status ON public.ai_gateway_invocations (status) WHERE status = 'PREPARED';

REVOKE ALL ON public.ai_gateway_invocations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ai_gateway_invocations TO service_role;

-- ============================================================================
-- Recreated functions (identical bodies to 20260521000025)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_gateway_invoke_begin(
  p_tool_name        text,
  p_business_id      uuid,
  p_input            jsonb,
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
  v_biz          public.business_entities%ROWTYPE;
  v_tool         public.tool_registry%ROWTYPE;
  v_tier_label   text;
  v_schema_chk   jsonb;
  v_minimized    jsonb;
  v_route        jsonb;
  v_route_dec    text;
  v_invocation_id uuid;
  v_audit_kind   audit.actor_kind_enum;
  v_actor_system text;
  v_audit_row    audit.audit_events;
BEGIN
  IF p_tool_name IS NULL OR p_business_id IS NULL OR p_input IS NULL THEN
    RAISE EXCEPTION 'ai_gateway_invoke_begin: p_tool_name, p_business_id, p_input required'
      USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false, 'decision', 'ERROR',
      'error_code', 'BUSINESS_NOT_FOUND',
      'message', format('business %s not found', p_business_id)
    );
  END IF;

  SELECT * INTO v_tool FROM public.tool_registry WHERE tool_name = p_tool_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false, 'decision', 'ERROR',
      'error_code', 'TOOL_NOT_FOUND',
      'message', format('tool %s not registered', p_tool_name)
    );
  END IF;

  IF v_tool.ai_tier = 'NONE'::public.ai_tier_enum THEN
    RETURN jsonb_build_object(
      'ok', false, 'decision', 'ERROR',
      'error_code', 'TIER_1_BYPASS_REQUIRED',
      'message', format('tool %s is Tier 1 (no AI); must not reach gateway', p_tool_name)
    );
  END IF;

  v_tier_label := public.ai_tier_canonical_label(v_tool.ai_tier);

  v_schema_chk := public._jsonb_matches_schema(p_input, v_tool.input_schema);
  IF NOT (v_schema_chk->>'valid')::boolean THEN
    INSERT INTO public.ai_gateway_invocations (
      business_id, workflow_run_id, tool_name, tier, tier_label, model_id,
      calling_phase, actor_user_id, status, result_variant,
      input_received, error_detail, finalized_at
    ) VALUES (
      p_business_id, p_workflow_run_id, p_tool_name, v_tool.ai_tier, v_tier_label, NULL,
      p_calling_phase, p_actor_user_id,
      'COMPLETED_SCHEMA_VIOLATION_INPUT'::public.ai_gateway_invocation_status_enum,
      'SCHEMA_VIOLATION_INPUT'::public.ai_gateway_result_variant_enum,
      p_input, v_schema_chk->'errors', clock_timestamp()
    )
    RETURNING id INTO v_invocation_id;

    IF p_actor_user_id IS NULL THEN
      v_audit_kind := 'SYSTEM'::audit.actor_kind_enum;
      v_actor_system := 'ai_gateway';
    ELSE
      v_audit_kind := 'USER'::audit.actor_kind_enum;
      v_actor_system := NULL;
    END IF;

    v_audit_row := audit.emit_audit(
      p_actor_kind      => v_audit_kind,
      p_action          => 'AI_GATEWAY_VALIDATION_FAILED',
      p_subject_type    => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
      p_subject_id      => v_invocation_id,
      p_actor_user_id   => p_actor_user_id,
      p_actor_system    => v_actor_system,
      p_organization_id => v_biz.organization_id,
      p_business_id     => p_business_id,
      p_reason          => format('input failed schema for tool %s', p_tool_name),
      p_after_state     => jsonb_build_object(
        'invocation_id', v_invocation_id,
        'tool_name',     p_tool_name,
        'variant',       'SCHEMA_VIOLATION_INPUT',
        'errors',        v_schema_chk->'errors'
      )
    );

    RETURN jsonb_build_object(
      'ok',             false,
      'invocation_id',  v_invocation_id,
      'result_variant', 'SCHEMA_VIOLATION_INPUT',
      'errors',         v_schema_chk->'errors',
      'audit_event_id', v_audit_row.id
    );
  END IF;

  v_minimized := public.ai_gateway_minimize_payload(v_tool.input_schema, p_input);

  v_route := public.route_ai_call(
    p_tool_name        => p_tool_name,
    p_business_id      => p_business_id,
    p_workflow_run_id  => p_workflow_run_id,
    p_calling_phase    => p_calling_phase,
    p_actor_user_id    => p_actor_user_id
  );
  v_route_dec := v_route->>'decision';

  IF v_route_dec = 'BLOCK' THEN
    INSERT INTO public.ai_gateway_invocations (
      business_id, workflow_run_id, tool_name, tier, tier_label, model_id,
      calling_phase, actor_user_id, status, result_variant,
      input_received, minimized_input, error_detail, finalized_at
    ) VALUES (
      p_business_id, p_workflow_run_id, p_tool_name, v_tool.ai_tier, v_tier_label, NULL,
      p_calling_phase, p_actor_user_id,
      'COMPLETED_TIER_BLOCKED'::public.ai_gateway_invocation_status_enum,
      'TIER_BLOCKED'::public.ai_gateway_result_variant_enum,
      p_input, v_minimized,
      jsonb_build_object('routing_reason', v_route->>'routing_reason',
                         'route_audit_event_id', v_route->>'audit_event_id'),
      clock_timestamp()
    )
    RETURNING id INTO v_invocation_id;

    RETURN jsonb_build_object(
      'ok',             false,
      'invocation_id',  v_invocation_id,
      'result_variant', 'TIER_BLOCKED',
      'routing_reason', v_route->>'routing_reason',
      'audit_event_id', v_route->>'audit_event_id'
    );
  ELSIF v_route_dec <> 'ALLOW' THEN
    RETURN jsonb_build_object(
      'ok', false, 'decision', 'ERROR',
      'error_code', COALESCE(v_route->>'error_code', 'ROUTING_UNEXPECTED'),
      'message', format('routing returned unexpected decision: %s', v_route_dec),
      'route_envelope', v_route
    );
  END IF;

  INSERT INTO public.ai_gateway_invocations (
    business_id, workflow_run_id, tool_name, tier, tier_label, model_id, prompt_version,
    calling_phase, actor_user_id, status, input_received, minimized_input
  ) VALUES (
    p_business_id, p_workflow_run_id, p_tool_name, v_tool.ai_tier, v_tier_label,
    v_route->>'model_id', v_route->>'prompt_version',
    p_calling_phase, p_actor_user_id,
    'PREPARED'::public.ai_gateway_invocation_status_enum, p_input, v_minimized
  )
  RETURNING id INTO v_invocation_id;

  IF p_actor_user_id IS NULL THEN
    v_audit_kind := 'SYSTEM'::audit.actor_kind_enum;
    v_actor_system := 'ai_gateway';
  ELSE
    v_audit_kind := 'USER'::audit.actor_kind_enum;
    v_actor_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => v_audit_kind,
    p_action          => 'AI_GATEWAY_INVOKED',
    p_subject_type    => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
    p_subject_id      => v_invocation_id,
    p_actor_user_id   => p_actor_user_id,
    p_actor_system    => v_actor_system,
    p_organization_id => v_biz.organization_id,
    p_business_id     => p_business_id,
    p_reason          => format('gateway invocation prepared for tool %s tier %s',
                                 p_tool_name, v_tier_label),
    p_after_state     => jsonb_build_object(
      'invocation_id',   v_invocation_id,
      'tool_name',       p_tool_name,
      'tier',            v_tool.ai_tier::text,
      'tier_label',      v_tier_label,
      'model_id',        v_route->>'model_id',
      'calling_phase',   p_calling_phase,
      'workflow_run_id', p_workflow_run_id
    )
  );

  RETURN jsonb_build_object(
    'ok',              true,
    'invocation_id',   v_invocation_id,
    'tier',            v_tool.ai_tier::text,
    'tier_label',      v_tier_label,
    'model_id',        v_route->>'model_id',
    'prompt_version',  v_route->>'prompt_version',
    'minimized_input', v_minimized,
    'audit_event_id',  v_audit_row.id
  );
END;
$function$;
COMMENT ON FUNCTION public.ai_gateway_invoke_begin(text, uuid, jsonb, uuid, text, uuid) IS
  'AI gateway chokepoint (begin phase). Recreated by 20260521000026 fix-up; behaviour unchanged from 20260521000025.';

REVOKE EXECUTE ON FUNCTION public.ai_gateway_invoke_begin(text, uuid, jsonb, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_gateway_invoke_begin(text, uuid, jsonb, uuid, text, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.ai_gateway_invoke_finalize(
  p_invocation_id        uuid,
  p_dispatch_status      text,
  p_raw_response         jsonb DEFAULT NULL,
  p_dispatch_error_detail jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_inv          public.ai_gateway_invocations%ROWTYPE;
  v_biz          public.business_entities%ROWTYPE;
  v_validate     jsonb;
  v_variant      public.ai_gateway_result_variant_enum;
  v_status       public.ai_gateway_invocation_status_enum;
  v_audit_kind   audit.actor_kind_enum;
  v_actor_system text;
  v_audit_row    audit.audit_events;
  v_audit_event_id uuid;
BEGIN
  IF p_invocation_id IS NULL OR p_dispatch_status IS NULL THEN
    RAISE EXCEPTION 'ai_gateway_invoke_finalize: p_invocation_id and p_dispatch_status required'
      USING ERRCODE = '22000';
  END IF;
  IF p_dispatch_status NOT IN ('OK','ERROR') THEN
    RAISE EXCEPTION 'ai_gateway_invoke_finalize: p_dispatch_status must be OK or ERROR (got %)',
      p_dispatch_status USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_inv FROM public.ai_gateway_invocations WHERE id = p_invocation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false, 'decision', 'ERROR',
      'error_code', 'INVOCATION_NOT_FOUND',
      'message', format('gateway invocation %s not found', p_invocation_id)
    );
  END IF;
  IF v_inv.status <> 'PREPARED'::public.ai_gateway_invocation_status_enum THEN
    RETURN jsonb_build_object(
      'ok', false, 'decision', 'ERROR',
      'error_code', 'ALREADY_FINALIZED',
      'message', format('gateway invocation %s already in status %s', p_invocation_id, v_inv.status),
      'current_status', v_inv.status::text
    );
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = v_inv.business_id;

  IF p_dispatch_status = 'ERROR' THEN
    v_variant := 'MODEL_ERROR'::public.ai_gateway_result_variant_enum;
    v_status  := 'COMPLETED_MODEL_ERROR'::public.ai_gateway_invocation_status_enum;
    UPDATE public.ai_gateway_invocations
       SET status = v_status, result_variant = v_variant,
           raw_response = p_raw_response,
           error_detail = COALESCE(p_dispatch_error_detail,
                                   jsonb_build_object('code','MODEL_ERROR')),
           finalized_at = clock_timestamp()
     WHERE id = p_invocation_id;
    RETURN jsonb_build_object(
      'ok',             false,
      'invocation_id',  p_invocation_id,
      'result_variant', 'MODEL_ERROR',
      'error_detail',   COALESCE(p_dispatch_error_detail,
                                 jsonb_build_object('code','MODEL_ERROR'))
    );
  END IF;

  IF p_raw_response IS NULL THEN
    v_validate := jsonb_build_object('valid', false,
                    'errors', jsonb_build_array(jsonb_build_object(
                                'code','NULL_RESPONSE',
                                'message','dispatch_status=OK requires non-null raw_response')));
  ELSE
    v_validate := public.validate_tool_output(v_inv.tool_name, p_raw_response);
  END IF;

  IF NOT (v_validate->>'valid')::boolean THEN
    v_variant := 'SCHEMA_VIOLATION_OUTPUT'::public.ai_gateway_result_variant_enum;
    v_status  := 'COMPLETED_SCHEMA_VIOLATION_OUTPUT'::public.ai_gateway_invocation_status_enum;
    UPDATE public.ai_gateway_invocations
       SET status = v_status, result_variant = v_variant,
           raw_response = p_raw_response,
           error_detail = v_validate->'errors',
           finalized_at = clock_timestamp()
     WHERE id = p_invocation_id;

    IF v_inv.actor_user_id IS NULL THEN
      v_audit_kind := 'SYSTEM'::audit.actor_kind_enum;
      v_actor_system := 'ai_gateway';
    ELSE
      v_audit_kind := 'USER'::audit.actor_kind_enum;
      v_actor_system := NULL;
    END IF;

    v_audit_row := audit.emit_audit(
      p_actor_kind      => v_audit_kind,
      p_action          => 'AI_GATEWAY_RESPONSE_INVALID',
      p_subject_type    => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
      p_subject_id      => p_invocation_id,
      p_actor_user_id   => v_inv.actor_user_id,
      p_actor_system    => v_actor_system,
      p_organization_id => v_biz.organization_id,
      p_business_id     => v_inv.business_id,
      p_reason          => format('model output failed schema for tool %s', v_inv.tool_name),
      p_after_state     => jsonb_build_object(
        'invocation_id', p_invocation_id,
        'tool_name',     v_inv.tool_name,
        'variant',       'SCHEMA_VIOLATION_OUTPUT',
        'errors',        v_validate->'errors'
      )
    );
    v_audit_event_id := v_audit_row.id;

    RETURN jsonb_build_object(
      'ok',             false,
      'invocation_id',  p_invocation_id,
      'result_variant', 'SCHEMA_VIOLATION_OUTPUT',
      'errors',         v_validate->'errors',
      'audit_event_id', v_audit_event_id
    );
  END IF;

  v_variant := 'SUCCESS'::public.ai_gateway_result_variant_enum;
  v_status  := 'COMPLETED_SUCCESS'::public.ai_gateway_invocation_status_enum;
  UPDATE public.ai_gateway_invocations
     SET status = v_status, result_variant = v_variant,
         raw_response = p_raw_response,
         validated_output = p_raw_response,
         finalized_at = clock_timestamp()
   WHERE id = p_invocation_id;

  RETURN jsonb_build_object(
    'ok',               true,
    'invocation_id',    p_invocation_id,
    'result_variant',   'SUCCESS',
    'validated_output', p_raw_response,
    'tier',             v_inv.tier::text,
    'tier_label',       v_inv.tier_label,
    'model_id',         v_inv.model_id,
    'prompt_version',   v_inv.prompt_version
  );
END;
$function$;
COMMENT ON FUNCTION public.ai_gateway_invoke_finalize(uuid, text, jsonb, jsonb) IS
  'AI gateway finalize phase. Recreated by 20260521000026 fix-up; behaviour unchanged from 20260521000025.';

REVOKE EXECUTE ON FUNCTION public.ai_gateway_invoke_finalize(uuid, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_gateway_invoke_finalize(uuid, text, jsonb, jsonb) TO service_role;
