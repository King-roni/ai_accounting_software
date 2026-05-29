-- B05·P02 Audit Log Schema & Emission API
-- ============================================================================
-- The system-wide audit log. Every other block emits audited events through
-- the single chokepoint RPC audit.emit_audit(...), which writes to
-- audit.audit_events inside the SAME transaction as the state change being
-- audited (transactional coupling — both commit or neither does).
--
-- This phase ships:
--   * audit schema + ENUMs (actor_kind, subject_type)
--   * audit.audit_events with full column set per the spec
--   * monotonic event_id sequence (Phase 03 will partition per chain)
--   * RLS: SELECT tenant + role; INSERT/UPDATE/DELETE blocked from
--     authenticated; UPDATE forbidden across roles via an immutability
--     trigger (Principle 4 non-negotiable from Block 01)
--   * audit.emit_audit RPC — the single chokepoint
--   * audit.record_forensic_query RPC — emits AUDIT_LOG_QUERIED meta-event
--   * Indexes for the four canonical query shapes
--
-- prev_event_hash / event_hash columns are present but NULL — Phase 03
-- (audit log tamper resistance) wires the hash chain.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS audit;

-- ---- ENUMs ---------------------------------------------------------------

CREATE TYPE audit.actor_kind_enum AS ENUM ('USER','SYSTEM');

CREATE TYPE audit.subject_type_enum AS ENUM (
  'WORKFLOW_RUN',
  'TRANSACTION',
  'DOCUMENT',
  'MATCH_RECORD',
  'DRAFT_LEDGER_ENTRY',
  'REVIEW_ISSUE',
  'STATEMENT_UPLOAD',
  'RAW_UPLOAD_FILE',
  'PROCESSING_ARTIFACT',
  'EVIDENCE_PDF',
  'BANK_ACCOUNT',
  'ARCHIVE_RUN',
  'LEGAL_HOLD',
  'RETENTION_POLICY',
  'BUSINESS',
  'ORGANIZATION',
  'USER',
  'ORGANIZATION_INVITATION',
  'BUSINESS_USER_ROLE',
  'BUSINESS_INTEGRATION',
  'DRIVE_FOLDER_MAPPING',
  'STEP_UP_TOKEN',
  'MFA_FACTOR',
  'MFA_RECOVERY_CODE',
  'SESSION',
  'AUDIT_QUERY'
);

-- ---- sequence -----------------------------------------------------------
-- Globally monotonic in Phase 02. Phase 03 will partition per hash chain.

CREATE SEQUENCE audit.audit_event_id_seq
  AS bigint
  START WITH 1
  INCREMENT BY 1
  MINVALUE 1
  NO CYCLE;

-- ---- audit_events -------------------------------------------------------

CREATE TABLE audit.audit_events (
  id                 uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  event_id           bigint NOT NULL DEFAULT nextval('audit.audit_event_id_seq'),

  -- sub-millisecond precision: timestamptz already gives microseconds;
  -- clock_timestamp() so each row in a single transaction gets a distinct
  -- wall-clock timestamp.
  occurred_at        timestamptz NOT NULL DEFAULT clock_timestamp(),

  -- actor
  actor_kind         audit.actor_kind_enum NOT NULL,
  actor_user_id      uuid REFERENCES public.users(id),
  actor_role         public.user_role,
  actor_session_id   uuid,
  actor_system       text,

  -- tenancy (NULL allowed for pre-tenancy events like login attempts)
  organization_id    uuid REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id        uuid REFERENCES public.business_entities(id) ON DELETE RESTRICT,

  -- subject
  subject_type       audit.subject_type_enum NOT NULL,
  subject_id         uuid,

  -- action: free-form text constrained to DOMAIN_PAST_VERB naming convention
  -- (uppercase, underscore-separated; ≥ 4 chars). The canonical catalogue
  -- lives in the Stage 4 audit-event-taxonomy sub-doc.
  action             text NOT NULL,

  before_state       jsonb,
  after_state        jsonb,
  reason             text,
  request_context    jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Phase 03 will populate these.
  prev_event_hash    text,
  event_hash         text,

  created_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT audit_events_actor_kind_chk CHECK (
    (actor_kind = 'USER'   AND actor_user_id IS NOT NULL AND actor_system IS NULL)
    OR (actor_kind = 'SYSTEM' AND actor_user_id IS NULL  AND actor_system IS NOT NULL)
  ),
  CONSTRAINT audit_events_action_format_chk CHECK (
    action ~ '^[A-Z][A-Z0-9_]{3,}$'
  ),
  CONSTRAINT audit_events_event_hash_format_chk CHECK (
    event_hash IS NULL OR event_hash ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT audit_events_prev_event_hash_format_chk CHECK (
    prev_event_hash IS NULL OR prev_event_hash ~ '^[0-9a-f]{64}$'
  )
);

-- The four canonical query shapes per spec, plus useful composites.
CREATE INDEX idx_audit_events_business_occurred
  ON audit.audit_events (organization_id, business_id, occurred_at DESC);
CREATE INDEX idx_audit_events_actor_user_occurred
  ON audit.audit_events (actor_user_id, occurred_at DESC)
  WHERE actor_user_id IS NOT NULL;
CREATE INDEX idx_audit_events_subject_occurred
  ON audit.audit_events (subject_type, subject_id, occurred_at DESC);
CREATE INDEX idx_audit_events_action_occurred
  ON audit.audit_events (action, occurred_at DESC);
CREATE UNIQUE INDEX idx_audit_events_event_id
  ON audit.audit_events (event_id);
-- FK-cover indexes (org/biz)
CREATE INDEX idx_audit_events_org      ON audit.audit_events (organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX idx_audit_events_biz      ON audit.audit_events (business_id)     WHERE business_id IS NOT NULL;

-- ---- immutability + delete guard ---------------------------------------

CREATE OR REPLACE FUNCTION audit.fn_block_update()
RETURNS trigger LANGUAGE plpgsql
SET search_path = audit, public, pg_temp
AS $fn$
BEGIN
  RAISE EXCEPTION 'audit_events rows are immutable (table %.%)', TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = '42501';
END;
$fn$;

CREATE OR REPLACE FUNCTION audit.fn_guard_delete()
RETURNS trigger LANGUAGE plpgsql
SET search_path = audit, public, pg_temp
AS $fn$
BEGIN
  -- Retention process (Block 05 future phase) sets audit.allow_delete = 'on'
  -- session-locally. Any other DELETE attempt aborts.
  IF COALESCE(current_setting('audit.allow_delete', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'audit_events deletes are forbidden via application paths (retention process only)'
      USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$fn$;

CREATE TRIGGER trg_audit_events_block_update
  BEFORE UPDATE ON audit.audit_events
  FOR EACH ROW EXECUTE FUNCTION audit.fn_block_update();

CREATE TRIGGER trg_audit_events_guard_delete
  BEFORE DELETE ON audit.audit_events
  FOR EACH ROW EXECUTE FUNCTION audit.fn_guard_delete();

-- ---- RLS ----------------------------------------------------------------

ALTER TABLE audit.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.audit_events FORCE  ROW LEVEL SECURITY;

-- SELECT: tenant + role. NULL-org events (e.g., LOGIN_FAILED before tenancy
-- resolution) are visible only to OWNER/ADMIN of any org they belong to —
-- handled by a permissive "owner-or-admin-sees-org-less" sub-policy.
CREATE POLICY audit_events_select_tenant ON audit.audit_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id IS NOT NULL
    AND organization_id = public.current_org()
    AND (business_id IS NULL OR business_id = ANY(public.current_user_businesses()))
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.organization_id = audit.audit_events.organization_id
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN','ACCOUNTANT','REVIEWER','READ_ONLY','BOOKKEEPER')
    )
  );

CREATE POLICY audit_events_select_orgless_owners ON audit.audit_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id IS NULL  -- pre-tenancy events
    AND EXISTS (
      SELECT 1 FROM public.business_user_roles bur
      JOIN public.users u ON u.id = bur.user_id
      WHERE u.auth_user_id = auth.uid()
        AND bur.status = 'ACTIVE'
        AND bur.role IN ('OWNER','ADMIN')
    )
  );

CREATE POLICY audit_events_no_insert ON audit.audit_events
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY audit_events_no_update ON audit.audit_events
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY audit_events_no_delete ON audit.audit_events
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- schema grants ------------------------------------------------------

GRANT USAGE ON SCHEMA audit TO authenticated, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO authenticated;
GRANT SELECT, INSERT, DELETE ON ALL TABLES IN SCHEMA audit TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT, INSERT, DELETE ON TABLES TO service_role;

-- ---- emit_audit RPC -----------------------------------------------------
-- The single chokepoint. Other blocks ALWAYS invoke this rather than
-- inserting directly. Transactional coupling: if the caller's transaction
-- aborts, this insert rolls back with it (Phase 02 DoD).

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
  v_row    audit.audit_events;
BEGIN
  -- Required fields
  IF p_action IS NULL OR length(btrim(p_action)) = 0 THEN
    RAISE EXCEPTION 'emit_audit: action is required' USING ERRCODE = '22000';
  END IF;
  IF p_actor_kind = 'USER' AND p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'emit_audit: USER actor requires actor_user_id' USING ERRCODE = '22000';
  END IF;
  IF p_actor_kind = 'SYSTEM' AND (p_actor_system IS NULL OR length(btrim(p_actor_system)) = 0) THEN
    RAISE EXCEPTION 'emit_audit: SYSTEM actor requires actor_system principal name' USING ERRCODE = '22000';
  END IF;

  INSERT INTO audit.audit_events (
    actor_kind, actor_user_id, actor_role, actor_session_id, actor_system,
    organization_id, business_id,
    subject_type, subject_id,
    action, before_state, after_state, reason, request_context
  ) VALUES (
    p_actor_kind, p_actor_user_id, p_actor_role, p_actor_session_id,
    NULLIF(btrim(COALESCE(p_actor_system, '')), ''),
    p_organization_id, p_business_id,
    p_subject_type, p_subject_id,
    btrim(p_action), p_before_state, p_after_state, p_reason,
    COALESCE(p_request_context, '{}'::jsonb)
  )
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION audit.emit_audit(
  audit.actor_kind_enum, text, audit.subject_type_enum, uuid, uuid,
  public.user_role, uuid, text, uuid, uuid, jsonb, jsonb, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION audit.emit_audit(
  audit.actor_kind_enum, text, audit.subject_type_enum, uuid, uuid,
  public.user_role, uuid, text, uuid, uuid, jsonb, jsonb, text, jsonb
) TO service_role;

COMMENT ON FUNCTION audit.emit_audit(
  audit.actor_kind_enum, text, audit.subject_type_enum, uuid, uuid,
  public.user_role, uuid, text, uuid, uuid, jsonb, jsonb, text, jsonb
) IS
'B05·P02 audit emission chokepoint. Service-role only. Must be called inside the same transaction as the state change being audited so transactional coupling holds.';

-- ---- record_forensic_query (meta-audit) --------------------------------

CREATE OR REPLACE FUNCTION audit.record_forensic_query(
  p_query_description text,
  p_filters           jsonb DEFAULT '{}'::jsonb,
  p_request_context   jsonb DEFAULT '{}'::jsonb
) RETURNS audit.audit_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_user  uuid := public.current_user_id();
  v_org   uuid := public.current_org();
  v_row   audit.audit_events;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;

  v_row := audit.emit_audit(
    p_actor_kind      => 'USER',
    p_action          => 'AUDIT_LOG_QUERIED',
    p_subject_type    => 'AUDIT_QUERY',
    p_subject_id      => NULL,
    p_actor_user_id   => v_user,
    p_organization_id => v_org,
    p_reason          => p_query_description,
    p_request_context => p_request_context,
    p_after_state     => jsonb_build_object('filters', p_filters)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION audit.record_forensic_query(text, jsonb, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION audit.record_forensic_query(text, jsonb, jsonb) TO authenticated, service_role;

-- ---- bootstrap meta-event ----------------------------------------------

INSERT INTO audit.audit_events (
  actor_kind, actor_system,
  subject_type, action, reason
) VALUES (
  'SYSTEM', 'b05p02-migration',
  'AUDIT_QUERY', 'AUDIT_LOG_INITIALIZED',
  'audit schema + audit_events + emit_audit RPC online'
);

COMMENT ON SCHEMA audit IS
'B05·P02 audit log. audit_events is the system-wide forensic event store. INSERT only via audit.emit_audit (service_role); UPDATE forbidden by trigger; DELETE gated by retention session var (Block 05 future phase).';
COMMENT ON TABLE audit.audit_events IS
'B05·P02: one row per audited event. event_id monotonic via audit.audit_event_id_seq. prev_event_hash + event_hash are placeholders; Phase 03 wires the hash chain.';
