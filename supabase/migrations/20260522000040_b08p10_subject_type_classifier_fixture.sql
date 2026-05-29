-- B08·P10 step 1 of 2 — extend audit.subject_type_enum with CLASSIFIER_FIXTURE.
-- Split into its own migration to dodge the ALTER TYPE deferred-visibility rule.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CLASSIFIER_FIXTURE';
