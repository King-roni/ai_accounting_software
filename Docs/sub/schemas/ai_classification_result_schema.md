# Schema: ai_classification_results

**Block:** AI Classification  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`ai_classification_results` stores the output of every `ai.classify` invocation. Each row represents a single transaction's classification result, whether produced by the AI gateway or the rules-engine fallback. Rows in this table are the authoritative record of what classification was suggested before any accountant override. When an accountant overrides a classification, the override is recorded in `classification_override_log` and the `overridden_by` / `overridden_at` columns here are populated.

## DDL

```sql
CREATE TABLE ai_classification_results (
  id                    UUID          NOT NULL DEFAULT gen_uuid_v7(),
  run_id                UUID          NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
  transaction_id        UUID          NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  model_used            TEXT          NOT NULL,
  model_version         TEXT,
  confidence            DECIMAL(5,4),
  suggested_category_id UUID          NOT NULL REFERENCES chart_of_accounts(id),
  reasoning_excerpt     TEXT,
  token_count           INT,
  latency_ms            INT,
  fallback_used         BOOLEAN       NOT NULL DEFAULT FALSE,
  overridden_by         UUID          REFERENCES auth.users(id),
  overridden_at         TIMESTAMPTZ,
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT ai_classification_results_pkey PRIMARY KEY (id),
  CONSTRAINT ai_classification_results_confidence_range
    CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
  CONSTRAINT ai_classification_results_token_count_positive
    CHECK (token_count IS NULL OR token_count > 0),
  CONSTRAINT ai_classification_results_latency_positive
    CHECK (latency_ms IS NULL OR latency_ms > 0),
  CONSTRAINT ai_classification_results_override_consistency
    CHECK (
      (overridden_by IS NULL AND overridden_at IS NULL) OR
      (overridden_by IS NOT NULL AND overridden_at IS NOT NULL)
    )
);
```

## Indexes

```sql
CREATE INDEX idx_ai_classification_results_run_id
  ON ai_classification_results (run_id);

CREATE INDEX idx_ai_classification_results_transaction_id
  ON ai_classification_results (transaction_id);

CREATE INDEX idx_ai_classification_results_overridden_by
  ON ai_classification_results (overridden_by)
  WHERE overridden_by IS NOT NULL;

CREATE INDEX idx_ai_classification_results_confidence
  ON ai_classification_results (confidence)
  WHERE confidence IS NOT NULL;
```

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `run_id` | UUID | No | FK to `workflow_runs.id`. The run in which this classification was produced. |
| `transaction_id` | UUID | No | FK to `transactions.id`. The transaction that was classified. |
| `model_used` | TEXT | No | Model identifier string (e.g. `claude-3-5-haiku-20241022`, `rules_engine`). |
| `model_version` | TEXT | Yes | Model version or snapshot tag as returned by the gateway. Null for rules-engine results. |
| `confidence` | DECIMAL(5,4) | Yes | Confidence score 0.0000–1.0000. Null for rules-engine fallback results. |
| `suggested_category_id` | UUID | No | FK to `chart_of_accounts.id`. The category proposed by the model or rules engine. |
| `reasoning_excerpt` | TEXT | Yes | A short excerpt of the model's reasoning (max 500 characters). Stored for review queue display. Not the full chain-of-thought. |
| `token_count` | INT | Yes | Total tokens consumed for this transaction (prompt + completion). Null for rules-engine. |
| `latency_ms` | INT | Yes | Gateway response time in milliseconds. Null for rules-engine. |
| `fallback_used` | BOOLEAN | No | True when the rules engine produced this result in place of the AI gateway. |
| `overridden_by` | UUID | Yes | FK to `auth.users(id)`. Set when an accountant manually overrides the suggested category. |
| `overridden_at` | TIMESTAMPTZ | Yes | When the override was applied. |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |

## Row-Level Security

```sql
-- Business members can read results for their own runs
CREATE POLICY ai_classification_results_read
  ON ai_classification_results
  FOR SELECT
  USING (
    run_id IN (
      SELECT id FROM workflow_runs
      WHERE business_id = auth.jwt() ->> 'business_id'
    )
  );

-- Only the service role may insert or update
-- No direct client writes permitted
```

All writes to this table are performed exclusively through the service role via `ai.classify` and the override path in `tool_match_confirm.md`. Direct client-side inserts are denied.

## Data Zone and Retention

- **Zone:** Processing
- **Standard TTL:** Rows are deleted 7 days after the parent run is finalized, except where `overridden_by IS NOT NULL`.
- **Override retention:** Rows with an override set are promoted to the Operational zone and retained for 7 years as part of the audit trail for financial classification decisions, per `data_retention_policy.md`.
- The promotion is performed by the `zone_promotion_policy.md` post-finalization job.

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `AI_CLASSIFICATION_BATCH_COMPLETED` | LOW | Emitted by `ai.classify` after a successful batch write to this table |
| `CLASSIFICATION_MANUAL_OVERRIDE_SET` | LOW | Emitted when `overridden_by` and `overridden_at` are populated |

`CLASSIFICATION_MANUAL_OVERRIDE_SET` also triggers a write to `classification_override_log` (see `classification_override_log_schema.md`) and initiates the vendor memory update via `tool_vendor_memory_update.md`.

## Unique Constraint Consideration

There is intentionally no `UNIQUE (run_id, transaction_id)` constraint because the idempotency guard in `ai.classify` operates at the application layer. If a duplicate row is ever detected in a data audit, it is a signal of a tool invocation logic bug, not expected behaviour.

## Integration

- `ai.classify` — the sole writer under normal operation
- `classification_override_log_schema.md` — receives a corresponding row on every manual override
- `classification_confidence_drop_runbook.md` — operational runbook triggered when aggregate confidence in a run falls below the business's threshold
- `tool_vendor_memory_update.md` — receives the override signal via `CLASSIFICATION_MANUAL_OVERRIDE_SET`
- `review_issues_schema.md` — LOW_CONFIDENCE_CLASSIFICATION issues reference `ai_classification_results.id`

## Related Documents

- `tool_ai_classify.md` — tool that writes to this table
- `ai_usage_records_schema.md` — companion table for token billing aggregation
- `classification_override_log_schema.md` — append-only override history
- `chart_of_accounts_schema.md` — FK target for `suggested_category_id`
- `data_retention_policy.md` — retention rules by zone

## Notes on `reasoning_excerpt`

The `reasoning_excerpt` column stores at most 500 characters of the model's explanation for the category selection. It is not the full chain-of-thought and is not used for any automated downstream processing. Its sole purpose is to give accountants reviewing low-confidence results a plain-language signal about why the model chose a category. Do not use this field as input to further AI calls.
