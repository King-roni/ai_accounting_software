# client_multi_name_alias_schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owners:** 04, 08, 10 · **Stage:** 4 sub-doc (Layer 2 schema)

The Stage 2+ schema for clients that operate under multiple names — DBA aliases, post-merger renames, sole traders trading under a brand name, and the everyday case of "Acme Ltd." paying through a personal-name bank account. MVP ships with the `clients.aliases text[]` column on the canonical `clients` table; this sub-doc commits to the Stage 2+ migration path that promotes aliases into a first-class table with lifecycle and audit semantics.

Per Block 13 Phase 02: `tool_clients_registry.get_client_by_name` is the single read surface; MVP consults `clients.aliases`, Stage 2+ consults `client_aliases`. The tool signature does not change across the transition.

---

## MVP shape (current)

A single denormalised column on `clients`:

```sql
ALTER TABLE clients
  ADD COLUMN aliases text[] NOT NULL DEFAULT ARRAY[]::text[];

CREATE INDEX idx_clients_aliases_gin
  ON clients USING gin (aliases);
```

`get_client_by_name(business_id, name_normalized)` returns rows where:

```sql
SELECT id, canonical_name
  FROM clients
 WHERE business_id = $1
   AND (name_normalized = $2 OR $2 = ANY (aliases));
```

Limitations of the MVP shape:
- No per-alias audit (who added it, when, why).
- No alias lifecycle (active / retired / superseded).
- No alias-history reconstruction at a prior point in time.
- Bulk dedup against historical names is awkward because the array is unindexed for range scans.

These limitations are tolerable for MVP volumes but break at Stage 2+ scale.

---

## Stage 2+ shape (deferred)

A first-class `client_aliases` table linked to `clients`:

```sql
CREATE TYPE client_alias_status_enum AS ENUM (
  'ACTIVE',
  'RETIRED',
  'SUPERSEDED'
);

CREATE TYPE client_alias_kind_enum AS ENUM (
  'DBA',                   -- "doing business as" trade name
  'PRIOR_LEGAL_NAME',      -- pre-rename or pre-merger legal name
  'PERSONAL_NAME',         -- sole trader personal name vs business name
  'COMMON_MISSPELLING',    -- recorded misspellings that bank statements use
  'TRANSLATION',           -- transliteration / translation of the canonical name
  'INFERRED'               -- system-inferred from matching memory; user can promote / retire
);

CREATE TABLE client_aliases (
  alias_id                uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id             uuid NOT NULL REFERENCES business_entities(id),
  client_id               uuid NOT NULL REFERENCES clients(id),

  -- The alias text, normalised per vendor_signature_normalization rules.
  alias_text_normalized   text NOT NULL,
  alias_text_raw          text NOT NULL,
  alias_kind              client_alias_kind_enum NOT NULL,

  -- Lifecycle
  status                  client_alias_status_enum NOT NULL DEFAULT 'ACTIVE',
  effective_from          date NOT NULL DEFAULT CURRENT_DATE,
  effective_to            date,                      -- non-null when status != ACTIVE

  -- Canonical-name change linkage (when a former canonical_name becomes an alias)
  superseded_by_canonical_change_id uuid REFERENCES client_canonical_changes(id),

  -- Audit metadata
  added_by_user_id        uuid REFERENCES users(id),
  added_reason            text,
  retired_by_user_id      uuid REFERENCES users(id),
  retired_reason          text,

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_alias_lifecycle_consistency
    CHECK (
      (status = 'ACTIVE'     AND effective_to IS NULL AND retired_by_user_id IS NULL)
      OR
      (status IN ('RETIRED','SUPERSEDED') AND effective_to IS NOT NULL)
    )
);

CREATE UNIQUE INDEX idx_client_aliases_unique_active
  ON client_aliases(business_id, alias_text_normalized)
  WHERE status = 'ACTIVE';

CREATE INDEX idx_client_aliases_client
  ON client_aliases(business_id, client_id, status);
```

A separate `client_canonical_changes` table records canonical-name transitions explicitly:

```sql
CREATE TABLE client_canonical_changes (
  id                      uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id             uuid NOT NULL REFERENCES business_entities(id),
  client_id               uuid NOT NULL REFERENCES clients(id),
  old_canonical_name      text NOT NULL,
  new_canonical_name      text NOT NULL,
  changed_at              timestamptz NOT NULL DEFAULT now(),
  changed_by_user_id      uuid NOT NULL REFERENCES users(id),
  reason                  text NOT NULL
);

CREATE INDEX idx_client_canonical_changes_client
  ON client_canonical_changes(business_id, client_id, changed_at DESC);
```

The partial-unique index on `(business_id, alias_text_normalized) WHERE status = 'ACTIVE'` enforces that no two clients have the same active alias inside one business. Retired aliases can coexist (a name reused later belongs to a new client).

## Alias lifecycle

```
alias added (ACTIVE)
  → canonical name change (existing canonical_name moves to alias_kind = PRIOR_LEGAL_NAME, status = ACTIVE)
  → alias retired (RETIRED — effective_to set; client no longer trades under this name)
  → alias superseded (SUPERSEDED — replaced by another alias via canonical_change)
```

State transitions:

| From | To | Trigger | Audit event |
| --- | --- | --- | --- |
| (none) | `ACTIVE` | `in_workflow.add_client_alias` | `CLIENT_ALIAS_ADDED` |
| `ACTIVE` | `RETIRED` | `in_workflow.retire_client_alias` | `CLIENT_ALIAS_RETIRED` |
| `ACTIVE` | `SUPERSEDED` | `in_workflow.change_client_canonical_name` writes the supersession link | `CLIENT_CANONICAL_NAME_CHANGED` |

Inferred aliases (`alias_kind = INFERRED`) start `ACTIVE` and are subject to user review; the user can confirm (no-op), retire, or convert to a different `alias_kind`. Block 14's review queue surfaces inferred aliases as `Possible Wrong Match` MEDIUM with the recommended-action `Confirm alias` or `Retire alias`.

## Lookup integration

`tool_clients_registry.get_client_by_name` consults aliases identically in both MVP and Stage 2+:

```sql
-- Stage 2+ path
WITH match_active_aliases AS (
  SELECT a.client_id
    FROM client_aliases a
   WHERE a.business_id = $1
     AND a.status = 'ACTIVE'
     AND a.alias_text_normalized = $2
   LIMIT 1
)
SELECT c.id, c.canonical_name
  FROM clients c
 WHERE c.business_id = $1
   AND (
     c.name_normalized = $2
     OR c.id = (SELECT client_id FROM match_active_aliases)
   );
```

The tool emits `CLIENT_ALIAS_LOOKUP_HIT` (in addition to `CLIENT_REGISTRY_LOOKUP`) when a match arrives via the alias path so that downstream forensic queries can distinguish canonical-name hits from alias hits. Both events fire on the business chain per `audit_log_policies` section 4.

## Migration path (MVP → Stage 2+)

The migration is forward-only and runs in one transaction:

```sql
BEGIN;

-- 1. Create the enums and tables (DDL above).

-- 2. Backfill from the existing aliases text[].
INSERT INTO client_aliases (
  alias_id, business_id, client_id,
  alias_text_normalized, alias_text_raw,
  alias_kind, status, effective_from, added_reason
)
SELECT
  gen_uuid_v7(),
  c.business_id,
  c.id,
  unnested.alias_text,
  unnested.alias_text,
  'INFERRED'::client_alias_kind_enum,
  'ACTIVE'::client_alias_status_enum,
  CURRENT_DATE,
  'Backfilled from clients.aliases column'
  FROM clients c
  CROSS JOIN LATERAL unnest(c.aliases) AS unnested(alias_text)
 WHERE c.aliases IS NOT NULL
   AND array_length(c.aliases, 1) > 0;

-- 3. Mark the legacy column as deprecated; drop after one workflow-run cycle.
COMMENT ON COLUMN clients.aliases IS
  'DEPRECATED — superseded by client_aliases table. Read path still allowed; writes rejected by trigger.';

-- 4. Block writes to the legacy column.
CREATE OR REPLACE FUNCTION reject_clients_aliases_write()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.aliases IS DISTINCT FROM OLD.aliases THEN
    RAISE EXCEPTION 'clients.aliases is deprecated; use client_aliases table'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reject_clients_aliases_write
  BEFORE UPDATE ON clients
  FOR EACH ROW EXECUTE FUNCTION reject_clients_aliases_write();

COMMIT;
```

The legacy `clients.aliases` column is retained read-only for one workflow-run cycle (~30 days, per `tool_naming_convention_policy` deprecation window) so any in-flight code paths catch up; then a follow-up migration drops the column and the trigger.

Postgres has no `ALTER TYPE ... DROP VALUE`, so the new `client_alias_kind_enum` and `client_alias_status_enum` are forward-only after creation.

## RLS

Standard tenant isolation per the Block 02 Phase 05 template:

```sql
CREATE POLICY client_aliases_business_isolation ON client_aliases
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));

CREATE POLICY client_canonical_changes_business_isolation ON client_canonical_changes
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

## Mobile rejection

Per `mobile_write_rejection_endpoints`: `in_workflow.add_client_alias`, `in_workflow.retire_client_alias`, and `in_workflow.change_client_canonical_name` all reject `client_form_factor = MOBILE` with HTTP 403 + `MOBILE_WRITE_REJECTED`. Alias lookups via `tool_clients_registry.get_client_by_name` are read-only and allowed on mobile.

## Identifier and serialization conventions

Per `data_layer_conventions_policy`:
- `alias_id`, `client_canonical_changes.id` use UUID v7 (B-tree-friendly, time-prefixed).
- Normalisation of `alias_text_normalized` follows `vendor_signature_normalization` rules — bytes-equal-bytes after lowercase, trim, and collapse-whitespace.
- Audit `event_payload_canonical_json` for every alias event follows RFC 8785 ordering.

## Audit events

| Event | When |
| --- | --- |
| `CLIENT_ALIAS_ADDED` | A new alias row is INSERTed (ACTIVE) |
| `CLIENT_ALIAS_RETIRED` | An alias transitions ACTIVE → RETIRED |
| `CLIENT_CANONICAL_NAME_CHANGED` | A `client_canonical_changes` row is INSERTed; ACTIVE → SUPERSEDED on the prior canonical |
| `CLIENT_ALIAS_LOOKUP_HIT` | `get_client_by_name` matches via alias path, not canonical |

## Cross-references

- `tool_clients_registry` — consumer of the alias table at `get_client_by_name` time
- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON
- `audit_log_policies` — `<DOMAIN>_<PAST_VERB>` convention, RLS, chain partitioning
- `vendor_signature_normalization` — alias text normalisation rules (shared with Block 08's vendor memory)
- Block 13 Phase 02 — client database architecture
- Block 10 Phase 08 — IN-side matcher consults the registry for counterparty resolution
- `mobile_write_rejection_endpoints` — write endpoints reject MOBILE

## Open items deferred

- The promotion of `INFERRED` aliases to a user-confirmed kind through the review queue card — Stage 2+ UX sub-doc.
- Cross-business client matching (the same legal entity appearing in two unrelated businesses) — out of MVP scope per tenant isolation rules.
- Soft-deletion semantics for `client_canonical_changes` history under GDPR erasure — handled by `Docs/sub/policies/redaction_at_write_policy` pseudonymisation path.
