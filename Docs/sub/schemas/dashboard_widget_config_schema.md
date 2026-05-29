# Dashboard Widget Config Schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The `dashboard_widget_configs` table stores per-user, per-business widget layout and configuration for the main dashboard. It separates the physical widget layout grid (position, size) and widget-specific settings (date range, chart type, filter presets) from the broader user preferences stored in `dashboard_user_preferences`. While `dashboard_user_preferences` covers card visibility toggles, sidebar state, and theme, this table covers the spatial arrangement and parameterisation of configurable widgets within the dashboard canvas.

---

## 1. Table definition

```sql
CREATE TABLE dashboard_widget_configs (
  config_id           uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Identity
  user_id             uuid NOT NULL REFERENCES users(id),
  business_id         uuid NOT NULL,

  -- Widget type from the closed enum
  widget_type         dashboard_widget_type_enum NOT NULL,

  -- Layout position in a 12-column grid
  -- { "row": integer, "col": integer, "width": integer, "height": integer }
  position_json       jsonb NOT NULL,

  -- Widget-specific settings
  -- { "date_range": ..., "chart_type": ..., "filter_preset": ... }
  settings_json       jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Visibility flag: false = widget is rendered but hidden via CSS
  -- Distinct from card-level hiding in dashboard_user_preferences
  is_visible          boolean NOT NULL DEFAULT true,

  -- Timestamps
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- One row per user per business per widget type
  UNIQUE (user_id, business_id, widget_type)
);

CREATE TYPE dashboard_widget_type_enum AS ENUM (
  'PERIOD_SUMMARY',
  'CASH_FLOW',
  'VAT_SUMMARY',
  'REVIEW_QUEUE_STATUS',
  'MATCH_RATE',
  'RECENT_INVOICES',
  'ANALYTICS_CHART'
);

CREATE INDEX idx_dashboard_widget_configs_user_business
  ON dashboard_widget_configs(user_id, business_id);
```

---

## 2. Field reference

| Field | Type | Notes |
|---|---|---|
| `config_id` | UUID v7 PK | Monotonically increasing per `data_layer_conventions_policy` |
| `user_id` | UUID FK | References `users.id`; tenant-scoped per Section 5 |
| `business_id` | UUID | Tenant scope; RLS-enforced per Section 5 |
| `widget_type` | enum | One of the 7 closed values; see Section 3 |
| `position_json` | JSONB | Grid layout coordinates; shape: `{ "row": integer, "col": integer, "width": integer, "height": integer }`; values are non-negative integers bounded by the 12-column grid |
| `settings_json` | JSONB | Widget-specific settings; shape varies by `widget_type`; see Section 3 |
| `is_visible` | boolean | Whether the widget is currently displayed; default `true` |
| `created_at` | timestamptz | Row insert time |
| `updated_at` | timestamptz | Last update time; application code must update this on any change to `position_json`, `settings_json`, or `is_visible` |

---

## 3. Widget types and settings shapes

### `PERIOD_SUMMARY`

Displays a summary of the current or selected period's financial totals (revenue, expenses, net, VAT payable). Sources from `analytics_snapshots` for finalized periods.

```json
{
  "period_selector": "CURRENT | LAST | CUSTOM",
  "custom_period_start": "2026-01-01",
  "custom_period_end": "2026-01-31"
}
```

### `CASH_FLOW`

Displays a cash-flow timeline for the selected range.

```json
{
  "range_months": 3,
  "show_projections": false
}
```

### `VAT_SUMMARY`

Displays VAT payable and input VAT reclaim breakdown. Sources from `analytics_snapshots`.

```json
{
  "period_selector": "CURRENT | LAST | CUSTOM",
  "custom_period_start": "2026-01-01",
  "custom_period_end": "2026-01-31"
}
```

### `REVIEW_QUEUE_STATUS`

Displays the count of open review issues by severity for the current run.

```json
{
  "show_severity_breakdown": true,
  "filter_groups": []
}
```

### `MATCH_RATE`

Displays the percentage of transactions matched to invoices for the current period.

```json
{
  "period_selector": "CURRENT | LAST"
}
```

### `RECENT_INVOICES`

Displays the most recently created or updated invoices.

```json
{
  "max_items": 10,
  "status_filter": ["SENT", "PARTIALLY_PAID", "PAID"]
}
```

### `ANALYTICS_CHART`

A configurable chart sourced from `analytics_snapshots`. This is the most flexible widget; it supports multiple chart types and data dimensions.

```json
{
  "chart_type": "BAR | LINE | PIE",
  "data_dimension": "REVENUE | EXPENSES | NET | VAT",
  "period_count": 6,
  "period_unit": "MONTH"
}
```

---

## 4. Grid layout constraints

The dashboard canvas is a 12-column grid with an unbounded row count. The following constraints apply to `position_json`:

- `col` must be in `[0, 11]` (0-indexed).
- `width` must be in `[1, 12]`.
- `col + width` must be `<= 12` (widget must not overflow the grid horizontally).
- `row` must be `>= 0`.
- `height` must be `>= 1`.

These constraints are validated at the application layer before INSERT or UPDATE. No Postgres CHECK constraint encodes them because the bounds depend on composite field relationships across `position_json` properties.

Collision detection (two widgets for the same user occupying the same grid cell) is enforced at the application layer. The database does not enforce non-overlapping placement; the application validates the full layout before persisting changes.

---

## 5. RLS

Users may only SELECT, INSERT, and UPDATE their own widget config rows. Cross-user access is denied.

```sql
-- A user may only access their own widget configs
CREATE POLICY dashboard_widget_configs_owner_only
  ON dashboard_widget_configs
  FOR ALL
  USING (
    user_id = auth.current_user_id()
    AND business_id = ANY (auth.business_ids_for_session())
  );
```

Owner and Admin roles have no special visibility into other users' widget configurations. Each user's layout is private.

---

## 6. Audit events

Layout changes (position, visibility, settings) are non-operational preference data. Widget config changes are **not** audit-logged. The rationale: widget layout is a UI personalization preference with no operational or compliance significance. Writing an audit event for every drag-and-drop layout adjustment would generate high-volume, low-value entries with no forensic utility.

This exemption is analogous to the `DASHBOARD_PREFERENCES_UPDATED` event in `dashboard_preferences_schema`, which is emitted only for the preference write — not for intermediate transient states. For `dashboard_widget_configs`, even the persisted writes are not audit-logged.

If the platform's compliance posture changes and audit-logging of layout changes becomes required, a new event in the `DASHBOARD` domain of `audit_event_taxonomy` can be added without a migration of this table.

---

## 7. Mobile rejection

The dashboard is read-only on mobile. Widget config writes (INSERT, UPDATE) are rejected on mobile clients per the platform-wide mobile write rejection policy. The endpoint that persists widget layout changes is listed in `mobile_write_rejection_endpoints.md`. Mobile clients render the dashboard using the last saved layout (or the default layout if no config exists) as a read-only view.

Widget config reads (SELECT) are available on mobile to render the dashboard layout in read-only mode.

---

## 8. Default layout

When a user accesses the dashboard for the first time and has no `dashboard_widget_configs` rows, the application renders the default layout defined in the dashboard shell (Block 16 Phase 05). The default layout places all 7 widget types in a predefined grid arrangement. Widget config rows are only written on the first explicit layout change by the user (lazy initialization), consistent with the lazy-initialization pattern in `dashboard_preferences_schema`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; JSONB canonical encoding for `position_json` and `settings_json`; `updated_at` column convention
- `dashboard_preferences_schema` — complementary user preference table covering card visibility, sidebar, theme, and drilldown mode; lazy-initialization pattern
- `analytics_snapshot_schema` — data source for `PERIOD_SUMMARY`, `VAT_SUMMARY`, and `ANALYTICS_CHART` widget types
- `audit_log_policies` — rationale for non-logging of non-operational preference data; `DASHBOARD` domain events
- `audit_event_taxonomy` — `DASHBOARD` domain; no new events added by this schema
- `mobile_write_rejection_endpoints` — widget config update endpoint listed as mobile-rejected
- Block 16 Phase 01 — analytics consumption; dashboard data sourcing
- Block 16 Phase 05 — dashboard shell; default layout specification
- Block 16 Phase 06 — individual dashboard card implementations that correspond to each `widget_type`
- Block 16 Phase 07 — multi-business view and per-user customization architecture
