-- B09·P10 (part 1/2) — Add INTAKE_FIXTURE to audit.subject_type_enum.
-- ALTER TYPE ADD VALUE has deferred visibility within the same migration,
-- so the enum value MUST be added in its own migration before being used
-- in any function body or CHECK constraint.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'INTAKE_FIXTURE';
