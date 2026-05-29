# tag_taxonomy_version_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `tag_taxonomy_versions` and `tags` tables, the default-flag uniqueness constraint, and the retirement semantics that keep historical records stable when the active taxonomy evolves. Per the Stage 1 decision, finalized periods preserve the taxonomy version active at finalization; new runs use the latest version. Tags can be retired but never hard-deleted.

---

## `tag_taxonomy_versions` table

```sql
CREATE TABLE tag_taxonomy_versions (
  taxonomy_version_id       uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id               uuid        REFERENCES business_entities(id),   -- null = platform-wide default version
  version_number            integer     NOT NULL,                    -- monotonically increasing per business (or per platform for global)
  definition                jsonb       NOT NULL,                    -- array of tag definition objects (see below)
  is_default                boolean     NOT NULL DEFAULT false,
  created_at                timestamptz NOT NULL DEFAULT now(),
  created_by_user_id        uuid        REFERENCES users(id),
  retired_at                timestamptz,                            -- null = active; non-null = no longer assignable to new runs
  CONSTRAINT uq_version_number_per_scope
    UNIQUE (business_id, version_number)                            -- NULL business_id uses a single global scope enforced by partial index
);
```

### Default-flag uniqueness constraint

Exactly one taxonomy version may be the default for any given business (or for the global scope). This is enforced by a partial unique index:

```sql
CREATE UNIQUE INDEX idx_taxonomy_version_default_per_business
  ON tag_taxonomy_versions (business_id)
  WHERE is_default = true;
```

For the global scope (`business_id IS NULL`), the partial index enforces that at most one row with `business_id IS NULL AND is_default = true` exists. Postgres treats `NULL` values as distinct in standard unique indexes but the partial index approach here covers a single-row constraint correctly because the predicate `WHERE is_default = true` already filters to the candidate set.

Promoting a new default requires first clearing `is_default = false` on the current default version, then setting the new version's flag — both in a single transaction. The audit event `CLASSIFICATION_TAG_TAXONOMY_VERSION_CREATED` is emitted for the new version; a separate `CLASSIFICATION_TAG_TAXONOMY_VERSION_CREATED` event with `promoted_to_default: true` is not split into two events (the creation event carries a `is_default` field in its payload).

### `version_number` monotonicity

`version_number` is a monotonically increasing integer scoped to `(business_id)`. The application assigns `MAX(version_number) + 1` for the scope at creation time inside a serializable transaction. There is no auto-increment column — the explicit integer is needed for ordering in historical references (e.g., "this finalized period used taxonomy version 3").

### `definition` JSONB structure

The `definition` column holds an array of tag objects, one per tag in this version of the taxonomy:

```json
[
  {
    "tag_id": "<uuid v7 string>",
    "label": "Travel & Accommodation",
    "description": "Business travel including flights, hotels, and ground transport.",
    "maps_to_transaction_type": "OUT_EXPENSE",
    "is_active": true
  }
]
```

Field rules:
- `tag_id` — UUID v7 string. Must match the corresponding `tags.tag_id` row (enforced at write time by `classification.create_taxonomy_version`).
- `label` — required; non-empty string; max 120 characters; unique within the definition array (enforced at application layer, not DB constraint).
- `description` — required; max 500 characters.
- `maps_to_transaction_type` — required; one of the 12 values from `transaction_type_enum`. Every tag in the taxonomy maps to exactly one transaction type (Stage 1 decision).
- `is_active` — boolean; `false` marks a retired tag within this version's definition. Retired tags remain in the definition for historical rendering purposes.

The `definition` array is the canonical snapshot of the taxonomy at that version. Block 08 Phase 08's `workflow_runs.classification_taxonomy_snapshot` captures a defensive copy of this array at run start; the snapshot is independent of any subsequent edits to the live `definition`.

---

## `tags` table

```sql
CREATE TABLE tags (
  tag_id                    uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id               uuid        REFERENCES business_entities(id),   -- null = platform-wide tag
  taxonomy_version_id       uuid        NOT NULL REFERENCES tag_taxonomy_versions(taxonomy_version_id),
  label                     text        NOT NULL,
  maps_to_transaction_type  transaction_type_enum NOT NULL,
  is_custom                 boolean     NOT NULL DEFAULT false,       -- true for per-business additions
  is_active                 boolean     NOT NULL DEFAULT true,
  created_at                timestamptz NOT NULL DEFAULT now(),
  created_by_user_id        uuid        REFERENCES users(id),
  retired_at                timestamptz,                            -- null = active; non-null = soft-retired

  CONSTRAINT uq_tag_label_per_scope
    UNIQUE (business_id, label)                                     -- label unique within (business_id) scope
);
```

### Column notes

- `tag_id` — UUID v7 per `data_layer_conventions_policy §2`. The same `tag_id` appears in both this table and in the `definition` array of the `tag_taxonomy_versions` row that owns it.
- `taxonomy_version_id` — the taxonomy version in which this tag was introduced. A tag is introduced in exactly one version. If a later version promotes the same label, it receives a new `tag_id` (tags are version-scoped, not version-independent).
- `maps_to_transaction_type` — one of the 12 values from `transaction_type_enum`. `UNKNOWN` is not a valid mapping; a tag cannot map to the unclassified placeholder.
- `is_custom` — `true` for per-business custom tags created by the business owner; `false` for tags seeded from the platform default taxonomy.
- `is_active` / `retired_at` — see retirement semantics below.
- `label` uniqueness: the `UNIQUE (business_id, label)` constraint applies within a business scope. Global platform tags (`business_id IS NULL`) have a separate uniqueness scope. Case-sensitivity: labels are stored with original casing but compared case-insensitively at validation time (Block 08 Phase 06 calls `lower(label)` before the unique check; a tag "Travel" and "travel" cannot coexist in the same scope).

---

## Retirement semantics

Tags can be retired (set `is_active = false`, `retired_at = now()`). They are never deleted in MVP. The rules:

1. **Finalized periods are immutable.** Once Block 15 finalizes a period, the taxonomy version and its tags are frozen. The `tag_id` values on `transactions` rows in that period reference the version active at finalization — this reference never changes, even if the tag is later retired.

2. **In-flight runs use their snapshot.** Per Block 08 Phase 08, each workflow run captures the active taxonomy at start (`classification_taxonomy_snapshot`). Retirement during a run has no effect on that run; the snapshot carries the tag as active. The retirement takes effect for the next run.

3. **Vendor-memory references to retired tags.** When `recurring_vendor_memory` suggests a tag and that tag has since been retired, Block 08 Phase 06 appends a `(retired)` marker to the suggestion label in the review-queue card. The suggestion is still shown (vendor memory is preserved) but the user is prompted to select a current active tag.

4. **Retirement does not cascade.** Retiring a tag does not retire the taxonomy version. A version may contain a mix of active and retired tags and remain the active default version.

5. **Re-activation is permitted.** A retired tag may be re-activated by setting `is_active = true` and clearing `retired_at`. This is an Owner action, audit-logged as `CLASSIFICATION_TAG_RETIRED` with a `reactivated: true` payload field. Re-activation does not emit a separate event name.

---

## Indexes

```sql
-- Active tags per taxonomy version
CREATE INDEX idx_tags_taxonomy_active
  ON tags (taxonomy_version_id, is_active)
  WHERE is_active = true;

-- Business custom tags lookup
CREATE INDEX idx_tags_business_custom
  ON tags (business_id, is_custom, is_active)
  WHERE is_custom = true;

-- Transaction type lookup (for classifier dispatching)
CREATE INDEX idx_tags_transaction_type
  ON tags (maps_to_transaction_type, business_id)
  WHERE is_active = true;
```

---

## RLS

```sql
CREATE POLICY tag_taxonomy_versions_isolation ON tag_taxonomy_versions
  FOR ALL
  USING (
    business_id IS NULL
    OR business_id = ANY (auth.business_ids_for_session())
  );

CREATE POLICY tags_isolation ON tags
  FOR ALL
  USING (
    business_id IS NULL
    OR business_id = ANY (auth.business_ids_for_session())
  );
```

Global platform tags and taxonomy versions (`business_id IS NULL`) are readable by all authenticated sessions. Only platform admins may write global rows (enforced via Block 02 Phase 04 `canPerform`).

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `CLASSIFICATION_TAG_TAXONOMY_VERSION_CREATED` | New taxonomy version row inserted | LOW |
| `CLASSIFICATION_TAG_CREATED` | New tag row inserted | LOW |
| `CLASSIFICATION_TAG_RETIRED` | Tag `is_active` set to `false` (or re-activated) | LOW |

All events emitted via `emitAudit()` per `audit_log_policies` and exist in `audit_event_taxonomy`.

Note: `TAG_TAXONOMY_VERSION_BUMPED` and `CUSTOM_TAG_RETIRED` (existing taxonomy entries from Block 08 Phase 08) cover the workflow-run-level taxonomy snapshot events. The events defined here cover the underlying schema mutation events (creating a version row, creating a tag row, retiring a tag). These are complementary, not duplicates.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; canonical JSON for `definition` JSONB
- `audit_log_policies` — `CLASSIFICATION_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `CLASSIFICATION_TAG_TAXONOMY_VERSION_CREATED`, `CLASSIFICATION_TAG_CREATED`, `CLASSIFICATION_TAG_RETIRED`
- `transaction_type_enum` — closed 12-value enum; `maps_to_transaction_type` must be a value from this enum
- `transactions_schema` — `primary_tag_id`, `primary_tag_taxonomy_version_id`, `secondary_tag_ids` columns on `transactions`
- `transaction_tag_columns_schema` — tag columns on `transactions` table
- Block 08 Phase 01 — classification schema foundation
- Block 08 Phase 05 — default taxonomy definition
- Block 08 Phase 06 — custom tags and per-business overrides
- Block 08 Phase 08 — taxonomy version snapshots on workflow runs
- `tool_naming_convention_policy` — `classification.*` namespace for all tools referencing this schema
