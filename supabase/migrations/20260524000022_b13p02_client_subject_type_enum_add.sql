-- Block 13 Phase 02 (BOOK-117) — pre-migration: add CLIENT to audit.subject_type_enum
-- so the next migration can reference it without hitting ALTER TYPE deferred visibility.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CLIENT';
