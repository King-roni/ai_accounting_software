# Block 02 — Phase 01: Schema Scaffolding

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md`
- Decisions log: `Docs/decisions_log.md` (Postgres via Supabase · EU only · Supabase Vault available)

## Phase Goal

Lay down the database tables that everything in Block 02 (and every downstream block) will read and write. After this phase, the tenancy hierarchy exists in Postgres, has its scoping columns, and can be queried — but no application logic uses it yet.

## Dependencies

- Project bootstrap: a Supabase project exists in an EU region with environment configuration in place.
- Stage 1 decisions confirmed: Postgres via Supabase, EU only, RLS to be added in Phase 05.

## Deliverables

- **Migration framework** chosen and set up (Supabase CLI migrations is the default — confirm in sub-doc).
- **Core tables:**
  - `organizations` — `id`, `name`, `created_at`, `updated_at`, `status`.
  - `users` — extends Supabase Auth's `auth.users` via a `public.users` profile row keyed by `auth_user_id`. Carries display fields, MFA-enabled flag (populated in Phase 03), `created_at`, `updated_at`.
  - `business_entities` — `id`, `organization_id`, `legal_name`, `trading_name`, `company_registration_number`, `vat_number`, `tax_identification_number`, `country`, `base_currency`, `accounting_method` (defaults to `accrual`; only `accrual` is permitted in MVP per Stage 1 — the enum shape preserves room for post-MVP expansion), `vat_registered`, `vat_registration_date`, `vat_period_type`, `created_at`, `updated_at`.
  - `bank_accounts` — `id`, `business_id`, `provider`, `account_name`, `currency`, `masked_iban`, `iban_encrypted` (ciphertext column; encryption is owned by Block 05 — this column holds a ciphertext blob once that block lands), `account_number_encrypted`, `status`, `created_at`, `updated_at`.
  - `organization_users` — membership of users in organizations, with `organization_id`, `user_id`, `joined_at`, `status`.
  - `business_user_roles` — assignment of `(user_id, business_id) → role`, where role is one of the six. Includes `assigned_at`, `assigned_by`, `status`.
- **Indexes** on every foreign key, every `(organization_id, business_id)` pair, and on `status` columns used in filters.
- **Audit timestamp triggers** that maintain `updated_at` automatically.
- **Seed migration** that creates a single test organization + user during local dev (no production seed).

## Definition of Done

- Migrations apply cleanly to a fresh Supabase project.
- Every table from the list above is present with its expected columns.
- Foreign keys and indexes are in place; an `EXPLAIN` on a typical scoped query shows index use.
- A user record can be created via Supabase Auth and a corresponding `public.users` row exists.
- Test organization + business + bank account can be inserted via SQL without errors.
- No RLS policies yet — the schema is "open" until Phase 05 (this is intentional and called out in the migration's README).

## Sub-doc Hooks (Stage 4)

- **Migration tooling sub-doc** — Supabase CLI workflow, naming conventions, rollback strategy.
- **Schema definition sub-doc** — full column types, constraints, and ENUMs per table; this becomes the canonical schema reference.
- **Soft-delete vs status policy sub-doc** — when do records get a `status` enum vs an explicit deleted flag, and how does this interact with retention?
