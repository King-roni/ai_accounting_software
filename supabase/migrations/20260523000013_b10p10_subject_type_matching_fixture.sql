-- B10·P10 part 1 of 2 — add MATCHING_FIXTURE to audit.subject_type_enum.
-- Split into its own migration because ALTER TYPE ADD VALUE values are
-- not visible inside the same transaction that adds them (deferred visibility).
-- Same pattern as B09·P10's subject_type_intake_fixture migration.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'MATCHING_FIXTURE';
