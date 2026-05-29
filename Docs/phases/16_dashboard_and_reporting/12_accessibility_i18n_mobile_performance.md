# Block 16 — Phase 12: Accessibility, i18n, Mobile Read-Only & Performance Budget

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (deferred i18n note; Permission-Aware Rendering)
- Block doc: `Docs/blocks/14_review_queue.md` (Phase 09 — mobile read-only contract; soft-prompt for write attempts)
- UI/UX skill: §1 (Accessibility — CRITICAL), §3 (Performance — HIGH), §5 (Layout & Responsive)
- Phase 03 (Design System MASTER — tokens, motion, dark mode)
- Phase 04 (Component Library — every primitive ships a11y baked in)

## Phase Goal

Pin the cross-cutting quality gates Block 16 must clear before ship: WCAG AA accessibility (independently verified light + dark), Cyprus locale defaults with an i18n abstraction ready for Greek (deferred Stage 2+), the mobile read-only consumer of Block 14 Phase 09's contract (soft-prompt for write attempts on small screens), and Core Web Vitals performance budgets enforced by lint + CI. After this phase, the dashboard meets enterprise-SaaS quality standards across every dimension.

This is not a tail-end "polish" phase — these are the constraints that distinguish "quality SaaS" from "shipped MVP".

## Dependencies

- Phase 03 (Design System MASTER — tokens drive accessibility + i18n abstraction)
- Phase 04 (Component Library — components inherit a11y / i18n / responsiveness)
- Phase 05–08 (every dashboard surface gets audited against this phase's checklist)
- Block 02 Phase 11 (settings desktop-only)
- Block 14 Phase 09 (mobile read-only canonical contract)

## Deliverables

- **Accessibility (WCAG AA, with AAA aspirations on key surfaces):**
  - **Contrast verified independently for light AND dark** per UX rule `color-accessible-pairs`:
    - Body text ≥ 4.5:1 against surface.
    - Large text (≥ 24 px) ≥ 3:1.
    - Interactive elements (buttons, focus rings, severity badges) ≥ 3:1 against surface.
    - **Automated CI check** — every commit runs `axe-core` against every Storybook story in light + dark mode; build fails on contrast violations. Sub-doc tracks the runner.
  - **Keyboard navigation everywhere** (per `keyboard-nav`):
    - Tab order matches visual order.
    - Every interactive element reachable via keyboard.
    - Focus-visible ring on every focused element (per `focus-states`).
    - Skip-to-main-content link on the dashboard shell (Phase 05).
    - Cmd+K opens command palette; `?` opens keyboard-shortcut reference modal.
    - Arrow keys for navigable structures (sidebar, table rows, tabs).
  - **Screen-reader compatibility:**
    - Every chart has a screen-reader summary (per `screen-reader-summary` for charts).
    - Every icon-only button has `aria-label` (per `aria-labels`).
    - Tables have `aria-sort` on sortable columns (per `sortable-table`).
    - Toasts use `aria-live="polite"` for non-error; `role="alert"` for errors (per `toast-accessibility`).
    - Form errors use `aria-invalid` + `aria-describedby` (per `aria-live-errors`).
    - Dynamic content updates announce via `aria-live` regions where appropriate.
    - Heading hierarchy is sequential (h1 → h6, no level skipping per `heading-hierarchy`).
  - **Color-not-only:**
    - Every severity badge carries an icon (Lucide) + text label.
    - Every chart uses pattern / shape supplements alongside color (per `pattern-texture`).
    - Form errors use icon + text + color.
  - **`prefers-reduced-motion` respected everywhere** (per `reduced-motion`):
    - All durations collapse to 0 ms when the media query matches.
    - Spring physics disabled; replace with instant state changes.
    - Skeleton shimmer becomes a static gray bar.
    - Auto-rotating elements (carousels, animated charts) stop.
  - **Dynamic Type / system text scaling supported** (per `dynamic-type`):
    - Layout uses rem / em not fixed px for text sizes.
    - Containers grow with text; no truncation when text scales.
    - Tested at 200% browser zoom.
  - **Skip-link, "Skip to main content"** anchored at top of every page; visible on focus only.
  - **Per-page accessibility audit:** Phase 13's fixture suite runs axe-core against each rendered page on light + dark + mobile breakpoints; build fails on violations.

- **Internationalization (i18n) abstraction:**
  - **Cyprus locale defaults baked in** (Stage 1):
    - **Currency:** EUR (€) with Cyprus formatting (1.234,56 — period thousands, comma decimal).
    - **Date format:** EU (DD/MM/YYYY).
    - **Time format:** 24-hour.
    - **Week starts:** Monday.
    - **Decimal separator:** comma; **thousands separator:** period.
  - **Translation key abstraction** — every user-facing string in the dashboard is wrapped in a `t('key')` helper rather than hardcoded:
    - Stage 1 only ships English (`en`); the keys live in `i18n/en.json`.
    - **Greek (`el`) deferred to Stage 2+** — but the abstraction is in place so Greek can be added without refactor (per the architecture's deferred note).
    - Sub-doc owns the i18n library choice (Stage 1 default — `react-i18next` server-side compatible).
  - **Plural rules** handled via the i18n library's plural API (English has 2 forms, Greek has 2; abstraction supports both).
  - **Locale detection:** browser locale on first load; per-user override available in settings (sub-doc tracks the column on `users` — Stage 1 placeholder).
  - **Bidirectional text support:** not required for Greek/English but the abstraction supports `dir="auto"` on dynamic text inputs (e.g., counterparty names that may include Arabic if a Cyprus business has Middle East clients).
  - **Number / date / currency formatting** uses `Intl.NumberFormat` and `Intl.DateTimeFormat` driven by the user's locale; no hardcoded format strings in components.
  - **Translation completeness lint:** CI checks every key referenced in code exists in `en.json`; missing keys fail the build. Sub-doc tracks the lint rule.

- **Mobile read-only consumer** (per Block 14 Phase 09):
  - **Read-only on mobile:** dashboards (Phases 06 / 07), drill-downs (Phase 08), reports preview (the export download button works as a read action).
  - **Soft-prompted on mobile:** every write surface — card hide-toggle (Phase 06), accountant-pack config (Phase 11), card actions menu's write items (Phase 06), all of Block 14's resolutions, all of Block 12 / 13's user-approval and trigger-run actions.
  - **Refresh-now is treated as a READ intent** (per Phase 07; user-intent is "I want fresh data"; the server-side cost is bounded; mobile users gain real value). Refresh-now is allowed on mobile and is NOT in the soft-prompt list.
  - **Soft-prompt copy** matches Block 14 Phase 09's pattern: "This action is desktop-only. Open this on a desktop browser to [action]." With "Copy link to this page" + "Send to my inbox" CTAs.
  - **Server-side enforcement** — write APIs check `client_form_factor = MOBILE` and reject (per Block 14 Phase 09's UX guard). The Block-16-specific write surfaces added to Block 14 Phase 09's mobile-write-rejection sub-doc list:
    - `dashboard.update_preferences` (Phase 01)
    - `dashboard.hide_card` / `dashboard.show_card` (Phase 06)
    - `accountant_pack.update_config` (Phase 11; Owner / Admin only via `BUSINESS_SETTINGS_EDIT`)
    - `exports.requestExport` for write-side exports — note that READ-side exports (e.g., user-initiated CSV download) are accepted on mobile per the read-only constraint; per-export-kind sub-doc owns the read-vs-write classification.
    - `dashboard.user_approval` proxies (none directly; Block 12 / 13's user_approval tools are the canonical ones; mobile-write-rejected list owned by Block 14 Phase 09's sub-doc).
  - **Bottom navigation** (per Phase 05) replaces the sidebar on mobile.
  - **Settings inaccessible on mobile** — Block 02 Phase 11's desktop-only constraint inherits here.

- **Performance budget (Core Web Vitals targets):**
  - **CLS < 0.1** per `image-dimension` + `font-loading` + `content-jumping` rules:
    - Every `<img>` has explicit `width` / `height` or `aspect-ratio`.
    - Fonts loaded with `font-display: swap` and reserved space.
    - Async content reserves space (skeletons placeholder the future content size).
    - Charts have explicit container heights set BEFORE data loads.
  - **LCP < 2.5s** per `image-optimization` + `lazy-loading` + `bundle-splitting` + `critical-css`:
    - Above-the-fold images are not lazy-loaded.
    - Below-the-fold images use `loading="lazy"`.
    - Code splits per route (Next.js dynamic imports / React Suspense).
    - Critical CSS inlined for the dashboard shell.
    - Third-party scripts loaded `async` / `defer` (per `third-party-scripts`).
  - **INP < 200ms** per `main-thread-budget` + `input-latency` + `tap-feedback-speed`:
    - Heavy work moved off the main thread (sub-doc tracks Web Worker usage for chart computation).
    - Tap feedback within 100 ms.
    - Long tasks broken up.
    - `scheduler.yield()` / `requestIdleCallback` for non-urgent work.
  - **List virtualization at 50+ rows** (per `virtualize-lists`):
    - Tables (Phase 04) and the audit-history slice (Phase 08) virtualize.
    - Sub-doc owns the library choice (Stage 1 default — `@tanstack/react-virtual`).
  - **Image optimization** (per `image-optimization`):
    - WebP / AVIF served via responsive `<picture>` with fallback.
    - Avatars and brand assets preloaded only when above the fold.
  - **Network fallback** (per `network-fallback`):
    - Slow connection (<= 2G detected via Network Information API) serves lower-resolution charts and disables some animations.
    - Offline state shows a "Working offline — some data may be stale" banner (per `offline-support`).
  - **Performance budget CI check:**
    - Lighthouse CI runs against the dashboard shell + 3 representative drill-down pages on every PR.
    - Build fails if CWV exceeds budget (CLS > 0.1, LCP > 2.5s, INP > 200ms).
    - Sub-doc tracks the runner.

- **Responsive behaviour invariants** (per Phase 05's breakpoints; verified end-to-end here):
  - **375 px (iPhone SE):** all content visible without horizontal scroll (per `horizontal-scroll`).
  - **768 px (tablet portrait):** sidebar collapses to icons; cards stack 2-up.
  - **1024 px (tablet landscape / small laptop):** sidebar expands; cards in dashboard layout.
  - **1280 px (laptop):** canonical desktop experience.
  - **1440 px+ (desktop):** content max-width caps at 1440 px; surrounding gutters expand.
  - **Tested orientation:** portrait + landscape verified on each phone breakpoint (per `orientation-support`).

- **Disability simulation testing:**
  - Each major surface tested with: screen reader (VoiceOver / NVDA), keyboard-only, high-contrast mode, color-blind simulator, 200% zoom.
  - Sub-doc tracks the manual test checklist + the automated coverage.

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - `DASHBOARD_ACCESSIBILITY_AUDIT_RAN` (per CI run; aggregate with violation count)
  - `DASHBOARD_PERFORMANCE_BUDGET_VIOLATION_DETECTED` (per CI failure; payload identifies which CWV exceeded)
  - `DASHBOARD_LOCALE_SWITCHED` (per user override — low frequency)
  - `DASHBOARD_MOBILE_WRITE_ATTEMPT_REJECTED` — **NOT emitted as an audit event** (per Block 14 Phase 09's pattern — UX guard, not security event; metrics-only).

## Definition of Done

- Every Storybook story passes axe-core in light + dark + mobile breakpoint; CI fails on regressions.
- Keyboard navigation works end-to-end on every page (verified by Phase 13's fixtures).
- Screen-reader passes on each major surface (manual test + automated `aria-*` linting).
- `prefers-reduced-motion` collapses durations to 0 ms across all components.
- Cyprus locale defaults applied: EUR formatting, EU date format, Monday week start.
- i18n abstraction in place; English `en.json` populated; missing-key lint fails on undefined keys; Greek `el.json` empty placeholder created.
- Mobile read-only enforced: dashboards render; soft-prompt fires on every write attempt; settings inaccessible.
- CWV budgets enforced in CI: CLS < 0.1, LCP < 2.5s, INP < 200ms.
- Lists with 50+ rows virtualize.
- Tested at 200% zoom + landscape orientation + 375 px width with no horizontal scroll.
- Color-blind simulator pass on every dashboard card.

## Sub-doc Hooks (Stage 4)

- **axe-core CI integration sub-doc** — runner, per-story coverage, regression-blocking config.
- **i18n library choice sub-doc** — Stage 1 default; locale detection rules; per-user override storage.
- **Greek (`el`) translation roadmap sub-doc** — Stage 2+ activation steps.
- **Lighthouse CI configuration sub-doc** — per-PR runs, budget thresholds, regression alerts.
- **Web Worker usage sub-doc** — per-chart computation off-main-thread.
- **Network-aware degradation sub-doc** — exact thresholds, what to disable / lower.
- **Manual disability-simulation runbook sub-doc** — pre-release checklist with screen-reader / keyboard / color-blind / zoom tests.
- **Bidirectional text edge-case sub-doc** — Arabic counterparty names; mixed-script display.
- **PDF accessibility tagging sub-doc** — Phase 10's PDFs need WCAG-compliant structure trees.
- **Performance budget per-route sub-doc** — different routes (dashboard vs drill-down vs reports) get different budgets.
