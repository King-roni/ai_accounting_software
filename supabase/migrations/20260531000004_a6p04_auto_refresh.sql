-- ============================================================================
-- A6.4b (R6 · Analytics Projections) — Auto-refresh on data change.
--
-- Keeps the analytics.* projections current without a manual "Refresh now":
--   • Cheap AFTER-ROW triggers on the operational source tables mark the
--     business's projection STALE (sentinel = analytics.income_overview.refresh_state).
--     Guarded so a bulk write only does real work once (rest are 0-row updates).
--   • The read path (dashboard_analytics_card / _drill_down_analytics) lazily
--     recomputes when stale, serialized per-business by an xact advisory lock so
--     concurrent card reads don't stampede — one refreshes, the rest read fresh.
-- This marks-many / refreshes-once design avoids recomputing on every row write
-- (e.g. confirming 50 matches marks stale 50× but refreshes a single time).
-- ============================================================================

-- Sentinel-based staleness marker fired by source-table changes.
CREATE OR REPLACE FUNCTION analytics.tg_mark_projections_stale()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'analytics', 'pg_temp'
AS $$
DECLARE v_biz uuid;
BEGIN
  v_biz := COALESCE(NEW.business_id, OLD.business_id);
  IF v_biz IS NOT NULL THEN
    UPDATE analytics.income_overview SET refresh_state = 'STALE'
     WHERE business_id = v_biz AND refresh_state <> 'STALE';
  END IF;
  RETURN NULL;
END;
$$;
COMMENT ON FUNCTION analytics.tg_mark_projections_stale() IS 'R6/A6.4b: mark a business analytics projections STALE on operational data change.';

-- Lazy refresher: recompute a business projections iff stale (or never built),
-- serialized per-business so concurrent dashboard card reads refresh at most once.
CREATE OR REPLACE FUNCTION analytics.refresh_if_stale(p_business_ids uuid[])
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'analytics', 'public', 'pg_temp'
AS $$
DECLARE b uuid;
BEGIN
  FOREACH b IN ARRAY COALESCE(p_business_ids, ARRAY[]::uuid[]) LOOP
    PERFORM pg_advisory_xact_lock(hashtext('analytics_refresh'), hashtext(b::text));
    IF NOT EXISTS (SELECT 1 FROM analytics.income_overview WHERE business_id = b AND refresh_state = 'FRESH') THEN
      PERFORM analytics.refresh_business(b, NULL, 'auto-stale', NULL);
    END IF;
  END LOOP;
END;
$$;

-- Attach the staleness trigger to every operational table that feeds a projection.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'transactions', 'draft_ledger_entries', 'invoices', 'review_issues',
    'recurring_vendor_memory', 'archive_packages', 'workflow_runs'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_analytics_mark_stale ON public.%I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_analytics_mark_stale AFTER INSERT OR UPDATE OR DELETE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION analytics.tg_mark_projections_stale()', t);
  END LOOP;
END;
$$;

-- Make the read functions refresh-if-stale before reading (now VOLATILE).
CREATE OR REPLACE FUNCTION public.dashboard_analytics_card(p_card_id text, p_business_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'analytics', 'pg_temp'
AS $$
DECLARE v jsonb;
BEGIN
  PERFORM analytics.refresh_if_stale(p_business_ids);

  IF p_card_id = 'income_overview' THEN
    SELECT jsonb_build_object('mtd', COALESCE(sum(mtd_income), 0), 'rolling_12m', COALESCE(sum(rolling_12m_income), 0),
      'monthly_series', COALESCE((SELECT jsonb_agg(jsonb_build_object('month', mth, 'value', val) ORDER BY mth)
        FROM (SELECT e->>'month' AS mth, sum((e->>'value')::numeric) AS val FROM analytics.income_overview io2, jsonb_array_elements(io2.monthly_series) e WHERE io2.business_id = ANY(p_business_ids) GROUP BY 1) z), '[]'::jsonb),
      'last_refreshed_at', max(last_refreshed_at)) INTO v FROM analytics.income_overview WHERE business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'expense_overview' THEN
    SELECT jsonb_build_object('mtd', COALESCE(sum(mtd_expense), 0), 'rolling_12m', COALESCE(sum(rolling_12m_expense), 0),
      'monthly_series', COALESCE((SELECT jsonb_agg(jsonb_build_object('month', mth, 'value', val) ORDER BY mth)
        FROM (SELECT e->>'month' AS mth, sum((e->>'value')::numeric) AS val FROM analytics.expense_overview eo2, jsonb_array_elements(eo2.monthly_series) e WHERE eo2.business_id = ANY(p_business_ids) GROUP BY 1) z), '[]'::jsonb),
      'last_refreshed_at', max(last_refreshed_at)) INTO v FROM analytics.expense_overview WHERE business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'vat_summary' THEN
    SELECT jsonb_build_object('output_vat', COALESCE(sum(output_vat), 0), 'input_vat', COALESCE(sum(input_vat), 0),
      'net_position', COALESCE(sum(net_position), 0), 'last_refreshed_at', max(last_refreshed_at)) INTO v FROM analytics.vat_summary WHERE business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'subscription_recurring_totals' THEN
    SELECT jsonb_build_object('total_monthly', COALESCE(sum((recurring_by_supplier->>'total_monthly')::numeric), 0),
      'vendor_count', COALESCE(sum((recurring_by_supplier->>'vendor_count')::int), 0),
      'suppliers', COALESCE((SELECT jsonb_agg(s ORDER BY (s->>'amount')::numeric DESC) FROM analytics.subscriptions_overview so2, jsonb_array_elements(so2.recurring_by_supplier->'suppliers') s WHERE so2.business_id = ANY(p_business_ids)), '[]'::jsonb),
      'last_refreshed_at', max(last_refreshed_at)) INTO v FROM analytics.subscriptions_overview WHERE business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'client_invoice_aging' THEN
    SELECT jsonb_build_object('total_outstanding', COALESCE(sum((per_client_aging->>'total_outstanding')::numeric), 0),
      'buckets', jsonb_build_object('current', COALESCE(sum((per_client_aging->'buckets'->>'current')::numeric), 0),
        'd1_30', COALESCE(sum((per_client_aging->'buckets'->>'d1_30')::numeric), 0),
        'd31_60', COALESCE(sum((per_client_aging->'buckets'->>'d31_60')::numeric), 0),
        'd60_plus', COALESCE(sum((per_client_aging->'buckets'->>'d60_plus')::numeric), 0)),
      'last_refreshed_at', max(last_refreshed_at)) INTO v FROM analytics.client_invoice_status WHERE business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'evidence_collection_status' THEN
    SELECT jsonb_build_object('outstanding_count', COALESCE(sum(md.outstanding_count), 0),
      'total_transactions', (SELECT count(*) FROM public.transactions WHERE business_id = ANY(p_business_ids)),
      'last_refreshed_at', max(md.last_refreshed_at)) INTO v FROM analytics.missing_documents md WHERE md.business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'tax_treatment_breakdown' THEN
    SELECT jsonb_build_object('treatments', COALESCE(jsonb_agg(jsonb_build_object('treatment', t, 'amount', amt, 'count', cnt) ORDER BY amt DESC), '[]'::jsonb))
    INTO v FROM (SELECT vat_treatment::text AS t, COALESCE(sum(COALESCE(debit_amount, credit_amount, 0)), 0) AS amt, count(*) AS cnt FROM public.draft_ledger_entries WHERE business_id = ANY(p_business_ids) GROUP BY vat_treatment) z;
  ELSE v := '{}'::jsonb;
  END IF;
  RETURN COALESCE(v, '{}'::jsonb);
END;
$$;
GRANT EXECUTE ON FUNCTION public.dashboard_analytics_card(text, uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public._drill_down_analytics(p_card_id text, p_business_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'analytics', 'pg_temp'
AS $$
DECLARE v jsonb;
BEGIN
  PERFORM analytics.refresh_if_stale(p_business_ids);

  IF p_card_id = 'vat_summary' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', period_start::text, 'business_id', business_id, 'source', 'ANALYTICS',
      'payload', jsonb_build_object('title', to_char(period_start, 'Mon YYYY'), 'amount', net_position, 'output_vat', output_vat, 'input_vat', input_vat, 'period_start', period_start)) ORDER BY period_start DESC), '[]'::jsonb)
    INTO v FROM analytics.vat_summary WHERE business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'income_overview' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', mth, 'business_id', null, 'source', 'ANALYTICS',
      'payload', jsonb_build_object('title', mth, 'amount', val, 'transaction_date', mth || '-01')) ORDER BY mth DESC), '[]'::jsonb)
    INTO v FROM (SELECT e->>'month' AS mth, sum((e->>'value')::numeric) AS val FROM analytics.income_overview io, jsonb_array_elements(io.monthly_series) e WHERE io.business_id = ANY(p_business_ids) GROUP BY 1) z;
  ELSIF p_card_id = 'expense_overview' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', mth, 'business_id', null, 'source', 'ANALYTICS',
      'payload', jsonb_build_object('title', mth, 'amount', val, 'transaction_date', mth || '-01')) ORDER BY mth DESC), '[]'::jsonb)
    INTO v FROM (SELECT e->>'month' AS mth, sum((e->>'value')::numeric) AS val FROM analytics.expense_overview eo, jsonb_array_elements(eo.monthly_series) e WHERE eo.business_id = ANY(p_business_ids) GROUP BY 1) z;
  ELSIF p_card_id = 'subscription_recurring_totals' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', COALESCE(s->>'tag', 'vendor'), 'business_id', null, 'source', 'ANALYTICS',
      'payload', jsonb_build_object('title', COALESCE(s->>'tag', 'Vendor'), 'amount', (s->>'amount')::numeric, 'confirmations', (s->>'confirmations'))) ORDER BY (s->>'amount')::numeric DESC), '[]'::jsonb)
    INTO v FROM analytics.subscriptions_overview so, jsonb_array_elements(so.recurring_by_supplier->'suppliers') s WHERE so.business_id = ANY(p_business_ids);
  ELSIF p_card_id = 'client_invoice_aging' THEN
    WITH agg AS (SELECT COALESCE(sum((per_client_aging->'buckets'->>'current')::numeric), 0) AS c,
             COALESCE(sum((per_client_aging->'buckets'->>'d1_30')::numeric), 0) AS d1,
             COALESCE(sum((per_client_aging->'buckets'->>'d31_60')::numeric), 0) AS d2,
             COALESCE(sum((per_client_aging->'buckets'->>'d60_plus')::numeric), 0) AS d3
        FROM analytics.client_invoice_status WHERE business_id = ANY(p_business_ids))
    SELECT jsonb_build_array(
      jsonb_build_object('id', 'current', 'business_id', null, 'source', 'ANALYTICS', 'payload', jsonb_build_object('title', 'Current', 'amount', c)),
      jsonb_build_object('id', 'd1_30', 'business_id', null, 'source', 'ANALYTICS', 'payload', jsonb_build_object('title', '1-30 days', 'amount', d1)),
      jsonb_build_object('id', 'd31_60', 'business_id', null, 'source', 'ANALYTICS', 'payload', jsonb_build_object('title', '31-60 days', 'amount', d2)),
      jsonb_build_object('id', 'd60_plus', 'business_id', null, 'source', 'ANALYTICS', 'payload', jsonb_build_object('title', '60+ days', 'amount', d3))) INTO v FROM agg;
  ELSIF p_card_id = 'tax_treatment_breakdown' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', t, 'business_id', null, 'source', 'ANALYTICS',
      'payload', jsonb_build_object('title', replace(t, '_', ' '), 'amount', amt, 'count', cnt)) ORDER BY amt DESC), '[]'::jsonb)
    INTO v FROM (SELECT vat_treatment::text AS t, sum(COALESCE(debit_amount, credit_amount, 0)) AS amt, count(*) AS cnt FROM public.draft_ledger_entries WHERE business_id = ANY(p_business_ids) GROUP BY vat_treatment) z;
  ELSIF p_card_id = 'evidence_collection_status' THEN
    SELECT jsonb_build_array(jsonb_build_object('id', 'evidence', 'business_id', null, 'source', 'ANALYTICS',
      'payload', jsonb_build_object('title', 'Transactions awaiting evidence', 'count', COALESCE(sum(outstanding_count), 0))))
    INTO v FROM analytics.missing_documents WHERE business_id = ANY(p_business_ids);
  ELSE v := '[]'::jsonb;
  END IF;
  RETURN COALESCE(v, '[]'::jsonb);
END;
$$;
