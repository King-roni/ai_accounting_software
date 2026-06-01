-- R7.4 — personal audit feed: a per-user read over the hash-chain audit log.
--
-- audit.audit_events is append-only + hash-chained and lives in the `audit`
-- schema (not exposed to PostgREST). This adds a public, SECURITY DEFINER read
-- RPC scoped to the caller's OWN events (actor_user_id = current_user_id()),
-- returning only action / subject / timestamp / reason — never the
-- before/after-state or request_context blobs, which can hold sensitive data.
-- A null session (service role, no JWT) resolves to no user → no rows.

CREATE OR REPLACE FUNCTION public.list_my_audit_events(
  p_limit integer DEFAULT 50,
  p_lookback interval DEFAULT interval '30 days')
RETURNS TABLE(
  occurred_at timestamptz,
  action text,
  subject_type text,
  subject_id uuid,
  business_id uuid,
  reason text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
  SELECT ae.occurred_at, ae.action, ae.subject_type::text, ae.subject_id,
         ae.business_id, ae.reason
  FROM audit.audit_events ae
  WHERE ae.actor_user_id = public.current_user_id()
    AND public.current_user_id() IS NOT NULL
    AND ae.occurred_at > now() - p_lookback
  ORDER BY ae.occurred_at DESC
  LIMIT LEAST(GREATEST(p_limit, 1), 200);
$function$;

GRANT EXECUTE ON FUNCTION public.list_my_audit_events(integer, interval) TO authenticated;
