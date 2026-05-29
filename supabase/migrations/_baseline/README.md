# Live schema baseline (R0.1)

`20260529T000000_live_schema_baseline.sql` is a **squashed, current-state snapshot**
of the live Supabase app schema (project `noxvmnxrqlzsdfngfiww`, eu-west-1),
introspected from `pg_catalog` via the Supabase MCP on **2026-05-29**.

It exists because the incremental files in `supabase/migrations/*.sql` no longer
replay cleanly onto the live DB (the live `schema_migrations` records the original
timestamps; the repo files were renamed to a sequential scheme — version drift).
This baseline is the authoritative artifact for a **from-scratch rebuild** of the
app schema until the migration history is reconciled.

## What it contains (object-count verified against live)

| Object | Count |
|---|---|
| Schemas | 9 (`public, audit, keys, secrets, gdpr, alerts, archive, auth_runtime, backups`) |
| Enum types | 131 |
| Sequences | 1 |
| Functions | 660 |
| Tables | 157 |
| Constraints | 981 (PK/UNIQUE/CHECK then FK) |
| Indexes | 381 standalone (+201 PK/UNIQUE created via `ADD CONSTRAINT`) |
| Views | 17 |
| Triggers | 62 |
| RLS enables | 157 |
| Policies | 545 |
| Table grants | 2622 (anon/authenticated/service_role) |

Supabase-managed schemas (`auth`, `storage`, `realtime`, `vault`, `graphql`, …)
are **excluded** — the platform owns those.

## How to rebuild a fresh DB

```
psql "$DB_URL" -f supabase/migrations/_baseline/20260529T000000_live_schema_baseline.sql
psql "$DB_URL" -f supabase/seed.sql        # reference/seed data
```

The baseline begins with `SET check_function_bodies = false` and emits functions
before tables, so the table-default ↔ function circular dependency resolves on a
single pass. Replay with `public` in the `search_path` (the default).

## Known limitations (MCP introspection, not `pg_dump`)

- **Function-level `EXECUTE` / default-privilege grants are not reconstructed.**
  Supabase re-applies role `EXECUTE` defaults; SECURITY DEFINER functions run as
  owner, so this does not affect runtime behaviour.
- **Same-schema `public` FK targets are emitted unqualified** (`REFERENCES
  users(id)`); fine under the default search_path.
- **Views are ordered alphabetically**, not dependency-sorted (17 views; low risk).
- **Not yet replay-tested on a scratch DB.** Object coverage + statement syntax are
  verified; a full from-scratch replay (e.g. on a throwaway Supabase branch) is the
  remaining confidence step. Run `pg_dump` instead once a DB connection string is
  available — it is the canonical tool and supersedes this artifact.

## Rollback

Reverting a fresh rebuild = drop the 9 app schemas (`DROP SCHEMA <name> CASCADE`).
This baseline is additive (`CREATE … IF NOT EXISTS` for schemas); it is not meant to
be applied on top of the already-live DB.
