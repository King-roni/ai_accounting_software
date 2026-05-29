-- Migration: 20260519000003_auth_users_public_users_sync
-- Ticket: Plane BOOK B02P02 (749cd9c0-8c4b-4229-a1a4-3c9627bfcc17)
-- Block: 02 — Tenancy & Access Control
-- Phase: 02 — Authentication Baseline
-- Author: stage-7-2 implementation
-- Description:
--   Bridges Supabase Auth (auth.users) to our profile table (public.users).
--   Two triggers:
--     1. AFTER INSERT on auth.users → create public.users row, copy
--        email + auth_user_id, derive email_verified from confirmed_at.
--     2. AFTER UPDATE on auth.users (on email_confirmed_at, email, banned_until)
--        → keep public.users.email_verified + email + is_active in sync.
--
-- Architectural note:
--   B02·P02 spec describes a custom-auth path with bcrypt in public.users
--   and a separate sessions table. Foundational stack decision (Supabase
--   Auth) supersedes — Supabase Auth owns credentials + JWT sessions; this
--   trigger only mirrors auth.users into our profile table. HIBP breach
--   check, 5-concurrent-session limit, and role-based absolute timeout are
--   deferred to post-MVP (can land as Supabase Auth hooks once Block 05
--   audit infrastructure is in place).
--
-- RLS waiver: function operates as SECURITY DEFINER inside the auth-event
-- pipeline; touches public.users with auth schema authority.

------------------------------------------------------------------------
-- 1. Trigger function: handle_new_auth_user
------------------------------------------------------------------------
-- Fires AFTER an auth.users row is inserted (signup). Mirrors the new
-- identity into public.users so downstream blocks (org_users,
-- business_user_roles, etc.) can FK against it.

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  -- Idempotent: skip if a public.users row already linked to this auth row.
  IF EXISTS (SELECT 1 FROM public.users WHERE auth_user_id = NEW.id) THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.users (
    auth_user_id,
    email,
    email_verified,
    email_verified_at,
    display_name,
    is_active
  ) VALUES (
    NEW.id,
    NEW.email,
    NEW.email_confirmed_at IS NOT NULL,
    NEW.email_confirmed_at,
    -- Display name comes from user_metadata.display_name if the signup form set it,
    -- otherwise NULL and the user completes profile later.
    COALESCE(NEW.raw_user_meta_data->>'display_name', NULL),
    true
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_auth_user() IS
  'Creates a public.users profile row when a new auth.users row is inserted (signup). Idempotent.';

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();


------------------------------------------------------------------------
-- 2. Trigger function: handle_auth_user_updated
------------------------------------------------------------------------
-- Fires AFTER an auth.users row is UPDATEd. Propagates the three fields
-- we mirror (email, email_verified, is_active) into public.users.

CREATE OR REPLACE FUNCTION public.handle_auth_user_updated()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  UPDATE public.users
  SET
    email             = NEW.email,
    email_verified    = NEW.email_confirmed_at IS NOT NULL,
    email_verified_at = NEW.email_confirmed_at,
    -- Banned users (auth.users.banned_until set + in future) flip to inactive;
    -- otherwise leave is_active as-is (Owner/Admin manage manually).
    is_active         = CASE
                          WHEN NEW.banned_until IS NOT NULL AND NEW.banned_until > now()
                          THEN false
                          ELSE is_active
                        END
  WHERE auth_user_id = NEW.id;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_auth_user_updated() IS
  'Mirrors auth.users mutations (email, confirmation, ban) to public.users.';

DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;
CREATE TRIGGER on_auth_user_updated
  AFTER UPDATE OF email, email_confirmed_at, banned_until ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_auth_user_updated();
