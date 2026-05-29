# Schema: matching_scoring_configs

**Block:** Matching
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`matching_scoring_configs` stores per-business matching configuration. Each business entity may have at most one row — enforced by a UNIQUE constraint on `business_entity_id`. If no row exists for a business, the matching engine falls back to the platform-level defaults defined in `matching_engine_policy.md`.

The configuration controls the confidence thresholds that determine `match_level_enum` assignment, the date and amount tolerance windows, and the relative weighting of the three scoring signals (amount, description, date). The weights must sum to exactly 1.00 — this is enforced by a check constraint.

---

## DDL

```sql
CREATE TABLE matching_scoring_configs (
  id                          UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id          UUID          NOT NULL
                                REFERENCES business_entities(id)
                                ON DELETE RESTRICT,
  exact_match_threshold       NUMERIC(4,2)  NOT NULL DEFAULT 0.95,
  strong_probable_threshold   NUMERIC(4,2)  NOT NULL DEFAULT 0.80,
  weak_possible_threshold     NUMERIC(4,2)  NOT NULL DEFAULT 0.60,
  date_tolerance_days         INTEGER       NOT NULL DEFAULT 3,
  amount_tolerance_percent    NUMERIC(4,2)  NOT NULL DEFAULT 1.00,
  description_weight          NUMERIC(4,2)  NOT NULL DEFAULT 0.40,
  amount_weight               NUMERIC(4,2)  NOT NULL DEFAULT 0.40,
  date_weight                 NUMERIC(4,2)  NOT NULL DEFAULT 0.20,
  created_at                  TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at                  TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT matching_scoring_configs_pkey PRIMARY KEY (id),

  CONSTRAINT matching_scoring_configs_business_entity_id_unique
    UNIQUE (business_entity_id),

  CONSTRAINT matching_scoring_configs_exact_threshold_range
    CHECK (exact_match_threshold > 0 AND exact_match_threshold <= 1),

  CONSTRAINT matching_scoring_configs_strong_threshold_range
    CHECK (strong_probable_threshold > 0 AND strong_probable_threshold <= 1),

  CONSTRAINT matching_scoring_configs_weak_threshold_range
    CHECK (weak_possible_threshold > 0 AND weak_possible_threshold <= 1),

  CONSTRAINT matching_scoring_configs_threshold_ordering
    CHECK (
      exact_match_threshold > strong_probable_threshold
      AND strong_probable_threshold > weak_possible_threshold
    ),

  CONSTRAINT matching_scoring_configs_date_tolerance_positive
    CHECK (date_tolerance_days >= 0),

  CONSTRAINT matching_scoring_configs_amount_tolerance_positive
    CHECK (amount_tolerance_percent >= 0 AND amount_tolerance_percent <= 10),

  CONSTRAINT matching_scoring_configs_weights_sum_to_one
    CHECK (
      round(description_weight + amount_weight + date_weight, 2) = 1.00
    ),

  CONSTRAINT matching_scoring_configs_weights_positive
    CHECK (
      description_weight > 0
      AND amount_weight > 0
      AND date_weight > 0
    )
);
```

The `threshold_ordering` constraint enforces that `exact_match_threshold > strong_probable_threshold > weak_possible_threshold`. This prevents misconfiguration where the bands would overlap or invert, which would cause unpredictable routing behaviour in the matching engine.

The `weights_sum_to_one` constraint uses `round(..., 2)` to handle floating-point representation: NUMERIC(4,2) values are stored at two decimal places, and their sum should equal exactly 1.00 at that precision.

`amount_tolerance_percent` is capped at 10%. Tolerances above 10% are considered misconfiguration and are rejected. The default of 1.00 (%) is appropriate for most EUR-denominated matching; businesses with significant FX exposure may raise this to 2–3%.

---

## Indexes

```sql
CREATE UNIQUE INDEX idx_matching_scoring_configs_business_entity_id
  ON matching_scoring_configs (business_entity_id);

CREATE INDEX idx_matching_scoring_configs_created_at
  ON matching_scoring_configs (created_at DESC);
```

The unique index on `business_entity_id` is redundant with the UNIQUE constraint but is included explicitly for query planner visibility.

---

## Column Reference

| Column | Type | Nullable | Default | Description |
|---|---|---|---|---|
| `id` | UUID | No | gen_uuid_v7() | PK. |
| `business_entity_id` | UUID | No | — | FK to `business_entities(id)`. UNIQUE. |
| `exact_match_threshold` | NUMERIC(4,2) | No | 0.95 | Minimum composite score for EXACT level. |
| `strong_probable_threshold` | NUMERIC(4,2) | No | 0.80 | Minimum composite score for STRONG_PROBABLE level. |
| `weak_possible_threshold` | NUMERIC(4,2) | No | 0.60 | Minimum composite score for WEAK_POSSIBLE level. |
| `date_tolerance_days` | INTEGER | No | 3 | Acceptable date delta (days) for date signal scoring. |
| `amount_tolerance_percent` | NUMERIC(4,2) | No | 1.00 | FX-adjusted amount tolerance (%). Max 10. |
| `description_weight` | NUMERIC(4,2) | No | 0.40 | Weight of description signal in composite score. |
| `amount_weight` | NUMERIC(4,2) | No | 0.40 | Weight of amount signal in composite score. |
| `date_weight` | NUMERIC(4,2) | No | 0.20 | Weight of date signal in composite score. |
| `created_at` | TIMESTAMPTZ | No | now() | Row creation timestamp. |
| `updated_at` | TIMESTAMPTZ | No | now() | Last update timestamp. Maintained by trigger. |

---

## Row-Level Security

```sql
ALTER TABLE matching_scoring_configs ENABLE ROW LEVEL SECURITY;

CREATE POLICY matching_scoring_configs_select
  ON matching_scoring_configs
  FOR SELECT
  USING (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
  );

CREATE POLICY matching_scoring_configs_insert
  ON matching_scoring_configs
  FOR INSERT
  WITH CHECK (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
    AND (auth.jwt() ->> 'org_role') IN ('org:owner', 'org:accountant')
  );

CREATE POLICY matching_scoring_configs_update
  ON matching_scoring_configs
  FOR UPDATE
  USING (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
    AND (auth.jwt() ->> 'org_role') IN ('org:owner', 'org:accountant')
  );
```

Only `org:owner` and `org:accountant` may create or update matching scoring configuration. `org:viewer` and `org:admin` are read-only for this table.

DELETE is not permitted via RLS. Configuration rows are deactivated or reset to defaults, not deleted.

---

## Business Rules

1. A business entity may have at most one `matching_scoring_configs` row. Attempting to INSERT a second row for the same `business_entity_id` returns a unique constraint violation.
2. Configuration updates take effect on the next matching run. Runs already in RUNNING state use the configuration that was active when they started.
3. Setting `exact_match_threshold = 1.00` effectively disables auto-confirm (no real-world score is exactly 1.00 due to floating-point arithmetic). This is a valid configuration for businesses that require human review of all matches.
4. Setting `date_tolerance_days = 0` means the date signal only scores as a match when the transaction date equals the invoice date exactly.
5. Weight changes must be proposed and reviewed; they affect all future matching within the run. Historical proposals are not retroactively rescored.

---

## Fallback Behaviour

When no row exists for a business entity, the matching engine uses these platform defaults:

| Parameter | Default |
|---|---|
| exact_match_threshold | 0.95 |
| strong_probable_threshold | 0.80 |
| weak_possible_threshold | 0.60 |
| date_tolerance_days | 3 |
| amount_tolerance_percent | 1.00 |
| description_weight | 0.40 |
| amount_weight | 0.40 |
| date_weight | 0.20 |

These defaults are hardcoded in the matching engine and are not stored in any database table. They match the DEFAULT values in the DDL above.

---

## Audit Events

| Event | Trigger |
|---|---|
| `MATCHING_SCORING_CONFIG_CREATED` | First config row created for a business entity |
| `MATCHING_SCORING_CONFIG_UPDATED` | Any threshold or weight changed |

Both events include the previous and new values in the payload for change tracking.

---

## Related Documents

- `matching_engine_policy.md` — how thresholds and weights are applied during matching
- `match_proposal_schema.md` — proposals produced by the matching engine
- `match_scoring_config_schema.md` — alternate reference schema (check for overlap)
- `matching_policy.md` — overarching matching rules
- `match_scoring_weights_policy.md` — guidance on weight calibration
- `match_scoring_calibration_policy.md` — how thresholds are calibrated per business
- `matching_confidence_policy.md` — confidence band definitions
- `ecb_rate_schema.md` — FX rates used with amount_tolerance_percent
