-- B05·P07 Secrets Management
-- ============================================================================
-- Centralises every credential the application uses — Vault as the storage
-- backend, `secrets.managed_secrets` as the metadata + rotation tracker.
-- The application reads via `secrets.get_secret(name)` only; direct env-var
-- access for managed secrets is forbidden (lint rule lives in API/web layer).
--
-- Categories + rotation cadences live in `secrets.secret_policies`. The
-- background rotation job (API/worker cron) calls `secrets.list_due_for_rotation`
-- and rotates each via `secrets.rotate_secret`. The stale-credential detector
-- (API outbound-call failure hook) calls `secrets.flag_stale`.
-- ============================================================================

-- ---- subject_type extension --------------------------------------------------
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'SECRET';

-- ---- schema + status enum ----------------------------------------------------
CREATE SCHEMA IF NOT EXISTS secrets;

CREATE TYPE secrets.secret_status_enum AS ENUM ('ACTIVE','STALE_SUSPECT','RETIRED','DESTROYED');

-- ---- secrets.secret_policies -------------------------------------------------
-- Per-category rotation cadence. Loaded with the 9 categories from the
-- B05·P07 spec. BACKUP_ENCRYPTION gets overlap_window=30 days for
-- decrypting historical backups during transition.

CREATE TABLE secrets.secret_policies (
  category           text PRIMARY KEY,
  rotation_interval  interval NOT NULL,
  overlap_window     interval,
  description        text NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT secret_policies_interval_positive_chk CHECK (rotation_interval > '0'::interval),
  CONSTRAINT secret_policies_overlap_positive_chk  CHECK (overlap_window IS NULL OR overlap_window > '0'::interval)
);

INSERT INTO secrets.secret_policies (category, rotation_interval, overlap_window, description) VALUES
  ('DATABASE_CONNECTION', '90 days',  NULL,      'Postgres connection strings + service-role keys'),
  ('VAULT_ACCESS',        '365 days', NULL,      'Vault root-access credentials (managed by this manager)'),
  ('STORAGE_SIGNING',     '365 days', NULL,      'Supabase Storage signed-URL keys'),
  ('OCR_VENDOR',          '365 days', NULL,      'Google Document AI service-account credentials'),
  ('LLM_PROVIDER',        '365 days', NULL,      'Anthropic API key (Tier 3 LLM)'),
  ('OAUTH_CLIENT',        '365 days', NULL,      'Google OAuth client secrets (Gmail + Drive)'),
  ('SMTP',                '365 days', NULL,      'Email delivery SMTP credentials'),
  ('TSA',                 '365 days', NULL,      'RFC 3161 timestamping authority credentials (B05·P03)'),
  ('BACKUP_ENCRYPTION',   '365 days', '30 days', 'Backup encryption keys; overlap window allows decrypting prior-key backups');

GRANT SELECT ON secrets.secret_policies TO authenticated, service_role;

-- ---- secrets.managed_secrets -------------------------------------------------

CREATE TABLE secrets.managed_secrets (
  secret_id                 uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  secret_name               text NOT NULL UNIQUE,
  vault_secret_id           uuid NOT NULL,
  previous_vault_secret_id  uuid,  -- only set for BACKUP_ENCRYPTION during overlap window
  category                  text NOT NULL REFERENCES secrets.secret_policies(category) ON UPDATE CASCADE,
  owner                     text NOT NULL,
  description               text,
  status                    secrets.secret_status_enum NOT NULL DEFAULT 'ACTIVE',
  generation                integer NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  rotated_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at                timestamptz NOT NULL,
  stale_detected_at         timestamptz,
  last_stale_reason         text,
  destroyed_at              timestamptz,
  CONSTRAINT managed_secrets_generation_positive_chk CHECK (generation >= 1),
  CONSTRAINT managed_secrets_name_nonempty_chk CHECK (length(btrim(secret_name)) > 0),
  CONSTRAINT managed_secrets_destroyed_consistency_chk CHECK (
    (status = 'DESTROYED' AND destroyed_at IS NOT NULL) OR
    (status <> 'DESTROYED' AND destroyed_at IS NULL)
  )
);

CREATE INDEX idx_managed_secrets_category_status ON secrets.managed_secrets (category, status);
CREATE INDEX idx_managed_secrets_expires_at      ON secrets.managed_secrets (expires_at) WHERE status = 'ACTIVE';
CREATE INDEX idx_managed_secrets_status          ON secrets.managed_secrets (status);

-- service_role-only access (no authenticated SELECT — metadata also sensitive)
ALTER TABLE secrets.managed_secrets ENABLE ROW LEVEL SECURITY;
ALTER TABLE secrets.managed_secrets FORCE  ROW LEVEL SECURITY;

CREATE POLICY managed_secrets_no_select_authenticated ON secrets.managed_secrets
  AS RESTRICTIVE FOR SELECT TO authenticated USING (false);
CREATE POLICY managed_secrets_no_insert ON secrets.managed_secrets
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY managed_secrets_no_update ON secrets.managed_secrets
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY managed_secrets_no_delete ON secrets.managed_secrets
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON secrets.managed_secrets TO service_role;
GRANT USAGE  ON SCHEMA secrets TO authenticated, service_role;

-- ---- internal helper: _derive_expires_at -------------------------------------
CREATE OR REPLACE FUNCTION secrets._derive_expires_at(
  p_category   text,
  p_rotated_at timestamptz
) RETURNS timestamptz
LANGUAGE plpgsql STABLE
SET search_path = secrets, pg_temp
AS $fn$
DECLARE
  v_interval interval;
BEGIN
  SELECT rotation_interval INTO v_interval FROM secrets.secret_policies WHERE category = p_category;
  IF v_interval IS NULL THEN
    RAISE EXCEPTION '_derive_expires_at: unknown category %', p_category USING ERRCODE = '22023';
  END IF;
  RETURN p_rotated_at + v_interval;
END;
$fn$;

-- ---- RPC: secrets.register_secret -------------------------------------------
CREATE OR REPLACE FUNCTION secrets.register_secret(
  p_name          text,
  p_category      text,
  p_initial_value text,
  p_owner         text,
  p_description   text DEFAULT NULL
) RETURNS secrets.managed_secrets
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = secrets, vault, audit, public, pg_temp
AS $fn$
DECLARE
  v_secret_id  uuid;
  v_now        timestamptz := clock_timestamp();
  v_expires_at timestamptz;
  v_row        secrets.managed_secrets;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'register_secret: name is required' USING ERRCODE = '22000';
  END IF;
  IF p_category IS NULL OR length(btrim(p_category)) = 0 THEN
    RAISE EXCEPTION 'register_secret: category is required' USING ERRCODE = '22000';
  END IF;
  IF p_initial_value IS NULL OR length(p_initial_value) = 0 THEN
    RAISE EXCEPTION 'register_secret: initial_value is required' USING ERRCODE = '22000';
  END IF;
  IF p_owner IS NULL OR length(btrim(p_owner)) = 0 THEN
    RAISE EXCEPTION 'register_secret: owner is required' USING ERRCODE = '22000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM secrets.secret_policies WHERE category = p_category) THEN
    RAISE EXCEPTION 'register_secret: unknown category %', p_category USING ERRCODE = '23514';
  END IF;

  v_secret_id  := vault.create_secret(
    new_secret      => p_initial_value,
    new_name        => 'app-secret-' || p_name,
    new_description => COALESCE(p_description, format('B05P07 managed secret %s (%s)', p_name, p_category))
  );
  v_expires_at := secrets._derive_expires_at(p_category, v_now);

  INSERT INTO secrets.managed_secrets (
    secret_name, vault_secret_id, category, owner, description,
    status, generation, created_at, rotated_at, expires_at
  ) VALUES (
    p_name, v_secret_id, p_category, p_owner, p_description,
    'ACTIVE', 1, v_now, v_now, v_expires_at
  )
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'SECRET_CREATED',
    p_subject_type => 'SECRET'::audit.subject_type_enum,
    p_subject_id   => v_row.secret_id,
    p_actor_system => 'secrets.register_secret',
    p_reason       => format('secret %s registered under category %s', p_name, p_category),
    p_after_state  => jsonb_build_object(
      'secret_id',       v_row.secret_id,
      'secret_name',     p_name,
      'category',        p_category,
      'owner',           p_owner,
      'vault_secret_id', v_secret_id,
      'generation',      1,
      'expires_at',      v_expires_at
    )
  );

  RETURN v_row;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION secrets.register_secret(text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION secrets.register_secret(text, text, text, text, text) TO service_role;

-- ---- RPC: secrets.get_secret ------------------------------------------------
-- Returns the secret value. Mitigation A — never raises on runtime denials.
-- Wraps the vault.decrypted_secrets read in an EXCEPTION trap so a Vault
-- failure emits SECRET_ACCESS_FAILED + returns NULL rather than crashing.
-- p_actor_user_id optional; when provided, recorded on the audit row.

CREATE OR REPLACE FUNCTION secrets.get_secret(
  p_name           text,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = secrets, vault, audit, public, pg_temp
AS $fn$
DECLARE
  v_row    secrets.managed_secrets;
  v_value  text;
  v_err    text;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'get_secret: name is required' USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_row FROM secrets.managed_secrets WHERE secret_name = p_name;
  IF NOT FOUND THEN
    PERFORM audit.emit_audit(
      p_actor_kind    => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action        => 'SECRET_ACCESS_DENIED',
      p_subject_type  => 'SECRET'::audit.subject_type_enum,
      p_actor_user_id => p_actor_user_id,
      p_actor_system  => CASE WHEN p_actor_user_id IS NULL THEN 'secrets.get_secret' ELSE NULL END,
      p_reason        => format('secret %s not found', p_name),
      p_after_state   => jsonb_build_object('secret_name', p_name, 'reason_code', 'SECRET_NOT_FOUND')
    );
    RETURN NULL;
  END IF;

  IF v_row.status = 'DESTROYED' THEN
    PERFORM audit.emit_audit(
      p_actor_kind    => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action        => 'SECRET_ACCESS_DENIED',
      p_subject_type  => 'SECRET'::audit.subject_type_enum,
      p_subject_id    => v_row.secret_id,
      p_actor_user_id => p_actor_user_id,
      p_actor_system  => CASE WHEN p_actor_user_id IS NULL THEN 'secrets.get_secret' ELSE NULL END,
      p_reason        => format('secret %s is DESTROYED', p_name),
      p_after_state   => jsonb_build_object('secret_name', p_name, 'secret_id', v_row.secret_id, 'reason_code', 'SECRET_DESTROYED')
    );
    RETURN NULL;
  END IF;

  BEGIN
    SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE id = v_row.vault_secret_id;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    PERFORM audit.emit_audit(
      p_actor_kind    => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action        => 'SECRET_ACCESS_FAILED',
      p_subject_type  => 'SECRET'::audit.subject_type_enum,
      p_subject_id    => v_row.secret_id,
      p_actor_user_id => p_actor_user_id,
      p_actor_system  => CASE WHEN p_actor_user_id IS NULL THEN 'secrets.get_secret' ELSE NULL END,
      p_reason        => format('vault read failed for %s', p_name),
      p_after_state   => jsonb_build_object('secret_name', p_name, 'secret_id', v_row.secret_id, 'reason_code', 'VAULT_READ_FAILED', 'error_message', v_err)
    );
    RETURN NULL;
  END;

  IF v_value IS NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind    => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
      p_action        => 'SECRET_ACCESS_FAILED',
      p_subject_type  => 'SECRET'::audit.subject_type_enum,
      p_subject_id    => v_row.secret_id,
      p_actor_user_id => p_actor_user_id,
      p_actor_system  => CASE WHEN p_actor_user_id IS NULL THEN 'secrets.get_secret' ELSE NULL END,
      p_reason        => format('vault row missing for %s', p_name),
      p_after_state   => jsonb_build_object('secret_name', p_name, 'secret_id', v_row.secret_id, 'reason_code', 'VAULT_ROW_MISSING')
    );
    RETURN NULL;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind    => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
    p_action        => 'SECRET_ACCESSED',
    p_subject_type  => 'SECRET'::audit.subject_type_enum,
    p_subject_id    => v_row.secret_id,
    p_actor_user_id => p_actor_user_id,
    p_actor_system  => CASE WHEN p_actor_user_id IS NULL THEN 'secrets.get_secret' ELSE NULL END,
    p_reason        => format('secret %s accessed', p_name),
    p_after_state   => jsonb_build_object(
      'secret_name',     p_name,
      'secret_id',       v_row.secret_id,
      'category',        v_row.category,
      'generation',      v_row.generation,
      'vault_secret_id', v_row.vault_secret_id
    )
  );

  RETURN v_value;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION secrets.get_secret(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION secrets.get_secret(text, uuid) TO service_role;

-- ---- RPC: secrets.rotate_secret ---------------------------------------------
-- Emits SECRET_ROTATION_STARTED first (forensic record of the attempt). On
-- success: bumps generation, updates vault, sets previous_vault_secret_id
-- for BACKUP_ENCRYPTION (overlap window). Emits SECRET_ROTATED on success.
-- On failure (e.g., Vault error): raises — caller catches and invokes
-- secrets.record_rotation_failure in a fresh tx (Mitigation B).

CREATE OR REPLACE FUNCTION secrets.rotate_secret(
  p_name      text,
  p_new_value text,
  p_reason    text
) RETURNS secrets.managed_secrets
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = secrets, vault, audit, public, pg_temp
AS $fn$
DECLARE
  v_row              secrets.managed_secrets;
  v_old_vault_id     uuid;
  v_new_vault_id     uuid;
  v_now              timestamptz := clock_timestamp();
  v_new_expires_at   timestamptz;
  v_keep_previous    boolean;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'rotate_secret: name is required' USING ERRCODE = '22000';
  END IF;
  IF p_new_value IS NULL OR length(p_new_value) = 0 THEN
    RAISE EXCEPTION 'rotate_secret: new_value is required' USING ERRCODE = '22000';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'rotate_secret: reason is required' USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_row FROM secrets.managed_secrets WHERE secret_name = p_name FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rotate_secret: secret % not found', p_name USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status = 'DESTROYED' THEN
    RAISE EXCEPTION 'rotate_secret: secret % is DESTROYED', p_name USING ERRCODE = '23514';
  END IF;

  v_old_vault_id := v_row.vault_secret_id;
  v_keep_previous := (v_row.category = 'BACKUP_ENCRYPTION');

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'SECRET_ROTATION_STARTED',
    p_subject_type => 'SECRET'::audit.subject_type_enum,
    p_subject_id   => v_row.secret_id,
    p_actor_system => 'secrets.rotate_secret',
    p_reason       => format('rotation started for %s: %s', p_name, p_reason),
    p_before_state => jsonb_build_object('generation', v_row.generation, 'vault_secret_id', v_old_vault_id),
    p_after_state  => jsonb_build_object(
      'secret_name', p_name,
      'category',    v_row.category,
      'keep_previous_for_overlap', v_keep_previous
    )
  );

  v_new_vault_id := vault.create_secret(
    new_secret      => p_new_value,
    new_name        => format('app-secret-%s-g%s', p_name, (v_row.generation + 1)::text),
    new_description => format('B05P07 rotated secret %s generation %s', p_name, v_row.generation + 1)
  );

  v_new_expires_at := secrets._derive_expires_at(v_row.category, v_now);

  UPDATE secrets.managed_secrets
     SET vault_secret_id          = v_new_vault_id,
         previous_vault_secret_id = CASE WHEN v_keep_previous THEN v_old_vault_id ELSE NULL END,
         generation               = v_row.generation + 1,
         rotated_at               = v_now,
         expires_at               = v_new_expires_at,
         status                   = 'ACTIVE',
         stale_detected_at        = NULL,
         last_stale_reason        = NULL
   WHERE secret_id = v_row.secret_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'SECRET_ROTATED',
    p_subject_type => 'SECRET'::audit.subject_type_enum,
    p_subject_id   => v_row.secret_id,
    p_actor_system => 'secrets.rotate_secret',
    p_reason       => format('secret %s rotated to generation %s', p_name, v_row.generation),
    p_after_state  => jsonb_build_object(
      'secret_name',                p_name,
      'category',                   v_row.category,
      'generation',                 v_row.generation,
      'vault_secret_id',            v_new_vault_id,
      'previous_vault_secret_id',   v_row.previous_vault_secret_id,
      'rotated_at',                 v_now,
      'expires_at',                 v_new_expires_at,
      'overlap_active',             v_keep_previous
    )
  );

  RETURN v_row;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION secrets.rotate_secret(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION secrets.rotate_secret(text, text, text) TO service_role;

-- ---- RPC: secrets.record_rotation_failure -----------------------------------
-- Mitigation B fresh-tx audit. API orchestrator catches a rotate_secret
-- exception and calls this in a NEW transaction so the failure audit
-- persists. Also sets status=STALE_SUSPECT defensively.

CREATE OR REPLACE FUNCTION secrets.record_rotation_failure(
  p_name         text,
  p_error_class  text,
  p_error_detail text
) RETURNS audit.audit_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = secrets, audit, public, pg_temp
AS $fn$
DECLARE
  v_row     secrets.managed_secrets;
  v_audit   audit.audit_events;
BEGIN
  SELECT * INTO v_row FROM secrets.managed_secrets WHERE secret_name = p_name;
  IF FOUND AND v_row.status NOT IN ('DESTROYED','RETIRED') THEN
    UPDATE secrets.managed_secrets
       SET status            = 'STALE_SUSPECT',
           stale_detected_at = clock_timestamp(),
           last_stale_reason = format('rotation failed: %s', p_error_class)
     WHERE secret_id = v_row.secret_id;
  END IF;

  v_audit := audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'SECRET_ROTATION_FAILED',
    p_subject_type => 'SECRET'::audit.subject_type_enum,
    p_subject_id   => CASE WHEN FOUND THEN v_row.secret_id ELSE NULL END,
    p_actor_system => 'secrets.record_rotation_failure',
    p_reason       => format('rotation of %s failed: %s', p_name, p_error_class),
    p_after_state  => jsonb_build_object(
      'secret_name',  p_name,
      'error_class',  p_error_class,
      'error_detail', p_error_detail
    )
  );
  RETURN v_audit;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION secrets.record_rotation_failure(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION secrets.record_rotation_failure(text, text, text) TO service_role;

-- ---- RPC: secrets.flag_stale ------------------------------------------------
CREATE OR REPLACE FUNCTION secrets.flag_stale(
  p_name             text,
  p_detection_reason text
) RETURNS secrets.managed_secrets
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = secrets, audit, public, pg_temp
AS $fn$
DECLARE
  v_row secrets.managed_secrets;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'flag_stale: name is required' USING ERRCODE = '22000';
  END IF;
  IF p_detection_reason IS NULL OR length(btrim(p_detection_reason)) = 0 THEN
    RAISE EXCEPTION 'flag_stale: detection_reason is required' USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_row FROM secrets.managed_secrets WHERE secret_name = p_name FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'flag_stale: secret % not found', p_name USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status = 'DESTROYED' THEN
    RAISE EXCEPTION 'flag_stale: secret % is DESTROYED', p_name USING ERRCODE = '23514';
  END IF;

  UPDATE secrets.managed_secrets
     SET status            = 'STALE_SUSPECT',
         stale_detected_at = clock_timestamp(),
         last_stale_reason = p_detection_reason
   WHERE secret_id = v_row.secret_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'SECRET_STALE_DETECTED',
    p_subject_type => 'SECRET'::audit.subject_type_enum,
    p_subject_id   => v_row.secret_id,
    p_actor_system => 'secrets.flag_stale',
    p_reason       => format('secret %s flagged STALE_SUSPECT: %s', p_name, p_detection_reason),
    p_after_state  => jsonb_build_object(
      'secret_name',       p_name,
      'category',          v_row.category,
      'detection_reason',  p_detection_reason,
      'stale_detected_at', v_row.stale_detected_at
    )
  );

  RETURN v_row;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION secrets.flag_stale(text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION secrets.flag_stale(text, text) TO service_role;

-- ---- RPC: secrets.list_due_for_rotation -------------------------------------
CREATE OR REPLACE FUNCTION secrets.list_due_for_rotation()
RETURNS SETOF secrets.managed_secrets
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = secrets, pg_temp
AS $fn$
  SELECT * FROM secrets.managed_secrets
   WHERE status = 'ACTIVE' AND expires_at <= now()
   ORDER BY expires_at ASC;
$fn$;

REVOKE EXECUTE ON FUNCTION secrets.list_due_for_rotation() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION secrets.list_due_for_rotation() TO service_role;

-- ---- bootstrap audit event --------------------------------------------------
DO $bootstrap$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'VAULT_INITIALIZED',
    p_subject_type => 'AUDIT_QUERY'::audit.subject_type_enum,
    p_actor_system => 'b05p07-migration',
    p_reason       => 'secrets management surface online — secrets.{managed_secrets, secret_policies} + 6 RPCs + 9 policy categories'
  );
END
$bootstrap$;

COMMENT ON SCHEMA secrets IS
'B05·P07 secrets management. Centralised credential storage backed by Supabase Vault; managed_secrets tracks metadata + rotation cadence per category. get_secret is the only read path (audit-logged).';

COMMENT ON TABLE secrets.secret_policies IS
'B05·P07 per-category rotation cadence. BACKUP_ENCRYPTION carries overlap_window for in-flight backup decryption during transition.';

COMMENT ON TABLE secrets.managed_secrets IS
'B05·P07 managed secret tracker. vault_secret_id is the live Vault row; previous_vault_secret_id is the prior generation (BACKUP_ENCRYPTION only, during overlap_window).';

COMMENT ON FUNCTION secrets.get_secret(text, uuid) IS
'B05·P07 read path for managed secrets. Returns the value on success + emits SECRET_ACCESSED with secret_name + generation + vault_secret_id (NEVER the value). Mitigation A — returns NULL on runtime denials.';

COMMENT ON FUNCTION secrets.rotate_secret(text, text, text) IS
'B05·P07 rotation primitive. Emits SECRET_ROTATION_STARTED then SECRET_ROTATED. BACKUP_ENCRYPTION category preserves previous_vault_secret_id for the overlap_window. On failure RAISES — orchestrator calls record_rotation_failure in fresh tx (Mitigation B).';
