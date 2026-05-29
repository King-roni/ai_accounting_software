-- B04·P01 hashing helpers — SQL side of the cross-platform contract.
-- See api/src/cyprus_bookkeeping_api/hashing/core.py and
--     web/src/lib/hashing/ for the canonical_json implementations.
--
-- Callers pre-canonicalize their jsonb to text before invoking these
-- helpers. The functions do not re-implement canonical JSON in
-- PL/pgSQL — keeping the canonical-form algorithm in exactly one
-- language per side (Python in api, TS in web) prevents drift.

CREATE OR REPLACE FUNCTION public.hash_text_sha256(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions, pg_temp
AS $$
  SELECT encode(extensions.digest(convert_to(p_text, 'UTF8'), 'sha256'), 'hex');
$$;
REVOKE EXECUTE ON FUNCTION public.hash_text_sha256(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.hash_text_sha256(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.hash_chain_append(
  p_prev_hash text,
  p_canonical_event_text text
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions, pg_temp
AS $$
  SELECT encode(
    extensions.digest(
      convert_to(p_prev_hash || p_canonical_event_text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
$$;
REVOKE EXECUTE ON FUNCTION public.hash_chain_append(text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.hash_chain_append(text, text) TO authenticated;

COMMENT ON FUNCTION public.hash_text_sha256(text) IS
'B04·P01: SHA-256 (hex) of a pre-canonicalized text payload. Pair with canonical_json from api/src/.../hashing/core.py or web/src/lib/hashing/canonical-json.ts to compute matching record hashes.';
COMMENT ON FUNCTION public.hash_chain_append(text, text) IS
'B04·P01: audit-chain append. next_hash = sha256(prev_hash_hex || canonical_event_text). Used by B05·P02 hash chain.';
