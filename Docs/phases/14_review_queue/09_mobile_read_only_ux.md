# Block 14 — Phase 09: Mobile Read-Only UX

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Mobile UX)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 11 — settings desktop-only; mobile read-only applies only to dashboards / drill-down / queue)
- Decisions log: `Docs/decisions_log.md` (mobile UX: desktop-first, mobile read-only)

## Phase Goal

Implement the mobile read-only constraint: dashboards, transaction drill-down, and queue browsing all work on a phone, but issue resolution actions (Phase 04), bulk actions (Phase 05), assignment (Phase 06), notes editing (Phase 06), snooze (Phase 07), and manual re-scan (Phase 08) are desktop-only. After this phase, the "review on the go, resolve at the desk" pattern is enforced consistently.

## Dependencies

- Phase 01 (`review_issues` schema; permission surfaces — these stay valid; mobile adds an additional client-side gate on top)
- Phase 03 (card rendering — mobile inherits the rendered card content; layout adapts)
- Phase 04, 05, 06, 07, 08 (the actions disabled on mobile)
- Block 02 Phase 11 (settings — also desktop-only; this phase aligns the mobile-read-only pattern)

## Deliverables

- **Client-side viewport detection:**
  - The web app detects viewport via standard responsive breakpoints (sub-doc owns the exact CSS breakpoints; Stage 1 default — `< 768px` width = "mobile"; `≥ 768px` = "desktop").
  - The "mobile" classification applies regardless of device — a desktop browser at narrow width is treated as mobile (consistent UX). The user can opt-out by request-desktop-site (browser-level), not by Block 14 toggle.
- **What works on mobile (read-only):**
  - **Dashboards** — Block 16's overview, monthly summary, drill-down. Per Block 02 Phase 11's setting and Stage 1 default. Read-only.
  - **Transaction drill-down** — viewing the full structured transaction record, attached documents, match records, ledger entries.
  - **Review queue browsing** — viewing all six buckets, all card content (title, description, context, severity, recommended action, expand panel). The user can read every detail; they cannot click resolution actions.
  - **Audit trail viewing** — read-only Block 05 audit-log surfaces.
- **What's disabled on mobile (deny + soft prompt):**
  - **Phase 04 resolution actions** — every one-click action is disabled. Tapping a disabled action surfaces a soft prompt: `"This action is desktop-only. Open this issue on a desktop browser to resolve it."` with a `Send to my desktop` link (sub-doc tracks the deferred-action pattern; Stage 1 default — copies the issue's URL to clipboard / sends a self-link via the in-app inbox).
  - **Phase 05 bulk actions** — the multi-select UI is hidden entirely on mobile. The "Bulk apply" button is replaced by a `"Bulk actions are desktop-only"` info note.
  - **Phase 06 notes editing** — notes are visible (read-only); the edit textbox is replaced by a `"Add note from desktop"` info note. Reading existing notes works fine.
  - **Phase 06 assignment** — read-only on mobile (the user can see who the issue is assigned to); Owner/Admin attempting to assign is shown the desktop-only prompt.
  - **Phase 07 snooze** — desktop-only; mobile shows a `"Snooze from desktop"` info note.
  - **Phase 08 manual re-scan** — desktop-only.
  - **Block 12 Phase 07 / Block 13 Phase 09 user approval** — desktop-only (the high-stakes finalization-approval action stays at the desk). Specific tool names: `out_workflow.user_approval`, `out_workflow.user_revoke_approval`, `in_workflow.user_approval`, `in_workflow.user_revoke_approval`.
  - **Block 12 Phase 08 / Block 13 Phase 07 manual triggers** — desktop-only. Specific tool names: `out_workflow.start_run_manually`, `in_workflow.start_run_manually`, `out_workflow.adjustment_intake`, `in_workflow.adjustment_intake`.
  - **Block 02 Phase 11 settings** — desktop-only per the prior phase's decision; this phase aligns.
- **Server-side enforcement (defense in depth):**
  - The mobile-read-only rule is **client-side first** — the UI hides / disables write surfaces. But every write API also checks a `client_form_factor` signal in the request context (sub-doc owns the signal — header or session-based). When the signal is `MOBILE`, the API rejects with `MOBILE_FORM_FACTOR_WRITE_REJECTED`.
  - The signal can be spoofed by a determined client; the rejection is a UX guard, not a security boundary. Per the architecture doc — "the expected pattern is review on the go, resolve at the desk" — this is a design constraint, not a security one. Real security is the permission matrix (Block 02 Phase 04), which is independently enforced.
  - Sub-doc tracks the per-API list of mobile-write-rejected endpoints.
- **Soft-prompt UX:**
  - When a user taps a disabled action, the soft prompt appears as a non-blocking toast or modal:
    - **Body:** `"This action is desktop-only. Open this issue on a desktop browser to resolve it."`
    - **Primary CTA:** `Copy link to issue` (copies the deep-link URL; user pastes on desktop).
    - **Secondary CTA:** `Send to my inbox` (writes a Phase 06-style notification to the user's own in-app inbox containing the issue link; sub-doc tracks the timing).
    - **Tertiary:** `Dismiss`.
- **Responsive layout:**
  - Cards stack vertically on mobile; the expand panel collapses by default to save space.
  - The six-bucket sectioning persists on mobile but each section's count badge is more prominent (the user is browsing, prioritizing).
  - Severity colours and labels remain identical to desktop.
- **Accessibility:**
  - Mobile read-only mode is fully screen-reader compatible; disabled actions announce as `"<Action name>, disabled, desktop-only"`.
  - Sub-doc owns ARIA-label conventions.
- **Audit events:**
  - **No new audit events emitted by the mobile rejection path** — the rejection is informational, not a security or compliance event. Per the audit-volume principle from Phase 03's "no `REVIEW_CARD_VIEWED`" rule, mobile-write-attempts don't pollute the audit log.
  - The server-side rejection emits a debug-level metric (sub-doc owns the metrics shape) for product analytics — not the audit log.

## Definition of Done

- A user opens the review queue on a phone → all six buckets render → all cards show full content → tapping any resolution action surfaces the soft prompt → no API call fires.
- A user taps `Copy link to issue` → the deep-link URL is copied to clipboard.
- A user opens the same review queue on a desktop browser → all actions are enabled → resolutions work normally.
- A determined mobile client that spoofs `client_form_factor = DESKTOP` and calls a write API with `Bookkeeper` permissions can write — the security boundary is the permission matrix, not the form-factor signal. The mobile constraint is a UX guard.
- A genuine mobile client calling a write API with the correct `client_form_factor = MOBILE` signal is rejected with `MOBILE_FORM_FACTOR_WRITE_REJECTED`.
- Notes are visible on mobile (read-only); existing notes render in full.
- Assignment is visible on mobile (read-only); the assigner / assignee names show.
- Audit-trail surfaces work read-only on mobile.
- Settings, manual triggers, user approval, snooze, manual re-scan, bulk actions are all soft-prompted on mobile.

## Sub-doc Hooks (Stage 4)

- **Responsive breakpoints sub-doc** — exact CSS values; per-component layout transforms.
- **Soft-prompt UX sub-doc** — toast vs modal; per-disabled-action wording.
- **`Send to my inbox` self-link mechanism sub-doc** — schema, dispatch, expiry.
- **Per-API mobile-write-rejection list sub-doc** — exhaustive endpoint inventory.
- **Accessibility sub-doc** — ARIA labels, screen-reader scripts, keyboard shortcuts (desktop only).
- **Mobile-write-attempt analytics sub-doc** — metric collection for product feedback (e.g., "users tap snooze on mobile a lot — consider enabling").
- **Tablet form-factor sub-doc (deferred)** — Stage 1 collapses tablet to mobile; Stage 2+ may treat tablet as desktop for select actions.
