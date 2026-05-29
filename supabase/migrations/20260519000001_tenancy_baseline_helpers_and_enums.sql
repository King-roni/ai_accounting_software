-- Migration: 20260519000001_tenancy_baseline_helpers_and_enums
-- Ticket: Plane BOOK B02P01 (47f942ce-6812-4c19-8130-d8c2bf77ae3f)
-- Block: 02 — Tenancy & Access Control
-- Phase: 01 — Schema Scaffolding (baseline)
-- Author: stage-7-1 implementation
-- Description:
--   Establishes the shared helpers + closed ENUMs that the six core tenancy
--   tables (next migration) and every downstream block depend on:
--     1. pgcrypto enabled (gen_random_bytes for UUID v7)
--     2. gen_uuid_v7()      — UUID v7 generator per data_layer_conventions_policy
--     3. set_updated_at()    — trigger function that maintains updated_at
--     4. six ENUM types (user_role, business_status, account_status,
--        org_status, accounting_method, vat_period_type) per
--        tenancy_schema_definition + soft_delete_vs_status_policy.
--
-- RLS waiver: this migration creates no tables, so the
-- supabase_migration_tooling_policy §2.4 "CREATE TABLE must include RLS in
-- same file" rule does not apply.

------------------------------------------------------------------------
-- 1. Extensions
------------------------------------------------------------------------

-- pgcrypto provides gen_random_bytes(), needed by gen_uuid_v7().
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;


------------------------------------------------------------------------
-- 2. gen_uuid_v7() — canonical UUID v7 generator
------------------------------------------------------------------------
-- Generates RFC 9562 UUID v7: 48-bit Unix-millisecond timestamp prefix
-- + version=7 + variant=10 + random tail. Monotonically increasing within
-- ~1ms precision, B-tree-friendly (hot pages stay clustered).
--
-- Per data_layer_conventions_policy §2: default ID generator for every
-- business-data table; v4 (gen_random_uuid) is reserved for unguessable
-- short-lived tokens.

CREATE OR REPLACE FUNCTION public.gen_uuid_v7()
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  ts_ms        bigint;
  unix_ts_ms   bytea;
  uuid_bytes   bytea;
BEGIN
  -- 48-bit millisecond timestamp.
  ts_ms      := (extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  unix_ts_ms := substring(int8send(ts_ms) FROM 3);          -- 6 bytes

  -- 6 timestamp bytes + 10 random bytes = 16 bytes total.
  uuid_bytes := unix_ts_ms || extensions.gen_random_bytes(10);

  -- Set version = 7 in upper nibble of byte 6.
  uuid_bytes := set_byte(
    uuid_bytes, 6,
    ((get_byte(uuid_bytes, 6) & 15) | 112)
  );

  -- Set variant = 10 in upper two bits of byte 8 (RFC 4122 variant).
  uuid_bytes := set_byte(
    uuid_bytes, 8,
    ((get_byte(uuid_bytes, 8) & 63) | 128)
  );

  RETURN encode(uuid_bytes, 'hex')::uuid;
END;
$$;

COMMENT ON FUNCTION public.gen_uuid_v7() IS
  'RFC 9562 UUID v7 generator. Canonical per data_layer_conventions_policy §2.';


------------------------------------------------------------------------
-- 3. set_updated_at() — trigger function for audit timestamps
------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_updated_at() IS
  'BEFORE UPDATE trigger: maintains updated_at on every row mutation.';


------------------------------------------------------------------------
-- 4. Closed ENUMs (per tenancy_schema_definition + soft_delete policy)
------------------------------------------------------------------------

-- Six base roles per Stage 1 decision. Order is presentation-only; code
-- must treat the set as closed and hard-fail on unknown values.
CREATE TYPE public.user_role AS ENUM (
  'OWNER',
  'ADMIN',
  'BOOKKEEPER',
  'ACCOUNTANT',
  'REVIEWER',
  'READ_ONLY'
);

-- Business lifecycle status (business_entities). ARCHIVED is the
-- write-rejection terminal per soft_delete_vs_status_policy.
CREATE TYPE public.business_status AS ENUM (
  'ACTIVE',
  'INACTIVE',
  'ARCHIVED'
);

-- Generic account status (bank_accounts, organization_users,
-- business_user_roles). Same three values for symmetry.
CREATE TYPE public.account_status AS ENUM (
  'ACTIVE',
  'INACTIVE',
  'ARCHIVED'
);

-- Organization status. Orgs are not "archived" in MVP — deactivation
-- only, with deleted_at carrying the GDPR-erasure timestamp.
CREATE TYPE public.org_status AS ENUM (
  'ACTIVE',
  'INACTIVE'
);

-- Accounting method. MVP is ACCRUAL only (Stage 1 decision). ENUM
-- shape preserves room for post-MVP CASH addition without a migration.
CREATE TYPE public.accounting_method AS ENUM (
  'ACCRUAL'
);

-- VAT filing cadence. Cyprus default is QUARTERLY; MONTHLY for large
-- traders; ANNUAL for very small. Required for filing windows in B11/B16.
CREATE TYPE public.vat_period_type AS ENUM (
  'QUARTERLY',
  'MONTHLY',
  'ANNUAL'
);
