-- Migration: 20260519000004_mfa_recovery_codes_and_user_state
-- Ticket: Plane BOOK B02P03 (530bca79-637a-441e-aed9-901f66a94df5)
-- Block: 02 — Tenancy & Access Control
-- Phase: 03 — Multi-Factor Authentication
-- Author: stage-7-3 implementation
-- Description:
--   Stage 7-3 MFA schema additions on top of Supabase Auth's native MFA:
--     1. mfa_recovery_codes — bcrypt-hashed single-use recovery codes
--        (Supabase Auth has no native recovery-code feature, so we layer
--        it on top of auth.mfa_factors).
--     2. public.users columns — mfa_enabled (boolean), mfa_factors_count
--        (integer), last_used_factor_type (text) — surfaced to the UI
--        without having to cross-schema query auth.mfa_factors.
--     3. Sync trigger on auth.mfa_factors that maintains the public.users
--        counter columns automatically.
--
-- Architectural decisions (vs the phase / sub-doc spec):
--   • TOTP secret storage uses Supabase Auth's native auth.mfa_factors
--     (already AES-256-GCM-encrypted at rest by Supabase). The spec's
--     custom mfa_devices table is NOT created — duplicating the data
--     would defeat the security model. References to it elsewhere in the
--     spec corpus implicitly target auth.mfa_factors when reading.
--   • FIDO2 / passkey enrollment is deferred — Supabase Auth has native
--     WebAuthn support and the UI lands in a follow-up sub-phase once
--     the TOTP path is in production.
--   • Device trust + forced re-enrollment + audit events are deferred to
--     post-MVP / B05 audit landing.
--
-- RLS waiver: Phase-05 standard — RLS is enabled in B02·P05.

------------------------------------------------------------------------
-- 1. public.users MFA state columns
------------------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN mfa_enabled            boolean     NOT NULL DEFAULT false,
  ADD COLUMN mfa_factors_count      integer     NOT NULL DEFAULT 0
    CHECK (mfa_factors_count >= 0),
  ADD COLUMN last_used_factor_type  text;

COMMENT ON COLUMN public.users.mfa_enabled IS
  'TRUE when the user has at least one verified factor in auth.mfa_factors. Maintained by trigger.';
COMMENT ON COLUMN public.users.mfa_factors_count IS
  'Count of verified factors. Maintained by trigger.';
COMMENT ON COLUMN public.users.last_used_factor_type IS
  'Factor type of the most recent successful MFA challenge (totp | phone | webauthn). Application-set.';


------------------------------------------------------------------------
-- 2. mfa_recovery_codes table
------------------------------------------------------------------------

CREATE TABLE public.mfa_recovery_codes (
  id          uuid        NOT NULL DEFAULT public.gen_uuid_v7(),
  user_id     uuid        NOT NULL,
  code_hash   text        NOT NULL,                                  -- bcrypt $2b$...
  consumed_at timestamptz,                                           -- single-use marker
  consumed_ip text,                                                  -- last-resort forensic
  batch_id    uuid        NOT NULL,                                  -- groups the 8 codes from one regeneration
  created_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT mfa_recovery_codes_pkey      PRIMARY KEY (id),
  CONSTRAINT mfa_recovery_codes_user_fk   FOREIGN KEY (user_id)
    REFERENCES public.users(id) ON DELETE CASCADE
);

-- Active (unconsumed) lookups during challenge are scoped per user.
CREATE INDEX idx_mfa_recovery_codes_user_unconsumed
  ON public.mfa_recovery_codes (user_id)
  WHERE consumed_at IS NULL;

-- All codes for a user, newest-first (UI).
CREATE INDEX idx_mfa_recovery_codes_user_created
  ON public.mfa_recovery_codes (user_id, created_at DESC);

COMMENT ON TABLE public.mfa_recovery_codes IS
  'Bcrypt-hashed single-use recovery codes for MFA fallback. 8 codes per regeneration batch (per mfa_enrollment_policy.md). Plaintext is never stored — shown to user once at generation.';


------------------------------------------------------------------------
-- 3. auth.mfa_factors → public.users sync trigger
------------------------------------------------------------------------
-- Maintains public.users.mfa_factors_count + mfa_enabled by counting
-- verified factors. Runs as SECURITY DEFINER so it can read auth schema.

CREATE OR REPLACE FUNCTION public.refresh_user_mfa_state(p_auth_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM auth.mfa_factors
  WHERE user_id = p_auth_user_id
    AND status = 'verified';

  UPDATE public.users
  SET
    mfa_factors_count = v_count,
    mfa_enabled       = (v_count > 0)
  WHERE auth_user_id = p_auth_user_id;
END;
$$;

COMMENT ON FUNCTION public.refresh_user_mfa_state(uuid) IS
  'Re-counts verified MFA factors in auth.mfa_factors and updates public.users counters for the matching profile row.';

CREATE OR REPLACE FUNCTION public.handle_mfa_factor_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  -- On any insert/update/delete in auth.mfa_factors, recompute counters
  -- for the affected user(s). For UPDATE we recompute for both OLD and
  -- NEW user_ids in case factors got reassigned (shouldn't happen in
  -- practice, but cheap insurance).
  IF (TG_OP = 'DELETE') THEN
    PERFORM public.refresh_user_mfa_state(OLD.user_id);
    RETURN OLD;
  END IF;

  PERFORM public.refresh_user_mfa_state(NEW.user_id);
  IF (TG_OP = 'UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id) THEN
    PERFORM public.refresh_user_mfa_state(OLD.user_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_mfa_factor_changed ON auth.mfa_factors;
CREATE TRIGGER on_mfa_factor_changed
  AFTER INSERT OR UPDATE OR DELETE ON auth.mfa_factors
  FOR EACH ROW EXECUTE FUNCTION public.handle_mfa_factor_change();

COMMENT ON FUNCTION public.handle_mfa_factor_change() IS
  'Trigger function: refreshes public.users MFA counter columns when auth.mfa_factors changes.';
