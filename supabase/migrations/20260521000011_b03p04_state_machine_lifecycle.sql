-- B03·P04 State Machine & Lifecycle Controls
-- =============================================================================
-- Single chokepoint: public.transition_run is the ONLY way workflow_runs.status
-- can change. A BEFORE-UPDATE trigger blocks direct UPDATE of the status column
-- unless the session variable app.transition_run_active = 'true' (set by the
-- RPC for its UPDATE statement only). An AFTER-INSERT trigger emits a
-- null→CREATED state-change audit. The legal transition graph is data in
-- workflow_run_state_transitions; transition_run looks up the row and applies
-- the declared side-effect columns.
-- =============================================================================

CREATE TABLE public.workflow_run_state_transitions (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  transition_name             text NOT NULL,
  from_state                  public.workflow_run_status_enum,
  from_state_is_wildcard      boolean NOT NULL DEFAULT false,
  to_state                    public.workflow_run_status_enum NOT NULL,
  requires_step_up            boolean NOT NULL DEFAULT false,
  requires_permission_surface text,
  requires_permission_action  text,
  requires_reason             boolean NOT NULL DEFAULT false,
  side_effect_columns         jsonb NOT NULL DEFAULT '{}'::jsonb,
  description                 text,
  created_at                  timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT wrst_wildcard_xor_from CHECK (
    (from_state_is_wildcard AND from_state IS NULL)
    OR (NOT from_state_is_wildcard AND (from_state IS NOT NULL OR to_state = 'CREATED'))
  ),
  CONSTRAINT wrst_perm_pair CHECK (
    (requires_permission_surface IS NULL AND requires_permission_action IS NULL)
    OR (requires_permission_surface IS NOT NULL AND requires_permission_action IS NOT NULL)
  ),
  CONSTRAINT wrst_side_effect_obj CHECK (jsonb_typeof(side_effect_columns) = 'object')
);

CREATE UNIQUE INDEX uq_wrst_exact_pair  ON public.workflow_run_state_transitions (from_state, to_state) WHERE NOT from_state_is_wildcard;
CREATE UNIQUE INDEX uq_wrst_wildcard_to ON public.workflow_run_state_transitions (to_state) WHERE from_state_is_wildcard;
CREATE INDEX idx_wrst_from              ON public.workflow_run_state_transitions (from_state) WHERE NOT from_state_is_wildcard;

INSERT INTO public.workflow_run_state_transitions
  (transition_name, from_state, from_state_is_wildcard, to_state, requires_step_up, requires_permission_surface, requires_permission_action, requires_reason, side_effect_columns, description)
VALUES
  ('create',             NULL,                false, 'CREATED',           false, NULL, NULL, false, '{}'::jsonb,                                                                                                       'Initial creation (null → CREATED). Emitted by AFTER INSERT trigger; not callable via transition_run.'),
  ('start',              'CREATED',           false, 'RUNNING',           false, NULL, NULL, false, '{"started_at":"now"}'::jsonb,                                                                                     'Engine begins first phase.'),
  ('pause',              'RUNNING',           false, 'PAUSED',            false, 'workflow_run', 'pause', false, '{}'::jsonb,                                                                                                 'Manual pause.'),
  ('resume',             'PAUSED',            false, 'RUNNING',           false, 'workflow_run', 'resume', false, '{}'::jsonb,                                                                                                'Manual resume from last persisted phase boundary.'),
  ('review_hold_auto',   'RUNNING',           false, 'REVIEW_HOLD',       false, NULL, NULL, false, '{}'::jsonb,                                                                                                              'Auto: blocking gate or tool failure routed to review.'),
  ('review_release_auto','REVIEW_HOLD',       false, 'RUNNING',           false, NULL, NULL, false, '{}'::jsonb,                                                                                                              'Auto: gate re-evaluation found zero blocking issues.'),
  ('await_approval_auto','RUNNING',           false, 'AWAITING_APPROVAL', false, NULL, NULL, false, '{}'::jsonb,                                                                                                              'Auto: final pre-approval phase exit gates passed.'),
  ('finalize_start',     'AWAITING_APPROVAL', false, 'FINALIZING',        false, 'workflow_run', 'finalize', false, '{}'::jsonb,                                                                                              'User approval received; finalization in progress.'),
  ('finalize_complete',  'FINALIZING',        false, 'FINALIZED',         false, NULL, NULL, false, '{"finalized_at":"now","finalized_by":"actor","completed_at":"now"}'::jsonb,                                            'Lock sequence completed.'),
  ('finalize_rollback',  'FINALIZING',        false, 'AWAITING_APPROVAL', false, NULL, NULL, false, '{}'::jsonb,                                                                                                              'Lock sequence failure rollback (auto-retry policy).'),
  ('abort',              NULL,                true,  'ABORTED',           true,  'workflow_run', 'abort', true,  '{"aborted_at":"now","aborted_by":"actor","abort_reason":"reason","completed_at":"now"}'::jsonb,           'Manual abort (Owner/Admin + step-up + reason).');

CREATE OR REPLACE FUNCTION public.is_terminal_state(p_state public.workflow_run_status_enum)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = pg_temp
AS $fn$
  SELECT p_state IN ('FINALIZED','ABORTED','FAILED','CANCELLED');
$fn$;
REVOKE EXECUTE ON FUNCTION public.is_terminal_state(public.workflow_run_status_enum) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.is_terminal_state(public.workflow_run_status_enum) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.list_legal_transitions(p_current_state public.workflow_run_status_enum)
RETURNS SETOF public.workflow_run_state_transitions
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT *
    FROM public.workflow_run_state_transitions
   WHERE (NOT from_state_is_wildcard AND from_state = p_current_state)
      OR (from_state_is_wildcard AND p_current_state IS NOT NULL AND p_current_state NOT IN ('FINALIZED','ABORTED','FAILED','CANCELLED'))
   ORDER BY transition_name;
$fn$;
REVOKE EXECUTE ON FUNCTION public.list_legal_transitions(public.workflow_run_status_enum) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.list_legal_transitions(public.workflow_run_status_enum) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_block_direct_status_update()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF COALESCE(current_setting('app.transition_run_active', true),'') <> 'true' THEN
      RAISE EXCEPTION 'workflow_runs.status: direct UPDATE forbidden — use public.transition_run (% → %)', OLD.status, NEW.status
        USING ERRCODE='42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_workflow_runs_block_direct_status_update
  BEFORE UPDATE OF status ON public.workflow_runs
  FOR EACH ROW EXECUTE FUNCTION public.fn_block_direct_status_update();

CREATE OR REPLACE FUNCTION public.fn_audit_workflow_run_creation()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, audit, pg_temp
AS $fn$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_RUN_STATE_CHANGED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => NEW.id,
    p_business_id    => NEW.business_id,
    p_organization_id=> NEW.organization_id,
    p_actor_system   => 'workflow_engine',
    p_reason         => 'workflow_run created (null → CREATED)',
    p_after_state    => jsonb_build_object(
      'run_id',         NEW.id,
      'transition_name','create',
      'from_state',     NULL,
      'to_state',       NEW.status::text,
      'workflow_type',  NEW.workflow_type::text,
      'started_by',     NEW.started_by
    )
  );
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_workflow_runs_audit_creation
  AFTER INSERT ON public.workflow_runs
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_workflow_run_creation();

-- ---- transition_run: single chokepoint for status changes ------------------
-- Mitigation-A envelope. Never raises on policy failure; emits
-- WORKFLOW_RUN_STATE_CHANGE_REJECTED and returns {ok:false, reason:<code>}.
-- Error codes: ILLEGAL_TRANSITION, TERMINAL_STATE, STEP_UP_REQUIRED,
-- REASON_REQUIRED, PERMISSION_DENIED.
--
-- Note on audit constraint compatibility:
--   audit_events_actor_kind_chk requires:
--     USER  → actor_user_id NOT NULL AND actor_system IS NULL
--     SYSTEM → actor_user_id IS NULL AND actor_system NOT NULL
--   transition_run always emits as USER (actor_user_id only), never passes actor_system.
--   The creation trigger emits as SYSTEM (actor_system only), never passes actor_user_id.
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
BEGIN
  IF p_run_id IS NULL OR p_target_state IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'transition_run: run_id, target_state, actor_user_id are required' USING ERRCODE='22000';
  END IF;

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
     ORDER BY from_state_is_wildcard ASC
     LIMIT 1;
    IF NOT FOUND THEN
      v_reject_code := 'ILLEGAL_TRANSITION';
      v_reject_msg  := format('no transition defined: %s → %s', v_run.status, p_target_state);
    END IF;
  END IF;

  IF v_reject_code IS NULL AND v_trans.requires_step_up AND NOT COALESCE(p_step_up_verified, false) THEN
    v_reject_code := 'STEP_UP_REQUIRED';
    v_reject_msg  := format('transition %s requires step-up MFA verification', v_trans.transition_name);
  END IF;

  IF v_reject_code IS NULL AND v_trans.requires_reason AND (p_reason IS NULL OR length(btrim(p_reason)) = 0) THEN
    v_reject_code := 'REASON_REQUIRED';
    v_reject_msg  := format('transition %s requires a non-empty reason', v_trans.transition_name);
  END IF;

  IF v_reject_code IS NULL AND v_trans.requires_permission_surface IS NOT NULL THEN
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
      p_actor_kind     => 'USER'::audit.actor_kind_enum,
      p_action         => 'WORKFLOW_RUN_STATE_CHANGE_REJECTED',
      p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id     => v_run.id,
      p_business_id    => v_run.business_id,
      p_organization_id=> v_run.organization_id,
      p_actor_user_id  => p_actor_user_id,
      p_reason         => v_reject_msg,
      p_after_state    => jsonb_build_object(
        'run_id',         v_run.id,
        'from_state',     v_run.status::text,
        'attempted_to',   p_target_state::text,
        'rejection_code', v_reject_code,
        'context',        p_context
      )
    );
    RETURN jsonb_build_object(
      'ok',         false,
      'run_id',     v_run.id,
      'from_state', v_run.status::text,
      'to_state',   v_run.status::text,
      'reason',     v_reject_code,
      'message',    v_reject_msg
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
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_RUN_STATE_CHANGED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('transition %s: %s → %s', v_trans.transition_name, v_run.status, p_target_state),
    p_before_state   => jsonb_build_object('status', v_run.status::text),
    p_after_state    => jsonb_build_object(
      'run_id',           v_run.id,
      'transition_name',  v_trans.transition_name,
      'from_state',       v_run.status::text,
      'to_state',         p_target_state::text,
      'reason',           p_reason,
      'context',          p_context
    )
  );

  IF v_trans.transition_name = 'pause' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum, p_action => 'WORKFLOW_RUN_PAUSED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => p_actor_user_id,
      p_reason => format('run %s paused', v_run.id),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text)
    );
  ELSIF v_trans.transition_name = 'resume' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum, p_action => 'WORKFLOW_RUN_RESUMED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => p_actor_user_id,
      p_reason => format('run %s resumed', v_run.id),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text)
    );
  ELSIF v_trans.transition_name = 'abort' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum, p_action => 'WORKFLOW_RUN_ABORTED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => p_actor_user_id,
      p_reason => format('run %s aborted: %s', v_run.id, p_reason),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text, 'abort_reason', p_reason)
    );
  ELSIF v_trans.transition_name = 'finalize_complete' THEN
    PERFORM audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum, p_action => 'WORKFLOW_RUN_FINALIZED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_run.id,
      p_business_id => v_run.business_id, p_organization_id => v_run.organization_id,
      p_actor_user_id => p_actor_user_id,
      p_reason => format('run %s finalized', v_run.id),
      p_before_state => jsonb_build_object('status', v_run.status::text),
      p_after_state  => jsonb_build_object('status', p_target_state::text)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'run_id',          v_run.id,
    'from_state',      v_run.status::text,
    'to_state',        p_target_state::text,
    'transition_name', v_trans.transition_name,
    'audit_event_id',  v_audit.event_id
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.transition_run(uuid, public.workflow_run_status_enum, uuid, text, boolean, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.transition_run(uuid, public.workflow_run_status_enum, uuid, text, boolean, jsonb) TO authenticated, service_role;

ALTER TABLE public.workflow_run_state_transitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_run_state_transitions FORCE  ROW LEVEL SECURITY;

CREATE POLICY wrst_select_all ON public.workflow_run_state_transitions AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY wrst_no_insert  ON public.workflow_run_state_transitions AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY wrst_no_update  ON public.workflow_run_state_transitions AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY wrst_no_delete  ON public.workflow_run_state_transitions AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON public.workflow_run_state_transitions TO authenticated, service_role;

COMMENT ON TABLE public.workflow_run_state_transitions IS
'B03·P04 declarative state-machine catalog. transition_run is the sole writer to workflow_runs.status. Seed is the single source of truth — print-and-review compliant. side_effect_columns is a jsonb keyset; the values are sentinels (now/actor/reason) interpreted by transition_run.';

COMMENT ON FUNCTION public.transition_run(uuid, public.workflow_run_status_enum, uuid, text, boolean, jsonb) IS
'B03·P04 single chokepoint for workflow_runs.status changes. Mitigation-A envelope: never raises on policy failures, returns {ok, reason} with codes ILLEGAL_TRANSITION/TERMINAL_STATE/STEP_UP_REQUIRED/REASON_REQUIRED/PERMISSION_DENIED, emitting WORKFLOW_RUN_STATE_CHANGE_REJECTED. Success emits WORKFLOW_RUN_STATE_CHANGED plus transition-specific event (PAUSED/RESUMED/ABORTED/FINALIZED). Uses can_perform envelope key "decision" with values ALLOW/DENY/STEP_UP.';

COMMENT ON FUNCTION public.fn_block_direct_status_update() IS
'B03·P04 guard: blocks direct UPDATE of workflow_runs.status unless inside transition_run (which sets app.transition_run_active to true for the local statement).';
