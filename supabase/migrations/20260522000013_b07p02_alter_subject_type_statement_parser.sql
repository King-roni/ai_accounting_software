-- B07·P02 — Subject type addition for parser registry events.
--
-- STATEMENT_PARSER is the subject of STATEMENT_PARSER_REGISTERED audit events.
-- The parse lifecycle events (STATEMENT_PARSE_STARTED / _COMPLETED / _FAILED)
-- target the existing STATEMENT_UPLOAD subject and carry parse_run_id in
-- after_state — the user-facing object is the upload, not the parse run.
--
-- Split into its own file because ALTER TYPE ADD VALUE has deferred visibility
-- inside the same migration / transaction (the new value can't be used until
-- a new transaction starts).

ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'STATEMENT_PARSER';
