-- B15·P01 fix-up: GRANTs are needed so RLS actually runs the policy checks.
-- Without explicit GRANTs, authenticated gets 42501 at the privilege check
-- before RLS evaluates, which is the wrong layer. The spec's Layer-1
-- intent is RLS-based denial, so we grant SELECT/INSERT/UPDATE/DELETE
-- to authenticated and let the policies do the actual blocking.

GRANT SELECT, INSERT, UPDATE, DELETE ON public.archive_packages   TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.archive_manifests  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.archive_files      TO authenticated;
GRANT USAGE ON SCHEMA archive TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON archive.locked_ledger_entries TO authenticated;
