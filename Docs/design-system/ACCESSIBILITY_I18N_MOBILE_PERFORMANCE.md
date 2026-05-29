# Accessibility, i18n, Mobile Read-Only & Performance

Cross-cutting quality gates Block 16 must clear before ship. Independently verified light + dark accessibility, Cyprus locale defaults with i18n abstraction (Greek deferred), mobile read-only consumer of Block 14 P09's contract, Core Web Vitals budgets enforced by CI.

**Phase**: B16·P12 (BOOK-159) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/12_accessibility_i18n_mobile_performance.md` · **Schema**: `users.dashboard_locale` + 2 observability log tables + 3 RPCs from `20260526000037_b16p12_accessibility_i18n_mobile_performance.sql`

---

## 1. Accessibility (WCAG AA)

### Contrast matrix — verified independently for light AND dark

| Element type | Minimum ratio |
|---|---|
| Body text | 4.5:1 against surface |
| Large text (>= 24 px) | 3:1 |
| Interactive elements (buttons, focus rings, severity badges) | 3:1 against surface |

**CI enforcement**: every commit runs `axe-core` against every Storybook story in light + dark + mobile-375 breakpoint. Build fails on any contrast violation. The `record_dashboard_accessibility_audit_run(surface, total_stories, violation_count, modes_tested, ci_run_id, ctx)` RPC records the run + emits `DASHBOARD_ACCESSIBILITY_AUDIT_RAN`.

**Why dark mode contrast is checked independently**: dark mode is not a tinted-light variant — tokens have separate light/dark values. A token that passes 4.5:1 in light can fail in dark. Both modes go through axe-core separately.

### Keyboard navigation

- Tab order matches visual order on every page.
- Every interactive element is reachable via keyboard.
- Focus-visible ring on every focused element.
- Skip-to-main-content link on the dashboard shell (visible on focus only).
- `Cmd+K` opens command palette; `?` opens keyboard-shortcut reference modal.
- Arrow keys for navigable structures (sidebar, table rows, tabs).

### Screen-reader compatibility

- Every chart has a screen-reader summary.
- Every icon-only button has `aria-label`.
- Tables have `aria-sort` on sortable columns.
- Toasts use `aria-live="polite"` for non-error; `role="alert"` for errors.
- Form errors use `aria-invalid` + `aria-describedby`.
- Dynamic content updates announce via `aria-live` regions.
- Heading hierarchy is sequential (h1 -> h6, no level skipping).

### Color-not-only

Every severity badge carries an icon (Lucide) + text label. Every chart uses pattern / shape supplements alongside color. Form errors use icon + text + color.

### `prefers-reduced-motion` honored everywhere

- All durations collapse to 0 ms when the media query matches.
- Spring physics disabled; replace with instant state changes.
- Skeleton shimmer becomes a static gray bar.
- Auto-rotating elements stop.

### Dynamic Type / system text scaling

- Layout uses `rem` / `em` not fixed `px` for text sizes.
- Containers grow with text; no truncation when text scales.
- Tested at 200% browser zoom.

---

## 2. Internationalization (i18n)

### Cyprus locale defaults (Stage 1)

| Setting | Value |
|---|---|
| Currency | EUR (€) |
| Number format | `1.234,56` (period thousands, comma decimal) |
| Date format | EU `DD/MM/YYYY` |
| Time format | 24-hour |
| Week starts | Monday |

Formatting is driven by `Intl.NumberFormat` and `Intl.DateTimeFormat` keyed off the user's locale — no hardcoded format strings in components.

### Translation key abstraction

- Every user-facing string is wrapped in `t('key')` rather than hardcoded.
- Stage 1 ships English only (`en`); keys live in `i18n/en.json`.
- Greek (`el`) is deferred to Stage 2+ — but the abstraction is in place so Greek can be added without refactor.
- Default i18n library: `react-i18next` (sub-doc-owned choice).
- Plural rules handled via the i18n library's plural API (English has 2 forms, Greek has 2).
- `users.dashboard_locale` (enum: `'en'`, `'el'`; default `'en'`) persists each user's choice. Stage 1 rejects `'el'` with `LOCALE_NOT_YET_AVAILABLE`.
- `update_user_dashboard_locale(actor_user_id, target_user_id, new_locale, ctx)` is self-edit only — `actor != target` -> `LOCALE_UPDATE_REJECTED_NOT_SELF`. Emits `DASHBOARD_LOCALE_SWITCHED` on success.
- Bidirectional text support: `dir="auto"` on dynamic text inputs (counterparty names that may include Arabic) — covers Middle East clients of Cyprus businesses.

### Translation-completeness lint

CI checks every key referenced in code exists in `en.json`; missing keys fail the build. Sub-doc tracks the lint rule.

---

## 3. Mobile Read-Only (consumer of Block 14 P09)

### Allowed on mobile (READ intents)

- Dashboards (B16·P06 / P07)
- Drill-down views (B16·P08)
- Reports preview / download (read-side)
- **Refresh-now (B16·P07)** — explicitly READ intent; allowed on mobile

### Soft-prompted on mobile (write intents)

| Surface | RPC patched with `_reject_mobile_write` |
|---|---|
| `dashboard.update_preferences` (B16·P01) | yes |
| `dashboard.hide_card` / `show_card` (B16·P06) | folded into `dashboard.update_preferences` |
| `accountant_pack.update_config` (B16·P11) | yes |
| Card actions menu write items (B16·P06) | app-layer (folded into preferences) |
| Block 14 resolutions / Block 12+13 user-approval / trigger-run | inherits B14·P09's pattern |

The `_reject_mobile_write(p_context, p_surface_label)` helper raises `MOBILE_WRITE_REJECTED: surface=<label> is desktop-only` when `p_context ->> 'client_form_factor' = 'MOBILE'`.

### Soft-prompt copy (Block 14 P09 pattern)

> This action is desktop-only. Open this on a desktop browser to [action].
>
> [Copy link to this page] [Send to my inbox]

### Server-side enforcement is non-negotiable

Relying on client-side breakpoint detection alone is bypassable. Every write RPC on the mobile-soft-prompt list calls `_reject_mobile_write` at the top — that is the authoritative gate. The front-end soft-prompt is UX, not security.

### NOT emitted as an audit event

Per B14·P09's canonical pattern, mobile-write rejection is a UX guard, NOT a security event. The RPC raises a `P0001` exception and the front-end displays the soft-prompt. **`DASHBOARD_MOBILE_WRITE_ATTEMPT_REJECTED` is intentionally not in the audit taxonomy** — metrics-only.

### Bottom navigation + settings inaccessibility

Bottom navigation replaces the sidebar on mobile. Settings are inaccessible on mobile (Block 02 P11's desktop-only constraint inherits).

---

## 4. Performance Budget (Core Web Vitals)

| Metric | Budget | Enforcement |
|---|---|---|
| CLS | < 0.1 | Lighthouse CI; explicit `width`/`height` or `aspect-ratio` on every `<img>`; `font-display: swap` with reserved space; skeletons placeholder future-content size; charts have explicit container heights set BEFORE data loads |
| LCP | < 2.5 s | Above-the-fold images NOT lazy-loaded; below-the-fold use `loading="lazy"`; code splits per route; critical CSS inlined for shell; third-party scripts `async`/`defer` |
| INP | < 200 ms | Heavy work off main thread (Web Workers for chart computation); tap feedback < 100 ms; long tasks broken up; `scheduler.yield()` / `requestIdleCallback` for non-urgent work |

The `record_dashboard_performance_violation(metric, observed_value, threshold, route, ci_run_id, ctx)` RPC records each violation + emits `DASHBOARD_PERFORMANCE_BUDGET_VIOLATION_DETECTED`. `metric` is constrained to `CLS` / `LCP` / `INP`.

### List virtualization at 50+ rows

Tables (B16·P04) and the audit-history slice (B16·P08) virtualize. Default library: `@tanstack/react-virtual`.

### Image optimization

- WebP / AVIF served via responsive `<picture>` with fallback.
- Avatars and brand assets preloaded only when above the fold.

### Network-aware degradation

- Slow connection (<= 2G detected via Network Information API) serves lower-resolution charts and disables some animations.
- Offline state shows "Working offline — some data may be stale" banner.

---

## 5. Responsive breakpoints (verified end-to-end)

| Width | Behavior |
|---|---|
| 375 px (iPhone SE) | All content visible without horizontal scroll |
| 768 px (tablet portrait) | Sidebar collapses to icons; cards stack 2-up |
| 1024 px (tablet landscape / small laptop) | Sidebar expands; cards in dashboard layout |
| 1280 px (laptop) | Canonical desktop experience |
| 1440 px+ (desktop) | Content max-width 1440 px; surrounding gutters expand |

Tested portrait + landscape on each phone breakpoint.

---

## 6. Disability simulation testing

Each major surface tested with: screen reader (VoiceOver / NVDA), keyboard-only, high-contrast mode, color-blind simulator, 200% zoom. Sub-doc tracks the manual checklist + the automated coverage.

---

## 7. Audit events (3 new actions)

- `DASHBOARD_ACCESSIBILITY_AUDIT_RAN` — per CI run; payload carries `surface`, `total_stories`, `violation_count`, `modes_tested`, `ci_run_id`.
- `DASHBOARD_PERFORMANCE_BUDGET_VIOLATION_DETECTED` — per CI failure; payload identifies which CWV (`CLS`/`LCP`/`INP`), `observed_value`, `threshold`, `route`.
- `DASHBOARD_LOCALE_SWITCHED` — per user override; carries `old_locale` + `new_locale`. Low frequency.

`DASHBOARD_MOBILE_WRITE_ATTEMPT_REJECTED` is **NOT** an audit event — UX guard, metrics-only.

`SYSTEM_OBSERVABILITY` was added to `audit.subject_type_enum` for the two CI-emitted actions (deferred-visibility split — see `20260526000036_b16p12_subject_type_system_observability.sql`).

---

## 8. Three tricky rules (engineering must honor)

- **Independent light + dark contrast verification is non-negotiable.** Dark mode is not a tinted-light variant; tokens have separate light/dark values. CI runs axe-core against BOTH modes per Storybook story. A token that passes 4.5:1 in light can fail in dark. **Engineers must NOT promote a contrast change without re-running both modes** — the accessibility floor is non-negotiable.
- **i18n abstraction in Stage 1 even though only English ships.** Every user-facing string MUST be wrapped in `t('key')` from day one. Adding Greek later without refactor only works if no hardcoded strings exist in components. The translation-completeness lint enforces this. Cyprus formatting itself (EUR · DD/MM/YYYY · Monday · 24h) is driven by `Intl.*` keyed off the user's locale — NEVER hardcoded format strings in components.
- **Mobile rejection is UX guard (no audit emit), but server-side enforcement IS required.** Relying on client-side breakpoint detection alone is bypassable. The `_reject_mobile_write` helper at the RPC top is the source of truth. Refresh-now is explicitly NOT in the rejection list because the user-intent is READ. **Do NOT add an audit event for mobile rejection** — it would create noise + miscategorize a UX guard as a security event.

---

## Definition of Done

- Every Storybook story passes axe-core in light + dark + mobile breakpoint; CI fails on regressions.
- Keyboard navigation works end-to-end on every page.
- Screen-reader passes on each major surface (manual + automated `aria-*` linting).
- `prefers-reduced-motion` collapses durations to 0 ms across all components.
- Cyprus locale defaults applied: EUR formatting, EU date format, Monday week start.
- i18n abstraction in place; `en.json` populated; missing-key lint fails on undefined keys; `el.json` empty placeholder created.
- Mobile read-only enforced: dashboards render; soft-prompt fires on every write attempt; settings inaccessible.
- CWV budgets enforced in CI: CLS < 0.1, LCP < 2.5 s, INP < 200 ms.
- Lists with 50+ rows virtualize.
- Tested at 200% zoom + landscape + 375 px width with no horizontal scroll.
- Color-blind simulator passes on every dashboard card.

---

## Sub-doc hooks (Stage 4)

- axe-core CI integration — runner, per-story coverage, regression-blocking config
- i18n library choice — Stage 1 default; locale detection rules; per-user override storage
- Greek (`el`) translation roadmap — Stage 2+ activation steps
- Lighthouse CI configuration — per-PR runs, budget thresholds, regression alerts
- Web Worker usage — per-chart computation off-main-thread
- Network-aware degradation — exact thresholds, what to disable / lower
- Manual disability-simulation runbook — pre-release checklist with screen-reader / keyboard / color-blind / zoom tests
- Bidirectional text edge-case — Arabic counterparty names; mixed-script display
- PDF accessibility tagging — Phase 10's PDFs need WCAG-compliant structure trees
- Performance budget per-route — different routes get different budgets
