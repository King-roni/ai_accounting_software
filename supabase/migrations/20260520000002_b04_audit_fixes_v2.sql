-- Block 04 audit fixes v2 — 2026-05-20 (continues from 20260520000001)
-- ============================================================================
-- Two remaining issues from the post-Block-04 audit:
--
--  #2  Retention couldn't delete a v1 archive_run while v2+ adjustments
--      existed (adjustment_of_archive_run_id FK is RESTRICT). The bundle
--      family must be deleted as a unit, and only when EVERY chain member
--      is past the retention threshold.
--
--      Solution:
--        a) Helper archive.archive_run_chain(root_id) walks descendants.
--        b) New event RETENTION_DELETION_SKIPPED_NEWER_ADJUSTMENT signals
--           the skip when any chain member is still within retention.
--        c) run_retention_pass now:
--             - iterates ROOT archive_runs (adjustment_of_archive_run_id IS NULL)
--             - skips if the chain's newest completed_at is past threshold
--             - deletes the whole chain leaves-first when all are past
--
--  #3  Processing-zone prune ignored per-business legal holds (B04·P11).
--      The B04·P06 forward-declared per-run flag was the only signal.
--      Solution: prune_expired_processing_artifacts now also calls
--      archive.legal_hold_status(business_id) and skips with LEGAL_HOLD
--      reason if either signal fires.
-- ============================================================================

-- ---- Fix #2 — adjustment-chain-aware retention ---------------------------

ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'RETENTION_DELETION_SKIPPED_NEWER_ADJUSTMENT';

CREATE OR REPLACE FUNCTION archive.archive_run_chain(p_root_id uuid)
RETURNS TABLE (id uuid, depth integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
  WITH RECURSIVE chain AS (
    SELECT ar.id, 0 AS depth FROM archive.archive_runs ar WHERE ar.id = p_root_id
    UNION ALL
    SELECT ar.id, c.depth + 1
      FROM archive.archive_runs ar
      JOIN chain c ON ar.adjustment_of_archive_run_id = c.id
  )
  SELECT id, depth FROM chain ORDER BY depth ASC
$fn$;
REVOKE EXECUTE ON FUNCTION archive.archive_run_chain(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION archive.archive_run_chain(uuid) TO service_role;

CREATE OR REPLACE FUNCTION archive.run_retention_pass(
  p_now            timestamptz DEFAULT now(),
  p_dry_run        boolean     DEFAULT false,
  p_business_id    uuid        DEFAULT NULL,
  p_actor_system   text        DEFAULT 'retention-engine'
) RETURNS TABLE (planned integer, executed integer, skipped integer, failed integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_biz             record;
  v_root            record;
  v_chain_member    record;
  v_planned         integer := 0;
  v_executed        integer := 0;
  v_skipped         integer := 0;
  v_failed          integer := 0;
  v_threshold       timestamptz;
  v_hold            jsonb;
  v_lock_key        bigint := hashtext('archive.run_retention_pass')::bigint;
  v_max_completed   timestamptz;
BEGIN
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

      INSERT INTO archive.archive_events (organization_id, business_id, event_type, actor_system, payload)
      VALUES (v_biz.organization_id, v_biz.business_id, 'RETENTION_PASS_STARTED', p_actor_system,
              jsonb_build_object('threshold', v_threshold, 'retention_years', v_biz.retention_years, 'dry_run', p_dry_run));

      v_hold := archive.legal_hold_status(v_biz.business_id);

      -- Iterate ROOT runs only; the chain (root + adjustments) is processed
      -- together so the bundle family stays consistent.
      FOR v_root IN
        SELECT id, period_start, period_end, completed_at, status, bundle_storage_path
          FROM archive.archive_runs
         WHERE business_id = v_biz.business_id
           AND status = 'COMPLETE'
           AND adjustment_of_archive_run_id IS NULL
           AND completed_at IS NOT NULL
           AND completed_at < v_threshold
         ORDER BY completed_at ASC
      LOOP
        IF COALESCE((v_hold->>'on_hold')::boolean, false) THEN
          INSERT INTO archive.archive_events (organization_id, business_id, event_type, archive_run_id, actor_system, payload)
          VALUES (v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_SKIPPED_LEGAL_HOLD',
                  v_root.id, p_actor_system,
                  jsonb_build_object('period_start', v_root.period_start, 'period_end', v_root.period_end,
                                     'hold_reasons', COALESCE(v_hold->'hold_reasons','[]'::jsonb)));
          v_skipped := v_skipped + 1; CONTINUE;
        END IF;

        -- Skip the chain when the newest member is still within retention.
        SELECT max(ar.completed_at) INTO v_max_completed
          FROM archive.archive_runs ar
          JOIN archive.archive_run_chain(v_root.id) c ON c.id = ar.id;

        IF v_max_completed >= v_threshold THEN
          INSERT INTO archive.archive_events (organization_id, business_id, event_type, archive_run_id, actor_system, payload)
          VALUES (v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_SKIPPED_NEWER_ADJUSTMENT',
                  v_root.id, p_actor_system,
                  jsonb_build_object('period_start', v_root.period_start, 'period_end', v_root.period_end,
                                     'root_completed_at', v_root.completed_at,
                                     'chain_max_completed_at', v_max_completed,
                                     'threshold', v_threshold));
          v_skipped := v_skipped + 1; CONTINUE;
        END IF;

        IF p_dry_run THEN
          FOR v_chain_member IN
            SELECT ar.id, ar.period_start, ar.period_end, ar.bundle_storage_path, ar.completed_at
              FROM archive.archive_runs ar
              JOIN archive.archive_run_chain(v_root.id) c ON c.id = ar.id
             ORDER BY c.depth DESC
          LOOP
            INSERT INTO archive.archive_events (organization_id, business_id, event_type, archive_run_id, actor_system, payload)
            VALUES (v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_PLANNED',
                    v_chain_member.id, p_actor_system,
                    jsonb_build_object('period_start', v_chain_member.period_start, 'period_end', v_chain_member.period_end,
                                       'storage_path', v_chain_member.bundle_storage_path,
                                       'threshold', v_threshold, 'root_id', v_root.id));
            v_planned := v_planned + 1;
          END LOOP;
          CONTINUE;
        END IF;

        -- Delete leaves-first so the adjustment_of_archive_run_id RESTRICT
        -- FK is satisfied at each step.
        FOR v_chain_member IN
          SELECT ar.id, ar.period_start, ar.period_end, ar.bundle_storage_path, ar.completed_at
            FROM archive.archive_runs ar
            JOIN archive.archive_run_chain(v_root.id) c ON c.id = ar.id
           ORDER BY c.depth DESC
        LOOP
          BEGIN
            -- Emit EXECUTED audit BEFORE the delete (FK SET NULL cascade applies after).
            INSERT INTO archive.archive_events (organization_id, business_id, event_type, archive_run_id, actor_system, payload)
            VALUES (v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_EXECUTED',
                    v_chain_member.id, p_actor_system,
                    jsonb_build_object('period_start', v_chain_member.period_start, 'period_end', v_chain_member.period_end,
                                       'storage_path', v_chain_member.bundle_storage_path,
                                       'storage_cleanup_pending', (v_chain_member.bundle_storage_path IS NOT NULL),
                                       'root_id', v_root.id));
            PERFORM archive.retention_delete_archive_run(v_chain_member.id, 'retention_window_elapsed');
            v_executed := v_executed + 1;
          EXCEPTION WHEN OTHERS THEN
            INSERT INTO archive.archive_events (organization_id, business_id, event_type, archive_run_id, actor_system, payload)
            VALUES (v_biz.organization_id, v_biz.business_id, 'RETENTION_DELETION_INCONSISTENT',
                    v_chain_member.id, p_actor_system,
                    jsonb_build_object('period_start', v_chain_member.period_start, 'period_end', v_chain_member.period_end,
                                       'storage_path', v_chain_member.bundle_storage_path,
                                       'error', SQLERRM, 'root_id', v_root.id));
            v_failed := v_failed + 1;
          END;
        END LOOP;
      END LOOP;

      INSERT INTO archive.archive_events (organization_id, business_id, event_type, actor_system, payload)
      VALUES (v_biz.organization_id, v_biz.business_id, 'RETENTION_PASS_COMPLETED', p_actor_system,
              jsonb_build_object('planned', v_planned, 'executed', v_executed, 'skipped', v_skipped, 'failed', v_failed, 'dry_run', p_dry_run));
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

-- ---- Fix #3 — processing prune honors per-business legal hold ----------

CREATE OR REPLACE FUNCTION public.prune_expired_processing_artifacts(
  p_now   timestamptz DEFAULT now(),
  p_limit integer     DEFAULT 1000
) RETURNS TABLE (pruned integer, skipped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, archive, pg_temp
AS $fn$
DECLARE
  v_artifact record;
  v_run      public.workflow_runs;
  v_pruned   integer := 0;
  v_skipped  integer := 0;
  v_skip     public.processing_prune_skip_reason_enum;
  v_hold     jsonb;
BEGIN
  FOR v_artifact IN
    SELECT * FROM public.processing_artifacts
     WHERE expires_at IS NOT NULL AND expires_at <= p_now
     ORDER BY expires_at
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_artifact.workflow_run_id;
    v_skip := NULL;

    -- Per-run flag (B04·P06 forward declaration on workflow_runs).
    IF v_run.legal_hold_active THEN
      v_skip := 'LEGAL_HOLD';
    END IF;

    -- Per-business hold (B04·P11 archive.legal_holds). Either signal blocks.
    IF v_skip IS NULL THEN
      v_hold := archive.legal_hold_status(v_artifact.business_id);
      IF COALESCE((v_hold->>'on_hold')::boolean, false) THEN
        v_skip := 'LEGAL_HOLD';
      END IF;
    END IF;

    IF v_skip IS NULL AND v_run.status NOT IN ('FINALIZED','FAILED','CANCELLED') THEN
      v_skip := 'RUN_NOT_TERMINAL';
    END IF;

    IF v_skip IS NOT NULL THEN
      INSERT INTO public.processing_artifact_events (
        organization_id, business_id, event_type, processing_artifact_id,
        workflow_run_id, actor_system, skip_reason, payload
      ) VALUES (
        v_artifact.organization_id, v_artifact.business_id,
        'PROCESSING_ARTIFACT_PRUNE_SKIPPED', v_artifact.id,
        v_artifact.workflow_run_id, 'prune-job', v_skip,
        jsonb_build_object(
          'artifact_type',     v_artifact.artifact_type::text,
          'run_status',        v_run.status::text,
          'expires_at',        v_artifact.expires_at,
          'business_on_hold',  COALESCE(v_hold->>'on_hold','false')::boolean,
          'hold_reasons',      COALESCE(v_hold->'hold_reasons','[]'::jsonb)
        )
      );
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.processing_artifact_events (
      organization_id, business_id, event_type, processing_artifact_id,
      workflow_run_id, actor_system, payload
    ) VALUES (
      v_artifact.organization_id, v_artifact.business_id,
      'PROCESSING_ARTIFACT_PRUNED', v_artifact.id,
      v_artifact.workflow_run_id, 'prune-job',
      jsonb_build_object(
        'artifact_type',          v_artifact.artifact_type::text,
        'storage_bucket',         v_artifact.payload_storage_bucket,
        'storage_path',           v_artifact.payload_storage_path,
        'expired_at',             v_artifact.expires_at,
        'storage_cleanup_pending',(v_artifact.payload_storage_path IS NOT NULL)
      )
    );
    DELETE FROM public.processing_artifacts WHERE id = v_artifact.id;
    v_pruned := v_pruned + 1;
  END LOOP;
  RETURN QUERY SELECT v_pruned, v_skipped;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.prune_expired_processing_artifacts(timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.prune_expired_processing_artifacts(timestamptz, integer) TO service_role;
