-- B04·P09 Analytics Zone
-- ============================================================================
-- Read-side aggregate layer for Block 16 dashboard cards.
--
-- 11 aggregate tables, each with the same refresh-state suffix:
--   last_refreshed_at | refresh_state (FRESH/REBUILDING/STALE) | source_run_id
--
-- Refresh strategy:
--   * AFTER INSERT trigger on archive.archive_events fires on
--     event_type=ARCHIVE_PROMOTION_COMPLETED, marks every aggregate for the
--     business STALE + emits ANALYTICS_REBUILD_TRIGGERED.
--   * refresh_business RPC (service_role) takes an advisory lock keyed on
--     (business_id, aggregate_table), flips STALE -> REBUILDING -> FRESH,
--     bumps last_refreshed_at, emits ANALYTICS_REBUILD_COMPLETED. Concurrent
--     callers coalesce via the lock.
--   * request_manual_refresh RPC (authenticated, OWNER/ADMIN) emits
--     ANALYTICS_REFRESH_REQUESTED_MANUAL and delegates.
--
-- Aggregation bodies are intentionally noop here (last_refreshed_at bump +
-- state transition). Block 16 will replace each rebuild function with the
-- per-aggregate SQL it owns.
--
-- RLS: tenant-scoped SELECT for authenticated; INSERT/UPDATE/DELETE blocked
-- from authenticated; service_role-only writers via DEFINER RPCs.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS analytics;

CREATE TYPE analytics.refresh_state_enum AS ENUM ('FRESH', 'REBUILDING', 'STALE');

CREATE TYPE analytics.analytics_event_type_enum AS ENUM (
  'ANALYTICS_REBUILD_TRIGGERED',
  'ANALYTICS_REBUILD_COMPLETED',
  'ANALYTICS_REBUILD_FAILED',
  'ANALYTICS_REFRESH_REQUESTED_MANUAL'
);

-- ---- aggregate tables ---------------------------------------------------
-- Shape: org_id + business_id + (optional period cols) + aggregate cols
-- + last_refreshed_at + refresh_state + source_run_id.

CREATE TABLE analytics.monthly_overview (
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id         uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  period_start        date NOT NULL,
  period_end          date NOT NULL,
  run_status          text,
  in_flight_phase     text,
  blocking_issue_count integer NOT NULL DEFAULT 0,
  last_refreshed_at   timestamptz NOT NULL DEFAULT now(),
  refresh_state       analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id       uuid,
  PRIMARY KEY (business_id, period_start, period_end),
  CHECK (period_end >= period_start)
);

CREATE TABLE analytics.income_overview (
  organization_id    uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id        uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  mtd_income         numeric(20,4) NOT NULL DEFAULT 0,
  rolling_12m_income numeric(20,4) NOT NULL DEFAULT 0,
  monthly_series     jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_refreshed_at  timestamptz NOT NULL DEFAULT now(),
  refresh_state      analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id      uuid
);

CREATE TABLE analytics.expense_overview (
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id         uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  mtd_expense         numeric(20,4) NOT NULL DEFAULT 0,
  rolling_12m_expense numeric(20,4) NOT NULL DEFAULT 0,
  monthly_series      jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_refreshed_at   timestamptz NOT NULL DEFAULT now(),
  refresh_state       analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id       uuid
);

CREATE TABLE analytics.missing_documents (
  organization_id   uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id       uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  outstanding_count integer NOT NULL DEFAULT 0,
  last_refreshed_at timestamptz NOT NULL DEFAULT now(),
  refresh_state     analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id     uuid
);

CREATE TABLE analytics.review_issues_summary (
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id         uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  counts_by_group     jsonb NOT NULL DEFAULT '{}'::jsonb,
  counts_by_severity  jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_refreshed_at   timestamptz NOT NULL DEFAULT now(),
  refresh_state       analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id       uuid
);

CREATE TABLE analytics.vat_summary (
  organization_id   uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id       uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  period_start      date NOT NULL,
  period_end        date NOT NULL,
  output_vat        numeric(20,4) NOT NULL DEFAULT 0,
  input_vat         numeric(20,4) NOT NULL DEFAULT 0,
  net_position      numeric(20,4) NOT NULL DEFAULT 0,
  last_refreshed_at timestamptz NOT NULL DEFAULT now(),
  refresh_state     analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id     uuid,
  PRIMARY KEY (business_id, period_start, period_end),
  CHECK (period_end >= period_start)
);

CREATE TABLE analytics.subscriptions_overview (
  organization_id      uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id          uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  recurring_by_supplier jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_refreshed_at    timestamptz NOT NULL DEFAULT now(),
  refresh_state        analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id        uuid
);

CREATE TABLE analytics.team_member_costs (
  organization_id        uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id            uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  costs_by_counterparty  jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_refreshed_at      timestamptz NOT NULL DEFAULT now(),
  refresh_state          analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id          uuid
);

CREATE TABLE analytics.client_invoice_status (
  organization_id   uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id       uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  per_client_aging  jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{client, current, 30d, 60d, 90d_plus}]
  last_refreshed_at timestamptz NOT NULL DEFAULT now(),
  refresh_state     analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id     uuid
);

CREATE TABLE analytics.cash_movement (
  organization_id   uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id       uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  period_start      date NOT NULL,
  period_end        date NOT NULL,
  net_inflow        numeric(20,4) NOT NULL DEFAULT 0,
  net_outflow       numeric(20,4) NOT NULL DEFAULT 0,
  last_refreshed_at timestamptz NOT NULL DEFAULT now(),
  refresh_state     analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id     uuid,
  PRIMARY KEY (business_id, period_start, period_end),
  CHECK (period_end >= period_start)
);

CREATE TABLE analytics.finalized_periods_index (
  organization_id   uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id       uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  periods           jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{period_start, period_end, archive_run_id, bundle_storage_path}]
  last_refreshed_at timestamptz NOT NULL DEFAULT now(),
  refresh_state     analytics.refresh_state_enum NOT NULL DEFAULT 'FRESH',
  source_run_id     uuid
);

-- ---- analytics_events audit log -----------------------------------------

CREATE TABLE analytics.analytics_events (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id          uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id              uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  event_type               analytics.analytics_event_type_enum NOT NULL,
  aggregate_table          text,
  source_run_id            uuid,
  actor_user_id            uuid REFERENCES public.users(id),
  actor_system             text,
  payload                  jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT analytics_events_actor_chk CHECK (
    (actor_user_id IS NOT NULL) <> (actor_system IS NOT NULL)
  )
);

CREATE INDEX idx_analytics_events_business_occurred ON analytics.analytics_events (business_id, occurred_at DESC);
CREATE INDEX idx_analytics_events_event_type        ON analytics.analytics_events (business_id, event_type, occurred_at DESC);
CREATE INDEX idx_analytics_events_organization      ON analytics.analytics_events (organization_id);
CREATE INDEX idx_analytics_events_actor_user        ON analytics.analytics_events (actor_user_id) WHERE actor_user_id IS NOT NULL;
CREATE INDEX idx_analytics_events_source_run        ON analytics.analytics_events (source_run_id) WHERE source_run_id IS NOT NULL;

-- ---- RLS: tenant SELECT only; writes blocked from authenticated ---------

DO $apply$
DECLARE v_tbl text;
BEGIN
  FOREACH v_tbl IN ARRAY ARRAY[
    'monthly_overview','income_overview','expense_overview','missing_documents',
    'review_issues_summary','vat_summary','subscriptions_overview',
    'team_member_costs','client_invoice_status','cash_movement',
    'finalized_periods_index','analytics_events'
  ] LOOP
    EXECUTE format('ALTER TABLE analytics.%I ENABLE ROW LEVEL SECURITY', v_tbl);
    EXECUTE format('ALTER TABLE analytics.%I FORCE  ROW LEVEL SECURITY', v_tbl);
    EXECUTE format('CREATE POLICY %I_select ON analytics.%I AS PERMISSIVE FOR SELECT TO authenticated USING (organization_id = public.current_org() AND business_id = ANY(public.current_user_businesses()))', v_tbl, v_tbl);
    EXECUTE format('CREATE POLICY %I_no_insert ON analytics.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false)', v_tbl, v_tbl);
    EXECUTE format('CREATE POLICY %I_no_update ON analytics.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false)', v_tbl, v_tbl);
    EXECUTE format('CREATE POLICY %I_no_delete ON analytics.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (false)', v_tbl, v_tbl);
  END LOOP;
END;
$apply$;

-- ---- schema grants ------------------------------------------------------

GRANT USAGE ON SCHEMA analytics TO authenticated, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA analytics TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;

-- ---- refresh helpers ----------------------------------------------------
-- aggregate-table lists. Split by PK shape so refresh_business can use
-- ON CONFLICT (business_id) on the single-PK aggregates while period-keyed
-- aggregates are handled by refresh_business_period.
CREATE OR REPLACE FUNCTION analytics.aggregate_tables_single_pk() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = analytics, pg_temp AS $fn$
  SELECT ARRAY['income_overview','expense_overview','missing_documents',
               'review_issues_summary','subscriptions_overview',
               'team_member_costs','client_invoice_status','finalized_periods_index']::text[]
$fn$;

CREATE OR REPLACE FUNCTION analytics.aggregate_tables_period_keyed() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = analytics, pg_temp AS $fn$
  SELECT ARRAY['monthly_overview','vat_summary','cash_movement']::text[]
$fn$;

CREATE OR REPLACE FUNCTION analytics.aggregate_tables_all() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = analytics, pg_temp AS $fn$
  SELECT analytics.aggregate_tables_single_pk() || analytics.aggregate_tables_period_keyed()
$fn$;

-- Advisory lock helper: hash (business_id, aggregate_table) into a bigint.
-- Returns true if the lock was acquired (caller is the rebuilder), false if
-- someone else holds it (caller should coalesce).
CREATE OR REPLACE FUNCTION analytics.try_acquire_refresh_lock(
  p_business_id uuid, p_aggregate_table text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = analytics, pg_temp
AS $fn$
DECLARE v_key bigint;
BEGIN
  -- hashtext returns int4 in PG; multiply / XOR to get a stable bigint.
  v_key := (hashtext(p_business_id::text)::bigint << 32)
           | (hashtextextended(p_aggregate_table, 0)::bigint & x'00000000FFFFFFFF'::bigint);
  RETURN pg_try_advisory_xact_lock(v_key);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION analytics.try_acquire_refresh_lock(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.try_acquire_refresh_lock(uuid, text) TO service_role;

-- Mark all aggregates STALE for a business + emit ANALYTICS_REBUILD_TRIGGERED.
-- Called by the AFTER-INSERT trigger on archive.archive_events.
CREATE OR REPLACE FUNCTION analytics.mark_business_stale(
  p_business_id uuid, p_source_run_id uuid, p_actor_system text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = analytics, public, pg_temp
AS $fn$
DECLARE
  v_org uuid;
  v_tbl text;
BEGIN
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN RETURN; END IF;

  FOREACH v_tbl IN ARRAY analytics.aggregate_tables_all() LOOP
    EXECUTE format('UPDATE analytics.%I SET refresh_state = ''STALE'' WHERE business_id = $1', v_tbl)
      USING p_business_id;
  END LOOP;

  INSERT INTO analytics.analytics_events (
    organization_id, business_id, event_type, source_run_id, actor_system, payload
  ) VALUES (
    v_org, p_business_id, 'ANALYTICS_REBUILD_TRIGGERED', p_source_run_id, p_actor_system,
    jsonb_build_object('trigger','ARCHIVE_PROMOTION_COMPLETED')
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION analytics.mark_business_stale(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.mark_business_stale(uuid, uuid, text) TO service_role;

-- Trigger on archive.archive_events: fires on ARCHIVE_PROMOTION_COMPLETED.
CREATE OR REPLACE FUNCTION analytics.fn_on_archive_promotion_completed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = analytics, public, archive, pg_temp
AS $fn$
BEGIN
  IF NEW.event_type = 'ARCHIVE_PROMOTION_COMPLETED' THEN
    PERFORM analytics.mark_business_stale(NEW.business_id, NEW.archive_run_id, 'archive-trigger');
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_archive_events_trigger_rebuild
  AFTER INSERT ON archive.archive_events
  FOR EACH ROW
  EXECUTE FUNCTION analytics.fn_on_archive_promotion_completed();

-- refresh_business: take advisory lock per aggregate, flip REBUILDING -> FRESH,
-- bump last_refreshed_at. Concurrent callers coalesce on the lock (the
-- second one immediately finds REBUILDING/already-FRESH and skips).
CREATE OR REPLACE FUNCTION analytics.refresh_business(
  p_business_id uuid,
  p_source_run_id uuid DEFAULT NULL,
  p_actor_system text DEFAULT 'refresh-job',
  p_actor_user_id uuid DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = analytics, public, pg_temp
AS $fn$
DECLARE
  v_org      uuid;
  v_tbl      text;
  v_acquired boolean;
  v_count    integer := 0;
BEGIN
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'business % not found', p_business_id USING ERRCODE='P0002';
  END IF;
  -- v_org resolved; nested BEGIN wraps the rebuild so the FAILED audit
  -- writer below has a valid org_id to attach to.
  BEGIN

  -- refresh_business only iterates SINGLE-PK aggregates (8 of 11). The
  -- 3 period-keyed aggregates (monthly_overview, vat_summary, cash_movement)
  -- are handled by refresh_business_period because ON CONFLICT (business_id)
  -- can't match a composite PK. clock_timestamp() is used (not now()) so
  -- consecutive calls in one transaction advance last_refreshed_at.
    FOREACH v_tbl IN ARRAY analytics.aggregate_tables_single_pk() LOOP
      v_acquired := analytics.try_acquire_refresh_lock(p_business_id, v_tbl);
      IF NOT v_acquired THEN CONTINUE; END IF;

      EXECUTE format('UPDATE analytics.%I SET refresh_state=''REBUILDING'' WHERE business_id=$1', v_tbl)
        USING p_business_id;

      EXECUTE format($u$
        INSERT INTO analytics.%I (organization_id, business_id, last_refreshed_at, refresh_state, source_run_id)
        VALUES ($1, $2, clock_timestamp(), 'FRESH', $3)
        ON CONFLICT (business_id) DO UPDATE
          SET last_refreshed_at = clock_timestamp(),
              refresh_state     = 'FRESH',
              source_run_id     = EXCLUDED.source_run_id
      $u$, v_tbl) USING v_org, p_business_id, p_source_run_id;

      v_count := v_count + 1;
    END LOOP;

    INSERT INTO analytics.analytics_events (
      organization_id, business_id, event_type, source_run_id, actor_user_id, actor_system, payload, occurred_at
    ) VALUES (
      v_org, p_business_id, 'ANALYTICS_REBUILD_COMPLETED', p_source_run_id,
      p_actor_user_id,
      CASE WHEN p_actor_user_id IS NULL THEN p_actor_system ELSE NULL END,
      jsonb_build_object('aggregates_refreshed', v_count, 'scope', 'single_pk'),
      clock_timestamp()
    );

    RETURN v_count;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO analytics.analytics_events (
      organization_id, business_id, event_type, source_run_id, actor_system, payload, occurred_at
    ) VALUES (
      v_org, p_business_id, 'ANALYTICS_REBUILD_FAILED', p_source_run_id, p_actor_system,
      jsonb_build_object('error', SQLERRM), clock_timestamp()
    );
    RAISE;
  END;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION analytics.refresh_business(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.refresh_business(uuid, uuid, text, uuid) TO service_role;

-- Per-aggregate composite-PK tables (monthly_overview, vat_summary,
-- cash_movement) need a separate "ensure row exists for current period"
-- path. For B04·P09 they get the same noop treatment without UPSERT.
-- Block 16 will provide period-specific rebuild logic. Here we just leave
-- those tables untouched by refresh_business unless rows already exist.

CREATE OR REPLACE FUNCTION analytics.refresh_business_period(
  p_business_id uuid, p_period_start date, p_period_end date,
  p_source_run_id uuid DEFAULT NULL, p_actor_system text DEFAULT 'refresh-job'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = analytics, public, pg_temp
AS $fn$
DECLARE
  v_org uuid;
BEGIN
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'business % not found', p_business_id USING ERRCODE='P0002';
  END IF;

  INSERT INTO analytics.monthly_overview (organization_id, business_id, period_start, period_end, last_refreshed_at, refresh_state, source_run_id)
  VALUES (v_org, p_business_id, p_period_start, p_period_end, now(), 'FRESH', p_source_run_id)
  ON CONFLICT (business_id, period_start, period_end) DO UPDATE
    SET last_refreshed_at = now(), refresh_state = 'FRESH', source_run_id = EXCLUDED.source_run_id;

  INSERT INTO analytics.vat_summary (organization_id, business_id, period_start, period_end, last_refreshed_at, refresh_state, source_run_id)
  VALUES (v_org, p_business_id, p_period_start, p_period_end, now(), 'FRESH', p_source_run_id)
  ON CONFLICT (business_id, period_start, period_end) DO UPDATE
    SET last_refreshed_at = now(), refresh_state = 'FRESH', source_run_id = EXCLUDED.source_run_id;

  INSERT INTO analytics.cash_movement (organization_id, business_id, period_start, period_end, last_refreshed_at, refresh_state, source_run_id)
  VALUES (v_org, p_business_id, p_period_start, p_period_end, now(), 'FRESH', p_source_run_id)
  ON CONFLICT (business_id, period_start, period_end) DO UPDATE
    SET last_refreshed_at = now(), refresh_state = 'FRESH', source_run_id = EXCLUDED.source_run_id;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION analytics.refresh_business_period(uuid, date, date, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION analytics.refresh_business_period(uuid, date, date, uuid, text) TO service_role;

-- request_manual_refresh: authenticated entry point, Owner/Admin only.
-- Emits ANALYTICS_REFRESH_REQUESTED_MANUAL, then runs refresh_business.
CREATE OR REPLACE FUNCTION analytics.request_manual_refresh(
  p_business_id uuid
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = analytics, public, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_org  uuid;
  v_role public.user_role;
  v_count integer;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000';
  END IF;

  SELECT bur.role INTO v_role
    FROM public.business_user_roles bur
    WHERE bur.user_id = v_user AND bur.business_id = p_business_id AND bur.status = 'ACTIVE';
  IF v_role IS NULL OR v_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'role does not grant manual refresh (got %)', v_role USING ERRCODE='42501';
  END IF;

  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;

  INSERT INTO analytics.analytics_events (organization_id, business_id, event_type, actor_user_id, payload)
  VALUES (v_org, p_business_id, 'ANALYTICS_REFRESH_REQUESTED_MANUAL', v_user, '{}'::jsonb);

  v_count := analytics.refresh_business(p_business_id, NULL, 'manual', v_user);
  RETURN v_count;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION analytics.request_manual_refresh(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION analytics.request_manual_refresh(uuid) TO authenticated, service_role;

-- ---- comments -----------------------------------------------------------

COMMENT ON SCHEMA analytics IS
'B04·P09 Analytics Zone: read-side aggregates for Block 16 dashboard. SELECT for authenticated; INSERT/UPDATE/DELETE via service_role DEFINER RPCs only. Refresh triggered by ARCHIVE_PROMOTION_COMPLETED audit events.';
COMMENT ON FUNCTION analytics.refresh_business(uuid, uuid, text, uuid) IS
'B04·P09 refresh job: takes advisory lock per (business, aggregate), flips refresh_state STALE/REBUILDING -> FRESH, bumps last_refreshed_at. Concurrent callers coalesce on the lock. Block 16 replaces the per-table aggregation bodies with real SQL.';
COMMENT ON FUNCTION analytics.request_manual_refresh(uuid) IS
'B04·P09 manual refresh entry point. Authenticated; OWNER/ADMIN only. Emits ANALYTICS_REFRESH_REQUESTED_MANUAL then delegates to refresh_business.';
COMMENT ON TRIGGER trg_archive_events_trigger_rebuild ON archive.archive_events IS
'B04·P09 wiring: ARCHIVE_PROMOTION_COMPLETED emits ANALYTICS_REBUILD_TRIGGERED + marks all aggregates STALE for the business. The async refresh job consumes STALE rows.';
