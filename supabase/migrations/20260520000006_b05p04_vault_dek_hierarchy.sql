-- B05·P04 Vault Setup & DEK Hierarchy
-- ============================================================================
-- Establishes the key hierarchy: Supabase Vault root key (managed by Vault
-- platform) → per-organization KEK (stored as a Vault secret; Vault root key
-- protects it via transparent at-rest encryption) → per-business DEK (a 32-byte
-- AES-256 key, encrypted with the parent KEK material via pgp_sym_encrypt_bytea
-- and stored as bytea ciphertext on keys.business_deks).
--
-- Critical invariant: DEK plaintext NEVER persists anywhere — it lives in
-- memory only for the duration of an unwrap call. The actual hierarchy is:
--   * KEK material = vault.decrypted_secrets.decrypted_secret (read-only view
--     that decrypts via the Vault root key)
--   * DEK material = pgp_sym_decrypt_bytea(business_deks.dek_ciphertext, KEK)
--
-- Phase 05 (pgcrypto field-level encryption) consumes get_active_dek_material()
-- as its read-side surface.
-- ============================================================================

-- ---- subject_type extensions -------------------------------------------------
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'KEK';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'DEK';

-- ---- schema + status enums ---------------------------------------------------
CREATE SCHEMA IF NOT EXISTS keys;

CREATE TYPE keys.kek_status_enum AS ENUM ('ACTIVE','ROTATED','RETIRED');
CREATE TYPE keys.dek_status_enum AS ENUM ('ACTIVE','RETIRED','DESTROYED');

-- ---- keys.organization_keks --------------------------------------------------
CREATE TABLE keys.organization_keks (
  kek_id           uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  vault_secret_id  uuid NOT NULL,  -- references vault.secrets(id); no FK because vault is a system schema
  status           keys.kek_status_enum NOT NULL DEFAULT 'ACTIVE',
  generation       integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  rotated_at       timestamptz,
  retired_at       timestamptz,
  CONSTRAINT organization_keks_generation_positive_chk CHECK (generation >= 1)
);

-- One ACTIVE KEK per organization (partial-UNIQUE pattern from B04·P11)
CREATE UNIQUE INDEX uq_organization_keks_one_active
  ON keys.organization_keks (organization_id)
  WHERE status = 'ACTIVE';
CREATE INDEX idx_organization_keks_org_status
  ON keys.organization_keks (organization_id, status, generation DESC);

-- ---- keys.business_deks ------------------------------------------------------
CREATE TABLE keys.business_deks (
  dek_id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  business_id         uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  parent_kek_id       uuid NOT NULL REFERENCES keys.organization_keks(kek_id) ON DELETE RESTRICT,
  dek_ciphertext      bytea,  -- NULL after DESTROYED (cryptographic erasure)
  status              keys.dek_status_enum NOT NULL DEFAULT 'ACTIVE',
  generation          integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  rotated_at          timestamptz,
  retired_at          timestamptz,
  destroyed_at        timestamptz,
  destruction_reason  text,
  CONSTRAINT business_deks_generation_positive_chk CHECK (generation >= 1),
  CONSTRAINT business_deks_destroyed_state_chk CHECK (
    -- ACTIVE / RETIRED must have ciphertext; DESTROYED must have NULL ciphertext + destroyed_at + reason
    (status IN ('ACTIVE','RETIRED') AND dek_ciphertext IS NOT NULL AND destroyed_at IS NULL)
    OR
    (status = 'DESTROYED' AND dek_ciphertext IS NULL AND destroyed_at IS NOT NULL AND destruction_reason IS NOT NULL)
  )
);

-- One ACTIVE DEK per business
CREATE UNIQUE INDEX uq_business_deks_one_active
  ON keys.business_deks (business_id)
  WHERE status = 'ACTIVE';
CREATE INDEX idx_business_deks_business_status
  ON keys.business_deks (business_id, status, generation DESC);
CREATE INDEX idx_business_deks_parent_kek
  ON keys.business_deks (parent_kek_id);

-- ---- RLS ---------------------------------------------------------------------
ALTER TABLE keys.organization_keks ENABLE ROW LEVEL SECURITY;
ALTER TABLE keys.organization_keks FORCE  ROW LEVEL SECURITY;
ALTER TABLE keys.business_deks     ENABLE ROW LEVEL SECURITY;
ALTER TABLE keys.business_deks     FORCE  ROW LEVEL SECURITY;

-- Authenticated: SELECT metadata only for OWNER/ADMIN of the org/business.
-- ciphertext column is granted SELECT-restricted below; OWNER/ADMIN can see
-- the metadata for key audit purposes but cannot exfiltrate ciphertext.
CREATE POLICY organization_keks_select_owner_admin ON keys.organization_keks
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.organization_id = keys.organization_keks.organization_id
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN')
    )
  );

CREATE POLICY business_deks_select_owner_admin ON keys.business_deks
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.business_entities be
      WHERE be.id = keys.business_deks.business_id
        AND be.organization_id = public.current_org()
    )
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.organization_id = public.current_org()
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN')
    )
  );

-- Block all direct INSERT/UPDATE/DELETE from authenticated
CREATE POLICY organization_keks_no_insert ON keys.organization_keks
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY organization_keks_no_update ON keys.organization_keks
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY organization_keks_no_delete ON keys.organization_keks
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

CREATE POLICY business_deks_no_insert ON keys.business_deks
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY business_deks_no_update ON keys.business_deks
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY business_deks_no_delete ON keys.business_deks
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- grants ------------------------------------------------------------------
GRANT USAGE ON SCHEMA keys TO authenticated, service_role;

-- Authenticated can SELECT metadata, but NOT the dek_ciphertext column
GRANT SELECT (kek_id, organization_id, vault_secret_id, status, generation, created_at, rotated_at, retired_at)
  ON keys.organization_keks TO authenticated;
GRANT SELECT (dek_id, business_id, parent_kek_id, status, generation, created_at, rotated_at, retired_at, destroyed_at, destruction_reason)
  ON keys.business_deks TO authenticated;

-- service_role direct DML is NOT granted — all writes go through DEFINER RPCs.
GRANT SELECT ON keys.organization_keks, keys.business_deks TO service_role;

-- ---- internal helper: fetch KEK material -------------------------------------
-- Reads the decrypted KEK bytes from Vault for a given KEK id. SECURITY DEFINER
-- so it can read vault.decrypted_secrets even when the caller is in a less
-- privileged context. NO audit emission here — emit at the RPC layer.

CREATE OR REPLACE FUNCTION keys._get_kek_material(p_kek_id uuid)
RETURNS bytea
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = keys, vault, extensions, public, pg_temp
AS $fn$
DECLARE
  v_secret_id uuid;
  v_b64       text;
BEGIN
  SELECT vault_secret_id INTO v_secret_id
    FROM keys.organization_keks
   WHERE kek_id = p_kek_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_get_kek_material: kek_id % not found', p_kek_id USING ERRCODE = 'P0002';
  END IF;

  SELECT decrypted_secret INTO v_b64
    FROM vault.decrypted_secrets
   WHERE id = v_secret_id;
  IF v_b64 IS NULL THEN
    RAISE EXCEPTION '_get_kek_material: vault secret % not found / not readable', v_secret_id USING ERRCODE = 'P0002';
  END IF;

  RETURN decode(v_b64, 'base64');
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys._get_kek_material(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys._get_kek_material(uuid) TO service_role;

-- ---- RPC: create_org_kek -----------------------------------------------------
-- Generates 32 random bytes, base64-encodes, stores via vault.create_secret,
-- inserts a keys.organization_keks row, emits KEK_CREATED. Called by the
-- AFTER INSERT trigger on public.organizations.

CREATE OR REPLACE FUNCTION keys.create_org_kek(p_organization_id uuid)
RETURNS keys.organization_keks
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_kek_bytes bytea;
  v_kek_b64   text;
  v_secret_id uuid;
  v_row       keys.organization_keks;
BEGIN
  IF p_organization_id IS NULL THEN
    RAISE EXCEPTION 'create_org_kek: organization_id is required' USING ERRCODE = '22000';
  END IF;
  IF EXISTS (SELECT 1 FROM keys.organization_keks WHERE organization_id = p_organization_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'create_org_kek: org % already has an ACTIVE KEK', p_organization_id USING ERRCODE = '23505';
  END IF;

  v_kek_bytes := extensions.gen_random_bytes(32);
  v_kek_b64   := encode(v_kek_bytes, 'base64');
  v_secret_id := vault.create_secret(
    new_secret      => v_kek_b64,
    new_name        => 'kek-' || p_organization_id::text,
    new_description => 'B05P04 KEK for organization ' || p_organization_id::text
  );

  INSERT INTO keys.organization_keks (organization_id, vault_secret_id, status, generation)
  VALUES (p_organization_id, v_secret_id, 'ACTIVE', 1)
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'KEK_CREATED',
    p_subject_type    => 'KEK'::audit.subject_type_enum,
    p_subject_id      => v_row.kek_id,
    p_actor_system    => 'keys.create_org_kek',
    p_organization_id => p_organization_id,
    p_reason          => 'KEK auto-generated on organization creation',
    p_after_state     => jsonb_build_object(
      'kek_id', v_row.kek_id,
      'organization_id', p_organization_id,
      'vault_secret_id', v_secret_id,
      'generation', 1
    )
  );

  RETURN v_row;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.create_org_kek(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.create_org_kek(uuid) TO service_role;

-- ---- RPC: create_business_dek ------------------------------------------------
-- Fetches parent KEK bytes from Vault, generates a 32-byte DEK, wraps with
-- pgp_sym_encrypt_bytea, inserts row, emits DEK_CREATED. DEK plaintext is
-- discarded at function return — never persisted.

CREATE OR REPLACE FUNCTION keys.create_business_dek(p_business_id uuid)
RETURNS keys.business_deks
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_org_id      uuid;
  v_parent_kek  keys.organization_keks;
  v_kek_bytes   bytea;
  v_kek_b64     text;
  v_dek_bytes   bytea;
  v_ciphertext  bytea;
  v_row         keys.business_deks;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'create_business_dek: business_id is required' USING ERRCODE = '22000';
  END IF;
  SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_business_id;
  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'create_business_dek: business % not found', p_business_id USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (SELECT 1 FROM keys.business_deks WHERE business_id = p_business_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'create_business_dek: business % already has an ACTIVE DEK', p_business_id USING ERRCODE = '23505';
  END IF;

  SELECT * INTO v_parent_kek
    FROM keys.organization_keks
   WHERE organization_id = v_org_id AND status = 'ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_business_dek: no ACTIVE KEK for org % (run create_org_kek first)', v_org_id USING ERRCODE = 'P0002';
  END IF;

  v_kek_bytes  := keys._get_kek_material(v_parent_kek.kek_id);
  v_kek_b64    := encode(v_kek_bytes, 'base64');
  v_dek_bytes  := extensions.gen_random_bytes(32);
  v_ciphertext := extensions.pgp_sym_encrypt_bytea(v_dek_bytes, v_kek_b64);

  INSERT INTO keys.business_deks (business_id, parent_kek_id, dek_ciphertext, status, generation)
  VALUES (p_business_id, v_parent_kek.kek_id, v_ciphertext, 'ACTIVE', 1)
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'DEK_CREATED',
    p_subject_type    => 'DEK'::audit.subject_type_enum,
    p_subject_id      => v_row.dek_id,
    p_actor_system    => 'keys.create_business_dek',
    p_organization_id => v_org_id,
    p_business_id     => p_business_id,
    p_reason          => 'DEK auto-generated on business creation',
    p_after_state     => jsonb_build_object(
      'dek_id', v_row.dek_id,
      'business_id', p_business_id,
      'parent_kek_id', v_parent_kek.kek_id,
      'generation', 1
    )
  );

  RETURN v_row;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.create_business_dek(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.create_business_dek(uuid) TO service_role;

-- ---- RPC: get_active_dek_material -------------------------------------------
-- Read-side surface Phase 05 will consume. RETURNS NULL on runtime denials
-- (BUSINESS_NOT_FOUND, NO_ACTIVE_DEK) and emits KEY_ACCESS_DENIED BEFORE the
-- NULL return — Mitigation A of audit-then-raise hazard (RAISE would roll
-- back the audit emission). RAISES only for programming-error inputs.

CREATE OR REPLACE FUNCTION keys.get_active_dek_material(p_business_id uuid)
RETURNS bytea
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_org_id      uuid;
  v_dek_row     keys.business_deks;
  v_kek_bytes   bytea;
  v_kek_b64     text;
  v_dek_bytes   bytea;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'get_active_dek_material: business_id is required' USING ERRCODE = '22000';
  END IF;

  SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_business_id;
  IF v_org_id IS NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'KEY_ACCESS_DENIED',
      p_subject_type => 'DEK'::audit.subject_type_enum,
      p_actor_system => 'keys.get_active_dek_material',
      p_reason       => format('business %s not found', p_business_id),
      p_after_state  => jsonb_build_object('business_id', p_business_id, 'reason_code', 'BUSINESS_NOT_FOUND')
    );
    RETURN NULL;
  END IF;

  SELECT * INTO v_dek_row
    FROM keys.business_deks
   WHERE business_id = p_business_id AND status = 'ACTIVE';
  IF NOT FOUND THEN
    PERFORM audit.emit_audit(
      p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
      p_action          => 'KEY_ACCESS_DENIED',
      p_subject_type    => 'DEK'::audit.subject_type_enum,
      p_actor_system    => 'keys.get_active_dek_material',
      p_organization_id => v_org_id,
      p_business_id     => p_business_id,
      p_reason          => 'no ACTIVE DEK for business',
      p_after_state     => jsonb_build_object('business_id', p_business_id, 'reason_code', 'NO_ACTIVE_DEK')
    );
    RETURN NULL;
  END IF;

  v_kek_bytes := keys._get_kek_material(v_dek_row.parent_kek_id);
  v_kek_b64   := encode(v_kek_bytes, 'base64');
  v_dek_bytes := extensions.pgp_sym_decrypt_bytea(v_dek_row.dek_ciphertext, v_kek_b64);

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'KEY_ACCESSED',
    p_subject_type    => 'DEK'::audit.subject_type_enum,
    p_subject_id      => v_dek_row.dek_id,
    p_actor_system    => 'keys.get_active_dek_material',
    p_organization_id => v_org_id,
    p_business_id     => p_business_id,
    p_reason          => 'DEK material fetched for field-level encryption',
    p_after_state     => jsonb_build_object(
      'dek_id', v_dek_row.dek_id,
      'business_id', p_business_id,
      'generation', v_dek_row.generation
    )
  );

  RETURN v_dek_bytes;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.get_active_dek_material(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.get_active_dek_material(uuid) TO service_role;

-- ---- RPC: get_dek_by_id ------------------------------------------------------
-- Read-side for historical RETIRED-DEK-encrypted data. Same shape as
-- get_active_dek_material but resolves by dek_id; allowed for ACTIVE and
-- RETIRED, raises for DESTROYED.

CREATE OR REPLACE FUNCTION keys.get_dek_by_id(p_dek_id uuid)
RETURNS bytea
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_dek_row   keys.business_deks;
  v_org_id    uuid;
  v_kek_bytes bytea;
  v_kek_b64   text;
  v_dek_bytes bytea;
BEGIN
  IF p_dek_id IS NULL THEN
    RAISE EXCEPTION 'get_dek_by_id: dek_id is required' USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_dek_row FROM keys.business_deks WHERE dek_id = p_dek_id;
  IF NOT FOUND THEN
    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'KEY_ACCESS_DENIED',
      p_subject_type => 'DEK'::audit.subject_type_enum,
      p_actor_system => 'keys.get_dek_by_id',
      p_reason       => format('dek %s not found', p_dek_id),
      p_after_state  => jsonb_build_object('dek_id', p_dek_id, 'reason_code', 'DEK_NOT_FOUND')
    );
    RETURN NULL;
  END IF;

  SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = v_dek_row.business_id;

  IF v_dek_row.status = 'DESTROYED' THEN
    PERFORM audit.emit_audit(
      p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
      p_action          => 'KEY_ACCESS_DENIED',
      p_subject_type    => 'DEK'::audit.subject_type_enum,
      p_subject_id      => p_dek_id,
      p_actor_system    => 'keys.get_dek_by_id',
      p_organization_id => v_org_id,
      p_business_id     => v_dek_row.business_id,
      p_reason          => 'DEK has been DESTROYED — cryptographic erasure',
      p_after_state     => jsonb_build_object('dek_id', p_dek_id, 'reason_code', 'DEK_DESTROYED')
    );
    RETURN NULL;
  END IF;

  v_kek_bytes := keys._get_kek_material(v_dek_row.parent_kek_id);
  v_kek_b64   := encode(v_kek_bytes, 'base64');
  v_dek_bytes := extensions.pgp_sym_decrypt_bytea(v_dek_row.dek_ciphertext, v_kek_b64);

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'KEY_ACCESSED',
    p_subject_type    => 'DEK'::audit.subject_type_enum,
    p_subject_id      => p_dek_id,
    p_actor_system    => 'keys.get_dek_by_id',
    p_organization_id => v_org_id,
    p_business_id     => v_dek_row.business_id,
    p_reason          => format('historical DEK material fetched (status=%s)', v_dek_row.status),
    p_after_state     => jsonb_build_object('dek_id', p_dek_id, 'status', v_dek_row.status, 'generation', v_dek_row.generation)
  );

  RETURN v_dek_bytes;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.get_dek_by_id(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.get_dek_by_id(uuid) TO service_role;

-- ---- RPC: rotate_dek ---------------------------------------------------------
-- Creates a new ACTIVE DEK for the business; marks the current ACTIVE one as
-- RETIRED. Phase 05's re-encryption job re-encrypts existing pgcrypto
-- ciphertexts using the new key (deferred to Phase 05).

CREATE OR REPLACE FUNCTION keys.rotate_dek(p_business_id uuid)
RETURNS keys.business_deks
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_old_dek      keys.business_deks;
  v_new_dek      keys.business_deks;
  v_org_id       uuid;
  v_parent_kek   keys.organization_keks;
  v_kek_bytes    bytea;
  v_kek_b64      text;
  v_new_bytes    bytea;
  v_ciphertext   bytea;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'rotate_dek: business_id is required' USING ERRCODE = '22000';
  END IF;

  SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_business_id;
  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'rotate_dek: business % not found', p_business_id USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_old_dek
    FROM keys.business_deks
   WHERE business_id = p_business_id AND status = 'ACTIVE'
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rotate_dek: no ACTIVE DEK for business %', p_business_id USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_parent_kek
    FROM keys.organization_keks
   WHERE organization_id = v_org_id AND status = 'ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rotate_dek: no ACTIVE KEK for org %', v_org_id USING ERRCODE = 'P0002';
  END IF;

  -- Mark old RETIRED first so the partial-UNIQUE on ACTIVE doesn't conflict
  UPDATE keys.business_deks
     SET status = 'RETIRED', retired_at = clock_timestamp()
   WHERE dek_id = v_old_dek.dek_id;

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'DEK_RETIRED',
    p_subject_type    => 'DEK'::audit.subject_type_enum,
    p_subject_id      => v_old_dek.dek_id,
    p_actor_system    => 'keys.rotate_dek',
    p_organization_id => v_org_id,
    p_business_id     => p_business_id,
    p_reason          => 'rotation: superseded by new generation'
  );

  v_kek_bytes  := keys._get_kek_material(v_parent_kek.kek_id);
  v_kek_b64    := encode(v_kek_bytes, 'base64');
  v_new_bytes  := extensions.gen_random_bytes(32);
  v_ciphertext := extensions.pgp_sym_encrypt_bytea(v_new_bytes, v_kek_b64);

  INSERT INTO keys.business_deks (business_id, parent_kek_id, dek_ciphertext, status, generation)
  VALUES (p_business_id, v_parent_kek.kek_id, v_ciphertext, 'ACTIVE', v_old_dek.generation + 1)
  RETURNING * INTO v_new_dek;

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'DEK_ROTATED',
    p_subject_type    => 'DEK'::audit.subject_type_enum,
    p_subject_id      => v_new_dek.dek_id,
    p_actor_system    => 'keys.rotate_dek',
    p_organization_id => v_org_id,
    p_business_id     => p_business_id,
    p_reason          => format('rotation generation %s -> %s', v_old_dek.generation, v_new_dek.generation),
    p_after_state     => jsonb_build_object(
      'old_dek_id', v_old_dek.dek_id,
      'new_dek_id', v_new_dek.dek_id,
      'business_id', p_business_id,
      'generation', v_new_dek.generation
    )
  );

  RETURN v_new_dek;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.rotate_dek(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.rotate_dek(uuid) TO service_role;

-- ---- RPC: rotate_kek ---------------------------------------------------------
-- Creates a new ACTIVE KEK for the organization; re-wraps every ACTIVE and
-- RETIRED DEK belonging to this org's businesses under the new KEK. Old KEK
-- transitions ACTIVE -> ROTATED. DEK material doesn't change — only the wrap.

CREATE OR REPLACE FUNCTION keys.rotate_kek(p_organization_id uuid)
RETURNS keys.organization_keks
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_old_kek     keys.organization_keks;
  v_new_kek     keys.organization_keks;
  v_old_bytes   bytea;
  v_new_bytes   bytea;
  v_new_b64     text;
  v_old_b64     text;
  v_secret_id   uuid;
  v_dek_row     record;
  v_dek_bytes   bytea;
  v_new_ct      bytea;
  v_rewrapped   integer := 0;
BEGIN
  IF p_organization_id IS NULL THEN
    RAISE EXCEPTION 'rotate_kek: organization_id is required' USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_old_kek
    FROM keys.organization_keks
   WHERE organization_id = p_organization_id AND status = 'ACTIVE'
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rotate_kek: no ACTIVE KEK for org %', p_organization_id USING ERRCODE = 'P0002';
  END IF;

  v_old_bytes := keys._get_kek_material(v_old_kek.kek_id);
  v_old_b64   := encode(v_old_bytes, 'base64');
  v_new_bytes := extensions.gen_random_bytes(32);
  v_new_b64   := encode(v_new_bytes, 'base64');

  v_secret_id := vault.create_secret(
    new_secret      => v_new_b64,
    new_name        => 'kek-' || p_organization_id::text || '-g' || (v_old_kek.generation + 1)::text,
    new_description => format('B05P04 rotated KEK for org %s (gen %s)', p_organization_id, v_old_kek.generation + 1)
  );

  -- Mark old ROTATED first so partial-UNIQUE doesn't conflict
  UPDATE keys.organization_keks
     SET status = 'ROTATED', rotated_at = clock_timestamp()
   WHERE kek_id = v_old_kek.kek_id;

  INSERT INTO keys.organization_keks (organization_id, vault_secret_id, status, generation)
  VALUES (p_organization_id, v_secret_id, 'ACTIVE', v_old_kek.generation + 1)
  RETURNING * INTO v_new_kek;

  -- Re-wrap every ACTIVE + RETIRED DEK under this org's businesses (not DESTROYED)
  FOR v_dek_row IN
    SELECT bd.* FROM keys.business_deks bd
     JOIN public.business_entities be ON be.id = bd.business_id
     WHERE be.organization_id = p_organization_id
       AND bd.status IN ('ACTIVE','RETIRED')
       AND bd.parent_kek_id = v_old_kek.kek_id
  LOOP
    v_dek_bytes := extensions.pgp_sym_decrypt_bytea(v_dek_row.dek_ciphertext, v_old_b64);
    v_new_ct    := extensions.pgp_sym_encrypt_bytea(v_dek_bytes, v_new_b64);
    UPDATE keys.business_deks
       SET dek_ciphertext = v_new_ct,
           parent_kek_id  = v_new_kek.kek_id
     WHERE dek_id = v_dek_row.dek_id;
    v_rewrapped := v_rewrapped + 1;
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'KEK_ROTATED',
    p_subject_type    => 'KEK'::audit.subject_type_enum,
    p_subject_id      => v_new_kek.kek_id,
    p_actor_system    => 'keys.rotate_kek',
    p_organization_id => p_organization_id,
    p_reason          => format('KEK rotated generation %s -> %s; %s DEKs re-wrapped', v_old_kek.generation, v_new_kek.generation, v_rewrapped),
    p_after_state     => jsonb_build_object(
      'old_kek_id', v_old_kek.kek_id,
      'new_kek_id', v_new_kek.kek_id,
      'organization_id', p_organization_id,
      'generation', v_new_kek.generation,
      'deks_rewrapped', v_rewrapped
    )
  );

  RETURN v_new_kek;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.rotate_kek(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.rotate_kek(uuid) TO service_role;

-- ---- RPC: destroy_dek --------------------------------------------------------
-- Cryptographic erasure: NULLs the ciphertext, sets status=DESTROYED.
-- Gated by session-local `keys.allow_destroy = 'on'`. The retention pass
-- (B04·P10 future hook) and the manual ops procedure are the only paths that
-- set this var. Emits DEK_DESTROYED BEFORE NULLing so the destruction is
-- forensically recorded even if the UPDATE fails.

-- Returns jsonb envelope {success, denial_reason?, ...} to honor the
-- audit-then-raise hazard: on guard failure we must EMIT the audit and
-- RETURN (Mitigation A) so the audit row survives. RAISEing would roll
-- back the KEY_ACCESS_DENIED emission alongside the function frame.
CREATE OR REPLACE FUNCTION keys.destroy_dek(
  p_business_id uuid,
  p_dek_id      uuid,
  p_reason      text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, vault, extensions, audit, public, pg_temp
AS $fn$
DECLARE
  v_dek_row keys.business_deks;
  v_org_id  uuid;
BEGIN
  IF p_business_id IS NULL OR p_dek_id IS NULL OR p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'destroy_dek: business_id, dek_id, reason all required' USING ERRCODE = '22000';
  END IF;

  IF COALESCE(current_setting('keys.allow_destroy', true), 'off') <> 'on' THEN
    SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_business_id;
    PERFORM audit.emit_audit(
      p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
      p_action          => 'KEY_ACCESS_DENIED',
      p_subject_type    => 'DEK'::audit.subject_type_enum,
      p_subject_id      => p_dek_id,
      p_actor_system    => 'keys.destroy_dek',
      p_organization_id => v_org_id,
      p_business_id     => p_business_id,
      p_reason          => 'destroy_dek invoked without keys.allow_destroy=on guard',
      p_after_state     => jsonb_build_object('dek_id', p_dek_id, 'reason_code', 'GUARD_NOT_SET', 'requested_reason', p_reason)
    );
    RETURN jsonb_build_object(
      'success',        false,
      'denial_reason',  'GUARD_NOT_SET',
      'dek_id',         p_dek_id,
      'business_id',    p_business_id,
      'message',        'destroy_dek requires keys.allow_destroy=on set by retention or multi-party ops procedure'
    );
  END IF;

  SELECT * INTO v_dek_row
    FROM keys.business_deks
   WHERE dek_id = p_dek_id AND business_id = p_business_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'denial_reason', 'DEK_NOT_FOUND', 'dek_id', p_dek_id, 'business_id', p_business_id);
  END IF;
  IF v_dek_row.status = 'DESTROYED' THEN
    RETURN jsonb_build_object('success', false, 'denial_reason', 'ALREADY_DESTROYED', 'dek_id', p_dek_id, 'business_id', p_business_id);
  END IF;

  SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_business_id;

  -- Emit BEFORE nulling: even if the subsequent UPDATE fails, the destruction
  -- attempt is forensically recorded. Audit chain advances inside the same tx.
  PERFORM audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'DEK_DESTROYED',
    p_subject_type    => 'DEK'::audit.subject_type_enum,
    p_subject_id      => p_dek_id,
    p_actor_system    => 'keys.destroy_dek',
    p_organization_id => v_org_id,
    p_business_id     => p_business_id,
    p_reason          => p_reason,
    p_before_state    => jsonb_build_object('dek_id', p_dek_id, 'status', v_dek_row.status, 'generation', v_dek_row.generation),
    p_after_state     => jsonb_build_object('dek_id', p_dek_id, 'status', 'DESTROYED', 'destruction_reason', p_reason)
  );

  UPDATE keys.business_deks
     SET status             = 'DESTROYED',
         dek_ciphertext     = NULL,
         destroyed_at       = clock_timestamp(),
         destruction_reason = p_reason,
         retired_at         = COALESCE(retired_at, clock_timestamp())
   WHERE dek_id = p_dek_id
  RETURNING * INTO v_dek_row;

  RETURN jsonb_build_object(
    'success',            true,
    'dek_id',             p_dek_id,
    'business_id',        p_business_id,
    'status',             v_dek_row.status,
    'destroyed_at',       v_dek_row.destroyed_at,
    'destruction_reason', v_dek_row.destruction_reason
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION keys.destroy_dek(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION keys.destroy_dek(uuid, uuid, text) TO service_role;

-- ---- AFTER INSERT triggers ---------------------------------------------------

CREATE OR REPLACE FUNCTION keys._on_organization_created()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, public, pg_temp
AS $fn$
BEGIN
  PERFORM keys.create_org_kek(NEW.id);
  RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION keys._on_business_created()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = keys, public, pg_temp
AS $fn$
BEGIN
  PERFORM keys.create_business_dek(NEW.id);
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_organizations_create_kek
  AFTER INSERT ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION keys._on_organization_created();

CREATE TRIGGER trg_business_entities_create_dek
  AFTER INSERT ON public.business_entities
  FOR EACH ROW EXECUTE FUNCTION keys._on_business_created();

-- ---- bootstrap VAULT_INITIALIZED audit event --------------------------------
-- Recorded via a DO block so the function-body-late-parse rule covers the
-- KEK/DEK enum literals if any future bootstrap action needs them.

DO $bootstrap$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'VAULT_INITIALIZED',
    p_subject_type => 'AUDIT_QUERY'::audit.subject_type_enum,
    p_actor_system => 'b05p04-migration',
    p_reason       => 'Vault DEK hierarchy schema online — keys.organization_keks + keys.business_deks + 7 RPCs + 2 lifecycle triggers'
  );
END
$bootstrap$;

-- ---- comments ----------------------------------------------------------------

COMMENT ON SCHEMA keys IS
'B05·P04 Vault-backed key hierarchy. organization_keks store wrapped KEKs in Vault (via vault.create_secret); business_deks store KEK-wrapped DEK ciphertexts (pgp_sym_encrypt_bytea). DEK plaintext never persists — only flows through DEFINER RPCs.';

COMMENT ON TABLE keys.organization_keks IS
'B05·P04: per-organization Key Encryption Key. KEK material lives in vault.secrets (read via vault.decrypted_secrets view); this table holds metadata + Vault secret reference.';

COMMENT ON TABLE keys.business_deks IS
'B05·P04: per-business Data Encryption Key. dek_ciphertext is the DEK bytes wrapped with parent KEK material via pgp_sym_encrypt_bytea. After DESTROYED, ciphertext is NULL (cryptographic erasure) — any data still encrypted under this DEK becomes permanently unrecoverable.';

COMMENT ON FUNCTION keys.get_active_dek_material(uuid) IS
'B05·P04 read-side surface for Phase 05 field-level encryption. Returns 32-byte DEK material on success; RETURNS NULL on runtime denials (BUSINESS_NOT_FOUND, NO_ACTIVE_DEK) — emits KEY_ACCESS_DENIED audit before NULL return (Mitigation A of audit-then-raise hazard). RAISES only for programming errors (NULL business_id). service-role only.';

COMMENT ON FUNCTION keys.destroy_dek(uuid, uuid, text) IS
'B05·P04 cryptographic erasure. Returns jsonb envelope {success, denial_reason?, ...} (Mitigation A of audit-then-raise hazard — on guard failure emit KEY_ACCESS_DENIED + RETURN denial, no RAISE). Gated by session var keys.allow_destroy=on (retention pass or multi-party ops). Audit-BEFORE-mutate ordering.';
