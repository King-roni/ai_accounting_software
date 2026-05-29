-- B03·P09 Part 1: subject_type extension (deferred visibility split)
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'TRIGGER_EVENT';
