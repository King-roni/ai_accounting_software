-- =============================================================================
-- Pretest readiness fix (2026-06-01) — classification entry gate multi-period block
-- =============================================================================
-- evaluate_classify_entry_gate held the run (passes=false, NON_PENDING_TX_EXISTS)
-- whenever ANY business transaction had a non-PENDING classification_status,
-- scoped business-wide (all statement_uploads for the business). Because
-- handle_classification ALSO classifies business-wide PENDING rows, the first
-- run for a business confirms every transaction across every period — so the
-- entry gate then permanently HOLDs every subsequent run (next month, a fresh
-- upload, etc.) at REVIEW_HOLD. This silently breaks multi-period operation and
-- any post-finalization journey (finalized rows are non-PENDING forever).
--
-- The hold is also redundant: the CLASSIFICATION engine only touches PENDING
-- rows (no-ops on already-classified ones) and the shared-phase dedup
-- (check_shared_phase_can_dedup) already prevents the OUT/IN sibling from
-- re-classifying. Re-entering with rows already classified is therefore safe.
--
-- Fix: advance regardless of non-PENDING rows; still report counts for
-- observability. The first-run case (all PENDING) is unchanged (advances);
-- subsequent runs now advance and classify only their own PENDING rows.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.evaluate_classify_entry_gate(p_workflow_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.workflow_runs%ROWTYPE;
  v_total      int;
  v_pending    int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  SELECT count(*),
         count(*) FILTER (WHERE classification_status IS NULL
                            OR classification_status = 'PENDING'::public.transaction_classification_status_enum)
    INTO v_total, v_pending
    FROM public.transactions
   WHERE statement_upload_id IN (SELECT id FROM public.statement_uploads WHERE business_id = v_run.business_id);

  -- Always advance: the engine only classifies PENDING rows and the shared-phase
  -- dedup guards the sibling, so entering when some rows are already classified
  -- (prior period / sibling / finalized) is a safe no-op for those rows.
  RETURN jsonb_build_object('passes', true, 'total_count', v_total, 'pending_count', v_pending);
END
$function$;
