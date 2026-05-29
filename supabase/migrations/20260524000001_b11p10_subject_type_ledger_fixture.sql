-- B11·P10 part 1 of 2 — add LEDGER_FIXTURE to audit.subject_type_enum.
-- Split for deferred enum visibility (ALTER TYPE ADD VALUE not visible in
-- same transaction). Same pattern as B09·P10 / B10·P10 / B11·P02 / B11·P05.

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'LEDGER_FIXTURE';
