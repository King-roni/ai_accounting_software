# Block 14 — Review Queue & Human Review

## Role in the System

This block is where the user sees what the system needs from them. It collects every issue raised by upstream blocks (Block 06's End-Scan, Block 07's dedup, Block 08's classification confidence, Block 10's matching, Block 11's VAT review flag, Block 13's invoice lifecycle anomalies), groups them into the **six fixed UI buckets**, and offers a small set of one-click resolution actions for each. The user's resolutions feed back into the active workflow run.

The block exists to honor Principle 5 (Simple Interface, Advanced Backend). The system underneath may track twenty distinct technical issue types, four match levels, eight VAT treatments, and a dozen confidence thresholds — but the user sees a clean, grouped queue with plain-language descriptions and obvious actions.

---

## Scope

### In scope
- The six fixed UI buckets and the routing logic from `issue_type` → `issue_group`
- Issue card structure (title, description, recommended action, attached context)
- Severity levels (`LOW`, `MEDIUM`, `HIGH`, `BLOCKING`) and how they affect finalization
- Resolution actions and their audit-log shape
- The HUMAN_REVIEW_HOLD experience inside OUT_MONTHLY and IN_MONTHLY
- Bulk actions on grouped issues
- Plain-language rendering of upstream technical content

### Out of scope (covered elsewhere)
- Generation of the issues themselves → Blocks 06, 07, 08, 10, 11, 13
- Final period lock → Block 15
- Audit log internals → Block 05

---

## The Six Issue Groups

Every issue raised anywhere in the system lands in exactly one of these buckets:

```text
1. Missing Documents
2. Needs Confirmation
3. Possible Wrong Match
4. Possible Tax/VAT Issue
5. Unusual Transaction
6. Ready to Finalize
```

The mapping from `issue_type` (the internal taxonomy) to `issue_group` (the UI bucket) is owned by this block. It is a fixed table — adding a new `issue_type` always declares which `issue_group` it belongs to.

`Ready to Finalize` is special: it is the only group that, when populated alone with no items in the other five, signals that the run can advance to finalization. It is not a "queue" in the same sense — it's the green-light state.

---

## Issue Card Structure

Each card surfaces:

```text
plain-language title              (one short line)
plain-language description        (1-3 sentences)
context                           (transaction amount, date, supplier/client, current tag, attached document if any)
severity                          (LOW / MEDIUM / HIGH / BLOCKING)
recommended action                (the most likely resolution)
one-click actions                 (the available resolutions for this issue)
expand                            (technical detail on demand for advanced users)
```

Example:

> **Missing invoice for Google Workspace payment**
> EUR 49.00 paid on 3 April 2026 to Google Ireland Ltd. No matching invoice was found in email or Drive.
> *Recommended:* upload invoice, or mark as no invoice available.
> *Severity:* HIGH (blocks finalization for OUT_EXPENSE without an exception).

The technical taxonomy (illustrative examples only: `OUT_EXPENSE_NO_INVOICE`, `MATCH_BELOW_LEVEL_3` — the canonical `issue_type` strings are owned by each producing block) is hidden by default; advanced users can expand a card to see them.

---

## Severity Levels

```text
LOW       — informational; doesn't block, can be deferred to next run
MEDIUM    — should be reviewed; doesn't block finalization
HIGH      — should be resolved; blocks unless user documents an exception
BLOCKING  — must be resolved; finalization gate refuses to advance
```

`BLOCKING` is reserved for cases where finalizing without resolution would corrupt the accounting record (e.g., an `UNKNOWN`-classified transaction, a failed mandatory VAT classification, a duplicate-invoice claim across transactions).

---

## Resolution Actions

Each issue type declares which actions are available. The full action vocabulary:

```text
Upload document
Confirm match
Reject match
Change tag
Change transaction type
Mark as internal transfer
Mark as bank fee
Mark as non-deductible
Mark as no invoice available (with reason)
Add explanation note
Send to accountant review
Ignore with reason
Re-run scan after change
```

Every resolution emits an audit event capturing the actor, the issue, the chosen action, and the reason if free-text was provided.

---

## Bulk Actions

Within an issue group, users can apply a single resolution to multiple issues at once. Examples:

- "Confirm all matches in this group" — applies `Confirm match` to every selected `Needs Confirmation` issue.
- "Mark all small bank fees as bank fees" — applies the type-change to every selected `Unusual Transaction` matching a filter.

Bulk actions are gated by a **confirmation step** that shows the affected set before commit. Each affected issue produces its own audit event.

## Notes & Assignment

- **Per-issue notes:** every issue carries a single free-text **notes field** that the resolving user can fill in to document reasoning (especially for exceptions and judgement calls). The note is captured in the audit log alongside the resolution.
- **Issue assignment:** Owner and Admin roles can **assign an issue to a Bookkeeper or Accountant** within the same business. The assignee is notified (in-app + email). Anyone with the right role can still resolve any issue regardless of assignment.

## Issue Snooze

Non-blocking issues (severity `LOW` or `MEDIUM`) can be **snoozed** with an explicit reason. Snoozed issues do not block finalization for the current run; they automatically reappear at the start of the next workflow run for the same business so they aren't forgotten. Snooze actions are audit-logged with their reason text.

`HIGH` and `BLOCKING` issues cannot be snoozed — they must be resolved or formally documented as exceptions.

## Re-Scan on Resolution

When a user resolves an issue, the End-Scan engine **re-runs only on the issues affected by the resolution** — not a full re-scan. Affected issues include any issue touching the same transaction, the same document, or the same match record as the resolved item. This keeps the queue current without reprocessing the whole period after every click.

## Mobile UX

Mobile in MVP is **read-only**: dashboards, transaction drill-down, and queue browsing all work on a phone, but issue resolution actions are desktop-only. The expected pattern is "review on the go, resolve at the desk".

---

## HUMAN_REVIEW_HOLD Experience

Both OUT_MONTHLY and IN_MONTHLY enter `HUMAN_REVIEW_HOLD` whenever blocking issues exist. From the user's perspective, this is simply "your review queue has X items waiting". The workflow advances automatically as soon as zero blocking issues remain and the user records explicit approval.

`HUMAN_REVIEW_HOLD` is the **phase name**; while it is the active phase of a run with blocking issues, the engine sets the **run-level state** (Block 03 lifecycle) to `REVIEW_HOLD`. The two are coupled by definition — a run is in `REVIEW_HOLD` because its active phase is `HUMAN_REVIEW_HOLD` and at least one blocking issue is open. They are not the same thing, but they always travel together.

The HOLD is not a separate UI screen — it's the same review queue, with the only difference being a "Ready to finalize" state at the top of the queue once all blockers are cleared.

---

## Plain-Language Rendering

The translation from technical findings to plain language is a Block 06 responsibility (Tier 2 by default; Tier 3 only when the case warrants extra clarity). Block 14 owns the **rendering**: how cards are laid out, how groups are presented, how actions are labelled, how severity is colour-coded.

Card content is generated at issue-creation time, not at render time, so the user always sees stable text and the audit log captures exactly what the user saw.

---

## Interfaces

### Inputs
- `Review Issue` records produced by upstream blocks (06, 07, 08, 10, 11, 13)
- The active workflow run's state (Block 03)
- Principal context for permission checks (Block 02)

### Outputs
- Resolution events back to the workflow run, allowing gates to re-evaluate
- Audit events for every resolution (Block 05)
- A "ready" signal to Block 15 when zero blocking issues remain and approval is recorded

---

## Operating Rules

- **Principle 5 (Simple Interface):** the user only sees plain-language content; technical taxonomy is collapsed behind expand.
- **Principle 1 (Workflow-First):** resolutions advance state through the engine; the queue does not directly mutate ledger or transaction records.
- **Principle 3 (AI Assists, Rules Decide):** AI generates the plain-language card content; the resolution itself is always recorded as a human action.
- **Stage 1 decisions applied:** issue groups are the six fixed buckets; the role × surface matrix from Block 02 determines who can resolve what; bulk actions emit one audit event per issue.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Bulk actions:** yes, with confirmation step — covered in Bulk Actions.
- **Notes per issue:** single notes field — covered in Notes & Assignment.
- **Issue assignment:** yes, with notification — covered in Notes & Assignment.
- **Issue snooze:** yes, with explicit reason, for non-blocking issues — covered in Issue Snooze.
- **Re-scan on resolution:** affected-issues only — covered in Re-Scan on Resolution.
- **Mobile UX:** desktop-first, mobile read-only — covered in Mobile UX.

No open questions remain at the architecture level. Phase docs will define the notification channel for assignments, the exact "affected issues" scope for re-scan, and the mobile read-only UI breakpoints.
