-- Block 13 Phase 05 (BOOK-120) — pre-migration: add EXPIRED_UNCONVERTED to
-- invoice_lifecycle_status_enum (12th value; terminal pro-forma state).
ALTER TYPE public.invoice_lifecycle_status_enum ADD VALUE IF NOT EXISTS 'EXPIRED_UNCONVERTED';
