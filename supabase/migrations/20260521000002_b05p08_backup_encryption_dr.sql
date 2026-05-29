-- B05·P08 Backup Encryption & DR
-- ============================================================================
-- DB-side metadata + orchestration primitives for the backup + disaster
-- recovery layer. Actual pg_dump scheduling, Storage replication, and restore
-- execution live at the platform / API-worker layer; this phase ships the
-- tracking tables + RPCs + audit emission + multi-party authorisation gate.
--
-- Backup encryption keys live in the BACKUP_ENCRYPTION category of B05·P07's
-- secrets manager (365d rotation + 30d overlap). Each backup_records row
-- records the EXACT vault.secrets.id that encrypted the backup — so
-- restoration fetches that specific key regardless of subsequent rotations
-- (overlap semantics are implicit: any backup is recoverable as long as its
-- vault row persists).
-- ============================================================================

-- ---- subject_type extensions -------------------------------------------------
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'BACKUP';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'RESTORE_RUN';

-- ---- backups schema + enums --------------------------------------------------
CREATE SCHEMA IF NOT EXISTS backups;

CREATE TYPE backups.backup_source_enum AS ENUM ('POSTGRES','STORAGE');
CREATE TYPE backups.backup_status_enum AS ENUM ('STARTED','COMPLETED','FAILED');
CREATE TYPE backups.restore_status_enum AS ENUM (
  'INITIATED','QUARANTINE_LOADED','VERIFICATION_PASSED','VERIFICATION_FAILED',
  'PROMOTED_TO_PRODUCTION','REJECTED'
);
CREATE TYPE backups.replication_lag_status_enum AS ENUM ('OK','EXCEEDED');
CREATE TYPE backups.restore_type_enum AS ENUM ('WEEKLY_TEST','MONTHLY_DR_DRILL','PRODUCTION_RESTORE','AD_HOC');

-- ---- PRODUCTION_RESTORE sensitive surface ------------------------------------
-- Tighter 60s window — same as KEY_DESTRUCTION (irreversible destructive op).
INSERT INTO auth_runtime.sensitive_surfaces (surface, step_up_window, description)
VALUES ('PRODUCTION_RESTORE', '60 seconds', 'Production restore from backup (B05·P08) — multi-party + tight step-up window')
ON CONFLICT (surface) DO NOTHING;

-- ---- backups.backup_records --------------------------------------------------
CREATE TABLE backups.backup_records (
  id                 uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  source             backups.backup_source_enum NOT NULL,
  source_name        text NOT NULL,  -- 'postgres' for POSTGRES, bucket name for STORAGE
  period_start       timestamptz NOT NULL,
  period_end         timestamptz NOT NULL,
  bytes              bigint,
  backup_hash        text,   -- SHA-256 64-hex
  encryption_key_id  uuid NOT NULL,  -- exact vault.secrets.id at encryption time
  location           text,
  status             backups.backup_status_enum NOT NULL DEFAULT 'STARTED',
  started_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at       timestamptz,
  failed_at          timestamptz,
  failure_reason     text,
  CONSTRAINT backup_records_period_order_chk    CHECK (period_end > period_start),
  CONSTRAINT backup_records_source_name_nonempty CHECK (length(btrim(source_name)) > 0),
  CONSTRAINT backup_records_hash_format_chk     CHECK (backup_hash IS NULL OR backup_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT backup_records_state_consistency_chk CHECK (
    (status = 'STARTED'   AND completed_at IS NULL AND failed_at IS NULL AND bytes IS NULL  AND backup_hash IS NULL  AND location IS NULL AND failure_reason IS NULL)
    OR
    (status = 'COMPLETED' AND completed_at IS NOT NULL AND failed_at IS NULL AND bytes IS NOT NULL AND backup_hash IS NOT NULL AND location IS NOT NULL)
    OR
    (status = 'FAILED'    AND failed_at IS NOT NULL AND completed_at IS NULL AND failure_reason IS NOT NULL)
  ),
  CONSTRAINT backup_records_bytes_nonneg_chk    CHECK (bytes IS NULL OR bytes >= 0)
);

CREATE INDEX idx_backup_records_source_period      ON backups.backup_records (source, period_end DESC);
CREATE INDEX idx_backup_records_status             ON backups.backup_records (status);
CREATE INDEX idx_backup_records_encryption_key_id  ON backups.backup_records (encryption_key_id);

-- ---- backups.restore_runs ----------------------------------------------------
CREATE TABLE backups.restore_runs (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  restore_type                backups.restore_type_enum NOT NULL,
  backup_record_id            uuid NOT NULL REFERENCES backups.backup_records(id) ON DELETE RESTRICT,
  initiated_by_user_id        uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  second_authoriser_user_id   uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  quarantine_namespace        text NOT NULL,
  status                      backups.restore_status_enum NOT NULL DEFAULT 'INITIATED',
  audit_chain_verified        boolean,
  archive_hashes_verified     boolean,
  verification_details        jsonb,
  initiated_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  quarantine_loaded_at        timestamptz,
  verification_at             timestamptz,
  promoted_at                 timestamptz,
  rejected_at                 timestamptz,
  rejection_reason            text,
  CONSTRAINT restore_runs_distinct_authorisers_chk CHECK (initiated_by_user_id <> second_authoriser_user_id),
  CONSTRAINT restore_runs_quarantine_nonempty_chk  CHECK (length(btrim(quarantine_namespace)) > 0)
);

CREATE INDEX idx_restore_runs_status        ON backups.restore_runs (status);
CREATE INDEX idx_restore_runs_backup        ON backups.restore_runs (backup_record_id);
CREATE INDEX idx_restore_runs_initiator     ON backups.restore_runs (initiated_by_user_id);
CREATE INDEX idx_restore_runs_authoriser    ON backups.restore_runs (second_authoriser_user_id);
CREATE INDEX idx_restore_runs_initiated_at  ON backups.restore_runs (initiated_at DESC);

-- ---- backups.replication_status ----------------------------------------------
CREATE TABLE backups.replication_status (
  source_key          text PRIMARY KEY,  -- e.g., 'archive-bundles', 'raw-uploads', 'postgres-wal'
  source_region       text NOT NULL,
  replica_region      text NOT NULL,
  lag_seconds         int NOT NULL,
  threshold_seconds   int NOT NULL,
  lag_status          backups.replication_lag_status_enum NOT NULL,
  last_observed_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT replication_status_lag_nonneg_chk        CHECK (lag_seconds >= 0),
  CONSTRAINT replication_status_threshold_positive_chk CHECK (threshold_seconds > 0),
  CONSTRAINT replication_status_regions_differ_chk    CHECK (source_region <> replica_region),
  CONSTRAINT replication_status_lag_status_consistent CHECK (
    (lag_status = 'EXCEEDED' AND lag_seconds > threshold_seconds)
    OR (lag_status = 'OK' AND lag_seconds <= threshold_seconds)
  )
);

CREATE INDEX idx_replication_status_lag ON backups.replication_status (lag_status, last_observed_at DESC);

-- ---- RLS ---------------------------------------------------------------------
-- backups.* tables are platform-internal. authenticated has no access at all.
ALTER TABLE backups.backup_records      ENABLE ROW LEVEL SECURITY;
ALTER TABLE backups.backup_records      FORCE  ROW LEVEL SECURITY;
ALTER TABLE backups.restore_runs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE backups.restore_runs        FORCE  ROW LEVEL SECURITY;
ALTER TABLE backups.replication_status  ENABLE ROW LEVEL SECURITY;
ALTER TABLE backups.replication_status  FORCE  ROW LEVEL SECURITY;

CREATE POLICY backup_records_no_authenticated      ON backups.backup_records      AS RESTRICTIVE FOR ALL TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY restore_runs_no_authenticated        ON backups.restore_runs        AS RESTRICTIVE FOR ALL TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY replication_status_no_authenticated  ON backups.replication_status  AS RESTRICTIVE FOR ALL TO authenticated USING (false) WITH CHECK (false);

GRANT USAGE  ON SCHEMA backups TO service_role;
GRANT SELECT ON backups.backup_records, backups.restore_runs, backups.replication_status TO service_role;

-- ---- RPC: record_backup_started ---------------------------------------------
CREATE OR REPLACE FUNCTION backups.record_backup_started(
  p_source            backups.backup_source_enum,
  p_source_name       text,
  p_period_start      timestamptz,
  p_period_end        timestamptz,
  p_encryption_key_id uuid
) RETURNS backups.backup_records
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, vault, public, pg_temp
AS $fn$
DECLARE
  v_row     backups.backup_records;
  v_key_ok  boolean;
BEGIN
  IF p_source IS NULL THEN RAISE EXCEPTION 'record_backup_started: source required' USING ERRCODE='22000'; END IF;
  IF p_source_name IS NULL OR length(btrim(p_source_name)) = 0 THEN RAISE EXCEPTION 'record_backup_started: source_name required' USING ERRCODE='22000'; END IF;
  IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end <= p_period_start THEN
    RAISE EXCEPTION 'record_backup_started: invalid period (% .. %)', p_period_start, p_period_end USING ERRCODE='22000';
  END IF;
  IF p_encryption_key_id IS NULL THEN RAISE EXCEPTION 'record_backup_started: encryption_key_id required' USING ERRCODE='22000'; END IF;

  SELECT EXISTS (SELECT 1 FROM vault.secrets WHERE id = p_encryption_key_id) INTO v_key_ok;
  IF NOT v_key_ok THEN
    RAISE EXCEPTION 'record_backup_started: encryption_key_id % not found in vault.secrets', p_encryption_key_id USING ERRCODE='P0002';
  END IF;

  INSERT INTO backups.backup_records (source, source_name, period_start, period_end, encryption_key_id, status)
  VALUES (p_source, p_source_name, p_period_start, p_period_end, p_encryption_key_id, 'STARTED')
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'BACKUP_STARTED',
    p_subject_type => 'BACKUP'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'backups.record_backup_started',
    p_reason       => format('%s backup of %s started for period %s .. %s', p_source, p_source_name, p_period_start, p_period_end),
    p_after_state  => jsonb_build_object(
      'backup_id', v_row.id,
      'source', p_source, 'source_name', p_source_name,
      'period_start', p_period_start, 'period_end', p_period_end,
      'encryption_key_id', p_encryption_key_id
    )
  );

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.record_backup_started(backups.backup_source_enum, text, timestamptz, timestamptz, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.record_backup_started(backups.backup_source_enum, text, timestamptz, timestamptz, uuid) TO service_role;

-- ---- RPC: record_backup_completed -------------------------------------------
CREATE OR REPLACE FUNCTION backups.record_backup_completed(
  p_backup_id    uuid,
  p_bytes        bigint,
  p_backup_hash  text,
  p_location     text
) RETURNS backups.backup_records
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_row backups.backup_records;
BEGIN
  IF p_backup_id IS NULL THEN RAISE EXCEPTION 'record_backup_completed: backup_id required' USING ERRCODE='22000'; END IF;
  IF p_bytes IS NULL OR p_bytes < 0 THEN RAISE EXCEPTION 'record_backup_completed: bytes >= 0 required' USING ERRCODE='22000'; END IF;
  IF p_backup_hash IS NULL OR p_backup_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'record_backup_completed: backup_hash must be 64-hex' USING ERRCODE='22000';
  END IF;
  IF p_location IS NULL OR length(btrim(p_location)) = 0 THEN
    RAISE EXCEPTION 'record_backup_completed: location required' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_row FROM backups.backup_records WHERE id = p_backup_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_backup_completed: backup % not found', p_backup_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'STARTED' THEN
    RAISE EXCEPTION 'record_backup_completed: backup % not in STARTED (got %)', p_backup_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE backups.backup_records
     SET status       = 'COMPLETED',
         bytes        = p_bytes,
         backup_hash  = p_backup_hash,
         location     = p_location,
         completed_at = clock_timestamp()
   WHERE id = p_backup_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'BACKUP_COMPLETED',
    p_subject_type => 'BACKUP'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'backups.record_backup_completed',
    p_reason       => format('backup %s completed (%s bytes)', p_backup_id, p_bytes),
    p_after_state  => jsonb_build_object(
      'backup_id', v_row.id, 'bytes', p_bytes, 'backup_hash', p_backup_hash, 'location', p_location
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.record_backup_completed(uuid, bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.record_backup_completed(uuid, bigint, text, text) TO service_role;

-- ---- RPC: record_backup_failed (Mitigation B fresh-tx callable) -------------
CREATE OR REPLACE FUNCTION backups.record_backup_failed(
  p_backup_id      uuid,
  p_failure_reason text
) RETURNS backups.backup_records
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_row backups.backup_records;
BEGIN
  IF p_backup_id IS NULL THEN RAISE EXCEPTION 'record_backup_failed: backup_id required' USING ERRCODE='22000'; END IF;
  IF p_failure_reason IS NULL OR length(btrim(p_failure_reason)) = 0 THEN
    RAISE EXCEPTION 'record_backup_failed: failure_reason required' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_row FROM backups.backup_records WHERE id = p_backup_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_backup_failed: backup % not found', p_backup_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'STARTED' THEN
    RAISE EXCEPTION 'record_backup_failed: backup % not in STARTED (got %)', p_backup_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE backups.backup_records
     SET status         = 'FAILED',
         failed_at      = clock_timestamp(),
         failure_reason = p_failure_reason
   WHERE id = p_backup_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'BACKUP_FAILED',
    p_subject_type => 'BACKUP'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'backups.record_backup_failed',
    p_reason       => format('backup %s failed: %s', p_backup_id, p_failure_reason),
    p_after_state  => jsonb_build_object('backup_id', v_row.id, 'failure_reason', p_failure_reason)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.record_backup_failed(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.record_backup_failed(uuid, text) TO service_role;

-- ---- RPC: report_replication_lag --------------------------------------------
CREATE OR REPLACE FUNCTION backups.report_replication_lag(
  p_source_key        text,
  p_source_region     text,
  p_replica_region    text,
  p_lag_seconds       int,
  p_threshold_seconds int
) RETURNS backups.replication_status
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_row    backups.replication_status;
  v_status backups.replication_lag_status_enum;
BEGIN
  IF p_source_key IS NULL OR length(btrim(p_source_key)) = 0 THEN
    RAISE EXCEPTION 'report_replication_lag: source_key required' USING ERRCODE='22000';
  END IF;
  IF p_source_region IS NULL OR p_replica_region IS NULL OR p_source_region = p_replica_region THEN
    RAISE EXCEPTION 'report_replication_lag: source/replica regions must differ' USING ERRCODE='22000';
  END IF;
  IF p_lag_seconds IS NULL OR p_lag_seconds < 0 THEN
    RAISE EXCEPTION 'report_replication_lag: lag_seconds >= 0 required' USING ERRCODE='22000';
  END IF;
  IF p_threshold_seconds IS NULL OR p_threshold_seconds <= 0 THEN
    RAISE EXCEPTION 'report_replication_lag: threshold_seconds > 0 required' USING ERRCODE='22000';
  END IF;

  v_status := CASE WHEN p_lag_seconds > p_threshold_seconds THEN 'EXCEEDED' ELSE 'OK' END;

  INSERT INTO backups.replication_status (source_key, source_region, replica_region, lag_seconds, threshold_seconds, lag_status, last_observed_at)
  VALUES (p_source_key, p_source_region, p_replica_region, p_lag_seconds, p_threshold_seconds, v_status, clock_timestamp())
  ON CONFLICT (source_key) DO UPDATE SET
    source_region     = EXCLUDED.source_region,
    replica_region    = EXCLUDED.replica_region,
    lag_seconds       = EXCLUDED.lag_seconds,
    threshold_seconds = EXCLUDED.threshold_seconds,
    lag_status        = EXCLUDED.lag_status,
    last_observed_at  = EXCLUDED.last_observed_at
  RETURNING * INTO v_row;

  IF v_status = 'EXCEEDED' THEN
    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'BACKUP_REPLICATION_LAG_EXCEEDED',
      p_subject_type => 'BACKUP'::audit.subject_type_enum,
      p_actor_system => 'backups.report_replication_lag',
      p_reason       => format('replication lag %ss exceeds threshold %ss for %s', p_lag_seconds, p_threshold_seconds, p_source_key),
      p_after_state  => jsonb_build_object(
        'source_key', p_source_key, 'source_region', p_source_region, 'replica_region', p_replica_region,
        'lag_seconds', p_lag_seconds, 'threshold_seconds', p_threshold_seconds, 'alert', 'WARNING'
      )
    );
  END IF;
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.report_replication_lag(text, text, text, int, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.report_replication_lag(text, text, text, int, int) TO service_role;

-- ---- RPC: get_backup_decryption_key ------------------------------------------
-- Returns the EXACT vault.decrypted_secrets value for the backup's
-- recorded encryption_key_id. Overlap-window semantics are implicit: any
-- backup is decryptable as long as its vault row persists (which it does
-- as long as managed_secrets.previous_vault_secret_id retains a reference,
-- or the vault row hasn't been explicitly removed).
--
-- Mitigation A — returns NULL on lookup failure (audit-then-raise hazard
-- mitigated). Caller branches on NULL.

CREATE OR REPLACE FUNCTION backups.get_backup_decryption_key(p_backup_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, vault, audit, public, pg_temp
AS $fn$
DECLARE
  v_row    backups.backup_records;
  v_value  text;
BEGIN
  IF p_backup_id IS NULL THEN
    RAISE EXCEPTION 'get_backup_decryption_key: backup_id required' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_row FROM backups.backup_records WHERE id = p_backup_id;
  IF NOT FOUND THEN
    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'SECRET_ACCESS_DENIED',
      p_subject_type => 'BACKUP'::audit.subject_type_enum,
      p_actor_system => 'backups.get_backup_decryption_key',
      p_reason       => format('backup %s not found', p_backup_id),
      p_after_state  => jsonb_build_object('backup_id', p_backup_id, 'reason_code', 'BACKUP_NOT_FOUND')
    );
    RETURN NULL;
  END IF;

  BEGIN
    SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE id = v_row.encryption_key_id;
  EXCEPTION WHEN OTHERS THEN
    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'SECRET_ACCESS_FAILED',
      p_subject_type => 'BACKUP'::audit.subject_type_enum,
      p_subject_id   => v_row.id,
      p_actor_system => 'backups.get_backup_decryption_key',
      p_reason       => format('vault read failed for backup %s', p_backup_id),
      p_after_state  => jsonb_build_object('backup_id', p_backup_id, 'encryption_key_id', v_row.encryption_key_id, 'reason_code', 'VAULT_READ_FAILED')
    );
    RETURN NULL;
  END;

  IF v_value IS NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'SECRET_ACCESS_DENIED',
      p_subject_type => 'BACKUP'::audit.subject_type_enum,
      p_subject_id   => v_row.id,
      p_actor_system => 'backups.get_backup_decryption_key',
      p_reason       => format('vault row missing for backup %s', p_backup_id),
      p_after_state  => jsonb_build_object('backup_id', p_backup_id, 'encryption_key_id', v_row.encryption_key_id, 'reason_code', 'VAULT_ROW_MISSING')
    );
    RETURN NULL;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'SECRET_ACCESSED',
    p_subject_type => 'BACKUP'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'backups.get_backup_decryption_key',
    p_reason       => format('backup %s decryption key fetched', p_backup_id),
    p_after_state  => jsonb_build_object('backup_id', p_backup_id, 'encryption_key_id', v_row.encryption_key_id)
  );
  RETURN v_value;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.get_backup_decryption_key(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.get_backup_decryption_key(uuid) TO service_role;

-- ---- RPC: initiate_restore (multi-party gate) -------------------------------
-- Mitigation A — returns jsonb envelope. Multi-party check:
--   1. Two distinct user ids
--   2. Both users have at least one ACTIVE business_user_role with role=OWNER
--   3. Both users have mfa_recent_at within PRODUCTION_RESTORE's step_up_window
-- On denial: emits RESTORE_REJECTED + returns {success:false, denial_reason, ...}.
-- On success: INSERTs restore_runs + emits RESTORE_INITIATED.

CREATE OR REPLACE FUNCTION backups.initiate_restore(
  p_backup_record_id          uuid,
  p_initiated_by_user_id      uuid,
  p_second_authoriser_user_id uuid,
  p_restore_type              backups.restore_type_enum,
  p_quarantine_namespace      text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, auth_runtime, audit, public, pg_temp
AS $fn$
DECLARE
  v_backup   backups.backup_records;
  v_window   interval;
  v_now      timestamptz := clock_timestamp();
  v_init_mfa timestamptz;
  v_sec_mfa  timestamptz;
  v_init_owner boolean;
  v_sec_owner  boolean;
  v_row        backups.restore_runs;
  v_denial     text;
BEGIN
  -- Validation (RAISES — programming errors)
  IF p_backup_record_id IS NULL THEN
    RAISE EXCEPTION 'initiate_restore: backup_record_id required' USING ERRCODE='22000';
  END IF;
  IF p_initiated_by_user_id IS NULL OR p_second_authoriser_user_id IS NULL THEN
    RAISE EXCEPTION 'initiate_restore: both user ids required' USING ERRCODE='22000';
  END IF;
  IF p_initiated_by_user_id = p_second_authoriser_user_id THEN
    RAISE EXCEPTION 'initiate_restore: initiator and second_authoriser must differ' USING ERRCODE='22000';
  END IF;
  IF p_restore_type IS NULL THEN
    RAISE EXCEPTION 'initiate_restore: restore_type required' USING ERRCODE='22000';
  END IF;
  IF p_quarantine_namespace IS NULL OR length(btrim(p_quarantine_namespace)) = 0 THEN
    RAISE EXCEPTION 'initiate_restore: quarantine_namespace required' USING ERRCODE='22000';
  END IF;

  -- Backup must exist + be COMPLETED
  SELECT * INTO v_backup FROM backups.backup_records WHERE id = p_backup_record_id;
  IF NOT FOUND THEN
    v_denial := 'BACKUP_NOT_FOUND';
  ELSIF v_backup.status <> 'COMPLETED' THEN
    v_denial := 'BACKUP_NOT_COMPLETED';
  END IF;

  IF v_denial IS NULL THEN
    -- Window lookup
    SELECT step_up_window INTO v_window FROM auth_runtime.sensitive_surfaces WHERE surface = 'PRODUCTION_RESTORE';
    IF v_window IS NULL THEN v_window := '60 seconds'::interval; END IF;

    -- Initiator OWNER + recent MFA
    SELECT EXISTS (
      SELECT 1 FROM public.business_user_roles
       WHERE user_id = p_initiated_by_user_id AND status = 'ACTIVE' AND role = 'OWNER'
    ) INTO v_init_owner;
    SELECT mfa_recent_at INTO v_init_mfa FROM public.users WHERE id = p_initiated_by_user_id;

    -- Second authoriser OWNER + recent MFA
    SELECT EXISTS (
      SELECT 1 FROM public.business_user_roles
       WHERE user_id = p_second_authoriser_user_id AND status = 'ACTIVE' AND role = 'OWNER'
    ) INTO v_sec_owner;
    SELECT mfa_recent_at INTO v_sec_mfa FROM public.users WHERE id = p_second_authoriser_user_id;

    IF NOT v_init_owner THEN v_denial := 'INITIATOR_NOT_OWNER';
    ELSIF NOT v_sec_owner THEN v_denial := 'SECOND_AUTHORISER_NOT_OWNER';
    ELSIF v_init_mfa IS NULL OR (v_now - v_init_mfa) > v_window THEN v_denial := 'INITIATOR_MFA_STALE';
    ELSIF v_sec_mfa IS NULL OR (v_now - v_sec_mfa) > v_window THEN v_denial := 'SECOND_AUTHORISER_MFA_STALE';
    END IF;
  END IF;

  IF v_denial IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind     => 'USER'::audit.actor_kind_enum,
      p_action         => 'RESTORE_REJECTED',
      p_subject_type   => 'RESTORE_RUN'::audit.subject_type_enum,
      p_actor_user_id  => p_initiated_by_user_id,
      p_actor_system   => NULL,
      p_reason         => format('restore initiation rejected: %s', v_denial),
      p_after_state    => jsonb_build_object(
        'backup_record_id', p_backup_record_id,
        'initiated_by',     p_initiated_by_user_id,
        'second_authoriser', p_second_authoriser_user_id,
        'restore_type',     p_restore_type,
        'denial_reason',    v_denial,
        'phase',            'initiation'
      )
    );
    RETURN jsonb_build_object(
      'success',         false,
      'denial_reason',   v_denial,
      'backup_record_id', p_backup_record_id,
      'message',         format('restore initiation rejected: %s', v_denial)
    );
  END IF;

  INSERT INTO backups.restore_runs (
    restore_type, backup_record_id, initiated_by_user_id, second_authoriser_user_id,
    quarantine_namespace, status, initiated_at
  ) VALUES (
    p_restore_type, p_backup_record_id, p_initiated_by_user_id, p_second_authoriser_user_id,
    p_quarantine_namespace, 'INITIATED', v_now
  )
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'RESTORE_INITIATED',
    p_subject_type   => 'RESTORE_RUN'::audit.subject_type_enum,
    p_subject_id     => v_row.id,
    p_actor_user_id  => p_initiated_by_user_id,
    p_reason         => format('restore %s initiated (%s)', v_row.id, p_restore_type),
    p_after_state    => jsonb_build_object(
      'restore_run_id',   v_row.id,
      'backup_record_id', p_backup_record_id,
      'initiated_by',     p_initiated_by_user_id,
      'second_authoriser', p_second_authoriser_user_id,
      'restore_type',     p_restore_type,
      'quarantine_namespace', p_quarantine_namespace
    )
  );

  RETURN jsonb_build_object(
    'success',        true,
    'restore_run_id', v_row.id,
    'status',         v_row.status,
    'quarantine_namespace', v_row.quarantine_namespace
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.initiate_restore(uuid, uuid, uuid, backups.restore_type_enum, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.initiate_restore(uuid, uuid, uuid, backups.restore_type_enum, text) TO service_role;

-- ---- RPC: record_quarantine_loaded ------------------------------------------
CREATE OR REPLACE FUNCTION backups.record_quarantine_loaded(p_restore_run_id uuid)
RETURNS backups.restore_runs
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_row backups.restore_runs;
BEGIN
  IF p_restore_run_id IS NULL THEN RAISE EXCEPTION 'record_quarantine_loaded: id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_row FROM backups.restore_runs WHERE id = p_restore_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_quarantine_loaded: % not found', p_restore_run_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'INITIATED' THEN
    RAISE EXCEPTION 'record_quarantine_loaded: % not in INITIATED (got %)', p_restore_run_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE backups.restore_runs
     SET status = 'QUARANTINE_LOADED', quarantine_loaded_at = clock_timestamp()
   WHERE id = p_restore_run_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'RESTORE_QUARANTINE_LOADED',
    p_subject_type => 'RESTORE_RUN'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'backups.record_quarantine_loaded',
    p_reason       => format('restore %s loaded into quarantine namespace %s', v_row.id, v_row.quarantine_namespace),
    p_after_state  => jsonb_build_object('restore_run_id', v_row.id, 'quarantine_namespace', v_row.quarantine_namespace)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.record_quarantine_loaded(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.record_quarantine_loaded(uuid) TO service_role;

-- ---- RPC: verify_restored_data ----------------------------------------------
CREATE OR REPLACE FUNCTION backups.verify_restored_data(
  p_restore_run_id          uuid,
  p_chain_id                uuid,
  p_archive_hashes_verified boolean,
  p_archive_details         jsonb DEFAULT NULL
) RETURNS backups.restore_runs
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_row          backups.restore_runs;
  v_chain_result jsonb;
  v_chain_ok     boolean;
  v_overall_ok   boolean;
  v_now          timestamptz := clock_timestamp();
BEGIN
  IF p_restore_run_id IS NULL THEN RAISE EXCEPTION 'verify_restored_data: id required' USING ERRCODE='22000'; END IF;
  IF p_chain_id IS NULL THEN RAISE EXCEPTION 'verify_restored_data: chain_id required' USING ERRCODE='22000'; END IF;
  IF p_archive_hashes_verified IS NULL THEN RAISE EXCEPTION 'verify_restored_data: archive_hashes_verified required' USING ERRCODE='22000'; END IF;

  SELECT * INTO v_row FROM backups.restore_runs WHERE id = p_restore_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'verify_restored_data: % not found', p_restore_run_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'QUARANTINE_LOADED' THEN
    RAISE EXCEPTION 'verify_restored_data: % must be in QUARANTINE_LOADED (got %)', p_restore_run_id, v_row.status USING ERRCODE='23514';
  END IF;

  -- Re-verify the audit chain via Phase 03 primitive
  v_chain_result := audit.verify_restored_chain(p_chain_id);
  v_chain_ok     := (v_chain_result->>'verified')::boolean;
  v_overall_ok   := v_chain_ok AND p_archive_hashes_verified;

  UPDATE backups.restore_runs
     SET status                  = (CASE WHEN v_overall_ok THEN 'VERIFICATION_PASSED' ELSE 'VERIFICATION_FAILED' END)::backups.restore_status_enum,
         audit_chain_verified    = v_chain_ok,
         archive_hashes_verified = p_archive_hashes_verified,
         verification_details    = jsonb_build_object(
            'audit_chain', v_chain_result,
            'archive', COALESCE(p_archive_details, jsonb_build_object('verified', p_archive_hashes_verified))
         ),
         verification_at         = v_now
   WHERE id = p_restore_run_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => CASE WHEN v_overall_ok THEN 'RESTORE_VERIFICATION_PASSED' ELSE 'RESTORE_VERIFICATION_FAILED' END,
    p_subject_type => 'RESTORE_RUN'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'backups.verify_restored_data',
    p_reason       => format('restore %s verification %s', v_row.id, CASE WHEN v_overall_ok THEN 'PASSED' ELSE 'FAILED' END),
    p_after_state  => jsonb_build_object(
      'restore_run_id', v_row.id,
      'audit_chain_verified',    v_chain_ok,
      'archive_hashes_verified', p_archive_hashes_verified,
      'verified',                v_overall_ok
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.verify_restored_data(uuid, uuid, boolean, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.verify_restored_data(uuid, uuid, boolean, jsonb) TO service_role;

-- ---- RPC: promote_restore_to_production -------------------------------------
CREATE OR REPLACE FUNCTION backups.promote_restore_to_production(p_restore_run_id uuid)
RETURNS backups.restore_runs
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_row backups.restore_runs;
BEGIN
  IF p_restore_run_id IS NULL THEN RAISE EXCEPTION 'promote_restore: id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_row FROM backups.restore_runs WHERE id = p_restore_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'promote_restore: % not found', p_restore_run_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'VERIFICATION_PASSED' THEN
    RAISE EXCEPTION 'promote_restore: % must be in VERIFICATION_PASSED (got %)', p_restore_run_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE backups.restore_runs
     SET status = 'PROMOTED_TO_PRODUCTION', promoted_at = clock_timestamp()
   WHERE id = p_restore_run_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'RESTORE_PROMOTED_TO_PRODUCTION',
    p_subject_type   => 'RESTORE_RUN'::audit.subject_type_enum,
    p_subject_id     => v_row.id,
    p_actor_user_id  => v_row.initiated_by_user_id,
    p_reason         => format('restore %s promoted to production', v_row.id),
    p_after_state    => jsonb_build_object(
      'restore_run_id', v_row.id, 'restore_type', v_row.restore_type, 'promoted_at', v_row.promoted_at, 'alert', 'WARNING'
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.promote_restore_to_production(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.promote_restore_to_production(uuid) TO service_role;

-- ---- RPC: reject_restore ----------------------------------------------------
CREATE OR REPLACE FUNCTION backups.reject_restore(
  p_restore_run_id uuid,
  p_reason         text
) RETURNS backups.restore_runs
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_row backups.restore_runs;
BEGIN
  IF p_restore_run_id IS NULL THEN RAISE EXCEPTION 'reject_restore: id required' USING ERRCODE='22000'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN RAISE EXCEPTION 'reject_restore: reason required' USING ERRCODE='22000'; END IF;

  SELECT * INTO v_row FROM backups.restore_runs WHERE id = p_restore_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'reject_restore: % not found', p_restore_run_id USING ERRCODE='P0002'; END IF;
  IF v_row.status IN ('PROMOTED_TO_PRODUCTION','REJECTED') THEN
    RAISE EXCEPTION 'reject_restore: % already in terminal status %', p_restore_run_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE backups.restore_runs
     SET status = 'REJECTED', rejected_at = clock_timestamp(), rejection_reason = p_reason
   WHERE id = p_restore_run_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'RESTORE_REJECTED',
    p_subject_type => 'RESTORE_RUN'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'backups.reject_restore',
    p_reason       => format('restore %s rejected: %s', v_row.id, p_reason),
    p_after_state  => jsonb_build_object('restore_run_id', v_row.id, 'rejection_reason', p_reason)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.reject_restore(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.reject_restore(uuid, text) TO service_role;

-- ---- RPC: record_restore_test_outcome ---------------------------------------
CREATE OR REPLACE FUNCTION backups.record_restore_test_outcome(
  p_test_type        backups.restore_type_enum,
  p_backup_record_id uuid,
  p_passed           boolean,
  p_details          jsonb DEFAULT '{}'::jsonb
) RETURNS audit.audit_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = backups, audit, public, pg_temp
AS $fn$
DECLARE
  v_audit audit.audit_events;
  v_action text;
BEGIN
  IF p_test_type IS NULL THEN RAISE EXCEPTION 'record_restore_test_outcome: test_type required' USING ERRCODE='22000'; END IF;
  IF p_passed IS NULL THEN RAISE EXCEPTION 'record_restore_test_outcome: passed required' USING ERRCODE='22000'; END IF;
  IF p_test_type NOT IN ('WEEKLY_TEST','MONTHLY_DR_DRILL') THEN
    RAISE EXCEPTION 'record_restore_test_outcome: test_type must be WEEKLY_TEST or MONTHLY_DR_DRILL (got %)', p_test_type USING ERRCODE='22000';
  END IF;

  v_action := CASE WHEN p_passed THEN 'RESTORE_TEST_PASSED' ELSE 'RESTORE_TEST_FAILED' END;
  v_audit := audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => v_action,
    p_subject_type => 'BACKUP'::audit.subject_type_enum,
    p_subject_id   => p_backup_record_id,
    p_actor_system => 'backups.record_restore_test_outcome',
    p_reason       => format('%s %s', p_test_type, CASE WHEN p_passed THEN 'PASSED' ELSE 'FAILED' END),
    p_after_state  => jsonb_build_object(
      'test_type', p_test_type, 'backup_record_id', p_backup_record_id, 'passed', p_passed, 'details', p_details
    )
  );

  -- Monthly drill always emits DR_DRILL_COMPLETED in addition
  IF p_test_type = 'MONTHLY_DR_DRILL' THEN
    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'DR_DRILL_COMPLETED',
      p_subject_type => 'BACKUP'::audit.subject_type_enum,
      p_subject_id   => p_backup_record_id,
      p_actor_system => 'backups.record_restore_test_outcome',
      p_reason       => format('monthly DR drill completed: %s', CASE WHEN p_passed THEN 'PASSED' ELSE 'FAILED' END),
      p_after_state  => jsonb_build_object('backup_record_id', p_backup_record_id, 'passed', p_passed, 'details', p_details)
    );
  END IF;
  RETURN v_audit;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION backups.record_restore_test_outcome(backups.restore_type_enum, uuid, boolean, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION backups.record_restore_test_outcome(backups.restore_type_enum, uuid, boolean, jsonb) TO service_role;

-- ---- bootstrap audit event --------------------------------------------------
DO $bootstrap$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'VAULT_INITIALIZED',
    p_subject_type => 'AUDIT_QUERY'::audit.subject_type_enum,
    p_actor_system => 'b05p08-migration',
    p_reason       => 'backup encryption + DR surface online — backups.{backup_records,restore_runs,replication_status} + 11 RPCs + PRODUCTION_RESTORE sensitive surface (60s)'
  );
END
$bootstrap$;

COMMENT ON SCHEMA backups IS
'B05·P08 backup + disaster recovery. DB-side metadata + orchestration. Actual pg_dump scheduling, Storage replication, and restore execution live at platform / API-worker layer.';

COMMENT ON TABLE backups.backup_records IS
'B05·P08 one row per backup attempt. encryption_key_id references the EXACT vault.secrets.id at encryption time — overlap semantics are implicit (any backup decryptable as long as its Vault row persists).';

COMMENT ON TABLE backups.restore_runs IS
'B05·P08 restore lifecycle: INITIATED → QUARANTINE_LOADED → VERIFICATION_(PASSED|FAILED) → PROMOTED_TO_PRODUCTION | REJECTED. Multi-party authorisation enforced at initiate_restore (initiator + second_authoriser, both OWNER + recent MFA within PRODUCTION_RESTORE step_up_window).';

COMMENT ON FUNCTION backups.initiate_restore(uuid, uuid, uuid, backups.restore_type_enum, text) IS
'B05·P08 restore initiation chokepoint. Multi-party gate (two distinct OWNERs both with mfa_recent_at <= 60s). Returns jsonb envelope (Mitigation A) — no RAISE on denial; emits RESTORE_REJECTED + returns {success:false, denial_reason}.';

COMMENT ON FUNCTION backups.verify_restored_data(uuid, uuid, boolean, jsonb) IS
'B05·P08 restore-time verification. Re-runs audit.verify_restored_chain (chain re-verify) + accepts archive_hashes_verified flag from external archive-bundle hasher. Combined verdict drives VERIFICATION_PASSED/FAILED state and audit emission.';
