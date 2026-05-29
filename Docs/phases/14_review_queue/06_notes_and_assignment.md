# Block 14 — Phase 06: Notes & Assignment

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Notes & Assignment)
- Decisions log: `Docs/decisions_log.md` (single notes field per issue; assignment with in-app + email notification; Owner / Admin can assign to Bookkeeper / Accountant; anyone with the right role can still resolve regardless of assignment)

## Phase Goal

Implement the per-issue notes field and the assignment surface. Notes capture user reasoning during resolution (especially for exceptions and judgement calls); assignment lets Owners / Admins route an issue to a specific user (with notification) without removing other users' ability to resolve. After this phase, the queue supports collaborative resolution.

## Dependencies

- Phase 01 (`review_issues` schema — `notes`, `assigned_to`, `assigned_at`, `assigned_by`, `assignment_notification_sent_at`; `REVIEW_ASSIGN` permission surface)
- Phase 04 (resolution actions — `Add explanation note` writes to `notes`; `Send to accountant review` invokes assignment)
- Block 02 Phase 04 (permission matrix — `REVIEW_ASSIGN` surface; role membership for assignee validation)
- Block 02 Phase 11 (settings surface — assignee-picker UX)
- Block 05 Phase 02 (audit log)

## Deliverables

- **Notes API:**
  - `notes.update({ issue_id, actor_user_id, notes_text? })` — replace the notes field; `notes_text` may be empty (clears the note); audit-logged.
  - **Per-issue single notes field** (not a thread; not multiple comments) — Stage 1 default per the decisions log. Sub-doc tracks the Stage 2+ comment-thread upgrade.
  - **Edit history:** every update emits `REVIEW_NOTE_UPDATED` with the before/after text; the audit log carries the full history. The current note is what's queryable on the row.
  - **Notes during resolution:** Phase 04's resolution actions accept an `optional_note` parameter; the resolution writes the note to `review_issues.notes` AND emits the resolution audit event with the note inline. The two paths (`notes.update` vs resolution-with-note) converge on the same column.
- **Notes permissions:**
  - **Read:** any user with `REVIEW_QUEUE_VIEW` (everyone).
  - **Write:** any user with `REVIEW_QUEUE_RESOLVE` (Owner / Admin / Bookkeeper / Accountant). Reviewer / Read-only cannot write notes.
- **Assignment API:**
  - `review_queue.assign({ issue_id, actor_user_id, assignee_user_id }) → assignment_record`
    - Permission gate: `REVIEW_ASSIGN` (Owner / Admin only per the matrix).
    - **Assignee validation:** `assignee_user_id` must have `role ∈ {Bookkeeper, Accountant}` in the same business AND have `REVIEW_QUEUE_RESOLVE` (so they can act on the assignment). Other roles (Owner / Admin / Reviewer / Read-only) are rejected — Owners / Admins typically don't need assignments (they're the assigners); Reviewer / Read-only can't resolve.
    - Sets `assigned_to`, `assigned_at`, `assigned_by` on the row.
    - Triggers Phase 06's notification dispatcher (see below).
  - `review_queue.reassign({ issue_id, actor_user_id, new_assignee_user_id })` — same gate; updates the assignment columns; emits `REVIEW_ASSIGNMENT_REASSIGNED`; new notification fires; the prior assignee is silently un-notified (no inverse notification — sub-doc tracks the choice).
  - `review_queue.clear_assignment({ issue_id, actor_user_id })` — clears the assignment; emits `REVIEW_ASSIGNMENT_CLEARED`; no notification fires.
- **Notification dispatcher:**
  - On `review_queue.assign` or `review_queue.reassign`, the dispatcher writes to two channels:
    - **In-app inbox** — a row in `notifications` (sub-doc owns the schema; Stage 1 default — a per-user notifications table with `kind`, `payload`, `read_at`).
    - **Email** — sent to the assignee's email address (per Block 02 Phase 02 — user identity).
  - The dispatcher is async (queued via Block 03 Phase 09's scheduler); it doesn't block the assignment API call.
  - On successful delivery, `assignment_notification_sent_at` is populated. On failure (transient or permanent), a HIGH review issue is raised — but only after retries are exhausted.
  - **Notification-failure issue special-class rules (closes the recursion gap):** notification-failure issues are a distinct class with deterministic handling that avoids the circular path of "notification failed → raise issue → that issue gets assigned → its assignment notification fails":
    - **No AI call** for card content — Phase 03's structured-fallback template runs immediately (deterministic title / description / recommended_action); `card_content_tier_used = NONE`, `card_content_fallback_applied = false` (this is the canonical content, not a fallback).
    - **No assignment** — the issue auto-routes to all `Owner`-role users in the business via the in-app inbox only. No email notification is dispatched (the email channel just failed; sending another would likely fail too).
    - The issue type is `review_queue.notification_dispatch_failed`; allowed resolution actions are `Add explanation note`, `Re-run scan after change` (which re-attempts the original notification), `Ignore with reason`.
  - **Email opt-out:** sub-doc tracks per-user email preferences (Stage 1 default — opt-in by default; opt-out via account settings).
  - **In-app inbox is mandatory** (cannot be opted out of) — Owner / Admin governance requirement.
- **Resolve-vs-assignment relationship** (the architecture-doc commitment):
  - Anyone with `REVIEW_QUEUE_RESOLVE` can resolve any issue **regardless of `assigned_to`**. Assignment is a routing hint, not a lock.
  - When a non-assignee resolves an assigned issue, the resolution audit event captures both `actor_user_id` and `assigned_to` (so reports can identify "issue was assigned to X but resolved by Y" patterns). Sub-doc tracks the dashboard surface.
- **Assignee inbox view** (cross-block contract with Block 16 dashboard):
  - The dashboard exposes a per-user "Assigned to me" view filtering `review_issues WHERE assigned_to = current_user AND status = OPEN`.
  - Sub-doc owns the dashboard sub-section; this phase pins the underlying query.
- **`Send to accountant review` resolution action wiring** (Phase 04 → this phase):
  - Phase 04's `Send to accountant review` action invokes `review_queue.assign({ ..., assignee_user_id })` where the assignee is selected from a per-business list of `Accountant`-role users. The picker UX is owned by the sub-doc; the underlying API is unified.
  - The action does NOT close the issue — it stays `OPEN` with the assignment attached.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_NOTE_UPDATED` (per `notes.update` call OR per resolution-with-note)
  - `REVIEW_ASSIGNMENT_CREATED`
  - `REVIEW_ASSIGNMENT_REASSIGNED` (with prior assignee in payload)
  - `REVIEW_ASSIGNMENT_CLEARED`
  - `REVIEW_ASSIGNMENT_NOTIFICATION_DISPATCHED` (one event per assignment with payload `{ channels_succeeded: ['in_app', 'email'], channels_failed: [] }` — single event covers both channels per the audit-volume principle from Phase 03)
  - `REVIEW_ASSIGNMENT_NOTIFICATION_FAILED` (per failed delivery; HIGH review issue raised after retry exhaustion)
  - `REVIEW_ASSIGNMENT_REJECTED_INVALID_ASSIGNEE` (when the assignee fails the role / surface / business check)

## Definition of Done

- A `Bookkeeper` writes a note to an issue → `REVIEW_NOTE_UPDATED` fires; the note is queryable on the row.
- An `Owner` assigns an issue to a `Bookkeeper` → `REVIEW_ASSIGNMENT_CREATED` fires → notification dispatcher writes the in-app + email entries → `assignment_notification_sent_at` populates.
- A `Bookkeeper` attempting to assign is denied with the right error (`REVIEW_ASSIGN` denied).
- An `Owner` attempting to assign to a `Read-only` user is rejected with `REVIEW_ASSIGNMENT_REJECTED_INVALID_ASSIGNEE`.
- An `Owner` attempting to assign to a user from a different business is rejected.
- An `Admin` invokes `review_queue.reassign` from Bookkeeper-A to Bookkeeper-B; `REVIEW_ASSIGNMENT_REASSIGNED` fires with both prior and new assignee; new notification.
- A non-assignee Bookkeeper resolves an assigned issue → resolution succeeds → audit event captures both `actor_user_id` and `assigned_to`.
- A `Reviewer` attempts a write to `notes` → denied (no `REVIEW_QUEUE_RESOLVE`).
- A user opts out of email notifications → assignment still creates the in-app entry; no email is sent.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **`notifications` table sub-doc** — schema, per-user inbox, retention.
- **Email-send mechanism sub-doc** — provider integration, bounce handling, retry semantics.
- **Email-opt-out sub-doc** — per-user preferences, account-settings UX.
- **Assignee-picker UX sub-doc** — list rendering, search, per-business filtering.
- **Stage 2+ comment-thread upgrade sub-doc** — what would change in `notes` schema for multi-comment support.
- **Reassignment-notify-prior-assignee sub-doc (deferred)** — Stage 1 default is "no inverse notification"; Stage 2+ tunable.
- **Assigned-but-resolved-by-other dashboard sub-doc** — Block 16 surface for assignment-effectiveness reports.
