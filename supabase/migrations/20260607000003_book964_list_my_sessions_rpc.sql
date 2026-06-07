-- =============================================================================
-- BOOK-964 — /account/sessions: read sessions via a public RPC, not the auth schema.
-- =============================================================================
-- The page queried admin.schema('auth').from('sessions'), but PostgREST does not
-- expose the `auth` schema (db-schemas = public, graphql_public), so the request
-- failed with "Invalid schema: auth" and the device list never loaded.
--
-- Fix: a SECURITY DEFINER function in `public` that returns the *caller's* own
-- sessions from auth.sessions, scoped by auth.uid(). Callable by authenticated
-- via the normal data API (no service-role / no auth-schema exposure needed).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.list_my_sessions()
 RETURNS TABLE(
   id uuid,
   created_at timestamptz,
   updated_at timestamptz,
   factor_id uuid,
   aal text,
   user_agent text,
   ip text)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  SELECT s.id, s.created_at, s.updated_at, s.factor_id,
         s.aal::text, s.user_agent, host(s.ip)
  FROM auth.sessions s
  WHERE s.user_id = auth.uid()
  ORDER BY s.updated_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.list_my_sessions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_sessions() TO authenticated;
