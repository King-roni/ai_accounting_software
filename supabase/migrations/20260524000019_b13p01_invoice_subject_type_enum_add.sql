-- Block 13 Phase 01 (BOOK-116) — pre-migration: add subject_type values.
-- ALTER TYPE ADD VALUE has deferred visibility within the same migration; values
-- used in the same statement-list are not yet "committed" to the type. Split off
-- here so the next migration (`20260524000020_b13p01_invoice_schema_and_numbering`)
-- can use INVOICE / CREDIT_NOTE / INVOICE_SEQUENCE_COUNTER as audit subject_type.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'INVOICE';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'INVOICE_LINE';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CREDIT_NOTE';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'INVOICE_SEQUENCE_COUNTER';
