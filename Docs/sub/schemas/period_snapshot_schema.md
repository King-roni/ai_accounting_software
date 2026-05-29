# Period Snapshot Schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Block reference:** Block 16 § Phase 01 (Dashboard Architecture), Phase 03 (Analytics Pre-computation) · **Stage:** 4 sub-doc (Layer 2 schema)

**Purpose:** Defines the `period_snapshots` table — pre-computed period-level metrics that power dashboard cards and report views without requiring live queries against large transaction, ledger, or invoice tables. Snapshots are rebuilt on defined triggers, served with a staleness banner when stale, and retained in the Operational data zone for 7 years.

This table is distinct from `analytics_snapshots` (defined in `analytics_snapshot_schema.md`). `analytics_snapshots` is a versioned run-scoped aggregate linked to a specific `workflow_run_id`; `period_snapshots` is a broader period-scoped pre-computation that covers both `DASHBOARD` and `REPORT` snapshot types and includes issue severity breakdowns not present in `analytics_snapshots`.

---

## Table definition

```sql
CREATE TABLE period_snapshots (
  id                      uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Tenant and period scope
  business_id             uuid NOT NULL,
  period_year             integer NOT NULL
                            CHECK (period_year >= 2020 AND period_year <= 2099),
  period_month            integer NOT NULL
                            CHECK (period_month >= 1 AND period_month <= 12),

  -- Optional run linkage — null for DASHBOARD snapshots covering a period
  -- with no workflow run yet started; non-null for REPORT snapshots
  workflow_run_id         uuid REFERENCES workflow_runs(workflow_run_id),

  -- Snapshot type
  snapshot_type           text NOT NULL
                            CHECK (snapshot_type IN ('DASHBOARD', 'REPORT')),

  -- Pre-computed metrics (JSONB — see Section 2 for shape)
  metrics                 jsonb NOT NULL,

  -- Computation timestamp
  computed_at             timestamptz NOT NULL,

  -- Staleness tracking
  is_stale                boolean NOT NULL DEFAULT false,
  invalidated_at          timestamptz,
  invalidation_reason     text,

  -- Retention markers (Operational zone — 7-year post-deactivation)
  created_at              timestamptz NOT NULL DEFAULT now(),

  -- One active snapshot per (business, year, month, type) at a time
  -- Multiple rows may exist for the same period if rebuilt; latest is served
  CONSTRAINT period_snapshots_period_type_key
    UNIQUE NULLS NOT DISTINCT (business_id, period_year, period_month, snapshot_type, workflow_run_id)
);

CREATE INDEX idx_period_snapshots_lookup
  ON period_snapshots(business_id, period_year, period_month, snapshot_type)
  WHERE is_stale = false;

CREATE INDEX idx_period_snapshots_stale
  ON period_snapshots(business_id, is_stale, computed_at DESC)
  WHERE is_stale = true;

CREATE INDEX idx_period_snapshots_run
  ON period_snapshots(workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;
```

All PKs use `gen_uuid_v7()` per `data_layer_conventions_policy`. `workflow_run_id` is nullable — `DASHBOARD` snapshots for periods where no run has started reference no run.

---

## `metrics` JSONB shape

```json
{
  "income_total_eur":           "12500.00",
  "expense_total_eur":          "8300.00",
  "vat_liability_eur":          "2400.00",
  "match_rate_pct":             90,
  "open_issue_count_by_severity": {
    "BLOCKING": 2,
    "HIGH":     3,
    "MEDIUM":   5,
    "LOW":      8
  },
  "transaction_count":          20,
  "invoice_count_by_status": {
    "DRAFT":    2,
    "SENT":     5,
    "PAID":     3,
    "OVERDUE":  1
  }
}
```

Currency fields (`income_total_eur`, `expense_total_eur`, `vat_liability_eur`) are serialized as decimal-precise strings per `data_layer_conventions_policy` Section 3 — Currency special case. They are never floats.

`match_rate_pct` is an integer 0–100.

`open_issue_count_by_severity` uses the four values of the platform severity enum: `BLOCKING`, `HIGH`, `MEDIUM`, `LOW`. All four keys are always present; a count of `0` is explicit — it is not omitted.

`invoice_count_by_status` uses the four invoice status values. All four keys are always present.

---

## Rebuild triggers

A snapshot is rebuilt (a new `period_snapshots` row is inserted and the previous row is marked `is_stale = true`) on the following triggers:

| Trigger | Snapshot types rebuilt |
|---|---|
| `ARCHIVE_PROMOTION_COMPLETED` event | `DASHBOARD` and `REPORT` for the finalized period |
| Hourly tick during an active (non-terminal) run | `DASHBOARD` only |
| Manual operator request via `report.rebuild_analytics_snapshot` | `DASHBOARD` and `REPORT` |

The rebuild is executed by `report.rebuild_analytics_snapshot`. On rebuild:

1. The tool computes the `metrics` JSONB from current operational data.
2. A new `period_snapshots` row is inserted with `is_stale = false`, `computed_at = now()`.
3. The previous row for the same `(business_id, period_year, period_month, snapshot_type)` is updated to `is_stale = true`, `invalidated_at = now()`, `invalidation_reason = '<trigger description>'`.

Audit event emitted: `ANALYTICS_SNAPSHOT_REBUILT` per `audit_event_taxonomy`.

---

## Staleness

If the underlying data changes — a new issue is resolved, a transaction is reclassified, an invoice status transitions — and the snapshot has not been rebuilt within 1 hour, the snapshot is marked `is_stale = true`.

Staleness detection runs as a background job that queries:

- The `review_issues` table for issues whose `updated_at` is after the snapshot's `computed_at`.
- The `transactions` table for transactions whose `updated_at` is after `computed_at`.
- The `invoices` table for status changes after `computed_at`.

When any such newer record is found and the snapshot age exceeds 1 hour from `computed_at`, `is_stale = true` and `invalidated_at = now()` are written.

**Stale snapshots are still served.** The dashboard and report API do not block on a stale snapshot. Instead, a banner is appended to the API response when `is_stale = true`:

```json
{
  "data_freshness_warning": "Data may be up to 1 hour old. Refresh to see the latest."
}
```

The UI renders this as a non-blocking informational banner at the top of the dashboard or report view.

---

## Data zone and retention

Period snapshots are in the **Operational data zone** per the four-zone model:

- **Zone:** Operational
- **Retention:** 7 years after business deactivation
- **Object Lock:** Not applicable — snapshot rows are Postgres, not Object Storage
- **Archive promotion:** Snapshot rows are not promoted to the Archive zone. The archive bundle contains the immutable ledger and document set; snapshot rows are derived data and are not part of the sealed bundle.

Snapshot rows are subject to Postgres-level retention enforcement by the retention engine after the 7-year window. Deletion is executed by the `retention_engine` database role, not by any application role.

---

## Query pattern

The dashboard and report API query the latest non-stale snapshot for a period:

```sql
SELECT metrics, computed_at, is_stale
FROM period_snapshots
WHERE business_id   = $1
  AND period_year   = $2
  AND period_month  = $3
  AND snapshot_type = $4
ORDER BY computed_at DESC
LIMIT 1;
```

If `is_stale = true` on the returned row, the API includes the `data_freshness_warning` field. If no row exists (first period, no snapshot yet computed), the API falls back to a live query and queues a `report.rebuild_analytics_snapshot` job asynchronously.

---

## Cross-references

- `analytics_snapshot_schema.md` — related but distinct run-scoped snapshot table; `ANALYTICS_SNAPSHOT_REBUILT` event; version-controlled snapshot for comparison queries
- `report_job_schema.md` — `report_jobs` table that backs the `report.rebuild_analytics_snapshot` async job
- `dashboard_card_definitions_ui_spec.md` — card catalog and data source tool definitions; snapshot fields map to card metrics
- `period_comparison_schema.md` — prior-period delta computation that uses `period_snapshots` as its data source
