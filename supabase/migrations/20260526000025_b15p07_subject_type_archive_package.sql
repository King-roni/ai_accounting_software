-- B15·P07 fix-up: audit.subject_type_enum had ARCHIVE_RUN but no ARCHIVE_PACKAGE.
-- New audit emissions in P07 (verify_archive_package, log_archive_data_read,
-- accept_archive_tamper, FINALIZATION_OBJECT_LOCK_APPLIED) target archive
-- packages as their subject. Add the enum value as a separate migration
-- since ALTER TYPE ADD VALUE has deferred visibility within the same tx.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'ARCHIVE_PACKAGE';
