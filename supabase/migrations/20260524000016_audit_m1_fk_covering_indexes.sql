-- Audit M1 — add covering indexes on FK columns that lack them
-- =====================================================================
-- 20 FK columns were missing supporting indexes per live pg_constraint vs
-- pg_index audit. Without these, FK-referenced-row updates/deletes scan the
-- child tables (potentially many rows). Most-trafficked candidates also
-- back common JOIN paths (e.g. _out_adjustment_check_parent joining
-- adjustment_records on run_id + parent_run_id).
--
-- All indexes created CONCURRENTLY would be ideal, but a single transaction
-- migration uses normal CREATE INDEX (blocking the table briefly). At this
-- scale (greenfield DB, no production traffic) the block is negligible.
--
-- Indexes are partial WHERE col IS NOT NULL for nullable FK columns to keep
-- the index small and avoid indexing NULL slots.
-- =====================================================================

BEGIN;

-- adjustment_records (Block 12 P01/P09)
CREATE INDEX IF NOT EXISTS adjustment_records_run_id_idx
  ON public.adjustment_records (run_id);
CREATE INDEX IF NOT EXISTS adjustment_records_parent_run_id_idx
  ON public.adjustment_records (parent_run_id);
CREATE INDEX IF NOT EXISTS adjustment_records_requesting_user_id_idx
  ON public.adjustment_records (requesting_user_id);

-- out_workflow_business_config (Block 12 P01)
CREATE INDEX IF NOT EXISTS out_workflow_business_config_last_updated_by_idx
  ON public.out_workflow_business_config (last_updated_by)
  WHERE last_updated_by IS NOT NULL;

-- out_workflow_reminders (Block 12 P06)
CREATE INDEX IF NOT EXISTS out_workflow_reminders_business_id_idx
  ON public.out_workflow_reminders (business_id);
CREATE INDEX IF NOT EXISTS out_workflow_reminders_organization_id_idx
  ON public.out_workflow_reminders (organization_id);

-- workflow_run_approvals (Block 12 P01)
CREATE INDEX IF NOT EXISTS workflow_run_approvals_approved_by_idx
  ON public.workflow_run_approvals (approved_by);
CREATE INDEX IF NOT EXISTS workflow_run_approvals_revoked_by_idx
  ON public.workflow_run_approvals (revoked_by)
  WHERE revoked_by IS NOT NULL;

-- workflow_runs (Block 03 + Block 12 col adds)
CREATE INDEX IF NOT EXISTS workflow_runs_started_by_idx
  ON public.workflow_runs (started_by)
  WHERE started_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS workflow_runs_finalized_by_idx
  ON public.workflow_runs (finalized_by)
  WHERE finalized_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS workflow_runs_aborted_by_idx
  ON public.workflow_runs (aborted_by)
  WHERE aborted_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS workflow_runs_triggered_by_user_id_idx
  ON public.workflow_runs (triggered_by_user_id)
  WHERE triggered_by_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS workflow_runs_tag_taxonomy_version_id_idx
  ON public.workflow_runs (tag_taxonomy_version_id)
  WHERE tag_taxonomy_version_id IS NOT NULL;

-- transactions (Block 12 P03 / P06 col adds)
CREATE INDEX IF NOT EXISTS transactions_exception_documented_by_idx
  ON public.transactions (exception_documented_by)
  WHERE exception_documented_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS transactions_out_filter_decided_by_run_id_idx
  ON public.transactions (out_filter_decided_by_run_id)
  WHERE out_filter_decided_by_run_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS transactions_in_filter_decided_by_run_id_idx
  ON public.transactions (in_filter_decided_by_run_id)
  WHERE in_filter_decided_by_run_id IS NOT NULL;

-- draft_ledger_entries (Block 11)
CREATE INDEX IF NOT EXISTS dle_credit_account_idx
  ON public.draft_ledger_entries (business_id, credit_account_code);
CREATE INDEX IF NOT EXISTS dle_debit_account_idx
  ON public.draft_ledger_entries (business_id, debit_account_code);
CREATE INDEX IF NOT EXISTS dle_chart_mapping_version_id_idx
  ON public.draft_ledger_entries (chart_mapping_version_id)
  WHERE chart_mapping_version_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS dle_manual_override_by_idx
  ON public.draft_ledger_entries (manual_override_by)
  WHERE manual_override_by IS NOT NULL;

-- trigger_events_processed (Block 03 P09)
CREATE INDEX IF NOT EXISTS trigger_events_processed_organization_id_idx
  ON public.trigger_events_processed (organization_id)
  WHERE organization_id IS NOT NULL;

COMMIT;
