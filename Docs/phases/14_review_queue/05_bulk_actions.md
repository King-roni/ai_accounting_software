# Block 14 — Phase 05: Bulk Actions

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Bulk Actions)
- Decisions log: `Docs/decisions_log.md` (bulk actions: yes, with confirmation step; one audit event per affected issue)

## Phase Goal

Implement within-group bulk apply: a user selects multiple issues in the same `issue_group` and applies a single resolution action across all of them. Mandatory confirmation step shows the affected set before commit; each affected issue still produces its own audit event (per the Stage 1 decision). After this phase, common patterns like "confirm all matches in this group" or "mark all small bank fees" become one click.

## Dependencies

- Phase 01 (`review_issues` schema; `REVIEW_QUEUE_RESOLVE` permission surface)
- Phase 02 (`issue_group` and `severity` taxonomies)
- Phase 04 (resolution-action vocabulary; per-`issue_type` allowed-actions; per-action permission gating)
- Block 03 Phase 05 (gate re-evaluation — bulk resolutions trigger re-eval per affected issue)
- Block 05 Phase 02 (audit log — one event per affected issue)

## Deliverables

- **Note on snooze:** snooze is NOT in the 13-action vocabulary because it doesn't close the issue (status transitions to `SNOOZED`, not `RESOLVED` / `DISMISSED`). The architecture-doc framing of "bulk actions" includes snooze conceptually, but the implementation splits `bulk.applyAction` (closing actions) and `bulk.snooze` (Phase 07 — non-closing) into two parallel surfaces with the same preview / confirmation pattern. Both share the per-issue audit-event emission rule.
- **Bulk-apply API:**
  - `bulk.applyAction({ business_id, run_id?, issue_ids: UUID[], action_kind, action_payload, optional_note? }) → BulkApplyResult`
  - Returns `{ requested: N, applied: M, skipped: K, failures: [{ issue_id, reason }, ...] }` — partial success is allowed.
  - **Pre-commit confirmation step (mandatory):** the API has two phases — `bulk.preview(...)` returns the affected-set summary; the UI shows it; `bulk.applyAction(...)` requires a `confirmation_token` returned by preview. The token is single-use, business-scoped, expires after 5 minutes (sub-doc tracks the timing). This prevents accidental "click → apply" without seeing the impact.
- **Selection rules:**
  - **Same `issue_group` only** — bulk actions cross-bucket are NOT permitted in Stage 1. The architecture doc commits to "within an issue group" — bulk action across `Missing Documents` + `Possible Wrong Match` is rejected.
  - **Selection mechanisms:**
    - **Explicit IDs** — the user multi-selects cards in the UI; the IDs flow into the API.
    - **Filter-based** — the user defines a filter (e.g., "all `dedup.possible_duplicate` with amount < €5") and the API resolves it to IDs at preview time. **Stale-filter protection:** if new issues match the filter between preview and commit, they are NOT included in the apply (the confirmation captured the exact ID set the user saw).
- **Per-issue execution:**
  - The bulk action iterates over the selected IDs; for each, it invokes the per-issue resolution path from Phase 04.
  - **Each affected issue produces its own audit event** (`REVIEW_RESOLUTION_APPLIED` per Phase 04 — Stage 1 decision pinned in the decisions log).
  - **Per-issue allowed-action check:** if the action is not in an issue's `allowed_resolution_actions`, that issue is skipped (`reason = "ACTION_NOT_ALLOWED"`); other issues proceed.
  - **Per-issue permission check:** the `REVIEW_QUEUE_RESOLVE` gate runs once per call (the user must have the surface); per-action sub-permissions (e.g., `Ignore with reason` on `BLOCKING`) are checked per issue and recorded as failures rather than aborting the whole bulk.
  - **Per-issue idempotency:** already-closed issues are skipped (`reason = "ALREADY_CLOSED"`); audit-logged.
  - **Severity-restricted dismissal:** when `action_kind = Ignore with reason`, any selected issue with `severity = BLOCKING` is rejected per Phase 04's restriction; the rest proceed.
- **Atomicity:**
  - **Not transactional across issues** — partial success is a feature, not a bug. The user sees in the result which issues succeeded and which failed.
  - The producing block's downstream effects are per-issue atomic (e.g., `Confirm match` for one issue is atomic with its `match_records` update; the next issue's update is a separate transaction).
  - Sub-doc tracks the failure-recovery UX: the result modal lets the user re-attempt failed issues individually.
- **Bulk action examples (Stage 1 representative):**
  - **`Confirm all matches in Needs Confirmation`** — selects all `matching.matched_needs_confirmation` issues; applies `Confirm match`.
  - **`Mark all small bank fees as bank fees`** — filter: `issue_type = classification.unknown_type` AND amount < €5; applies `Mark as bank fee`.
  - **`Add explanation note to all`** — bulk-applies the same explanation note across selected issues; useful for "documented exception, audited under Y" patterns.
  - **`Ignore all unusual transactions with reason`** — selects all `endscan.unusual_amount` MEDIUM issues; applies `Ignore with reason`.
- **Common bulk-action filter primitives** (sub-doc owns the canonical filter-DSL; Stage 1 representative):
  - `issue_type = ?`
  - `severity ∈ {?, ?, ...}`
  - `transaction.amount ≤ ?` / `≥ ?` / `between ?, ?`
  - `transaction.tag = ?`
  - `created_at ≥ ?` / `≤ ?`
  - `assigned_to = ?` / `IS NULL`
- **Permission gating:**
  - `REVIEW_QUEUE_RESOLVE` is required for the call (same surface Phase 04 uses).
  - The action-kind sub-permissions from Phase 04 apply per issue (per-issue rejection rather than whole-bulk rejection).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_BULK_PREVIEW_REQUESTED` (one per `bulk.preview` call; payload includes the resolved ID count)
  - `REVIEW_BULK_APPLIED` (one per `bulk.applyAction` call; payload includes total counts: requested / applied / skipped / failures)
  - `REVIEW_RESOLUTION_APPLIED` (Phase 04 — one per affected issue; the per-issue events are emitted as part of the bulk apply)
  - `REVIEW_BULK_CONFIRMATION_TOKEN_EXPIRED` (when a stale token is rejected)

## Definition of Done

- A user previews a bulk apply for 50 selected `matching.matched_needs_confirmation` issues; the preview returns a confirmation token + the affected-set summary.
- The user calls `bulk.applyAction` with the token + `action_kind = Confirm match`; 50 individual resolutions execute; 50 individual audit events fire.
- A bulk apply with a mix of allowed and disallowed actions per issue produces a partial-success result; the failures list explains why each was skipped.
- A bulk `Ignore with reason` over a mix of `MEDIUM` and `BLOCKING` issues skips the `BLOCKING` ones with the right error.
- A bulk apply across two different `issue_group` buckets is rejected.
- An expired confirmation token is rejected; the user re-previews.
- A bulk apply triggers per-issue gate re-evaluation; the workflow may transition out of `AWAITING_APPROVAL` (the canonical state for HUMAN_REVIEW_HOLD per Block 12 Phase 07 / Block 13 Phase 09) if the bulk cleared the last blocking issue.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Confirmation-token mechanism sub-doc** — token shape, expiry, replay protection.
- **Filter-DSL sub-doc** — exact grammar for filter-based bulk; UI builder.
- **Result-modal UX sub-doc** — partial-success rendering; per-issue retry path.
- **Bulk-performance sub-doc** — typical bulk size; per-issue latency budget; transactionality trade-offs.
- **Cross-bucket bulk action sub-doc (deferred Stage 2+)** — the rare case of "ignore all MEDIUM across all buckets" with explicit per-bucket confirmation.
- **Audit-volume sub-doc** — per-issue audit emission cost analysis; aggregate-event alternatives if volume becomes painful.
