-- Audit M4 — rebuild IN_ADJUSTMENT phases (mirror B12·P09 for symmetry)
-- =====================================================================
-- Before: IN_ADJUSTMENT had 4 placeholder phases (ADJUSTMENT_DRAFT,
-- CLASSIFY_ADJUSTMENT, USER_REVIEW, ARCHIVE_PROMOTION) inherited from
-- Block 03 P02's initial workflow type registration. These never received
-- gates or tools; they were placeholders awaiting B13 work.
--
-- B12·P09 already rebuilt OUT_ADJUSTMENT with the canonical 5-phase
-- sequence. Mirror that here for IN_ADJUSTMENT so Block 13's adjustment
-- intake RPC has the same shape. Pattern: rename → shift +100 → delete
-- → insert (same rebuild dance from B12·P02/P09 that works around
-- fn_check_phase_in_registry).
-- =====================================================================

BEGIN;

-- Rename + shift placeholders out of the way (no dependent rows confirmed
-- by audit query — safe)
UPDATE public.workflow_phase_definitions
   SET phase_name = phase_name || '__obsolete'
 WHERE workflow_type='IN_ADJUSTMENT';
UPDATE public.workflow_phase_definitions
   SET phase_order = phase_order + 100
 WHERE workflow_type='IN_ADJUSTMENT';
DELETE FROM public.workflow_phase_definitions WHERE workflow_type='IN_ADJUSTMENT';

INSERT INTO public.workflow_phase_definitions (workflow_type, phase_order, phase_name)
VALUES
  ('IN_ADJUSTMENT', 1, 'ADJUSTMENT_INTAKE'),
  ('IN_ADJUSTMENT', 2, 'ADJUSTMENT_LEDGER_PREP'),
  ('IN_ADJUSTMENT', 3, 'ADJUSTMENT_AI_REVIEW'),
  ('IN_ADJUSTMENT', 4, 'ADJUSTMENT_HUMAN_REVIEW'),
  ('IN_ADJUSTMENT', 5, 'ADJUSTMENT_FINALIZATION');

COMMIT;
