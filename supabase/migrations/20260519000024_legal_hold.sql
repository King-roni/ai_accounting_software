-- B04·P11 Legal Hold
-- ============================================================================
-- Per-business legal-hold flag wired into the retention engine. While ACTIVE,
-- the retention pass skips deletion for the business. Owner-only operation;
-- both set and lift require step-up MFA (B02·P06).
--
-- Hook swap: this migration REPLACEs archive.legal_hold_status (the
-- placeholder shipped by B04·P10) with the real implementation that reads
-- archive.legal_holds. No retention-engine code changes are required.
--
-- Storage Object Lock extension is the storage-platform layer's concern;
-- the DB emits LEGAL_HOLD_SET / LEGAL_HOLD_LIFTED audit events that the
-- platform worker consumes to extend / restore the lock retention window.
-- ============================================================================

-- ---- ENUM extensions ----------------------------------------------------

CREATE TYPE archive.legal_hold_status_enum AS ENUM ('ACTIVE','LIFTED');

ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'LEGAL_HOLD_SET';
ALTER TYPE archive.archive_event_type_enum ADD VALUE IF NOT EXISTS 'LEGAL_HOLD_LIFTED';

-- ---- legal_holds table --------------------------------------------------

CREATE TABLE archive.legal_holds (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  status          archive.legal_hold_status_enum NOT NULL DEFAULT 'ACTIVE',

  hold_reason     text NOT NULL,
  set_by          uuid NOT NULL REFERENCES public.users(id),
  set_at          timestamptz NOT NULL DEFAULT now(),

  lift_reason     text,
  lifted_by       uuid REFERENCES public.users(id),
  lifted_at       timestamptz,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT legal_holds_hold_reason_nonempty_chk CHECK (length(btrim(hold_reason)) > 0),
  CONSTRAINT legal_holds_lifted_consistency_chk CHECK (
    (status = 'ACTIVE' AND lift_reason IS NULL AND lifted_by IS NULL AND lifted_at IS NULL)
    OR (status = 'LIFTED' AND lift_reason IS NOT NULL AND length(btrim(lift_reason)) > 0
                          AND lifted_by IS NOT NULL AND lifted_at IS NOT NULL)
  )
);

CREATE INDEX idx_legal_holds_business_status   ON archive.legal_holds (business_id, status);
CREATE INDEX idx_legal_holds_organization      ON archive.legal_holds (organization_id);
CREATE INDEX idx_legal_holds_set_by            ON archive.legal_holds (set_by);
CREATE INDEX idx_legal_holds_lifted_by         ON archive.legal_holds (lifted_by) WHERE lifted_by IS NOT NULL;

-- At most one ACTIVE hold per business at a time.
CREATE UNIQUE INDEX idx_legal_holds_one_active_per_business
  ON archive.legal_holds (business_id)
  WHERE status = 'ACTIVE';

CREATE TRIGGER legal_holds_set_updated_at
  BEFORE UPDATE ON archive.legal_holds
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE archive.legal_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE archive.legal_holds FORCE  ROW LEVEL SECURITY;

CREATE POLICY legal_holds_select ON archive.legal_holds
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY legal_holds_no_insert ON archive.legal_holds
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY legal_holds_no_update ON archive.legal_holds
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY legal_holds_no_delete ON archive.legal_holds
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON archive.legal_holds TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON archive.legal_holds TO service_role;

-- ---- legal_hold_status: REPLACEs the B04·P10 placeholder ---------------

CREATE OR REPLACE FUNCTION archive.legal_hold_status(p_business_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
  WITH active AS (
    SELECT hold_reason
      FROM archive.legal_holds
     WHERE business_id = p_business_id AND status = 'ACTIVE'
  )
  SELECT jsonb_build_object(
    'on_hold',      EXISTS (SELECT 1 FROM active),
    'hold_reasons', COALESCE((SELECT jsonb_agg(hold_reason) FROM active), '[]'::jsonb)
  )
$fn$;
REVOKE EXECUTE ON FUNCTION archive.legal_hold_status(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.legal_hold_status(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION archive.legal_hold_status(uuid) IS
'B04·P11 real implementation (replaces B04·P10 placeholder). Reads archive.legal_holds for the business. Returns {on_hold, hold_reasons}. Called by the retention engine to decide skip-vs-delete.';

-- ---- set_legal_hold -----------------------------------------------------

CREATE OR REPLACE FUNCTION archive.set_legal_hold(
  p_business_id   uuid,
  p_hold_reason   text,
  p_step_up_token uuid
) RETURNS archive.legal_holds
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_org  uuid;
  v_role public.user_role;
  v_row  archive.legal_holds;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_hold_reason IS NULL OR length(btrim(p_hold_reason)) = 0 THEN
    RAISE EXCEPTION 'hold_reason must be non-empty' USING ERRCODE='22000';
  END IF;

  SELECT bur.role INTO v_role FROM public.business_user_roles bur
    WHERE bur.user_id = v_user AND bur.business_id = p_business_id AND bur.status = 'ACTIVE';
  IF v_role IS NULL OR v_role <> 'OWNER' THEN
    RAISE EXCEPTION 'role does not grant legal hold management (got %); OWNER only', v_role
      USING ERRCODE='42501';
  END IF;

  PERFORM public.consume_step_up_token(p_step_up_token, p_business_id, 'legal_hold_set', NULL);

  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;

  -- Partial UNIQUE index enforces at most one ACTIVE hold per business.
  -- A duplicate set attempt while one is ACTIVE will raise unique_violation.
  INSERT INTO archive.legal_holds (
    organization_id, business_id, status, hold_reason, set_by, set_at
  ) VALUES (
    v_org, p_business_id, 'ACTIVE', btrim(p_hold_reason), v_user, now()
  ) RETURNING * INTO v_row;

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, actor_user_id, payload
  ) VALUES (
    v_org, p_business_id, 'LEGAL_HOLD_SET', v_user,
    jsonb_build_object(
      'legal_hold_id', v_row.id,
      'hold_reason',   v_row.hold_reason,
      'set_at',        v_row.set_at
    )
  );

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.set_legal_hold(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.set_legal_hold(uuid, text, uuid) TO authenticated, service_role;

-- ---- lift_legal_hold ----------------------------------------------------

CREATE OR REPLACE FUNCTION archive.lift_legal_hold(
  p_legal_hold_id uuid,
  p_lift_reason   text,
  p_step_up_token uuid
) RETURNS archive.legal_holds
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_role public.user_role;
  v_row  archive.legal_holds;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_lift_reason IS NULL OR length(btrim(p_lift_reason)) = 0 THEN
    RAISE EXCEPTION 'lift_reason must be non-empty' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_row FROM archive.legal_holds WHERE id = p_legal_hold_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'legal hold % not found', p_legal_hold_id USING ERRCODE='P0002';
  END IF;
  IF v_row.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'legal hold % is not ACTIVE (got %)', p_legal_hold_id, v_row.status
      USING ERRCODE='22023';
  END IF;

  SELECT bur.role INTO v_role FROM public.business_user_roles bur
    WHERE bur.user_id = v_user AND bur.business_id = v_row.business_id AND bur.status = 'ACTIVE';
  IF v_role IS NULL OR v_role <> 'OWNER' THEN
    RAISE EXCEPTION 'role does not grant legal hold management (got %); OWNER only', v_role
      USING ERRCODE='42501';
  END IF;

  PERFORM public.consume_step_up_token(p_step_up_token, v_row.business_id, 'legal_hold_lift', NULL);

  UPDATE archive.legal_holds
     SET status      = 'LIFTED',
         lift_reason = btrim(p_lift_reason),
         lifted_by   = v_user,
         lifted_at   = now()
   WHERE id = p_legal_hold_id
  RETURNING * INTO v_row;

  INSERT INTO archive.archive_events (
    organization_id, business_id, event_type, actor_user_id, payload
  ) VALUES (
    v_row.organization_id, v_row.business_id, 'LEGAL_HOLD_LIFTED', v_user,
    jsonb_build_object(
      'legal_hold_id', v_row.id,
      'hold_reason',   v_row.hold_reason,
      'lift_reason',   v_row.lift_reason,
      'set_at',        v_row.set_at,
      'lifted_at',     v_row.lifted_at
    )
  );

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.lift_legal_hold(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.lift_legal_hold(uuid, text, uuid) TO authenticated, service_role;

COMMENT ON TABLE archive.legal_holds IS
'B04·P11 per-business legal hold (ACTIVE/LIFTED). At most one ACTIVE per business enforced by partial UNIQUE index. Reasons (set + lift) required and non-empty. RLS: SELECT for tenant; INSERT/UPDATE/DELETE blocked from authenticated — OWNER-only via DEFINER RPCs with step-up.';
COMMENT ON FUNCTION archive.set_legal_hold(uuid, text, uuid) IS
'B04·P11 set-hold (authenticated, OWNER only, step-up surface=legal_hold_set). Emits LEGAL_HOLD_SET. Partial UNIQUE catches double-set as 23505.';
COMMENT ON FUNCTION archive.lift_legal_hold(uuid, text, uuid) IS
'B04·P11 lift-hold (authenticated, OWNER only, step-up surface=legal_hold_lift). Transitions ACTIVE -> LIFTED and emits LEGAL_HOLD_LIFTED.';
