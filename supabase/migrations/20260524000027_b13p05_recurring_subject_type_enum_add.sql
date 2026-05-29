-- Block 13 Phase 05 (BOOK-120) — pre-migration: add new subject_type values.
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'RECURRING_INVOICE_TEMPLATE';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'RECURRING_INVOICE_RUN';
