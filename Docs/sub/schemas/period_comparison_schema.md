# Period Comparison Schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

Defines the query response schema for period-over-period comparison — the data structure returned when a user selects two finalized periods to view side-by-side on the dashboard. This is a query response schema (not a stored table). Rows are computed on-demand by the `report.compare_periods` tool from the current `analytics_snapshots` for the requested periods.

---

## 1. Overview

Period comparison is a read-only analytical feature. The user selects a base period and a comparison period; the tool fetches both current snapshots, computes absolute and percentage deltas, and returns the structured response. No state is persisted. The response is point-in-time; it does not subscribe to updates.

Both periods must be finalized (have an `analytics_snapshots` row with `is_current = true`) before a comparison can be served. If either period has no current snapshot, the tool returns a structured error rather than partial data.

---

## 2. The `report.compare_periods` tool

```typescript
engine.registerTool({
  name: "report.compare_periods",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  audit_events: ["PERIOD_COMPARISON_QUERIED"],
  description_ref: "Docs/sub/tools/tool_report_compare_periods.md",
});
```

**Side-effect class:** `READ_ONLY` — no writes to any operational or archive table. `WRITES_AUDIT` for the `PERIOD_COMPARISON_QUERIED` event.

**Permission:** `DASHBOARD_VIEW` surface is required. No additional step-up or export permission is required for the comparison query itself; both periods are finalized and their aggregate snapshots are not restricted beyond tenant isolation.

---

## 3. Request schema

```typescript
interface PeriodComparisonRequest {
  business_id: string;        // UUID v7

  base_period: {
    period_start: string;     // ISO 8601 date, e.g. "2025-01-01"
    period_end: string;       // ISO 8601 date, e.g. "2025-01-31"
  };

  comparison_period: {
    period_start: string;
    period_end: string;
  };
}
```

The `base_period` is the reference period against which percentage changes are computed. The `comparison_period` is the other period. The UI convention is: `base_period` = more recent period; `comparison_period` = earlier period, yielding positive deltas for growth. This convention is advisory — the tool accepts either ordering.

---

## 4. Response schema

```typescript
interface PeriodComparisonResponse {
  base_period: PeriodRef;
  comparison_period: PeriodRef;
  delta: PeriodDelta;
  base_snapshot: AnalyticsSnapshot;
  comparison_snapshot: AnalyticsSnapshot;
  generated_at: string;       // ISO 8601 timestamptz — when this response was computed
}

interface PeriodRef {
  period_start: string;       // ISO 8601 date
  period_end: string;         // ISO 8601 date
  snapshot_id: string;        // UUID — the analytics_snapshots row used
}

interface PeriodDelta {
  /** Absolute differences: base_value - comparison_value */
  revenue_eur_delta: string;        // decimal string; negative = revenue fell
  expenses_eur_delta: string;       // decimal string
  net_eur_delta: string;            // decimal string
  vat_payable_eur_delta: string;    // decimal string

  /**
   * Percentage changes: (base_value - comparison_value) / abs(comparison_value) * 100
   * null when comparison_value is zero (division guard — see Section 5)
   * Represented as decimal strings, e.g. "12.50" for 12.5%
   */
  revenue_pct_change: string | null;
  expenses_pct_change: string | null;
  net_pct_change: string | null;
}

interface AnalyticsSnapshot {
  snapshot_id: string;
  business_id: string;
  period_start: string;
  period_end: string;
  workflow_run_id: string;
  snapshot_version: number;
  total_revenue_eur: string;        // decimal string
  total_expenses_eur: string;
  net_eur: string;
  vat_payable_eur: string;
  transaction_count: number;
  matched_invoice_count: number;
  unmatched_transaction_count: number;
  open_review_issue_count: number;
  computed_at: string;
}
```

Currency values in the response are decimal strings (e.g., `"12345.67"`), not floating-point numbers, per `data_layer_conventions_policy` canonical JSON serialization rules for currency.

---

## 5. Validation and error handling

**Both periods must have current snapshots.** Before computing the delta, the tool verifies that `analytics_snapshots` contains a row with `is_current = true` for both `(business_id, period_start, period_end)` pairs. If either is missing, the tool returns a structured error:

```typescript
interface PeriodComparisonError {
  error_code: 'SNAPSHOT_NOT_FOUND_BASE' | 'SNAPSHOT_NOT_FOUND_COMPARISON';
  missing_period_start: string;
  missing_period_end: string;
  message: string;
}
```

Partial data is never returned — the caller receives either a complete `PeriodComparisonResponse` or an error.

**Division guard for percentage changes.** When a `comparison_value` is zero, the percentage change for that metric is `null`. The UI is expected to render `null` percentage changes as "N/A" rather than zero or infinity. This applies independently per metric — a period with `comparison_period.total_revenue_eur = 0` returns `null` for `revenue_pct_change` but may still return a numeric `expenses_pct_change`.

**Period ordering.** The tool does not enforce that `base_period` is more recent than `comparison_period`. Both orderings are valid. A future period may be compared to a past period (e.g., for budget-vs-actuals workflows). The sign of delta values reflects the formula: `base - comparison`.

---

## 6. Mobile

Period comparison is a read-only query. Mobile clients may invoke `report.compare_periods`. The endpoint is not listed in `mobile_write_rejection_endpoints`. Response payload sizes are bounded by the fixed set of aggregate fields (no pagination required).

---

## 7. Audit events

| Event | Severity | When |
|---|---|---|
| `PERIOD_COMPARISON_QUERIED` | LOW | Emitted once per `report.compare_periods` invocation. Payload includes `business_id`, `base_period_start`, `base_period_end`, `comparison_period_start`, `comparison_period_end`, `base_snapshot_id`, `comparison_snapshot_id`, `generated_at` |

`PERIOD_COMPARISON_QUERIED` is LOW severity — this is a read-only analytical query. The event is on the business-scoped hash chain per `audit_log_policies`. It is a `REPORT` domain event (see `audit_event_taxonomy`).

---

## Cross-references

- `data_layer_conventions_policy` — decimal string serialization for currency in response payload; UUID v7 for `snapshot_id` references; canonical JSON serialization
- `analytics_snapshot_schema` — `analytics_snapshots` table providing both `base_snapshot` and `comparison_snapshot`; `is_current` flag validation; `numeric(15,2)` currency type converted to decimal strings in response
- `drill_down_schemas` — `report.drill_down` sibling tool; `DASHBOARD_VIEW` permission surface; response pagination envelope pattern (comparison uses a non-paginated single response)
- `dashboard_preferences_schema` — multi-period comparison entry point from the dashboard cards; `ARCHIVE_PROMOTION_COMPLETED` trigger that ensures snapshots are current
- `tool_naming_convention_policy` — `report.compare_periods` tool name; `report` namespace; `READ_ONLY` side-effect class
- `audit_log_policies` — `PERIOD_COMPARISON_QUERIED` event naming; `REPORT` domain; business-scoped hash chain
- `audit_event_taxonomy` — `REPORT` domain canonical events; `PERIOD_COMPARISON_QUERIED` entry
- `mobile_write_rejection_endpoints` — `report.compare_periods` is not listed (read-only, permitted on mobile)
- `permission_matrix` — `DASHBOARD_VIEW` surface requirement
- Block 16 Phase 06 — default dashboard cards; period comparison entry point on Monthly Overview card
- Block 16 Phase 02 — drill-down routing and permissions; `report.compare_periods` routing
