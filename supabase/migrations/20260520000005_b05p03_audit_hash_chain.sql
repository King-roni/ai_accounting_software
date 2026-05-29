-- B05·P03 Audit Log Tamper Resistance
-- ============================================================================
-- Wires the hash chain over B05·P02's audit.audit_events placeholder columns.
-- Each emitted event hash-chains to the previous via the public.hash_chain_append
-- primitive from B04·P01. A chain head per organization tracks the running hash
-- (with a single system chain for org-less events such as pre-tenancy login
-- attempts and the AUDIT_LOG_INITIALIZED bootstrap). Periodic checkpoints anchor
-- the chain head into a third-party RFC 3161 timestamping authority — this phase
-- ships a deterministic PLACEHOLDER_LOCAL provider; the real TSA HTTP client
-- lives in the API layer (production cutover). A verification job walks the
-- chain end-to-end recomputing hashes and cross-checking checkpoints.
--
-- Hook-swap pattern (B04·P10 → B04·P11):
--   audit.emit_audit signature is preserved verbatim. Callers from B04 and
--   B05·P02 require no changes. The new body computes prev_event_hash +
--   event_hash inside the same transaction as the state change being audited
--   (transactional coupling — both commit or neither does).
-- ============================================================================

-- ---- subject_type extensions -------------------------------------------------
-- ALTER TYPE … ADD VALUE inside a single migration tx is allowed in PG 12+; the
-- new values are not visible to immediate statements but plpgsql function bodies
-- parse the literal-to-enum casts at call time, by which point the migration has
-- committed.
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CHAIN_HEAD';
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'CHAIN_CHECKPOINT';

-- ---- chain_heads -------------------------------------------------------------
-- One row per chain. Default partition is per-organization_id; org-less events
-- (AUDIT_LOG_INITIALIZED, pre-tenancy LOGIN_FAILED, etc.) share a single
-- system chain keyed by the nil-uuid.

CREATE TABLE audit.chain_heads (
  chain_id           uuid PRIMARY KEY,
  latest_event_id    bigint      NOT NULL,
  latest_event_hash  text        NOT NULL,
  latest_event_at    timestamptz NOT NULL,
  chain_started_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT chain_heads_hash_format_chk CHECK (latest_event_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX idx_chain_heads_latest_at ON audit.chain_heads (latest_event_at DESC);

ALTER TABLE audit.chain_heads ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.chain_heads FORCE  ROW LEVEL SECURITY;

-- SELECT: org-keyed chain visible to its members; system chain (nil uuid)
-- visible only to OWNER/ADMIN of any org they belong to.
CREATE POLICY chain_heads_select_tenant ON audit.chain_heads
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    chain_id <> '00000000-0000-0000-0000-000000000000'::uuid
    AND chain_id = public.current_org()
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.organization_id = audit.chain_heads.chain_id
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN','ACCOUNTANT','REVIEWER','READ_ONLY','BOOKKEEPER')
    )
  );

CREATE POLICY chain_heads_select_system_owners ON audit.chain_heads
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    chain_id = '00000000-0000-0000-0000-000000000000'::uuid
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN')
    )
  );

CREATE POLICY chain_heads_no_insert ON audit.chain_heads
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY chain_heads_no_update ON audit.chain_heads
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY chain_heads_no_delete ON audit.chain_heads
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- chain_checkpoints -------------------------------------------------------
-- Append-only checkpoint log. Each row is an anchor of the chain head into a
-- third-party RFC 3161 timestamping authority at a moment in time.

CREATE TABLE audit.chain_checkpoints (
  id                   uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  chain_id             uuid        NOT NULL REFERENCES audit.chain_heads(chain_id) ON DELETE RESTRICT,
  event_id             bigint      NOT NULL,
  event_hash           text        NOT NULL,
  timestamp_token      bytea       NOT NULL,
  tsa_provider         text        NOT NULL,
  tsa_response_status  text        NOT NULL DEFAULT 'OK',
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT chain_checkpoints_hash_format_chk CHECK (event_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT chain_checkpoints_provider_nonempty_chk CHECK (length(btrim(tsa_provider)) > 0)
);

CREATE INDEX idx_chain_checkpoints_chain_event ON audit.chain_checkpoints (chain_id, event_id DESC);
CREATE INDEX idx_chain_checkpoints_chain_created ON audit.chain_checkpoints (chain_id, created_at DESC);

-- Reuse the same immutability + delete-guard trigger functions defined in P02.
CREATE TRIGGER trg_chain_checkpoints_block_update
  BEFORE UPDATE ON audit.chain_checkpoints
  FOR EACH ROW EXECUTE FUNCTION audit.fn_block_update();

CREATE TRIGGER trg_chain_checkpoints_guard_delete
  BEFORE DELETE ON audit.chain_checkpoints
  FOR EACH ROW EXECUTE FUNCTION audit.fn_guard_delete();

ALTER TABLE audit.chain_checkpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.chain_checkpoints FORCE  ROW LEVEL SECURITY;

CREATE POLICY chain_checkpoints_select_tenant ON audit.chain_checkpoints
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    chain_id <> '00000000-0000-0000-0000-000000000000'::uuid
    AND chain_id = public.current_org()
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.organization_id = audit.chain_checkpoints.chain_id
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN','ACCOUNTANT','REVIEWER','READ_ONLY','BOOKKEEPER')
    )
  );

CREATE POLICY chain_checkpoints_select_system_owners ON audit.chain_checkpoints
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    chain_id = '00000000-0000-0000-0000-000000000000'::uuid
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN')
    )
  );

CREATE POLICY chain_checkpoints_no_insert ON audit.chain_checkpoints
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY chain_checkpoints_no_update ON audit.chain_checkpoints
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY chain_checkpoints_no_delete ON audit.chain_checkpoints
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- grants ------------------------------------------------------------------

GRANT SELECT ON audit.chain_heads, audit.chain_checkpoints TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON audit.chain_heads TO service_role;
GRANT SELECT, INSERT, DELETE ON audit.chain_checkpoints TO service_role;

-- ---- canonical_jsonb (recursive) ---------------------------------------------
-- Sorted-keys, comma-tight, RFC 8259-escape serialiser that matches the
-- byte-for-byte output of B04·P01's Python `canonical_json` and TypeScript
-- canonical serialiser for objects, arrays, and primitives stored in jsonb.

CREATE OR REPLACE FUNCTION audit.canonical_jsonb(p jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_temp
AS $fn$
DECLARE
  v_typeof  text;
  v_parts   text[] := ARRAY[]::text[];
  v_elem    jsonb;
  v_key     text;
  v_keys    text[];
BEGIN
  IF p IS NULL THEN
    RETURN 'null';
  END IF;
  v_typeof := jsonb_typeof(p);
  IF v_typeof = 'null'    THEN RETURN 'null'; END IF;
  IF v_typeof = 'boolean' THEN RETURN p::text; END IF;
  IF v_typeof = 'number'  THEN RETURN p::text; END IF;
  IF v_typeof = 'string'  THEN RETURN p::text; END IF; -- jsonb::text emits a properly-escaped JSON string
  IF v_typeof = 'array' THEN
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p) LOOP
      v_parts := v_parts || audit.canonical_jsonb(v_elem);
    END LOOP;
    RETURN '[' || array_to_string(v_parts, ',') || ']';
  END IF;
  IF v_typeof = 'object' THEN
    SELECT array_agg(k ORDER BY k) INTO v_keys
      FROM jsonb_object_keys(p) AS k;
    IF v_keys IS NULL THEN RETURN '{}'; END IF;
    FOREACH v_key IN ARRAY v_keys LOOP
      v_parts := v_parts || (to_jsonb(v_key)::text || ':' || audit.canonical_jsonb(p -> v_key));
    END LOOP;
    RETURN '{' || array_to_string(v_parts, ',') || '}';
  END IF;
  RAISE EXCEPTION 'canonical_jsonb: unsupported jsonb type %', v_typeof;
END;
$fn$;

-- ---- canonical_event_payload -------------------------------------------------
-- Sorted-keys canonical form for an audit event. Top-level keys:
--   action, actor (kind/role/session_id/system/user_id), after_state,
--   before_state, business_id, event_id, occurred_at (ISO 8601 UTC),
--   organization_id, reason, request_context, subject (id/type).

CREATE OR REPLACE FUNCTION audit.canonical_event_payload(
  p_event_id          bigint,
  p_occurred_at       timestamptz,
  p_actor_kind        audit.actor_kind_enum,
  p_actor_user_id     uuid,
  p_actor_role        public.user_role,
  p_actor_session_id  uuid,
  p_actor_system      text,
  p_organization_id   uuid,
  p_business_id       uuid,
  p_subject_type      audit.subject_type_enum,
  p_subject_id        uuid,
  p_action            text,
  p_before_state      jsonb,
  p_after_state       jsonb,
  p_reason            text,
  p_request_context   jsonb
) RETURNS text LANGUAGE plpgsql IMMUTABLE
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_iso         text;
  v_actor       text;
  v_subject     text;
BEGIN
  v_iso := to_char(p_occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');

  v_actor := '{' ||
    '"kind":'       || to_jsonb(p_actor_kind::text)::text || ',' ||
    '"role":'       || COALESCE(to_jsonb(p_actor_role::text)::text, 'null') || ',' ||
    '"session_id":' || COALESCE(to_jsonb(p_actor_session_id::text)::text, 'null') || ',' ||
    '"system":'     || COALESCE(to_jsonb(p_actor_system)::text, 'null') || ',' ||
    '"user_id":'    || COALESCE(to_jsonb(p_actor_user_id::text)::text, 'null') ||
    '}';

  v_subject := '{' ||
    '"id":'   || COALESCE(to_jsonb(p_subject_id::text)::text, 'null') || ',' ||
    '"type":' || to_jsonb(p_subject_type::text)::text ||
    '}';

  RETURN '{' ||
    '"action":'          || to_jsonb(p_action)::text || ',' ||
    '"actor":'           || v_actor || ',' ||
    '"after_state":'     || audit.canonical_jsonb(p_after_state) || ',' ||
    '"before_state":'    || audit.canonical_jsonb(p_before_state) || ',' ||
    '"business_id":'     || COALESCE(to_jsonb(p_business_id::text)::text, 'null') || ',' ||
    '"event_id":'        || p_event_id::text || ',' ||
    '"occurred_at":'     || to_jsonb(v_iso)::text || ',' ||
    '"organization_id":' || COALESCE(to_jsonb(p_organization_id::text)::text, 'null') || ',' ||
    '"reason":'          || COALESCE(to_jsonb(p_reason)::text, 'null') || ',' ||
    '"request_context":' || audit.canonical_jsonb(p_request_context) || ',' ||
    '"subject":'         || v_subject ||
    '}';
END;
$fn$;

-- ---- emit_audit (HOOK SWAP) --------------------------------------------------
-- Same 14-arg signature as B05·P02. Single INSERT into audit_events with the
-- hash chain already populated — no after-the-fact UPDATE, so the immutability
-- trigger stays clean. Atomic chain advance via FOR UPDATE row lock on
-- chain_heads inside the caller's transaction.

CREATE OR REPLACE FUNCTION audit.emit_audit(
  p_actor_kind        audit.actor_kind_enum,
  p_action            text,
  p_subject_type      audit.subject_type_enum,
  p_subject_id        uuid                  DEFAULT NULL,
  p_actor_user_id     uuid                  DEFAULT NULL,
  p_actor_role        public.user_role      DEFAULT NULL,
  p_actor_session_id  uuid                  DEFAULT NULL,
  p_actor_system      text                  DEFAULT NULL,
  p_organization_id   uuid                  DEFAULT NULL,
  p_business_id       uuid                  DEFAULT NULL,
  p_before_state      jsonb                 DEFAULT NULL,
  p_after_state       jsonb                 DEFAULT NULL,
  p_reason            text                  DEFAULT NULL,
  p_request_context   jsonb                 DEFAULT '{}'::jsonb
) RETURNS audit.audit_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_event_id      bigint;
  v_occurred_at   timestamptz := clock_timestamp();
  v_actor_system  text        := NULLIF(btrim(COALESCE(p_actor_system, '')), '');
  v_action        text        := btrim(p_action);
  v_req_ctx       jsonb       := COALESCE(p_request_context, '{}'::jsonb);
  v_chain_id      uuid;
  v_prev_hash     text;
  v_canonical     text;
  v_event_hash    text;
  v_row           audit.audit_events;
  SYSTEM_CHAIN_ID constant uuid := '00000000-0000-0000-0000-000000000000';
  GENESIS_HASH    constant text := repeat('0', 64);
BEGIN
  -- Validation (same as P02)
  IF p_action IS NULL OR length(btrim(p_action)) = 0 THEN
    RAISE EXCEPTION 'emit_audit: action is required' USING ERRCODE = '22000';
  END IF;
  IF p_actor_kind = 'USER' AND p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'emit_audit: USER actor requires actor_user_id' USING ERRCODE = '22000';
  END IF;
  IF p_actor_kind = 'SYSTEM' AND (p_actor_system IS NULL OR length(btrim(p_actor_system)) = 0) THEN
    RAISE EXCEPTION 'emit_audit: SYSTEM actor requires actor_system principal name' USING ERRCODE = '22000';
  END IF;

  -- 1. Allocate event_id from the monotonic sequence
  v_event_id := nextval('audit.audit_event_id_seq');

  -- 2. Resolve chain_id (org-keyed; nil-uuid system chain for org-less events)
  v_chain_id := COALESCE(p_organization_id, SYSTEM_CHAIN_ID);

  -- 3. Lock chain head (or seed at genesis if first event on this chain).
  --    Use INSERT … ON CONFLICT DO NOTHING then SELECT FOR UPDATE so that a
  --    concurrent emit on the same chain serializes on the row lock.
  INSERT INTO audit.chain_heads (
    chain_id, latest_event_id, latest_event_hash, latest_event_at, chain_started_at, updated_at
  ) VALUES (
    v_chain_id, 0, GENESIS_HASH, v_occurred_at, v_occurred_at, v_occurred_at
  )
  ON CONFLICT (chain_id) DO NOTHING;

  SELECT latest_event_hash INTO v_prev_hash
    FROM audit.chain_heads
   WHERE chain_id = v_chain_id
   FOR UPDATE;

  -- 4. Build canonical payload (sorted keys, RFC-8259-escaped)
  v_canonical := audit.canonical_event_payload(
    p_event_id        => v_event_id,
    p_occurred_at     => v_occurred_at,
    p_actor_kind      => p_actor_kind,
    p_actor_user_id   => p_actor_user_id,
    p_actor_role      => p_actor_role,
    p_actor_session_id=> p_actor_session_id,
    p_actor_system    => v_actor_system,
    p_organization_id => p_organization_id,
    p_business_id     => p_business_id,
    p_subject_type    => p_subject_type,
    p_subject_id      => p_subject_id,
    p_action          => v_action,
    p_before_state    => p_before_state,
    p_after_state     => p_after_state,
    p_reason          => p_reason,
    p_request_context => v_req_ctx
  );

  -- 5. Compute event_hash
  v_event_hash := public.hash_chain_append(v_prev_hash, v_canonical);

  -- 6. Single INSERT with prev_event_hash + event_hash already populated
  INSERT INTO audit.audit_events (
    event_id, occurred_at,
    actor_kind, actor_user_id, actor_role, actor_session_id, actor_system,
    organization_id, business_id,
    subject_type, subject_id,
    action, before_state, after_state, reason, request_context,
    prev_event_hash, event_hash
  ) VALUES (
    v_event_id, v_occurred_at,
    p_actor_kind, p_actor_user_id, p_actor_role, p_actor_session_id,
    v_actor_system,
    p_organization_id, p_business_id,
    p_subject_type, p_subject_id,
    v_action, p_before_state, p_after_state, p_reason, v_req_ctx,
    v_prev_hash, v_event_hash
  )
  RETURNING * INTO v_row;

  -- 7. Atomic chain head advance
  UPDATE audit.chain_heads SET
    latest_event_id   = v_event_id,
    latest_event_hash = v_event_hash,
    latest_event_at   = v_occurred_at,
    updated_at        = clock_timestamp()
  WHERE chain_id = v_chain_id;

  RETURN v_row;
END;
$fn$;

COMMENT ON FUNCTION audit.emit_audit(
  audit.actor_kind_enum, text, audit.subject_type_enum, uuid, uuid,
  public.user_role, uuid, text, uuid, uuid, jsonb, jsonb, text, jsonb
) IS
'B05·P03 hash-chained audit emission chokepoint. Same signature as B05·P02; populates prev_event_hash + event_hash via public.hash_chain_append over audit.canonical_event_payload(). Atomic chain advance via FOR UPDATE on audit.chain_heads inside caller transaction.';

-- ---- backfill the B05·P02 bootstrap row -------------------------------------
-- AUDIT_LOG_INITIALIZED (event_id=1) was inserted before the chain existed; it
-- has NULL prev_event_hash + event_hash. Compute its hash now and seed the
-- system chain head at that row.

DO $bf$
DECLARE
  v_row       audit.audit_events;
  v_canonical text;
  v_hash      text;
  GENESIS_HASH constant text := repeat('0', 64);
BEGIN
  SELECT * INTO v_row FROM audit.audit_events
    WHERE event_hash IS NULL ORDER BY event_id ASC LIMIT 1;
  IF NOT FOUND THEN
    RAISE NOTICE 'B05·P03 backfill: no unhashed bootstrap row found (already hashed or absent)';
    RETURN;
  END IF;

  v_canonical := audit.canonical_event_payload(
    p_event_id        => v_row.event_id,
    p_occurred_at     => v_row.occurred_at,
    p_actor_kind      => v_row.actor_kind,
    p_actor_user_id   => v_row.actor_user_id,
    p_actor_role      => v_row.actor_role,
    p_actor_session_id=> v_row.actor_session_id,
    p_actor_system    => v_row.actor_system,
    p_organization_id => v_row.organization_id,
    p_business_id     => v_row.business_id,
    p_subject_type    => v_row.subject_type,
    p_subject_id      => v_row.subject_id,
    p_action          => v_row.action,
    p_before_state    => v_row.before_state,
    p_after_state     => v_row.after_state,
    p_reason          => v_row.reason,
    p_request_context => v_row.request_context
  );
  v_hash := public.hash_chain_append(GENESIS_HASH, v_canonical);

  -- DDL-disable the immutability trigger for this single backfill update.
  -- (Same pattern complete_archive_run uses to mutate PENDING→COMPLETE.)
  ALTER TABLE audit.audit_events DISABLE TRIGGER trg_audit_events_block_update;
  UPDATE audit.audit_events
     SET prev_event_hash = GENESIS_HASH,
         event_hash      = v_hash
   WHERE id = v_row.id;
  ALTER TABLE audit.audit_events ENABLE TRIGGER trg_audit_events_block_update;

  -- Seed the system chain head (bootstrap event had organization_id = NULL).
  INSERT INTO audit.chain_heads (
    chain_id, latest_event_id, latest_event_hash, latest_event_at, chain_started_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000'::uuid,
    v_row.event_id, v_hash, v_row.occurred_at, v_row.occurred_at, clock_timestamp()
  )
  ON CONFLICT (chain_id) DO UPDATE SET
    latest_event_id   = EXCLUDED.latest_event_id,
    latest_event_hash = EXCLUDED.latest_event_hash,
    latest_event_at   = EXCLUDED.latest_event_at,
    updated_at        = clock_timestamp();
END
$bf$;

-- ---- checkpoint_chain --------------------------------------------------------
-- Anchors the current chain head into a third-party RFC 3161 timestamping
-- authority. SHIPPED with a deterministic PLACEHOLDER_LOCAL provider; the
-- real TSA HTTP submission lives in the API orchestrator (production cutover).
-- Failure path is the audit-then-raise hazard's Mitigation B — orchestrator
-- catches the exception and invokes audit.record_checkpoint_failure in a
-- fresh transaction so the failure audit persists.

CREATE OR REPLACE FUNCTION audit.checkpoint_chain(p_chain_id uuid)
RETURNS audit.chain_checkpoints
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_head        audit.chain_heads;
  v_token       bytea;
  v_provider    text := 'PLACEHOLDER_LOCAL';
  v_status      text := 'PLACEHOLDER_OK';
  v_checkpoint  audit.chain_checkpoints;
  SYSTEM_CHAIN_ID constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  SELECT * INTO v_head FROM audit.chain_heads WHERE chain_id = p_chain_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'checkpoint_chain: chain % does not exist', p_chain_id USING ERRCODE = 'P0002';
  END IF;

  -- Deterministic placeholder token (real TSA replies are opaque DER blobs).
  v_token := convert_to(
    format(
      '{"placeholder":true,"chain_id":"%s","event_hash":"%s","event_id":%s,"stamped_at":"%s"}',
      p_chain_id, v_head.latest_event_hash, v_head.latest_event_id, clock_timestamp()::text
    ),
    'UTF8'
  );

  INSERT INTO audit.chain_checkpoints (
    chain_id, event_id, event_hash, timestamp_token, tsa_provider, tsa_response_status
  ) VALUES (
    p_chain_id, v_head.latest_event_id, v_head.latest_event_hash,
    v_token, v_provider, v_status
  )
  RETURNING * INTO v_checkpoint;

  -- Emit success audit on the same chain (transactional coupling: if the TSA
  -- submission row INSERT failed, the audit row would roll back too).
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'CHAIN_CHECKPOINTED',
    p_subject_type => 'CHAIN_CHECKPOINT'::audit.subject_type_enum,
    p_subject_id   => v_checkpoint.id,
    p_actor_system => 'audit.checkpoint_chain',
    p_organization_id => CASE WHEN p_chain_id = SYSTEM_CHAIN_ID THEN NULL ELSE p_chain_id END,
    p_reason       => format('Checkpoint anchored via %s at event_id=%s', v_provider, v_head.latest_event_id),
    p_after_state  => jsonb_build_object(
      'checkpoint_id', v_checkpoint.id,
      'chain_id',      p_chain_id,
      'event_id',      v_head.latest_event_id,
      'event_hash',    v_head.latest_event_hash,
      'tsa_provider',  v_provider
    )
  );

  RETURN v_checkpoint;
END;
$fn$;

-- ---- record_checkpoint_failure ----------------------------------------------
-- Audit-only RPC for the API orchestrator to record a CHAIN_CHECKPOINT_FAILED
-- after catching a TSA-call exception. Should be called in a fresh transaction
-- so the failure audit persists (Mitigation B of the audit-then-raise hazard).

CREATE OR REPLACE FUNCTION audit.record_checkpoint_failure(
  p_chain_id              uuid,
  p_event_id_at_attempt   bigint,
  p_event_hash_at_attempt text,
  p_tsa_provider          text,
  p_error_class           text,
  p_error_detail          text
) RETURNS audit.audit_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_row audit.audit_events;
  SYSTEM_CHAIN_ID constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  v_row := audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'CHAIN_CHECKPOINT_FAILED',
    p_subject_type => 'CHAIN_HEAD'::audit.subject_type_enum,
    p_actor_system => 'audit.record_checkpoint_failure',
    p_organization_id => CASE WHEN p_chain_id = SYSTEM_CHAIN_ID THEN NULL ELSE p_chain_id END,
    p_reason       => format('TSA checkpoint failed: %s', p_error_class),
    p_after_state  => jsonb_build_object(
      'chain_id',     p_chain_id,
      'event_id',     p_event_id_at_attempt,
      'event_hash',   p_event_hash_at_attempt,
      'tsa_provider', p_tsa_provider,
      'error_class',  p_error_class,
      'error_detail', p_error_detail
    )
  );
  RETURN v_row;
END;
$fn$;

-- ---- _verify_chain_walk (internal) ------------------------------------------
-- Walks every event of a chain in event_id order, recomputing hashes and
-- cross-checking checkpoints. Returns the verification result jsonb; emits
-- no audit (the public-facing wrappers add the audit event with the right
-- action name).

CREATE OR REPLACE FUNCTION audit._verify_chain_walk(p_chain_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_rec               record;
  v_prev_hash         text := repeat('0', 64);
  v_canonical         text;
  v_recomputed        text;
  v_break_event_id    bigint := NULL;
  v_break_reason      text   := NULL;
  v_count             integer := 0;
  v_mismatched        jsonb := '[]'::jsonb;
  v_checkpoint        record;
  SYSTEM_CHAIN_ID constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  FOR v_rec IN
    SELECT * FROM audit.audit_events
     WHERE COALESCE(organization_id, SYSTEM_CHAIN_ID) = p_chain_id
     ORDER BY event_id ASC
  LOOP
    v_count := v_count + 1;
    v_canonical := audit.canonical_event_payload(
      p_event_id        => v_rec.event_id,
      p_occurred_at     => v_rec.occurred_at,
      p_actor_kind      => v_rec.actor_kind,
      p_actor_user_id   => v_rec.actor_user_id,
      p_actor_role      => v_rec.actor_role,
      p_actor_session_id=> v_rec.actor_session_id,
      p_actor_system    => v_rec.actor_system,
      p_organization_id => v_rec.organization_id,
      p_business_id     => v_rec.business_id,
      p_subject_type    => v_rec.subject_type,
      p_subject_id      => v_rec.subject_id,
      p_action          => v_rec.action,
      p_before_state    => v_rec.before_state,
      p_after_state     => v_rec.after_state,
      p_reason          => v_rec.reason,
      p_request_context => v_rec.request_context
    );
    v_recomputed := public.hash_chain_append(v_prev_hash, v_canonical);

    IF v_rec.prev_event_hash IS DISTINCT FROM v_prev_hash THEN
      v_break_event_id := v_rec.event_id;
      v_break_reason   := 'prev_event_hash_mismatch';
      EXIT;
    END IF;
    IF v_recomputed IS DISTINCT FROM v_rec.event_hash THEN
      v_break_event_id := v_rec.event_id;
      v_break_reason   := 'event_hash_mismatch';
      EXIT;
    END IF;
    v_prev_hash := v_rec.event_hash;
  END LOOP;

  -- Cross-check checkpoints (only when the event walk was clean)
  IF v_break_event_id IS NULL THEN
    FOR v_checkpoint IN
      SELECT cp.id          AS checkpoint_id,
             cp.event_id    AS checkpoint_event_id,
             cp.event_hash  AS stored_hash,
             ev.event_hash  AS actual_hash
        FROM audit.chain_checkpoints cp
        LEFT JOIN audit.audit_events ev ON ev.event_id = cp.event_id
       WHERE cp.chain_id = p_chain_id
       ORDER BY cp.event_id ASC
    LOOP
      IF v_checkpoint.stored_hash IS DISTINCT FROM v_checkpoint.actual_hash THEN
        v_mismatched := v_mismatched || jsonb_build_object(
          'checkpoint_id', v_checkpoint.checkpoint_id,
          'event_id',      v_checkpoint.checkpoint_event_id,
          'stored_hash',   v_checkpoint.stored_hash,
          'actual_hash',   v_checkpoint.actual_hash
        );
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'chain_id',               p_chain_id,
    'verified',               (v_break_event_id IS NULL AND jsonb_array_length(v_mismatched) = 0),
    'events_walked',          v_count,
    'break_at_event_id',      v_break_event_id,
    'break_reason',           v_break_reason,
    'mismatched_checkpoints', v_mismatched
  );
END;
$fn$;

-- ---- verify_chain ------------------------------------------------------------
-- Public-facing verification. Audit-before-return (no raise): always returns
-- the result jsonb, and emits CHAIN_VERIFIED or CHAIN_VERIFICATION_FAILED on
-- the chain itself so the verification act is recorded forensically.

CREATE OR REPLACE FUNCTION audit.verify_chain(p_chain_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_result jsonb;
  v_org_id uuid;
  SYSTEM_CHAIN_ID constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  v_result := audit._verify_chain_walk(p_chain_id);
  v_org_id := CASE WHEN p_chain_id = SYSTEM_CHAIN_ID THEN NULL ELSE p_chain_id END;

  IF (v_result->>'verified')::boolean THEN
    PERFORM audit.emit_audit(
      p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
      p_action          => 'CHAIN_VERIFIED',
      p_subject_type    => 'CHAIN_HEAD'::audit.subject_type_enum,
      p_actor_system    => 'audit.verify_chain',
      p_organization_id => v_org_id,
      p_reason          => format('chain %s verified across %s events', p_chain_id, v_result->>'events_walked'),
      p_after_state     => v_result
    );
  ELSE
    PERFORM audit.emit_audit(
      p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
      p_action          => 'CHAIN_VERIFICATION_FAILED',
      p_subject_type    => 'CHAIN_HEAD'::audit.subject_type_enum,
      p_actor_system    => 'audit.verify_chain',
      p_organization_id => v_org_id,
      p_reason          => format('chain %s verification failed', p_chain_id),
      p_after_state     => v_result
    );
  END IF;

  RETURN v_result;
END;
$fn$;

-- ---- verify_restored_chain ---------------------------------------------------
-- Post-restore verification. Same walk as verify_chain, but emits
-- CHAIN_RESTORED_AND_VERIFIED on success (vs CHAIN_VERIFIED). Called by the
-- backup-restore pipeline (Phase 08) before promoting restored data to
-- authoritative.

CREATE OR REPLACE FUNCTION audit.verify_restored_chain(p_chain_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_result jsonb;
  v_org_id uuid;
  SYSTEM_CHAIN_ID constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  v_result := audit._verify_chain_walk(p_chain_id);
  v_org_id := CASE WHEN p_chain_id = SYSTEM_CHAIN_ID THEN NULL ELSE p_chain_id END;

  IF (v_result->>'verified')::boolean THEN
    PERFORM audit.emit_audit(
      p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
      p_action          => 'CHAIN_RESTORED_AND_VERIFIED',
      p_subject_type    => 'CHAIN_HEAD'::audit.subject_type_enum,
      p_actor_system    => 'audit.verify_restored_chain',
      p_organization_id => v_org_id,
      p_reason          => format('chain %s restored + verified across %s events', p_chain_id, v_result->>'events_walked'),
      p_after_state     => v_result
    );
  ELSE
    PERFORM audit.emit_audit(
      p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
      p_action          => 'CHAIN_VERIFICATION_FAILED',
      p_subject_type    => 'CHAIN_HEAD'::audit.subject_type_enum,
      p_actor_system    => 'audit.verify_restored_chain',
      p_organization_id => v_org_id,
      p_reason          => format('restored chain %s verification failed', p_chain_id),
      p_after_state     => v_result
    );
  END IF;

  RETURN v_result;
END;
$fn$;

-- ---- current_chain_anchor ----------------------------------------------------
-- Resolves business → organization → chain head + latest at-or-before
-- checkpoint. Used by B04·P08's promotion pipeline to write the chain anchor
-- into the archive manifest at finalization time.

CREATE OR REPLACE FUNCTION audit.current_chain_anchor(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_org_id     uuid;
  v_head       audit.chain_heads;
  v_checkpoint audit.chain_checkpoints;
BEGIN
  SELECT organization_id INTO v_org_id
    FROM public.business_entities WHERE id = p_business_id;
  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'current_chain_anchor: business % not found', p_business_id USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_head FROM audit.chain_heads WHERE chain_id = v_org_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'chain_id',        v_org_id,
      'event_hash',      repeat('0', 64),
      'event_id',        0,
      'event_at',        NULL,
      'checkpointed_at', NULL,
      'tsa_provider',    NULL
    );
  END IF;

  SELECT * INTO v_checkpoint FROM audit.chain_checkpoints
   WHERE chain_id = v_org_id AND event_id <= v_head.latest_event_id
   ORDER BY event_id DESC, created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'chain_id',        v_org_id,
    'event_hash',      v_head.latest_event_hash,
    'event_id',        v_head.latest_event_id,
    'event_at',        v_head.latest_event_at,
    'checkpointed_at', v_checkpoint.created_at,
    'tsa_provider',    v_checkpoint.tsa_provider
  );
END;
$fn$;

-- ---- grants on RPCs ----------------------------------------------------------

REVOKE EXECUTE ON FUNCTION audit.canonical_jsonb(jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION audit.canonical_jsonb(jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION audit.canonical_event_payload(
  bigint, timestamptz, audit.actor_kind_enum, uuid, public.user_role, uuid, text,
  uuid, uuid, audit.subject_type_enum, uuid, text, jsonb, jsonb, text, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.canonical_event_payload(
  bigint, timestamptz, audit.actor_kind_enum, uuid, public.user_role, uuid, text,
  uuid, uuid, audit.subject_type_enum, uuid, text, jsonb, jsonb, text, jsonb
) TO service_role;

REVOKE EXECUTE ON FUNCTION audit.checkpoint_chain(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION audit.checkpoint_chain(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION audit.record_checkpoint_failure(uuid, bigint, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION audit.record_checkpoint_failure(uuid, bigint, text, text, text, text) TO service_role;

REVOKE EXECUTE ON FUNCTION audit._verify_chain_walk(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION audit._verify_chain_walk(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION audit.verify_chain(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION audit.verify_chain(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION audit.verify_restored_chain(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION audit.verify_restored_chain(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION audit.current_chain_anchor(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION audit.current_chain_anchor(uuid) TO authenticated, service_role;

-- ---- comments ----------------------------------------------------------------

COMMENT ON TABLE audit.chain_heads IS
'B05·P03: one row per hash chain. Default partition is per organization_id; the nil-uuid chain holds org-less events (pre-tenancy, bootstrap). Mutable — head advances on every emit_audit.';

COMMENT ON TABLE audit.chain_checkpoints IS
'B05·P03: append-only RFC 3161 timestamping checkpoints anchoring the chain head at a point in real-world time. SHIPPED with PLACEHOLDER_LOCAL provider; real TSA HTTP submission is wired in the API layer at production cutover.';

COMMENT ON FUNCTION audit.checkpoint_chain(uuid) IS
'B05·P03 checkpoint creation. PLACEHOLDER token while DB tests pass; real RFC 3161 HTTP submission wired at API layer (production cutover).';

COMMENT ON FUNCTION audit.verify_chain(uuid) IS
'B05·P03 chain integrity verification. Walks every event, recomputes hashes, cross-checks checkpoints. Audit-before-return — emits CHAIN_VERIFIED or CHAIN_VERIFICATION_FAILED then returns the result jsonb.';

COMMENT ON FUNCTION audit.verify_restored_chain(uuid) IS
'B05·P03 post-restore chain verification. Same walk as verify_chain; emits CHAIN_RESTORED_AND_VERIFIED on success.';

COMMENT ON FUNCTION audit.current_chain_anchor(uuid) IS
'B05·P03 chain anchor accessor. Resolves business_id → organization_id → chain head + latest at-or-before checkpoint. Read by B04·P08 promotion pipeline to seal archive manifests.';
