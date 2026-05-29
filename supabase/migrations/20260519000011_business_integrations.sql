-- B02·P08 OAuth Integration Foundation
-- ============================================================================
-- Tables: business_integrations + drive_folder_mappings.
-- RPCs: record_integration_connect / refresh / refresh_failed / disconnect +
--       save_drive_folder_mapping. Disconnect consumes a B02·P06 step-up token.
--
-- Token encryption happens Node-side (AES-256-GCM with a server-only master
-- key); this layer stores opaque base64 ciphertext. The Vault-backed path is
-- documented as a deferred enhancement.
-- ============================================================================

CREATE TYPE public.integration_provider AS ENUM ('GMAIL','GOOGLE_DRIVE');
CREATE TYPE public.integration_status   AS ENUM ('ACTIVE','DISCONNECTED','ERROR');

CREATE TABLE IF NOT EXISTS public.business_integrations (
  id                              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id                 uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  provider                        public.integration_provider NOT NULL,
  status                          public.integration_status NOT NULL DEFAULT 'ACTIVE',
  connected_user_id               uuid REFERENCES public.users(id),
  oauth_access_token_encrypted    text,
  oauth_refresh_token_encrypted   text,
  scope                           text[] NOT NULL DEFAULT ARRAY[]::text[],
  access_token_expires_at         timestamptz,
  connected_at                    timestamptz NOT NULL DEFAULT now(),
  last_refreshed_at               timestamptz,
  last_used_at                    timestamptz,
  last_error                      text,
  disconnected_at                 timestamptz,
  disconnected_by                 uuid REFERENCES public.users(id),
  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_integrations_business_provider_unique UNIQUE (business_id, provider)
);

CREATE INDEX IF NOT EXISTS idx_business_integrations_business
  ON public.business_integrations (business_id, status);

CREATE TRIGGER business_integrations_set_updated_at
  BEFORE UPDATE ON public.business_integrations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.business_integrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_integrations FORCE  ROW LEVEL SECURITY;

-- Owner/Admin (and members generally — the encrypted tokens are opaque
-- without the server-side master key, so this is operational visibility).
CREATE POLICY business_integrations_select ON public.business_integrations
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY business_integrations_no_insert ON public.business_integrations
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY business_integrations_no_update ON public.business_integrations
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY business_integrations_no_delete ON public.business_integrations
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

CREATE TABLE IF NOT EXISTS public.drive_folder_mappings (
  business_id                   uuid PRIMARY KEY REFERENCES public.business_entities(id) ON DELETE CASCADE,
  organization_id               uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  root_folder_id                text NOT NULL,
  root_folder_name              text,
  subfolder_naming_convention   text NOT NULL DEFAULT '2_week_date_ranges'
    CHECK (subfolder_naming_convention IN ('2_week_date_ranges')),
  connected_at                  timestamptz NOT NULL DEFAULT now(),
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER drive_folder_mappings_set_updated_at
  BEFORE UPDATE ON public.drive_folder_mappings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.drive_folder_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.drive_folder_mappings FORCE  ROW LEVEL SECURITY;

CREATE POLICY drive_folder_mappings_select ON public.drive_folder_mappings
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY drive_folder_mappings_no_insert ON public.drive_folder_mappings
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY drive_folder_mappings_no_update ON public.drive_folder_mappings
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY drive_folder_mappings_no_delete ON public.drive_folder_mappings
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ===========================================================================
-- Helper: caller is Owner/Admin on the given business (used by every write RPC)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._integration_assert_owner_admin(p_business_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id uuid;
  v_role public.user_role;
BEGIN
  SELECT u.id INTO v_caller_user_id FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'INTEGRATION_NOT_AUTHENTICATED' USING ERRCODE = '28000';
  END IF;
  SELECT role INTO v_role FROM public.business_user_roles
  WHERE user_id = v_caller_user_id AND business_id = p_business_id AND status='ACTIVE';
  IF v_role IS NULL OR v_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'INTEGRATION_REQUIRES_OWNER_OR_ADMIN' USING ERRCODE = '42501';
  END IF;
  RETURN v_caller_user_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public._integration_assert_owner_admin(uuid) FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- record_integration_connect — upsert on (business_id, provider)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.record_integration_connect(
  p_business_id                   uuid,
  p_provider                      public.integration_provider,
  p_scope                         text[],
  p_encrypted_access_token        text,
  p_encrypted_refresh_token       text,
  p_access_token_expires_at       timestamptz
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id uuid;
  v_organization_id uuid;
  v_integration_id uuid;
BEGIN
  v_caller_user_id := public._integration_assert_owner_admin(p_business_id);

  SELECT organization_id INTO v_organization_id
  FROM public.business_entities WHERE id = p_business_id;
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'INTEGRATION_BUSINESS_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  v_integration_id := public.gen_uuid_v7();
  INSERT INTO public.business_integrations (
    id, organization_id, business_id, provider, status, connected_user_id,
    oauth_access_token_encrypted, oauth_refresh_token_encrypted, scope,
    access_token_expires_at, connected_at, last_refreshed_at,
    last_error, disconnected_at, disconnected_by
  ) VALUES (
    v_integration_id, v_organization_id, p_business_id, p_provider, 'ACTIVE',
    v_caller_user_id, p_encrypted_access_token, p_encrypted_refresh_token,
    p_scope, p_access_token_expires_at, now(), now(), NULL, NULL, NULL
  )
  ON CONFLICT ON CONSTRAINT business_integrations_business_provider_unique
  DO UPDATE SET
    status                        = 'ACTIVE',
    connected_user_id             = v_caller_user_id,
    oauth_access_token_encrypted  = EXCLUDED.oauth_access_token_encrypted,
    oauth_refresh_token_encrypted = EXCLUDED.oauth_refresh_token_encrypted,
    scope                         = EXCLUDED.scope,
    access_token_expires_at       = EXCLUDED.access_token_expires_at,
    connected_at                  = now(),
    last_refreshed_at             = now(),
    last_error                    = NULL,
    disconnected_at               = NULL,
    disconnected_by               = NULL
  RETURNING id INTO v_integration_id;

  RETURN v_integration_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.record_integration_connect(uuid, public.integration_provider, text[], text, text, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_integration_connect(uuid, public.integration_provider, text[], text, text, timestamptz) TO authenticated;

-- ===========================================================================
-- record_integration_refresh
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.record_integration_refresh(
  p_integration_id                uuid,
  p_encrypted_access_token        text,
  p_encrypted_refresh_token       text,
  p_access_token_expires_at       timestamptz
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_business_id uuid;
BEGIN
  SELECT business_id INTO v_business_id
  FROM public.business_integrations
  WHERE id = p_integration_id AND status IN ('ACTIVE','ERROR');
  IF v_business_id IS NULL THEN RETURN false; END IF;

  PERFORM public._integration_assert_owner_admin(v_business_id);

  UPDATE public.business_integrations SET
    oauth_access_token_encrypted  = p_encrypted_access_token,
    oauth_refresh_token_encrypted = COALESCE(p_encrypted_refresh_token, oauth_refresh_token_encrypted),
    access_token_expires_at       = p_access_token_expires_at,
    status                        = 'ACTIVE',
    last_refreshed_at             = now(),
    last_error                    = NULL
  WHERE id = p_integration_id;
  RETURN FOUND;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.record_integration_refresh(uuid, text, text, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_integration_refresh(uuid, text, text, timestamptz) TO authenticated;

-- ===========================================================================
-- record_integration_refresh_failed
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.record_integration_refresh_failed(
  p_integration_id uuid,
  p_error_message  text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_business_id uuid;
BEGIN
  SELECT business_id INTO v_business_id FROM public.business_integrations WHERE id = p_integration_id;
  IF v_business_id IS NULL THEN RETURN false; END IF;
  PERFORM public._integration_assert_owner_admin(v_business_id);

  UPDATE public.business_integrations SET
    status     = 'ERROR',
    last_error = p_error_message
  WHERE id = p_integration_id;
  RETURN FOUND;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.record_integration_refresh_failed(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_integration_refresh_failed(uuid, text) TO authenticated;

-- ===========================================================================
-- record_integration_disconnect — step-up required, clears tokens at rest
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.record_integration_disconnect(
  p_integration_id uuid,
  p_step_up_token  uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id uuid;
  v_business_id uuid;
  v_consumed boolean;
  v_reason text;
BEGIN
  SELECT business_id INTO v_business_id
  FROM public.business_integrations
  WHERE id = p_integration_id AND status <> 'DISCONNECTED';
  IF v_business_id IS NULL THEN RETURN false; END IF;

  v_caller_user_id := public._integration_assert_owner_admin(v_business_id);

  SELECT consumed, reason INTO v_consumed, v_reason
  FROM public.consume_step_up_token(p_step_up_token, v_business_id, 'EXTERNAL_INTEGRATION', NULL);
  IF NOT v_consumed THEN
    RAISE EXCEPTION 'INTEGRATION_STEP_UP_REJECTED:%', v_reason USING ERRCODE = '42501';
  END IF;

  UPDATE public.business_integrations SET
    status                         = 'DISCONNECTED',
    disconnected_at                = now(),
    disconnected_by                = v_caller_user_id,
    oauth_access_token_encrypted   = NULL,
    oauth_refresh_token_encrypted  = NULL
  WHERE id = p_integration_id;
  RETURN FOUND;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.record_integration_disconnect(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_integration_disconnect(uuid, uuid) TO authenticated;

-- ===========================================================================
-- save_drive_folder_mapping
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.save_drive_folder_mapping(
  p_business_id       uuid,
  p_root_folder_id    text,
  p_root_folder_name  text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
BEGIN
  PERFORM public._integration_assert_owner_admin(p_business_id);
  SELECT organization_id INTO v_organization_id FROM public.business_entities WHERE id = p_business_id;
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'INTEGRATION_BUSINESS_NOT_FOUND' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.drive_folder_mappings (
    business_id, organization_id, root_folder_id, root_folder_name,
    subfolder_naming_convention, connected_at
  ) VALUES (
    p_business_id, v_organization_id, p_root_folder_id, p_root_folder_name,
    '2_week_date_ranges', now()
  )
  ON CONFLICT (business_id) DO UPDATE SET
    root_folder_id   = EXCLUDED.root_folder_id,
    root_folder_name = EXCLUDED.root_folder_name,
    connected_at     = now();
  RETURN true;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.save_drive_folder_mapping(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.save_drive_folder_mapping(uuid, text, text) TO authenticated;

COMMENT ON TABLE public.business_integrations IS
'Per-business OAuth integrations (B02·P08). Tokens are encrypted Node-side with AES-256-GCM before being stored. Lifecycle RPCs are the only mutation paths.';
