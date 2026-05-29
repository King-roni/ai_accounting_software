-- B16·P12 — Add SYSTEM_OBSERVABILITY to audit.subject_type_enum
-- Deferred-visibility split — used in 20260526000037_b16p12_accessibility_i18n_mobile_performance.sql.
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'SYSTEM_OBSERVABILITY';
