# Legal Hold UI Spec

**Category:** UI · **Owning block:** 04 — Data Architecture · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The Owner-only UI for managing per-business legal holds: panel placement, set/lift forms, history display, status badge, error states. The UI consumes the canonical `legal_holds` table per `legal_hold_lifecycle_policy.md` (extended this cycle with `lift_reason` + `lifted_by_user_id` columns). The displayed ACTIVE / LIFTED / EXPIRED / SCHEDULED statuses are derived via the `v_legal_hold_status` view.

---

## 1. Panel placement

Route: `/business/:business_id/settings/legal-hold`

Visibility: **Owner role only** per `permission_matrix.md` `LEGAL_HOLD/SET` and `LEGAL_HOLD/LIFT` surfaces (NEW — added this cycle). Admin/Bookkeeper/Accountant/Reviewer/Read-only see the route return HTTP 403 with `ACCESS_DENIED`; the side-bar nav item is not rendered.

Mobile: read-only access — the panel renders status badge + history but the set/lift forms are not presented (write surfaces rejected per `mobile_write_rejection_endpoints.md`).

---

## 2. Status badge

Top of the panel, always visible:

| `v_legal_hold_status.status` | Badge color | Label | Subtext |
|---|---|---|---|
| No rows / all `LIFTED`/`EXPIRED` | `--color-status-success` | "No active legal hold" | "Last status change: <relative_time>" |
| 1+ `ACTIVE` | `--color-status-danger` | "Active legal hold — <hold_kind>" | "Filed by <user_name>, <relative_time>" |
| 1+ `SCHEDULED` | `--color-status-warning` | "Legal hold scheduled — <hold_kind>" | "Activates on <hold_started_at>" |

When multiple active holds exist: badge shows count (e.g. "2 active legal holds") + the most recently filed `hold_kind`.

---

## 3. Set-hold form

Visible to Owner when no active hold exists, OR collapsed-by-default when active holds exist (a "+ File additional hold" link expands).

| Field | Type | Validation | Notes |
|---|---|---|---|
| `hold_kind` | Select | Required; fixed enum (TAX_INVESTIGATION / COURT_ORDER / GDPR_ENQUIRY / REGULATOR_REQUEST / OTHER) per `legal_hold_reason_guidance.md` §2 | OTHER unlocks a `hold_kind_other` free-text field |
| `hold_authority` | Text | Required, max 200 chars, non-empty | E.g. `"Tax Department of Cyprus / Case #2026-AC-1923"` |
| `hold_ends_at` | Date picker | Optional; must be > now() + 1 hour | NULL = open-ended (recommended default) |
| Acknowledgment checkbox | Checkbox | Required: "I confirm the legal authority for this hold is documented" | Submit disabled until checked |

Submit button:

- Label: "File legal hold"
- Color: `--color-status-danger` (high-consequence action)
- Disabled state until all required fields populated + acknowledgment checked
- On click: triggers step-up MFA per `legal_hold_step_up_policy` (NEW — cross-block coordination flagged for B02·P06)
- On step-up pass: `POST /api/v1/businesses/:business_id/legal-holds` with form payload + `step_up_token_id`
- On success: panel refreshes; new ACTIVE row appears in history; `LEGAL_HOLD_SET` audit event emitted

---

## 4. Lift-hold form

Per active hold row, an inline "Lift this hold" button. Click expands:

| Field | Type | Validation |
|---|---|---|
| `lift_reason` | Textarea | Required, non-empty, max 2000 chars |
| Acknowledgment checkbox | Checkbox | Required: "I confirm the lifting authority is documented and the hold is no longer required" |

Submit: triggers step-up MFA, then `POST /api/v1/legal-holds/:id/lift` with `{lift_reason, step_up_token_id}`. On success the row transitions to LIFTED status — backend sets `hold_ends_at = now()` + `lift_reason` + `lifted_by_user_id` atomically per `legal_hold_lifecycle_policy.md` §4.

---

## 5. History list

Below the current-status section, a chronological list of all holds (active + past):

```
┌──────────────────────────────────────────────────────────────────────┐
│ ⚖  TAX_INVESTIGATION — Tax Department of Cyprus / Case #2026-AC-1923 │
│                                                                       │
│ Filed: 2026-02-15 by Maria K.                                         │
│ Lifted: 2026-04-22 by Andreas P.                                      │
│ Reason for lifting: "Investigation concluded; no further hold req'd."│
│                                                                       │
│ Status: LIFTED                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

Sort order: most-recent first by `filed_at`. Pagination at 20 rows.

Empty state: "No legal holds have been filed for this business." with a `[Filing guidance]` link opening an inline modal rendered from `legal_hold_reason_guidance.md`.

---

## 6. Error states

| Scenario | UI behavior |
|---|---|
| Step-up token expired between submit and API call | Inline: "Verification expired — please re-confirm." |
| `LEGAL_HOLD_PERMISSION_DENIED` (Owner role removed mid-form) | Toast: "You no longer have permission for this action." + redirect to business overview |
| `LEGAL_HOLD_VALIDATION_FAILED` (server validation) | Per-field inline error from server payload |
| Network failure | Toast: "Could not save. Check your connection." + form preserves values |
| Lift attempt on already-LIFTED row (race condition) | Toast: "This hold has already been lifted." + history refreshes |

---

## 7. Empty state — first-time

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                       │
│            No legal holds on file                                     │
│                                                                       │
│   A legal hold pauses retention deletion for this business.           │
│   File one only when required by a regulator, court, or               │
│   pending audit. See [Filing guidance].                               │
│                                                                       │
│                  [+ File a legal hold]                                │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 8. Audit events surfaced

The panel does not render a live audit feed — those events appear in Block 16's standard audit history:

- `LEGAL_HOLD_SET` (HIGH; emitted on file)
- `LEGAL_HOLD_LIFTED` (MEDIUM; emitted on manual lift)
- `LEGAL_HOLD_EXPIRED` (LOW; emitted by daily scan when `hold_ends_at` passes without manual lift — NEW event from `legal_hold_lifecycle_policy.md`)
- `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` (LOW; consumer event visible from Block 16 audit history)

---

## 9. Accessibility

- All form fields have explicit `<label>` elements
- Step-up challenge UI inherits a11y from `step_up_ui_spec.md`
- Status badge: `aria-live="polite"` for screen-reader status announcements
- History list: `<table>` with proper headers + keyboard row navigation
- Date picker meets WCAG 2.1 AA for keyboard + screen reader

---

## 10. Cross-references

- `legal_hold_lifecycle_policy.md` (B04·P11 seq 426) — schema + state machine + `v_legal_hold_status` view
- `legal_hold_reason_guidance.md` (B04·P11 seq 428) — `hold_kind` enum + `hold_authority` examples + content rules
- `legal_hold_maximum_window_policy.md` (B04·P11 seq 430) — `hold_ends_at` upper bound when set
- `legal_hold_admin_extension_policy.md` (B04·P11 seq 436) — Owner-only MVP rule rationale
- `object_lock_retention_extension_policy.md` (B04·P11 seq 424) — async job triggered on `LEGAL_HOLD_SET`
- `permission_matrix.md` — NEW `LEGAL_HOLD/SET` + `LEGAL_HOLD/LIFT` surfaces (added this cycle)
- `step_up_ui_spec.md` — step-up challenge UI pattern
- `legal_hold_step_up_policy` (cross-block coordination flagged for B02·P06) — step-up validity window
- `mobile_write_rejection_endpoints.md` — set/lift listed as mobile-rejected
- `design_system_tokens.md` — `--color-status-*` tokens
- Block 04 Phase 11 — owning phase
- Block 02 Phase 04 — `permission_matrix` consumer
- Block 02 Phase 06 — step-up framework
- Block 16 — audit-history surface
