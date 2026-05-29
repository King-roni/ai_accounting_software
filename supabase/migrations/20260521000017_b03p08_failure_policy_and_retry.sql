-- B03·P08 Failure Policy & Retry
-- =============================================================================
-- Three-class error handling (TRANSIENT / FATAL / SCHEMA), bounded retry with
-- exponential backoff for transient failures, two-level state convergence on
-- terminal failure (phase HOLDING + run REVIEW_HOLD), user-action paths
-- (Retry, Skip). Review-issue creation is a placeholder audit event for B14.
--
-- transition_run extended to support SYSTEM actor (NULL user) for auto-
-- transitions like review_hold_auto. Privileged transitions reject SYSTEM
-- with SYSTEM_FORBIDDEN_FOR_PRIVILEGED_TRANSITION.
--
-- Audit actions added (text, no enum work):
--   WORKFLOW_TOOL_RETRY_SCHEDULED, WORKFLOW_TOOL_FAILED_AFTER_RETRIES,
--   WORKFLOW_TOOL_FATAL_ERROR, WORKFLOW_TOOL_SCHEMA_ERROR,
--   WORKFLOW_TOOL_SKIPPED_BY_USER, WORKFLOW_TOOL_RETRY_REQUESTED,
--   WORKFLOW_REVIEW_ISSUE_REQUESTED
-- =============================================================================

CREATE TYPE public.tool_error_class_enum AS ENUM ('TRANSIENT','FATAL','SCHEMA');

ALTER TABLE public.tool_registry
  ADD COLUMN retry_max_attempts    integer NOT NULL DEFAULT 3,
  ADD COLUMN retry_backoff_base_ms integer NOT NULL DEFAULT 2000,
  ADD COLUMN retry_backoff_max_ms  integer NOT NULL DEFAULT 60000,
  ADD CONSTRAINT tr_retry_max_nonneg   CHECK (retry_max_attempts >= 0),
  ADD CONSTRAINT tr_retry_base_pos     CHECK (retry_backoff_base_ms > 0),
  ADD CONSTRAINT tr_retry_max_ge_base  CHECK (retry_backoff_max_ms >= retry_backoff_base_ms);

ALTER TABLE public.tool_invocations
  ADD COLUMN next_retry_at timestamptz,
  ADD COLUMN error_class   public.tool_error_class_enum;

CREATE INDEX idx_ti_retry_pending_due
  ON public.tool_invocations (next_retry_at)
  WHERE status = 'RETRY_PENDING';

CREATE OR REPLACE FUNCTION public.compute_next_retry_at(
  p_attempt integer,
  p_base_ms integer,
  p_max_ms  integer
) RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_temp
AS $fn$
DECLARE v_ms double precision;
BEGIN
  IF p_attempt < 1 THEN p_attempt := 1; END IF;
  v_ms := p_base_ms * power(2::double precision, p_attempt - 1);
  IF v_ms > p_max_ms THEN v_ms := p_max_ms; END IF;
  RETURN clock_timestamp() + (v_ms || ' milliseconds')::interval;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.compute_next_retry_at(integer, integer, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.compute_next_retry_at(integer, integer, integer) TO authenticated, service_role;

-- ---- transition_run: SYSTEM actor support (NULL user = SYSTEM context) -----
CREATE OR REPLACE FUNCTION public.transition_run(
  p_run_id            uuid,
  p_target_state      public.workflow_run_status_enum,
  p_actor_user_id     uuid,
  p_reason            text DEFAULT NULL,
  p_step_up_verified  boolean DEFAULT false,
  p_context           jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run         public.workflow_runs;
  v_trans       public.workflow_run_state_transitions;
  v_perm        jsonb;
  v_perm_dec    text;
  v_audit       audit.audit_events;
  v_set_clauses text := '';
  v_sql         text;
  v_reject_code text;
  v_reject_msg  text;
  v_is_system   boolean;
BEGIN
  IF p_run_id IS NULL OR p_target_state IS NULL THEN
    RAISE EXCEPTION 'transition_run: run_id and target_state are required' USING ERRCODE='22000';
  END IF;
  v_is_system := (p_actor_user_id IS NULL);

  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'transition_run: run_id % not found', p_run_id USING ERRCODE='P0002'; END IF;

  IF public.is_terminal_state(v_run.status) THEN
    v_reject_code := 'TERMINAL_STATE';
    v_reject_msg  := format('run is in terminal state %s; no transitions permitted', v_run.status);
  ELSE
    SELECT * INTO v_trans
      FROM public.workflow_run_state_transitions
     WHERE to_state = p_target_state
       AND ((NOT from_state_is_wildcard AND from_state = v_run.status) OR from_state_is_wildcard)
     ORDER BY from_state_is_wildcard ASC LIMIT 1;
    IF NOT FOUND THEN
      v_reject_code := 'ILLEGAL_TRANSITION';
      v_reject_msg  := format('no transition defined: %s → %s', v_run.status, p_target_state);
    END IF;
  END IF;

  IF v_reject_code IS NULL AND v_is_system AND v_trans.requires_permission_surface IS NOT NULL THEN
    v_reject_code := 'SYSTEM_FORBIDDEN_FOR_PRIVILEGED_TRANSITION';
    v_reject_msg  := format('SYSTEM actor cannot perform privileged transition %s (requires %s:%s)',
                            v_trans.transition_name, v_trans.requires_permission_surface, v_trans.requires_permission_action);
  END IF;

  IF v_reject_code IS NULL AND v_trans.requires_step_up AND NOT COALESCE(p_step_up_verified, false) THEN
    v_reject_code := 'STEP_UP_REQUIRED';
    v_reject_msg  := format('transition %s requires step-up MFA verification', v_trans.transition_name);
  END IF;

  IF v_reject_code IS NULL AND v_trans.requires_reason AND (p_reason IS NULL OR length(btrim(p_reason)) = 0) THEN
    v_reject_code := 'REASON_REQUIRED';
    v_reject_msg  := format('transition %s requires a non-empty reason', v_trans.transition_name);
  END IF;

  IF v_reject_code IS NULL AND NOT v_is_system AND v_trans.requires_permission_surface IS NOT NULL THEN
    v_perm := public.can_perform(
      p_actor_user_id   => p_actor_user_id,
      p_surface         => v_trans.requires_permission_surface,
      p_action          => v_trans.requires_permission_action,
      p_resource        => jsonb_build_object('run_id', v_run.id, 'workflow_type', v_run.workflow_type),
      p_business_id     => v_run.business_id,
      p_organization_id => v_run.organization_id
    );
    v_perm_dec := v_perm->>'decision';
    IF v_perm_dec = 'DENY' THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('actor lacks permission %s:%s (reason=%s)', v_trans.requires_permission_surface, v_trans.requires_permission_action, v_perm->>'reason_code');
    ELSIF v_perm_dec = 'STEP_UP' AND NOT COALESCE(p_step_up_verified, false) THEN
      v_reject_code := 'STEP_UP_REQUIRED';
      v_reject_msg  := format('permission %s:%s requires step-up MFA', v_trans.requires_permission_surface, v_trans.requires_permission_action);
    ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind     => CASE WHEN v_is_system THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action         => 'WORKFLOW_RUN_STATE_CHANGE_REJECTED',
      p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id     => v_run.id,
      p_business_id    => v_run.business_id,
      p_organization_id=> v_run.organization_id,
      p_actor_user_id  => CASE WHEN v_is_system THEN NULL ELSE p_actor_user_id END,
      p_actor_system   => CASE WHEN v_is_system THEN 'workflow_engine' ELSE NULL END,
      p_reason         => v_reject_msg,
      p_after_state    => jsonb_build_object(
        'run_id', v_run.id, 'from_state', v_run.status::text,
        'attempted_to', p_target_state::text, 'rejection_code', v_reject_code, 'context', p_context
      )
    );
    RETURN jsonb_build_object(
      'ok', false, 'run_id', v_run.id, 'from_state', v_run.status::text,
      'to_state', v_run.status::text, 'reason', v_reject_code, 'message', v_reject_msg
    );
  END IF;

  v_set_clauses := format('status = %L::public.workflow_run_status_enum', p_target_state);
  IF v_trans.side_effect_columns ? 'started_at'    THEN v_set_clauses := v_set_clauses || ', started_at = clock_timestamp()'; END IF;
  IF v_trans.side_effect_columns ? 'finalized_at'  THEN v_set_clauses := v_set_clauses || ', finalized_at = clock_timestamp()'; END IF;
  IF v_trans.side_effect_columns ? 'finalized_by'  THEN v_set_clauses := v_set_clauses || format(', finalized_by = %L::uuid', p_actor_user_id); END IF;
  IF v_trans.side_effect_columns ? 'aborted_at'    THEN v_set_clauses := v_set_clauses || ', aborted_at = clock_timestamp()'; END IF;
  IF v_trans.side_effect_columns ? 'aborted_by'    THEN v_set_clauses := v_set_clauses || format(', aborted_by = %L::uuid', p_actor_user_id); END IF;
  IF v_trans.side_effect_columns ? 'abort_reason'  THEN v_set_clauses := v_set_clauses || format(', abort_reason = %L', p_reason); END IF;
  IF v_trans.side_effect_columns ? 'completed_at'  THEN v_set_clauses := v_set_clauses || ', completed_at = clock_timestamp()'; END IF;
  v_set_clauses := v_set_clauses || ', updated_at = clock_timestamp()';

  PERFORM set_config('app.transition_run_active', 'true', true);
  v_sql := format('UPDATE public.workflow_runs SET %s WHERE id = %L', v_set_clauses, p_run_id);
  EXECUTE v_sql;
  PERFORM set_config('app.transition_run_active', 'false', true);

  v_audit := audit.emit_audit(
    p_actor_kind     => CASE WHEN v_is_system THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
    p_action         => 'WORKFLOW_RUN_STATE_CHANGED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => CASE WHEN v_is_system THEN NULL ELSE p_actor_user_id END,
    p_actor_system   => CASE WHEN v_is_system THEN 'workflow_engine' ELSE NULL END,
    p_reason         => format('transition %s: %s → %s', v_trans.transition_name, v_run.status, p_target_state),
    p_before_state   => jsonb_build_object('status', v_run.status::text),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'transition_name', v_trans.transition_name,
      'from_state', v_run.status::text, 'to_state', p_target_state::text,
      'reason', p_reason, 'context', p_context
    )
  );

  IF v_trans.transition_name = 'pause' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => CASE WHEN v_is_system THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action => 'WORKFLOW_RUN_PAUSED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => CASE WHEN v_is_system THEN NULL ELSE p_actor_user_id END,
      p_actor_system  => CASE WHEN v_is_system THEN 'workflow_engine' ELSE NULL END,
      p_reason => format('run %s paused', v_run.id),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text)
    );
  ELSIF v_trans.transition_name = 'resume' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => CASE WHEN v_is_system THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action => 'WORKFLOW_RUN_RESUMED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => CASE WHEN v_is_system THEN NULL ELSE p_actor_user_id END,
      p_actor_system  => CASE WHEN v_is_system THEN 'workflow_engine' ELSE NULL END,
      p_reason => format('run %s resumed', v_run.id),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text)
    );
  ELSIF v_trans.transition_name = 'abort' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => CASE WHEN v_is_system THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action => 'WORKFLOW_RUN_ABORTED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => CASE WHEN v_is_system THEN NULL ELSE p_actor_user_id END,
      p_actor_system  => CASE WHEN v_is_system THEN 'workflow_engine' ELSE NULL END,
      p_reason => format('run %s aborted: %s', v_run.id, p_reason),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text, 'abort_reason', p_reason)
    );
  ELSIF v_trans.transition_name = 'finalize_complete' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => CASE WHEN v_is_system THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action => 'WORKFLOW_RUN_FINALIZED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => CASE WHEN v_is_system THEN NULL ELSE p_actor_user_id END,
      p_actor_system  => CASE WHEN v_is_system THEN 'workflow_engine' ELSE NULL END,
      p_reason => format('run %s finalized', v_run.id),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'run_id', v_run.id, 'from_state', v_run.status::text,
    'to_state', p_target_state::text, 'transition_name', v_trans.transition_name, 'audit_event_id', v_audit.event_id
  );
END;
$fn$;

-- ---- fail_tool_invocation: failure chokepoint ------------------------------
CREATE OR REPLACE FUNCTION public.fail_tool_invocation(
  p_invocation_id   uuid,
  p_error_class     public.tool_error_class_enum,
  p_error_summary   text,
  p_error_detail    jsonb DEFAULT '{}'::jsonb,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_inv          public.tool_invocations;
  v_tool         public.tool_registry;
  v_phase        public.workflow_phase_states;
  v_run          public.workflow_runs;
  v_will_retry   boolean := false;
  v_next_at      timestamptz;
  v_action_event text;
  v_severity     text;
  v_transition_result jsonb;
BEGIN
  IF p_invocation_id IS NULL OR p_error_class IS NULL OR p_error_summary IS NULL THEN
    RAISE EXCEPTION 'fail_tool_invocation: invocation_id, error_class, error_summary required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_inv FROM public.tool_invocations WHERE id = p_invocation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fail_tool_invocation: invocation % not found', p_invocation_id USING ERRCODE='P0002'; END IF;
  IF v_inv.status NOT IN ('PENDING','RETRY_PENDING') THEN
    RAISE EXCEPTION 'fail_tool_invocation: invocation % is in status % (not failable)', p_invocation_id, v_inv.status USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_tool  FROM public.tool_registry WHERE tool_name = v_inv.tool_name;
  SELECT * INTO v_phase FROM public.workflow_phase_states WHERE id = v_inv.phase_state_id;
  SELECT * INTO v_run   FROM public.workflow_runs WHERE id = v_inv.workflow_run_id;

  v_will_retry := (
    p_error_class = 'TRANSIENT'
    AND v_inv.attempt_number < v_tool.retry_max_attempts
    AND v_tool.failure_semantics <> 'IDEMPOTENT_AT_MOST_ONCE'
  );

  IF v_will_retry THEN
    v_next_at := public.compute_next_retry_at(v_inv.attempt_number, v_tool.retry_backoff_base_ms, v_tool.retry_backoff_max_ms);
    UPDATE public.tool_invocations
       SET status        = 'RETRY_PENDING'::public.tool_invocation_status_enum,
           error_class   = p_error_class,
           error_summary = p_error_summary,
           next_retry_at = v_next_at,
           updated_at    = clock_timestamp()
     WHERE id = p_invocation_id
     RETURNING * INTO v_inv;
    PERFORM audit.emit_audit(
      p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
      p_action         => 'WORKFLOW_TOOL_RETRY_SCHEDULED',
      p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id     => v_run.id,
      p_business_id    => v_run.business_id,
      p_organization_id=> v_run.organization_id,
      p_actor_system   => 'workflow_engine',
      p_reason         => format('tool %s retry scheduled (attempt %s/%s, transient: %s)',
                                 v_inv.tool_name, v_inv.attempt_number, v_tool.retry_max_attempts, p_error_summary),
      p_after_state    => jsonb_build_object(
        'run_id', v_run.id, 'phase_state_id', v_inv.phase_state_id,
        'tool_invocation_id', v_inv.id, 'tool_name', v_inv.tool_name,
        'attempt_number', v_inv.attempt_number, 'max_attempts', v_tool.retry_max_attempts,
        'next_retry_at', v_next_at, 'error_class', p_error_class::text,
        'error_summary', p_error_summary, 'error_detail', p_error_detail
      )
    );
    RETURN jsonb_build_object(
      'ok', true, 'will_retry', true, 'next_retry_at', v_next_at,
      'attempts_remaining', v_tool.retry_max_attempts - v_inv.attempt_number,
      'run_held', false, 'review_issue_requested', false, 'severity', NULL
    );
  END IF;

  UPDATE public.tool_invocations
     SET status        = 'FAILED'::public.tool_invocation_status_enum,
         error_class   = p_error_class,
         error_summary = p_error_summary,
         completed_at  = clock_timestamp(),
         updated_at    = clock_timestamp(),
         next_retry_at = NULL
   WHERE id = p_invocation_id
   RETURNING * INTO v_inv;

  IF v_phase.status <> 'HOLDING' THEN
    PERFORM public.hold_phase(v_inv.phase_state_id, format('tool failure: %s', v_inv.tool_name), 'BLOCKING'::public.gate_hold_severity_enum);
  END IF;

  IF v_run.status NOT IN ('REVIEW_HOLD','ABORTED','FINALIZED','FAILED','CANCELLED') THEN
    v_transition_result := public.transition_run(
      v_run.id, 'REVIEW_HOLD'::public.workflow_run_status_enum, p_actor_user_id,
      format('tool failure: %s', v_inv.tool_name), false, jsonb_build_object('error_class', p_error_class::text)
    );
  END IF;

  IF p_error_class = 'TRANSIENT' THEN
    v_action_event := 'WORKFLOW_TOOL_FAILED_AFTER_RETRIES'; v_severity := 'HIGH';
  ELSIF p_error_class = 'FATAL' THEN
    v_action_event := 'WORKFLOW_TOOL_FATAL_ERROR';          v_severity := 'BLOCKING';
  ELSE
    v_action_event := 'WORKFLOW_TOOL_SCHEMA_ERROR';         v_severity := 'HIGH';
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => v_action_event,
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('tool %s terminal failure (%s): %s', v_inv.tool_name, p_error_class, p_error_summary),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'phase_state_id', v_inv.phase_state_id, 'phase_name', v_phase.phase_name,
      'tool_invocation_id', v_inv.id, 'tool_name', v_inv.tool_name, 'attempt_number', v_inv.attempt_number,
      'error_class', p_error_class::text, 'error_summary', p_error_summary, 'error_detail', p_error_detail,
      'severity', v_severity
    )
  );

  -- B14 review issue placeholder
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_REVIEW_ISSUE_REQUESTED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => format('review issue for tool %s failure in phase %s', v_inv.tool_name, v_phase.phase_name),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'phase_state_id', v_inv.phase_state_id, 'phase_name', v_phase.phase_name,
      'tool_name', v_inv.tool_name, 'error_class', p_error_class::text,
      'error_summary', p_error_summary, 'severity', v_severity,
      'suggested_actions', CASE
        WHEN p_error_class = 'SCHEMA' THEN jsonb_build_array('Retry', 'Report bug', 'Abort')
        WHEN p_error_class = 'FATAL'  THEN jsonb_build_array('Abort')
        ELSE jsonb_build_array('Retry', 'Skip', 'Abort')
      END
    )
  );

  RETURN jsonb_build_object(
    'ok', true, 'will_retry', false, 'next_retry_at', NULL, 'attempts_remaining', 0,
    'run_held', true, 'review_issue_requested', true, 'severity', v_severity
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.fail_tool_invocation(uuid, public.tool_error_class_enum, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fail_tool_invocation(uuid, public.tool_error_class_enum, text, jsonb, uuid) TO service_role;

-- ---- reset_tool_for_retry (user "Retry" action) ----------------------------
CREATE OR REPLACE FUNCTION public.reset_tool_for_retry(
  p_invocation_id uuid,
  p_actor_user_id uuid,
  p_reason        text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_inv   public.tool_invocations;
  v_phase public.workflow_phase_states;
  v_run   public.workflow_runs;
  v_transition_result jsonb;
BEGIN
  IF p_invocation_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'reset_tool_for_retry: invocation_id and actor_user_id required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_inv FROM public.tool_invocations WHERE id = p_invocation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'reset_tool_for_retry: invocation % not found', p_invocation_id USING ERRCODE='P0002'; END IF;
  IF v_inv.status <> 'FAILED' THEN
    RAISE EXCEPTION 'reset_tool_for_retry: invocation % is in status % (must be FAILED)', p_invocation_id, v_inv.status USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_phase FROM public.workflow_phase_states WHERE id = v_inv.phase_state_id;
  SELECT * INTO v_run   FROM public.workflow_runs WHERE id = v_inv.workflow_run_id;

  -- Reset invocation. attempt_number=1 (not 0) due to ti_attempt_positive CHECK on tool_invocations.
  UPDATE public.tool_invocations
     SET status         = 'PENDING'::public.tool_invocation_status_enum,
         attempt_number = 1,
         error_summary  = NULL,
         error_class    = NULL,
         next_retry_at  = NULL,
         completed_at   = NULL,
         updated_at     = clock_timestamp()
   WHERE id = p_invocation_id
   RETURNING * INTO v_inv;

  UPDATE public.workflow_phase_states
     SET status = 'RUNNING'::public.phase_state_status_enum,
         updated_at = clock_timestamp()
   WHERE id = v_inv.phase_state_id;

  IF v_run.status = 'REVIEW_HOLD' THEN
    v_transition_result := public.transition_run(
      v_run.id, 'RUNNING'::public.workflow_run_status_enum, p_actor_user_id,
      COALESCE(p_reason, 'user requested retry'), false, '{}'::jsonb
    );
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_TOOL_RETRY_REQUESTED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('user-requested retry of tool %s', v_inv.tool_name),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'phase_state_id', v_inv.phase_state_id,
      'tool_invocation_id', v_inv.id, 'tool_name', v_inv.tool_name, 'reason', p_reason
    )
  );

  RETURN jsonb_build_object('ok', true, 'invocation_id', v_inv.id, 'run_status', v_run.status::text);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.reset_tool_for_retry(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.reset_tool_for_retry(uuid, uuid, text) TO authenticated, service_role;

-- ---- skip_held_tool (user "Skip" action) -----------------------------------
CREATE OR REPLACE FUNCTION public.skip_held_tool(
  p_invocation_id uuid,
  p_actor_user_id uuid,
  p_reason        text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_inv   public.tool_invocations;
  v_run   public.workflow_runs;
BEGIN
  IF p_invocation_id IS NULL OR p_actor_user_id IS NULL OR p_reason IS NULL OR length(btrim(p_reason))=0 THEN
    RAISE EXCEPTION 'skip_held_tool: invocation_id, actor_user_id, reason required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_inv FROM public.tool_invocations WHERE id = p_invocation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'skip_held_tool: invocation % not found', p_invocation_id USING ERRCODE='P0002'; END IF;
  IF v_inv.status <> 'FAILED' THEN
    RAISE EXCEPTION 'skip_held_tool: invocation % is in status % (must be FAILED)', p_invocation_id, v_inv.status USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_inv.workflow_run_id;
  UPDATE public.tool_invocations
     SET status     = 'SKIPPED'::public.tool_invocation_status_enum,
         updated_at = clock_timestamp()
   WHERE id = p_invocation_id;
  PERFORM audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_TOOL_SKIPPED_BY_USER',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('user skipped tool %s: %s', v_inv.tool_name, p_reason),
    p_after_state    => jsonb_build_object(
      'run_id', v_run.id, 'phase_state_id', v_inv.phase_state_id,
      'tool_invocation_id', v_inv.id, 'tool_name', v_inv.tool_name, 'reason', p_reason
    )
  );
  RETURN jsonb_build_object('ok', true, 'invocation_id', v_inv.id);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.skip_held_tool(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.skip_held_tool(uuid, uuid, text) TO authenticated, service_role;

-- ---- register_tool extended with retry policy params -----------------------
CREATE OR REPLACE FUNCTION public.register_tool(
  p_tool_name              text,
  p_version                text,
  p_input_schema           jsonb,
  p_output_schema          jsonb,
  p_side_effect            public.side_effect_class_enum,
  p_ai_tier                public.ai_tier_enum,
  p_failure_semantics      public.tool_failure_semantics_enum,
  p_dedup_key_generator_ref text DEFAULT NULL,
  p_description            text DEFAULT NULL,
  p_retry_max_attempts     integer DEFAULT 3,
  p_retry_backoff_base_ms  integer DEFAULT 2000,
  p_retry_backoff_max_ms   integer DEFAULT 60000
) RETURNS public.tool_registry
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE v_row public.tool_registry;
BEGIN
  IF p_tool_name IS NULL OR length(btrim(p_tool_name)) = 0 THEN
    RAISE EXCEPTION 'register_tool: tool_name required' USING ERRCODE='22000'; END IF;
  IF p_version IS NULL OR length(btrim(p_version)) = 0 THEN
    RAISE EXCEPTION 'register_tool: version required' USING ERRCODE='22000'; END IF;
  IF p_input_schema IS NULL OR jsonb_typeof(p_input_schema) <> 'object' THEN
    RAISE EXCEPTION 'register_tool: input_schema must be jsonb object' USING ERRCODE='22000'; END IF;
  IF p_output_schema IS NULL OR jsonb_typeof(p_output_schema) <> 'object' THEN
    RAISE EXCEPTION 'register_tool: output_schema must be jsonb object' USING ERRCODE='22000'; END IF;

  INSERT INTO public.tool_registry (
    tool_name, version, input_schema, output_schema, side_effect, ai_tier, failure_semantics,
    dedup_key_generator_ref, description,
    retry_max_attempts, retry_backoff_base_ms, retry_backoff_max_ms
  ) VALUES (
    p_tool_name, p_version, p_input_schema, p_output_schema, p_side_effect, p_ai_tier, p_failure_semantics,
    p_dedup_key_generator_ref, p_description,
    COALESCE(p_retry_max_attempts, 3), COALESCE(p_retry_backoff_base_ms, 2000), COALESCE(p_retry_backoff_max_ms, 60000)
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
    retry_max_attempts      = EXCLUDED.retry_max_attempts,
    retry_backoff_base_ms   = EXCLUDED.retry_backoff_base_ms,
    retry_backoff_max_ms    = EXCLUDED.retry_backoff_max_ms,
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
      'dedup_key_generator_ref', p_dedup_key_generator_ref,
      'retry_max_attempts', COALESCE(p_retry_max_attempts, 3),
      'retry_backoff_base_ms', COALESCE(p_retry_backoff_base_ms, 2000),
      'retry_backoff_max_ms', COALESCE(p_retry_backoff_max_ms, 60000)
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.register_tool(text, text, jsonb, jsonb, public.side_effect_class_enum, public.ai_tier_enum, public.tool_failure_semantics_enum, text, text, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.register_tool(text, text, jsonb, jsonb, public.side_effect_class_enum, public.ai_tier_enum, public.tool_failure_semantics_enum, text, text, integer, integer, integer) TO service_role;

COMMENT ON FUNCTION public.fail_tool_invocation(uuid, public.tool_error_class_enum, text, jsonb, uuid) IS
'B03·P08 failure chokepoint. Decides retry-vs-terminal based on error_class + tool retry policy + failure_semantics. On terminal failure: marks invocation FAILED, holds phase, transitions run to REVIEW_HOLD (via SYSTEM-capable transition_run), emits error-class audit + WORKFLOW_REVIEW_ISSUE_REQUESTED with severity + suggested_actions for B14 to consume.';

COMMENT ON FUNCTION public.transition_run(uuid, public.workflow_run_status_enum, uuid, text, boolean, jsonb) IS
'B03·P04+P08 single chokepoint for workflow_runs.status changes. SYSTEM actor (NULL user) supported for auto-transitions; privileged transitions (require permission) reject SYSTEM with SYSTEM_FORBIDDEN_FOR_PRIVILEGED_TRANSITION. Permission check skipped entirely for SYSTEM.';

COMMENT ON FUNCTION public.reset_tool_for_retry(uuid, uuid, text) IS
'B03·P08 user "Retry" action. Resets invocation to PENDING + attempt_number=1 (NOT 0 — ti_attempt_positive CHECK requires >=1), clears error fields, moves phase RUNNING + run REVIEW_HOLD→RUNNING.';

COMMENT ON FUNCTION public.skip_held_tool(uuid, uuid, text) IS
'B03·P08 user "Skip" action. Marks FAILED tool as SKIPPED. Does not auto-transition phase/run — caller decides next step (other failures may still block).';
