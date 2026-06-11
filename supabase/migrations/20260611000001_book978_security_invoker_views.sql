-- =============================================================================
-- BOOK-978 — read-model views bypass tenant RLS (cross-tenant + anon leak).
-- =============================================================================
-- The public.v_* read-model views (and ai_usage_run_totals) were created without
-- `security_invoker = true`, so they execute with the view OWNER's privileges and
-- bypass RLS on their base tables. None self-filter by the caller, and they were
-- granted SELECT to both `authenticated` and `anon`. Result: any authenticated
-- user — or any unauthenticated caller with the anon key — could read every
-- tenant's review issues, blocking issues, finalization readiness, invoices, AI
-- usage and archive manifests by selecting the view without a business_id filter.
--
-- Proof (live): as role `authenticated` (and as `anon`), SELECT count(*) FROM
-- public.v_review_issue_card returned 98 — all review issues across BOTH tenant
-- businesses — while the RLS-protected base table review_issues returned 0 for the
-- same caller. The base tables are correctly scoped
-- (organization_id = current_org() AND business_id = ANY(current_user_businesses()));
-- the views simply never applied it.
--
-- Fix: flip every flagged view to `security_invoker = true` so the querying user's
-- RLS applies to the base tables, and REVOKE the anon SELECT grant (none of these
-- are public — the app authenticates). Consumption patterns are preserved:
--   * direct authenticated reads (e.g. v_archive_package_latest_manifest in the
--     adjustment panel) — base tables have authenticated SELECT policies, so the
--     caller still sees their own business's rows;
--   * SECURITY DEFINER RPCs that read these views internally — the RPC still runs
--     as its owner (RLS-bypassing) and filters by the business_id it was passed;
--   * the worker / service_role — BYPASSRLS, unaffected.
-- This also clears the 17 `security_definer_view` ERROR security-advisor findings.
-- =============================================================================

DO $$
DECLARE
  v_view text;
  v_views constant text[] := ARRAY[
    'ai_usage_run_totals',
    'v_active_review_queue',
    'v_archive_package_latest_manifest',
    'v_assignee_inbox',
    'v_blocking_issues',
    'v_bulk_preview_token_status',
    'v_dashboard_fixture_coverage',
    'v_finalization_fixture_coverage',
    'v_finalization_readiness',
    'v_in_workflow_fixture_coverage',
    'v_invoices_with_adjustments',
    'v_issue_resolution_options',
    'v_issue_type_coverage',
    'v_ready_to_finalize_runs',
    'v_review_issue_card',
    'v_review_queue_fixture_coverage',
    'v_snoozed_review_queue'
  ];
BEGIN
  FOREACH v_view IN ARRAY v_views LOOP
    IF to_regclass(format('public.%I', v_view)) IS NULL THEN
      RAISE EXCEPTION 'BOOK-978: expected view public.% not found', v_view;
    END IF;
    EXECUTE format('ALTER VIEW public.%I SET (security_invoker = true)', v_view);
    -- Defense in depth: tenant read-models are never public. The querying-user
    -- RLS already returns 0 rows for anon once security_invoker is on, but drop
    -- the grant so a future anon base-table policy can't re-open the hole.
    EXECUTE format('REVOKE SELECT ON public.%I FROM anon', v_view);
  END LOOP;
END $$;
