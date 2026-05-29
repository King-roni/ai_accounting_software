-- B03·P03 Part 1: subject_type extension (deferred visibility split)
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'TOOL_REGISTRY';
