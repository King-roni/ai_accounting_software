-- =============================================================================
-- BOOK-980 — matching exit gate is a no-op; make it actually verify matching ran.
-- =============================================================================
-- evaluate_matching_exit_gate only failed when an in-period OUT_EXPENSE had
-- match_status IS NULL. But transactions.match_status DEFAULTs to 'UNMATCHED'
-- (non-null), so the IS NULL branch can never be true → the gate always returned
-- {satisfied:true} and enforced nothing.
--
-- After the MATCHING phase runs, every in-period OUT_EXPENSE is one of:
--   * matched/confirmed  → match_status <> 'UNMATCHED' (apply_match_score), or
--   * a proposed match   → match_status STAYS 'UNMATCHED' but a match_records row
--                          exists (probable match awaiting user confirmation — the
--                          exit gate fires before confirmation, so this is normal), or
--   * no document found  → match_status STAYS 'UNMATCHED' and record_match_no_match
--                          files a 'match.missing_documents' review issue.
-- So a transaction that is still UNMATCHED with NONE of (a match_records row, a
-- match.missing_documents issue) was never processed by matching. The old gate
-- could not see this; the new gate fails on exactly that case, so a period can no
-- longer pass the MATCHING exit gate with expenses the matching engine never touched.
--
-- Exposed live: a Demo Trading Ltd OUT period reached FINALIZED with its MATCHING
-- phase still RUNNING and 4 UNMATCHED expenses (incl. an exact rent-invoice match)
-- and zero missing-documents issues — yet this gate reported satisfied.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.evaluate_matching_exit_gate(p_workflow_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_business_id uuid;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_unprocessed_n int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_business_id, v_period_start, v_period_end
    FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  -- An OUT_EXPENSE the matching engine processed is either matched
  -- (match_status <> 'UNMATCHED'), has a match_records row (a proposed match
  -- awaiting confirmation), or has a 'match.missing_documents' review issue.
  -- Still-UNMATCHED (or NULL) with NONE of those ⇒ matching never ran for it.
  SELECT count(*) INTO v_unprocessed_n
    FROM public.transactions t
   WHERE t.business_id = v_business_id
     AND t.transaction_type = 'OUT_EXPENSE'
     AND t.transaction_date BETWEEN v_period_start::date AND v_period_end::date
     AND (t.match_status IS NULL
          OR t.match_status = 'UNMATCHED'::public.transaction_match_status_enum)
     AND NOT EXISTS (
       SELECT 1 FROM public.match_records mr WHERE mr.transaction_id = t.id
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.review_issues ri
        WHERE ri.transaction_id = t.id
          AND ri.issue_type = 'match.missing_documents'
     );

  IF v_unprocessed_n > 0 THEN
    RETURN jsonb_build_object(
      'satisfied', false,
      'reason', 'OUT_EXPENSE_NOT_MATCH_PROCESSED',
      'unprocessed_count', v_unprocessed_n);
  END IF;
  RETURN jsonb_build_object('satisfied', true);
END;
$function$;
