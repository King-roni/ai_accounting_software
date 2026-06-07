-- =============================================================================
-- BOOK-969 — resume a run held at a gate (not just a human-review hold).
-- =============================================================================
-- The run drawer's only resume affordance was "Clear review hold", which calls
-- {out,in}_workflow_clear_human_review_hold — those clear the HUMAN_REVIEW_HOLD
-- side phase only. When a run is REVIEW_HOLD because a phase gate held (e.g.
-- LEDGER_PREPARATION exit gate), the button was a silent no-op (still toasted
-- "success") and there was no in-app way to resume after fixing the cause.
--
-- resume_workflow_run transitions REVIEW_HOLD → RUNNING (review_release_auto) and
-- resets any HOLDING phase to PENDING so the worker re-drives from the held phase
-- and re-evaluates its gate (proceeds if the blocker is fixed; re-holds if not).
-- The drawer uses this for gate holds and keeps the clear-hold RPC for the
-- human-review case (which carries its own approval/audit semantics).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.resume_workflow_run(
  p_run_id uuid, p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
DECLARE
  v_run    public.workflow_runs;
  v_trans  jsonb;
  v_reset  int := 0;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND');
  END IF;
  IF v_run.status <> 'REVIEW_HOLD'::public.workflow_run_status_enum THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_IN_REVIEW_HOLD',
                              'status', v_run.status::text);
  END IF;

  v_trans := public.transition_run(
    p_run_id, 'RUNNING'::public.workflow_run_status_enum, p_actor_user_id,
    'resume from review hold (re-drive held phases)', false, p_context);
  IF NOT COALESCE((v_trans->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('decision','DENY',
      'reason_code', COALESCE(v_trans->>'reason','TRANSITION_REJECTED'),
      'message', v_trans->>'message');
  END IF;

  UPDATE public.workflow_phase_states
     SET status = 'PENDING', gate_decision = NULL, completed_at = NULL, error_summary = NULL
   WHERE workflow_run_id = p_run_id AND status = 'HOLDING';
  GET DIAGNOSTICS v_reset = ROW_COUNT;

  RETURN jsonb_build_object('decision','ALLOW','run_id', p_run_id,
    'phases_reset', v_reset, 'transition', v_trans->>'transition_name');
END;
$function$;

REVOKE ALL ON FUNCTION public.resume_workflow_run(uuid,uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resume_workflow_run(uuid,uuid,jsonb) TO authenticated;
