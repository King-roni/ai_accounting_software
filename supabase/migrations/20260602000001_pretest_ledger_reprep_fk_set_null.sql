-- =============================================================================
-- Pretest fix (2026-06-02) — N2: unblock LEDGER_PREPARATION re-run (FK 23503)
-- =============================================================================
-- prepare_ledger_entries does a blind DELETE FROM draft_ledger_entries + reinsert.
-- review_issues.draft_ledger_entry_id → draft_ledger_entries(id) is NO ACTION, so
-- any RE-RUN over a transaction whose draft entry is referenced by a review_issue
-- (e.g. ledger.missing_required_evidence) raised ERROR 23503 and the IN finalize
-- journey (resolve issue → rescan → re-drive → re-prep) could never complete.
--
-- Make the link drop to NULL when an entry is regenerated: the issue's meaningful
-- anchors (transaction_id / workflow_run_id) remain; the stale entry pointer is
-- cleared (the entry no longer exists). Re-prep then succeeds; the rescan path
-- re-raises/clears issues against the new entries as appropriate.
-- =============================================================================

ALTER TABLE public.review_issues
  DROP CONSTRAINT review_issues_draft_ledger_entry_id_fkey;

ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issues_draft_ledger_entry_id_fkey
  FOREIGN KEY (draft_ledger_entry_id) REFERENCES public.draft_ledger_entries(id)
  ON DELETE SET NULL;
