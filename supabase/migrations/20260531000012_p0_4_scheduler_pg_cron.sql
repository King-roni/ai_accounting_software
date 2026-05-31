-- P0.4 — time-driven scheduling. pg_cron was not installed and
-- recurring_run_daily_scheduler was never invoked, so recurring invoices never
-- generated and nothing time-drove the system. Installs pg_cron and schedules
-- the daily recurring-invoice run + pro-forma-expiry sweep.
--
-- Worker tick: the P0.1 orchestrator worker is a continuous poll loop
-- (python -m cyprus_bookkeeping_api.worker), so it needs no cron in an
-- always-on deployment. A serverless/cron-driven alternative can hit the new
-- api endpoint POST /internal/worker/tick (pg_net job documented for P3 once a
-- reachable URL + secret exist); not scheduled here to avoid a dangling job.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ── batch pro-forma expiry (only a per-invoice RPC existed) ──────────────────
CREATE OR REPLACE FUNCTION public.expire_due_pro_forma_invoices(
  p_now          timestamptz DEFAULT now(),
  p_actor_system text DEFAULT 'pro_forma_expiry_scheduler',
  p_context      jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_inv     record;
  v_expired int := 0;
  v_failed  int := 0;
  v_res     jsonb;
BEGIN
  FOR v_inv IN
    SELECT id FROM public.invoices
     WHERE invoice_type = 'PRO_FORMA'::public.invoice_type_enum
       AND lifecycle_status IN ('DRAFT'::public.invoice_lifecycle_status_enum,
                                'SENT'::public.invoice_lifecycle_status_enum)
       AND pro_forma_expires_at IS NOT NULL
       AND pro_forma_expires_at <= p_now
     ORDER BY pro_forma_expires_at
  LOOP
    v_res := public.invoice_mark_pro_forma_expired(v_inv.id, p_actor_system, p_context);
    IF v_res->>'decision' = 'ALLOW' THEN v_expired := v_expired + 1; ELSE v_failed := v_failed + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'expired_count', v_expired, 'failed_count', v_failed, 'as_of', p_now);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.expire_due_pro_forma_invoices(timestamptz, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.expire_due_pro_forma_invoices(timestamptz, text, jsonb) TO service_role;

-- ── daily schedules (cron.schedule upserts by job name → idempotent) ─────────
SELECT cron.schedule('recurring-invoices-daily', '5 0 * * *',
  $$SELECT public.recurring_run_daily_scheduler(now(), 'pg_cron', '{}'::jsonb)$$);
SELECT cron.schedule('pro-forma-expiry-daily', '10 0 * * *',
  $$SELECT public.expire_due_pro_forma_invoices(now(), 'pg_cron', '{}'::jsonb)$$);
