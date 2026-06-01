-- =============================================================================
-- Pretest readiness fix (2026-06-02) — restrict step-up sentinel EXECUTE (re-audit)
-- =============================================================================
-- 20260601000014 created list_stale_step_up_guard_functions() and did
-- REVOKE ALL ... FROM PUBLIC, but on this project anon/authenticated hold their
-- own default-ACL EXECUTE grants, so REVOKE FROM PUBLIC was a no-op and the fn
-- stayed callable unauthenticated over PostgREST (/rest/v1/rpc) — flagged by
-- Supabase advisors 0028/0029. Impact is bounded (it returns only public
-- function names, currently none) but it contradicts the intent. Revoke from
-- the role grants explicitly; keep service_role (used by the guard test).
-- =============================================================================

REVOKE EXECUTE ON FUNCTION public.list_stale_step_up_guard_functions() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_stale_step_up_guard_functions() TO service_role;
