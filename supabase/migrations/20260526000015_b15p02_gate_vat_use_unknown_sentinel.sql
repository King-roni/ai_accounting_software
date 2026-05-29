-- B15·P02 fix-up: gate_finalization_vat_classifications_complete was
-- checking dle.vat_treatment IS NULL, but the column is NOT NULL with
-- an 'UNKNOWN' enum value used as the "not yet classified" sentinel.
-- Switch the predicate to use the sentinel.

CREATE OR REPLACE FUNCTION public.gate_finalization_vat_classifications_complete(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run record;
  v_unclassified int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','vat_classifications_complete',
                              'payload', jsonb_build_object('reason','RUN_NOT_FOUND'));
  END IF;

  SELECT count(*) INTO v_unclassified
    FROM public.draft_ledger_entries dle
    JOIN public.transactions t ON t.id = dle.parent_transaction_id
   WHERE t.business_id = v_run.business_id
     AND t.transaction_date BETWEEN v_run.period_start AND v_run.period_end
     AND dle.vat_treatment = 'UNKNOWN'::public.vat_treatment_enum;

  IF v_unclassified = 0 THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','vat_classifications_complete');
  END IF;
  RETURN jsonb_build_object('decision','HOLD','gate','vat_classifications_complete',
    'payload', jsonb_build_object('unclassified_count', v_unclassified));
END;
$$;
