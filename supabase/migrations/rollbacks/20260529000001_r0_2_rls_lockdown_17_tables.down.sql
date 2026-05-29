-- Rollback for 20260529000001_r0_2_rls_lockdown_17_tables.sql
-- Restores the prior (pre-R0.2) state: RLS off + the original anon/authenticated
-- grants. Only run if the lockdown must be reverted.

-- Category A
DROP POLICY IF EXISTS dashboard_card_definitions_select_all_authenticated ON public.dashboard_card_definitions;
DROP POLICY IF EXISTS dashboard_card_definitions_no_insert ON public.dashboard_card_definitions;
DROP POLICY IF EXISTS dashboard_card_definitions_no_update ON public.dashboard_card_definitions;
DROP POLICY IF EXISTS dashboard_card_definitions_no_delete ON public.dashboard_card_definitions;
ALTER TABLE public.dashboard_card_definitions DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.dashboard_card_definitions TO anon, authenticated;

DROP POLICY IF EXISTS export_catalogue_definitions_select_all_authenticated ON public.export_catalogue_definitions;
DROP POLICY IF EXISTS export_catalogue_definitions_no_insert ON public.export_catalogue_definitions;
DROP POLICY IF EXISTS export_catalogue_definitions_no_update ON public.export_catalogue_definitions;
DROP POLICY IF EXISTS export_catalogue_definitions_no_delete ON public.export_catalogue_definitions;
ALTER TABLE public.export_catalogue_definitions DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.export_catalogue_definitions TO anon, authenticated;

DROP POLICY IF EXISTS pdf_generator_registry_select_all_authenticated ON public.pdf_generator_registry;
DROP POLICY IF EXISTS pdf_generator_registry_no_insert ON public.pdf_generator_registry;
DROP POLICY IF EXISTS pdf_generator_registry_no_update ON public.pdf_generator_registry;
DROP POLICY IF EXISTS pdf_generator_registry_no_delete ON public.pdf_generator_registry;
ALTER TABLE public.pdf_generator_registry DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.pdf_generator_registry TO anon, authenticated;

-- Category B (were granted to anon+authenticated, except pipeline_* which were service_role-only)
ALTER TABLE public.classifier_fixtures DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.classifier_fixtures TO anon, authenticated;
ALTER TABLE public.classifier_fixture_runs DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.classifier_fixture_runs TO anon, authenticated;
ALTER TABLE public.ledger_fixtures DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.ledger_fixtures TO anon, authenticated;
ALTER TABLE public.ledger_fixture_runs DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.ledger_fixture_runs TO anon, authenticated;
ALTER TABLE public.matching_fixtures DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.matching_fixtures TO anon, authenticated;
ALTER TABLE public.matching_fixture_runs DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.matching_fixture_runs TO anon, authenticated;
ALTER TABLE public.pipeline_fixtures DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.pipeline_fixture_runs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.finalization_fixture_registry DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.finalization_fixture_registry TO anon, authenticated;
ALTER TABLE public.in_workflow_fixture_registry DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.in_workflow_fixture_registry TO anon, authenticated;
ALTER TABLE public.out_workflow_fixture_registry DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.out_workflow_fixture_registry TO anon, authenticated;
ALTER TABLE public.review_queue_fixture_registry DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.review_queue_fixture_registry TO anon, authenticated;

-- Category C (were granted to authenticated)
ALTER TABLE auth_runtime.sensitive_surfaces DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON auth_runtime.sensitive_surfaces TO authenticated;
ALTER TABLE secrets.secret_policies DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON secrets.secret_policies TO authenticated;
