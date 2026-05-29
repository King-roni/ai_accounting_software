-- ============================================================================
-- Block 13 Phase 07 — IN_MONTHLY phase rebuild (audit-M5 fix)
--
-- Current state (placeholder shape):
--   1 INVOICE_GENERATION, 2 PARSE_INCOME, 3 EVIDENCE_DISCOVERY_LOCAL,
--   4 EVIDENCE_DISCOVERY_DRIVE, 5 EVIDENCE_DISCOVERY_GMAIL, 6 CLASSIFY,
--   7 INCOME_MATCHING, 8 LEDGER_DRAFT, 9 REVIEW_QUEUE_GATE,
--   10 USER_REVIEW, 11 ARCHIVE_PROMOTION
--
-- Target (canonical per B13·P07 spec, 8 positions):
--   1 INGESTION, 2 CLASSIFICATION, 3 IN_FILTER, 4 INCOME_MATCHING,
--   5 LEDGER_PREPARATION, 6 AI_END_SCAN, 7 HUMAN_REVIEW_HOLD (side),
--   8 FINALIZATION
-- ============================================================================

DELETE FROM public.phase_tool_expectations  WHERE workflow_type='IN_MONTHLY';
DELETE FROM public.phase_gate_assignments   WHERE workflow_type='IN_MONTHLY';

UPDATE public.workflow_phase_definitions
   SET phase_name = phase_name || '__OBSOLETE',
       phase_order = phase_order + 100
 WHERE workflow_type = 'IN_MONTHLY';

DELETE FROM public.workflow_phase_definitions WHERE workflow_type='IN_MONTHLY';

INSERT INTO public.workflow_phase_definitions (workflow_type, phase_order, phase_name, optional, description, is_shared_with_pair) VALUES
  ('IN_MONTHLY', 1, 'INGESTION',          false, 'Shared with OUT_MONTHLY — Block 07 owns', true),
  ('IN_MONTHLY', 2, 'CLASSIFICATION',     false, 'Shared with OUT_MONTHLY — Block 08 owns', true),
  ('IN_MONTHLY', 3, 'IN_FILTER',          false, 'IN-side scope filter — B13·P08 owns', false),
  ('IN_MONTHLY', 4, 'INCOME_MATCHING',    false, 'IN-side matching — B10·P08 owns', false),
  ('IN_MONTHLY', 5, 'LEDGER_PREPARATION', false, 'Consolidates INCOME_LEDGER_PREPARATION + VAT_CLASSIFICATION — B11·P09', false),
  ('IN_MONTHLY', 6, 'AI_END_SCAN',        false, 'End-of-run AI review — B06·P11', false),
  ('IN_MONTHLY', 7, 'HUMAN_REVIEW_HOLD',  true,  'Side phase — entered conditionally — B13·P09 owns', false),
  ('IN_MONTHLY', 8, 'FINALIZATION',       false, 'Block 15 — period lock', false);
