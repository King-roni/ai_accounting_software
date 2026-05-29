# Schema: dedup_results

**Block:** Intake  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`dedup_results` is an ephemeral Processing-zone table that records the outcome of the deduplication check performed by `intake.check_dedup`. One row is written per transaction checked. The table is scoped to a single run; rows are deleted 7 days after the run completes.

This table is not part of the permanent ledger. It is a working artifact used by the intake pipeline and the review queue to communicate deduplication decisions. The permanent record of duplicate detection is the `DEDUP_CHECK_COMPLETED` audit event and the `dedup_status` column on `transactions`.

---

## DDL

```sql
CREATE TYPE dedup_status_enum AS ENUM (
  'NEW',
  'DUPLICATE_EXACT',
  'DUPLICATE_PROBABLE',
  'NEEDS_REVIEW'
);

CREATE TABLE dedup_results (
  id                      UUID          NOT NULL DEFAULT gen_uuid_v7(),
  run_id                  UUID          NOT NULL
                            REFERENCES workflow_runs(id)
                            ON DELETE CASCADE,
  transaction_id          UUID          NOT NULL UNIQUE
                            REFERENCES transactions(id)
                            ON DELETE CASCADE,
  dedup_status            dedup_status_enum NOT NULL,
  matched_transaction_id  UUID          NULL
                            REFERENCES transactions(id)
                            ON DELETE SET NULL,
  match_confidence        DECIMAL(5,4)  NULL
                            CHECK (match_confidence IS NULL
                                OR (match_confidence >= 0 AND match_confidence <= 1)),
  checked_at              TIMESTAMPTZ   NOT NULL DEFAULT now(),
  check_duration_ms       INT           NULL CHECK (check_duration_ms >= 0),

  CONSTRAINT dedup_results_pkey PRIMARY KEY (id)
);
```

---

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | Primary key. Generated with `gen_uuid_v7()`. |
| `run_id` | UUID | No | FK to `workflow_runs(id)`. All rows in a batch share the same `run_id`. |
| `transaction_id` | UUID | No | FK to `transactions(id)`. UNIQUE — one result per transaction. |
| `dedup_status` | dedup_status_enum | No | Result of the check. See status definitions below. |
| `matched_transaction_id` | UUID | Yes | FK to `transactions(id)`. Populated for `DUPLICATE_EXACT` and `DUPLICATE_PROBABLE`. Points to the existing transaction that is the likely duplicate. |
| `match_confidence` | DECIMAL(5,4) | Yes | Confidence score 0.0000–1.0000. `1.0` for exact matches. Trigram similarity score for probable matches. `NULL` for `NEW`. |
| `checked_at` | TIMESTAMPTZ | No | Timestamp the check completed for this row. Set by the tool, not a database default, so it reflects the actual computation time. |
| `check_duration_ms` | INT | Yes | Wall-clock time in milliseconds for this individual row's check. Used for performance monitoring. |

---

## Status Definitions

| Status | Meaning | Advances to classification |
|---|---|---|
| `NEW` | No duplicate found. Transaction is genuinely new. | Yes |
| `DUPLICATE_EXACT` | Exact match on composite key. Transaction is a structural duplicate. | No — silently excluded |
| `DUPLICATE_PROBABLE` | Fuzzy match above threshold. Human confirmation required. | No — held pending review |
| `NEEDS_REVIEW` | Ambiguous signal (e.g. multiple fuzzy candidates). Escalated to review queue without a specific matched ID. | No — held pending review |

---

## Indexes

```sql
-- Fast lookup of all results for a run (primary pipeline access pattern)
CREATE INDEX idx_dedup_results_run_id
  ON dedup_results (run_id);

-- Partial index: quickly find non-NEW results for review queue population
-- and run summary statistics without scanning NEW rows (typically the majority)
CREATE INDEX idx_dedup_results_non_new
  ON dedup_results (run_id, dedup_status)
  WHERE dedup_status != 'NEW';
```

The UNIQUE constraint on `transaction_id` provides implicit unique-lookup performance without an additional explicit index.

---

## Data Zone and Retention

**Data zone:** Processing (ephemeral working data, not permanent ledger).

Retention policy: rows are deleted 7 days after the associated run reaches a terminal state (`FINALIZED`, `FAILED`, or `CANCELLED`).

Deletion is performed by a scheduled Supabase function:

```sql
DELETE FROM dedup_results
WHERE run_id IN (
  SELECT id
  FROM   workflow_runs
  WHERE  status      IN ('FINALIZED', 'FAILED', 'CANCELLED')
    AND  finalized_at < now() - INTERVAL '7 days'
);
```

Reference: `data_retention_policy.md`.

---

## Row-Level Security

```sql
ALTER TABLE dedup_results ENABLE ROW LEVEL SECURITY;

-- Service role has full write access (INSERT, UPDATE, DELETE)
CREATE POLICY dedup_results_service_write
  ON dedup_results
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Business members may read results for their own runs
CREATE POLICY dedup_results_business_read
  ON dedup_results
  FOR SELECT
  TO authenticated
  USING (
    run_id IN (
      SELECT wr.id
      FROM   workflow_runs wr
      JOIN   business_entities be ON be.id = wr.business_id
      JOIN   org_members om        ON om.business_id = be.id
      WHERE  om.user_id = auth.uid()
    )
  );
```

Reference: `rls_policy_template.md`, `row_level_security_policies.md`.

---

## Audit Event

A single `DEDUP_CHECK_COMPLETED` event (severity: LOW) is emitted per `intake.check_dedup` invocation. It is emitted once per run call, summarising aggregate counts, not once per row. This prevents audit log bloat when processing statements with hundreds of transactions.

```jsonc
{
  "event":                  "DEDUP_CHECK_COMPLETED",
  "severity":               "LOW",
  "run_id":                 "<uuid>",
  "business_id":            "<uuid>",
  "checked_count":          150,
  "new_count":              143,
  "duplicate_exact_count":  4,
  "duplicate_probable_count": 3,
  "needs_review_count":     0,
  "duration_ms":            312
}
```

Reference: `emit_audit_api.md`, `audit_event_naming_convention_policy.md`.

---

## Integration Points

| System | How it uses this table |
|---|---|
| `intake.check_dedup` | Writes all rows in a batch after checking each transaction |
| Review queue population | Reads `WHERE dedup_status IN ('DUPLICATE_PROBABLE', 'NEEDS_REVIEW')` to create review issues |
| Run progress API | Reads aggregate counts for progress display |
| Intake pipeline orchestrator | Reads `WHERE dedup_status = 'NEW'` to determine which transactions advance to classification |
| Data retention job | Deletes rows 7 days post-run terminal state |

---

## Related Documents

- `tool_dedup_check.md` — tool that writes to this table
- `deduplication_fingerprint_schema.md` — composite key used for exact match
- `dedup_key_generator_policy.md` — key normalisation
- `deduplication_policy.md` — threshold and scoring rules
- `transactions_schema.md` — `dedup_status` column mirrored from this table
- `intake_pipeline_overview.md` — overall pipeline context
- `data_retention_policy.md` — 7-day Processing zone retention rule
- `row_level_security_policies.md` — RLS conventions
