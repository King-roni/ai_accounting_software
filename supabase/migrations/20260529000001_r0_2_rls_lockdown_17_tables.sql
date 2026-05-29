-- R0.2 — Resolve 17 RLS-disabled tables (live security exposure)
-- Supabase security advisor flagged 17 tables with RLS off, reachable by
-- anon/authenticated. Per-table decision (NOT a blanket enable):
--   A) Global definition tables consumed by the app via RPC → RLS on,
--      SELECT to authenticated, deny writes, revoke anon. Matches the
--      tool_registry/gate_registry/issue_type_registry convention.
--   B) Test/E2E fixtures + fixture-run tables (backend/test only) → RLS on,
--      no policy, revoke anon+authenticated. service_role bypasses RLS.
--   C) Security-config tables → RLS on, no policy, revoke authenticated.
--      service_role bypasses RLS; SECURITY DEFINER RPCs (owned by postgres)
--      bypass RLS.
-- Verified 2026-05-29: no web/api source reads these tables directly; the only
-- live frontend (B02 auth) does not touch them, so no surface breaks.
-- Applied to live via apply_migration r0_2_rls_lockdown_17_tables.
-- Rollback: ALTER TABLE ... DISABLE ROW LEVEL SECURITY; DROP POLICY ...;
--           GRANT SELECT ... (re-grant prior grants). See rollbacks/ if added.

-- ============================================================
-- Category A: global definition tables (RLS on, read-only for authenticated)
-- ============================================================
ALTER TABLE public.dashboard_card_definitions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dashboard_card_definitions_select_all_authenticated ON public.dashboard_card_definitions;
CREATE POLICY dashboard_card_definitions_select_all_authenticated ON public.dashboard_card_definitions FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS dashboard_card_definitions_no_insert ON public.dashboard_card_definitions;
CREATE POLICY dashboard_card_definitions_no_insert ON public.dashboard_card_definitions FOR INSERT TO authenticated WITH CHECK (false);
DROP POLICY IF EXISTS dashboard_card_definitions_no_update ON public.dashboard_card_definitions;
CREATE POLICY dashboard_card_definitions_no_update ON public.dashboard_card_definitions FOR UPDATE TO authenticated USING (false);
DROP POLICY IF EXISTS dashboard_card_definitions_no_delete ON public.dashboard_card_definitions;
CREATE POLICY dashboard_card_definitions_no_delete ON public.dashboard_card_definitions FOR DELETE TO authenticated USING (false);
REVOKE ALL ON public.dashboard_card_definitions FROM anon;

ALTER TABLE public.export_catalogue_definitions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS export_catalogue_definitions_select_all_authenticated ON public.export_catalogue_definitions;
CREATE POLICY export_catalogue_definitions_select_all_authenticated ON public.export_catalogue_definitions FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS export_catalogue_definitions_no_insert ON public.export_catalogue_definitions;
CREATE POLICY export_catalogue_definitions_no_insert ON public.export_catalogue_definitions FOR INSERT TO authenticated WITH CHECK (false);
DROP POLICY IF EXISTS export_catalogue_definitions_no_update ON public.export_catalogue_definitions;
CREATE POLICY export_catalogue_definitions_no_update ON public.export_catalogue_definitions FOR UPDATE TO authenticated USING (false);
DROP POLICY IF EXISTS export_catalogue_definitions_no_delete ON public.export_catalogue_definitions;
CREATE POLICY export_catalogue_definitions_no_delete ON public.export_catalogue_definitions FOR DELETE TO authenticated USING (false);
REVOKE ALL ON public.export_catalogue_definitions FROM anon;

ALTER TABLE public.pdf_generator_registry ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pdf_generator_registry_select_all_authenticated ON public.pdf_generator_registry;
CREATE POLICY pdf_generator_registry_select_all_authenticated ON public.pdf_generator_registry FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS pdf_generator_registry_no_insert ON public.pdf_generator_registry;
CREATE POLICY pdf_generator_registry_no_insert ON public.pdf_generator_registry FOR INSERT TO authenticated WITH CHECK (false);
DROP POLICY IF EXISTS pdf_generator_registry_no_update ON public.pdf_generator_registry;
CREATE POLICY pdf_generator_registry_no_update ON public.pdf_generator_registry FOR UPDATE TO authenticated USING (false);
DROP POLICY IF EXISTS pdf_generator_registry_no_delete ON public.pdf_generator_registry;
CREATE POLICY pdf_generator_registry_no_delete ON public.pdf_generator_registry FOR DELETE TO authenticated USING (false);
REVOKE ALL ON public.pdf_generator_registry FROM anon;

-- ============================================================
-- Category B: test/E2E fixtures and fixture-run tables (service_role only)
-- ============================================================
ALTER TABLE public.classifier_fixtures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.classifier_fixtures FROM anon, authenticated;
ALTER TABLE public.classifier_fixture_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.classifier_fixture_runs FROM anon, authenticated;
ALTER TABLE public.ledger_fixtures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ledger_fixtures FROM anon, authenticated;
ALTER TABLE public.ledger_fixture_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ledger_fixture_runs FROM anon, authenticated;
ALTER TABLE public.matching_fixtures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.matching_fixtures FROM anon, authenticated;
ALTER TABLE public.matching_fixture_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.matching_fixture_runs FROM anon, authenticated;
ALTER TABLE public.pipeline_fixtures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pipeline_fixtures FROM anon, authenticated;
ALTER TABLE public.pipeline_fixture_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pipeline_fixture_runs FROM anon, authenticated;
ALTER TABLE public.finalization_fixture_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.finalization_fixture_registry FROM anon, authenticated;
ALTER TABLE public.in_workflow_fixture_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.in_workflow_fixture_registry FROM anon, authenticated;
ALTER TABLE public.out_workflow_fixture_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.out_workflow_fixture_registry FROM anon, authenticated;
ALTER TABLE public.review_queue_fixture_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.review_queue_fixture_registry FROM anon, authenticated;

-- ============================================================
-- Category C: security-config tables (service_role only)
-- ============================================================
ALTER TABLE auth_runtime.sensitive_surfaces ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON auth_runtime.sensitive_surfaces FROM authenticated;
ALTER TABLE secrets.secret_policies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON secrets.secret_policies FROM authenticated;
