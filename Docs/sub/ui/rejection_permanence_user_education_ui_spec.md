# rejection_permanence_user_education_ui_spec

**Category:** UI · **Owning block:** 10 — Matching Engine · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

UX mechanisms that communicate the "rejection is permanent" guarantee to prevent accidental rejections in the match-review flow. Companion to:

- `match_review_ui_spec.md` (BOOK-186) — hosts the reject button these layers wrap around.
- `rejection_memory_schema.md` (BOOK-166) — the schema-level "forever-remember" commitment this UX implements.
- `rejection_memory_privileged_override_ui_spec.md` (BOOK-202) — the expensive Owner-only reversal path referenced by these layers.

Six progressive layers of user education, each tuned to a different mistake-mode.

---

## 1. Why this matters

Stage-1 promise per BOOK-166 §"Purpose" line 5: *"Remember forever for the same (transaction, document) pair; never re-suggest a pair the user has rejected."*

Reversing a mistaken rejection requires Owner-only step-up via BOOK-202 — slow, expensive, and emits a HIGH-severity audit event that operators see. The cheaper fix is preventing the mistake in the first place via progressive education.

This doc commits to **six** layers, ordered from least-intrusive (passive labels) to most-intrusive (first-time-user info panel). Combined, they reduce accidental-rejection rate without making the deliberate-rejection path slow for confident users.

---

## 2. Layer 1 — Passive labels

The "Reject" button itself signals permanence by its labelling alone, before any interaction.

| Aspect | Value |
|---|---|
| Button text | **"Reject permanently"** (not just "Reject") |
| Icon | `×` plus a small lock / "forever" glyph |
| Color | `--color-action-permanent-warning` (new token) — red-tinted but NOT pure-danger-red (pure danger is reserved for destructive multi-row operations like bulk-delete) |
| Below-button help text | Muted: "This pair won't be re-suggested." |

The two-word "permanently" carries the load: every user who reaches the button reads it (even if they don't read the help text below). Layer 1's job is to make sure nobody clicks expecting reversibility.

---

## 3. Layer 2 — Hover hint (desktop only)

Hovering the "Reject permanently" button for ≥200 ms surfaces a tooltip:

> "Rejection is permanent. This transaction won't be suggested as matching this document again. Only the business Owner can reverse this from Settings → Matching → Rejection Memory."

Tooltip styling: standard tooltip per `component_library_ui_spec`. 200–300 ms hover delay before display (matches existing tooltip cadence on the platform).

**Mobile note**: tooltips don't fire on mobile (no hover). The full reject flow is desktop-only per `mobile_write_rejection_endpoints.md`, so this layer's absence on mobile is correct by design.

---

## 4. Layer 3 — Confirmation modal (the safety gate)

Mandatory two-step before rejection commits.

```
┌─────────────────────────────────────────────────┐
│  Reject this pair permanently?                  │
│                                                 │
│  This pair will be remembered forever — it      │
│  won't be suggested again on future runs.       │
│                                                 │
│  ┌─────────────────┐  ┌─────────────────┐       │
│  │ TRANSACTION     │  │ DOCUMENT        │       │
│  │ €1,450.00       │  │ INV-2026-0042   │       │
│  │ 10 May 2026     │  │ 8 May 2026      │       │
│  │ Acme Ltd        │  │ Acme Ltd        │       │
│  └─────────────────┘  └─────────────────┘       │
│                                                 │
│  Why are you rejecting?                         │
│  ┌─────────────────────────────────────┐        │
│  │ ▾ Wrong supplier                    │        │
│  ├ Wrong amount                         │        │
│  ├ Different period                     │        │
│  ├ Already matched elsewhere            │        │
│  └ Other                                │        │
│                                                 │
│  ☐ I understand this can't be undone           │
│     (except by the Owner from Settings)        │
│                                                 │
│  [Cancel]                  [Reject permanently]│
└─────────────────────────────────────────────────┘
```

### 4.1 Key UX commitments

| Element | Behaviour |
|---|---|
| Side-by-side transaction × document detail cards | Lets the user confirm they're rejecting the right pair. Mismatched pair = visual signal to Cancel. |
| Picklist for rejection reason | 5 values per BOOK-200 (`wrong supplier` / `wrong amount` / `different period` / `already matched elsewhere` / `other`); "Other" expands a 500-char free-text input per BOOK-166 §"Column notes". |
| Mandatory "I understand" checkbox | "Reject permanently" button is disabled until checked. Forces a deliberate confirming action; defeats accidental click-through. |
| Affordance hierarchy | Cancel is ghost-style with **wider hit target** than Reject — the safer action is the easier action. Reject is red-tinted but visually secondary. |
| Esc key | Closes the modal without rejecting (safe-default exit). |
| Enter key | **Does NOT auto-submit** — prevents keyboard-mash accidents. User must click Reject explicitly. |
| Focus management | First-focus on the picklist (NOT on Reject button). Forces interaction with the reason field before reaching submit. |

### 4.2 Why the checkbox

Industry-standard "are you sure?" modals can be dismissed by reflex-clicking through. A mandatory checkbox interrupts that reflex by requiring a distinct interaction (move cursor to checkbox, click). The text "I understand this can't be undone (except by the Owner from Settings)" simultaneously acknowledges permanence AND identifies the reversal-authority owner (preventing the user from later thinking "I'll just undo it myself").

---

## 5. Layer 4 — Undo grace period (5 seconds)

After the confirmation modal commits, a toast appears with a 5-second undo window:

```
┌────────────────────────────────────────────────────┐
│ ✓ Pair rejected permanently.    [Undo (5s)]    [×] │
└────────────────────────────────────────────────────┘
```

### 5.1 Mechanism

- Toast displays for 5 seconds with a countdown timer on the Undo button.
- Clicking Undo within the 5-second window calls `matching.undo_recent_rejection(rejection_id)` SECURITY DEFINER RPC.
- The RPC validates: rejection was created &lt;5 seconds ago AND by the calling user; then DELETEs the `match_rejection_memory` row AND emits `MATCHING_REJECTION_UNDONE_VIA_GRACE_PERIOD` (LOW).
- After 5 seconds the toast fades automatically; the rejection is now actually permanent (subject only to Owner override per BOOK-202).
- Pressing `U` on the keyboard during the toast also triggers undo (accessibility shortcut).

### 5.2 Why 5 seconds

Long enough for the "wait, that was wrong" reflex; short enough that users can't rely on grace-undo as a deliberate workflow. Specifically:

- Users CAN'T reject-then-undo as a no-op tap-loop on dozens of similar pairs (grace is too short for repeated abuse).
- Users CAN catch the "I clicked the wrong row" mistake within the same conscious moment.

The 5-second window is a Stage-1 decision; Stage-2+ may tune it based on Layer 4's undo-rate metric (per §13).

### 5.3 Why immediate commit + delayed delete (not delayed write)

The rejection writes to `match_rejection_memory` immediately on confirmation. Undo issues a DELETE on the row. We do NOT defer the write to "after grace period expires" because:

- Race condition: another scoring run during the grace window would re-suggest the pair if the row didn't exist.
- Auditability: the timestamp on the rejection row should reflect the user's intent moment, not the grace-period-end moment.
- Failure mode: if the user closes the browser tab during grace, the rejection still commits (intended behaviour — they confirmed it).

The DELETE-on-undo emits a distinct audit event so the audit chain can distinguish "rejection that happened then was undone" from "rejection that never happened."

---

## 6. Layer 5 — Audit-trail surfacing

After rejection (post-grace), the rejected pair appears in the transaction's detail drawer with a clear status:

| Element | Display |
|---|---|
| Badge | "Rejected (permanent)" in muted-red. Hover tooltip: "Rejected by {user_display_name} on {date}. Reason: {rejection_reason}." |
| Helper link | "How to reverse this" → opens a help drawer (§7) explaining the Owner-only override flow per BOOK-202. Educational for non-Owner users; actionable for Owners. |
| Timeline entry | Rejection appears in the transaction-detail event timeline alongside other events (classified, matched, etc.) so the user sees rejection in context, not as a hidden one-shot action. Timeline order: `(value_date DESC, event_at DESC)`. |

The audit-trail surfacing is the "long tail" of user education — even users who didn't see the modal can later learn what rejection means by encountering its consequences.

---

## 7. Layer 6 — First-time-user inline help

The FIRST time a user attempts to reject ANY pair, the confirmation modal includes an expandable info panel above the picklist:

```
┌─────────────────────────────────────────────────┐
│  ▼ First time rejecting?                        │
│                                                 │
│  When you reject a pair, the system remembers   │
│  it forever and won't suggest it again. If you  │
│  make a mistake, only your business Owner can   │
│  undo it via Settings → Matching → Rejection    │
│  Memory.                                        │
│                                                 │
│  Most rejections are correct — if you're        │
│  confident this pair shouldn't match, go ahead. │
│  If you're not sure, click Cancel and ask a     │
│  teammate.                                      │
│                                                 │
└─────────────────────────────────────────────────┘
```

### 7.1 Implementation

- Tracked via `user_settings.has_rejected_match boolean DEFAULT false` (new column to add at B10·P06 implementation; default false for all existing users → all current users see the panel on their next rejection regardless of prior session history).
- Panel is **expanded by default** on the first rejection (forcing the user to read or actively collapse it).
- On successful first rejection: `has_rejected_match := true`.
- On subsequent rejections: panel is hidden by default; replaced by a small "Learn more" link the user can click if they want to re-read.
- Audit emit: `MATCHING_REJECTION_FIRST_TIME_EDUCATED` (LOW) on first-time render — analytics signal that the user has been shown the canonical explanation.

### 7.2 Why not for every rejection

Users who reject frequently (high-volume bookkeepers) would find the persistent panel annoying — it would tutorial-fatigue them into ignoring it. Showing it once + leaving a small "Learn more" affordance preserves the education without becoming friction.

---

## 8. Help center anchor

A dedicated help-center article at `/help/matching/rejection-memory` accessible via:

- The "How to reverse this" link in Layer 5.
- A small help icon (?) in the confirmation modal header (Layer 3).
- The "Learn more" link in subsequent rejections (Layer 6, post-first-time).

### 8.1 Article content (outline)

1. What rejection means — "you're telling the system this pair is wrong forever"
2. Why it's permanent — Stage-1 user-trust commitment + correctness property
3. When to use rejection vs snooze — rejection = "this is wrong, don't re-suggest"; snooze = "I'll deal with this later, but it might still be valid"
4. Who can undo — Business Owner only, via Settings → Matching → Rejection Memory
5. What to do if you reject by mistake — three options: (a) catch it within 5s grace window via Layer 4 undo; (b) ask your Owner to reverse via BOOK-202 settings flow; (c) if you're not the Owner and the Owner is unavailable, escalate per your business's internal process

Stage-2+ may add a video tutorial showing the flow end-to-end.

---

## 9. Mobile

The entire reject flow is desktop-only per `mobile_write_rejection_endpoints.md` (the underlying RPC is a write surface). On mobile, the user sees:

- The proposed pair in the matching workspace mobile view (read-only).
- A "Resolve on desktop" card replacing the action area, with the standard mobile-rejection messaging from BOOK-184 §"Mobile behaviour".

The education layers (§§2–7) are therefore not surfaced on mobile because the action they educate about can't be triggered. Layer 5 (audit-trail surfacing) DOES appear on mobile because it's read-only.

---

## 10. Accessibility (WCAG 2.1 AA)

| Element | A11y commitment |
|---|---|
| Reject-permanently button | `aria-label="Reject this pair permanently — cannot be undone except by business Owner"` |
| Confirmation modal | Focus-trapped per BOOK-201 modal pattern; first-focus on reason picklist (NOT Reject button); Esc-cancel; checkbox `aria-required="true"` |
| Modal sentence-case title | `aria-labelledby` references the title element |
| Tooltip (Layer 2) | Screen-reader-announced via `aria-describedby` on the button |
| Toast undo countdown (Layer 4) | Visual countdown + screen-reader text: "Pair rejected. Undo available for 5 seconds. Press U to undo." |
| Keyboard shortcut U | Activates undo during grace toast; documented in the page's keyboard-shortcuts help dialog |
| First-time info panel (Layer 6) | Expanded by default = no expand-to-discover hidden content; `aria-expanded="true"` |
| Audit-trail badge (Layer 5) | `aria-label="Status: rejected permanently"` |

---

## 11. Per-role visibility

The user-education layers apply to all roles that can reject. Per BOOK-197 `resolution_action_enum.md` role × action matrix (the `reject_match` row):

| Role | Sees reject button? | Sees education layers? |
|---|---|---|
| Owner | ✓ | ✓ |
| Admin | ✓ | ✓ |
| Bookkeeper | ✓ | ✓ |
| Accountant | ✓ | ✓ |
| Reviewer | ✗ (cannot reject) | n/a |
| Read-only | ✗ | n/a |

Reviewer and Read-only roles don't see the reject button at all, so the education layers are not surfaced for them. The "Rejected (permanent)" status badge (Layer 5) IS visible to all roles because it's read-only audit-trail content.

---

## 12. Audit events (additions beyond BOOK-166's existing set)

| Event | Severity | When |
|---|---|---|
| `MATCHING_REJECTION_UNDONE_VIA_GRACE_PERIOD` | LOW | User undoes rejection within 5-second grace window (per Layer 4) |
| `MATCHING_REJECTION_FIRST_TIME_EDUCATED` | LOW | First-time-user info panel was surfaced (per Layer 6) — analytics signal |

Both are NEW events that need adding to `audit_event_taxonomy.md`. Payloads:

```jsonc
// MATCHING_REJECTION_UNDONE_VIA_GRACE_PERIOD
{
  "rejection_id":                "<uuid>",
  "undone_by_user_id":           "<uuid>",
  "transaction_id":              "<uuid>",
  "document_id":                 "<uuid>",
  "business_id":                 "<uuid>",
  "rejected_at":                 "<timestamptz>",
  "undone_at":                   "<timestamptz>",
  "elapsed_seconds":              <float 0-5>
}

// MATCHING_REJECTION_FIRST_TIME_EDUCATED
{
  "user_id":                     "<uuid>",
  "business_id":                 "<uuid>",
  "surfaced_at":                 "<timestamptz>"
}
```

---

## 13. Metrics to track post-launch (Stage-2+ analytics)

These metrics tell us whether the education layers work:

| Metric | Healthy range | Warning signal |
|---|---|---|
| Rejection rate (rejections / matches reviewed) | 5–15% (calibration-dependent) | Sudden spike → users confused about reject vs snooze; sudden drop → users avoiding the action when they should use it |
| Grace-period undo rate (undones / rejections) | < 3% | High rate → users routinely clicking wrong; signals Layer 3 modal isn't catching mistakes |
| Owner-override rate (overrides / rejections) | < 0.5% | High rate → users rejecting by mistake post-grace; signals education layers need tuning |
| First-time-rejection-then-Owner-override correlation | < 1% of first-time rejections | High correlation → first-time-user education (Layer 6) failing |
| Per-role rejection rate distribution | Distribution matches activity | Heavy skew toward one role → unfair load |

Stage-2+ analytics ingestion via `analytics` schema; Block 16 dashboard surfaces these metrics for ops review.

---

## 14. Cross-references

- `match_review_ui_spec.md` (BOOK-186) — host UI for the reject button; this doc adds educational layers around the existing affordance
- `rejection_memory_schema.md` (BOOK-166) — schema-level "forever-remember" commitment this UX implements; §"Audit event" + §"Retention policy"
- `rejection_memory_privileged_override_ui_spec.md` (BOOK-202) — Owner-only reversal path the UI references in Layers 2, 3, 5, 7, 8
- `resolution_action_enum.md` (BOOK-197) — role × action matrix that determines which roles see the reject button (§11)
- `mobile_write_rejection_endpoints.md` — desktop-only enforcement (§9)
- `review_queue_card_layout_ui_spec.md` (BOOK-184) — review card hosts the reject affordance + mobile messaging pattern (§9)
- `audit_event_taxonomy.md` — needs `MATCHING_REJECTION_UNDONE_VIA_GRACE_PERIOD` + `MATCHING_REJECTION_FIRST_TIME_EDUCATED` added (§12)
- `design_system_tokens` — `--color-action-permanent-warning` new token (§2)
- `component_library_ui_spec.md` — Modal, Toast, Tooltip, Button components
- Block 10 Phase 06 — owning phase
- Block 14 Phase 04 — resolution actions context
- Stage 1 decision — "remember forever for the same (transaction, document) pair; never re-suggest a pair the user has rejected"
