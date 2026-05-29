# Block 16 — Phase 05: Dashboard Shell — Navigation, Layout & Information Architecture

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Default Dashboard Views; Permission-Aware Rendering)
- Block doc: `Docs/blocks/14_review_queue.md` (Phase 09 — mobile read-only consumer)
- Phase 03 (Design System MASTER — tokens, motion, dark mode)
- Phase 04 (Component Library — Top Nav, Sidebar, Command Palette primitives)
- UI/UX skill: §5 (Layout & Responsive), §9 (Navigation Patterns)

## Phase Goal

Build the persistent dashboard chrome — the top nav, sidebar, business switcher, period switcher, search / command palette, notifications bell, user menu — and the responsive layout grid (desktop, tablet, mobile read-only). Information architecture is the spine the dashboard surfaces (Phases 06–08) hang from. After this phase, every page in the app inherits a consistent, navigable, branded shell.

The shell is the most-seen surface in the product. Stripe / Linear / Mercury / Pleo polish — clean, dense, fast — is non-negotiable here.

## Dependencies

- Phase 01 (`dashboard_user_preferences` for sidebar collapse state)
- Phase 03 (Design System MASTER tokens, motion, dark mode)
- Phase 04 (Top Nav, Sidebar, Command Palette, Tabs primitives)
- Block 02 Phase 04 (permission matrix — sidebar items gate per role)
- Block 02 Phase 11 (settings link — desktop-only per the architecture)
- Block 14 Phase 09 (mobile read-only — shell adapts)

## Deliverables

- **Layout grid (desktop ≥ 1280 px):**
  - **Top nav:** 56 px tall, fixed, full-width, `surface-1` background with bottom border `border-subtle`.
  - **Sidebar:** 240 px wide expanded / 56 px collapsed, fixed left, `surface-1` background, bottom anchored to viewport.
  - **Main content:** flex-1 to the right of the sidebar, `surface-0` background, max-width `1440 px` for content (Linear / Stripe pattern — content doesn't stretch infinitely on ultrawide displays), centered with adaptive horizontal gutters per viewport (per `adaptive-gutters-by-breakpoint`).
  - **Right context drawer (optional, per page):** 360 px wide, slides in from the right for review-issue cards, audit-event detail, etc. Closes on escape / click-outside.
- **Top nav contents (left → right):**
  - **Brand mark** (left-most; click → multi-business overview if user has access to ≥ 2 businesses, else current-business dashboard).
  - **Business switcher** — dropdown with current business name + initial-letter avatar + chevron. Lists every business the user has access to + a "Multi-business overview" entry. Searchable when user has > 7 businesses (sub-doc tunes). Selected business persists across sessions (sub-doc tracks the storage).
  - **Period switcher** — current accounting period chip with prev/next arrows. Click opens a date-range picker keyed to the business's `period_start` / `period_end` granularity (monthly default). Affects every card on the dashboard simultaneously.
  - **Search trigger** — Cmd+K opens the Command Palette (Phase 04 primitive). On the trigger button: keyboard-shortcut hint visible per `cursor-pointer` + tooltip.
  - **Notifications bell** — badge count of unread notifications (Block 14 Phase 06 owns the schema). Click opens the notifications drawer (right-side) with chronological list grouped by today / yesterday / earlier.
  - **Theme toggle** — light / dark / system (3-state segmented control). Persists per user via a new `users.theme_preference` enum column (`LIGHT`, `DARK`, `SYSTEM`; default `SYSTEM`) — Block 02 Phase 01 schema extension flagged for sub-doc-stage migration.
  - **User menu** — avatar + chevron. Dropdown: name / email, Switch organization, Settings (desktop-only — Block 14 Phase 09 / Block 02 Phase 11), Help, Sign out.
- **Sidebar contents:**
  - **Section 1 — Dashboard** (top): single entry "Dashboard" linking to the overview view (Phase 06 / 07).
  - **Section 2 — Domain pages** (the 11 default cards' click-throughs as their own pages, per the dashboard-as-portal pattern; sub-doc tunes which cards get sidebar entries):
    - Transactions, Invoices, Documents, Reviews queue, Periods, Reports, Subscriptions, Team, Clients.
  - **Section 3 — Account** (bottom):
    - Settings (desktop-only; mobile users see a soft-prompt per Block 14 Phase 09).
    - Help.
  - **Active-state indicator** — `primary` colored left-border accent (4 px) on the active item, plus `text-primary` weight 500 on label, plus active-state filled icon variant per `filled-vs-outline-discipline`.
  - **Permission gating** — sidebar items hide entirely when the user lacks the surface (per `empty-nav-state` — explanation surfaces only when explicit; otherwise the entry simply doesn't render).
  - **Collapse toggle** — bottom of the sidebar; persists in `dashboard_user_preferences.sidebar_collapsed` (sub-doc tracks the column addition to Phase 01's table).
- **Sidebar collapse mechanics:**
  - Expanded (240 px) — full label + icon.
  - Collapsed (56 px) — icon only with tooltip on hover. Tooltip shows full label + keyboard shortcut.
  - Smooth transition (200 ms ease-out per Phase 03's motion tokens).
- **Command Palette (deepening Phase 04's primitive):**
  - **Categories:** Navigate (sidebar pages), Switch business, Switch period, Open transaction by id, Open invoice by number, Open issue by id, Recent (last 5 visited), Actions (e.g., "Start a new month-close run", "Refresh dashboard now"), Settings.
  - Fuzzy search powered by `fzf`-style scoring (sub-doc tracks the library).
  - Keyboard-only operable; escape dismisses.
  - **Search scope** respects active business selection by default; toggle to "Search all businesses I have access to" available.
- **Period switcher mechanics:**
  - Granularity: month (default), quarter, year. Toggle in the picker.
  - Disabled / dimmed periods that lie outside the user's permission window or before business creation.
  - Forward / back arrows move one granularity unit at a time.
  - Period picker shows finalization status badges (`status-success` for finalized; `status-neutral` for in-flight; `severity-medium` for held; `severity-blocking` for tamper-alert per Block 15 Phase 07).
- **Notifications drawer:**
  - Right-side drawer (Phase 04 primitive).
  - Notification kinds: review-issue assignments (Block 14 Phase 06), workflow run completions, finalization successes, archive verifications, system alerts.
  - Per-notification: icon + title + relative time + click-through.
  - Mark-as-read on click; bulk "Mark all as read" header action.
  - Empty state when no notifications.
- **Skip link:**
  - "Skip to main content" link anchored to the top of the document, visible on focus only (per UX rule `skip-links`). Tab from page load → skip link → main content.
- **Responsive breakpoints:**
  - **Desktop (≥ 1280 px):** full sidebar + main + optional right drawer. The canonical experience.
  - **Tablet (768–1280 px):** sidebar collapses to icon-only by default; main content uses smaller gutters; cards stack 2-up where they were 4-up on desktop.
  - **Mobile (≤ 768 px):** sidebar replaced by a bottom navigation bar (5-item max per `bottom-nav-limit`): Dashboard, Reviews, Periods, Reports, More (drawer with everything else). Top nav collapses to brand + business switcher + Cmd+K + user menu. **Mobile is read-only** per Block 14 Phase 09 — every write surface shows the desktop-only soft prompt.
- **Persistent navigation guarantee** (per `persistent-nav`):
  - The top nav and sidebar (or bottom nav on mobile) are present on every page in the app — settings, drill-downs, modals, etc. They never hide.
  - Exception: full-screen modal flows (e.g., the finalization-approval flow with step-up auth) hide the chrome to focus the user; the user can escape back to the chrome via the modal's close.
- **Brand identity:**
  - Logo / wordmark — sub-doc owns the asset; Stage 1 placeholder is a Lucide icon + product name in 600-weight Inter Display.
  - Per the UX rule `correct-brand-logos` — official assets only; never recolored unofficially.
- **Z-index scale** (per `z-index-management`):
  - 0: page content.
  - 10: sticky table headers / sidebar on scroll.
  - 20: top nav.
  - 40: dropdowns, popovers, command palette.
  - 100: drawer / right context drawer.
  - 1000: modal + scrim.
  - 1500: toast stack.
  - 2000: emergency alerts (tamper detection, audit failure).
- **Document-title pattern:**
  - `<Page name> · <Business name> · <Product name>` — supports keyword-search inside browser tabs.
  - Updates on every navigation (per `focus-on-route-change` — focus moves to main content).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - `DASHBOARD_BUSINESS_SWITCHED`
  - `DASHBOARD_PERIOD_SWITCHED`
  - `DASHBOARD_COMMAND_PALETTE_USED` (sub-doc tracks aggregation; per-event might be too noisy)
  - `DASHBOARD_THEME_TOGGLED`
  - `DASHBOARD_SIDEBAR_COLLAPSED` / `_EXPANDED` (low-volume, per-user)

## Definition of Done

- The shell renders consistently across every page; brand / business switcher / period switcher / search / notifications / theme / user menu are all functional.
- Cmd+K opens the Command Palette; fuzzy search returns relevant results.
- Sidebar collapses to icon-only mode and persists; tooltips show on hover in collapsed mode.
- Theme toggle switches between light / dark / system; the choice persists per user.
- Period switcher updates every dashboard card simultaneously without a page reload.
- Skip-link works on tab from page load.
- Mobile breakpoint shows bottom nav and hides sidebar; write actions soft-prompt per Block 14 Phase 09.
- Full keyboard navigation: tab through top nav → sidebar → main content; arrow keys in sidebar; cmd+K opens palette.
- Light + dark mode independently look polished (verified visually).
- Every audit event fires correctly.

## Sub-doc Hooks (Stage 4)

- **Brand asset sub-doc** — logo, wordmark, dark-mode variants; usage rules.
- **Business-switcher search threshold sub-doc** — when search activates (>7 default).
- **Sidebar persistence schema sub-doc** — `sidebar_collapsed` column addition to Phase 01.
- **Notification kinds catalog sub-doc** — exhaustive list with per-kind icon, copy, click-through.
- **Z-index canonical reference sub-doc** — central authority preventing per-component drift.
- **Mobile bottom-nav configuration sub-doc** — per-role / per-business nav item visibility.
- **Command Palette ranking sub-doc** — fzf scoring weights; recency boost; per-user history.
- **Document-title format sub-doc** — i18n implications; truncation rules.
