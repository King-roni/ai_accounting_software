-- =============================================================================
-- Reset the demo dataset back to baseline — "Demo Trading Ltd" (R7.9)
-- =============================================================================
-- Removes everything scripts/seed_demo_dataset.sql adds (Feb/Mar/Apr 2026
-- statements + transactions, the two draft demo invoices, the three discovered
-- documents). The original May-2026 baseline (the c1 upload + its 6
-- transactions, the SENT invoice, the two clients) is left untouched.
--
-- The c1 upload is intentionally NOT reverted to UPLOADED — leaving it ACCEPTED
-- keeps the stuck-parse hazard cleared.
--
-- Run with the service_role connection (bypasses RLS). Re-running is safe.
-- After a reset you can re-run scripts/seed_demo_dataset.sql to rebuild.
--
-- SCOPE NOTE (2026-06-01 pretest): this script tears down only the *additive*
-- seed-r79 fixtures (file_id / invoice_number LIKE patterns above). It does NOT
-- touch the driven workflow state stood up for the testing phase, which is
-- INTENTIONAL and coherent demo content, not stale ad-hoc rows:
--   * the canonical OUT/IN runs (started via out_workflow_start_run_manually),
--   * their engine-produced match_records / review_issues / draft_ledger_entries,
--   * the FINALIZED May 2026 OUT period + its archive_package (v1 manifest) and
--     the OUT_ADJUSTMENT run (v2 manifest).
-- The finalized period is deliberately PERMANENT: finalization writes an
-- immutable, object-locked archive (3-layer immutability), so it cannot be
-- reverted by a reset and is left in place as the Archive/adjustment demo.
-- To rebuild non-finalized runs from scratch, cancel/remove them via the
-- workflow RPCs and re-run out_workflow_start_run_manually + the worker.
-- =============================================================================

DO $$
DECLARE
  v_biz uuid := '0e000000-0000-4000-8000-0000000000b1';
  v_deleted_tx int; v_deleted_upl int; v_deleted_inv int; v_deleted_doc int;
BEGIN
  -- Transactions first (FK → statement_uploads).
  DELETE FROM public.transactions t
   USING public.statement_uploads s
   WHERE t.statement_upload_id = s.id
     AND s.business_id = v_biz
     AND s.file_id LIKE 'seed-r79-%';
  GET DIAGNOSTICS v_deleted_tx = ROW_COUNT;

  DELETE FROM public.statement_uploads
   WHERE business_id = v_biz AND file_id LIKE 'seed-r79-%';
  GET DIAGNOSTICS v_deleted_upl = ROW_COUNT;

  -- Only DRAFT invoices are deletable (fn_block_invoice_delete_non_draft); the
  -- seed keeps these DRAFT precisely so reset is clean.
  DELETE FROM public.invoices
   WHERE business_id = v_biz AND invoice_number LIKE 'INV-DEMO-79%';
  GET DIAGNOSTICS v_deleted_inv = ROW_COUNT;

  DELETE FROM public.documents
   WHERE business_id = v_biz AND invoice_number LIKE 'SEED-R79-%';
  GET DIAGNOSTICS v_deleted_doc = ROW_COUNT;

  RAISE NOTICE 'reset_demo_dataset: removed % transactions, % uploads, % invoices, % documents',
    v_deleted_tx, v_deleted_upl, v_deleted_inv, v_deleted_doc;
END $$;

-- Refresh analytics so the dashboard reflects the baseline again.
SELECT analytics.refresh_business('0e000000-0000-4000-8000-0000000000b1'::uuid);
