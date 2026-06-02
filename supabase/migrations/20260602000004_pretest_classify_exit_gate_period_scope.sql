-- =============================================================================
-- Pretest fix (2026-06-02) — N4: evaluate_classify_exit_gate period scope
-- =============================================================================
-- The classify EXIT gate scoped its "all resolved / no null type / needs-conf
-- has a review issue" checks business-wide (statement_upload_id IN <all uploads
-- for the business>) — the same pathology fixed on the ENTRY side in
-- 20260601000015. It passes in normal sequential operation, but any business-
-- wide unresolved / null-type / needs-confirmation-without-issue transaction in
-- ANOTHER period would HOLD an unrelated period's run at the CLASSIFICATION exit.
--
-- Fix: scope the checks to the run's own period, mirroring the canonical
-- finalization gate pattern (business_id + transaction_date BETWEEN
-- period_start AND period_end; see gate_finalization_transactions_processed).
-- Logic and return shape are otherwise unchanged.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.evaluate_classify_exit_gate(p_workflow_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run                public.workflow_runs%ROWTYPE;
  v_total              int;
  v_unresolved         int;
  v_null_type          int;
  v_needs_conf         int;
  v_needs_conf_no_iss  int;
  v_status_counts      jsonb;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  WITH tx AS (
    SELECT t.id, t.classification_status, t.transaction_type
      FROM public.transactions t
     WHERE t.business_id = v_run.business_id
       AND t.transaction_date BETWEEN v_run.period_start AND v_run.period_end
  )
  SELECT count(*) FILTER (WHERE TRUE),
         count(*) FILTER (WHERE classification_status NOT IN
                                ('CONFIRMED'::public.transaction_classification_status_enum,
                                 'NEEDS_CONFIRMATION'::public.transaction_classification_status_enum)
                            OR classification_status IS NULL),
         count(*) FILTER (WHERE transaction_type IS NULL),
         count(*) FILTER (WHERE classification_status = 'NEEDS_CONFIRMATION'::public.transaction_classification_status_enum)
    INTO v_total, v_unresolved, v_null_type, v_needs_conf
    FROM tx;

  SELECT count(*)
    INTO v_needs_conf_no_iss
    FROM public.transactions t
   WHERE t.business_id = v_run.business_id
     AND t.transaction_date BETWEEN v_run.period_start AND v_run.period_end
     AND t.classification_status = 'NEEDS_CONFIRMATION'::public.transaction_classification_status_enum
     AND NOT EXISTS (SELECT 1 FROM public.review_issues ri WHERE ri.transaction_id = t.id);

  SELECT jsonb_object_agg(coalesce(s::text, 'NULL'), c) INTO v_status_counts
    FROM (
      SELECT classification_status::text AS s, count(*) AS c
        FROM public.transactions
       WHERE business_id = v_run.business_id
         AND transaction_date BETWEEN v_run.period_start AND v_run.period_end
       GROUP BY classification_status
    ) z;

  IF v_unresolved > 0 THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'UNRESOLVED_TX_EXISTS',
      'total_count', v_total, 'unresolved_count', v_unresolved, 'status_counts', v_status_counts);
  END IF;
  IF v_null_type > 0 THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'NULL_TRANSACTION_TYPE',
      'total_count', v_total, 'null_type_count', v_null_type, 'status_counts', v_status_counts);
  END IF;
  IF v_needs_conf_no_iss > 0 THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'NEEDS_CONFIRMATION_MISSING_REVIEW_ISSUE',
      'total_count', v_total, 'missing_review_issues_count', v_needs_conf_no_iss, 'status_counts', v_status_counts);
  END IF;

  RETURN jsonb_build_object('passes', true, 'total_count', v_total,
                            'needs_confirmation_count', v_needs_conf,
                            'status_counts', v_status_counts);
END$function$;
