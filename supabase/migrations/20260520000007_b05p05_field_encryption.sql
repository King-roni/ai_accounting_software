-- B05·P05 pgcrypto Field-Level Encryption
-- ============================================================================
-- Wires pgcrypto-based field-level encryption on top of B05·P04's Vault DEK
-- hierarchy. Adds three SQL functions:
--   * keys.encrypt_field(business_id, plaintext) → bytea  (silent — no audit
--     on routine writes per spec; FIELD_ENCRYPTED reserved for bulk migration)
--   * keys.decrypt_field(business_id, ciphertext, field_name) → text
--     (emits FIELD_DECRYPTED with field_name + ciphertext_fingerprint; NEVER
--     plaintext in the audit payload)
--   * keys.mask_field(plaintext, kind) → text  (IMMUTABLE pure function)
--
-- Convention: every "*_encrypted" column ships with a paired "*_masked" text
-- column. Application reads use *_masked by default; explicit decryption goes
-- through decrypt_field at the API layer (B05·P05 ships the DB primitive; the
-- HTTP "decrypt-at-use" endpoint + B05·P06 permission gating ship in the
-- API layer).
--
-- Cross-tenant isolation: decrypt_field uses pgp_sym_decrypt which RAISES on
-- wrong-key. We catch the exception in-function and RETURN NULL silently —
-- no plaintext leakage, no audit-then-raise rollback hazard. The API layer
-- enforces tenant boundaries upstream (defense in depth at DB layer).
-- ============================================================================

-- ---- subject_type extension --------------------------------------------------
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'ENCRYPTED_FIELD';

-- ---- field_kind_enum ---------------------------------------------------------
CREATE TYPE keys.field_kind_enum AS ENUM (
  'IBAN',
  'ACCOUNT_NUMBER',
  'VAT_NUMBER',
  'OAUTH_TOKEN'
);

-- ---- migrate business_integrations oauth_* from text → bytea ----------------
-- Empty in current DB (verified pre-migration); safe to ALTER COLUMN.
ALTER TABLE public.business_integrations
  ALTER COLUMN oauth_access_token_encrypted  TYPE bytea USING NULL,
  ALTER COLUMN oauth_refresh_token_encrypted TYPE bytea USING NULL;

-- ---- missing *_masked columns ----------------------------------------------
ALTER TABLE public.bank_accounts
  ADD COLUMN IF NOT EXISTS iban_masked            text,
  ADD COLUMN IF NOT EXISTS account_number_masked  text;

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS raw_description_masked text;

ALTER TABLE public.business_integrations
  ADD COLUMN IF NOT EXISTS oauth_access_token_masked  text,
  ADD COLUMN IF NOT EXISTS oauth_refresh_token_masked text;

-- ---- keys.mask_field --------------------------------------------------------
-- Pure IMMUTABLE function. Per-kind rules:
--   IBAN           : '***' || last 4 chars (whitespace stripped first)
--   ACCOUNT_NUMBER : '***' || last 4 chars
--   VAT_NUMBER     : first 2 (country prefix) || '***' || last 2 chars
--   OAUTH_TOKEN    : fixed '***'

CREATE OR REPLACE FUNCTION keys.mask_field(
  p_plaintext text,
  p_kind      keys.field_kind_enum
) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_temp
AS $fn$
DECLARE
  v_clean text;
  v_len   int;
BEGIN
  IF p_plaintext IS NULL THEN RETURN NULL; END IF;

  IF p_kind = 'OAUTH_TOKEN' THEN
    RETURN '***';
  END IF;

  v_clean := regexp_replace(p_plaintext, '\s', '', 'g');
  v_len   := length(v_clean);

  IF p_kind = 'IBAN' OR p_kind = 'ACCOUNT_NUMBER' THEN
    IF v_len <= 4 THEN
      RETURN '***';  -- too short to safely reveal anything
    END IF;
    RETURN '***' || right(v_clean, 4);
  END IF;

  IF p_kind = 'VAT_NUMBER' THEN
    IF v_len <= 4 THEN
      RETURN '***';
    END IF;
    RETURN left(v_clean, 2) || '***' || right(v_clean, 2);
  END IF;

  RAISE EXCEPTION 'mask_field: unsupported kind %', p_kind USING ERRCODE = '22023';
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.mask_field(text, keys.field_kind_enum) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION keys.mask_field(text, keys.field_kind_enum) TO authenticated, service_role;

COMMENT ON FUNCTION keys.mask_field(text, keys.field_kind_enum) IS
'B05·P05 pure IMMUTABLE masking. Deterministic given same input + kind; no audit emitted on call (re-masking is idempotent per spec).';

-- ---- keys.encrypt_field -----------------------------------------------------
-- SILENT — no audit on routine writes per spec line 42. FIELD_ENCRYPTED is
-- reserved for bulk-migration runbooks. Returns NULL if DEK unavailable
-- (Mitigation A — get_active_dek_material already emitted KEY_ACCESS_DENIED).

CREATE OR REPLACE FUNCTION keys.encrypt_field(
  p_business_id uuid,
  p_plaintext   text
) RETURNS bytea
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_dek       bytea;
  v_dek_b64   text;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'encrypt_field: business_id is required' USING ERRCODE = '22000';
  END IF;
  IF p_plaintext IS NULL THEN
    RETURN NULL;
  END IF;

  v_dek := keys.get_active_dek_material(p_business_id);
  IF v_dek IS NULL THEN
    RETURN NULL;  -- KEY_ACCESS_DENIED already emitted by get_active_dek_material
  END IF;

  v_dek_b64 := encode(v_dek, 'base64');
  RETURN extensions.pgp_sym_encrypt(p_plaintext, v_dek_b64);
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.encrypt_field(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.encrypt_field(uuid, text) TO service_role;

COMMENT ON FUNCTION keys.encrypt_field(uuid, text) IS
'B05·P05 field encryption. Silent on routine writes (no audit). Returns NULL if DEK unavailable (Mitigation A — KEY_ACCESS_DENIED emitted by get_active_dek_material). service-role only.';

-- ---- keys.decrypt_field -----------------------------------------------------
-- Emits FIELD_DECRYPTED on success with field_name + ciphertext_fingerprint;
-- NEVER plaintext in audit payload. Catches pgp_sym_decrypt RAISE (wrong key
-- / corrupt data — cross-tenant attempts) and returns NULL silently — no
-- plaintext leakage, no audit-then-raise rollback hazard.

CREATE OR REPLACE FUNCTION keys.decrypt_field(
  p_business_id uuid,
  p_ciphertext  bytea,
  p_field_name  text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_dek         bytea;
  v_dek_b64     text;
  v_plaintext   text;
  v_fingerprint text;
  v_org_id      uuid;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'decrypt_field: business_id is required' USING ERRCODE = '22000';
  END IF;
  IF p_field_name IS NULL OR length(btrim(p_field_name)) = 0 THEN
    RAISE EXCEPTION 'decrypt_field: field_name is required' USING ERRCODE = '22000';
  END IF;
  IF p_ciphertext IS NULL THEN
    RETURN NULL;
  END IF;

  v_dek := keys.get_active_dek_material(p_business_id);
  IF v_dek IS NULL THEN
    RETURN NULL;
  END IF;

  v_dek_b64 := encode(v_dek, 'base64');

  BEGIN
    v_plaintext := extensions.pgp_sym_decrypt(p_ciphertext, v_dek_b64);
  EXCEPTION WHEN OTHERS THEN
    -- Wrong key (cross-tenant) / corrupt data. Return NULL silently —
    -- no plaintext exposed; no FIELD_DECRYPTED emission (it's a non-event
    -- at this layer; API enforces tenant boundary upstream).
    RETURN NULL;
  END;

  v_fingerprint := public.hash_text_sha256(encode(p_ciphertext, 'base64'));
  SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_business_id;

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'FIELD_DECRYPTED',
    p_subject_type    => 'ENCRYPTED_FIELD'::audit.subject_type_enum,
    p_actor_system    => 'keys.decrypt_field',
    p_organization_id => v_org_id,
    p_business_id     => p_business_id,
    p_reason          => format('field %s decrypted', p_field_name),
    p_after_state     => jsonb_build_object(
      'field_name',             p_field_name,
      'business_id',            p_business_id,
      'ciphertext_fingerprint', v_fingerprint,
      'ciphertext_bytes',       octet_length(p_ciphertext)
    )
  );

  RETURN v_plaintext;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.decrypt_field(uuid, bytea, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.decrypt_field(uuid, bytea, text) TO service_role;

COMMENT ON FUNCTION keys.decrypt_field(uuid, bytea, text) IS
'B05·P05 field decryption. Emits FIELD_DECRYPTED with field_name + ciphertext_fingerprint (NEVER plaintext). Cross-tenant / wrong-key attempts caught silently → RETURN NULL. service-role only; HTTP decrypt-at-use API enforces B05·P06 permission upstream.';

-- ---- bootstrap audit event --------------------------------------------------
DO $bootstrap$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'VAULT_INITIALIZED',
    p_subject_type => 'AUDIT_QUERY'::audit.subject_type_enum,
    p_actor_system => 'b05p05-migration',
    p_reason       => 'field-level encryption surface online — keys.encrypt_field + keys.decrypt_field + keys.mask_field; *_masked columns added; oauth_*_encrypted migrated to bytea'
  );
END
$bootstrap$;
