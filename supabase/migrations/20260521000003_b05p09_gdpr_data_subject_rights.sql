-- B05·P09 GDPR Data Subject Rights
-- ============================================================================
-- Right-of-access, right-of-rectification, and right-of-erasure flows. Stage 1
-- locked the erasure semantics: record intent immediately, pseudonymize
-- personal identifiers right away, anonymize fully after retention window
-- expires, never erase the erasure event itself.
--
-- The DB layer ships:
--   * data_subject_requests lifecycle table
--   * pseudonym_registry with originals encrypted under a PSEUDONYM_REGISTRY
--     key from the secrets manager (NOT per-business DEK chain — registry is
--     org-agnostic)
--   * 10 lifecycle RPCs incl. the named entry point gdpr.run_scheduled_anonymization
--     that B04·P10 retention engine will invoke
--   * legal-hold deferral check inside pseudonymize_subject
--
-- HTTP endpoints, identity verification, export bundle generation, retention
-- cron wiring all live in the API/worker layer.
-- ============================================================================

-- ---- subject_type extension --------------------------------------------------
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'DATA_SUBJECT_REQUEST';

-- ---- gdpr schema + enums -----------------------------------------------------
CREATE SCHEMA IF NOT EXISTS gdpr;

CREATE TYPE gdpr.request_type_enum   AS ENUM ('ACCESS','RECTIFICATION','ERASURE');
CREATE TYPE gdpr.request_status_enum AS ENUM (
  'RECEIVED','IN_PROGRESS','FULFILLED','REJECTED','DEFERRED_RETENTION','DEFERRED_LEGAL_HOLD'
);

-- ---- New PSEUDONYM_REGISTRY secrets category --------------------------------
INSERT INTO secrets.secret_policies (category, rotation_interval, overlap_window, description)
VALUES ('PSEUDONYM_REGISTRY', '365 days', NULL,
        'GDPR pseudonym registry encryption key (B05·P09); org-agnostic, lives outside per-business DEK chain')
ON CONFLICT (category) DO NOTHING;

-- ---- New GDPR_REQUEST_FULFILL sensitive surface -----------------------------
INSERT INTO auth_runtime.sensitive_surfaces (surface, step_up_window, description)
VALUES ('GDPR_REQUEST_FULFILL', '5 minutes',
        'Fulfil a GDPR data subject request (B05·P09): generate export, pseudonymize, schedule anonymization, run anonymization')
ON CONFLICT (surface) DO NOTHING;

-- ---- gdpr.data_subject_requests ----------------------------------------------
CREATE TABLE gdpr.data_subject_requests (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  request_type                gdpr.request_type_enum NOT NULL,
  subject_user_id             uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  subject_business_id         uuid REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  requester_user_id           uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  status                      gdpr.request_status_enum NOT NULL DEFAULT 'RECEIVED',
  rejection_reason            text,
  deferral_reason             text,
  scheduled_anonymization_at  timestamptz,
  export_location             text,
  export_bundle_hash          text,
  submitted_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  identity_verified_at        timestamptz,
  fulfilled_at                timestamptz,
  -- XOR: exactly one of subject_user_id / subject_business_id is set
  CONSTRAINT dsr_subject_xor_chk CHECK (
    (subject_user_id IS NOT NULL AND subject_business_id IS NULL)
    OR
    (subject_user_id IS NULL AND subject_business_id IS NOT NULL)
  ),
  CONSTRAINT dsr_state_consistency_chk CHECK (
    (status = 'FULFILLED' AND fulfilled_at IS NOT NULL)
    OR (status = 'REJECTED' AND rejection_reason IS NOT NULL)
    OR (status IN ('DEFERRED_RETENTION','DEFERRED_LEGAL_HOLD') AND deferral_reason IS NOT NULL)
    OR (status IN ('RECEIVED','IN_PROGRESS'))
  ),
  CONSTRAINT dsr_export_format_chk CHECK (
    export_bundle_hash IS NULL OR export_bundle_hash ~ '^[0-9a-f]{64}$'
  )
);

CREATE INDEX idx_dsr_subject_user        ON gdpr.data_subject_requests (subject_user_id)     WHERE subject_user_id IS NOT NULL;
CREATE INDEX idx_dsr_subject_business    ON gdpr.data_subject_requests (subject_business_id) WHERE subject_business_id IS NOT NULL;
CREATE INDEX idx_dsr_requester           ON gdpr.data_subject_requests (requester_user_id);
CREATE INDEX idx_dsr_status              ON gdpr.data_subject_requests (status);
CREATE INDEX idx_dsr_scheduled_anon      ON gdpr.data_subject_requests (scheduled_anonymization_at)
  WHERE status IN ('RECEIVED','IN_PROGRESS') AND scheduled_anonymization_at IS NOT NULL;

-- ---- gdpr.pseudonym_registry -------------------------------------------------
CREATE TABLE gdpr.pseudonym_registry (
  id                      uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  request_id              uuid NOT NULL REFERENCES gdpr.data_subject_requests(id) ON DELETE RESTRICT,
  identifier_kind         text NOT NULL,  -- 'email', 'display_name', etc.
  original_ciphertext     bytea NOT NULL,
  pseudonym               text  NOT NULL,
  created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pseudonym_registry_kind_nonempty CHECK (length(btrim(identifier_kind)) > 0),
  CONSTRAINT pseudonym_registry_pseudonym_nonempty CHECK (length(btrim(pseudonym)) > 0),
  CONSTRAINT pseudonym_registry_unique_per_request_kind UNIQUE (request_id, identifier_kind)
);

CREATE INDEX idx_pseudonym_registry_request ON gdpr.pseudonym_registry (request_id);

-- ---- RLS ---------------------------------------------------------------------
ALTER TABLE gdpr.data_subject_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE gdpr.data_subject_requests FORCE  ROW LEVEL SECURITY;
ALTER TABLE gdpr.pseudonym_registry    ENABLE ROW LEVEL SECURITY;
ALTER TABLE gdpr.pseudonym_registry    FORCE  ROW LEVEL SECURITY;

-- Data subject can read their own requests
CREATE POLICY dsr_select_subject_or_requester ON gdpr.data_subject_requests
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    (subject_user_id IS NOT NULL AND subject_user_id = public.current_user_id())
    OR requester_user_id = public.current_user_id()
  );

CREATE POLICY dsr_no_insert ON gdpr.data_subject_requests AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY dsr_no_update ON gdpr.data_subject_requests AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY dsr_no_delete ON gdpr.data_subject_requests AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- Pseudonym registry NEVER readable by authenticated — service_role + DEFINER only
CREATE POLICY pseudonym_registry_no_authenticated ON gdpr.pseudonym_registry
  AS RESTRICTIVE FOR ALL TO authenticated USING (false) WITH CHECK (false);

GRANT USAGE  ON SCHEMA gdpr TO authenticated, service_role;
GRANT SELECT ON gdpr.data_subject_requests TO authenticated, service_role;
GRANT SELECT ON gdpr.pseudonym_registry    TO service_role;

-- ---- Bootstrap the PSEUDONYM_REGISTRY key in the secrets manager -----------
-- DO block so the registration is conditional + tolerant of replays.
DO $bootstrap_key$
DECLARE
  v_exists boolean;
  v_random_seed text;
BEGIN
  SELECT EXISTS (SELECT 1 FROM secrets.managed_secrets WHERE secret_name = 'pseudonym_registry_key') INTO v_exists;
  IF NOT v_exists THEN
    -- 32 random bytes → base64 → use as the registry encryption passphrase
    v_random_seed := encode(extensions.gen_random_bytes(32), 'base64');
    PERFORM secrets.register_secret(
      p_name          => 'pseudonym_registry_key',
      p_category      => 'PSEUDONYM_REGISTRY',
      p_initial_value => v_random_seed,
      p_owner         => 'b05p09-migration',
      p_description   => 'B05·P09 GDPR pseudonym registry encryption key (org-agnostic)'
    );
  END IF;
END
$bootstrap_key$;

-- ---- internal helper: gdpr._registry_key_value ------------------------------
CREATE OR REPLACE FUNCTION gdpr._registry_key_value()
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = gdpr, secrets, public, pg_temp
AS $fn$
DECLARE
  v_key text;
BEGIN
  v_key := secrets.get_secret('pseudonym_registry_key');
  IF v_key IS NULL THEN
    RAISE EXCEPTION '_registry_key_value: pseudonym_registry_key not available' USING ERRCODE='P0002';
  END IF;
  RETURN v_key;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION gdpr._registry_key_value() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr._registry_key_value() TO service_role;

-- ---- RPC: submit_request -----------------------------------------------------
CREATE OR REPLACE FUNCTION gdpr.submit_request(
  p_request_type        gdpr.request_type_enum,
  p_subject_user_id     uuid,
  p_subject_business_id uuid,
  p_requester_user_id   uuid
) RETURNS gdpr.data_subject_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row gdpr.data_subject_requests;
  v_org_id uuid;
BEGIN
  IF p_request_type IS NULL THEN RAISE EXCEPTION 'submit_request: request_type required' USING ERRCODE='22000'; END IF;
  IF p_requester_user_id IS NULL THEN RAISE EXCEPTION 'submit_request: requester_user_id required' USING ERRCODE='22000'; END IF;
  IF (p_subject_user_id IS NULL) = (p_subject_business_id IS NULL) THEN
    RAISE EXCEPTION 'submit_request: exactly one of subject_user_id / subject_business_id must be set' USING ERRCODE='22000';
  END IF;

  INSERT INTO gdpr.data_subject_requests (
    request_type, subject_user_id, subject_business_id, requester_user_id, status, submitted_at
  ) VALUES (
    p_request_type, p_subject_user_id, p_subject_business_id, p_requester_user_id, 'RECEIVED', clock_timestamp()
  )
  RETURNING * INTO v_row;

  IF p_subject_business_id IS NOT NULL THEN
    SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_subject_business_id;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'DATA_SUBJECT_REQUEST_RECEIVED',
    p_subject_type    => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id      => v_row.id,
    p_actor_user_id   => p_requester_user_id,
    p_organization_id => v_org_id,
    p_business_id     => p_subject_business_id,
    p_reason          => format('GDPR %s request received', p_request_type),
    p_after_state     => jsonb_build_object(
      'request_id', v_row.id, 'request_type', p_request_type,
      'subject_user_id', p_subject_user_id, 'subject_business_id', p_subject_business_id,
      'requester_user_id', p_requester_user_id
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.submit_request(gdpr.request_type_enum, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.submit_request(gdpr.request_type_enum, uuid, uuid, uuid) TO service_role;

-- ---- RPC: record_identity_verified -------------------------------------------
CREATE OR REPLACE FUNCTION gdpr.record_identity_verified(p_request_id uuid)
RETURNS gdpr.data_subject_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row gdpr.data_subject_requests;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'record_identity_verified: id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_identity_verified: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'RECEIVED' THEN
    RAISE EXCEPTION 'record_identity_verified: % not in RECEIVED (got %)', p_request_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE gdpr.data_subject_requests
     SET status = 'IN_PROGRESS', identity_verified_at = clock_timestamp()
   WHERE id = p_request_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_REQUEST_IDENTITY_VERIFIED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.record_identity_verified',
    p_reason       => format('identity verified for request %s', p_request_id),
    p_after_state  => jsonb_build_object('request_id', v_row.id, 'identity_verified_at', v_row.identity_verified_at)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.record_identity_verified(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.record_identity_verified(uuid) TO service_role;

-- ---- RPC: record_export_generated --------------------------------------------
-- ACCESS-flow only — IN_PROGRESS → FULFILLED, emits DATA_SUBJECT_EXPORT_GENERATED
-- and DATA_SUBJECT_REQUEST_FULFILLED.
CREATE OR REPLACE FUNCTION gdpr.record_export_generated(
  p_request_id        uuid,
  p_export_location   text,
  p_export_bundle_hash text
) RETURNS gdpr.data_subject_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row gdpr.data_subject_requests;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'record_export_generated: id required' USING ERRCODE='22000'; END IF;
  IF p_export_location IS NULL OR length(btrim(p_export_location)) = 0 THEN
    RAISE EXCEPTION 'record_export_generated: export_location required' USING ERRCODE='22000';
  END IF;
  IF p_export_bundle_hash IS NULL OR p_export_bundle_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'record_export_generated: bundle_hash must be 64-hex' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_export_generated: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.request_type <> 'ACCESS' THEN
    RAISE EXCEPTION 'record_export_generated: only ACCESS requests (got %)', v_row.request_type USING ERRCODE='23514';
  END IF;
  IF v_row.status <> 'IN_PROGRESS' THEN
    RAISE EXCEPTION 'record_export_generated: % not in IN_PROGRESS (got %)', p_request_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE gdpr.data_subject_requests
     SET status             = 'FULFILLED',
         export_location    = p_export_location,
         export_bundle_hash = p_export_bundle_hash,
         fulfilled_at       = clock_timestamp()
   WHERE id = p_request_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_EXPORT_GENERATED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.record_export_generated',
    p_reason       => format('export generated for request %s', p_request_id),
    p_after_state  => jsonb_build_object(
      'request_id', v_row.id,
      'export_location', p_export_location,
      'export_bundle_hash', p_export_bundle_hash
    )
  );
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_REQUEST_FULFILLED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.record_export_generated',
    p_reason       => format('ACCESS request %s fulfilled', p_request_id),
    p_after_state  => jsonb_build_object('request_id', v_row.id, 'fulfilled_at', v_row.fulfilled_at)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.record_export_generated(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.record_export_generated(uuid, text, text) TO service_role;

-- ---- RPC: record_export_downloaded -------------------------------------------
CREATE OR REPLACE FUNCTION gdpr.record_export_downloaded(
  p_request_id          uuid,
  p_downloaded_by_user_id uuid
) RETURNS audit.audit_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row   gdpr.data_subject_requests;
  v_audit audit.audit_events;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'record_export_downloaded: id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_export_downloaded: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'FULFILLED' OR v_row.request_type <> 'ACCESS' THEN
    RAISE EXCEPTION 'record_export_downloaded: % not a fulfilled ACCESS request', p_request_id USING ERRCODE='23514';
  END IF;

  v_audit := audit.emit_audit(
    p_actor_kind    => 'USER'::audit.actor_kind_enum,
    p_action        => 'DATA_SUBJECT_EXPORT_DOWNLOADED',
    p_subject_type  => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id    => v_row.id,
    p_actor_user_id => p_downloaded_by_user_id,
    p_reason        => format('export download for request %s', p_request_id),
    p_after_state   => jsonb_build_object(
      'request_id', v_row.id,
      'downloaded_by', p_downloaded_by_user_id,
      'export_bundle_hash', v_row.export_bundle_hash
    )
  );
  RETURN v_audit;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.record_export_downloaded(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.record_export_downloaded(uuid, uuid) TO service_role;

-- ---- RPC: defer_for_legal_hold ----------------------------------------------
CREATE OR REPLACE FUNCTION gdpr.defer_for_legal_hold(
  p_request_id uuid,
  p_reason     text
) RETURNS gdpr.data_subject_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row gdpr.data_subject_requests;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'defer_for_legal_hold: id required' USING ERRCODE='22000'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'defer_for_legal_hold: reason required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'defer_for_legal_hold: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.status IN ('FULFILLED','REJECTED') THEN
    RAISE EXCEPTION 'defer_for_legal_hold: % already terminal %', p_request_id, v_row.status USING ERRCODE='23514';
  END IF;

  UPDATE gdpr.data_subject_requests
     SET status = 'DEFERRED_LEGAL_HOLD', deferral_reason = p_reason
   WHERE id = p_request_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_REQUEST_DEFERRED_LEGAL_HOLD',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.defer_for_legal_hold',
    p_reason       => format('request %s deferred (legal hold): %s', p_request_id, p_reason),
    p_after_state  => jsonb_build_object('request_id', v_row.id, 'deferral_reason', p_reason)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.defer_for_legal_hold(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.defer_for_legal_hold(uuid, text) TO service_role;

-- ---- RPC: pseudonymize_subject ----------------------------------------------
-- ERASURE flow Step 1. Returns jsonb envelope (Mitigation A). Legal-hold check:
-- if any business the subject is associated with has an ACTIVE legal hold (via
-- archive.legal_hold_status), defer to DEFERRED_LEGAL_HOLD and return denial.
-- MVP pseudonymizes public.users.{email, display_name}; future phases extend
-- the per-table walker.

CREATE OR REPLACE FUNCTION gdpr.pseudonymize_subject(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, secrets, archive, audit, extensions, public, pg_temp
AS $fn$
DECLARE
  v_row             gdpr.data_subject_requests;
  v_user            public.users;
  v_registry_key    text;
  v_pseudo_email    text;
  v_pseudo_name     text;
  v_orig_email_ct   bytea;
  v_orig_name_ct    bytea;
  v_fields          int := 0;
  v_biz             record;
  v_hold_status     jsonb;
  v_org_id          uuid;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'pseudonymize_subject: id required' USING ERRCODE='22000'; END IF;

  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pseudonymize_subject: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.request_type <> 'ERASURE' THEN
    RAISE EXCEPTION 'pseudonymize_subject: only ERASURE requests (got %)', v_row.request_type USING ERRCODE='23514';
  END IF;
  IF v_row.status NOT IN ('RECEIVED','IN_PROGRESS') THEN
    RAISE EXCEPTION 'pseudonymize_subject: % must be RECEIVED or IN_PROGRESS (got %)', p_request_id, v_row.status USING ERRCODE='23514';
  END IF;
  IF v_row.subject_user_id IS NULL THEN
    -- MVP only handles user-subject erasure; business-subject TBD
    RAISE EXCEPTION 'pseudonymize_subject: business-subject erasure not yet implemented (MVP supports subject_user_id only)' USING ERRCODE='0A000';
  END IF;

  -- Legal-hold check: any business the subject has a role on?
  FOR v_biz IN
    SELECT DISTINCT bur.business_id, bur.organization_id
      FROM public.business_user_roles bur
     WHERE bur.user_id = v_row.subject_user_id
       AND bur.status = 'ACTIVE'
  LOOP
    v_hold_status := archive.legal_hold_status(v_biz.business_id);
    IF (v_hold_status->>'on_hold')::boolean THEN
      PERFORM gdpr.defer_for_legal_hold(
        p_request_id,
        format('business %s under legal hold (hold_reasons: %s)', v_biz.business_id, v_hold_status->'hold_reasons')
      );
      RETURN jsonb_build_object(
        'success', false,
        'denial_reason', 'LEGAL_HOLD',
        'request_id', p_request_id,
        'business_id', v_biz.business_id,
        'message', format('erasure deferred — business %s under legal hold', v_biz.business_id)
      );
    END IF;
  END LOOP;

  -- Fetch subject + registry key
  SELECT * INTO v_user FROM public.users WHERE id = v_row.subject_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pseudonymize_subject: subject user % not found', v_row.subject_user_id USING ERRCODE='P0002';
  END IF;
  v_registry_key := gdpr._registry_key_value();

  -- Generate stable pseudonyms (deterministic on request_id + kind)
  v_pseudo_email := 'pseudo_' || substr(public.hash_text_sha256(p_request_id::text || ':email'), 1, 16) || '@erased.invalid';
  v_pseudo_name  := 'Pseudonymous Subject ' || substr(public.hash_text_sha256(p_request_id::text || ':name'), 1, 8);

  -- Encrypt originals + register
  IF v_user.email IS NOT NULL AND v_user.email <> v_pseudo_email THEN
    v_orig_email_ct := extensions.pgp_sym_encrypt_bytea(convert_to(v_user.email, 'UTF8'), v_registry_key);
    INSERT INTO gdpr.pseudonym_registry (request_id, identifier_kind, original_ciphertext, pseudonym)
    VALUES (p_request_id, 'email', v_orig_email_ct, v_pseudo_email)
    ON CONFLICT (request_id, identifier_kind) DO NOTHING;
    UPDATE public.users SET email = v_pseudo_email WHERE id = v_user.id;
    v_fields := v_fields + 1;
  END IF;
  IF v_user.display_name IS NOT NULL AND v_user.display_name <> v_pseudo_name THEN
    v_orig_name_ct := extensions.pgp_sym_encrypt_bytea(convert_to(v_user.display_name, 'UTF8'), v_registry_key);
    INSERT INTO gdpr.pseudonym_registry (request_id, identifier_kind, original_ciphertext, pseudonym)
    VALUES (p_request_id, 'display_name', v_orig_name_ct, v_pseudo_name)
    ON CONFLICT (request_id, identifier_kind) DO NOTHING;
    UPDATE public.users SET display_name = v_pseudo_name WHERE id = v_user.id;
    v_fields := v_fields + 1;
  END IF;

  -- Move request to IN_PROGRESS if still RECEIVED
  IF v_row.status = 'RECEIVED' THEN
    UPDATE gdpr.data_subject_requests SET status = 'IN_PROGRESS' WHERE id = p_request_id;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_PSEUDONYMIZED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.pseudonymize_subject',
    p_reason       => format('subject pseudonymized for request %s (%s fields)', p_request_id, v_fields),
    p_after_state  => jsonb_build_object(
      'request_id', v_row.id,
      'subject_user_id', v_row.subject_user_id,
      'fields_pseudonymized', v_fields
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_row.id,
    'fields_pseudonymized', v_fields
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.pseudonymize_subject(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.pseudonymize_subject(uuid) TO service_role;

-- ---- RPC: schedule_anonymization --------------------------------------------
CREATE OR REPLACE FUNCTION gdpr.schedule_anonymization(p_request_id uuid)
RETURNS gdpr.data_subject_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row          gdpr.data_subject_requests;
  v_scheduled_at timestamptz;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'schedule_anonymization: id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'schedule_anonymization: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.request_type <> 'ERASURE' THEN
    RAISE EXCEPTION 'schedule_anonymization: only ERASURE (got %)', v_row.request_type USING ERRCODE='23514';
  END IF;
  IF v_row.status NOT IN ('IN_PROGRESS','DEFERRED_LEGAL_HOLD','DEFERRED_RETENTION') THEN
    RAISE EXCEPTION 'schedule_anonymization: % must be IN_PROGRESS/DEFERRED_* (got %)', p_request_id, v_row.status USING ERRCODE='23514';
  END IF;

  -- MVP: Cyprus accounting retention is 6 years; future phases derive from
  -- max(period_end of affected finalized periods) + retention from each
  -- business's archive.retention_policies row.
  v_scheduled_at := clock_timestamp() + interval '6 years';

  UPDATE gdpr.data_subject_requests
     SET scheduled_anonymization_at = v_scheduled_at
   WHERE id = p_request_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_ANONYMIZATION_SCHEDULED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.schedule_anonymization',
    p_reason       => format('anonymization scheduled for request %s at %s', p_request_id, v_scheduled_at),
    p_after_state  => jsonb_build_object('request_id', v_row.id, 'scheduled_anonymization_at', v_scheduled_at)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.schedule_anonymization(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.schedule_anonymization(uuid) TO service_role;

-- ---- RPC: reject_request -----------------------------------------------------
CREATE OR REPLACE FUNCTION gdpr.reject_request(
  p_request_id uuid,
  p_reason     text
) RETURNS gdpr.data_subject_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row gdpr.data_subject_requests;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'reject_request: id required' USING ERRCODE='22000'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reject_request: reason required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'reject_request: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.status = 'FULFILLED' THEN
    RAISE EXCEPTION 'reject_request: % already FULFILLED', p_request_id USING ERRCODE='23514';
  END IF;

  UPDATE gdpr.data_subject_requests
     SET status = 'REJECTED', rejection_reason = p_reason
   WHERE id = p_request_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_REQUEST_REJECTED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.reject_request',
    p_reason       => format('request %s rejected: %s', p_request_id, p_reason),
    p_after_state  => jsonb_build_object('request_id', v_row.id, 'rejection_reason', p_reason)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.reject_request(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.reject_request(uuid, text) TO service_role;

-- ---- RPC: run_scheduled_anonymization ---------------------------------------
-- The named entry point B04·P10 retention engine will call when
-- scheduled_anonymization_at has elapsed. Replaces remaining pseudonyms with
-- '[anonymized]', emits DATA_SUBJECT_ANONYMIZED + DATA_SUBJECT_REQUEST_FULFILLED.

CREATE OR REPLACE FUNCTION gdpr.run_scheduled_anonymization(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = gdpr, audit, public, pg_temp
AS $fn$
DECLARE
  v_row             gdpr.data_subject_requests;
  v_anonymized_rows int := 0;
  v_anon_marker     text := '[anonymized]';
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'run_scheduled_anonymization: id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'run_scheduled_anonymization: % not found', p_request_id USING ERRCODE='P0002'; END IF;
  IF v_row.request_type <> 'ERASURE' THEN
    RAISE EXCEPTION 'run_scheduled_anonymization: only ERASURE (got %)', v_row.request_type USING ERRCODE='23514';
  END IF;
  IF v_row.status NOT IN ('IN_PROGRESS','DEFERRED_RETENTION','DEFERRED_LEGAL_HOLD') THEN
    RAISE EXCEPTION 'run_scheduled_anonymization: % must be IN_PROGRESS or DEFERRED_* (got %)', p_request_id, v_row.status USING ERRCODE='23514';
  END IF;
  IF v_row.subject_user_id IS NULL THEN
    RAISE EXCEPTION 'run_scheduled_anonymization: business-subject erasure not implemented' USING ERRCODE='0A000';
  END IF;

  -- Replace remaining identifiers with the anon marker
  WITH updated AS (
    UPDATE public.users
       SET email        = v_anon_marker || '+' || substr(public.hash_text_sha256(p_request_id::text), 1, 8) || '@erased.invalid',
           display_name = v_anon_marker
     WHERE id = v_row.subject_user_id
    RETURNING 1
  )
  SELECT count(*) INTO v_anonymized_rows FROM updated;

  -- Mark request FULFILLED
  UPDATE gdpr.data_subject_requests
     SET status = 'FULFILLED', fulfilled_at = clock_timestamp()
   WHERE id = p_request_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_ANONYMIZED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.run_scheduled_anonymization',
    p_reason       => format('subject anonymized for request %s (%s rows updated)', p_request_id, v_anonymized_rows),
    p_after_state  => jsonb_build_object(
      'request_id', v_row.id,
      'subject_user_id', v_row.subject_user_id,
      'anonymized_rows', v_anonymized_rows
    )
  );
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'DATA_SUBJECT_REQUEST_FULFILLED',
    p_subject_type => 'DATA_SUBJECT_REQUEST'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'gdpr.run_scheduled_anonymization',
    p_reason       => format('ERASURE request %s fulfilled', p_request_id),
    p_after_state  => jsonb_build_object('request_id', v_row.id, 'fulfilled_at', v_row.fulfilled_at)
  );

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_row.id,
    'anonymized_rows', v_anonymized_rows,
    'fulfilled_at', v_row.fulfilled_at
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION gdpr.run_scheduled_anonymization(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION gdpr.run_scheduled_anonymization(uuid) TO service_role;

-- ---- RPC: get_request_status -------------------------------------------------
-- Status visibility for the data subject. RLS scopes by subject_user_id or
-- requester_user_id. SECURITY INVOKER so RLS applies to the caller.

CREATE OR REPLACE FUNCTION gdpr.get_request_status(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = gdpr, public, pg_temp
AS $fn$
DECLARE
  v_row gdpr.data_subject_requests;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'get_request_status: id required' USING ERRCODE='22000'; END IF;
  -- RLS will filter; if not visible, returns NULL row
  SELECT * INTO v_row FROM gdpr.data_subject_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false, 'request_id', p_request_id);
  END IF;
  RETURN jsonb_build_object(
    'found',                       true,
    'request_id',                  v_row.id,
    'request_type',                v_row.request_type,
    'status',                      v_row.status,
    'subject_user_id',             v_row.subject_user_id,
    'subject_business_id',         v_row.subject_business_id,
    'requester_user_id',           v_row.requester_user_id,
    'submitted_at',                v_row.submitted_at,
    'identity_verified_at',        v_row.identity_verified_at,
    'fulfilled_at',                v_row.fulfilled_at,
    'scheduled_anonymization_at',  v_row.scheduled_anonymization_at,
    'deferral_reason',             v_row.deferral_reason,
    'rejection_reason',            v_row.rejection_reason
  );
END;
$fn$;
GRANT EXECUTE ON FUNCTION gdpr.get_request_status(uuid) TO authenticated, service_role;

-- ---- bootstrap audit event --------------------------------------------------
DO $bootstrap$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'VAULT_INITIALIZED',
    p_subject_type => 'AUDIT_QUERY'::audit.subject_type_enum,
    p_actor_system => 'b05p09-migration',
    p_reason       => 'GDPR data subject rights surface online — gdpr.{data_subject_requests, pseudonym_registry} + 10 RPCs + PSEUDONYM_REGISTRY category + pseudonym_registry_key + GDPR_REQUEST_FULFILL sensitive surface'
  );
END
$bootstrap$;

COMMENT ON SCHEMA gdpr IS
'B05·P09 GDPR Data Subject Rights — access/rectification/erasure flows. DB primitives + named entry point gdpr.run_scheduled_anonymization for B04·P10 retention engine.';

COMMENT ON TABLE gdpr.data_subject_requests IS
'B05·P09 lifecycle: RECEIVED → IN_PROGRESS → FULFILLED | REJECTED | DEFERRED_*. Subject XOR check enforces exactly one of subject_user_id / subject_business_id.';

COMMENT ON TABLE gdpr.pseudonym_registry IS
'B05·P09 reversible-during-legal-challenge pseudonym mapping. Originals encrypted under PSEUDONYM_REGISTRY secrets-manager key (org-agnostic; outside per-business DEK chain).';

COMMENT ON FUNCTION gdpr.pseudonymize_subject(uuid) IS
'B05·P09 ERASURE step 1. Legal-hold check via archive.legal_hold_status for any business the subject is associated with → defers to DEFERRED_LEGAL_HOLD via Mitigation A jsonb envelope.';

COMMENT ON FUNCTION gdpr.run_scheduled_anonymization(uuid) IS
'B05·P09 ERASURE final step. B04·P10 retention engine invokes when scheduled_anonymization_at has elapsed. Replaces remaining identifiers with [anonymized]; emits DATA_SUBJECT_ANONYMIZED + DATA_SUBJECT_REQUEST_FULFILLED. The erasure event itself is preserved per Stage 1 decision.';
