# Schema: ai_classification_configs

**Namespace:** ai
**Table:** ai_classification_configs
**Purpose:** Per-business configuration for AI-driven transaction and document
classification. Each business entity has at most one row. Settings control the pinned
model version, confidence thresholds that gate automatic acceptance vs. human review,
the subset of VAT categories the AI may assign, and the canary rollout percentage for
model candidates.

---

## Table Definition

```sql
CREATE TABLE ai_classification_configs (
  id                               uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_entity_id               uuid        NOT NULL UNIQUE
                                                 REFERENCES business_entities(id)
                                                 ON DELETE CASCADE,
  model_version                    text        NOT NULL,
  confidence_auto_accept_threshold numeric(5,4) NOT NULL DEFAULT 0.90,
  confidence_review_threshold      numeric(5,4) NOT NULL DEFAULT 0.70,
  enabled_categories               text[]      NOT NULL DEFAULT '{}',
  training_feedback_enabled        boolean     NOT NULL DEFAULT true,
  canary_percentage                smallint    NOT NULL DEFAULT 0,
  created_at                       timestamptz NOT NULL DEFAULT now(),
  updated_at                       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_auto_accept_range
    CHECK (confidence_auto_accept_threshold BETWEEN 0.50 AND 1.00),
  CONSTRAINT chk_review_range
    CHECK (confidence_review_threshold BETWEEN 0.00 AND 1.00),
  CONSTRAINT chk_threshold_order
    CHECK (confidence_review_threshold < confidence_auto_accept_threshold),
  CONSTRAINT chk_canary_range
    CHECK (canary_percentage BETWEEN 0 AND 100)
);
```

---

## Column Reference

| Column | Type | Default | Notes |
|---|---|---|---|
| id | uuid | gen_uuid_v7() | Business PK; monotonically increasing |
| business_entity_id | uuid FK | — | UNIQUE; one config per business |
| model_version | text | — | Pinned model identifier, e.g. `claude-classify-3.1`. Must match a deployed version in `ai_model_registry` |
| confidence_auto_accept_threshold | numeric(5,4) | 0.90 | Predictions at or above this score are auto-accepted without human review |
| confidence_review_threshold | numeric(5,4) | 0.70 | Predictions below this score enter REVIEW_HOLD; predictions between the two thresholds go to the review queue |
| enabled_categories | text[] | {} | VAT category codes the AI may assign. Empty array = all categories enabled |
| training_feedback_enabled | boolean | true | When true, resolved classifications are written to `ai_training_feedback` |
| canary_percentage | smallint | 0 | Percentage of documents routed to a canary model candidate. 0 disables canary routing |
| created_at | timestamptz | now() | Row creation time; immutable after insert |
| updated_at | timestamptz | now() | Maintained by trigger on each UPDATE |

---

## Check Constraints

### `chk_threshold_order`

The review threshold must be strictly less than the auto-accept threshold. This enforces
the three-band classification model:

- `score >= auto_accept_threshold` → auto-accepted
- `review_threshold <= score < auto_accept_threshold` → review queue
- `score < review_threshold` → REVIEW_HOLD

Violating this constraint raises a CHECK error. Threshold changes apply to the next
classification run; in-progress runs are not retroactively re-routed.

### `chk_canary_range`

Canary percentage must be 0–100 inclusive. Setting to 0 disables canary routing for the
business. Setting to 100 routes all documents to the canary model (controlled testing
only; not permitted in production environments per `ai_model_versioning_policy`).

---

## Indexes

```sql
CREATE UNIQUE INDEX uq_ai_classification_configs_business
  ON ai_classification_configs(business_entity_id);

CREATE INDEX idx_ai_classification_configs_model_version
  ON ai_classification_configs(model_version);
```

---

## updated_at Trigger

```sql
CREATE OR REPLACE FUNCTION ai_classification_configs_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ai_classification_configs_updated_at
  BEFORE UPDATE ON ai_classification_configs
  FOR EACH ROW
  EXECUTE FUNCTION ai_classification_configs_set_updated_at();
```

---

## Row-Level Security

```sql
ALTER TABLE ai_classification_configs ENABLE ROW LEVEL SECURITY;

CREATE POLICY ai_classification_configs_read
  ON ai_classification_configs FOR SELECT
  USING (auth.business_entity_id_for_session() = business_entity_id);

CREATE POLICY ai_classification_configs_write
  ON ai_classification_configs FOR ALL
  USING (
    auth.role_on_business(business_entity_id) = 'admin'
    OR current_setting('app.system_role_active', true) = 'true'
  )
  WITH CHECK (
    auth.role_on_business(business_entity_id) = 'admin'
    OR current_setting('app.system_role_active', true) = 'true'
  );
```

Only `org:admin` users or the system role may insert or update. Accountants and
read-only members may read the config but cannot modify it.

---

## Business Rules

1. **One row per business.** The UNIQUE constraint enforces this. Always UPDATE the
   existing row; never delete and re-insert.

2. **Default config on provisioning.** When `business_entities` is created, the intake
   provisioning workflow inserts a default row using system defaults. `model_version`
   is set to `ai_model_registry.current_production_version`.

3. **Threshold changes are not retroactive.** Changes take effect on the next
   classification run. Pause an in-progress run before changing thresholds if
   mid-run reclassification is needed.

4. **Empty `enabled_categories` means all categories.** Populate this field to restrict
   AI classification to specific VAT codes, e.g. for businesses that manually handle
   exempt or mixed-use categories.

5. **Canary routing.** When `canary_percentage > 0`, the AI gateway samples that
   percentage to the canary model from `ai_model_registry.current_canary_version`.
   Results are logged to `ai_result_variants` but do not affect the primary output
   unless explicitly promoted.

6. **Training feedback.** When `training_feedback_enabled = false`, review-queue
   resolutions are not written to `ai_training_feedback`. This does not affect the
   current model but reduces data available for future retraining.

---

## Audit Events

| Event | Severity | Condition |
|---|---|---|
| AI_CLASSIFICATION_CONFIG_CREATED | LOW | Row inserted during business provisioning |
| AI_CLASSIFICATION_CONFIG_UPDATED | MEDIUM | Any column updated by an admin |

`AI_CLASSIFICATION_CONFIG_UPDATED` payload must include `changed_fields`,
`old_values`, and `new_values`.

---

## Related Documents

- `ai_model_registry` — valid `model_version` values and canary candidate version
- `ai_training_feedback_schema.md` — feedback rows written when flag is enabled
- `ai_result_variants_schema.md` — canary result storage
- `ai_gateway_schema.md` — gateway routing logic that reads `canary_percentage`
- `classification_confidence_policy.md` — threshold floor values and three-band model
- `ai_model_versioning_policy.md` — rules for pinning and migrating model versions
- `tool_ai_classify.md` — tool that reads this config at classification time
- `tool_ai_retrain_trigger.md` — tool that uses `training_feedback_enabled` flag
