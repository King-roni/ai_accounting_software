# chart_of_accounts_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 11 — Ledger & Cyprus VAT Engine · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The chart-of-accounts table + the version-tag mechanics that pin a chart version per workflow run. Per Stage 1: "Default chart of accounts: Adopt a Cyprus-friendly standard chart shipped with the product; allow per-business customization."

Per Block 11 Phase 03's pre-finalization invariant: every `draft_ledger_entries` row in a period must share a single `chart_mapping_version_id` before Block 15 sees it. This schema declares the version table and the per-business customization mechanism.

---

## Tables

### `chart_mapping_versions`

```sql
CREATE TABLE chart_mapping_versions (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL REFERENCES business_entities(id),
  version_label               text NOT NULL,                        -- e.g., "Cyprus default v1", "Cyprus default v1 + custom 2026-01"
  is_default                  boolean NOT NULL DEFAULT false,
  effective_from              timestamptz NOT NULL,
  effective_until             timestamptz,                          -- NULL = current
  source_kind                 text NOT NULL,                        -- 'CYPRUS_DEFAULT' | 'PER_BUSINESS_CUSTOMIZATION'
  base_version_id             uuid REFERENCES chart_mapping_versions(id),  -- parent version for customizations
  created_by_user_id          uuid REFERENCES users(id),
  created_at                  timestamptz NOT NULL DEFAULT now(),

  UNIQUE (business_id, is_default) DEFERRABLE INITIALLY DEFERRED   -- at most one is_default per business
);
```

## Canonical DDL

The `account_type_enum` type and `chart_of_accounts` table DDL are defined in `ledger_account_chart_schema.md`. This file previously contained a conflicting definition; it has been removed. See `ledger_account_chart_schema.md` for all column definitions, indexes, and RLS policies.

`account_type_enum` canonical values: ASSET · LIABILITY · EQUITY · REVENUE · EXPENSE · VAT_CONTROL

Note: the sixth enum value is `VAT_CONTROL` (not `OFF_BALANCE`). Cyprus VAT control accounts are distinct system accounts used for VAT rate tracking; they require their own account type rather than an off-balance classification.

## Version semantics

Per Block 11 Phase 03: at workflow-run creation, the `principal_context_snapshot_json` (on `workflow_runs`) records the active `chart_mapping_version_id`. Throughout the run's lifetime, `prepare_entries` and other Block 11 tools use that pinned version — even if `is_default` changes during the run.

### Per-business customization

Per Stage 1 + Block 11 Phase 03:

1. Each business starts with `source_kind = 'CYPRUS_DEFAULT'` — a copy of the Cyprus default chart shipped with the product
2. Per-business customizations create a new version with `source_kind = 'PER_BUSINESS_CUSTOMIZATION'` and `base_version_id` pointing at the prior version
3. New transactions classify against the latest `is_default = true` version
4. Existing finalized data continues to reference its pinned version

### Pre-finalization invariant

Per Block 11 Phase 03 (canonical):

```sql
-- Inside Block 15 lock-sequence step 1 (snapshot), this query must return 0:
SELECT COUNT(DISTINCT chart_mapping_version_id)
FROM draft_ledger_entries
WHERE business_id = $business_id
  AND period_start = $period_start
  AND period_end = $period_end;
```

If the count is > 1, the lock sequence rejects with `LEDGER_VERSION_INCONSISTENT`. Block 11 Phase 09's `recompute_ledger_entries` (per `ledger_recompute_side_effects_policy`) is invoked to bring every row to the latest version before finalization.

### Backdated edits (Stage 2+)

Per `backdated_chart_edit_policy` (merged into `data_layer_conventions_policy` cross-references): backdated edits to chart customizations (effective_from < now()) are a Stage 2+ feature. MVP rejects them; new versions take effect prospectively only.

## Default Cyprus chart

The shipped default chart lives in `cyprus_default_chart_catalog` (Reference data, Block 11) and seeds `chart_mapping_versions` + `chart_of_accounts` for each new business at signup time. The default has ~80 accounts covering standard Cyprus business needs.

## Audit events

| Event | When |
| --- | --- |
| `CHART_MAPPING_VERSION_CREATED` | New version row inserted |
| `CHART_ACCOUNT_ADDED` | Per-account customization (INSERT) |
| `CHART_ACCOUNT_RETIRED` | Account retired (UPDATE setting retired_at) |
| `CHART_DEFAULT_VERSION_CHANGED` | `is_default` flag moves to a new version |

All emissions are per `audit_log_policies`.

## Indexes

```sql
CREATE INDEX idx_chart_accounts_business_version_code
  ON chart_of_accounts(business_id, chart_mapping_version_id, account_code);

CREATE INDEX idx_chart_versions_business_default
  ON chart_mapping_versions(business_id, is_default)
  WHERE is_default = true;

CREATE INDEX idx_chart_accounts_active
  ON chart_of_accounts(chart_mapping_version_id)
  WHERE active = true;
```

## RLS

Tenant isolation per `permission_matrix`. Per-business read for any role with business access; per-business write only for Owner / Admin via `BUSINESS_SETTINGS_EDIT` surface:

```sql
CREATE POLICY chart_accounts_read ON chart_of_accounts
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

CREATE POLICY chart_accounts_write ON chart_of_accounts
  FOR INSERT, UPDATE, DELETE
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.has_surface(business_id, 'BUSINESS_SETTINGS_EDIT')
  );
```

Mobile rejection for writes: REJECT per `mobile_write_rejection_endpoints` (settings is desktop-only).

## Cross-references

- `cyprus_default_chart_catalog` (Block 11 Reference data) — the shipped Cyprus default chart content
- `vat_treatment_enum` — `vat_treatment_hint` enum
- `vies_record_format` — `vies_eligible` consumer
- `cyprus_deductibility_table` — deductibility mapping per Cyprus VAT rules
- `tag_to_account_convention` — how primary tags map to chart accounts
- `version_pin_resolution_schema` (Block 11) — chart_mapping_version_id resolution SQL
- `ledger_recompute_side_effects_policy` — replace-on-recompute semantics
- `audit_log_policies` — `CHART_*` event family
- `permission_matrix` — `BUSINESS_SETTINGS_EDIT` surface for chart customization
- `mobile_write_rejection_endpoints` — settings is desktop-only
- Block 04 Phase 04 — chart_of_accounts ownership home
- Block 11 Phase 02 — default Cyprus chart of accounts (architecture)
- Block 11 Phase 03 — per-business chart customization & versioning
- Stage 1 decision — Cyprus-friendly default + per-business customization

## Related Documents

- `ledger_account_chart_schema.md` — canonical `chart_of_accounts` table DDL and `account_type_enum` definition; this file defers all column definitions, indexes, and RLS to that document
- `ledger_entry_schema.md` — `ledger_entries` table; FK to `chart_of_accounts` via `account_code` and `chart_mapping_version_id`

## RLS Policies

Row-level security for `chart_mapping_versions` is inherited from `business_entities`; see `row_level_security_policies.md`. The `chart_of_accounts` RLS policies are defined in `ledger_account_chart_schema.md` and follow the same tenant-isolation pattern: read access for any role with business membership, write access gated by the `BUSINESS_SETTINGS_EDIT` surface.
