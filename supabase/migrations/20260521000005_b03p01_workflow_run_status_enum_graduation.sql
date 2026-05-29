-- B03·P01 Part 1: workflow_run_status enum graduation
-- =============================================================================
-- ALTER TYPE ADD VALUE has deferred visibility — the new value can't be used
-- in CHECK constraints in the SAME transaction (per the gotcha drawer in
-- mempalace). Splitting into two migrations guarantees the new enum value
-- commits before subsequent migrations reference it.
--
-- 1. Add ABORTED to the existing stub enum (preserves FAILED/CANCELLED/COMPENSATING
--    which B04·P06 write_processing_artifact uses for TTL calculation).
-- 2. Rename in place: workflow_run_status_stub_enum → workflow_run_status_enum.
--    All existing references (workflow_runs.status column, B04·P06 RPC parameter
--    type) resolve to the renamed type automatically.
-- =============================================================================

ALTER TYPE public.workflow_run_status_stub_enum ADD VALUE IF NOT EXISTS 'ABORTED';
ALTER TYPE public.workflow_run_status_stub_enum RENAME TO workflow_run_status_enum;
