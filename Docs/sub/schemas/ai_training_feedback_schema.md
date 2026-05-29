# Schema: ai_training_feedback

**Block:** AI Classification
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`ai_training_feedback` captures every human correction to an AI-generated classification result. Rows are created by `tool_classification_override.md` (when a reviewer replaces the AI-proposed category in the review queue), by bulk reclassification operations, and by API-level corrections. Each row records the original and corrected values, the reason for the correction, and who made it.

The primary downstream use of this table is the AI training export pipeline. Rows are batched and exported to the training system on a scheduled basis. Before export, all personally identifiable information is stripped — the exported payload contains only category codes, account codes, normalised feature vectors, and the correction source. No counterparty names, transaction descriptions, business identifiers, or user identifiers leave the platform in the training export.

---

## Enum Definition

```sql
CREATE TYPE correction_source_enum AS ENUM (
  'REVIEW_QUEUE_OVERRIDE',
  'BULK_RECLASSIFY',
  'API_CORRECTION'
);
```

- `REVIEW_QUEUE_OVERRIDE` — correction made by a reviewer acting on a review queue issue via `tool_classification_override.md`.
- `BULK_RECLASSIFY` — correction applied to a batch of transactions via the bulk reclassification interface.
- `API_CORRECTION` — correction submitted programmatically through the external API (e.g. by an integrating accounting system).

---

## DDL

```sql
CREATE TABLE ai_training_feedback (
  id                            UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id            UUID          NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  transaction_id                UUID          NOT NULL REFERENCES transactions(id) ON DELETE RESTRICT,
  original_classification_id    UUID              NULL REFERENCES ai_classification_results(id) ON DELETE SET NULL,
  corrected_vat_category        TEXT          NOT NULL,
  corrected_account_code        TEXT          NOT NULL,
  correction_reason             TEXT              NULL,
  corrected_by                  UUID          NOT NULL REFERENCES org_members(id) ON DELETE RESTRICT,
  correction_source             correction_source_enum NOT NULL,
  exported_to_training_at       TIMESTAMPTZ       NULL,
  created_at                    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT ai_training_feedback_pkey PRIMARY KEY (id),

  CONSTRAINT ai_training_feedback_vat_category_nonempty
    CHECK (length(trim(corrected_vat_category)) > 0),

  CONSTRAINT ai_training_feedback_account_code_nonempty
    CHECK (length(trim(corrected_account_code)) > 0)
);
```

`original_classification_id` is nullable and uses `ON DELETE SET NULL`. If the source `ai_classification_results` row is purged (e.g. after a data retention cycle), the feedback row is preserved but its link to the original result is severed. The corrected values remain intact and are still valid for training export.

`corrected_by` references `org_members(id)`. This is a deliberate choice: corrections are always traceable to a specific organisation member, not only an `auth.users` identity. `org_members` provides the business-scoped role context needed for audit and capacity limit checks.

`exported_to_training_at` is NULL until the training export job processes the row. Once set, the row is not re-exported. The column acts as a soft lock for the export job.

---

## Indexes

```sql
CREATE INDEX idx_ai_training_feedback_business_entity_id
  ON ai_training_feedback (business_entity_id);

CREATE INDEX idx_ai_training_feedback_transaction_id
  ON ai_training_feedback (transaction_id);

CREATE INDEX idx_ai_training_feedback_original_classification_id
  ON ai_training_feedback (original_classification_id)
  WHERE original_classification_id IS NOT NULL;

CREATE INDEX idx_ai_training_feedback_corrected_by
  ON ai_training_feedback (corrected_by);

CREATE INDEX idx_ai_training_feedback_correction_source
  ON ai_training_feedback (correction_source);

CREATE INDEX idx_ai_training_feedback_not_exported
  ON ai_training_feedback (created_at ASC)
  WHERE exported_to_training_at IS NULL;

CREATE INDEX idx_ai_training_feedback_created_at
  ON ai_training_feedback (created_at DESC);
```

The partial index on `exported_to_training_at IS NULL` is the hot path used by the training export job. It remains small because the export job processes rows promptly; once exported, rows leave the partial index.

---

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `business_entity_id` | UUID | No | FK to `business_entities(id)`. ON DELETE RESTRICT. |
| `transaction_id` | UUID | No | FK to `transactions(id)`. ON DELETE RESTRICT. |
| `original_classification_id` | UUID | Yes | FK to `ai_classification_results(id)`. NULL if no AI result existed (rule-only classification). ON DELETE SET NULL. |
| `corrected_vat_category` | TEXT | No | The VAT category code selected by the reviewer. |
| `corrected_account_code` | TEXT | No | The chart-of-accounts code selected by the reviewer. |
| `correction_reason` | TEXT | Yes | Free-text reason for the correction. Optional but encouraged. |
| `corrected_by` | UUID | No | FK to `org_members(id)`. Identity of the person who made the correction. |
| `correction_source` | correction_source_enum | No | Mechanism through which the correction was submitted. |
| `exported_to_training_at` | TIMESTAMPTZ | Yes | NULL until the training export job processes this row. |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |

---

## Row-Level Security

```sql
ALTER TABLE ai_training_feedback ENABLE ROW LEVEL SECURITY;

-- Business entity members may read their own feedback rows
CREATE POLICY ai_training_feedback_select
  ON ai_training_feedback
  FOR SELECT
  USING (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
  );

-- INSERT via service role only (tool_classification_override writes these rows)
-- No direct client-side writes
```

---

## Training Export Mechanism

The training export job runs on a scheduled cadence (configured in the platform operations layer). Each run:

1. Selects rows where `exported_to_training_at IS NULL`, ordered by `created_at ASC`, with a configurable batch size (default 500).
2. Constructs a stripped payload for each row (see Privacy Note below).
3. Posts the batch to the training pipeline endpoint.
4. On successful acknowledgement from the training pipeline, sets `exported_to_training_at = now()` on the processed rows in a single UPDATE.
5. If the training pipeline returns an error, the job does not mark rows as exported. They will be retried on the next scheduled run.

The job is idempotent: if it crashes after posting but before updating `exported_to_training_at`, the training pipeline will receive the same rows again on retry. The training pipeline is responsible for deduplicating inbound feedback by `id`.

---

## Privacy Note: No PII in Training Export

The payload sent to the training pipeline is a stripped representation of each feedback row. It contains:

- `feedback_id` (the `ai_training_feedback.id` — no linkable business context in the training environment)
- `corrected_vat_category`
- `corrected_account_code`
- `correction_source`
- Normalised feature vector from `ai_classification_results.feature_vector` (anonymised token weights, no raw text)

The following fields are explicitly excluded from the training export:
- `business_entity_id`
- `transaction_id`
- `corrected_by`
- `correction_reason` (may contain counterparty names or other free-text PII)
- Any raw transaction description or counterparty name

This exclusion is enforced in the export job code and is not overridable by configuration. It satisfies the data minimisation requirement for AI training data under the platform's GDPR obligations. See `gdpr_data_subject_rights_policy.md` for the broader context.

---

## Audit Events

Rows in `ai_training_feedback` are created as part of the `tool_classification_override.md` execution flow, which emits `AI_CLASSIFICATION_OVERRIDDEN`. There is no separate audit event for the feedback row creation itself; the override event is the authoritative record. The training export job emits a summary log entry (not an audit event) per batch processed, recording batch size and `exported_to_training_at` range.

---

## Related Documents

- `tool_classification_override.md` — primary writer of rows into this table
- `ai_classification_result_schema.md` — the source classification result linked by original_classification_id
- `classification_override_log_schema.md` — parallel append-only log for override audit trail
- `classification_confidence_escalation_policy.md` — when corrections are triggered by confidence tiers
- `org_member_schema.md` — FK target for corrected_by
- `gdpr_data_subject_rights_policy.md` — PII exclusion requirements for training data
- `data_retention_policy.md` — retention period for feedback rows
- `transactions_schema.md` — FK target for transaction_id
