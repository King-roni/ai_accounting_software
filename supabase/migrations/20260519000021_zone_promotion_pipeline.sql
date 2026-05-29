-- B04·P08 Zone Promotion Pipeline
-- ============================================================================
-- DB-side orchestrator that drains operational rows into the archive at
-- finalization. Bundle ZIP assembly + Storage upload live in the
-- application layer (TypeScript / edge function); this migration provides
-- the atomic SECURITY DEFINER RPCs the orchestrator calls.
--
-- Atomicity contract: promote_workflow_run runs as a single transaction.
-- Either every archive row + audit event commits, or none of them do
-- (the run remains in FINALIZING, Block 15 retries or escalates).
--
-- Adjustment runs: same period as a prior COMPLETE archive_run; promotion
-- adds a new manifest version pointing at the prior archive_run via
-- adjustment_of_archive_run_id. Original archive rows are untouched.
-- ============================================================================

-- ---- ENUM extensions ----------------------------------------------------

ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'ARCHIVE_PROMOTION_STARTED';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'ARCHIVE_PROMOTION_RECORDS_WRITTEN';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'ARCHIVE_PROMOTION_COMPLETED';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'ARCHIVE_PROMOTION_FAILED';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'ARCHIVE_PROMOTION_ROLLED_BACK';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'PROCESSING_PRUNE_SCHEDULED';

-- ---- adjustment-chain column on archive_runs ----------------------------

ALTER TABLE archive.archive_runs
  ADD COLUMN IF NOT EXISTS adjustment_of_archive_run_id uuid
    REFERENCES archive.archive_runs(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_archive_runs_adjustment_of
  ON archive.archive_runs (adjustment_of_archive_run_id)
  WHERE adjustment_of_archive_run_id IS NOT NULL;

-- An adjustment run must declare manifest_version > 1 + point at its
-- parent; a v1 run must NOT carry adjustment_of_archive_run_id.
ALTER TABLE archive.archive_runs
  ADD CONSTRAINT archive_runs_adjustment_consistency_chk CHECK (
    (manifest_version = 1 AND adjustment_of_archive_run_id IS NULL)
    OR (manifest_version > 1 AND adjustment_of_archive_run_id IS NOT NULL)
  );

-- ---- promote_workflow_run -----------------------------------------------
-- Single atomic RPC. On exception, all changes (archive rows, LOCKED
-- flips, audit events, processing-zone TTL updates) roll back together.
-- The caller (orchestrator) wraps this in try/catch + writes
-- ARCHIVE_PROMOTION_FAILED via record_promotion_failure on exception.

CREATE OR REPLACE FUNCTION archive.promote_workflow_run(
  p_workflow_run_id            uuid,
  p_period_start               date,
  p_period_end                 date,
  p_manifest_payload           jsonb,
  p_manifest_hash              text,
  p_prev_manifest_hash         text,
  p_manifest_version           integer DEFAULT 1,
  p_adjustment_of_archive_run_id uuid    DEFAULT NULL,
  p_finalized_by_user_id       uuid    DEFAULT NULL,
  p_archive_writer             text    DEFAULT 'promotion-pipeline'
) RETURNS archive.archive_runs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_wf           public.workflow_runs;
  v_run          archive.archive_runs;
  v_org          uuid;
  v_biz          uuid;
  v_records_ct   integer := 0;
  v_tx_ct        integer := 0;
  v_match_ct     integer := 0;
  v_doc_ct       integer := 0;
  v_ledger_ct    integer := 0;
  v_issue_ct     integer := 0;
  v_locked_ids   uuid[];
  v_proc_ct      integer := 0;
  v_row          record;
  v_is_adjustment boolean := (p_adjustment_of_archive_run_id IS NOT NULL);
BEGIN
  -- Resolve + tenancy guard.
  SELECT * INTO v_wf FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'workflow run % not found', p_workflow_run_id USING ERRCODE = 'P0002';
  END IF;
  IF v_wf.status <> 'FINALIZED' THEN
    RAISE EXCEPTION 'workflow run % must be FINALIZED (got %)', p_workflow_run_id, v_wf.status
      USING ERRCODE = '22023';
  END IF;
  v_org := v_wf.organization_id;
  v_biz := v_wf.business_id;

  -- Adjustment cross-check: parent must exist, COMPLETE, same business, same period.
  IF v_is_adjustment THEN
    PERFORM 1 FROM archive.archive_runs
      WHERE id = p_adjustment_of_archive_run_id
        AND business_id = v_biz
        AND period_start = p_period_start
        AND period_end   = p_period_end
        AND status = 'COMPLETE';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'adjustment parent % not found / wrong tenant / period mismatch',
        p_adjustment_of_archive_run_id USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Open the archive_run (manifest hash chain validation lives here).
  v_run := archive.append_archive_run(
    v_biz, p_workflow_run_id, p_period_start, p_period_end,
    p_manifest_version, p_manifest_payload, p_manifest_hash, p_prev_manifest_hash,
    p_finalized_by_user_id, p_archive_writer, p_adjustment_of_archive_run_id
  );

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, archive_run_id,
    actor_user_id, actor_system, payload
  ) VALUES (
    v_org, v_biz, 'ARCHIVE_PROMOTION_STARTED', v_run.id,
    p_finalized_by_user_id,
    CASE WHEN p_finalized_by_user_id IS NULL THEN p_archive_writer ELSE NULL END,
    jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'is_adjustment', v_is_adjustment,
      'manifest_version', p_manifest_version,
      'adjustment_of_archive_run_id', p_adjustment_of_archive_run_id
    )
  );

  -- ---- record snapshots ----------
  -- Adjustment runs only ingest entities with parent_finalized_run_id IS NOT NULL
  -- (or absent linkage). Initial runs ingest everything scoped to the workflow_run.

  FOR v_row IN
    SELECT id, to_jsonb(t) AS payload
      FROM public.transactions t
     WHERE t.business_id = v_biz
       AND EXISTS (SELECT 1 FROM public.draft_ledger_entries dle
                   WHERE dle.workflow_run_id = p_workflow_run_id
                     AND dle.transaction_id = t.id
                     AND (NOT v_is_adjustment OR dle.parent_finalized_run_id IS NOT NULL))
  LOOP
    PERFORM archive.archive_record(v_run.id, 'TRANSACTION', v_row.id, v_row.payload);
    v_tx_ct := v_tx_ct + 1;
  END LOOP;

  FOR v_row IN
    SELECT id, to_jsonb(d) AS payload
      FROM public.documents d
     WHERE d.business_id = v_biz
       AND EXISTS (SELECT 1 FROM public.draft_ledger_entries dle
                   JOIN public.match_records mr ON mr.id = dle.match_record_id
                   WHERE dle.workflow_run_id = p_workflow_run_id
                     AND mr.document_id = d.id
                     AND (NOT v_is_adjustment OR dle.parent_finalized_run_id IS NOT NULL))
  LOOP
    PERFORM archive.archive_record(v_run.id, 'DOCUMENT', v_row.id, v_row.payload);
    v_doc_ct := v_doc_ct + 1;
  END LOOP;

  FOR v_row IN
    SELECT id, to_jsonb(mr) AS payload
      FROM public.match_records mr
     WHERE mr.business_id = v_biz
       AND EXISTS (SELECT 1 FROM public.draft_ledger_entries dle
                   WHERE dle.workflow_run_id = p_workflow_run_id
                     AND dle.match_record_id = mr.id
                     AND (NOT v_is_adjustment OR dle.parent_finalized_run_id IS NOT NULL))
  LOOP
    PERFORM archive.archive_record(v_run.id, 'MATCH_RECORD', v_row.id, v_row.payload);
    v_match_ct := v_match_ct + 1;
  END LOOP;

  FOR v_row IN
    SELECT id, to_jsonb(dle) AS payload
      FROM public.draft_ledger_entries dle
     WHERE dle.workflow_run_id = p_workflow_run_id
       AND dle.business_id     = v_biz
       AND dle.approval_status = 'APPROVED'
       AND (NOT v_is_adjustment OR dle.parent_finalized_run_id IS NOT NULL)
  LOOP
    PERFORM archive.archive_record(v_run.id, 'LEDGER_ENTRY', v_row.id, v_row.payload);
    v_locked_ids := array_append(v_locked_ids, v_row.id);
    v_ledger_ct := v_ledger_ct + 1;
  END LOOP;

  -- Resolved review_issues only (per spec).
  FOR v_row IN
    SELECT id, to_jsonb(ri) AS payload
      FROM public.review_issues ri
     WHERE ri.workflow_run_id = p_workflow_run_id
       AND ri.business_id     = v_biz
       AND ri.status IN ('RESOLVED','DISMISSED','AUTO_RESOLVED_BY_RESCAN')
  LOOP
    PERFORM archive.archive_record(v_run.id, 'REVIEW_ISSUE', v_row.id, v_row.payload);
    v_issue_ct := v_issue_ct + 1;
  END LOOP;

  -- workflow_runs_summary snapshot (single row).
  INSERT INTO archive.workflow_runs_summary (
    id, organization_id, business_id, archive_run_id, payload
  ) VALUES (
    v_wf.id, v_org, v_biz, v_run.id, to_jsonb(v_wf)
  );

  v_records_ct := v_tx_ct + v_doc_ct + v_match_ct + v_ledger_ct + v_issue_ct + 1;

  -- Lock the archived APPROVED draft_ledger_entries.
  IF v_locked_ids IS NOT NULL AND cardinality(v_locked_ids) > 0 THEN
    UPDATE public.draft_ledger_entries
       SET approval_status = 'LOCKED'
     WHERE id = ANY(v_locked_ids);
  END IF;

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, archive_run_id,
    actor_user_id, actor_system, payload
  ) VALUES (
    v_org, v_biz, 'ARCHIVE_PROMOTION_RECORDS_WRITTEN', v_run.id,
    p_finalized_by_user_id,
    CASE WHEN p_finalized_by_user_id IS NULL THEN p_archive_writer ELSE NULL END,
    jsonb_build_object(
      'transactions', v_tx_ct,
      'documents',    v_doc_ct,
      'match_records', v_match_ct,
      'ledger_entries', v_ledger_ct,
      'review_issues', v_issue_ct,
      'workflow_summary', 1,
      'locked_ledger_entry_ids', to_jsonb(v_locked_ids)
    )
  );

  -- Schedule the processing-zone prune: bump expires_at to now+24h on any
  -- processing_artifacts for this run that don't already have a sooner
  -- expiry. recompute_processing_ttl_for_run only extends.
  PERFORM public.recompute_processing_ttl_for_run(p_workflow_run_id);
  -- count how many processing artifacts now have an expiry set.
  SELECT count(*) INTO v_proc_ct
    FROM public.processing_artifacts
   WHERE workflow_run_id = p_workflow_run_id AND expires_at IS NOT NULL;

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, archive_run_id,
    actor_system, payload
  ) VALUES (
    v_org, v_biz, 'PROCESSING_PRUNE_SCHEDULED', v_run.id, p_archive_writer,
    jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'processing_artifacts_scheduled', v_proc_ct
    )
  );

  RETURN v_run;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION archive.promote_workflow_run(uuid, date, date, jsonb, text, text, integer, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION archive.promote_workflow_run(uuid, date, date, jsonb, text, text, integer, uuid, uuid, text) TO service_role;

-- ---- rollback_promotion -------------------------------------------------
-- Reverts a (still-PENDING) archive_run: unlocks the ledger entries that
-- were just promoted, deletes the archive snapshots + the archive_run row.
-- Caller (orchestrator) uses this when Storage upload fails post-DB-commit.

CREATE OR REPLACE FUNCTION archive.rollback_promotion(
  p_archive_run_id uuid,
  p_reason         text DEFAULT 'rollback_requested'
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_run        archive.archive_runs;
  v_locked_ids uuid[];
  v_total      integer := 0;
  v_count      integer;
BEGIN
  SELECT * INTO v_run FROM archive.archive_runs WHERE id = p_archive_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'archive run % not found', p_archive_run_id USING ERRCODE = 'P0002';
  END IF;
  IF v_run.status <> 'PENDING' THEN
    RAISE EXCEPTION 'cannot rollback archive_run % in status %', p_archive_run_id, v_run.status
      USING ERRCODE = '22023';
  END IF;

  -- Unlock any ledger entries we just locked.
  SELECT array_agg(id) INTO v_locked_ids
    FROM archive.ledger_entries WHERE archive_run_id = p_archive_run_id;
  IF v_locked_ids IS NOT NULL AND cardinality(v_locked_ids) > 0 THEN
    UPDATE public.draft_ledger_entries
       SET approval_status = 'APPROVED'
     WHERE id = ANY(v_locked_ids) AND approval_status = 'LOCKED';
  END IF;

  -- Delete archive children + the archive_run itself.
  PERFORM set_config('archive.allow_delete', 'on', true);
  DELETE FROM archive.transactions       WHERE archive_run_id = p_archive_run_id; GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  DELETE FROM archive.match_records      WHERE archive_run_id = p_archive_run_id; GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  DELETE FROM archive.documents          WHERE archive_run_id = p_archive_run_id; GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  DELETE FROM archive.evidence_pdfs      WHERE archive_run_id = p_archive_run_id; GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  DELETE FROM archive.ledger_entries     WHERE archive_run_id = p_archive_run_id; GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  DELETE FROM archive.review_issues      WHERE archive_run_id = p_archive_run_id; GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  DELETE FROM archive.workflow_runs_summary WHERE archive_run_id = p_archive_run_id; GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  DELETE FROM archive.archive_runs       WHERE id = p_archive_run_id;             GET DIAGNOSTICS v_count=ROW_COUNT; v_total := v_total + v_count;
  PERFORM set_config('archive.allow_delete', 'off', true);

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, archive_run_id,
    actor_system, payload
  ) VALUES (
    v_run.organization_id, v_run.business_id, 'ARCHIVE_PROMOTION_ROLLED_BACK', NULL,
    'promotion-pipeline',
    jsonb_build_object(
      'archive_run_id',          p_archive_run_id,
      'workflow_run_id',         v_run.workflow_run_id,
      'reason',                  p_reason,
      'rows_deleted',            v_total,
      'unlocked_ledger_entry_ids', to_jsonb(v_locked_ids)
    )
  );

  RETURN v_total;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION archive.rollback_promotion(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION archive.rollback_promotion(uuid, text) TO service_role;

-- ---- record_promotion_failure ------------------------------------------
-- Audit-only RPC the orchestrator calls when promote_workflow_run raises.
-- Runs in its own transaction (so the audit row persists across the
-- failed promotion's rollback).

CREATE OR REPLACE FUNCTION archive.record_promotion_failure(
  p_business_id        uuid,
  p_workflow_run_id    uuid,
  p_reason             text,
  p_error_payload      jsonb DEFAULT '{}'::jsonb,
  p_archive_writer     text  DEFAULT 'promotion-pipeline'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_org uuid;
BEGIN
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'business % not found', p_business_id USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, archive_run_id,
    actor_system, payload
  ) VALUES (
    v_org, p_business_id, 'ARCHIVE_PROMOTION_FAILED', NULL,
    p_archive_writer,
    jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'reason',          p_reason,
      'error',           p_error_payload
    )
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION archive.record_promotion_failure(uuid, uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION archive.record_promotion_failure(uuid, uuid, text, jsonb, text) TO service_role;

COMMENT ON FUNCTION archive.promote_workflow_run(uuid, date, date, jsonb, text, text, integer, uuid, uuid, text) IS
'B04·P08 promotion orchestrator: opens archive_run (validating manifest chain), snapshots operational entities (transactions / documents / match_records / draft_ledger_entries / resolved review_issues / workflow summary), locks APPROVED ledger entries -> LOCKED, schedules processing-zone prune, emits the STARTED/RECORDS_WRITTEN/PRUNE_SCHEDULED audits. Atomic — exceptions roll back everything.';
COMMENT ON FUNCTION archive.rollback_promotion(uuid, text) IS
'B04·P08 promotion rollback: unlocks the ledger entries we just promoted, deletes the archive children + the archive_run row, emits ARCHIVE_PROMOTION_ROLLED_BACK. Caller uses this when Storage upload fails after a successful DB-side promotion.';
COMMENT ON FUNCTION archive.record_promotion_failure(uuid, uuid, text, jsonb, text) IS
'B04·P08 promotion failure audit: stand-alone audit emission for promotion-failure scenarios (the failed promotion''s transaction rolled back, so the orchestrator calls this in a fresh transaction to record the event).';
