-- Block 13 Phase 11 (BOOK-126) — pre-migration: add IN-specific delta kinds.
-- ALTER TYPE ADD VALUE has deferred visibility; split into a pre-migration so
-- the next migration can use the new values in the same statement-list.

ALTER TYPE public.adjustment_delta_kind_enum ADD VALUE IF NOT EXISTS 'RETROACTIVE_CREDIT_NOTE';
ALTER TYPE public.adjustment_delta_kind_enum ADD VALUE IF NOT EXISTS 'CORRECT_PAYMENT_ALLOCATION';
ALTER TYPE public.adjustment_delta_kind_enum ADD VALUE IF NOT EXISTS 'MARK_INVOICE_WRITTEN_OFF';
