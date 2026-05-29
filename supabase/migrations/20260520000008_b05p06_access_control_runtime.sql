-- B05·P06 Access Control Runtime
-- ============================================================================
-- The DB-side enforcement chokepoint that wraps every protected operation.
-- Block 02 owns the *decision* (`public.can_perform`); Block 05 owns the
-- *enforcement* (`auth_runtime.check_access`) — the runtime that calls
-- can_perform, processes ALLOW/DENY/STEP_UP, checks `mfa_recent_at` against
-- the validity window, and emits the right audit event for every outcome.
--
-- HOOK-SWAP: `public.can_perform` ships here as a permissive PLACEHOLDER that
-- always returns {decision: ALLOW} (with session-var test hooks for forced
-- DENY/STEP_UP/RAISE during lifecycle tests). When B02·P04 ships, it will
-- CREATE OR REPLACE this function with real role+permission logic — same
-- signature, callers unchanged.
--
-- Similarly: `public.users.mfa_recent_at` is added here as a NULL placeholder
-- column. B02·P06's MFA flow will populate it on every successful MFA challenge.
-- ============================================================================

-- ---- subject_type extension --------------------------------------------------
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'ACCESS_DECISION';

-- ---- schema + decision enum --------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth_runtime;

CREATE TYPE auth_runtime.access_decision_enum AS ENUM ('ALLOW','DENY','STEP_UP');

-- ---- sensitive_surfaces lookup ----------------------------------------------
-- The canonical list of surfaces that emit ACCESS_ALLOWED on success (per
-- spec). Non-sensitive surfaces emit ACCESS_ALLOWED audit only as needed by
-- the caller; the runtime stays silent on routine ALLOW decisions.

CREATE TABLE auth_runtime.sensitive_surfaces (
  surface         text PRIMARY KEY,
  step_up_window  interval NOT NULL DEFAULT '5 minutes'::interval,
  description     text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sensitive_surfaces_window_positive_chk CHECK (step_up_window > '0'::interval)
);

INSERT INTO auth_runtime.sensitive_surfaces (surface, step_up_window, description) VALUES
  ('FINALIZATION',           '5 minutes',  'Workflow finalization → archive promotion (B04·P08)'),
  ('USER_MANAGEMENT',        '5 minutes',  'Invite, role change, deactivate (B02·P02)'),
  ('INTEGRATION_DISCONNECT', '5 minutes',  'Disconnect external OAuth integration (B02·P08)'),
  ('ARCHIVE_EXPORT',         '5 minutes',  'Export finalized archive bundle (B04·P07)'),
  ('ROLE_ESCALATION',        '5 minutes',  'Elevate user role (B02·P04)'),
  ('SECRETS_ROTATION',       '5 minutes',  'Rotate secrets / API keys (B05·P07)'),
  ('KEK_ROTATION',           '5 minutes',  'Rotate organization KEK (B05·P04)'),
  ('DEK_ROTATION',           '5 minutes',  'Rotate business DEK (B05·P04)'),
  ('KEY_DESTRUCTION',        '60 seconds', 'Cryptographic erasure of DEK (B05·P04) — tighter window'),
  ('DECRYPT_AT_USE',         '5 minutes',  'Decrypt-at-use API for sensitive fields (B05·P05)');

GRANT SELECT ON auth_runtime.sensitive_surfaces TO authenticated, service_role;

-- ---- mfa_recent_at placeholder on users -------------------------------------
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS mfa_recent_at timestamptz;

COMMENT ON COLUMN public.users.mfa_recent_at IS
'B05·P06 placeholder. B02·P06 MFA flow will populate on every successful MFA challenge. auth_runtime.check_access compares against per-surface step_up_window.';

-- ---- PLACEHOLDER public.can_perform -----------------------------------------
-- Hook-swap target: B02·P04 will CREATE OR REPLACE with real role+permission
-- decision logic. Same signature, callers unchanged.
--
-- Placeholder behavior:
--   default → {decision: 'ALLOW'}
--   test.can_perform_should_raise = 'on'  → RAISE EXCEPTION
--   test.can_perform_decision = 'DENY'    → {decision:'DENY', reason_code, cross_tenant?}
--   test.can_perform_decision = 'STEP_UP' → {decision:'STEP_UP', step_up_surface}
--   test.can_perform_decision = 'ALLOW'   → {decision:'ALLOW'} (explicit)

CREATE OR REPLACE FUNCTION public.can_perform(
  p_actor_user_id   uuid,
  p_surface         text,
  p_action          text,
  p_resource        jsonb,
  p_business_id     uuid DEFAULT NULL,
  p_organization_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_decision_override text;
  v_should_raise      text;
  v_cross_tenant      text;
  v_reason_code       text;
BEGIN
  v_should_raise := COALESCE(current_setting('test.can_perform_should_raise', true), 'off');
  IF v_should_raise = 'on' THEN
    RAISE EXCEPTION 'can_perform: simulated decision-function bug (test hook)' USING ERRCODE = 'P0001';
  END IF;

  v_decision_override := COALESCE(current_setting('test.can_perform_decision', true), '');

  IF v_decision_override = 'DENY' THEN
    v_cross_tenant := COALESCE(current_setting('test.can_perform_cross_tenant', true), 'false');
    v_reason_code  := COALESCE(NULLIF(current_setting('test.can_perform_reason', true), ''), 'denied_by_test');
    RETURN jsonb_build_object(
      'decision',     'DENY',
      'reason_code',  v_reason_code,
      'cross_tenant', (v_cross_tenant = 'true')
    );
  END IF;

  IF v_decision_override = 'STEP_UP' THEN
    RETURN jsonb_build_object(
      'decision',        'STEP_UP',
      'step_up_surface', p_surface
    );
  END IF;

  -- Default placeholder: ALLOW. B02·P04 will swap this body with real
  -- role+permission decision logic. Callers don't change.
  RETURN jsonb_build_object('decision', 'ALLOW');
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.can_perform(uuid, text, text, jsonb, uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.can_perform(uuid, text, text, jsonb, uuid, uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.can_perform(uuid, text, text, jsonb, uuid, uuid) IS
'B05·P06 PLACEHOLDER. B02·P04 will CREATE OR REPLACE with real role+permission decision logic via hook-swap. Signature stable. Currently returns {decision:ALLOW} for all; consults session vars test.can_perform_decision / test.can_perform_should_raise for lifecycle tests.';

-- ---- is_sensitive_surface helper --------------------------------------------
CREATE OR REPLACE FUNCTION auth_runtime.is_sensitive_surface(p_surface text)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = auth_runtime, pg_temp
AS $fn$
  SELECT EXISTS (SELECT 1 FROM auth_runtime.sensitive_surfaces WHERE surface = p_surface);
$fn$;

GRANT EXECUTE ON FUNCTION auth_runtime.is_sensitive_surface(text) TO authenticated, service_role;

-- ---- auth_runtime.check_access (THE CHOKEPOINT) -----------------------------
-- Returns jsonb envelope. Mitigation A throughout — no RAISE on runtime
-- denial; always emit + return. Wraps can_perform in EXCEPTION trap so a
-- broken decision function produces ACCESS_DECISION_THREW + CRITICAL alert
-- instead of crashing the caller.

CREATE OR REPLACE FUNCTION auth_runtime.check_access(
  p_actor_user_id   uuid,
  p_surface         text,
  p_action          text,
  p_resource        jsonb,
  p_business_id     uuid DEFAULT NULL,
  p_organization_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = auth_runtime, public, audit, pg_temp
AS $fn$
DECLARE
  v_decision_jsonb       jsonb;
  v_decision             text;
  v_is_sensitive         boolean;
  v_step_up_window       interval;
  v_mfa_recent_at        timestamptz;
  v_reason_code          text;
  v_cross_tenant         boolean := false;
  v_resource_fingerprint text;
  v_canonical            text;
  v_err_state            text;
  v_err_msg              text;
BEGIN
  -- Validation (programming errors → RAISE; no audit)
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'check_access: actor_user_id is required' USING ERRCODE = '22000';
  END IF;
  IF p_surface IS NULL OR length(btrim(p_surface)) = 0 THEN
    RAISE EXCEPTION 'check_access: surface is required' USING ERRCODE = '22000';
  END IF;
  IF p_action IS NULL OR length(btrim(p_action)) = 0 THEN
    RAISE EXCEPTION 'check_access: action is required' USING ERRCODE = '22000';
  END IF;

  -- Resource fingerprint: SHA-256 of canonical JSON form. Avoids embedding
  -- potentially-sensitive resource details in the audit payload while still
  -- enabling forensic correlation against the request log.
  v_canonical := audit.canonical_jsonb(COALESCE(p_resource, '{}'::jsonb));
  v_resource_fingerprint := public.hash_text_sha256(v_canonical);
  v_is_sensitive := auth_runtime.is_sensitive_surface(p_surface);

  -- Wrap can_perform in EXCEPTION trap so a broken decision function audits
  -- ACCESS_DECISION_THREW + denies the operation instead of crashing the caller.
  BEGIN
    v_decision_jsonb := public.can_perform(
      p_actor_user_id, p_surface, p_action,
      COALESCE(p_resource, '{}'::jsonb),
      p_business_id, p_organization_id
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_state = RETURNED_SQLSTATE, v_err_msg = MESSAGE_TEXT;
    PERFORM audit.emit_audit(
      p_actor_kind      => 'USER'::audit.actor_kind_enum,
      p_action          => 'ACCESS_DECISION_THREW',
      p_subject_type    => 'ACCESS_DECISION'::audit.subject_type_enum,
      p_actor_user_id   => p_actor_user_id,
      p_organization_id => p_organization_id,
      p_business_id     => p_business_id,
      p_reason          => format('can_perform threw: %s', v_err_msg),
      p_after_state     => jsonb_build_object(
        'surface',              p_surface,
        'action',               p_action,
        'resource_fingerprint', v_resource_fingerprint,
        'error_class',          v_err_state,
        'error_message',        v_err_msg,
        'alert',                'CRITICAL'
      )
    );
    RETURN jsonb_build_object(
      'decision',    'DENY',
      'reason_code', 'decision_threw',
      'alert',       'CRITICAL'
    );
  END;

  v_decision := v_decision_jsonb->>'decision';

  -- ALLOW branch
  IF v_decision = 'ALLOW' THEN
    IF v_is_sensitive THEN
      PERFORM audit.emit_audit(
        p_actor_kind      => 'USER'::audit.actor_kind_enum,
        p_action          => 'ACCESS_ALLOWED',
        p_subject_type    => 'ACCESS_DECISION'::audit.subject_type_enum,
        p_actor_user_id   => p_actor_user_id,
        p_organization_id => p_organization_id,
        p_business_id     => p_business_id,
        p_reason          => format('%s/%s allowed', p_surface, p_action),
        p_after_state     => jsonb_build_object(
          'surface',              p_surface,
          'action',               p_action,
          'resource_fingerprint', v_resource_fingerprint,
          'sensitive',            true
        )
      );
    END IF;
    RETURN jsonb_build_object('decision', 'ALLOW');
  END IF;

  -- DENY branch
  IF v_decision = 'DENY' THEN
    v_reason_code  := COALESCE(v_decision_jsonb->>'reason_code', 'denied');
    v_cross_tenant := COALESCE((v_decision_jsonb->>'cross_tenant')::boolean, false);
    PERFORM audit.emit_audit(
      p_actor_kind      => 'USER'::audit.actor_kind_enum,
      p_action          => 'ACCESS_DENIED',
      p_subject_type    => 'ACCESS_DECISION'::audit.subject_type_enum,
      p_actor_user_id   => p_actor_user_id,
      p_organization_id => p_organization_id,
      p_business_id     => p_business_id,
      p_reason          => format('%s/%s denied: %s', p_surface, p_action, v_reason_code),
      p_after_state     => jsonb_build_object(
        'surface',              p_surface,
        'action',               p_action,
        'resource_fingerprint', v_resource_fingerprint,
        'reason_code',          v_reason_code,
        'cross_tenant',         v_cross_tenant
      )
    );
    RETURN jsonb_build_object(
      'decision',     'DENY',
      'reason_code',  v_reason_code,
      'cross_tenant', v_cross_tenant
    );
  END IF;

  -- STEP_UP / REQUIRE_STEP_UP branch
  IF v_decision IN ('STEP_UP', 'REQUIRE_STEP_UP') THEN
    SELECT step_up_window INTO v_step_up_window
      FROM auth_runtime.sensitive_surfaces WHERE surface = p_surface;
    IF v_step_up_window IS NULL THEN
      v_step_up_window := '5 minutes'::interval;  -- default for non-sensitive surfaces that opt in
    END IF;

    SELECT mfa_recent_at INTO v_mfa_recent_at FROM public.users WHERE id = p_actor_user_id;

    IF v_mfa_recent_at IS NOT NULL AND (now() - v_mfa_recent_at) <= v_step_up_window THEN
      -- Recent MFA — treat as ALLOW
      IF v_is_sensitive THEN
        PERFORM audit.emit_audit(
          p_actor_kind      => 'USER'::audit.actor_kind_enum,
          p_action          => 'ACCESS_ALLOWED',
          p_subject_type    => 'ACCESS_DECISION'::audit.subject_type_enum,
          p_actor_user_id   => p_actor_user_id,
          p_organization_id => p_organization_id,
          p_business_id     => p_business_id,
          p_reason          => format('%s/%s allowed via recent MFA', p_surface, p_action),
          p_after_state     => jsonb_build_object(
            'surface',              p_surface,
            'action',               p_action,
            'resource_fingerprint', v_resource_fingerprint,
            'via',                  'recent_mfa',
            'sensitive',            true
          )
        );
      END IF;
      RETURN jsonb_build_object('decision', 'ALLOW', 'via', 'recent_mfa');
    END IF;

    -- Stale MFA → step-up required
    PERFORM audit.emit_audit(
      p_actor_kind      => 'USER'::audit.actor_kind_enum,
      p_action          => 'ACCESS_STEP_UP_TRIGGERED',
      p_subject_type    => 'ACCESS_DECISION'::audit.subject_type_enum,
      p_actor_user_id   => p_actor_user_id,
      p_organization_id => p_organization_id,
      p_business_id     => p_business_id,
      p_reason          => format('%s/%s requires step-up', p_surface, p_action),
      p_after_state     => jsonb_build_object(
        'surface',                p_surface,
        'action',                 p_action,
        'resource_fingerprint',   v_resource_fingerprint,
        'step_up_window_seconds', extract(epoch from v_step_up_window)::int
      )
    );
    RETURN jsonb_build_object(
      'decision',               'STEP_UP',
      'step_up_surface',        p_surface,
      'step_up_window_seconds', extract(epoch from v_step_up_window)::int
    );
  END IF;

  -- Unknown decision shape → defensive DENY (never accept unknown verdict)
  PERFORM audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'ACCESS_DENIED',
    p_subject_type    => 'ACCESS_DECISION'::audit.subject_type_enum,
    p_actor_user_id   => p_actor_user_id,
    p_organization_id => p_organization_id,
    p_business_id     => p_business_id,
    p_reason          => format('unknown decision from can_perform: %s', v_decision),
    p_after_state     => jsonb_build_object(
      'surface',              p_surface,
      'action',               p_action,
      'resource_fingerprint', v_resource_fingerprint,
      'reason_code',          'unknown_decision',
      'raw_decision',         v_decision_jsonb
    )
  );
  RETURN jsonb_build_object('decision', 'DENY', 'reason_code', 'unknown_decision');
END;
$fn$;

-- SERVICE_ROLE ONLY — authenticated revoked 2026-05-21 (F1 audit fix):
-- function trusts p_actor_user_id parameter; authenticated invocation would
-- allow impersonation + info disclosure. API-layer withAccessControl holds
-- the verified principal and calls via service_role.
REVOKE EXECUTE ON FUNCTION auth_runtime.check_access(uuid, text, text, jsonb, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION auth_runtime.check_access(uuid, text, text, jsonb, uuid, uuid) TO service_role;

COMMENT ON FUNCTION auth_runtime.check_access(uuid, text, text, jsonb, uuid, uuid) IS
'B05·P06 access control chokepoint. Returns jsonb envelope {decision, reason_code?, cross_tenant?, step_up_surface?, alert?}. Wraps public.can_perform in EXCEPTION trap (ACCESS_DECISION_THREW → DENY + CRITICAL alert). Emits ACCESS_ALLOWED only for sensitive surfaces. Recent MFA bypass for STEP_UP per per-surface step_up_window. SERVICE_ROLE ONLY — authenticated revoked 2026-05-21 (F1 audit fix): trusts p_actor_user_id parameter so authenticated invocation would allow impersonation + info disclosure.';

-- ---- bootstrap audit event --------------------------------------------------
DO $bootstrap$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'VAULT_INITIALIZED',
    p_subject_type => 'AUDIT_QUERY'::audit.subject_type_enum,
    p_actor_system => 'b05p06-migration',
    p_reason       => 'access control runtime online — auth_runtime.check_access + public.can_perform PLACEHOLDER + 10 sensitive surfaces + users.mfa_recent_at column'
  );
END
$bootstrap$;

COMMENT ON SCHEMA auth_runtime IS
'B05·P06 access control runtime. check_access is the DB-side enforcement chokepoint that wraps public.can_perform decisions and emits audit events for every outcome.';

COMMENT ON TABLE auth_runtime.sensitive_surfaces IS
'B05·P06 canonical list of surfaces that emit ACCESS_ALLOWED on success + per-surface step_up_window override. KEY_DESTRUCTION uses a tighter 60s window per spec sub-doc.';
