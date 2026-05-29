-- B06·P04 — Prompt Management (migration 1 of 2)
--
-- Adds PROMPT to audit.subject_type_enum. Standalone per the deferred-visibility
-- gotcha; the main P04 migration uses this value as subject_type for all
-- AI_PROMPT_* audit events (REGISTERED / DEPLOYED / ROLLED_BACK / REGRESSION_FAILED
-- / PROMOTION_OVERRIDE_USED / REGISTER_REJECTED / DEPLOY_REJECTED).

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'PROMPT';
