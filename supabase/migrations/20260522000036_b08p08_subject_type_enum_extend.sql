-- B08·P08 fix-up #3 (step 1 of 2 — enum extension, deferred visibility)
-- Add subject_type values for taxonomy lifecycle. Functions that reference these
-- values are (re)created in the immediately following migration.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'TAG_TAXONOMY_VERSION';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'BUSINESS_TAG_TAXONOMY_ASSIGNMENT';
