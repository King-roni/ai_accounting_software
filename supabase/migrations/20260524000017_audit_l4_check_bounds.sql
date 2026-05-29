-- Audit L4 — add upper-bound CHECK constraints on B12 tables (DoS / runaway risk)
-- =====================================================================
-- 3 CHECK constraints to guard against pathological inputs:
--   out_workflow_reminders.ordinal   <= 100   (prevent runaway-loop insert)
--   adjustment_records.reason length <= 4000  (DoS via huge payload)
--   out_workflow_business_config.manual_upload_hold_reminder_days
--                                    <= 365   (prevent absurd cadence)
-- =====================================================================

BEGIN;

ALTER TABLE public.out_workflow_reminders
  ADD CONSTRAINT out_workflow_reminders_ordinal_upper_chk
  CHECK (ordinal <= 100);

ALTER TABLE public.adjustment_records
  ADD CONSTRAINT adjustment_records_reason_max_length_chk
  CHECK (length(reason) <= 4000);

ALTER TABLE public.out_workflow_business_config
  ADD CONSTRAINT out_workflow_business_config_reminder_days_upper_chk
  CHECK (manual_upload_hold_reminder_days <= 365);

COMMIT;
