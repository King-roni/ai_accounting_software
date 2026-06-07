-- =============================================================================
-- BOOK-968 (part A) — add CONFIRM_LEDGER_ENTRY resolution action.
-- =============================================================================
-- ledger.requires_accountant_review issues (raised by apply_vat_treatment_manual_
-- override and the ledger engine) had no resolving action that an accountant
-- could use to *confirm* the entry: allowed actions were CHANGE_TAG (a Stage-1
-- stub that routes away), ADD_EXPLANATION_NOTE (keeps the issue OPEN), and
-- SEND_TO_ACCOUNTANT_REVIEW (re-assigns). So a manual VAT override left a blocking
-- review issue that could never be closed in-app → period could not finalize.
--
-- Part A adds the new enum value only. ALTER TYPE ADD VALUE has deferred
-- visibility, so the value cannot be used in the same migration — the handler +
-- registry wiring lands in part B (20260607000005).
-- =============================================================================

ALTER TYPE public.resolution_action_kind_enum ADD VALUE IF NOT EXISTS 'CONFIRM_LEDGER_ENTRY';
