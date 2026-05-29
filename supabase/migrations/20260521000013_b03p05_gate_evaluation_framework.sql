-- B03·P05 Gate Evaluation Framework
-- =============================================================================
-- DB layer mirrors code-side gate function declarations. Engine startup (API)
-- calls register_gate per declared gate, then add_phase_gate for each phase
-- attachment. The engine's evaluate-gates loop (B03·P06) calls
-- list_phase_gates to enumerate, evaluates each gate code-side, then
-- record_gate_decision per outcome (or record_gate_threw on exception).
-- =============================================================================

CREATE TYPE public.gate_kind_enum          AS ENUM ('ENTRY','EXIT');
CREATE TYPE public.gate_hold_severity_enum AS ENUM ('ADVISORY','BLOCKING');

CREATE TABLE public.gate_registry (
  gate_name      text PRIMARY KEY,
  version        text NOT NULL,
  description    text,
  registered_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT gr_name_namespaced CHECK (gate_name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  CONSTRAINT gr_version_semver  CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$')
);

CREATE TRIGGER gate_registry_set_updated_at
  BEFORE UPDATE ON public.gate_registry
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.phase_gate_assignments (
  id            uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_type public.workflow_type_enum NOT NULL,
  phase_name    text NOT NULL,
  gate_name     text NOT NULL REFERENCES public.gate_registry(gate_name) ON DELETE RESTRICT,
  kind          public.gate_kind_enum NOT NULL,
  eval_order    integer NOT NULL DEFAULT 100,
  created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pga_unique_assignment UNIQUE (workflow_type, phase_name, gate_name, kind)
);

CREATE INDEX idx_pga_phase ON public.phase_gate_assignments (workflow_type, phase_name, kind, eval_order);
CREATE INDEX idx_pga_gate  ON public.phase_gate_assignments (gate_name);

CREATE OR REPLACE FUNCTION public.fn_check_gate_phase_in_registry()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.workflow_phase_definitions wpd
     WHERE wpd.workflow_type = NEW.workflow_type AND wpd.phase_name = NEW.phase_name
  ) THEN
    RAISE EXCEPTION 'phase_gate_assignments: phase % not in workflow_phase_definitions for type %', NEW.phase_name, NEW.workflow_type
      USING ERRCODE='P0002';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_pga_phase_exists
  BEFORE INSERT OR UPDATE OF workflow_type, phase_name ON public.phase_gate_assignments
  FOR EACH ROW EXECUTE FUNCTION public.fn_check_gate_phase_in_registry();

ALTER TABLE public.gate_registry           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gate_registry           FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.phase_gate_assignments  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.phase_gate_assignments  FORCE  ROW LEVEL SECURITY;

CREATE POLICY gr_select_all  ON public.gate_registry           AS PERMISSIVE  FOR SELECT TO authenticated USING (true);
CREATE POLICY gr_no_insert   ON public.gate_registry           AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY gr_no_update   ON public.gate_registry           AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY gr_no_delete   ON public.gate_registry           AS RESTRICTIVE FOR DELETE TO authenticated USING (false);
CREATE POLICY pga_select_all ON public.phase_gate_assignments  AS PERMISSIVE  FOR SELECT TO authenticated USING (true);
CREATE POLICY pga_no_insert  ON public.phase_gate_assignments  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY pga_no_update  ON public.phase_gate_assignments  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY pga_no_delete  ON public.phase_gate_assignments  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON public.gate_registry, public.phase_gate_assignments TO authenticated, service_role;

-- ---- RPC: register_gate -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_gate(
  p_gate_name   text,
  p_version     text,
  p_description text DEFAULT NULL
) RETURNS public.gate_registry
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE v_row public.gate_registry;
BEGIN
  IF p_gate_name IS NULL OR length(btrim(p_gate_name)) = 0 THEN
    RAISE EXCEPTION 'register_gate: gate_name required' USING ERRCODE='22000';
  END IF;
  IF p_version IS NULL OR length(btrim(p_version)) = 0 THEN
    RAISE EXCEPTION 'register_gate: version required' USING ERRCODE='22000';
  END IF;

  INSERT INTO public.gate_registry (gate_name, version, description)
  VALUES (p_gate_name, p_version, p_description)
  ON CONFLICT (gate_name) DO UPDATE SET
    version     = EXCLUDED.version,
    description = EXCLUDED.description,
    updated_at  = clock_timestamp()
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'GATE_REGISTRY_REGISTERED',
    p_subject_type => 'GATE_REGISTRY'::audit.subject_type_enum,
    p_actor_system => 'engine.registerGate',
    p_reason       => format('gate %s v%s registered', p_gate_name, p_version),
    p_after_state  => jsonb_build_object('gate_name', p_gate_name, 'version', p_version)
  );

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.register_gate(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.register_gate(text, text, text) TO service_role;

-- ---- RPC: add_phase_gate ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_phase_gate(
  p_workflow_type public.workflow_type_enum,
  p_phase_name    text,
  p_gate_name     text,
  p_kind          public.gate_kind_enum,
  p_eval_order    integer DEFAULT 100
) RETURNS public.phase_gate_assignments
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_row public.phase_gate_assignments;
BEGIN
  IF p_workflow_type IS NULL OR p_phase_name IS NULL OR p_gate_name IS NULL OR p_kind IS NULL THEN
    RAISE EXCEPTION 'add_phase_gate: all of workflow_type, phase_name, gate_name, kind required' USING ERRCODE='22000';
  END IF;

  INSERT INTO public.phase_gate_assignments (workflow_type, phase_name, gate_name, kind, eval_order)
  VALUES (p_workflow_type, p_phase_name, p_gate_name, p_kind, COALESCE(p_eval_order, 100))
  ON CONFLICT (workflow_type, phase_name, gate_name, kind) DO UPDATE SET
    eval_order = EXCLUDED.eval_order
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.add_phase_gate(public.workflow_type_enum, text, text, public.gate_kind_enum, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.add_phase_gate(public.workflow_type_enum, text, text, public.gate_kind_enum, integer) TO service_role;

-- ---- RPC: list_phase_gates --------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_phase_gates(
  p_workflow_type public.workflow_type_enum,
  p_phase_name    text,
  p_kind          public.gate_kind_enum
) RETURNS TABLE (
  gate_name   text,
  version     text,
  description text,
  eval_order  integer
)
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT gr.gate_name, gr.version, gr.description, pga.eval_order
    FROM public.phase_gate_assignments pga
    JOIN public.gate_registry gr ON gr.gate_name = pga.gate_name
   WHERE pga.workflow_type = p_workflow_type
     AND pga.phase_name    = p_phase_name
     AND pga.kind          = p_kind
   ORDER BY pga.eval_order, gr.gate_name;
$fn$;
REVOKE EXECUTE ON FUNCTION public.list_phase_gates(public.workflow_type_enum, text, public.gate_kind_enum) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_phase_gates(public.workflow_type_enum, text, public.gate_kind_enum) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._resolve_phase_state_context(p_phase_state_id uuid)
RETURNS TABLE (run_id uuid, business_id uuid, organization_id uuid)
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT wr.id, wr.business_id, wr.organization_id
    FROM public.workflow_phase_states wps
    JOIN public.workflow_runs wr ON wr.id = wps.workflow_run_id
   WHERE wps.id = p_phase_state_id;
$fn$;

-- ---- RPC: record_gate_decision ---------------------------------------------
CREATE OR REPLACE FUNCTION public.record_gate_decision(
  p_phase_state_id uuid,
  p_gate_name      text,
  p_decision       public.gate_decision_enum,
  p_reason         text DEFAULT NULL,
  p_severity       public.gate_hold_severity_enum DEFAULT NULL,
  p_side_phase     text DEFAULT NULL,
  p_actor_user_id  uuid DEFAULT NULL,
  p_context        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_ctx     RECORD;
  v_audit   audit.audit_events;
  v_action  text;
  v_updated boolean := false;
  v_payload jsonb;
BEGIN
  IF p_phase_state_id IS NULL OR p_gate_name IS NULL OR p_decision IS NULL THEN
    RAISE EXCEPTION 'record_gate_decision: phase_state_id, gate_name, decision required' USING ERRCODE='22000';
  END IF;
  IF p_decision IN ('HOLD','ROUTE_TO_SIDE_PHASE') AND (p_reason IS NULL OR length(btrim(p_reason)) = 0) THEN
    RAISE EXCEPTION 'record_gate_decision: % requires non-empty reason', p_decision USING ERRCODE='22000';
  END IF;
  IF p_decision = 'ROUTE_TO_SIDE_PHASE' AND (p_side_phase IS NULL OR length(btrim(p_side_phase)) = 0) THEN
    RAISE EXCEPTION 'record_gate_decision: ROUTE_TO_SIDE_PHASE requires side_phase' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_ctx FROM public._resolve_phase_state_context(p_phase_state_id);
  IF v_ctx.run_id IS NULL THEN
    RAISE EXCEPTION 'record_gate_decision: phase_state_id % not found', p_phase_state_id USING ERRCODE='P0002';
  END IF;

  IF p_decision = 'ADVANCE' THEN
    v_action  := 'WORKFLOW_GATE_PASSED';
  ELSIF p_decision = 'HOLD' THEN
    v_action  := 'WORKFLOW_GATE_HOLD';
    UPDATE public.workflow_phase_states
       SET gate_decision = 'HOLD'::public.gate_decision_enum,
           updated_at    = clock_timestamp()
     WHERE id = p_phase_state_id;
    v_updated := true;
  ELSIF p_decision = 'ROUTE_TO_SIDE_PHASE' THEN
    v_action  := 'WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE';
    UPDATE public.workflow_phase_states
       SET gate_decision = 'ROUTE_TO_SIDE_PHASE'::public.gate_decision_enum,
           updated_at    = clock_timestamp()
     WHERE id = p_phase_state_id;
    v_updated := true;
  END IF;

  v_payload := jsonb_build_object(
    'phase_state_id', p_phase_state_id,
    'gate_name',      p_gate_name,
    'decision',       p_decision::text,
    'reason',         p_reason,
    'severity',       p_severity::text,
    'side_phase',     p_side_phase,
    'context',        p_context
  );

  v_audit := audit.emit_audit(
    p_actor_kind     => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
    p_action         => v_action,
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_ctx.run_id,
    p_business_id    => v_ctx.business_id,
    p_organization_id=> v_ctx.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_actor_system   => CASE WHEN p_actor_user_id IS NULL THEN 'workflow_engine' ELSE NULL END,
    p_reason         => format('gate %s → %s', p_gate_name, p_decision),
    p_after_state    => v_payload
  );

  RETURN jsonb_build_object(
    'audit_event_id',       v_audit.event_id,
    'phase_state_updated',  v_updated,
    'decision',             p_decision::text
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_gate_decision(uuid, text, public.gate_decision_enum, text, public.gate_hold_severity_enum, text, uuid, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_gate_decision(uuid, text, public.gate_decision_enum, text, public.gate_hold_severity_enum, text, uuid, jsonb) TO authenticated, service_role;

-- ---- RPC: record_gate_threw (failsafe) -------------------------------------
CREATE OR REPLACE FUNCTION public.record_gate_threw(
  p_phase_state_id   uuid,
  p_gate_name        text,
  p_exception_message text,
  p_exception_detail  jsonb DEFAULT NULL,
  p_actor_user_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_ctx   RECORD;
  v_audit audit.audit_events;
BEGIN
  IF p_phase_state_id IS NULL OR p_gate_name IS NULL OR p_exception_message IS NULL THEN
    RAISE EXCEPTION 'record_gate_threw: phase_state_id, gate_name, exception_message required' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_ctx FROM public._resolve_phase_state_context(p_phase_state_id);
  IF v_ctx.run_id IS NULL THEN
    RAISE EXCEPTION 'record_gate_threw: phase_state_id % not found', p_phase_state_id USING ERRCODE='P0002';
  END IF;

  UPDATE public.workflow_phase_states
     SET gate_decision = 'HOLD'::public.gate_decision_enum,
         updated_at    = clock_timestamp()
   WHERE id = p_phase_state_id;

  v_audit := audit.emit_audit(
    p_actor_kind     => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
    p_action         => 'WORKFLOW_GATE_THREW',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_ctx.run_id,
    p_business_id    => v_ctx.business_id,
    p_organization_id=> v_ctx.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_actor_system   => CASE WHEN p_actor_user_id IS NULL THEN 'workflow_engine' ELSE NULL END,
    p_reason         => format('gate %s threw: %s', p_gate_name, p_exception_message),
    p_after_state    => jsonb_build_object(
      'phase_state_id',    p_phase_state_id,
      'gate_name',         p_gate_name,
      'decision',          'HOLD',
      'severity',          'BLOCKING',
      'exception_message', p_exception_message,
      'exception_detail',  p_exception_detail
    )
  );

  RETURN jsonb_build_object(
    'audit_event_id',      v_audit.event_id,
    'phase_state_updated', true,
    'decision',            'HOLD'
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_gate_threw(uuid, text, text, jsonb, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_gate_threw(uuid, text, text, jsonb, uuid) TO authenticated, service_role;

COMMENT ON TABLE public.gate_registry IS
'B03·P05 startup-registered gate function declarations from Blocks 06-13. Gate bodies are code-side; DB layer catalogues them and links to phases via phase_gate_assignments.';

COMMENT ON FUNCTION public.record_gate_decision(uuid, text, public.gate_decision_enum, text, public.gate_hold_severity_enum, text, uuid, jsonb) IS
'B03·P05 gate-decision recorder. Decision ADVANCE → audit only (WORKFLOW_GATE_PASSED). Decision HOLD → sets phase_state.gate_decision=HOLD + WORKFLOW_GATE_HOLD audit. Decision ROUTE_TO_SIDE_PHASE → sets phase_state.gate_decision=ROUTE_TO_SIDE_PHASE + WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE audit. HOLD/ROUTE require non-empty reason; ROUTE requires non-null side_phase.';

COMMENT ON FUNCTION public.record_gate_threw(uuid, text, text, jsonb, uuid) IS
'B03·P05 gate-exception failsafe. Treated as HOLD-with-BLOCKING per spec. Sets phase_state.gate_decision=HOLD + emits WORKFLOW_GATE_THREW with exception_message captured. Gate exceptions NEVER crash the run.';
