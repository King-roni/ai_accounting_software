-- B15·P02 fix-up: gate_finalization_audit_log_quiescent was matching the
-- WORKFLOW_RUN_STATE_CHANGED audit emitted by the workflow_runs creation
-- trigger (actor_system='workflow_engine') and the composite's own
-- FINALIZATION_PRECONDITIONS_* audits. Neither indicates "upstream work
-- in flight" — they're administrative footprints. Narrow the predicate
-- to exclude composite-self-emissions and engine-plumbing audits.

CREATE OR REPLACE FUNCTION public.gate_finalization_audit_log_quiescent(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE v_recent int;
BEGIN
  SELECT count(*) INTO v_recent FROM audit.audit_events
   WHERE subject_type = 'WORKFLOW_RUN'::audit.subject_type_enum
     AND subject_id = p_run_id
     AND created_at > clock_timestamp() - interval '5 seconds'
     AND action NOT LIKE 'FINALIZATION_%'
     AND action <> 'WORKFLOW_RUN_STATE_CHANGED'
     AND COALESCE(actor_system, '') NOT IN ('finalization_gate_composite', 'workflow_engine');
  IF v_recent = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','audit_log_quiescent');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','audit_log_quiescent',
    'payload', jsonb_build_object('recent_events_count', v_recent,
                                   'settle_window_seconds', 5));
END;
$$;
