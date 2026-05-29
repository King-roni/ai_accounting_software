-- B03·P02 Part 1: subject_type extension (deferred visibility split)
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'WORKFLOW_CONFIG';
