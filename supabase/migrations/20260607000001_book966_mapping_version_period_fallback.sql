-- =============================================================================
-- BOOK-966 — chart mapping version: fall back to earliest version for periods
-- that predate every version (onboard-now / process-last-month).
-- =============================================================================
-- A business seeded today gets a mapping version with effective_from = now(),
-- so chart_resolve_mapping_version returned NULL for any PRIOR-month period →
-- LEDGER_PREPARATION raised NO_ACTIVE_MAPPING_VERSION_FOR_PERIOD, produced 0
-- draft entries, and the run could never finalize (the normal first-run case).
--
-- Fix (general, low-risk): prefer the latest version effective on/before the
-- period; if the period predates every version, fall back to the EARLIEST
-- version (the initial chart). A later version with a real effective_from still
-- supersedes it going forward. This fixes every business without rewriting the
-- 200-line seed loader.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.chart_resolve_mapping_version(
  p_business_id uuid, p_period_start timestamp with time zone)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT id FROM (
    SELECT id, 0 AS pref, effective_from, version_number
      FROM public.chart_of_accounts_mapping_versions
     WHERE business_id = p_business_id AND effective_from <= p_period_start
    UNION ALL
    SELECT id, 1 AS pref, effective_from, version_number
      FROM public.chart_of_accounts_mapping_versions
     WHERE business_id = p_business_id
  ) v
  ORDER BY pref ASC,
           CASE WHEN pref = 0 THEN effective_from END DESC NULLS LAST,
           CASE WHEN pref = 1 THEN effective_from END ASC  NULLS LAST,
           CASE WHEN pref = 0 THEN version_number END DESC NULLS LAST,
           CASE WHEN pref = 1 THEN version_number END ASC  NULLS LAST
  LIMIT 1;
$function$;
