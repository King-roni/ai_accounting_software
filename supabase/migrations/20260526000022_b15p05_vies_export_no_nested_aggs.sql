-- B15·P05 fix-up: _compose_vies_export_csv used SUM() inside string_agg(),
-- which Postgres rejects ("aggregate function calls cannot be nested").
-- Rewrite with a CTE so the group-by aggregation finishes before the outer
-- string_agg consumes the rows.

CREATE OR REPLACE FUNCTION public._compose_vies_export_csv(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_rows text := '';
BEGIN
  WITH grouped AS (
    SELECT COALESCE(dle.counterparty_country, '')    AS country,
           COALESCE(dle.counterparty_vat_number, '') AS vat_no,
           SUM(COALESCE(dle.vies_value_basis_eur, 0)) AS total_basis
      FROM public.draft_ledger_entries dle
      JOIN public.transactions t ON t.id = dle.parent_transaction_id
     WHERE t.business_id = p_business_id
       AND t.transaction_date BETWEEN p_period_start AND p_period_end
       AND dle.vies_relevant = true
     GROUP BY dle.counterparty_country, dle.counterparty_vat_number
  )
  SELECT string_agg(format('%s,%s,%s', country, vat_no, total_basis::text),
                    E'\n' ORDER BY country, vat_no)
    INTO v_rows FROM grouped;
  RETURN 'counterparty_country,counterparty_vat_number,value_basis_eur' ||
         CASE WHEN v_rows IS NULL THEN '' ELSE E'\n' || v_rows END;
END;
$$;
