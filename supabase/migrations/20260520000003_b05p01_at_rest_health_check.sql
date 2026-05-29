-- B05·P01 At-rest encryption health check
-- ============================================================================
-- Startup self-check the spec requires. Verifies the DB-observable security
-- baseline: every application bucket is private (public=false). Postgres
-- at-rest encryption + bucket-level at-rest encryption are Supabase platform
-- defaults (AES-256); the RPC's note field documents that explicitly. The
-- application HTTP clients (api/secure_http/, web/src/lib/secure-http/)
-- enforce TLS 1.3 + HSTS + SPKI certificate pinning on outbound calls.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.at_rest_encryption_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, storage, pg_temp
AS $fn$
  WITH expected_buckets AS (
    SELECT unnest(ARRAY['raw-uploads','processing-zone','archive-bundles']) AS id
  ),
  bucket_state AS (
    SELECT
      eb.id,
      b.id IS NOT NULL                AS exists,
      COALESCE(NOT b.public, false)   AS is_private,
      b.file_size_limit               AS size_limit,
      cardinality(b.allowed_mime_types) AS allowed_mime_count
    FROM expected_buckets eb
    LEFT JOIN storage.buckets b ON b.id = eb.id
  )
  SELECT jsonb_build_object(
    'all_ok', (
      SELECT bool_and(exists AND is_private)
        FROM bucket_state
    ),
    'buckets', (
      SELECT jsonb_agg(jsonb_build_object(
        'id',           id,
        'exists',       exists,
        'is_private',   is_private,
        'size_limit',   size_limit,
        'allowed_mime_count', allowed_mime_count
      ))
      FROM bucket_state
    ),
    'note',
      'Postgres at-rest encryption is enforced by Supabase platform default (AES-256). '
      'Bucket-level encryption is also Supabase platform default. TLS 1.3 + HSTS + '
      'certificate pinning are enforced by the application HTTP clients '
      '(api/secure_http and web/src/lib/secure-http).'
  )
$fn$;

REVOKE EXECUTE ON FUNCTION public.at_rest_encryption_status() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.at_rest_encryption_status() TO authenticated, service_role;

COMMENT ON FUNCTION public.at_rest_encryption_status() IS
'B05·P01 startup self-check. Returns {all_ok, buckets[], note}. Fail-fast assertion at boot: any FALSE in all_ok means an application bucket is misconfigured (public, missing, etc.).';
