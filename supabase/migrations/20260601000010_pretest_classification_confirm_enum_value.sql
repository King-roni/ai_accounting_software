-- =============================================================================
-- Pretest readiness fix (2026-06-01) — add CONFIRM_CLASSIFICATION resolution action
-- =============================================================================
-- public.record_classification_user_confirmed wrote
--   resolution_action = 'CONFIRM'
-- but 'CONFIRM' is NOT a member of public.resolution_action_kind_enum
-- (members: UPLOAD_DOCUMENT, CONFIRM_MATCH, REJECT_MATCH, CHANGE_TAG,
--  CHANGE_TRANSACTION_TYPE, MARK_AS_*, ADD_EXPLANATION_NOTE,
--  SEND_TO_ACCOUNTANT_REVIEW, IGNORE_WITH_REASON, RERUN_SCAN_AFTER_CHANGE).
-- So every call raised 22P02 and the entire "confirm a NEEDS_CONFIRMATION
-- classification" → classification_exit gate → finalize path was unreachable.
--
-- Add the intended value. ALTER TYPE ... ADD VALUE has deferred visibility, so
-- the RPC that USES the value ships in the next migration
-- (20260601000011_pretest_classification_confirm_rpc_fix.sql).
-- =============================================================================

ALTER TYPE public.resolution_action_kind_enum
  ADD VALUE IF NOT EXISTS 'CONFIRM_CLASSIFICATION';
