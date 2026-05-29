# Schema: classification_override_log

**Block:** AI Classification  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`classification_override_log` is an append-only table that records every instance where an accountant manually overrides the AI-suggested classification for a transaction. It captures the original category, the replacement category, the accountant's stated reason, and the AI confidence at the time of override. Rows in this table are permanent — they are never updated or deleted — and form part of the audit trail for financial classification decisions. The table also feeds the vendor memory update pipeline: every override triggers a write to vendor memory via `tool_vendor_memory_update.md`.

## DDL

```sql
CREATE TABLE classification_override_log (
  id                          UUID          NOT NULL DEFAULT gen_uuid_v7(),
  run_id                      UUID          NOT NULL REFERENCES workflow_runs(id) ON DELETE RESTRICT,
  transaction_id              UUID          NOT NULL REFERENCES transactions(id) ON DELETE RESTRICT,
  original_category_id        UUID          NOT NULL REFERENCES chart_of_accounts(id),
  override_category_id        UUID          NOT NULL REFERENCES chart_of_accounts(id),
  override_reason             TEXT          NOT NULL,
  overridden_by               UUID          NOT NULL REFERENCES auth.users(id),
  ai_confidence_at_override   DECIMAL(5,4),
  created_at                  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT classification_override_log_pkey PRIMARY KEY (id),
  CONSTRAINT classification_override_log_categories_differ
    CHECK (original_category_id != override_category_id),
  CONSTRAINT classification_override_log_confidence_range
    CHECK (
      ai_confidence_at_override IS NULL OR
      (ai_confidence_at_override >= 0 AND ai_confidence_at_override <= 1)
    ),
  CONSTRAINT classification_override_log_reason_nonempty
    CHECK (length(trim(override_reason)) > 0)
);
```

## Append-Only Enforcement

No UPDATE and no DELETE is permitted on this table by any role, including the service role. This is enforced at the database level by triggers:

```sql
CREATE OR REPLACE FUNCTION classification_override_log_deny_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'classification_override_log is append-only: UPDATE is not permitted';
END;
$$;

CREATE TRIGGER classification_override_log_no_update
  BEFORE UPDATE ON classification_override_log
  FOR EACH ROW EXECUTE FUNCTION classification_override_log_deny_update();

CREATE OR REPLACE FUNCTION classification_override_log_deny_delete()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'classification_override_log is append-only: DELETE is not permitted';
END;
$$;

CREATE TRIGGER classification_override_log_no_delete
  BEFORE DELETE ON classification_override_log
  FOR EACH ROW EXECUTE FUNCTION classification_override_log_deny_delete();
```

These triggers fire before any statement-level operation and cannot be bypassed by the application. Only a superuser can drop them, and that action would generate an unresolvable audit gap.

## Indexes

```sql
CREATE INDEX idx_classification_override_log_run_id
  ON classification_override_log (run_id);

CREATE INDEX idx_classification_override_log_transaction_id
  ON classification_override_log (transaction_id);

CREATE INDEX idx_classification_override_log_overridden_by
  ON classification_override_log (overridden_by);

CREATE INDEX idx_classification_override_log_created_at
  ON classification_override_log (created_at DESC);
```

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `run_id` | UUID | No | FK to `workflow_runs(id)`. ON DELETE RESTRICT prevents run deletion while override history exists. |
| `transaction_id` | UUID | No | FK to `transactions(id)`. ON DELETE RESTRICT prevents transaction deletion while override history exists. |
| `original_category_id` | UUID | No | The category that was suggested by the AI (or rules engine) prior to override. FK to `chart_of_accounts(id)`. |
| `override_category_id` | UUID | No | The category selected by the accountant. FK to `chart_of_accounts(id)`. Must differ from `original_category_id`. |
| `override_reason` | TEXT | No | Free-text reason provided by the accountant. Required; must be non-empty after trimming. |
| `overridden_by` | UUID | No | FK to `auth.users(id)`. The accountant who performed the override. |
| `ai_confidence_at_override` | DECIMAL(5,4) | Yes | The confidence score from `ai_classification_results` at the time the override was applied. Null if the original result was produced by the rules engine (which does not produce a confidence score). |
| `created_at` | TIMESTAMPTZ | No | Immutable creation timestamp. |

## Row-Level Security

```sql
-- Business members can read override logs for their own runs
CREATE POLICY classification_override_log_read
  ON classification_override_log
  FOR SELECT
  USING (
    run_id IN (
      SELECT id FROM workflow_runs
      WHERE business_id = (auth.jwt() ->> 'business_id')::UUID
    )
  );

-- INSERT is permitted only through the service role
-- No client-side writes
```

## Data Zone and Retention

- **Zone:** Operational
- **Retention:** 7 years from `created_at`, consistent with the financial decision audit trail requirements in `data_retention_policy.md`.
- This table is never purged by the standard Processing-zone TTL job. It is subject only to the Operational-zone lifecycle, which triggers deletion only after the 7-year mark.

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `CLASSIFICATION_MANUAL_OVERRIDE_SET` | LOW | A row is inserted into this table |

The audit payload includes: `run_id`, `transaction_id`, `original_category_id`, `override_category_id`, `overridden_by`, `ai_confidence_at_override`.

## Vendor Memory Update Trigger

Every insert into `classification_override_log` triggers the vendor memory update pipeline. The database trigger fires after insert:

```sql
CREATE OR REPLACE FUNCTION classification_override_log_after_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  PERFORM net.http_post(
    url := current_setting('app.vendor_memory_update_url'),
    body := json_build_object(
      'event', 'CLASSIFICATION_MANUAL_OVERRIDE_SET',
      'transaction_id', NEW.transaction_id,
      'original_category_id', NEW.original_category_id,
      'override_category_id', NEW.override_category_id,
      'overridden_by', NEW.overridden_by
    )::text,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER classification_override_log_notify_vendor_memory
  AFTER INSERT ON classification_override_log
  FOR EACH ROW EXECUTE FUNCTION classification_override_log_after_insert();
```

This trigger invokes `tool_vendor_memory_update.md` via the internal HTTP API so vendor memory learns from every accountant correction.

## Integration with ai_classification_results

When a row is inserted here, the corresponding `ai_classification_results` row for `(run_id, transaction_id)` has its `overridden_by` and `overridden_at` columns populated. This join allows any query to see both the AI suggestion and the accountant's correction in one view.

## Related Documents

- `ai_classification_result_schema.md` — the AI result that was overridden
- `tool_ai_classify.md` — the tool that produced the original classification
- `tool_vendor_memory_update.md` — downstream tool triggered by every override
- `chart_of_accounts_schema.md` — FK target for both category columns
- `data_retention_policy.md` — Operational zone 7-year retention
- `classification_confidence_drop_runbook.md` — uses override frequency as a signal for model quality
