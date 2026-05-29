-- B05 cross-phase audit fix F1 (2026-05-21)
-- ============================================================================
-- Finding from the 2026-05-21 audit of B05·P03..P07:
-- auth_runtime.check_access was GRANT EXECUTE'd to `authenticated`, but it
-- accepts `p_actor_user_id` as a parameter and trusts it. An authenticated
-- caller could pass another user's id and (a) learn the access decision for
-- that user (information disclosure) and (b) write the WRONG principal into
-- the audit row (audit-trail integrity).
--
-- Spec says withAccessControl is the API-layer chokepoint that holds the
-- verified principal and calls check_access via service_role. No legitimate
-- path for direct authenticated invocation exists. Other DB-side DEFINER
-- RPCs that wrap protected operations inherit service_role grant via their
-- own SECURITY DEFINER + ownership.
--
-- Severity: HIGH (information disclosure + audit-trail integrity)
-- See audit-findings drawer for full audit results.
-- ============================================================================

REVOKE EXECUTE ON FUNCTION auth_runtime.check_access(uuid, text, text, jsonb, uuid, uuid) FROM authenticated;

COMMENT ON FUNCTION auth_runtime.check_access(uuid, text, text, jsonb, uuid, uuid) IS
'B05·P06 access control chokepoint. Returns jsonb envelope {decision, reason_code?, cross_tenant?, step_up_surface?, alert?}. Wraps public.can_perform in EXCEPTION trap (ACCESS_DECISION_THREW → DENY + CRITICAL alert). Emits ACCESS_ALLOWED only for sensitive surfaces. Recent MFA bypass for STEP_UP per per-surface step_up_window. SERVICE_ROLE ONLY — authenticated revoked 2026-05-21 (F1 audit fix): trusts p_actor_user_id parameter so authenticated invocation would allow impersonation + info disclosure.';
