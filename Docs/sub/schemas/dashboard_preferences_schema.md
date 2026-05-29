# Dashboard Preferences Schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

Two complementary schemas that together define the per-user dashboard configuration layer and the analytics refresh dependency graph. First, an augmented `dashboard_user_preferences` table with the full set of preference columns. Second, a materialized-view dependency map — a reference table linking each of the 11 dashboard cards to its backing materialized view and the audit events that trigger a refresh of that view.

---

## 1. The `dashboard_user_preferences` table

This table augments the base table declared in Block 16 Phase 01 with the additional preference columns required by Phases 05, 07, and 08. The Phase 01 declaration is the authoritative schema owner; this sub-doc extends it with the full column set.

```sql
CREATE TABLE dashboard_user_preferences (
  preference_id           uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Identity (one row per user per business)
  user_id                 uuid NOT NULL REFERENCES users(id),
  business_id             uuid NOT NULL,
  organization_id         uuid NOT NULL,

  -- Card visibility: map of card_id → boolean
  -- Missing key means visible (default); explicit false means hidden
  hidden_card_ids         jsonb NOT NULL DEFAULT '[]'::jsonb,
  -- Array of card_id strings the user has hidden, e.g. ["cashflow_overview","vat_summary_card"]

  -- Sidebar
  sidebar_collapsed       boolean NOT NULL DEFAULT false,

  -- Detail-view rendering mode
  drilldown_mode          drilldown_mode_enum NOT NULL DEFAULT 'DRAWER',

  -- Theme
  theme                   theme_enum NOT NULL DEFAULT 'SYSTEM',

  -- Audit timestamp
  updated_at              timestamptz NOT NULL DEFAULT now(),
  created_at              timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  UNIQUE (business_id, user_id)
);

CREATE TYPE drilldown_mode_enum AS ENUM ('DRAWER', 'FULL_PAGE');

CREATE TYPE theme_enum AS ENUM ('LIGHT', 'DARK', 'SYSTEM');

CREATE INDEX idx_dashboard_prefs_user_business
  ON dashboard_user_preferences(user_id, business_id);
```

### Column notes

**`hidden_card_ids`** — stored as a JSONB array of `card_id` strings (text, matching `dashboard_card_definitions.card_id`). The inverse design (store hidden rather than visible) ensures forward-compatibility: new cards added to the system default to visible for all users without requiring a migration to add them to preference rows.

**`drilldown_mode`** — `DRAWER` renders transaction/document detail as a right-side panel; `FULL_PAGE` navigates to a dedicated detail page. Per Block 16 Phase 08.

**`theme`** — `SYSTEM` follows the user's OS preference via CSS `prefers-color-scheme`. Does not affect server-side rendering; the theme is applied client-side.

**`sidebar_collapsed`** — collapsed state of the primary navigation sidebar. Per Block 16 Phase 05.

### RLS

```sql
-- A user may only read and write their own preference row
CREATE POLICY dashboard_prefs_owner_only
  ON dashboard_user_preferences
  FOR ALL
  USING (user_id = auth.current_user_id());
```

Cross-user access is denied at the RLS layer. Owner/Admin have no special visibility into other users' dashboard preferences.

---

## 2. Materialized-view dependency map

Reference table: for each of the 11 dashboard cards, the backing materialized view name and the set of audit events that trigger a refresh of that view.

**Refresh semantics:**
- **Event-driven refresh:** the `ARCHIVE_PROMOTION_COMPLETED` subscriber in Block 16 Phase 01 refreshes affected views on each finalization. The dependency map below determines which views a given event touches.
- **Daily background refresh:** all analytics MVs are refreshed at 03:00 UTC by a background job. This catches changes from operational events (document indexing, VAT treatment decisions) that do not trigger `ARCHIVE_PROMOTION_COMPLETED`. Dashboards may lag up to 24 hours on low-activity businesses — this is an intentional eventual-consistency trade-off per the Block 04 Phase 09 Analytics zone contract.
- **Manual refresh:** `DASHBOARD_REFRESH_MANUAL` surface allows any role to trigger an immediate refresh for their business.

### Dependency map

| Card ID | Display name | Materialized view | Refresh-trigger events |
|---|---|---|---|
| `monthly_overview` | Monthly Overview | `mv_monthly_overview` | `ARCHIVE_PROMOTION_COMPLETED`, `STATEMENT_UPLOAD_COMPLETED` |
| `income_overview` | Income Overview | `mv_income_overview` | `ARCHIVE_PROMOTION_COMPLETED`, `INVOICE_PAID`, `INVOICE_PARTIALLY_PAID`, `IN_INVOICE_ALLOCATION_APPLIED` |
| `vat_summary` | VAT Summary | `mv_vat_summary` | `ARCHIVE_PROMOTION_COMPLETED`, `LEDGER_VAT_TREATMENT_DECIDED` |
| `missing_docs` | Missing Documents | `mv_missing_docs` | `DOCUMENT_SOURCE_INDEXED` (via `FILE_INDEXED`), `MATCHING_AUTO_CONFIRMED`, `MATCHING_USER_CONFIRMED`, `REVIEW_ISSUE_RESOLVED` |
| `invoice_aging` | Invoice Aging | `mv_invoice_aging` | `INVOICE_PAID`, `INVOICE_PARTIALLY_PAID`, `INVOICE_WRITTEN_OFF`, `INVOICE_CREDITED`, `ARCHIVE_PROMOTION_COMPLETED` |
| `supplier_spend` | Supplier Spend | `mv_supplier_spend` | `ARCHIVE_PROMOTION_COMPLETED`, `CLASSIFICATION_USER_RECLASSIFIED` |
| `run_progress` | Run Progress | `mv_run_progress` | `WORKFLOW_RUN_STATE_CHANGED`, `WORKFLOW_GATE_PASSED`, `WORKFLOW_GATE_HOLD` |
| `cashflow_trend` | Cashflow Trend | `mv_cashflow_trend` | `ARCHIVE_PROMOTION_COMPLETED` |
| `review_queue_summary` | Review Queue Summary | `mv_review_queue_summary` | `REVIEW_ISSUE_CREATED`, `REVIEW_ISSUE_RESOLVED`, `REVIEW_ISSUE_DISMISSED`, `REVIEW_AUTO_RESOLVED_BY_RESCAN` |
| `vies_status` | VIES Status | `mv_vies_status` | `ARCHIVE_PROMOTION_COMPLETED`, `LEDGER_VIES_PERIOD_ASSIGNED`, `LEDGER_VIES_PERIOD_CHANGED` |
| `client_outstanding` | Client Outstanding | `mv_client_outstanding` | `INVOICE_PAID`, `INVOICE_PARTIALLY_PAID`, `INVOICE_WRITTEN_OFF`, `INVOICE_CREDITED`, `CLIENT_CREATED`, `CLIENT_UPDATED` |

### Refresh-trigger notes

- `ARCHIVE_PROMOTION_COMPLETED` is the canonical batch-refresh trigger. After every finalization, all finance-figure cards are refreshed.
- Operational events (invoice payments, review-issue resolutions) trigger targeted refreshes of the cards that consume live operational data. These refreshes run via the event-subscription pipeline, not the daily job.
- `mv_run_progress` is the only card that subscribes to `WORKFLOW_RUN_STATE_CHANGED` directly — it shows real-time run status and benefits from near-real-time refresh.
- The daily 03:00 UTC background job is a catch-all for events not covered above (e.g., `CLASSIFICATION_LAYER_1_DECIDED`, document OCR completions) — these affect reporting data but are too high-frequency to trigger per-event MV refreshes in MVP.

---

## 3. Audit events

| Event | When |
|---|---|
| `DASHBOARD_PREFERENCES_UPDATED` | Any change to a `dashboard_user_preferences` row |

This event already exists in the `DASHBOARD` domain of `audit_event_taxonomy`.

---

## Cross-references
- `data_layer_conventions_policy` — UUID v7 PK generation; JSONB canonical encoding for `hidden_card_ids`
- `audit_log_policies` — `DASHBOARD_PREFERENCES_UPDATED` event naming
- `audit_event_taxonomy` — `DASHBOARD` domain events; cross-reference to `ARCHIVE_PROMOTION_COMPLETED` trigger
- `permission_matrix` — `DASHBOARD_VIEW`, `DASHBOARD_REFRESH_MANUAL` surfaces
- Block 16 Phase 01 — base `dashboard_user_preferences` table definition; `dashboard_card_definitions` registry
- Block 16 Phase 05 — sidebar collapse state
- Block 16 Phase 07 — manual refresh flow
- Block 16 Phase 08 — `drilldown_mode` preference consumption
- Block 04 Phase 09 — Analytics zone; `REFRESH MATERIALIZED VIEW CONCURRENTLY` primitive
- Block 15 Phase 04 — `ARCHIVE_PROMOTION_COMPLETED` emitter

---

## 4. Default values and first-run behaviour

When a user accesses the dashboard for the first time, no `dashboard_user_preferences` row exists for them. The application treats a missing row as equivalent to a row with all defaults:

| Column | Default behaviour when row absent |
|---|---|
| `hidden_card_ids` | All 11 cards are visible |
| `sidebar_collapsed` | Sidebar expanded |
| `drilldown_mode` | `DRAWER` |
| `theme` | `SYSTEM` (follows OS) |

The preference row is only written on the first explicit user preference change (lazy initialization). This avoids creating 11-card-visible rows for every user on every business at boot, which would create unnecessary write traffic for organizations with many users.

The `DASHBOARD_PREFERENCES_UPDATED` audit event is emitted only when the preference row is explicitly written, not on first-read resolution of defaults.

---

## 5. Multi-business context

Per `permission_matrix`, the `DASHBOARD_VIEW` surface is granted to every role. Users who hold roles on multiple businesses within an organization have separate `dashboard_user_preferences` rows per `(user_id, business_id)`. Preferences on business A do not affect the dashboard on business B.

The multi-business consolidated view (Block 16 Phase 12) renders with a merged card layout that does not consume per-business preferences — it uses a fixed layout. Per-business preferences apply only to the single-business dashboard view.
