# archive_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The Finalized Archive zone — a separate Postgres schema (`archive.*`) with stricter RLS and write semantics, per the Stage 1 decision: "Separate Postgres schema with stricter RLS + Supabase Storage Object Lock for archive files."

Tables here are append-only and immutable from the application's perspective. Writes happen only inside the Block 15 lock sequence, gated by mutually exclusive session variables (`app.original_lock_active`, `app.adjustment_lock_active`) per the Block 15 Phase 07 amendment.

---

## Schema declaration

```sql
CREATE SCHEMA archive;

-- Roles
CREATE ROLE archive_writer;             -- only Block 15 finalization processes assume this
CREATE ROLE archive_reader;             -- application read access
CREATE ROLE retention_engine;           -- the only role authorised for archive DELETEs (after retention window)
```

## Core tables

### `archive.locked_ledger_entries`

The `locked_ledger_entries` table is defined canonically in `locked_ledger_entries_schema` (Block 15 Layer 2). This file references it as part of the archive data model; the column definition is not repeated here.

### `archive.archive_packages`

```sql
CREATE TABLE archive.archive_packages (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL,
  workflow_run_id             uuid NOT NULL REFERENCES workflow_runs(workflow_run_id),
  period_start                date NOT NULL,
  period_end                  date NOT NULL,

  -- Bundle metadata
  bundle_object_uri           text NOT NULL,                        -- Supabase Storage path
  bundle_hash                 text NOT NULL,                        -- hex SHA-256 of the full bundle bytes
  bundle_size_bytes           bigint NOT NULL,

  -- Manifest chain
  current_manifest_version_number integer NOT NULL DEFAULT 1,

  -- Object Lock metadata
  object_lock_retention_until timestamptz NOT NULL,                 -- per Cyprus 6-year minimum
  object_lock_mode            text NOT NULL DEFAULT 'COMPLIANCE',   -- vs 'GOVERNANCE' per object_lock_integration

  -- Lifecycle
  promoted_at                 timestamptz NOT NULL DEFAULT now(),

  UNIQUE (business_id, period_start, period_end)                    -- one package per period per business
);
```

Per Stage 1: "Archive package format: a single sealed zip bundle with the manifest embedded inside the bundle. The bundle itself is the immutable object under Storage Object Lock."

The `bundle_object_uri` points to the sealed zip; the bundle's internal layout is per `archive_bundle_layout_schema`. Adjustment-finalization writes a NEW bundle alongside (e.g., `bundle_v2.zip`) — per the Block 15 scan fix: each bundle is a separate zone object.

### `archive.archive_manifests`

```sql
CREATE TABLE archive.archive_manifests (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  archive_package_id          uuid NOT NULL REFERENCES archive.archive_packages(id),
  manifest_version_number     integer NOT NULL,

  -- The manifest itself
  manifest_canonical_json     text NOT NULL,                        -- canonical JSON, never modified
  manifest_hash               text NOT NULL,                        -- hex SHA-256 of manifest_canonical_json

  -- Lineage
  prior_manifest_id           uuid REFERENCES archive.archive_manifests(id),
  source_adjustment_run_id    uuid REFERENCES workflow_runs(workflow_run_id),

  -- RFC 3161 anchor (Block 05 Phase 03)
  rfc_3161_timestamp_id       uuid,

  created_at                  timestamptz NOT NULL DEFAULT now(),

  UNIQUE (archive_package_id, manifest_version_number)
);
```

Per Stage 1: "Manifest versioning on re-finalization: increment a version number and preserve all prior manifests under Object Lock. Each adjustment-finalization writes a new manifest version; old versions remain queryable."

The manifest carries the full inventory of files inside the bundle, their hashes, and the chain back to the prior version. Per the Block 15 scan fix: manifests live INSIDE their respective zip bundles as files; this Postgres table indexes the manifests for query (the manifest content is duplicated for fast access).

### `archive.review_issues` (frozen)

Mirror of operational `review_issues` at the finalization moment. Per the Block 04 scan fix: renamed from `archive.review_issues_history` to `archive.review_issues` for symmetry with operational naming.

```sql
CREATE TABLE archive.review_issues (
  -- Same column list as operational review_issues
  -- Plus:
  archive_package_id          uuid NOT NULL REFERENCES archive.archive_packages(id),
  archived_at                 timestamptz NOT NULL DEFAULT now()
);
```

### `archive.transactions`, `archive.documents`, `archive.match_records`

Mirrors of the corresponding operational tables, frozen at finalization. Per Phase 04 step 2 of the lock sequence (Block 15): the canonical FK references for these tables pin to Block 09's `documents` schema for cross-block ownership clarity.

## RLS

Stricter than operational. Per Stage 1 ("Finalized Archive physical model: stricter RLS"):

```sql
CREATE POLICY archive_locked_ledger_entries_read ON archive.locked_ledger_entries
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND (
      auth.role_on_business(business_id) IN ('Owner', 'Admin', 'Accountant')
      -- Bookkeeper/Reviewer/Read-only can read aggregated views, not raw rows
    )
  );

CREATE POLICY archive_locked_ledger_entries_no_update ON archive.locked_ledger_entries
  FOR UPDATE
  USING (false);                                                     -- nobody can UPDATE; immutable

CREATE POLICY archive_locked_ledger_entries_no_delete ON archive.locked_ledger_entries
  FOR DELETE
  USING (
    current_setting('app.retention_engine_active', true) = 'true'
    AND auth.role_on_business(business_id) IS NULL                  -- retention_engine has no business role
  );
```

Application access is mostly through views — `archive.locked_ledger_entries_aggregated` and similar — that strip per-row PII for roles below Accountant.

## Audit visibility

Per-session archive reads are aggregated per `audit_log_policies` aggregation rule and emitted at session end as `ARCHIVE_DATA_READ_SESSION_SUMMARY` per the Block 15 scan. No per-read `ARCHIVE_DATA_READ` event is emitted — that form was collapsed into the session summary to control audit volume.

Tampering attempts (e.g., UPDATE blocked by RLS) emit `OBJECT_LOCK_VIOLATION_DETECTED` per `audit_log_policies`.

## Storage Object Lock

The zip bundle in Supabase Storage is under Object Lock per the Stage 1 decision. The Postgres tables here index the bundles; the bytes themselves are in Storage.

Per `object_lock_integration` (Integrations, Block 04): per-bundle Object Lock retention is set at promotion time; extension is per `object_lock_retention_extension_policy`.

## Per-bundle retention

Per the Block 15 scan: each bundle has its own retention timestamp on `archive_packages.object_lock_retention_until`. The whole package is purgeable only when all bundles for the package have aged out.

## Cross-references

- `archive_bundle_layout_schema` — internal zip layout
- `archive_manifest_schemas` (Block 15) — manifest chain query patterns
- `archive_hash_anchor_integration` — RFC 3161 anchoring
- `object_lock_integration` — Object Lock specifics
- `data_layer_conventions_policy` — canonical JSON + SHA-256
- `audit_log_policies` — `ARCHIVE_*` event family + `OBJECT_LOCK_VIOLATION_DETECTED`
- `lock_sequence_policies` — Block 15's write path
- `archive_bundle_policies` — bundle determinism + dedup
- Block 04 Phase 07 — Finalized Secure Archive zone (architecture)
- Block 15 Phase 01 — archive package & locked ledger schema
- Block 15 Phase 07 — Object Lock + three-layer immutability
- Stage 1 decision — separate Postgres schema + Object Lock
