# Schema: matching_exceptions

**Block:** Matching  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`matching_exceptions` records every transaction in a workflow run that the matching engine could not automatically match to an invoice. Each row captures why matching failed, what level of matching was attempted, and — once an accountant investigates — the documentation they provided to resolve or acknowledge the exception. This table is the primary input for the review queue's matching exception issues and is referenced by the finalization gate to ensure all exceptions are accounted for before a run can finalize.

## Type Definitions

```sql
CREATE TYPE matching_level_enum AS ENUM (
  'EXACT',
  'STRONG_PROBABLE',
  'WEAK_POSSIBLE',
  'NO_MATCH'
);

CREATE TYPE matching_exception_type_enum AS ENUM (
  'NO_CANDIDATE',
  'AMBIGUOUS_MULTIPLE',
  'AMOUNT_TOLERANCE_EXCEEDED',
  'DATE_RANGE_EXCEEDED',
  'CURRENCY_MISMATCH',
  'ALREADY_MATCHED'
);
```

## DDL

```sql
CREATE TABLE matching_exceptions (
  id                    UUID                          NOT NULL DEFAULT gen_uuid_v7(),
  run_id                UUID                          NOT NULL REFERENCES workflow_runs(id) ON DELETE RESTRICT,
  transaction_id        UUID                          NOT NULL REFERENCES transactions(id) ON DELETE RESTRICT,
  invoice_id            UUID                          REFERENCES invoices(id) ON DELETE SET NULL,
  match_level           matching_level_enum           NOT NULL,
  failure_reason        TEXT                          NOT NULL,
  exception_type        matching_exception_type_enum  NOT NULL,
  documented_by         UUID                          REFERENCES auth.users(id),
  documented_at         TIMESTAMPTZ,
  documentation_note    TEXT,
  created_at            TIMESTAMPTZ                   NOT NULL DEFAULT NOW(),

  CONSTRAINT matching_exceptions_pkey PRIMARY KEY (id),
  CONSTRAINT matching_exceptions_documentation_consistency
    CHECK (
      (documented_by IS NULL AND documented_at IS NULL AND documentation_note IS NULL) OR
      (documented_by IS NOT NULL AND documented_at IS NOT NULL AND documentation_note IS NOT NULL)
    ),
  CONSTRAINT matching_exceptions_failure_reason_nonempty
    CHECK (length(trim(failure_reason)) > 0)
);
```

## Indexes

```sql
CREATE INDEX idx_matching_exceptions_run_id
  ON matching_exceptions (run_id);

CREATE INDEX idx_matching_exceptions_transaction_id
  ON matching_exceptions (transaction_id);

CREATE INDEX idx_matching_exceptions_invoice_id
  ON matching_exceptions (invoice_id)
  WHERE invoice_id IS NOT NULL;

CREATE INDEX idx_matching_exceptions_documented_by
  ON matching_exceptions (documented_by)
  WHERE documented_by IS NOT NULL;

CREATE INDEX idx_matching_exceptions_exception_type
  ON matching_exceptions (exception_type);

CREATE INDEX idx_matching_exceptions_undocumented
  ON matching_exceptions (run_id)
  WHERE documented_by IS NULL;
```

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `run_id` | UUID | No | FK to `workflow_runs(id)`. ON DELETE RESTRICT. |
| `transaction_id` | UUID | No | FK to `transactions(id)`. The transaction that could not be matched. |
| `invoice_id` | UUID | Yes | FK to `invoices(id)`. Populated when `exception_type = 'AMBIGUOUS_MULTIPLE'` or `'AMOUNT_TOLERANCE_EXCEEDED'` to indicate the closest candidate invoice. Null for `'NO_CANDIDATE'`. |
| `match_level` | matching_level_enum | No | The highest match level that was attempted before the engine gave up. For example, `WEAK_POSSIBLE` means the engine tried EXACT, STRONG_PROBABLE, and WEAK_POSSIBLE without finding a valid match. |
| `failure_reason` | TEXT | No | Human-readable description of why the match failed. Populated by the matching engine from its internal scoring output. |
| `exception_type` | matching_exception_type_enum | No | Categorical reason code. See exception type descriptions below. |
| `documented_by` | UUID | Yes | FK to `auth.users(id)`. Set when an accountant documents the exception in the review queue. |
| `documented_at` | TIMESTAMPTZ | Yes | When the exception was documented. |
| `documentation_note` | TEXT | Yes | The accountant's note explaining the exception (e.g. "Client paid late, invoice 2024-089 settled separately"). All three documentation columns must be set together. |
| `created_at` | TIMESTAMPTZ | No | When the exception was recorded by the matching engine. |

## Exception Type Descriptions

| Type | Description |
|---|---|
| `NO_CANDIDATE` | No invoice was found whose amount, date, and counterparty came within any match scoring threshold |
| `AMBIGUOUS_MULTIPLE` | Two or more invoices scored above the WEAK_POSSIBLE threshold, and none was clearly dominant |
| `AMOUNT_TOLERANCE_EXCEEDED` | A candidate invoice was found but the amount difference exceeded the configured tolerance in `match_scoring_config_schema.md` |
| `DATE_RANGE_EXCEEDED` | A candidate invoice was found but the transaction date falls outside the allowed date window for that match level |
| `CURRENCY_MISMATCH` | A candidate invoice was found but the transaction currency does not match the invoice currency |
| `ALREADY_MATCHED` | The best candidate invoice is already matched to a different transaction in this run or a prior run |

## Row-Level Security

```sql
-- Business members can read exceptions for their own runs
CREATE POLICY matching_exceptions_read
  ON matching_exceptions
  FOR SELECT
  USING (
    run_id IN (
      SELECT id FROM workflow_runs
      WHERE business_id = (auth.jwt() ->> 'business_id')::UUID
    )
  );

-- Business members can update documentation fields only
CREATE POLICY matching_exceptions_document
  ON matching_exceptions
  FOR UPDATE
  USING (
    run_id IN (
      SELECT id FROM workflow_runs
      WHERE business_id = (auth.jwt() ->> 'business_id')::UUID
    )
  )
  WITH CHECK (
    -- Only allow updates that set documentation fields
    documented_by IS NOT NULL
  );

-- Inserts: service role only
```

## Finalization Gate

`matching_exceptions` feeds directly into the finalization gate (see `finalization_gate_sql_schema.md`). A run cannot transition to `FINALIZING` if there are any rows in this table for the `run_id` where `documented_by IS NULL`. The gate query is:

```sql
SELECT COUNT(*) = 0
FROM matching_exceptions
WHERE run_id = $1
  AND documented_by IS NULL;
```

If this returns false, the gate blocks finalization and the reason is surfaced to the accountant as an unresolved matching exception.

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `MATCHING_EXCEPTION_CREATED` | LOW | A row is inserted by the matching engine |
| `MATCHING_EXCEPTION_DOCUMENTED` | LOW | `documented_by`, `documented_at`, and `documentation_note` are set on an existing row |

## Data Zone and Retention

- **Zone:** Operational
- **Retention:** 7 years, as matching exception documentation forms part of the financial audit trail.

## Integration

- `matching_policy.md` — governs the matching rules that produce exceptions
- `match_scoring_config_schema.md` — configuration for tolerances referenced in `AMOUNT_TOLERANCE_EXCEEDED`
- `review_issues_schema.md` — review queue issues of type `MATCHING_EXCEPTION_UNRESOLVED` reference rows in this table
- `finalization_gate_sql_schema.md` — finalization gate that blocks on undocumented exceptions
- `out_exception_documented_policy.md` — policy governing the documentation workflow

## Related Documents

- `tool_match_propose.md` — matching engine tool that creates rows in this table
- `tool_match_confirm.md` — match confirmation tool
- `match_signal_evidence_schema.md` — scoring evidence associated with each exception
- `data_retention_policy.md` — Operational zone 7-year retention
