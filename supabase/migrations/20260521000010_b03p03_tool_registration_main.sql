-- B03·P03 Tool Registration Framework (main)
-- =============================================================================
-- DB layer mirrors code-side tool declarations from Blocks 06–13 as
-- authoritative reference data. Engine startup (API/web) calls register_tool
-- for each declared tool; phase definitions link tools to phases via
-- phase_tool_expectations; the engine's invokeTool (B03·P06) calls
-- validate_tool_invocation BEFORE executing and validate_tool_output AFTER.
-- =============================================================================

CREATE TYPE public.side_effect_class_enum AS ENUM ('READ_ONLY','WRITES_RUN_STATE','CALLS_EXTERNAL_API');
CREATE TYPE public.ai_tier_enum AS ENUM ('NONE','LOCAL_LLM','EXTERNAL_LLM');
CREATE TYPE public.tool_failure_semantics_enum AS ENUM ('RETRYABLE','FATAL_ON_FIRST_FAIL','IDEMPOTENT_AT_MOST_ONCE');

-- ---- tool_registry ----------------------------------------------------------
CREATE TABLE public.tool_registry (
  tool_name                 text PRIMARY KEY,
  version                   text NOT NULL,
  input_schema              jsonb NOT NULL,
  output_schema             jsonb NOT NULL,
  side_effect               public.side_effect_class_enum NOT NULL,
  ai_tier                   public.ai_tier_enum NOT NULL DEFAULT 'NONE',
  failure_semantics         public.tool_failure_semantics_enum NOT NULL,
  dedup_key_generator_ref   text,
  description               text,
  registered_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT tr_name_namespaced   CHECK (tool_name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  CONSTRAINT tr_version_semver    CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'),
  CONSTRAINT tr_input_schema_obj  CHECK (jsonb_typeof(input_schema)  = 'object'),
  CONSTRAINT tr_output_schema_obj CHECK (jsonb_typeof(output_schema) = 'object')
);

CREATE INDEX idx_tool_registry_ai_tier     ON public.tool_registry (ai_tier);
CREATE INDEX idx_tool_registry_side_effect ON public.tool_registry (side_effect);

CREATE TRIGGER tool_registry_set_updated_at
  BEFORE UPDATE ON public.tool_registry
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---- phase_tool_expectations ------------------------------------------------
CREATE TABLE public.phase_tool_expectations (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_type            public.workflow_type_enum NOT NULL,
  phase_name               text NOT NULL,
  tool_name                text NOT NULL REFERENCES public.tool_registry(tool_name) ON DELETE RESTRICT,
  permitted_side_effects   public.side_effect_class_enum[] NOT NULL,
  required                 boolean NOT NULL DEFAULT true,
  created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pte_unique_assignment       UNIQUE (workflow_type, phase_name, tool_name),
  CONSTRAINT pte_permitted_nonempty      CHECK (cardinality(permitted_side_effects) >= 1)
);

CREATE INDEX idx_phase_tool_expectations_phase ON public.phase_tool_expectations (workflow_type, phase_name);
CREATE INDEX idx_phase_tool_expectations_tool  ON public.phase_tool_expectations (tool_name);

-- Trigger: phase_name must exist in workflow_phase_definitions for the same workflow_type
CREATE OR REPLACE FUNCTION public.fn_check_phase_in_registry()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.workflow_phase_definitions wpd
     WHERE wpd.workflow_type = NEW.workflow_type AND wpd.phase_name = NEW.phase_name
  ) THEN
    RAISE EXCEPTION 'phase_tool_expectations: phase % not in workflow_phase_definitions for type %', NEW.phase_name, NEW.workflow_type
      USING ERRCODE='P0002';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_pte_phase_exists
  BEFORE INSERT OR UPDATE OF workflow_type, phase_name ON public.phase_tool_expectations
  FOR EACH ROW EXECUTE FUNCTION public.fn_check_phase_in_registry();

-- ---- RLS — public lookup ----------------------------------------------------
ALTER TABLE public.tool_registry             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tool_registry             FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.phase_tool_expectations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.phase_tool_expectations   FORCE  ROW LEVEL SECURITY;

CREATE POLICY tr_select_all  ON public.tool_registry AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY tr_no_insert   ON public.tool_registry AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY tr_no_update   ON public.tool_registry AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY tr_no_delete   ON public.tool_registry AS RESTRICTIVE FOR DELETE TO authenticated USING (false);
CREATE POLICY pte_select_all ON public.phase_tool_expectations AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY pte_no_insert  ON public.phase_tool_expectations AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY pte_no_update  ON public.phase_tool_expectations AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY pte_no_delete  ON public.phase_tool_expectations AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON public.tool_registry, public.phase_tool_expectations TO authenticated, service_role;

-- ---- helper: JSON-Schema-lite match -----------------------------------------
-- MVP: enforces (a) required keys present in payload (b) no additional keys
-- when schema.additionalProperties = false. Returns {valid, errors[]}.
CREATE OR REPLACE FUNCTION public._jsonb_matches_schema(p_payload jsonb, p_schema jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_temp
AS $fn$
DECLARE
  v_required   jsonb;
  v_props      jsonb;
  v_addl       boolean;
  v_errors     jsonb := '[]'::jsonb;
  v_missing    text[] := ARRAY[]::text[];
  v_extra      text[] := ARRAY[]::text[];
  v_key        text;
BEGIN
  IF p_payload IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'errors', jsonb_build_array(jsonb_build_object('code','NULL_PAYLOAD','message','payload is NULL')));
  END IF;
  IF jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('valid', false, 'errors', jsonb_build_array(jsonb_build_object('code','NOT_OBJECT','message','payload must be a JSON object')));
  END IF;

  v_required := p_schema -> 'required';
  v_props    := p_schema -> 'properties';
  v_addl     := COALESCE((p_schema ->> 'additionalProperties')::boolean, true);

  -- Required keys
  IF v_required IS NOT NULL AND jsonb_typeof(v_required) = 'array' THEN
    SELECT array_agg(req)
      INTO v_missing
      FROM jsonb_array_elements_text(v_required) AS req
     WHERE NOT (p_payload ? req);
    IF v_missing IS NOT NULL AND cardinality(v_missing) > 0 THEN
      v_errors := v_errors || jsonb_build_object('code','MISSING_REQUIRED','message',format('missing required keys: %s', array_to_string(v_missing, ', ')),'keys', to_jsonb(v_missing));
    END IF;
  END IF;

  -- additionalProperties=false → reject extra keys
  IF NOT v_addl AND v_props IS NOT NULL THEN
    FOR v_key IN SELECT * FROM jsonb_object_keys(p_payload) LOOP
      IF NOT (v_props ? v_key) THEN
        v_extra := v_extra || v_key;
      END IF;
    END LOOP;
    IF cardinality(v_extra) > 0 THEN
      v_errors := v_errors || jsonb_build_object('code','UNEXPECTED_KEYS','message',format('unexpected keys: %s', array_to_string(v_extra, ', ')),'keys', to_jsonb(v_extra));
    END IF;
  END IF;

  RETURN jsonb_build_object('valid', jsonb_array_length(v_errors) = 0, 'errors', v_errors);
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public._jsonb_matches_schema(jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public._jsonb_matches_schema(jsonb, jsonb) TO authenticated, service_role;

-- ---- RPC: register_tool -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_tool(
  p_tool_name              text,
  p_version                text,
  p_input_schema           jsonb,
  p_output_schema          jsonb,
  p_side_effect            public.side_effect_class_enum,
  p_ai_tier                public.ai_tier_enum,
  p_failure_semantics      public.tool_failure_semantics_enum,
  p_dedup_key_generator_ref text DEFAULT NULL,
  p_description            text DEFAULT NULL
) RETURNS public.tool_registry
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_row public.tool_registry;
BEGIN
  IF p_tool_name IS NULL OR length(btrim(p_tool_name)) = 0 THEN
    RAISE EXCEPTION 'register_tool: tool_name required' USING ERRCODE='22000';
  END IF;
  IF p_version IS NULL OR length(btrim(p_version)) = 0 THEN
    RAISE EXCEPTION 'register_tool: version required' USING ERRCODE='22000';
  END IF;
  IF p_input_schema IS NULL OR jsonb_typeof(p_input_schema) <> 'object' THEN
    RAISE EXCEPTION 'register_tool: input_schema must be jsonb object' USING ERRCODE='22000';
  END IF;
  IF p_output_schema IS NULL OR jsonb_typeof(p_output_schema) <> 'object' THEN
    RAISE EXCEPTION 'register_tool: output_schema must be jsonb object' USING ERRCODE='22000';
  END IF;

  INSERT INTO public.tool_registry (
    tool_name, version, input_schema, output_schema, side_effect, ai_tier, failure_semantics,
    dedup_key_generator_ref, description
  ) VALUES (
    p_tool_name, p_version, p_input_schema, p_output_schema, p_side_effect, p_ai_tier, p_failure_semantics,
    p_dedup_key_generator_ref, p_description
  )
  ON CONFLICT (tool_name) DO UPDATE SET
    version                 = EXCLUDED.version,
    input_schema            = EXCLUDED.input_schema,
    output_schema           = EXCLUDED.output_schema,
    side_effect             = EXCLUDED.side_effect,
    ai_tier                 = EXCLUDED.ai_tier,
    failure_semantics       = EXCLUDED.failure_semantics,
    dedup_key_generator_ref = EXCLUDED.dedup_key_generator_ref,
    description             = EXCLUDED.description,
    updated_at              = clock_timestamp()
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'TOOL_REGISTRY_REGISTERED',
    p_subject_type => 'TOOL_REGISTRY'::audit.subject_type_enum,
    p_actor_system => 'engine.registerTool',
    p_reason       => format('tool %s v%s registered (side_effect=%s ai_tier=%s)', p_tool_name, p_version, p_side_effect, p_ai_tier),
    p_after_state  => jsonb_build_object(
      'tool_name', p_tool_name, 'version', p_version,
      'side_effect', p_side_effect, 'ai_tier', p_ai_tier,
      'failure_semantics', p_failure_semantics,
      'dedup_key_generator_ref', p_dedup_key_generator_ref
    )
  );

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.register_tool(text, text, jsonb, jsonb, public.side_effect_class_enum, public.ai_tier_enum, public.tool_failure_semantics_enum, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.register_tool(text, text, jsonb, jsonb, public.side_effect_class_enum, public.ai_tier_enum, public.tool_failure_semantics_enum, text, text) TO service_role;

-- ---- RPC: record_tool_registration_rejected --------------------------------
CREATE OR REPLACE FUNCTION public.record_tool_registration_rejected(
  p_tool_name   text,
  p_reason      text,
  p_error_detail text DEFAULT NULL
) RETURNS audit.audit_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_row audit.audit_events;
BEGIN
  IF p_tool_name IS NULL OR length(btrim(p_tool_name)) = 0 THEN
    RAISE EXCEPTION 'record_tool_registration_rejected: tool_name required' USING ERRCODE='22000';
  END IF;
  v_row := audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'TOOL_REGISTRY_REJECTED',
    p_subject_type => 'TOOL_REGISTRY'::audit.subject_type_enum,
    p_actor_system => 'engine.registerTool',
    p_reason       => format('tool %s registration rejected: %s', p_tool_name, p_reason),
    p_after_state  => jsonb_build_object('tool_name', p_tool_name, 'reason', p_reason, 'error_detail', p_error_detail)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_tool_registration_rejected(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_tool_registration_rejected(text, text, text) TO service_role;

-- ---- RPC: add_phase_tool_expectation ---------------------------------------
CREATE OR REPLACE FUNCTION public.add_phase_tool_expectation(
  p_workflow_type           public.workflow_type_enum,
  p_phase_name              text,
  p_tool_name               text,
  p_permitted_side_effects  public.side_effect_class_enum[],
  p_required                boolean DEFAULT true
) RETURNS public.phase_tool_expectations
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_row public.phase_tool_expectations;
BEGIN
  IF p_workflow_type IS NULL THEN RAISE EXCEPTION 'add_phase_tool_expectation: workflow_type required' USING ERRCODE='22000'; END IF;
  IF p_phase_name IS NULL OR length(btrim(p_phase_name)) = 0 THEN
    RAISE EXCEPTION 'add_phase_tool_expectation: phase_name required' USING ERRCODE='22000'; END IF;
  IF p_tool_name IS NULL OR length(btrim(p_tool_name)) = 0 THEN
    RAISE EXCEPTION 'add_phase_tool_expectation: tool_name required' USING ERRCODE='22000'; END IF;
  IF p_permitted_side_effects IS NULL OR cardinality(p_permitted_side_effects) = 0 THEN
    RAISE EXCEPTION 'add_phase_tool_expectation: permitted_side_effects required' USING ERRCODE='22000'; END IF;

  INSERT INTO public.phase_tool_expectations (workflow_type, phase_name, tool_name, permitted_side_effects, required)
  VALUES (p_workflow_type, p_phase_name, p_tool_name, p_permitted_side_effects, p_required)
  ON CONFLICT (workflow_type, phase_name, tool_name) DO UPDATE SET
    permitted_side_effects = EXCLUDED.permitted_side_effects,
    required               = EXCLUDED.required
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.add_phase_tool_expectation(public.workflow_type_enum, text, text, public.side_effect_class_enum[], boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.add_phase_tool_expectation(public.workflow_type_enum, text, text, public.side_effect_class_enum[], boolean) TO service_role;

-- ---- RPC: validate_tool_invocation -----------------------------------------
CREATE OR REPLACE FUNCTION public.validate_tool_invocation(
  p_workflow_type   public.workflow_type_enum,
  p_phase_name      text,
  p_tool_name       text,
  p_input_payload   jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_errors  jsonb := '[]'::jsonb;
  v_tool    public.tool_registry;
  v_pte     public.phase_tool_expectations;
  v_schema_check jsonb;
BEGIN
  IF p_workflow_type IS NULL OR p_phase_name IS NULL OR p_tool_name IS NULL THEN
    RAISE EXCEPTION 'validate_tool_invocation: all of workflow_type, phase_name, tool_name required' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_tool FROM public.tool_registry WHERE tool_name = p_tool_name;
  IF NOT FOUND THEN
    v_errors := v_errors || jsonb_build_object('code','UNKNOWN_TOOL','message',format('tool %s not in registry', p_tool_name));
    RETURN jsonb_build_object('valid', false, 'errors', v_errors);
  END IF;

  SELECT * INTO v_pte FROM public.phase_tool_expectations
   WHERE workflow_type = p_workflow_type AND phase_name = p_phase_name AND tool_name = p_tool_name;
  IF NOT FOUND THEN
    v_errors := v_errors || jsonb_build_object('code','UNREGISTERED_FOR_PHASE','message',format('tool %s not declared for phase %s of %s', p_tool_name, p_phase_name, p_workflow_type));
  ELSE
    IF NOT (v_tool.side_effect = ANY(v_pte.permitted_side_effects)) THEN
      v_errors := v_errors || jsonb_build_object(
        'code','SIDE_EFFECT_DISALLOWED',
        'message', format('tool side_effect=%s not in phase permitted=%s', v_tool.side_effect, v_pte.permitted_side_effects),
        'tool_side_effect', v_tool.side_effect,
        'permitted', to_jsonb(v_pte.permitted_side_effects)
      );
    END IF;
  END IF;

  v_schema_check := public._jsonb_matches_schema(p_input_payload, v_tool.input_schema);
  IF NOT (v_schema_check->>'valid')::boolean THEN
    v_errors := v_errors || jsonb_build_object(
      'code','SCHEMA_VIOLATION_INPUT',
      'message','input payload failed schema check',
      'schema_errors', v_schema_check->'errors'
    );
  END IF;

  RETURN jsonb_build_object('valid', jsonb_array_length(v_errors) = 0, 'errors', v_errors);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.validate_tool_invocation(public.workflow_type_enum, text, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.validate_tool_invocation(public.workflow_type_enum, text, text, jsonb) TO authenticated, service_role;

-- ---- RPC: validate_tool_output ---------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_tool_output(
  p_tool_name       text,
  p_output_payload  jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tool         public.tool_registry;
  v_schema_check jsonb;
BEGIN
  IF p_tool_name IS NULL THEN RAISE EXCEPTION 'validate_tool_output: tool_name required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_tool FROM public.tool_registry WHERE tool_name = p_tool_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'errors', jsonb_build_array(jsonb_build_object('code','UNKNOWN_TOOL','message',format('tool %s not in registry', p_tool_name))));
  END IF;

  v_schema_check := public._jsonb_matches_schema(p_output_payload, v_tool.output_schema);
  IF NOT (v_schema_check->>'valid')::boolean THEN
    RETURN jsonb_build_object('valid', false, 'errors', jsonb_build_array(jsonb_build_object(
      'code','SCHEMA_VIOLATION_OUTPUT',
      'message','output payload failed schema check',
      'schema_errors', v_schema_check->'errors'
    )));
  END IF;
  RETURN jsonb_build_object('valid', true, 'errors', '[]'::jsonb);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.validate_tool_output(text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.validate_tool_output(text, jsonb) TO authenticated, service_role;

COMMENT ON TABLE public.tool_registry IS
'B03·P03 startup-registered tool declarations from Blocks 06–13. UPSERT by tool_name. JSON-Schema-lite validation in DB (MVP: required + additionalProperties); full JSON Schema validation in API/web layer.';

COMMENT ON TABLE public.phase_tool_expectations IS
'B03·P03 per-(workflow_type, phase_name, tool_name) declaration. permitted_side_effects gates which tool side_effects the phase will accept at invocation.';

COMMENT ON FUNCTION public.validate_tool_invocation(public.workflow_type_enum, text, text, jsonb) IS
'B03·P03 invocation-time gate. Returns {valid, errors}. Error codes: UNKNOWN_TOOL, UNREGISTERED_FOR_PHASE, SIDE_EFFECT_DISALLOWED, SCHEMA_VIOLATION_INPUT. B03·P06 engine.invokeTool MUST call this before executing the tool.';
