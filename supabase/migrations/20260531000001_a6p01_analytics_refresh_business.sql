-- ============================================================================
-- A6.1 (R6 · Analytics Projections) — Real analytics aggregation.
--
-- The analytics.* projection tables existed but were never populated: the
-- canonical orchestrator analytics.refresh_business(...) only stamped
-- refresh_state='FRESH' via a generic loop (no metric computation) and skipped
-- the period-keyed tables, and analytics.aggregate_tables_*() just returned
-- table names. This installs the real metric computation and rewires the
-- orchestrator to call it, so the dashboard's "Awaiting data" cards can render
-- live metrics (read path: A6.2).
--
-- analytics.compute_business_projections(org, business) — bespoke per-table
--   aggregation from operational data. Idempotent upserts on each table's PK.
-- analytics.refresh_business(business, source_run_id, actor_system, actor_user) —
--   canonical orchestrator: resolves org, computes, emits the analytics_events
--   audit row (ANALYTICS_REBUILD_COMPLETED / _FAILED). Same signature as before.
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.compute_business_projections(p_organization_id uuid, p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'analytics', 'public', 'pg_temp'
AS $$
DECLARE
  v_now       timestamptz := clock_timestamp();
  v_cur_month date := date_trunc('month', current_date)::date;
BEGIN
  -- 1 · VAT summary (per period, from the draft ledger)
  INSERT INTO analytics.vat_summary
    (organization_id, business_id, period_start, period_end, output_vat, input_vat, net_position, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id, date_trunc('month', entry_period)::date,
         (date_trunc('month', entry_period) + interval '1 month - 1 day')::date,
         COALESCE(sum(output_vat_due_amount), 0), COALESCE(sum(input_vat_reclaimable_amount), 0),
         COALESCE(sum(output_vat_due_amount), 0) - COALESCE(sum(input_vat_reclaimable_amount), 0), v_now, 'FRESH'
    FROM public.draft_ledger_entries WHERE business_id = p_business_id GROUP BY date_trunc('month', entry_period)
  ON CONFLICT (business_id, period_start, period_end) DO UPDATE
    SET output_vat = EXCLUDED.output_vat, input_vat = EXCLUDED.input_vat, net_position = EXCLUDED.net_position,
        last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 2 · Income overview (MTD, rolling 12m, monthly series)
  INSERT INTO analytics.income_overview
    (organization_id, business_id, mtd_income, rolling_12m_income, monthly_series, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id,
    COALESCE((SELECT sum(amount) FROM public.transactions WHERE business_id = p_business_id AND amount > 0 AND date_trunc('month', transaction_date)::date = v_cur_month), 0),
    COALESCE((SELECT sum(amount) FROM public.transactions WHERE business_id = p_business_id AND amount > 0 AND transaction_date >= (v_cur_month - interval '11 months')), 0),
    COALESCE((SELECT jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'value', v) ORDER BY m)
                FROM (SELECT date_trunc('month', transaction_date)::date AS m, sum(amount) AS v FROM public.transactions WHERE business_id = p_business_id AND amount > 0 GROUP BY 1) s), '[]'::jsonb),
    v_now, 'FRESH'
  ON CONFLICT (business_id) DO UPDATE
    SET mtd_income = EXCLUDED.mtd_income, rolling_12m_income = EXCLUDED.rolling_12m_income,
        monthly_series = EXCLUDED.monthly_series, last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 3 · Expense overview (amounts stored positive)
  INSERT INTO analytics.expense_overview
    (organization_id, business_id, mtd_expense, rolling_12m_expense, monthly_series, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id,
    COALESCE((SELECT sum(-amount) FROM public.transactions WHERE business_id = p_business_id AND amount < 0 AND date_trunc('month', transaction_date)::date = v_cur_month), 0),
    COALESCE((SELECT sum(-amount) FROM public.transactions WHERE business_id = p_business_id AND amount < 0 AND transaction_date >= (v_cur_month - interval '11 months')), 0),
    COALESCE((SELECT jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'value', v) ORDER BY m)
                FROM (SELECT date_trunc('month', transaction_date)::date AS m, sum(-amount) AS v FROM public.transactions WHERE business_id = p_business_id AND amount < 0 GROUP BY 1) s), '[]'::jsonb),
    v_now, 'FRESH'
  ON CONFLICT (business_id) DO UPDATE
    SET mtd_expense = EXCLUDED.mtd_expense, rolling_12m_expense = EXCLUDED.rolling_12m_expense,
        monthly_series = EXCLUDED.monthly_series, last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 4 · Cash movement (per period)
  INSERT INTO analytics.cash_movement
    (organization_id, business_id, period_start, period_end, net_inflow, net_outflow, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id, date_trunc('month', transaction_date)::date,
         (date_trunc('month', transaction_date) + interval '1 month - 1 day')::date,
         COALESCE(sum(amount) FILTER (WHERE amount > 0), 0), COALESCE(sum(-amount) FILTER (WHERE amount < 0), 0), v_now, 'FRESH'
    FROM public.transactions WHERE business_id = p_business_id GROUP BY date_trunc('month', transaction_date)
  ON CONFLICT (business_id, period_start, period_end) DO UPDATE
    SET net_inflow = EXCLUDED.net_inflow, net_outflow = EXCLUDED.net_outflow,
        last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 5 · Monthly overview (per period, run status + blocking count)
  INSERT INTO analytics.monthly_overview
    (organization_id, business_id, period_start, period_end, run_status, in_flight_phase, blocking_issue_count, last_refreshed_at, refresh_state)
  SELECT DISTINCT ON (r.period_start::date, r.period_end::date)
         p_organization_id, p_business_id, r.period_start::date, r.period_end::date, r.status::text, NULL::text,
         (SELECT count(*) FROM public.review_issues WHERE business_id = p_business_id AND status = 'OPEN' AND severity = 'BLOCKING')::int, v_now, 'FRESH'
    FROM public.workflow_runs r WHERE r.business_id = p_business_id
   ORDER BY r.period_start::date, r.period_end::date, (CASE WHEN r.workflow_type::text LIKE 'OUT%' THEN 0 ELSE 1 END)
  ON CONFLICT (business_id, period_start, period_end) DO UPDATE
    SET run_status = EXCLUDED.run_status, in_flight_phase = EXCLUDED.in_flight_phase,
        blocking_issue_count = EXCLUDED.blocking_issue_count, last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 6 · Client invoice aging (outstanding receivables, bucketed)
  INSERT INTO analytics.client_invoice_status
    (organization_id, business_id, per_client_aging, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id,
    (WITH inv AS (
       SELECT total_amount,
         CASE WHEN due_date >= current_date THEN 'current' WHEN due_date >= current_date - 30 THEN 'd1_30'
              WHEN due_date >= current_date - 60 THEN 'd31_60' ELSE 'd60_plus' END AS bucket
         FROM public.invoices WHERE business_id = p_business_id AND lifecycle_status IN ('SENT', 'PAYMENT_EXPECTED', 'PARTIALLY_PAID'))
     SELECT jsonb_build_object('total_outstanding', COALESCE(sum(total_amount), 0), 'invoice_count', count(*),
       'buckets', jsonb_build_object('current', COALESCE(sum(total_amount) FILTER (WHERE bucket = 'current'), 0),
         'd1_30', COALESCE(sum(total_amount) FILTER (WHERE bucket = 'd1_30'), 0),
         'd31_60', COALESCE(sum(total_amount) FILTER (WHERE bucket = 'd31_60'), 0),
         'd60_plus', COALESCE(sum(total_amount) FILTER (WHERE bucket = 'd60_plus'), 0))) FROM inv),
    v_now, 'FRESH'
  ON CONFLICT (business_id) DO UPDATE
    SET per_client_aging = EXCLUDED.per_client_aging, last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 7 · Subscriptions overview (recurring vendor spend)
  INSERT INTO analytics.subscriptions_overview
    (organization_id, business_id, recurring_by_supplier, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id,
    (WITH mem AS (SELECT counterparty_signature AS sig, suggested_tag, confirmations_count FROM public.recurring_vendor_memory WHERE business_id = p_business_id AND status = 'ACTIVE'),
     lc AS (SELECT lower(trim(counterparty_name)) AS sig, abs(amount) AS amt, row_number() OVER (PARTITION BY lower(trim(counterparty_name)) ORDER BY transaction_date DESC) AS rn FROM public.transactions WHERE business_id = p_business_id AND direction = 'OUT'),
     j AS (SELECT m.sig, m.suggested_tag, m.confirmations_count, COALESCE(lc.amt, 0) AS amount FROM mem m LEFT JOIN lc ON lc.sig = m.sig AND lc.rn = 1)
     SELECT jsonb_build_object('vendor_count', (SELECT count(*) FROM j), 'total_monthly', COALESCE((SELECT sum(amount) FROM j), 0),
       'suppliers', COALESCE((SELECT jsonb_agg(jsonb_build_object('tag', suggested_tag, 'amount', amount, 'confirmations', confirmations_count) ORDER BY amount DESC) FROM j), '[]'::jsonb))),
    v_now, 'FRESH'
  ON CONFLICT (business_id) DO UPDATE
    SET recurring_by_supplier = EXCLUDED.recurring_by_supplier, last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 8 · Missing documents (transactions awaiting a confirmed match/evidence)
  INSERT INTO analytics.missing_documents (organization_id, business_id, outstanding_count, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id,
    (SELECT count(*) FROM public.transactions WHERE business_id = p_business_id AND match_status IN ('UNMATCHED', 'MATCHED_PROPOSED'))::int, v_now, 'FRESH'
  ON CONFLICT (business_id) DO UPDATE
    SET outstanding_count = EXCLUDED.outstanding_count, last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 9 · Review issues summary (open issues by group + severity)
  INSERT INTO analytics.review_issues_summary (organization_id, business_id, counts_by_group, counts_by_severity, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id,
    COALESCE((SELECT jsonb_object_agg(g, c) FROM (SELECT issue_group::text AS g, count(*) AS c FROM public.review_issues WHERE business_id = p_business_id AND status = 'OPEN' GROUP BY issue_group) x), '{}'::jsonb),
    COALESCE((SELECT jsonb_object_agg(s, c) FROM (SELECT severity::text AS s, count(*) AS c FROM public.review_issues WHERE business_id = p_business_id AND status = 'OPEN' GROUP BY severity) x), '{}'::jsonb),
    v_now, 'FRESH'
  ON CONFLICT (business_id) DO UPDATE
    SET counts_by_group = EXCLUDED.counts_by_group, counts_by_severity = EXCLUDED.counts_by_severity,
        last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  -- 10 · Finalized periods index (sealed archive packages)
  INSERT INTO analytics.finalized_periods_index (organization_id, business_id, periods, last_refreshed_at, refresh_state)
  SELECT p_organization_id, p_business_id,
    COALESCE((SELECT jsonb_agg(jsonb_build_object('period_start', period_start, 'original_finalization', original_finalization, 'created_at', created_at) ORDER BY period_start DESC) FROM public.archive_packages WHERE business_id = p_business_id), '[]'::jsonb),
    v_now, 'FRESH'
  ON CONFLICT (business_id) DO UPDATE
    SET periods = EXCLUDED.periods, last_refreshed_at = EXCLUDED.last_refreshed_at, refresh_state = 'FRESH';

  RETURN jsonb_build_object('decision', 'REFRESHED', 'business_id', p_business_id, 'refreshed_at', v_now,
    'tables', jsonb_build_array('vat_summary','income_overview','expense_overview','cash_movement','monthly_overview','client_invoice_status','subscriptions_overview','missing_documents','review_issues_summary','finalized_periods_index'));
END;
$$;
COMMENT ON FUNCTION analytics.compute_business_projections(uuid, uuid) IS 'R6/A6.1: recompute all analytics.* projection metrics for one business from operational data.';

-- Canonical orchestrator: real compute wrapped in the existing audit-event semantics.
CREATE OR REPLACE FUNCTION analytics.refresh_business(
  p_business_id uuid, p_source_run_id uuid DEFAULT NULL::uuid,
  p_actor_system text DEFAULT 'refresh-job'::text, p_actor_user_id uuid DEFAULT NULL::uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'analytics', 'public', 'pg_temp'
AS $$
DECLARE v_org uuid; v_result jsonb; v_count int;
BEGIN
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN RAISE EXCEPTION 'business % not found', p_business_id USING ERRCODE='P0002'; END IF;
  BEGIN
    v_result := analytics.compute_business_projections(v_org, p_business_id);
    v_count := jsonb_array_length(v_result->'tables');
    INSERT INTO analytics.analytics_events (organization_id, business_id, event_type, source_run_id, actor_user_id, actor_system, payload, occurred_at)
    VALUES (v_org, p_business_id, 'ANALYTICS_REBUILD_COMPLETED', p_source_run_id, p_actor_user_id,
            CASE WHEN p_actor_user_id IS NULL THEN p_actor_system ELSE NULL END,
            jsonb_build_object('aggregates_refreshed', v_count, 'scope', 'all'), clock_timestamp());
    RETURN v_count;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO analytics.analytics_events (organization_id, business_id, event_type, source_run_id, actor_system, payload, occurred_at)
    VALUES (v_org, p_business_id, 'ANALYTICS_REBUILD_FAILED', p_source_run_id, p_actor_system, jsonb_build_object('error', SQLERRM), clock_timestamp());
    RAISE;
  END;
END;
$$;
