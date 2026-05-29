# Dashboard Shell

Persistent chrome that wraps every page in the product: top nav, sidebar, business switcher, period switcher, command palette, notifications drawer, theme toggle, user menu. The information architecture every dashboard surface hangs from.

**Phase**: B16·P05 (BOOK-152) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/05_dashboard_shell.md`

The shell is the most-seen surface in the product. Stripe / Linear / Mercury / Pleo polish — clean, dense, fast — is non-negotiable.

---

## Layout grid (responsive breakpoints)

### Desktop (≥ 1280 px) — the canonical experience

- **Top nav**: 56 px tall, **fixed**, full-width, `surface-1` background, bottom border `border-subtle`.
- **Sidebar**: 240 px expanded / 56 px collapsed, fixed left, `surface-1` background.
- **Main content**: flex-1, `surface-0` background, max-width 1440 px (Linear / Stripe pattern — content does NOT stretch infinitely on ultrawide), centered with adaptive horizontal gutters per viewport.
- **Right context drawer** (optional, per page): 360 px wide, slides in from the right for review-issue cards, audit-event detail, etc.

### Tablet (768 – 1280 px)

- Sidebar collapses to **icon-only by default**.
- Main content uses smaller gutters.
- Cards stack 2-up where desktop was 4-up.

### Mobile (≤ 768 px)

- Sidebar replaced by **bottom navigation bar** with **5-item max**: Dashboard · Reviews · Periods · Reports · More (drawer with everything else).
- Top nav collapses to: brand + business switcher + Cmd+K + user menu.
- **Mobile is read-only** per B14·P09 — every write surface shows the desktop-only soft prompt.

---

## Top nav contents (left → right)

1. **Brand mark** — left-most; click → multi-business overview if user has ≥ 2 businesses, else current-business dashboard.
2. **Business switcher** — dropdown with current business name + initial-letter avatar + chevron. Lists every business the user has access to + a "Multi-business overview" entry. **Searchable when user has > 7 businesses** (sub-doc tunes). Selection persists across sessions.
3. **Period switcher** — current accounting period chip with prev/next arrows. Click opens a date-range picker. Affects every card simultaneously. Granularity: month (default), quarter, year. See **Period switcher mechanics** below.
4. **Search trigger (Cmd+K)** — opens the Command Palette. Keyboard-shortcut hint visible on the button + tooltip.
5. **Notifications bell** — badge count of unread notifications. Click opens the right-side notifications drawer.
6. **Theme toggle** — light / dark / system (3-state segmented control). Persists per user via a future `users.theme_preference` enum column (`LIGHT`, `DARK`, `SYSTEM`; default `SYSTEM`) — **Block 02 schema extension deferred to a future sub-doc migration** (Stage 1 ships the contract, not the column).
7. **User menu** — avatar + chevron. Dropdown: name / email · Switch organization · Settings (desktop-only) · Help · Sign out.

---

## Sidebar contents (3 sections)

### Section 1 — Dashboard (top)

- Dashboard (overview view; Phase 06 / 07)

### Section 2 — Domain pages (the click-through targets for the 11 cards)

- Transactions
- Invoices
- Documents
- Reviews queue
- Periods
- Reports
- Subscriptions
- Team
- Clients

### Section 3 — Account (bottom)

- Settings (**desktop-only**; mobile users see a soft-prompt per B14·P09)
- Help

### Active-state indicator

- **`color-primary` left-border accent (4 px) on the active item**, plus
- `text-primary` weight 500 on the label, plus
- Active-state **filled icon variant** per `filled-vs-outline-discipline`.

### Permission gating (hide-don't-show)

Sidebar items **hide entirely** when the user lacks the permission_surface — never greyed-out. Greyed entries leak the existence of features the user shouldn't know about. The empty-nav explanation surfaces only when explicitly designed (e.g., onboarding flows); otherwise the entry simply does not render.

### Collapse mechanics

- Expanded (240 px): full label + icon.
- Collapsed (56 px): icon only with tooltip-on-hover showing full label + keyboard shortcut.
- Smooth transition (200 ms ease-out per `motion-duration-normal`).
- State persists in `dashboard_user_preferences.sidebar_collapsed` (B16·P01).

---

## Command Palette categories (deepening B16·P04's primitive)

Categories shown in the palette in this order:

1. **Navigate** — sidebar pages
2. **Switch business** — every business in the user's access list
3. **Switch period** — last 12 month boundaries + custom date-range entry
4. **Open transaction by id** — partial-match search across recent transactions
5. **Open invoice by number** — partial-match across the invoice sequence
6. **Open issue by id** — partial-match across `review_issues`
7. **Recent** — last 5 visited pages / records
8. **Actions** — e.g., "Start a new month-close run", "Refresh dashboard now"
9. **Settings** — direct deep-links into settings sub-pages

**Search scoring**: fuzzy fzf-style scoring (library TBD in sub-doc). Recency boost on the user's last 30 days of palette history.

**Search scope** respects the active business selection by default; toggle to "Search all businesses I have access to" available.

**Keyboard-only operable**; Escape dismisses.

---

## Period switcher mechanics

- **Granularity**: month (default), quarter, year. Toggle in the picker.
- Disabled / dimmed periods that lie outside the user's permission window or before business creation.
- Forward / back arrows move one granularity unit at a time.
- **Status badges per period** (shown inline in the picker):
  - `status-success` — finalized
  - `status-neutral` — in-flight
  - `severity-medium` — held (HUMAN_REVIEW_HOLD)
  - `severity-blocking` — tamper-alert (per B15·P07)
- **Updates every dashboard card simultaneously without a page reload.** The period is shell-state, not per-card state. App-layer router treats it as a top-level route param.

---

## Notifications drawer

- Right-side drawer (P04 primitive).
- **Notification kinds**: review-issue assignments (B14·P06), workflow run completions, finalization successes, archive verifications, system alerts.
- **Per-notification**: icon + title + relative time + click-through.
- **Mark-as-read on click**; bulk "Mark all as read" header action.
- **Empty state** when no notifications.
- Detailed kind-by-kind catalog deferred to sub-doc.

---

## Skip link

`Skip to main content` — anchored to the top of the document, visible on focus only. Tab from page load → skip link → main content.

---

## Persistent navigation guarantee

The top nav and sidebar (or bottom nav on mobile) are present on **every page** in the app — settings, drill-downs, modals, etc. They never hide.

**Exception**: full-screen modal flows (e.g., the finalization-approval flow with step-up auth) intentionally hide the chrome to focus the user; the user can escape back to the chrome via the modal's close.

---

## Z-index scale (canonical reference)

| Layer | z-index | Use |
|---|---|---|
| Page content | 0 | Everything default |
| Sticky | 10 | Table headers / sidebar on scroll |
| Top nav | 20 | Fixed nav bar |
| Popovers | 40 | Dropdowns, popovers, command palette |
| Drawers | 100 | Right context drawer, notifications drawer |
| Modals | 1000 | Modal + scrim |
| Toasts | 1500 | Toast stack |
| Emergency alerts | 2000 | Tamper detection, audit failure banners |

Components reference this scale via tokens; never hard-coded z-index values.

---

## Document title pattern

Format: `<Page name> · <Business name> · <Product name>`

- Supports keyword-search inside browser tabs.
- Updates on every navigation.
- **Focus moves to main content on route change** per the `focus-on-route-change` UX rule.

i18n implications + truncation rules: sub-doc.

---

## Brand identity

- Logo / wordmark — sub-doc owns the asset.
- **Stage 1 placeholder**: Lucide icon + product name in 600-weight Inter Display.
- Per the UX rule `correct-brand-logos`: official assets only; never recolored unofficially.

---

## Audit events (DASHBOARD domain — 5 new actions)

- `DASHBOARD_BUSINESS_SWITCHED`
- `DASHBOARD_PERIOD_SWITCHED`
- `DASHBOARD_COMMAND_PALETTE_USED` (sub-doc tracks aggregation — per-event might be too noisy)
- `DASHBOARD_THEME_TOGGLED`
- `DASHBOARD_SIDEBAR_COLLAPSED` / `DASHBOARD_SIDEBAR_EXPANDED`

---

## Three tricky rules (engineering must honor)

- **Permission-gated hide-don't-show**: sidebar items the user can't access *disappear*, not greyed-out. Greyed entries leak feature existence.
- **Mobile is read-only** (B14·P09 inheritance): every write surface on mobile shows a desktop-only soft prompt. This phase's mobile shell must NOT expose write CTAs.
- **Period switcher updates every card simultaneously without a page reload** — the period is top-level shell-state, not per-card state. App-layer router treats it as a top-level route param.

---

## Definition of Done

- The shell renders consistently across every page; brand / business switcher / period switcher / search / notifications / theme / user menu all functional.
- Cmd+K opens the Command Palette; fuzzy search returns relevant results.
- Sidebar collapses to icon-only mode and persists; tooltips show on hover in collapsed mode.
- Theme toggle switches between light / dark / system; choice persists per user (once `users.theme_preference` lands in a future B02 sub-doc migration).
- Period switcher updates every dashboard card simultaneously without a page reload.
- Skip-link works on tab from page load.
- Mobile breakpoint shows bottom nav and hides sidebar; write actions soft-prompt per B14·P09.
- Full keyboard navigation: Tab through top nav → sidebar → main content; arrow keys in sidebar; Cmd+K opens palette.
- Light + dark mode independently look polished (verified visually).
- Every audit event fires correctly.

---

## Sub-doc hooks (Stage 4)

- Brand asset — logo, wordmark, dark-mode variants; usage rules
- Business-switcher search threshold (default >7)
- `users.theme_preference` column addition (Block 02 sub-doc migration)
- Sidebar persistence schema (`sidebar_collapsed` already in B16·P01)
- Notification kinds catalog — exhaustive list with per-kind icon, copy, click-through
- Mobile bottom-nav configuration — per-role / per-business nav item visibility
- Command Palette ranking — fzf scoring weights; recency boost; per-user history
- Document-title format — i18n implications; truncation rules
