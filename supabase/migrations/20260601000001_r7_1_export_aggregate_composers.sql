-- R7.1 — aggregate data composers for the export-generation worker.
--
-- The export worker is a thin serializer: every byte of report *data* is
-- composed in the DB (the same pattern as the existing _compose_*_json /
-- _compose_vies_export_csv helpers) and the worker only renders it to
-- CSV/XLSX/PDF/JSON/XML/ZIP + uploads + marks the export COMPLETED.
--
-- Four catalogue kinds had no composer, so the worker had nothing real to
-- render (supplier_overview, cashflow_overview, profit_loss_overview,
-- client_outstanding_report). These add them, derived only from data the
-- system already owns — straightforward arithmetic over public.transactions
-- (signed amount: IN > 0 / OUT < 0; period_excluded_at filters out excluded
-- rows) and public.invoices/allocations. No invented accounting semantics:
-- the P&L is explicitly cash-basis.
--
-- All are SECURITY DEFINER read-only helpers (no writes, no audit) consistent
-- with the existing _compose_* family, and EXECUTE is granted to the same
-- roles (PUBLIC) so the service-role worker can call them via PostgREST.

-- Supplier overview — OUT transactions grouped by counterparty, by spend.
CREATE OR REPLACE FUNCTION public._compose_supplier_overview_json(
  p_business_id uuid, p_period_start date, p_period_end date)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.total_outflow_eur DESC), '[]'::jsonb)
  FROM (
    SELECT COALESCE(NULLIF(btrim(counterparty_name), ''), '(unidentified)') AS supplier,
           count(*)                                AS transaction_count,
           round(sum(abs(amount)), 2)              AS total_outflow_eur
    FROM public.transactions
    WHERE business_id = p_business_id
      AND direction = 'OUT'
      AND period_excluded_at IS NULL
      AND transaction_date BETWEEN p_period_start AND p_period_end
    GROUP BY 1
  ) t;
$function$;

-- Cashflow overview — headline inflow/outflow/net + per-month breakdown.
CREATE OR REPLACE FUNCTION public._compose_cashflow_summary_json(
  p_business_id uuid, p_period_start date, p_period_end date)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'period_start', p_period_start,
    'period_end',   p_period_end,
    'inflow_eur',   round(COALESCE(sum(amount) FILTER (WHERE direction = 'IN'), 0), 2),
    'outflow_eur',  round(COALESCE(sum(abs(amount)) FILTER (WHERE direction = 'OUT'), 0), 2),
    'net_eur',      round(COALESCE(sum(amount), 0), 2),
    'transaction_count', count(*),
    'by_month', (
      SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.month), '[]'::jsonb)
      FROM (
        SELECT to_char(date_trunc('month', transaction_date), 'YYYY-MM') AS month,
               round(COALESCE(sum(amount) FILTER (WHERE direction = 'IN'), 0), 2)       AS inflow_eur,
               round(COALESCE(sum(abs(amount)) FILTER (WHERE direction = 'OUT'), 0), 2) AS outflow_eur,
               round(COALESCE(sum(amount), 0), 2)                                       AS net_eur
        FROM public.transactions
        WHERE business_id = p_business_id
          AND period_excluded_at IS NULL
          AND transaction_date BETWEEN p_period_start AND p_period_end
        GROUP BY 1
      ) m
    )
  )
  FROM public.transactions
  WHERE business_id = p_business_id
    AND period_excluded_at IS NULL
    AND transaction_date BETWEEN p_period_start AND p_period_end;
$function$;

-- Profit / loss overview — cash-basis income vs expense + per-type breakdown.
CREATE OR REPLACE FUNCTION public._compose_pnl_summary_json(
  p_business_id uuid, p_period_start date, p_period_end date)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'period_start',       p_period_start,
    'period_end',         p_period_end,
    'basis',              'cash',
    'income_total_eur',   round(COALESCE(sum(amount) FILTER (WHERE direction = 'IN'), 0), 2),
    'expense_total_eur',  round(COALESCE(sum(abs(amount)) FILTER (WHERE direction = 'OUT'), 0), 2),
    'net_profit_eur',     round(COALESCE(sum(amount), 0), 2),
    'by_type', (
      SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.amount_eur DESC), '[]'::jsonb)
      FROM (
        SELECT transaction_type::text AS transaction_type,
               direction::text        AS direction,
               count(*)               AS transaction_count,
               round(sum(abs(amount)), 2) AS amount_eur
        FROM public.transactions
        WHERE business_id = p_business_id
          AND period_excluded_at IS NULL
          AND transaction_date BETWEEN p_period_start AND p_period_end
        GROUP BY 1, 2
      ) b
    )
  )
  FROM public.transactions
  WHERE business_id = p_business_id
    AND period_excluded_at IS NULL
    AND transaction_date BETWEEN p_period_start AND p_period_end;
$function$;

-- Client outstanding — all-time: sent/expected invoices not fully settled.
CREATE OR REPLACE FUNCTION public._compose_client_outstanding_json(
  p_business_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.outstanding_eur DESC), '[]'::jsonb)
  FROM (
    SELECT COALESCE(c.display_name, '(no client)') AS client,
           i.invoice_number,
           i.issue_date,
           i.due_date,
           i.lifecycle_status::text                AS status,
           round(i.total_amount, 2)                AS invoice_total_eur,
           round(COALESCE(pa.paid, 0), 2)          AS paid_eur,
           round(i.total_amount - COALESCE(pa.paid, 0), 2) AS outstanding_eur
    FROM public.invoices i
    LEFT JOIN public.clients c ON c.id = i.client_id
    LEFT JOIN (
      SELECT invoice_id, sum(allocated_amount) AS paid
      FROM public.invoice_payment_allocations
      GROUP BY invoice_id
    ) pa ON pa.invoice_id = i.id
    WHERE i.business_id = p_business_id
      AND i.lifecycle_status IN ('SENT', 'PAYMENT_EXPECTED', 'PARTIALLY_PAID', 'OVERPAID')
      AND round(i.total_amount - COALESCE(pa.paid, 0), 2) <> 0
  ) t;
$function$;

GRANT EXECUTE ON FUNCTION public._compose_supplier_overview_json(uuid, date, date) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public._compose_cashflow_summary_json(uuid, date, date) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public._compose_pnl_summary_json(uuid, date, date) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public._compose_client_outstanding_json(uuid) TO PUBLIC;
