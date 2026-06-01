-- R7.6 — real EU VIES VAT validation (replaces format-only).
--
-- A (country, vat_number)-keyed cache of EU VIES results, populated by the
-- worker (which calls the public EU VIES REST API — no key). Shared by client
-- management and the reverse-charge/VIES ledger flag. A VAT number's validity
-- is public EU data, but we keep the cache RLS-locked (deny-all to authenticated;
-- reads go through the SECURITY DEFINER RPCs below) so we don't leak which
-- numbers the system has checked across tenants.

CREATE TABLE IF NOT EXISTS public.vies_checks (
  id                   uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  country              char(2) NOT NULL,
  vat_number           text NOT NULL,
  valid                boolean NOT NULL,
  registered_name      text,
  registered_address   text,
  request_identifier   text,
  source               text NOT NULL DEFAULT 'EU_VIES_REST',
  checked_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (country, vat_number)
);
ALTER TABLE public.vies_checks ENABLE ROW LEVEL SECURITY;
-- No policies → deny-all for authenticated; service_role + SECURITY DEFINER bypass.

-- Upsert a VIES result (worker / service role only).
CREATE OR REPLACE FUNCTION public.record_vies_check(
  p_country char(2), p_vat_number text, p_valid boolean,
  p_registered_name text DEFAULT NULL, p_registered_address text DEFAULT NULL,
  p_request_identifier text DEFAULT NULL, p_source text DEFAULT 'EU_VIES_REST')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_id uuid;
BEGIN
  IF p_country IS NULL OR p_vat_number IS NULL OR p_valid IS NULL THEN
    RAISE EXCEPTION 'record_vies_check: country, vat_number, valid required' USING ERRCODE='22000';
  END IF;
  INSERT INTO public.vies_checks
    (country, vat_number, valid, registered_name, registered_address, request_identifier, source, checked_at)
  VALUES
    (upper(p_country), p_vat_number, p_valid, NULLIF(p_registered_name, '---'),
     NULLIF(p_registered_address, '---'), p_request_identifier, p_source, clock_timestamp())
  ON CONFLICT (country, vat_number) DO UPDATE
    SET valid = EXCLUDED.valid,
        registered_name = EXCLUDED.registered_name,
        registered_address = EXCLUDED.registered_address,
        request_identifier = EXCLUDED.request_identifier,
        source = EXCLUDED.source,
        checked_at = EXCLUDED.checked_at
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'vies_check_id', v_id, 'valid', p_valid);
END;
$function$;

-- Cached VIES validity for a (country, vat) — boolean, or NULL if never checked.
CREATE OR REPLACE FUNCTION public.vat_number_vies_valid(p_country char(2), p_vat_number text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT valid FROM public.vies_checks
   WHERE country = upper(p_country) AND vat_number = p_vat_number
   LIMIT 1;
$function$;

-- (country, vat) pairs from clients that need a (re)check — EU, format-valid,
-- active, and either never checked or stale. The worker polls this.
CREATE OR REPLACE FUNCTION public.clients_needing_vies_check(
  p_limit integer DEFAULT 25, p_recheck_days integer DEFAULT 30)
RETURNS TABLE(country char(2), vat_number text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT DISTINCT c.country, c.vat_number
  FROM public.clients c
  LEFT JOIN public.vies_checks v ON v.country = c.country AND v.vat_number = c.vat_number
  WHERE c.disabled_at IS NULL
    AND c.vat_number IS NOT NULL
    AND c.vat_number_format_valid
    AND public.is_eu_member_state(c.country)
    AND (v.country IS NULL OR v.checked_at < now() - make_interval(days => p_recheck_days))
  ORDER BY 1, 2
  LIMIT GREATEST(p_limit, 1);
$function$;

-- Per-client VIES status for the clients screen (RLS-checked via the business).
CREATE OR REPLACE FUNCTION public.list_client_vies_statuses(p_business_id uuid)
RETURNS TABLE(client_id uuid, valid boolean, checked_at timestamptz, registered_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.id, v.valid, v.checked_at, v.registered_name
  FROM public.clients c
  JOIN public.vies_checks v ON v.country = c.country AND v.vat_number = c.vat_number
  WHERE c.business_id = p_business_id
    AND p_business_id = ANY (public.current_user_businesses());
$function$;

GRANT EXECUTE ON FUNCTION public.record_vies_check(char, text, boolean, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.clients_needing_vies_check(integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.vat_number_vies_valid(char, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_client_vies_statuses(uuid) TO authenticated;
