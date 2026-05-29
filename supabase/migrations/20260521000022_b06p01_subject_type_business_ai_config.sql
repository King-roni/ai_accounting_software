-- B06·P01 — Tier Classification & Routing (migration 1 of 2)
--
-- Adds BUSINESS_AI_CONFIG to audit.subject_type_enum. Standalone migration to
-- satisfy the deferred-visibility gotcha: ALTER TYPE ADD VALUE values are not
-- usable in the same transaction. The main B06·P01 migration (next file) uses
-- this label inside `update_business_ai_config` for AI_TIER_CONFIG_UPDATED.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'BUSINESS_AI_CONFIG';
