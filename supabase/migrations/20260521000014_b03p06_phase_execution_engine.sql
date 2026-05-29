-- B03·P06 Phase Execution Engine
-- =============================================================================
-- DB-side atomic phase-boundary primitives. The actual advanceRun loop is
-- code-side (web/API). All boundary RPCs lock the workflow_runs row
-- (SELECT FOR UPDATE) to serialise concurrent driver invocations.
--
-- Five audit actions (text, no enum work):
--   WORKFLOW_PHASE_ENTERED, WORKFLOW_PHASE_COMPLETED, WORKFLOW_PHASE_HOLDING,
--   WORKFLOW_PHASE_ROUTED, WORKFLOW_TOOL_INVOKED
-- =============================================================================

CREATE OR REPLACE FUNCTION public.enter_phase(
  p_run_id    uuid,
  p_phase_name text
) RETURNS public.workflow_phase_states
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run         public.workflow_runs;
  v_def         public.workflow_phase_definitions;
  v_state       public.workflow_phase_states;
  v_max_order   integer;
BEGIN
  IF p_run_id IS NULL OR p_phase_name IS NULL OR length(btrim(p_phase_name))=0 THEN
    RAISE EXCEPTION 'enter_phase: run_id and phase_name required' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'enter_phase: run % not found', p_run_id USING ERRCODE='P0002'; END IF;
  IF public.is_terminal_state(v_run.status) THEN
    RAISE EXCEPTION 'enter_phase: run % is terminal (%)', p_run_id, v_run.status USING ERRCODE='P0001';
  END IF;

  SELECT * INTO v_def
    FROM public.workflow_phase_definitions
   WHERE workflow_type = v_run.workflow_type AND phase_name = p_phase_name
   LIMIT 1;

  SELECT * INTO v_state
    FROM public.workflow_phase_states
   WHERE workflow_run_id = p_run_id AND phase_name = p_phase_name
   ORDER BY phase_order DESC LIMIT 1;

  IF FOUND THEN
    IF v_state.status = 'RUNNING' THEN
      -- Idempotent re-entry per DoD
      RETURN v_state;
    ELSIF v_state.status = 'PENDING' THEN
      UPDATE public.workflow_phase_states
         SET status = 'RUNNING'::public.phase_state_status_enum,
             started_at = COALESCE(started_at, clock_timestamp()),
             updated_at = clock_timestamp()
       WHERE id = v_state.id
       RETURNING * INTO v_state;
    ELSE
      RAISE EXCEPTION 'enter_phase: phase % already in status % (cannot re-enter)', p_phase_name, v_state.status USING ERRCODE='P0001';
    END IF;
  ELSE
    SELECT COALESCE(MAX(phase_order), 0) INTO v_max_order
      FROM public.workflow_phase_states WHERE workflow_run_id = p_run_id;
    INSERT INTO public.workflow_phase_states (workflow_run_id, phase_name, phase_order, status, started_at)
    VALUES (
      p_run_id, p_phase_name,
      COALESCE(v_def.phase_order, v_max_order + 1),
      'RUNNING'::public.phase_state_status_enum,
      clock_timestamp()
    )
    RETURNING * INTO v_state;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_PHASE_ENTERED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('phase %s entered (RUNNING)', p_phase_name),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'phase_state_id', v_state.id,
      'phase_name', p_phase_name, 'phase_order', v_state.phase_order
    )
  );

  RETURN v_state;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.enter_phase(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.enter_phase(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.complete_phase(p_phase_state_id uuid)
RETURNS public.workflow_phase_states
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_state public.workflow_phase_states;
  v_run   public.workflow_runs;
BEGIN
  IF p_phase_state_id IS NULL THEN RAISE EXCEPTION 'complete_phase: phase_state_id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_state FROM public.workflow_phase_states WHERE id = p_phase_state_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'complete_phase: phase_state % not found', p_phase_state_id USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_state.workflow_run_id FOR UPDATE;
  IF v_state.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'complete_phase: phase % is in status % (not RUNNING)', v_state.phase_name, v_state.status USING ERRCODE='P0001';
  END IF;
  UPDATE public.workflow_phase_states
     SET status = 'COMPLETED'::public.phase_state_status_enum,
         completed_at = clock_timestamp(),
         updated_at   = clock_timestamp()
   WHERE id = p_phase_state_id
   RETURNING * INTO v_state;
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_PHASE_COMPLETED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('phase %s completed', v_state.phase_name),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'phase_state_id', v_state.id,
      'phase_name', v_state.phase_name, 'completed_at', v_state.completed_at
    )
  );
  RETURN v_state;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.complete_phase(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.complete_phase(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.hold_phase(
  p_phase_state_id uuid,
  p_reason         text,
  p_severity       public.gate_hold_severity_enum DEFAULT 'BLOCKING'
) RETURNS public.workflow_phase_states
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_state public.workflow_phase_states;
  v_run   public.workflow_runs;
BEGIN
  IF p_phase_state_id IS NULL OR p_reason IS NULL OR length(btrim(p_reason))=0 THEN
    RAISE EXCEPTION 'hold_phase: phase_state_id and reason required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_state FROM public.workflow_phase_states WHERE id = p_phase_state_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'hold_phase: phase_state % not found', p_phase_state_id USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_state.workflow_run_id FOR UPDATE;
  UPDATE public.workflow_phase_states
     SET status     = 'HOLDING'::public.phase_state_status_enum,
         updated_at = clock_timestamp()
   WHERE id = p_phase_state_id
   RETURNING * INTO v_state;
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_PHASE_HOLDING',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('phase %s holding: %s', v_state.phase_name, p_reason),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'phase_state_id', v_state.id,
      'phase_name', v_state.phase_name, 'reason', p_reason, 'severity', p_severity::text
    )
  );
  RETURN v_state;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.hold_phase(uuid, text, public.gate_hold_severity_enum) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.hold_phase(uuid, text, public.gate_hold_severity_enum) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.route_phase(
  p_phase_state_id  uuid,
  p_side_phase_name text,
  p_reason          text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_orig       public.workflow_phase_states;
  v_side       public.workflow_phase_states;
  v_run        public.workflow_runs;
  v_max_order  integer;
BEGIN
  IF p_phase_state_id IS NULL OR p_side_phase_name IS NULL OR p_reason IS NULL OR length(btrim(p_side_phase_name))=0 OR length(btrim(p_reason))=0 THEN
    RAISE EXCEPTION 'route_phase: phase_state_id, side_phase_name, reason required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_orig FROM public.workflow_phase_states WHERE id = p_phase_state_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'route_phase: phase_state % not found', p_phase_state_id USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_orig.workflow_run_id FOR UPDATE;
  UPDATE public.workflow_phase_states
     SET status         = 'HOLDING'::public.phase_state_status_enum,
         gate_decision  = 'ROUTE_TO_SIDE_PHASE'::public.gate_decision_enum,
         updated_at     = clock_timestamp()
   WHERE id = p_phase_state_id
   RETURNING * INTO v_orig;
  SELECT COALESCE(MAX(phase_order), 0) INTO v_max_order
    FROM public.workflow_phase_states WHERE workflow_run_id = v_run.id;
  INSERT INTO public.workflow_phase_states (workflow_run_id, phase_name, phase_order, status)
  VALUES (v_run.id, p_side_phase_name, v_max_order + 1, 'PENDING'::public.phase_state_status_enum)
  RETURNING * INTO v_side;
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_PHASE_ROUTED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('phase %s routed to side phase %s: %s', v_orig.phase_name, p_side_phase_name, p_reason),
    p_after_state    => jsonb_build_object(
      'run_id',                v_run.id,
      'original_phase_state',  v_orig.id,
      'original_phase_name',   v_orig.phase_name,
      'side_phase_state',      v_side.id,
      'side_phase_name',       p_side_phase_name,
      'reason',                p_reason
    )
  );
  RETURN jsonb_build_object(
    'original_phase_state', to_jsonb(v_orig),
    'side_phase_state',     to_jsonb(v_side)
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.route_phase(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.route_phase(uuid, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.record_tool_invocation(
  p_phase_state_id     uuid,
  p_tool_name          text,
  p_status             public.tool_invocation_status_enum,
  p_attempt_number     integer DEFAULT 1,
  p_input_hash         text DEFAULT NULL,
  p_output_hash        text DEFAULT NULL,
  p_dedup_key          text DEFAULT NULL,
  p_external_request_id text DEFAULT NULL,
  p_error_summary      text DEFAULT NULL,
  p_started_at         timestamptz DEFAULT NULL,
  p_completed_at       timestamptz DEFAULT NULL
) RETURNS public.tool_invocations
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_phase public.workflow_phase_states;
  v_run   public.workflow_runs;
  v_inv   public.tool_invocations;
BEGIN
  IF p_phase_state_id IS NULL OR p_tool_name IS NULL OR p_status IS NULL THEN
    RAISE EXCEPTION 'record_tool_invocation: phase_state_id, tool_name, status required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_phase FROM public.workflow_phase_states WHERE id = p_phase_state_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_tool_invocation: phase_state % not found', p_phase_state_id USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_phase.workflow_run_id;
  INSERT INTO public.tool_invocations (
    workflow_run_id, phase_state_id, tool_name, attempt_number,
    input_hash, output_hash, status, dedup_key, external_request_id,
    started_at, completed_at, error_summary
  ) VALUES (
    v_phase.workflow_run_id, p_phase_state_id, p_tool_name, COALESCE(p_attempt_number, 1),
    p_input_hash, p_output_hash, p_status, p_dedup_key, p_external_request_id,
    p_started_at, p_completed_at, p_error_summary
  )
  RETURNING * INTO v_inv;
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_TOOL_INVOKED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('tool %s invoked (attempt %s, status=%s)', p_tool_name, COALESCE(p_attempt_number,1), p_status),
    p_after_state    => jsonb_build_object(
      'run_id',           v_run.id,
      'phase_state_id',   p_phase_state_id,
      'phase_name',       v_phase.phase_name,
      'tool_invocation_id', v_inv.id,
      'tool_name',        p_tool_name,
      'attempt_number',   COALESCE(p_attempt_number, 1),
      'status',           p_status::text,
      'input_hash',       p_input_hash,
      'output_hash',      p_output_hash,
      'dedup_key',        p_dedup_key
    )
  );
  RETURN v_inv;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_tool_invocation(uuid, text, public.tool_invocation_status_enum, integer, text, text, text, text, text, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_tool_invocation(uuid, text, public.tool_invocation_status_enum, integer, text, text, text, text, text, timestamptz, timestamptz) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.pick_next_phase(p_run_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_run        public.workflow_runs;
  v_next_phase text;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT phase_name INTO v_next_phase
    FROM public.workflow_phase_states
   WHERE workflow_run_id = p_run_id AND status = 'PENDING'
   ORDER BY phase_order
   LIMIT 1;
  IF FOUND THEN RETURN v_next_phase; END IF;

  SELECT wpd.phase_name INTO v_next_phase
    FROM public.workflow_phase_definitions wpd
   WHERE wpd.workflow_type = v_run.workflow_type
     AND NOT EXISTS (
       SELECT 1 FROM public.workflow_phase_states wps
        WHERE wps.workflow_run_id = p_run_id
          AND wps.phase_name = wpd.phase_name
     )
   ORDER BY wpd.phase_order
   LIMIT 1;
  RETURN v_next_phase;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.pick_next_phase(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pick_next_phase(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_run_progress(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_run             public.workflow_runs;
  v_total           integer;
  v_completed       integer;
  v_current_phase   text;
  v_current_status  public.phase_state_status_enum;
  v_last_activity   timestamptz;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'NOT_FOUND', 'run_id', p_run_id);
  END IF;

  SELECT count(*) INTO v_total
    FROM public.workflow_phase_definitions
   WHERE workflow_type = v_run.workflow_type;

  SELECT count(*) INTO v_completed
    FROM public.workflow_phase_states
   WHERE workflow_run_id = p_run_id AND status = 'COMPLETED';

  SELECT phase_name, status INTO v_current_phase, v_current_status
    FROM public.workflow_phase_states
   WHERE workflow_run_id = p_run_id AND status IN ('RUNNING','HOLDING','PENDING')
   ORDER BY phase_order DESC
   LIMIT 1;

  SELECT max(updated_at) INTO v_last_activity
    FROM public.workflow_phase_states
   WHERE workflow_run_id = p_run_id;

  RETURN jsonb_build_object(
    'run_id',                p_run_id,
    'run_status',            v_run.status::text,
    'workflow_type',         v_run.workflow_type::text,
    'current_phase',         v_current_phase,
    'current_phase_status',  v_current_status::text,
    'phases_completed',      COALESCE(v_completed, 0),
    'total_phases',          COALESCE(v_total, 0),
    'blocking_issues_count', 0,
    'started_at',            v_run.started_at,
    'last_activity_at',      v_last_activity,
    'finalized_at',          v_run.finalized_at,
    'estimated_completion',  NULL
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.get_run_progress(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_run_progress(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.enter_phase(uuid, text) IS
'B03·P06 atomic phase entry. Locks workflow_runs FOR UPDATE. Idempotent: re-entry on RUNNING phase returns same row without re-emitting audit. PENDING → RUNNING transitions emit WORKFLOW_PHASE_ENTERED.';

COMMENT ON FUNCTION public.complete_phase(uuid) IS
'B03·P06 atomic phase completion. Requires status=RUNNING. Sets COMPLETED+completed_at and emits WORKFLOW_PHASE_COMPLETED.';

COMMENT ON FUNCTION public.route_phase(uuid, text, text) IS
'B03·P06 side-phase routing. Original phase → HOLDING + gate_decision=ROUTE_TO_SIDE_PHASE. New side phase_state row appended with PENDING status. Emits WORKFLOW_PHASE_ROUTED with both phase_state ids in payload.';

COMMENT ON FUNCTION public.pick_next_phase(uuid) IS
'B03·P06 helper for the code-side driver. Returns next phase_name to enter: first PENDING phase_state (e.g., side phases) else next un-entered phase from workflow_phase_definitions by phase_order. NULL when run is complete.';

COMMENT ON FUNCTION public.get_run_progress(uuid) IS
'B03·P06 read-side progress API for UI. total_phases counts static workflow_phase_definitions for the workflow_type (MVP). blocking_issues_count and estimated_completion are placeholders until B14 and the heuristic sub-doc ship.';
