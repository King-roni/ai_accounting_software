-- B03·P05 Part 1: subject_type extension (deferred visibility split)
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'GATE_REGISTRY';
