# Analytics Snapshot Schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

Defines the `analytics_snapshots` table — pre-computed period-level financial aggregates that power the dashboard's finance cards without requiring live queries against large transaction and ledger tables. Snapshots are rebuilt after each finalization event and versioned so that the current snapshot can be identified while historical versions are retained for comparison queries.

---

## 1. Table definition

```sql
CREATE TABLE analytics_snapshots (
  snapshot_id                 uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Tenant and period scope
  business_id                 uuid NOT NULL,
  period_start                date NOT NULL,
  period_end                  date NOT NULL,

  -- Run linkage — which run's data this snapshot reflects
  workflow_run_id             uuid NOT NULL
                                REFERENCES workflow_runs(workflow_run_id),

  -- Version control
  snapshot_version            integer NOT NULL
                                CHECK (snapshot_version >= 1),
  is_current                  boolean NOT NULL DEFAULT true,

  -- Revenue and expense aggregates (EUR, numeric — no floats per data_layer_conventions_policy)
  total_revenue_eur           numeric(15,2) NOT NULL,
  total_expenses_eur          numeric(15,2) NOT NULL,
  net_eur                     numeric(15,2) NOT NULL,
  vat_payable_eur             numeric(15,2) NOT NULL,

  -- Transaction counts
  transaction_count           integer NOT NULL
                                CHECK (transaction_count >= 0),
  matched_invoice_count       integer NOT NULL
                                CHECK (matched_invoice_count >= 0),
  unmatched_transaction_count integer NOT NULL
                                CHECK (unmatched_transaction_count >= 0),

  -- Open review issues at snapshot time
  open_review_issue_count     integer NOT NULL
                                CHECK (open_review_issue_count >= 0),

  -- Computation timestamps
  computed_at                 timestamptz NOT NULL,
  created_at                  timestamptz NOT NULL DEFAULT now(),

  -- One row per (business, period, version)
  UNIQUE (business_id, period_start, period_end, snapshot_version)
);

CREATE INDEX idx_analytics_snapshots_current
  ON analytics_snapshots(business_id, period_start, period_end)
  WHERE is_current = true;

CREATE INDEX idx_analytics_snapshots_run
  ON analytics_snapshots(workflow_run_id);

CREATE INDEX idx_analytics_snapshots_business_period
  ON analytics_snapshots(business_id, period_start DESC);
```

---

## 2. Field reference

| Field | Type | Notes |
|---|---|---|
| `snapshot_id` | UUID v7 PK | Monotonically increasing per `data_layer_conventions_policy` |
| `business_id` | UUID | Tenant scope; RLS-enforced per Section 4 |
| `period_start` | date | Inclusive start of the period this snapshot covers |
| `period_end` | date | Inclusive end of the period |
| `workflow_run_id` | UUID FK | The run whose finalized data was the source for this snapshot |
| `snapshot_version` | integer | `1` for the first snapshot of a period; incremented on each rebuild triggered by subsequent adjustment-run finalizations |
| `is_current` | boolean | `true` for the latest version; `false` for superseded versions |
| `total_revenue_eur` | numeric(15,2) | Sum of all income-side locked ledger entries for the period, in EUR |
| `total_expenses_eur` | numeric(15,2) | Sum of all expense-side locked ledger entries for the period, in EUR |
| `net_eur` | numeric(15,2) | `total_revenue_eur - total_expenses_eur`; may be negative |
| `vat_payable_eur` | numeric(15,2) | Net VAT liability for the period per Cyprus VAT rules |
| `transaction_count` | integer | Total transaction count for the period |
| `matched_invoice_count` | integer | Count of transactions matched to at least one invoice |
| `unmatched_transaction_count` | integer | Count of transactions with no confirmed match |
| `open_review_issue_count` | integer | Count of `review_issues` rows with non-terminal status at snapshot time |
| `computed_at` | timestamptz | When the aggregation query ran; distinct from `created_at` (row insert time) |
| `created_at` | timestamptz | Row insert time |

---

## 3. Rebuild trigger and versioning

**Primary trigger:** `ARCHIVE_PROMOTION_COMPLETED` (cross-block event from Block 15 Phase 04/06) causes Block 16 to rebuild the snapshot for the affected `(business_id, period_start, period_end)`. The rebuild:
1. Queries `archive.locked_ledger_entries` and related tables for the period aggregates.
2. Inserts a new row with `snapshot_version = (previous_max + 1)` and `is_current = true`.
3. Sets `is_current = false` on the previous current row.

**Stale state:** snapshots may be stale in non-finalized periods (draft data). The `analytics_stale_state_ui_spec` governs how the dashboard communicates staleness to users. Snapshots are not pre-computed for draft (non-finalized) periods in MVP; draft-period figures are served from materialized views (`mv_monthly_overview` etc.) per `dashboard_preferences_schema`.

**No snapshot without finalization:** a snapshot row is only created after `ARCHIVE_PROMOTION_COMPLETED`. A period with no finalized run has no row in this table and the dashboard shows the draft-MV figures instead.

---

## 4. RLS

```sql
-- Tenant isolation: all authenticated roles may read snapshots for their business
CREATE POLICY analytics_snapshots_read
  ON analytics_snapshots
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

-- INSERT: only Block 16 analytics rebuild tools
CREATE POLICY analytics_snapshots_insert_rebuild
  ON analytics_snapshots
  FOR INSERT
  WITH CHECK (
    current_setting('app.analytics_rebuild_active', true) = 'true'
  );

-- UPDATE: restricted to setting is_current = false during version supersede
CREATE POLICY analytics_snapshots_update_supersede
  ON analytics_snapshots
  FOR UPDATE
  USING (
    current_setting('app.analytics_rebuild_active', true) = 'true'
  )
  WITH CHECK (is_current = false);

-- DELETE: blocked unconditionally
CREATE POLICY analytics_snapshots_no_delete
  ON analytics_snapshots
  FOR DELETE
  USING (false);
```

---

## 5. Mobile rejection

Read access to `analytics_snapshots` data (via the dashboard API) is available on mobile. The rebuild path (INSERT/UPDATE) is performed exclusively by Block 16 internal tools triggered by event subscriptions or scheduled jobs — no client-facing write surface exists. Those tools are listed in `mobile_write_rejection_endpoints`.

---

## 6. Audit events

| Event | Severity | When |
|---|---|---|
| `ANALYTICS_SNAPSHOT_REBUILT` | LOW | Emitted when a new snapshot row is inserted. Payload includes `snapshot_id`, `business_id`, `period_start`, `period_end`, `snapshot_version`, `workflow_run_id`, `computed_at` |

`ANALYTICS_SNAPSHOT_REBUILT` is LOW severity because snapshot rebuilds are expected, routine events that follow every finalization. The event is on the business-scoped hash chain per `audit_log_policies`. It is an `ANALYTICS` domain event.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; `numeric(15,2)` currency columns (no floats); date and timestamptz conventions; canonical JSON for audit payloads
- `period_comparison_schema` — period-over-period comparison queries consume `analytics_snapshots` rows; both `snapshot_id` references resolve to rows in this table
- `dashboard_preferences_schema` — materialized-view dependency map; `ARCHIVE_PROMOTION_COMPLETED` as the rebuild trigger; `mv_monthly_overview` and related MVs as the draft-period counterparts
- `locked_ledger_entries_schema` — source data for `total_revenue_eur`, `total_expenses_eur`, `net_eur`, `vat_payable_eur` aggregates
- `audit_log_policies` — `ANALYTICS_SNAPSHOT_REBUILT` event naming; `ANALYTICS` domain; business-scoped hash chain
- `audit_event_taxonomy` — `ANALYTICS` domain canonical events; `ANALYTICS_SNAPSHOT_REBUILT` entry; `ARCHIVE_PROMOTION_COMPLETED` cross-block trigger
- `mobile_write_rejection_endpoints` — analytics rebuild tools listed as mobile-rejected
- `workflow_state_enum` — `workflow_run_id` FK; `FINALIZED` state as the pre-condition for `ARCHIVE_PROMOTION_COMPLETED`
- `analytics_refresh_runbook` — operational runbook for manual snapshot rebuild; stale state remediation
- `analytics_stale_state_ui_spec` — UI specification for communicating snapshot staleness to users
- `block_16_as_of_view_schema` — as-of-period query view that selects from the current snapshot
- Block 16 Phase 01 — analytics consumption architecture; MV dependency graph; event-subscription rebuild path
- Block 15 Phase 04 — `ARCHIVE_PROMOTION_COMPLETED` emitter; cross-block event contract
- Block 04 Phase 09 — Analytics zone contract; eventual-consistency trade-offs
