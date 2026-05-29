# Multi-Business View, Refresh State & Per-User Customization

Three intertwined behaviors layered on top of the single-business shell (B16·P05) and the 11 cards (B16·P06):

1. **Multi-business consolidated view** — aggregated overview when a user has access to ≥ 2 businesses.
2. **Refresh-state UI** — banner + per-card stale indicator + manual "Refresh now" action.
3. **Per-user customization** — card hide / show with per-business scope; rearrange deferred to Stage 2+.

**Phase**: B16·P07 (BOOK-154) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/07_multi_business_view_refresh_state_and_customization.md` · **Schema**: `dashboard_user_preferences` + `dashboard_refresh_state` + `dashboard_processed_events` from B16·P01

---

## Multi-business consolidated view

Available to users with access to ≥ 2 businesses inside an organization. The business switcher's first entry is **"Multi-business overview"**; users with only 1 business see the single-business dashboard directly (no entry surfaces).

### Per-card aggregation rules

| Card | Aggregation rule |
|---|---|
| **Monthly Overview** | average progress %; severity rolls up to **MAX** (any single BLOCKING in any business → BLOCKING badge) |
| **Income Overview** | sum across businesses; trend line is the summed series |
| **Expense Overview** | sum; symmetric with Income |
| **Missing Documents** | sum count across businesses |
| **Review Issues** | sum per-bucket counts |
| **VAT Summary** | sum per-treatment totals — "orientation only — drill into specific business" footer link (per-business VAT positions are independently meaningful) |
| **Subscriptions** | sum monthly recurring; top vendors aggregated globally |
| **Team Member Costs** | sum month-to-date |
| **Client Invoice Status** | sum outstanding; aging buckets summed |
| **Cash Movement** | sum net |
| **Finalized Periods** | count across businesses; quick-action chips deep-link per business |

### Per-business breakdown drawer

Every card's footer carries a **"By business"** link → right-side drawer with one row per business showing that business's metric value. Clicking a row deep-links to the single-business dashboard (business switcher flips to that business).

### Permission filter inheritance

Same silent-filter contract as B16·P02: businesses the user cannot read **NEVER** appear in aggregates. The `DASHBOARD_DRILL_DOWN_FILTERED_INACCESSIBLE_BUSINESSES` audit captures any attempt to query an inaccessible business.

### "Currently viewing N businesses" badge

In the period switcher area; click reveals a checkbox list of included businesses for temporary session-scoped exclusion (sub-doc owns persistence question).

### Period switcher

One global period applies across all included businesses (Stage 1 default — simpler mental model). Per-business period offset (e.g., Business A on December, Business B on January) is deferred to a sub-doc; rare in practice for organisations using the same accountant.

### Drill-down behaviour from multi-business view

- Clicking into a card's drill-down opens the cross-business list with rows badged by business name (per B16·P02).
- The list supports filter-by-business and filter-by-period independently.
- Clicking an individual row deep-links into that business's single-business detail view (business switcher updates).

---

## Refresh-state UI

Three surfaces communicate freshness without alarming the user:

### 1. Banner

Subtle banner at the top of the dashboard (below top nav) when `dashboard_refresh_state.currently_refreshing = true`:

> "Updating numbers… last refreshed N minutes ago."

- **Styling**: `severity-low` neutral — informational, not alarming.
- **Dismissible per session**.
- Reappears on next refresh.

### 2. Per-card stale indicator

When the materialized view a card consumes is older than **5 minutes** (Stage 1 default; sub-doc tunes), the card shows a small clock icon next to the title with hover-tooltip "Last updated N minutes ago". The card still renders the last-known value rather than a skeleton (avoids flicker — per B16·P06's mid-refresh rule).

### 3. Manual "Refresh now" action

- **Keyboard shortcut**: Cmd+Shift+R.
- **Button** in the period switcher area, visible at all times.
- Triggers Block 04 P09's analytics rebuild via `dashboard_handle_archive_promotion_event` (B16·P01) with a **synthetic event_id** distinct from real `ARCHIVE_PROMOTION_COMPLETED` events. Sub-doc owns the synthetic event_id signature so the dedup table doesn't conflict with real lock-sequence events.
- Audit-event: `DASHBOARD_REFRESH_TRIGGERED_MANUALLY` (declared in B16·P01, emitted here for the manual button).

### Drill-down bypasses materialized views

Per B16·P02's contract: clicking into any card hits Operational DB / Archive directly, bypassing materialized views. The detail view is current even when aggregates lag. This is the architectural commitment: aggregates lag tolerably; details never do.

### Refresh state for the multi-business view

The banner reflects the freshest `last_refreshed_at` across the user's included businesses. "Updating" shows when ANY included business is refreshing (Stage 1 default).

---

## Per-user customization surface

### Card visibility toggle

- **Per-card `⋯` menu "Hide card"** action flips `dashboard_user_preferences.card_visibility[card_id] = false` (B16·P01) for the (user, business) pair.
- **"Show hidden cards" link** at the bottom of the dashboard lists hidden cards; click to restore.
- **Settings page integration** (Block 02 P11): a "Dashboard preferences" section under the user's account settings exposes the same hide/show controls + a **"Reset to default"** button.

### Scope

- **Per-user-per-business** (UNIQUE on `(business_id, user_id)` per B16·P01).
- Hiding a card on Business A does **NOT** hide it on Business B.

### Rearrange-and-save

**Deferred to Stage 2+** per the architecture. The `default_position` column on `dashboard_card_definitions` is fixed in Stage 1. A future "save preset" feature lands when product validates demand.

---

## Empty-organization handling

User has access to zero businesses → the dashboard renders an Empty State:

| Role | Empty-state copy + action |
|---|---|
| Owner / Admin | "No businesses yet" + **"Set up your first business"** primary action |
| Bookkeeper / Accountant / Reviewer / Read-only | "Ask your Owner / Admin to grant access" — no primary action |

The action is gated by `BUSINESS_ACCESS` + organisation-Owner permissions.

---

## Mobile read-only adaptation (per B14·P09)

- Multi-business overview renders the cards **stacked single-column** on mobile.
- The "By business" drawer becomes a **full-screen route** on mobile.
- **Manual "Refresh now"** works on mobile (read action, not write).
- **Hide-card** is a write action — soft-prompted per the desktop-only constraint.
- Per-business breakdown drill-down is **read-only** on mobile; deep-link to the per-business view works fully read-only.

---

## Audit events (DASHBOARD domain — 4 new actions)

| Action | When emitted |
|---|---|
| `DASHBOARD_MULTI_BUSINESS_VIEW_OPENED` | First-open per session aggregation (sub-doc owns; per-render would be too noisy) |
| `DASHBOARD_REFRESH_TRIGGERED_MANUALLY` | Declared in B16·P01; emitted here for the Cmd+Shift+R / button trigger |
| `DASHBOARD_REFRESH_BANNER_DISMISSED` | Per user dismissal of the "Updating numbers…" banner |
| `DASHBOARD_PER_USER_VISIBILITY_CHANGED` | Per card hide / show; finer-grained than B16·P01's `DASHBOARD_PREFERENCES_UPDATED` |

---

## Three tricky rules (engineering must honor)

- **Severity rollup is MAX, not average** — a single BLOCKING in any business escalates the consolidated card to BLOCKING. Averaging severity hides the worst case and is dangerous.
- **Per-business hide is independent per business** — `(business_id, user_id)` uniqueness means the same user hiding a card on Business A leaves Business B unaffected. Easy to misimplement as a per-user-global preference.
- **Manual refresh uses a synthetic event_id** distinct from real `ARCHIVE_PROMOTION_COMPLETED` events — sub-doc owns the synthetic signature so the dedup table doesn't conflict with real lock-sequence events.

---

## Definition of Done

- A user with access to 3 businesses sees the "Multi-business overview" entry in the business switcher.
- Multi-business view renders all 11 cards with aggregated metrics; per-card "By business" drawer opens correctly.
- Permission filter excludes rows from inaccessible businesses; audit event records the filter.
- Period switcher applies one global period across all included businesses.
- Refresh banner appears during analytics refresh; dismissible; reappears on next refresh.
- Per-card stale indicator shows when MV is > 5 minutes old.
- Manual "Refresh now" works and audit-logs.
- Drill-down from the multi-business view bypasses materialized views and hits live data.
- Per-user hide / show works per business; resets correctly via settings.
- Mobile breakpoint stacks cards single-column; write actions soft-prompt.
- Empty-organization state renders correctly per role.
- All audit events fire with the right payloads.

---

## Sub-doc hooks (Stage 4)

- Multi-business aggregation SQL — exact aggregation queries per card
- Per-business period offset (deferred Stage 2+) — when businesses run on different periods
- Stale-indicator threshold tuning — 5-minute default per card
- Manual-refresh synthetic event_id signature — exact payload shape so dedup doesn't conflict with real ARCHIVE_PROMOTION_COMPLETED events
- Reset-to-default UX — confirmation pattern; partial vs full reset
- Multi-business audit-event aggregation — first-open-per-session vs every-render trade-off
- Per-business-checkbox temporary-exclusion — session storage; persistence question
