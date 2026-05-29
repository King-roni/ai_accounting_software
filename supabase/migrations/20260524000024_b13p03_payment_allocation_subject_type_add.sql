-- Block 13 Phase 03 (BOOK-118) — pre-migration: add INVOICE_PAYMENT_ALLOCATION
-- to audit.subject_type_enum to navigate ALTER TYPE deferred visibility.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'INVOICE_PAYMENT_ALLOCATION';
