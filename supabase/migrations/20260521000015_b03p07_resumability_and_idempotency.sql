-- B03·P07 Resumability & Idempotency
-- =============================================================================
-- DB primitives for the dedup/resume contract. The actual crash-recovery
-- driver loop and external-API replay logic live code-side.
--
-- Canonical two-phase tool invocation pattern (from spec):
--   begin_tool_invocation → external call → complete_tool_invocation
-- Crash between the two leaves a PENDING row that the resume path detects
-- via lookup_tool_dedup.
--
-- Three new audit actions (text, no enum work):
--   WORKFLOW_RESUMED_AFTER_RESTART, WORKFLOW_TOOL_DEDUP_HIT,
--   WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID
-- =============================================================================

CREATE UNIQUE INDEX uq_ti_success_dedup
  ON public.tool_invocations (workflow_run_id, tool_name, dedup_key)
  WHERE status = 'SUCCESS' AND dedup_key IS NOT NULL;

CREATE INDEX idx_ti_pending_dedup
  ON public.tool_invocations (workflow_run_id, tool_name, dedup_key)
  WHERE status IN ('PENDING','RETRY_PENDING') AND dedup_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.lookup_tool_dedup(
  p_workflow_run_id uuid,
  p_tool_name       text,
  p_dedup_key       text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_prior public.tool_invocations;
BEGIN
  IF p_workflow_run_id IS NULL OR p_tool_name IS NULL OR p_dedup_key IS NULL THEN
    RAISE EXCEPTION 'lookup_tool_dedup: run_id, tool_name, dedup_key required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_prior
    FROM public.tool_invocations
   WHERE workflow_run_id = p_workflow_run_id
     AND tool_name       = p_tool_name
     AND dedup_key       = p_dedup_key
   ORDER BY
     CASE status::text
       WHEN 'SUCCESS' THEN 1
       WHEN 'PENDING' THEN 2
       WHEN 'RETRY_PENDING' THEN 3
       WHEN 'FAILED' THEN 4
       ELSE 5
     END,
     created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('hit', false, 'prior_invocation', NULL);
  END IF;

  RETURN jsonb_build_object(
    'hit', v_prior.status = 'SUCCESS',
    'prior_invocation', jsonb_build_object(
      'id',                  v_prior.id,
      'status',              v_prior.status::text,
      'output_hash',         v_prior.output_hash,
      'input_hash',          v_prior.input_hash,
      'external_request_id', v_prior.external_request_id,
      'attempt_number',      v_prior.attempt_number,
      'started_at',          v_prior.started_at,
      'completed_at',        v_prior.completed_at,
      'error_summary',       v_prior.error_summary
    )
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.lookup_tool_dedup(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.lookup_tool_dedup(uuid, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.begin_tool_invocation(
  p_phase_state_id     uuid,
  p_tool_name          text,
  p_input_hash         text,
  p_dedup_key          text,
  p_external_request_id text DEFAULT NULL,
  p_attempt_number     integer DEFAULT 1
) RETURNS public.tool_invocations
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_phase public.workflow_phase_states;
  v_inv   public.tool_invocations;
BEGIN
  IF p_phase_state_id IS NULL OR p_tool_name IS NULL THEN
    RAISE EXCEPTION 'begin_tool_invocation: phase_state_id and tool_name required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_phase FROM public.workflow_phase_states WHERE id = p_phase_state_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'begin_tool_invocation: phase_state % not found', p_phase_state_id USING ERRCODE='P0002'; END IF;
  INSERT INTO public.tool_invocations (
    workflow_run_id, phase_state_id, tool_name, attempt_number,
    input_hash, status, dedup_key, external_request_id, started_at
  ) VALUES (
    v_phase.workflow_run_id, p_phase_state_id, p_tool_name, COALESCE(p_attempt_number, 1),
    p_input_hash, 'PENDING'::public.tool_invocation_status_enum, p_dedup_key, p_external_request_id, clock_timestamp()
  )
  RETURNING * INTO v_inv;
  RETURN v_inv;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.begin_tool_invocation(uuid, text, text, text, text, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.begin_tool_invocation(uuid, text, text, text, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.complete_tool_invocation(
  p_tool_invocation_id  uuid,
  p_status              public.tool_invocation_status_enum,
  p_output_hash         text DEFAULT NULL,
  p_error_summary       text DEFAULT NULL,
  p_external_request_id text DEFAULT NULL
) RETURNS public.tool_invocations
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_inv   public.tool_invocations;
  v_run   public.workflow_runs;
  v_phase public.workflow_phase_states;
BEGIN
  IF p_tool_invocation_id IS NULL OR p_status IS NULL THEN
    RAISE EXCEPTION 'complete_tool_invocation: invocation_id and status required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_inv FROM public.tool_invocations WHERE id = p_tool_invocation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'complete_tool_invocation: invocation % not found', p_tool_invocation_id USING ERRCODE='P0002'; END IF;
  IF v_inv.status NOT IN ('PENDING','RETRY_PENDING') THEN
    RAISE EXCEPTION 'complete_tool_invocation: invocation % is in terminal status % (cannot complete)', p_tool_invocation_id, v_inv.status USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_phase FROM public.workflow_phase_states WHERE id = v_inv.phase_state_id;
  SELECT * INTO v_run   FROM public.workflow_runs        WHERE id = v_inv.workflow_run_id;
  UPDATE public.tool_invocations
     SET status              = p_status,
         output_hash         = COALESCE(p_output_hash, output_hash),
         error_summary       = COALESCE(p_error_summary, error_summary),
         external_request_id = COALESCE(p_external_request_id, external_request_id),
         completed_at        = clock_timestamp(),
         updated_at          = clock_timestamp()
   WHERE id = p_tool_invocation_id
   RETURNING * INTO v_inv;
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_TOOL_INVOKED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('tool %s completed (status=%s, attempt=%s)', v_inv.tool_name, p_status, v_inv.attempt_number),
    p_after_state    => jsonb_build_object(
      'run_id',              v_run.id,
      'phase_state_id',      v_inv.phase_state_id,
      'phase_name',          v_phase.phase_name,
      'tool_invocation_id',  v_inv.id,
      'tool_name',           v_inv.tool_name,
      'attempt_number',      v_inv.attempt_number,
      'status',              p_status::text,
      'input_hash',          v_inv.input_hash,
      'output_hash',         v_inv.output_hash,
      'dedup_key',           v_inv.dedup_key,
      'external_request_id', v_inv.external_request_id
    )
  );
  RETURN v_inv;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.complete_tool_invocation(uuid, public.tool_invocation_status_enum, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.complete_tool_invocation(uuid, public.tool_invocation_status_enum, text, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.record_tool_dedup_hit(
  p_phase_state_id     uuid,
  p_tool_name          text,
  p_dedup_key          text,
  p_prior_invocation_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_phase public.workflow_phase_states;
  v_run   public.workflow_runs;
  v_prior public.tool_invocations;
  v_audit audit.audit_events;
BEGIN
  IF p_phase_state_id IS NULL OR p_tool_name IS NULL OR p_dedup_key IS NULL OR p_prior_invocation_id IS NULL THEN
    RAISE EXCEPTION 'record_tool_dedup_hit: all params required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_phase FROM public.workflow_phase_states WHERE id = p_phase_state_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_tool_dedup_hit: phase_state % not found', p_phase_state_id USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_run   FROM public.workflow_runs WHERE id = v_phase.workflow_run_id;
  SELECT * INTO v_prior FROM public.tool_invocations WHERE id = p_prior_invocation_id;
  v_audit := audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_TOOL_DEDUP_HIT',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('tool %s dedup hit on key %s (cached from invocation %s)', p_tool_name, p_dedup_key, p_prior_invocation_id),
    p_after_state    => jsonb_build_object(
      'run_id',                v_run.id,
      'phase_state_id',        p_phase_state_id,
      'phase_name',            v_phase.phase_name,
      'tool_name',             p_tool_name,
      'dedup_key',             p_dedup_key,
      'prior_invocation_id',   p_prior_invocation_id,
      'prior_output_hash',     v_prior.output_hash,
      'prior_attempt_number',  v_prior.attempt_number
    )
  );
  RETURN jsonb_build_object('audit_event_id', v_audit.event_id);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_tool_dedup_hit(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_tool_dedup_hit(uuid, text, text, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.record_tool_replay_via_external_request_id(
  p_phase_state_id      uuid,
  p_tool_name           text,
  p_external_request_id text,
  p_prior_invocation_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_phase public.workflow_phase_states;
  v_run   public.workflow_runs;
  v_audit audit.audit_events;
BEGIN
  IF p_phase_state_id IS NULL OR p_tool_name IS NULL OR p_external_request_id IS NULL THEN
    RAISE EXCEPTION 'record_tool_replay_via_external_request_id: phase_state_id, tool_name, external_request_id required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_phase FROM public.workflow_phase_states WHERE id = p_phase_state_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_tool_replay_via_external_request_id: phase_state % not found', p_phase_state_id USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_phase.workflow_run_id;
  v_audit := audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('tool %s replay via external_request_id %s', p_tool_name, p_external_request_id),
    p_after_state    => jsonb_build_object(
      'run_id',               v_run.id,
      'phase_state_id',       p_phase_state_id,
      'phase_name',           v_phase.phase_name,
      'tool_name',            p_tool_name,
      'external_request_id',  p_external_request_id,
      'prior_invocation_id',  p_prior_invocation_id
    )
  );
  RETURN jsonb_build_object('audit_event_id', v_audit.event_id);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_tool_replay_via_external_request_id(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_tool_replay_via_external_request_id(uuid, text, text, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.enumerate_resumable_runs()
RETURNS SETOF public.workflow_runs
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT * FROM public.workflow_runs
   WHERE status IN ('RUNNING'::public.workflow_run_status_enum, 'FINALIZING'::public.workflow_run_status_enum)
   ORDER BY started_at NULLS LAST, created_at;
$fn$;
REVOKE EXECUTE ON FUNCTION public.enumerate_resumable_runs() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.enumerate_resumable_runs() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.record_run_resumed_after_restart(
  p_run_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run   public.workflow_runs;
  v_audit audit.audit_events;
BEGIN
  IF p_run_id IS NULL THEN RAISE EXCEPTION 'record_run_resumed_after_restart: run_id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_run_resumed_after_restart: run % not found', p_run_id USING ERRCODE='P0002'; END IF;
  IF public.is_terminal_state(v_run.status) THEN
    RAISE EXCEPTION 'record_run_resumed_after_restart: run % is terminal (%)', p_run_id, v_run.status USING ERRCODE='P0001';
  END IF;
  v_audit := audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_RESUMED_AFTER_RESTART',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('run %s resumed after restart: %s', p_run_id, COALESCE(p_reason, 'process startup')),
    p_after_state    => jsonb_build_object(
      'run_id',  v_run.id,
      'status',  v_run.status::text,
      'reason',  COALESCE(p_reason, 'process startup')
    )
  );
  RETURN jsonb_build_object('audit_event_id', v_audit.event_id);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_run_resumed_after_restart(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_run_resumed_after_restart(uuid, text) TO service_role;

COMMENT ON FUNCTION public.lookup_tool_dedup(uuid, text, text) IS
'B03·P07 dedup lookup. Returns {hit:bool, prior_invocation:obj|null}. hit=true only for SUCCESS rows. prior_invocation surfaces PENDING/RETRY_PENDING rows too so the engine can decide resume vs new attempt.';

COMMENT ON FUNCTION public.begin_tool_invocation(uuid, text, text, text, text, integer) IS
'B03·P07 two-phase tool invocation (start). INSERTs PENDING row with dedup_key + external_request_id BEFORE the external call. Does NOT emit WORKFLOW_TOOL_INVOKED (that comes from complete_tool_invocation).';

COMMENT ON FUNCTION public.complete_tool_invocation(uuid, public.tool_invocation_status_enum, text, text, text) IS
'B03·P07 two-phase tool invocation (finish). UPDATEs PENDING/RETRY_PENDING row to terminal status + emits WORKFLOW_TOOL_INVOKED. Rejects if target is already in terminal status.';

COMMENT ON FUNCTION public.record_tool_dedup_hit(uuid, text, text, uuid) IS
'B03·P07 dedup-hit audit. Per spec, this REPLACES WORKFLOW_TOOL_INVOKED — no new tool_invocations row, just the audit pointing at the cached prior invocation.';

COMMENT ON FUNCTION public.enumerate_resumable_runs() IS
'B03·P07 crash-recovery enumeration. Returns runs in RUNNING or FINALIZING. Engine startup iterates this and dispatches each to advanceRun.';

COMMENT ON FUNCTION public.record_run_resumed_after_restart(uuid, text) IS
'B03·P07 resume marker. Emits WORKFLOW_RESUMED_AFTER_RESTART without state-machine transition (run stays in RUNNING/FINALIZING). Engine calls before resuming.';
