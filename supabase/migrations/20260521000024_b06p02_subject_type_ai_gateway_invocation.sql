-- B06·P02 — Privacy Gateway Pipeline (migration 1 of 2)
--
-- Adds AI_GATEWAY_INVOCATION to audit.subject_type_enum. Standalone migration
-- to satisfy ALTER TYPE deferred-visibility (the value is used in the main
-- migration as subject_type for AI_GATEWAY_INVOKED / AI_GATEWAY_VALIDATION_FAILED
-- / AI_GATEWAY_RESPONSE_INVALID).

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'AI_GATEWAY_INVOCATION';
