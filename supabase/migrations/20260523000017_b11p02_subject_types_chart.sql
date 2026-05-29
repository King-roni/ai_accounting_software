-- B11·P02 part 1 of 2 — add CHART_* subject_types to audit.subject_type_enum.
-- Split into its own migration because ALTER TYPE ADD VALUE values are not
-- visible inside the same transaction that adds them (deferred visibility).
-- Same pattern as B09·P10 / B10·P10.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CHART_OF_ACCOUNTS_ENTRY';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CHART_MAPPING_RULE';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CHART_MAPPING_VERSION';
