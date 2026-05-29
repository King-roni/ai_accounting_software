-- B06·P03 — Redaction Policy & Engine (migration 1 of 2)
--
-- ALTER TYPE additions. Standalone migration per the deferred-visibility
-- gotcha: ALTER TYPE ADD VALUE entries are not usable in the same migration
-- that adds them.
--
--   * audit.subject_type_enum            +REDACTION_POLICY
--     (subject for AI_REDACTION_POLICY_* audit events)
--   * ai_gateway_invocation_status_enum  +COMPLETED_REDACTION_REJECTED
--     (terminal state for invocations rejected by the redaction step)
--   * ai_gateway_result_variant_enum     +REDACTION_REJECTED
--     (canonical AIResult variant returned in the envelope)
--
-- These were removed by the B06·P02 fix-up (20260521000026) because P02 had
-- no code path producing them. P03's main migration (20260521000028) wires
-- the redaction step that does produce them.

ALTER TYPE audit.subject_type_enum
  ADD VALUE IF NOT EXISTS 'REDACTION_POLICY';

ALTER TYPE public.ai_gateway_invocation_status_enum
  ADD VALUE IF NOT EXISTS 'COMPLETED_REDACTION_REJECTED';

ALTER TYPE public.ai_gateway_result_variant_enum
  ADD VALUE IF NOT EXISTS 'REDACTION_REJECTED';
