# Review Queue Mobile UI Spec

**Category:** UI · **Owning block:** 14 — Review Queue · **Block reference:** Block 14 § Phase 09 (Mobile Read-Only Contract) · **Stage:** 4 sub-doc (Layer 2 UI spec)

**Purpose:** Defines the mobile layout, interaction constraints, and soft-prompt UX for the review queue on `client_form_factor = MOBILE`. All write operations in the review queue are blocked server-side; this spec governs what the client renders before and after that rejection boundary. Front-end implementation binds to this document. Designers treating the mobile queue as a write surface must reference this spec first.

---

## Mobile write constraint

Every write action in the review queue — resolve, snooze, assign, bulk action, add note, regenerate card — is blocked on mobile clients. The server enforces this via shared middleware and returns:

```
HTTP 403 Forbidden
{
  "error_code": "MOBILE_WRITE_REJECTED",
  "endpoint": "review_queue.apply_resolution_action",
  "remediation": "This action is desktop-only. Open Cyprus Bookkeeping on a laptop or desktop browser to complete it."
}
```

The complete endpoint inventory is in `mobile_write_rejection_endpoints.md` under Block 14 — Review Queue. The client must not rely on server-side rejection as the primary gate; the soft-prompt (Section 3) is the correct client-layer response to a user tapping a blocked affordance. However, if the client-side gate is bypassed and the server returns `403 MOBILE_WRITE_REJECTED`, the client renders the soft-prompt bottom sheet as a fallback and logs the anomaly.

---

## Layout

### Single-column card list

The queue renders as a single-column vertical list. There is no multi-column or grid layout on mobile. Each card occupies the full viewport width with 12 px horizontal margin.

Cards use the **compact variant** defined in `review_queue_card_layout_ui_spec.md`. In the compact variant:

- The severity badge is visible in the card header without expanding.
- The issue type label is visible in the card header without expanding.
- The body region is collapsed by default; the affected record summary (transaction amount and counterparty, or invoice number and client name, depending on `issue_type` category) is shown as a single truncated line beneath the header.
- The footer region (assigned avatar, relative timestamp) is visible without expanding.
- The snooze button in the footer is rendered with `cursor: not-allowed` styling and triggers the soft-prompt on tap instead of the snooze picker.

Severity badge and issue type are always visible without expanding. This is the primary mobile affordance — users can triage by severity and type before taking any action on desktop.

### Bottom navigation

Four fixed tabs at the bottom of the viewport:

| Tab | Icon | Default |
|---|---|---|
| Queue | List icon | Yes — default landing tab |
| Filters | Funnel icon | No |
| Notifications | Bell icon | No |
| Profile | Person icon | No |

No action tabs are present in the bottom navigation. Tabs that would expose write affordances are excluded.

The `Queue` tab badge shows the count of open `BLOCKING` + `HIGH` issues. The badge is red for BLOCKING > 0 and amber when only HIGH issues are present.

---

## Read-only expand view

Tapping any card opens a **full-screen detail view** — not a slide-over, not a modal. The full-screen view pushes a new navigation entry and is dismissed with the back chevron or Android system back.

In the full-screen detail view:

- All issue fields defined in `review_queue_card_layout_ui_spec.md` are visible: header, body, affected record summary, notes, audit trail excerpt, and any linked documents.
- All action buttons (resolve, snooze, assign, bulk action controls) are replaced with the **soft-prompt banner** described in Section 3.
- The affected record can be expanded to show its full detail (transaction breakdown, ledger entry preview, etc.) — this is a read-only GET operation and is allowed on mobile.
- Document previews (linked PDFs) are viewable inline.

The full-screen detail view is not paginated; it renders the full issue record in a scrollable container.

---

## Soft-prompt UX

When a user taps any affordance that maps to a blocked write endpoint, the client renders a bottom sheet instead of submitting the request. The bottom sheet does not trigger the server call.

### Bottom sheet content

```
This action requires a desktop browser.
Your progress is saved.

[Dismiss]
```

The bottom sheet:

- Slides up from the viewport bottom edge.
- Is full-width.
- Contains no secondary call-to-action and no deep-link to a desktop URL (the user is already authenticated and does not need a magic link).
- Is dismissed by tapping "Dismiss" or by swiping the sheet down.
- Does not auto-dismiss; the user must explicitly close it.

**No error toast is shown.** The soft-prompt bottom sheet replaces the error toast entirely for mobile write rejections.

Covered affordances (all produce the same bottom sheet with identical copy):
- Resolve button
- Snooze button
- Assign button
- Any bulk action control (select all, apply bulk action)
- Add note button
- Regenerate card button

---

## Swipe gestures

**Swipe-right on a card: mark as viewed.** Swiping right on a card in the list marks the issue as `viewed` for the current user. This is a read-level action (it sets a `user_issue_views` row) and is allowed on mobile.

The swipe-right reveal shows a blue "Viewed" label. On snap completion, the card updates its visual state to reflect the viewed mark (a visual dimming or a small eye icon in the header — exact token in `review_queue_card_layout_ui_spec.md`).

**Swipe-left: no action.** Swipe-left is not implemented. Do not bind any gesture to swipe-left; this reservation avoids accidental resolve triggers. The gesture should produce a subtle elastic resistance and snap back.

---

## Filter panel

The filter panel is accessible on mobile as a bottom sheet triggered by the `Filters` bottom navigation tab or by the filter icon in the queue list header.

- The sheet is full-width and slides up.
- All filter options defined in `review_queue_filter_schema.md` are available: severity, issue type group, assigned user, status, date range, and workflow run scope.
- Applying a filter is allowed on mobile. Applying a filter issues a `GET` request; it is not a write operation.
- Active filter state is persisted per session (same as desktop), not per device.
- The filter count badge on the `Filters` tab shows the number of active non-default filter values.

Filter application triggers a list reload. The reload uses a loading skeleton (not a full-screen spinner) so the existing list remains visible during the fetch.

---

## Pagination and loading

The card list paginates with cursor-based pagination. On mobile:

- The initial page loads 20 cards.
- Scroll-to-end triggers the next page load automatically (infinite scroll).
- Each page load appends cards below the existing list without repositioning the scroll position.
- A loading indicator (a skeleton card) is appended at the list end during fetch.

---

## URL routing

The mobile queue is a distinct route from the desktop queue. The route prefix is shared; the mobile layout is triggered by `client_form_factor` detection at the layout boundary, not by a separate URL.

Sharing a direct link to an issue from desktop produces a URL that resolves to the full-screen detail view on mobile. The URL format is `/queue/<issue_id>`. The router detects `client_form_factor` and renders the full-screen view instead of the slide-over.

---

## Cross-references

- `review_queue_card_layout_ui_spec.md` — card anatomy, compact variant definition, severity badge styles
- `mobile_write_rejection_endpoints.md` — canonical inventory of all mobile-rejected endpoints across all blocks
- `review_queue_filter_schema.md` — filter option definitions and filter state schema
