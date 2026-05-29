# Drill-Down Schemas

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

Request and response schemas for dashboard drill-down queries — the read path that allows users to click a summary metric card and retrieve the underlying records. All queries are serviced by the `report.drill_down` tool, which is `READ_ONLY` side-effect class. Responses are paginated snapshots; they do not subscribe to real-time updates.

---

## 1. The `report.drill_down` tool

```typescript
engine.registerTool({
  name: "report.drill_down",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  audit_events: ["DASHBOARD_DRILL_DOWN_QUERIED"],
  description_ref: "Docs/sub/tools/tool_report_drill_down.md",
});
```

The tool accepts a discriminated union request keyed on `query_type` and returns a typed paginated response. It is the single entry point for all drill-down queries; the underlying data-access strategy (operational vs archive zone) is internal to the tool.

**Mobile:** read-only drill-down queries are permitted on mobile. The `report.drill_down` endpoint is not listed in `mobile_write_rejection_endpoints`.

**Permission:** `DASHBOARD_VIEW` surface is required. Archive-zone reads additionally require `REPORT_EXPORT_BASIC` or `REPORT_EXPORT_FULL` per `permission_matrix`.

---

## 2. Shared request envelope

```typescript
interface DrillDownRequest {
  query_type: DrillDownQueryType;    // discriminator
  business_id: string;               // UUID v7
  page: number;                      // 1-indexed; default 1
  page_size: number;                 // min 1; max 200; default 50
  sort_by?: string;                  // per-query-type allowlist
  sort_direction?: 'ASC' | 'DESC';   // default DESC
  filters?: DrillDownFilters;        // query-type-specific
  params: DrillDownParams;           // query-type-specific
}

type DrillDownQueryType =
  | 'TRANSACTION_LIST'
  | 'MATCH_BREAKDOWN'
  | 'VAT_BREAKDOWN'
  | 'REVIEW_ISSUE_LIST'
  | 'INVOICE_LIST';
```

All responses share a common pagination envelope:

```typescript
interface DrillDownPageEnvelope {
  query_type: DrillDownQueryType;
  page: number;
  page_size: number;
  total_count: number;
  snapshot_at: string;               // ISO 8601 timestamptz — data read time
  items: unknown[];                  // typed per query_type below
}
```

---

## 3. Query types

### 3.1 `TRANSACTION_LIST`

Transactions for a period or run. Typical callers: Cashflow Trend, Monthly Overview, Supplier Spend, Missing Documents cards.

Key params: `period_start` / `period_end` / `workflow_run_id` (at least one required). Filters: `transaction_type[]`, `tag[]`, `direction` (`IN | OUT`), `effective_match_status[]`, `counterparty_name_contains`, `amount_min`, `amount_max`, `finalization_status` (`DRAFT | LOCKED`). Sort allowlist: `transaction_date`, `amount_signed`, `counterparty_name`.

Item shape: `transaction_id`, `transaction_date`, `counterparty_name`, `amount_signed` (decimal string EUR), `currency`, `transaction_type`, `tag`, `effective_match_status`, `vat_treatment`, `finalization_status`, `workflow_run_id`.

### 3.2 `MATCH_BREAKDOWN`

Match records for a period and match level. Typical caller: Missing Documents card.

Key params: `period_start` / `period_end` / `workflow_run_id` (at least one required). Filters: `match_status[]`, `match_type[]` (`AUTO_CONFIRMED | USER_CONFIRMED | REJECTED | NO_MATCH`), `direction`. Sort allowlist: `transaction_date`, `score`, `match_status`.

Item shape: `match_record_id` (nullable for NO_MATCH), `transaction_id`, `document_id`, `match_status`, `score` (nullable), `transaction_date`, `transaction_amount_signed`, `document_type`.

### 3.3 `VAT_BREAKDOWN`

Transactions grouped by VAT treatment for a period. Typical caller: VAT Summary card.

Key params: `period_start` and `period_end` (both required). Filters: `vat_treatment[]` (subset of the 8 `vat_treatment_enum` values), `direction`, `finalization_status`. Sort allowlist: `vat_treatment`, `net_amount_eur`, `transaction_count`.

Item shape: `transaction_id`, `transaction_date`, `counterparty_name`, `amount_signed`, `vat_treatment`, `vat_amount`, `account_code`, `finalization_status`.

Response additionally carries a top-level `summary.by_treatment[]` aggregate (always present regardless of pagination) with per-treatment `transaction_count`, `net_amount_eur`, `vat_amount_eur`.

### 3.4 `REVIEW_ISSUE_LIST`

Review issues by severity and group. Typical caller: Review Queue Summary card.

Key params: `workflow_run_id` or `business_id` scoping. Filters: `severity[]` (from `{LOW, MEDIUM, HIGH, BLOCKING}`), `issue_group[]` (5 values from `issue_group_enum`), `status[]`, `assigned_to_user_id`, `created_after`, `created_before`. Default sort: `severity DESC, created_at ASC`.

Item shape: `review_issue_id`, `issue_type`, `issue_group`, `severity`, `status`, `title` (plain-language from `card_payload_json`), `assigned_to_user_id`, `created_at`, `workflow_run_id`.

### 3.5 `INVOICE_LIST`

Invoices by status. Typical callers: Invoice Aging, Client Outstanding cards.

Key params: `period_start` / `period_end` / `workflow_run_id` (at least one required). Filters: `lifecycle_status[]`, `client_id`, `invoice_type` (`PRO_FORMA | TAX_INVOICE`), `currency`, `days_outstanding_min`, `days_outstanding_max`. Sort allowlist: `issue_date`, `amount_eur`, `days_outstanding`, `lifecycle_status`.

Item shape: `invoice_id`, `invoice_number`, `client_id`, `client_name`, `issue_date`, `amount` (decimal string), `currency`, `lifecycle_status`, `days_outstanding` (nullable), `invoice_type`, `workflow_run_id`.

---

## 4. Snapshot semantics

Responses are point-in-time snapshots. `snapshot_at` records when the data was read. No real-time subscription is provided. For archive-zone reads (`finalization_status = LOCKED`), snapshots are always consistent because locked data is immutable.

---

## 5. Audit events

| Event | Severity | When |
|---|---|---|
| `DASHBOARD_DRILL_DOWN_QUERIED` | LOW | One event per `report.drill_down` invocation; payload includes `query_type`, `business_id`, `page`, `page_size`, `total_count` |

`DASHBOARD_DRILL_DOWN_QUERIED` is the schema-layer query event. The existing `DASHBOARD_DRILL_DOWN_ACCESSED` event in `audit_event_taxonomy` is emitted by the routing layer (Block 16 Phase 02) on navigation; these two events are complementary, not duplicates.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 identifiers; decimal string amounts; canonical JSON for audit payloads
- `dashboard_preferences_schema` — `drilldown_mode` preference (`DRAWER | FULL_PAGE`) consuming drill-down responses
- `tool_naming_convention_policy` — `report.drill_down` tool name; `report` namespace; `READ_ONLY` side-effect class
- `audit_log_policies` — `DASHBOARD_DRILL_DOWN_QUERIED` event naming; `DASHBOARD` domain
- `audit_event_taxonomy` — `DASHBOARD` domain events
- `permission_matrix` — `DASHBOARD_VIEW` surface; `REPORT_EXPORT_BASIC` / `REPORT_EXPORT_FULL` for archive reads
- `mobile_write_rejection_endpoints` — read-only drill-down is NOT listed (permitted on mobile)
- `vat_treatment_enum` — 8-value closed enum referenced in VAT_BREAKDOWN query
- `locked_ledger_entries_schema` — archive-zone source for `finalization_status = LOCKED` queries
- Block 16 Phase 02 — drill-down routing and permission filtering
- Block 16 Phase 08 — list and detail view surfaces consuming drill-down responses
- Block 14 Phase 02 — issue group and severity taxonomy for REVIEW_ISSUE_LIST
