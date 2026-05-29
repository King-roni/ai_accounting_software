-- B06·P09 — Fix-up: digest() needs an explicit search_path
--
-- The original B06·P09 migration (20260522000007) declared make_ai_cache_key
-- with SET search_path TO 'public', 'audit', 'pg_temp'. pgcrypto's digest()
-- lives in the extensions schema, so the function failed at runtime with
-- "function digest(text, unknown) does not exist". Fix: extend the search_path
-- to include 'extensions' and qualify the call as extensions.digest() for
-- defense-in-depth.

CREATE OR REPLACE FUNCTION public.make_ai_cache_key(
  p_tool_name text, p_prompt_id text, p_prompt_version text, p_policy_version text, p_input jsonb
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path TO 'public', 'audit', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_canonical text;
BEGIN
  IF p_tool_name IS NULL OR p_input IS NULL THEN
    RAISE EXCEPTION 'make_ai_cache_key: p_tool_name and p_input required'
      USING ERRCODE='22000';
  END IF;
  v_canonical := p_tool_name || E'\x1f'
              || COALESCE(p_prompt_id, '')      || E'\x1f'
              || COALESCE(p_prompt_version, '') || E'\x1f'
              || COALESCE(p_policy_version, '') || E'\x1f'
              || audit.canonical_jsonb(p_input);
  RETURN encode(extensions.digest(v_canonical, 'sha256'), 'hex');
END;
$function$;
