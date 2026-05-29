-- Audit H1 — add MATCHED_AUTO_HIGH_CONFIDENCE to transaction_match_status_enum
-- =====================================================================
-- Spec Docs/phases/12_out_workflow/06_manual_upload_hold_phase.md:43,53
-- requires MATCHED_AUTO_HIGH_CONFIDENCE as a clear state for
-- gate_out_manual_upload_hold_exit_v1. The enum was missing it.
--
-- The gate already treats anything not in {NULL, UNMATCHED} as "resolved"
-- (counts only unmatched rows), so adding the value is sufficient — no
-- gate body change required. Block 10's matcher can now emit this value
-- per spec.
-- =====================================================================

ALTER TYPE public.transaction_match_status_enum
  ADD VALUE IF NOT EXISTS 'MATCHED_AUTO_HIGH_CONFIDENCE';
