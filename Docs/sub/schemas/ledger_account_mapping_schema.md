# ledger_account_mapping_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `ledger_account_mappings` table, which maps discriminator tuples of `(transaction_type, vat_treatment, counterparty_country_class, custom_tag_id)` to debit and credit account codes in the chart of accounts. It also defines the resolution priority algorithm, the version-freeze semantics that preserve replay safety for finalized periods, and the fallback rule. Every tool in the `ledger` namespace that prepares a draft ledger entry reads this table.

---

## Table definition

```sql
CREATE TYPE counterparty_country_class_enum AS ENUM (
  'CYPRUS',
  'EU',
  'NON_EU',
  'ANY'
);

CREATE TABLE ledger_account_mappings (
  mapping_id                    uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                   uuid        NOT NULL REFERENCES business_entities(id),
  chart_version_id              uuid        NOT NULL REFERENCES chart_of_accounts_mapping_versions(id),
  rule_priority                 integer     NOT NULL DEFAULT 100,      -- lower integer wins
  transaction_type              transaction_type_enum,                  -- nullable = applies to any type
  vat_treatment                 vat_treatment_enum,                     -- nullable = applies to any treatment
  counterparty_country_class    counterparty_country_class_enum,        -- nullable = ANY; explicit ANY also permitted
  custom_tag_id                 uuid        REFERENCES tags(tag_id),    -- nullable = no tag constraint
  debit_account_code            text        NOT NULL REFERENCES chart_of_accounts(code),
  credit_account_code           text        NOT NULL REFERENCES chart_of_accounts(code),
  is_default                    boolean     NOT NULL DEFAULT false,
  is_active                     boolean     NOT NULL DEFAULT true,
  created_by_user_id            uuid        REFERENCES users(id),
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now()
);
```

### Column notes

- `mapping_id` — UUID v7 per `data_layer_conventions_policy §2`.
- `chart_version_id` — FK to `chart_of_accounts_mapping_versions.id` (Block 11 Phase 01). Every mapping belongs to a specific chart version. Finalized periods freeze this version (see version-freeze semantics below).
- `rule_priority` — lower integer wins on tie-break after specificity ordering. The primary resolution mechanism is most-specific-match (see resolution priority ordering below); `rule_priority` is the secondary tie-breaker when two rules have equal specificity.
- `transaction_type` — nullable; references `transaction_type_enum`. Null means "applies to any transaction type." Must be one of the 12 closed values when non-null; do not add values to `transaction_type_enum`.
- `vat_treatment` — nullable; references `vat_treatment_enum`. Null means "applies to any VAT treatment." Must be one of the 8 closed values when non-null; do not add values to `vat_treatment_enum`.
- `counterparty_country_class` — nullable; references `counterparty_country_class_enum`. `NULL` and `ANY` are semantically equivalent (both mean "no country constraint") — `ANY` is preferred for explicit default rules; `NULL` is accepted for rules where the author did not specify.
- `custom_tag_id` — nullable FK to `tags.tag_id`. When non-null, the rule applies only when the transaction carries this tag as its primary tag.
- `debit_account_code` / `credit_account_code` — both required; must reference active codes in `chart_of_accounts`. The FK enforces referential integrity; a disabled account code is still a valid FK target (accounts are disabled, not deleted), but the UI warns when a new mapping references a disabled account.
- `is_default` — marks the fallback rule for this `chart_version_id`. Exactly one active default rule per `chart_version_id` per `entry_kind` (enforced by application-layer validation, not a DB partial index — the entry_kind dimension makes a DB partial index unwieldy).
- `is_active` — soft-deactivation; inactive rules are never evaluated.

---

## Resolution priority ordering

When `ledger.prepare_entries` (Block 11 Phase 07) resolves the debit/credit accounts for a draft ledger entry, it applies the following algorithm:

### Step 1 — Compute specificity score

Each candidate rule's specificity is the count of its non-null discriminator columns:

| Discriminator column | Non-null contribution |
|---|---|
| `transaction_type` | +1 |
| `vat_treatment` | +1 |
| `counterparty_country_class` (excluding `ANY` and NULL) | +1 |
| `custom_tag_id` | +1 |

Maximum specificity: 4 (all four discriminators non-null / non-ANY).

### Step 2 — Select candidates

Query for all active rules in the current `chart_version_id` where each non-null discriminator matches the draft entry's values (NULL discriminators match any value):

```sql
SELECT *
FROM ledger_account_mappings
WHERE business_id = $1
  AND chart_version_id = $2
  AND is_active = true
  AND (transaction_type IS NULL OR transaction_type = $3)
  AND (vat_treatment IS NULL OR vat_treatment = $4)
  AND (counterparty_country_class IS NULL
       OR counterparty_country_class = 'ANY'
       OR counterparty_country_class = $5)
  AND (custom_tag_id IS NULL OR custom_tag_id = $6)
ORDER BY
  (CASE WHEN transaction_type IS NOT NULL THEN 1 ELSE 0 END +
   CASE WHEN vat_treatment IS NOT NULL THEN 1 ELSE 0 END +
   CASE WHEN counterparty_country_class IS NOT NULL
          AND counterparty_country_class != 'ANY' THEN 1 ELSE 0 END +
   CASE WHEN custom_tag_id IS NOT NULL THEN 1 ELSE 0 END) DESC,
  rule_priority ASC,
  mapping_id ASC
LIMIT 1;
```

### Step 3 — Fallback

If no non-default rule matches, the resolver falls back to the `is_default = true` rule for the `chart_version_id`. If no default rule exists, `ledger.prepare_entries` writes `NULL` to both account codes, sets `requires_accountant_review = true` on the draft entry with reason `"No mapping rule matched and no default rule found."`, and emits a `LEDGER_ACCOUNTANT_REVIEW_FLAGGED` event.

---

## Version-freeze semantics

When Block 15 finalizes a period, the `chart_of_accounts_mapping_versions` row active at lock time is frozen:

1. Block 15 Phase 03 calls `ledger.freeze_chart_version` which sets `frozen_at = now()` on the `chart_of_accounts_mapping_versions` row.
2. Every `locked_ledger_entries` row in the archive carries the `chart_version_id` frozen at lock time.
3. After `frozen_at` is set, no write operations to `ledger_account_mappings` rows referencing that `chart_version_id` are permitted. The application layer enforces this by checking `frozen_at IS NOT NULL` before allowing mutations; the DB enforces it via a trigger:

```sql
CREATE OR REPLACE FUNCTION prevent_frozen_mapping_update()
RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM chart_of_accounts_mapping_versions
    WHERE id = NEW.chart_version_id AND frozen_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Cannot modify mapping rules for a frozen chart version.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_frozen_mapping_update
  BEFORE INSERT OR UPDATE ON ledger_account_mappings
  FOR EACH ROW EXECUTE FUNCTION prevent_frozen_mapping_update();
```

This ensures that re-running the ledger preparation for a finalized period always produces identical account codes.

---

## Indexes

```sql
-- Primary resolution lookup
CREATE INDEX idx_ledger_mappings_version_active
  ON ledger_account_mappings (business_id, chart_version_id, is_active)
  WHERE is_active = true;

-- Default rule lookup
CREATE INDEX idx_ledger_mappings_default
  ON ledger_account_mappings (business_id, chart_version_id)
  WHERE is_default = true AND is_active = true;

-- Tag-specific rules
CREATE INDEX idx_ledger_mappings_tag
  ON ledger_account_mappings (business_id, custom_tag_id)
  WHERE custom_tag_id IS NOT NULL AND is_active = true;
```

---

## RLS

```sql
CREATE POLICY ledger_mappings_isolation ON ledger_account_mappings
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `LEDGER_MAPPING_CREATED` | New mapping rule inserted | LOW |
| `LEDGER_MAPPING_UPDATED` | Mapping rule predicate or account codes changed | LOW |
| `LEDGER_MAPPING_VERSION_FROZEN` | `chart_of_accounts_mapping_versions.frozen_at` set by Block 15 finalization | LOW |

All events emitted via `emitAudit()` per `audit_log_policies` and exist in `audit_event_taxonomy`.

Note: `CHART_MAPPING_VERSION_CREATED` and `CHART_MAPPING_VERSION_FROZEN` (declared in Block 11 Phase 01) cover the chart-version lifecycle. The events here cover the per-rule mutations. `LEDGER_MAPPING_VERSION_FROZEN` is the `LEDGER_*` domain emit that parallels `CHART_MAPPING_VERSION_FROZEN`; both are emitted during finalization (the former by the ledger layer, the latter by the chart layer).

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK
- `audit_log_policies` — `LEDGER_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `LEDGER_MAPPING_CREATED`, `LEDGER_MAPPING_UPDATED`, `LEDGER_MAPPING_VERSION_FROZEN`
- `transaction_type_enum` — closed 12-value enum; `transaction_type` discriminator
- `vat_treatment_enum` — closed 8-value enum; `vat_treatment` discriminator
- `chart_of_accounts_schema` — `chart_of_accounts` and `chart_of_accounts_mapping_versions` tables
- Block 11 Phase 01 — ledger schema foundation; `draft_ledger_entries`, `chart_of_accounts`, `chart_of_accounts_mapping_versions` table definitions
- Block 11 Phase 03 — chart-of-accounts customization (creates and updates mapping rules)
- Block 11 Phase 07 — type-aware ledger preparation dispatcher (primary consumer of this table)
- Block 15 Phase 03 — period finalization (triggers version freeze)
- `tool_naming_convention_policy` — `ledger.*` namespace for all tools referencing this schema
