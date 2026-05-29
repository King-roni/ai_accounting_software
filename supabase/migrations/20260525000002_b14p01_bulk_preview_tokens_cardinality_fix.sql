-- B14·P01 fix-up: array_length returns NULL for empty arrays, which makes
-- `NULL >= 1` evaluate to UNKNOWN → CHECK lets the row through. Switch the
-- non-empty guards on both new tables to cardinality(), which returns 0
-- for an empty array (and so the >= 1 comparison evaluates FALSE → REJECT).

ALTER TABLE public.bulk_preview_tokens
  DROP CONSTRAINT bulk_preview_tokens_affected_ids_nonempty_chk;

ALTER TABLE public.bulk_preview_tokens
  ADD CONSTRAINT bulk_preview_tokens_affected_ids_nonempty_chk
  CHECK (cardinality(affected_issue_ids) >= 1);

ALTER TABLE public.issue_type_registry
  DROP CONSTRAINT issue_type_registry_allowed_actions_nonempty_chk;

ALTER TABLE public.issue_type_registry
  ADD CONSTRAINT issue_type_registry_allowed_actions_nonempty_chk
  CHECK (cardinality(allowed_resolution_actions) >= 1);
