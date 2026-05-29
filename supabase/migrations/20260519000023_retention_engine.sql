-- B04·P10 Retention Engine
-- ============================================================================
-- Background-job RPCs that enforce per-business retention policies on the
-- archive. Default retention is 6 years (Cyprus legal minimum); businesses
-- can extend but never reduce below 6.
--
-- Legal-hold integration is via the `archive.legal_hold_status(business_id)`
-- function, which Phase 11 (Legal Hold) will REPLACE with the full
-- implementation. This phase ships a placeholder that always returns
-- {on_hold: false, hold_reasons: []} so the engine runs end-to-end without
-- a code-level dependency on Phase 11.
--
-- Deletion atomicity: each archive_run is deleted via the existing
-- `archive.retention_delete_archive_run` (Phase 07). Storage object delete
-- happens via a follow-up worker that consumes the RETENTION_DELETION_EXECUTED
-- audit; Storage-side failures call back through
-- `archive.record_retention_inconsistency` to surface a HIGH issue.
-- ============================================================================

-- ---- ENUM extensions ----------------------------------------------------

ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_PASS_STARTED';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_DELETION_PLANNED';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_DELETION_EXECUTED';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_DELETION_SKIPPED_LEGAL_HOLD';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_DELETION_INCONSISTENT';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_PASS_COMPLETED';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_POLICY_UPDATED';

-- ---- retention_policies ------------------------------------------------

CREATE TABLE archive.retention_policies (
  business_id      uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  retention_years  integer NOT NULL DEFAULT 6,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid REFERENCES public.users(id),
  CONSTRAINT retention_policies_min_years_chk CHECK (retention_years >= 6)
);

CREATE INDEX idx_retention_policies_organization ON archive.retention_policies (organization_id);
CREATE INDEX idx_retention_policies_updated_by   ON archive.retention_policies (updated_by) WHERE updated_by IS NOT NULL;

ALTER TABLE archive.retention_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE archive.retention_policies FORCE  ROW LEVEL SECURITY;
CREATE POLICY retention_policies_select ON archive.retention_policies
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY retention_policies_no_insert ON archive.retention_policies
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY retention_policies_no_update ON archive.retention_policies
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY retention_policies_no_delete ON archive.retention_policies
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON archive.retention_policies TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON archive.retention_policies TO service_role;

-- Seed defaults for existing businesses.
INSERT INTO archive.retention_policies (business_id, organization_id, retention_years)
SELECT id, organization_id, 6 FROM public.business_entities
ON CONFLICT (business_id) DO NOTHING;

-- Auto-seed on new business creation.
CREATE OR REPLACE FUNCTION archive.fn_seed_retention_policy()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
BEGIN
  INSERT INTO archive.retention_policies (business_id, organization_id, retention_years)
  VALUES (NEW.id, NEW.organization_id, 6)
  ON CONFLICT (business_id) DO NOTHING;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_business_entities_seed_retention_policy
  AFTER INSERT ON public.business_entities
  FOR EACH ROW EXECUTE FUNCTION archive.fn_seed_retention_policy();

-- ---- legal_hold_status placeholder --------------------------------------
-- Phase 11 will CREATE OR REPLACE this with the real implementation.

CREATE OR REPLACE FUNCTION archive.legal_hold_status(p_business_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
  SELECT jsonb_build_object('on_hold', false, 'hold_reasons', '[]'::jsonb);
$fn$;
REVOKE EXECUTE ON FUNCTION archive.legal_hold_status(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.legal_hold_status(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION archive.legal_hold_status(uuid) IS
'B04·P10 placeholder: always returns {on_hold: false, hold_reasons: []}. B04·P11 (Legal Hold) REPLACEs this function with the real implementation that queries the legal_holds table. No code change in the retention engine is required for the swap.';

-- ---- retention_threshold helper ----------------------------------------

CREATE OR REPLACE FUNCTION archive.retention_threshold(
  p_business_id uuid, p_now timestamptz DEFAULT now()
) RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
  SELECT p_now - make_interval(years => COALESCE((
    SELECT retention_years FROM archive.retention_policies WHERE business_id = p_business_id
  ), 6))
$fn$;
REVOKE EXECUTE ON FUNCTION archive.retention_threshold(uuid, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.retention_threshold(uuid, timestamptz) TO authenticated, service_role;

-- ---- update_retention_policy (authenticated, OWNER/ADMIN + step-up) ----

CREATE OR REPLACE FUNCTION archive.update_retention_policy(
  p_business_id     uuid,
  p_retention_years integer,
  p_step_up_token   uuid
) RETURNS archive.retention_policies
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_org  uuid;
  v_role public.user_role;
  v_row  archive.retention_policies;
  v_old  integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_retention_years < 6 THEN
    RAISE EXCEPTION 'retention_years % below legal minimum (6)', p_retention_years USING ERRCODE='22000';
  END IF;

  SELECT bur.role INTO v_role FROM public.business_user_roles bur
    WHERE bur.user_id = v_user AND bur.business_id = p_business_id AND bur.status = 'ACTIVE';
  IF v_role IS NULL OR v_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'role does not grant retention policy update (got %)', v_role USING ERRCODE='42501';
  END IF;

  -- Step-up consumption (B02·P06). Surface = 'retention_policy_update'.
  PERFORM public.consume_step_up_token(p_step_up_token, p_business_id, 'retention_policy_update', NULL);

  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;

  SELECT retention_years INTO v_old FROM archive.retention_policies WHERE business_id = p_business_id;
  INSERT INTO archive.retention_policies (business_id, organization_id, retention_years, updated_at, updated_by)
  VALUES (p_business_id, v_org, p_retention_years, now(), v_user)
  ON CONFLICT (business_id) DO UPDATE
    SET retention_years = EXCLUDED.retention_years,
        updated_at      = now(),
        updated_by      = EXCLUDED.updated_by
  RETURNING * INTO v_row;

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, actor_user_id, payload
  ) VALUES (
    v_org, p_business_id, 'RETENTION_POLICY_UPDATED', v_user,
    jsonb_build_object(
      'old_retention_years', v_old,
      'new_retention_years', p_retention_years
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.update_retention_policy(uuid, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.update_retention_policy(uuid, integer, uuid) TO authenticated, service_role;

-- ---- run_retention_pass -------------------------------------------------
-- Service-role background-job entry. Optional p_business_id constrains to
-- one business (used for targeted retests); NULL processes every business
-- with a retention policy. p_dry_run emits PLANNED audits without deleting.

CREATE OR REPLACE FUNCTION archive.run_retention_pass(
  p_now            timestamptz DEFAULT now(),
  p_dry_run        boolean     DEFAULT false,
  p_business_id    uuid        DEFAULT NULL,
  p_actor_system   text        DEFAULT 'retention-engine'
) RETURNS TABLE (
  planned   integer,
  executed  integer,
  skipped   integer,
  failed    integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_biz         record;
  v_run         record;
  v_planned     integer := 0;
  v_executed    integer := 0;
  v_skipped     integer := 0;
  v_failed      integer := 0;
  v_threshold   timestamptz;
  v_hold        jsonb;
  v_lock_key    bigint := hashtext('archive.run_retention_pass')::bigint;
BEGIN
  -- Session-level advisory lock with explicit unlock at function exit so
  -- the same session can call run_retention_pass multiple times in one
  -- transaction. Cross-session callers still coalesce: the second session
  -- gets false and returns immediately.
  IF NOT pg_try_advisory_lock(v_lock_key) THEN
    RETURN QUERY SELECT 0, 0, 0, 0; RETURN;
  END IF;

  BEGIN
  FOR v_biz IN
    SELECT rp.business_id, rp.organization_id, rp.retention_years
      FROM archive.retention_policies rp
     WHERE p_business_id IS NULL OR rp.business_id = p_business_id
  LOOP
    v_threshold := p_now - make_interval(years => v_biz.retention_years);

    INSERT INTO archive.archive_events (
      organization_id, business_id, event_type, actor_system, payload
    ) VALUES (
      v_biz.organization_id, v_biz.business_id, 'RETENTION_PASS_STARTED', p_actor_system,
      jsonb_build_object(
        'threshold', v_threshold,
        'retention_years', v_biz.retention_years,
        'dry_run', p_dry_run
      )
    );

    v_hold := archive.legal_hold_status(v_biz.business_id);

    FOR v_run IN
      SELECT id, period_start, period_end, completed_at, status, bundle_storage_path
        FROM archive.archive_runs
       WHERE business_id = v_biz.business_id
         AND status      = 'COMPLETE'
         AND completed_at IS NOT NULL
         AND completed_at < v_threshold
       ORDER BY completed_at ASC
    LOOP
      IF COALESCE((v_hold->>'on_hold')::boolean, false) THEN
        INSERT INTO archive.archive_events (
          organization_id, business_id, event_type, archive_run_id, actor_system, payload
        ) VALUES (
          v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_SKIPPED_LEGAL_HOLD',
          v_run.id, p_actor_system,
          jsonb_build_object(
            'period_start', v_run.period_start,
            'period_end',   v_run.period_end,
            'hold_reasons', COALESCE(v_hold->'hold_reasons','[]'::jsonb)
          )
        );
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      IF p_dry_run THEN
        INSERT INTO archive.archive_events (
          organization_id, business_id, event_type, archive_run_id, actor_system, payload
        ) VALUES (
          v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_PLANNED',
          v_run.id, p_actor_system,
          jsonb_build_object(
            'period_start', v_run.period_start,
            'period_end',   v_run.period_end,
            'storage_path', v_run.bundle_storage_path,
            'threshold',    v_threshold
          )
        );
        v_planned := v_planned + 1;
        CONTINUE;
      END IF;

      BEGIN
        -- Emit EXECUTED audit FIRST: archive_events.archive_run_id has
        -- ON DELETE SET NULL, but the row must exist at INSERT time to
        -- satisfy the FK. retention_delete_archive_run then deletes the
        -- archive_run and the FK cascades the audit's archive_run_id to
        -- NULL — the audit row stays in the log.
        INSERT INTO archive.archive_events (
          organization_id, business_id, event_type, archive_run_id, actor_system, payload
        ) VALUES (
          v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_EXECUTED',
          v_run.id, p_actor_system,
          jsonb_build_object(
            'period_start',  v_run.period_start,
            'period_end',    v_run.period_end,
            'storage_path',  v_run.bundle_storage_path,
            'storage_cleanup_pending', (v_run.bundle_storage_path IS NOT NULL)
          )
        );
        PERFORM archive.retention_delete_archive_run(v_run.id, 'retention_window_elapsed');
        v_executed := v_executed + 1;
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO archive.archive_events (
          organization_id, business_id, event_type, archive_run_id,
          actor_system, payload
        ) VALUES (
          v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_INCONSISTENT',
          v_run.id, p_actor_system,
          jsonb_build_object(
            'period_start', v_run.period_start,
            'period_end',   v_run.period_end,
            'storage_path', v_run.bundle_storage_path,
            'error',        SQLERRM
          )
        );
        v_failed := v_failed + 1;
      END;
    END LOOP;

    INSERT INTO archive.archive_events (
      organization_id, business_id, event_type, actor_system, payload
    ) VALUES (
      v_biz.organization_id, v_biz.business_id, 'RETENTION_PASS_COMPLETED', p_actor_system,
      jsonb_build_object(
        'planned',  v_planned,
        'executed', v_executed,
        'skipped',  v_skipped,
        'failed',   v_failed,
        'dry_run',  p_dry_run
      )
    );
  END LOOP;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_advisory_unlock(v_lock_key);
    RAISE;
  END;

  PERFORM pg_advisory_unlock(v_lock_key);
  RETURN QUERY SELECT v_planned, v_executed, v_skipped, v_failed;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.run_retention_pass(timestamptz, boolean, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION archive.run_retention_pass(timestamptz, boolean, uuid, text) TO service_role;

-- ---- record_retention_inconsistency (worker callback) ------------------

CREATE OR REPLACE FUNCTION archive.record_retention_inconsistency(
  p_business_id    uuid,
  p_archive_run_id uuid,
  p_storage_path   text,
  p_reason         text,
  p_error_payload  jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE v_org uuid;
BEGIN
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'business % not found', p_business_id USING ERRCODE='P0002';
  END IF;

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, archive_run_id,
    actor_system, reject_reason, payload
  ) VALUES (
    v_org, p_business_id, 'RETENTION_DELETION_INCONSISTENT', p_archive_run_id,
    'retention-engine', 'OTHER',
    jsonb_build_object('storage_path', p_storage_path, 'reason', p_reason, 'error', p_error_payload)
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.record_retention_inconsistency(uuid, uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION archive.record_retention_inconsistency(uuid, uuid, text, text, jsonb) TO service_role;

COMMENT ON TABLE archive.retention_policies IS
'B04·P10: per-business retention policy. Default 6 years (Cyprus legal minimum); CHECK prevents reducing below 6. Auto-seeded for new businesses via trigger.';
COMMENT ON FUNCTION archive.run_retention_pass(timestamptz, boolean, uuid, text) IS
'B04·P10 nightly retention pass. Iterates businesses; for each, computes the threshold (now - retention_years), enumerates COMPLETE archive_runs past it, calls legal_hold_status (B04·P11 swap-in), skips on hold, emits PLANNED audits in dry-run, otherwise deletes via retention_delete_archive_run + emits EXECUTED. Coalesces concurrent calls via global advisory lock. Returns (planned, executed, skipped, failed).';
COMMENT ON FUNCTION archive.update_retention_policy(uuid, integer, uuid) IS
'B04·P10 policy update: OWNER/ADMIN only; consumes a B02·P06 step-up token (surface=retention_policy_update); enforces retention_years >= 6.';

-- ---- relax archive_events_reject_reason_chk for retention -----------
-- The original B04·P07 constraint only allowed reject_reason on
-- ARCHIVE_WRITE_REJECTED. RETENTION_DELETION_INCONSISTENT may optionally
-- carry a reject_reason; widen the CHECK.
ALTER TABLE archive.archive_events DROP CONSTRAINT archive_events_reject_reason_chk;
ALTER TABLE archive.archive_events ADD CONSTRAINT archive_events_reject_reason_chk CHECK (
  CASE event_type
    WHEN 'ARCHIVE_WRITE_REJECTED'          THEN reject_reason IS NOT NULL
    WHEN 'RETENTION_DELETION_INCONSISTENT' THEN true
    ELSE reject_reason IS NULL
  END
);
