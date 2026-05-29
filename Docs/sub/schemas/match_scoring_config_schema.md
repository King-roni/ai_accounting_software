# match_scoring_configs schema

**Category:** Schemas · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

Per-business overrides to the default match signal weights used by the matching engine. When an active config row exists for a business, its weights replace the global defaults from `match_signal_weights.md`. When no active config exists, the global defaults apply.

---

## Table: `match_scoring_configs`

```sql
CREATE TABLE match_scoring_configs (
  id                          uuid          NOT NULL DEFAULT gen_uuid_v7()
                                            PRIMARY KEY,
  business_id                 uuid          NOT NULL
                                            REFERENCES business_entities(id),
  config_version              integer       NOT NULL DEFAULT 1,

  -- Signal weights (must sum to 1.0000)
  amount_delta_weight         numeric(5,4)  NOT NULL DEFAULT 0.4000,
  date_proximity_weight       numeric(5,4)  NOT NULL DEFAULT 0.3000,
  counterparty_match_weight   numeric(5,4)  NOT NULL DEFAULT 0.2000,
  reference_string_match_weight numeric(5,4) NOT NULL DEFAULT 0.1000,

  -- Generated column: sum of all four weights (stored for constraint + query)
  weight_sum_check            numeric(5,4)  GENERATED ALWAYS AS (
                                amount_delta_weight
                                + date_proximity_weight
                                + counterparty_match_weight
                                + reference_string_match_weight
                              ) STORED,

  -- Lifecycle
  is_active                   boolean       NOT NULL DEFAULT true,
  activated_at                timestamptz   NOT NULL DEFAULT now(),
  activated_by_user_id        uuid          NOT NULL REFERENCES users(id),
  deactivated_at              timestamptz   NULL,
  notes                       text          NULL,

  -- Audit timestamps
  created_at                  timestamptz   NOT NULL DEFAULT now(),
  updated_at                  timestamptz   NOT NULL DEFAULT now()
);
```

---

## Constraints

### Weight sum integrity

```sql
ALTER TABLE match_scoring_configs
  ADD CONSTRAINT match_scoring_configs_weight_sum_equals_one
  CHECK (weight_sum_check = 1.0000);
```

This constraint is enforced at INSERT and UPDATE time by Postgres. Any configuration that does not produce weights summing to exactly 1.0000 is rejected at the database layer. If the application layer detects a deviation via `MATCHING_SCORING_CONFIG_INVALID` before the INSERT is attempted, the workflow run is halted without a DB round-trip.

### Single active config per business

```sql
CREATE UNIQUE INDEX match_scoring_configs_one_active_per_business
  ON match_scoring_configs (business_id)
  WHERE is_active = true;
```

Only one active config is allowed per business at any time. To replace an active config, deactivate the existing row (`is_active = false`, `deactivated_at = now()`) before inserting the new one. The uniqueness constraint is a partial index rather than a full unique constraint so that historical (inactive) rows are not constrained.

---

## Default weights

| Signal | Default weight | Rationale |
| --- | --- | --- |
| `amount_delta` | 0.4000 (40%) | Amount proximity is the strongest single signal for expense matching |
| `date_proximity` | 0.3000 (30%) | Transaction date vs. invoice date drives 30% of the score |
| `counterparty_match` | 0.2000 (20%) | Counterparty name/VAT match contributes 20% |
| `reference_string_match` | 0.1000 (10%) | Free-text reference field match is weakest; contributes 10% |
| **Sum** | **1.0000** | Required invariant |

These defaults are also the values used when no active config row exists for a business (global fallback via `match_signal_weights.md`). A business-level config row with identical weights to the defaults is valid but redundant.

---

## Column reference

| Column | Type | Nullable | Description |
| --- | --- | --- | --- |
| `id` | uuid | NOT NULL | UUID v7 primary key. gen_uuid_v7() default. |
| `business_id` | uuid | NOT NULL | FK to `business_entities.id`. Tenant isolation key. |
| `config_version` | integer | NOT NULL | Monotonically increasing version counter within a business. Callers increment this on each new config row. |
| `amount_delta_weight` | numeric(5,4) | NOT NULL | Weight assigned to the amount-delta signal (0.0000–1.0000). |
| `date_proximity_weight` | numeric(5,4) | NOT NULL | Weight assigned to the date-proximity signal (0.0000–1.0000). |
| `counterparty_match_weight` | numeric(5,4) | NOT NULL | Weight assigned to the counterparty-match signal (0.0000–1.0000). |
| `reference_string_match_weight` | numeric(5,4) | NOT NULL | Weight assigned to the reference-string-match signal (0.0000–1.0000). |
| `weight_sum_check` | numeric(5,4) | GENERATED | Stored generated column; always equals the sum of the four weight columns. Used by the CHECK constraint. |
| `is_active` | boolean | NOT NULL | `true` if this config is currently in use for the business. At most one active row per business (partial unique index). |
| `activated_at` | timestamptz | NOT NULL | When this config became active. Defaults to `now()` at insert. |
| `activated_by_user_id` | uuid | NOT NULL | FK to `users.id`. The user who created/activated this config. Required for audit trail. |
| `deactivated_at` | timestamptz | NULL | Set when `is_active` transitions to `false`. Null for the active row. |
| `notes` | text | NULL | Optional free-text annotation describing the rationale for this config (max 1000 chars recommended). |
| `created_at` | timestamptz | NOT NULL | Row creation timestamp. |
| `updated_at` | timestamptz | NOT NULL | Last update timestamp. Maintained by an `AFTER UPDATE` trigger. |

---

## Indexes

```sql
-- Primary lookup: resolve active config for a business
CREATE INDEX match_scoring_configs_business_id_idx
  ON match_scoring_configs (business_id);

-- Ordered config history per business
CREATE INDEX match_scoring_configs_business_version_idx
  ON match_scoring_configs (business_id, config_version DESC);
```

---

## Row-level security

RLS tenant isolation is enforced on `business_id`:

```sql
ALTER TABLE match_scoring_configs ENABLE ROW LEVEL SECURITY;

CREATE POLICY match_scoring_configs_tenant_isolation
  ON match_scoring_configs
  USING (business_id = current_setting('app.current_business_id')::uuid);
```

Platform admin role bypasses RLS per the standard `BYPASSRLS` pattern in `rls_helper_functions.md`.

---

## Fallback resolution

The matching engine resolves the scoring config for a business as follows:

1. Query `match_scoring_configs WHERE business_id = $1 AND is_active = true`.
2. If a row is found, use its four weight columns.
3. If no row is found, fall back to the global default weights defined in `match_signal_weights.md`.

The fallback is implemented in the matching engine's config loader, not in SQL. No sentinel row is inserted for businesses with no custom config.

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `MATCHING_SCORING_CONFIG_UPDATED` | LOW | A new `match_scoring_configs` row is activated for a business |
| `MATCHING_SCORING_CONFIG_INVALID` | BLOCKING | `weight_sum_check` deviates from 1.0000 (detected before INSERT or during run validation) |

`MATCHING_SCORING_CONFIG_UPDATED` payload: `config_id`, `business_id`, `config_version`, `amount_delta_weight`, `date_proximity_weight`, `counterparty_match_weight`, `reference_string_match_weight`, `activated_by_user_id`.

`MATCHING_SCORING_CONFIG_INVALID` payload: `business_id`, `workflow_run_id`, `weight_sum_found`, `expected_sum`, `deviation`. Emitted by the matching engine's pre-run config validation step when the stored `weight_sum_check` value diverges from 1.0000 (possible only if the DB constraint was bypassed via a migration or direct DB write).

---

## Cross-references

- `match_signal_weights.md` — global default weights applied when no active config row exists
- `match_scoring_calibration_policy.md` — calibration process that produces new weight values
- `match_scoring_weights_policy.md` — policy governing when and how weights may be customised per business
- `matching_policy.md` — matching engine architecture and signal definitions
- `audit_event_taxonomy.md` — `MATCHING_SCORING_CONFIG_UPDATED`, `MATCHING_SCORING_CONFIG_INVALID`
- `rls_helper_functions.md` — standard RLS helper patterns
