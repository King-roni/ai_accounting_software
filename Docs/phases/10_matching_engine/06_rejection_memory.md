# Block 10 — Phase 06: Rejection Memory

## References

- Block doc: `Docs/blocks/10_matching_engine.md` (Rejection Memory section)
- Decisions log: `Docs/decisions_log.md` (rejected matches remembered forever per `(transaction, document)` pair — Stage 1)

## Phase Goal

Make the Stage 1 "forever-remember rejected pairs" rule operational. After this phase, when a user rejects a suggested match, the engine writes that rejection to `match_rejection_memory` (Phase 01) and the scoring engine (Phase 02) skips that pair forever in subsequent runs. The rejection is **pair-scoped**, not global — rejecting `(txn1, doc1)` doesn't affect `(txn2, doc1)` or `(txn1, doc2)`.

## Dependencies

- Phase 01 (`match_rejection_memory` table with the `(business_id, transaction_id, document_id)` unique constraint)
- Phase 03 (auto-confirm rule; the user-reject path lands here)
- Phase 02 (scoring engine reads this for suppression — the dependency is already wired in Phase 02's deliverables)

## Deliverables

- **Rejection recording flow** (consumed by Phase 03's user-reject resolution action):
  1. User clicks "Reject this match" on a `MATCHED_NEEDS_CONFIRMATION` or `POSSIBLE_MATCH` review issue.
  2. The flow requires a `rejection_reason` (free text or selected from common reasons: "wrong supplier", "wrong amount", "different period", "already matched elsewhere", "other").
  3. Insert a `match_rejection_memory` row with `(business_id, transaction_id, document_id, rejected_by, rejected_at, rejection_reason, original_match_record_id)`.
  4. Update the original `match_records` row's `match_status` to `REJECTED_MATCH`. The row is preserved for audit traceability — it doesn't get deleted.
  5. Emit `MATCHING_REJECTION_RECORDED` audit event.
- **Rejection lookup contract** (consumed by Phase 02):
  - Before computing signals for a `(transaction, document)` pair, the scoring engine checks `match_rejection_memory` for the pair.
  - If found, the pair is **suppressed**: no score is computed, no `match_records` row is created, no review issue is raised. Emit `MATCHING_REJECTION_SUPPRESSED`.
- **Pair-scoped semantics:**
  - Rejecting `(txn1, doc1)` does NOT suppress `(txn2, doc1)` — `doc1` is still a candidate for other transactions.
  - Rejecting `(txn1, doc1)` does NOT suppress `(txn1, doc2)` — `txn1` is still scored against other documents.
  - The unique constraint on `(business_id, transaction_id, document_id)` enforces this scope at the database layer.
- **Privileged override path** (rare; for genuine mistakes):
  - **Authorized roles:** `Owner` only. `Admin` is intentionally NOT authorized for this action — `Admin` covers day-to-day operational oversight, but Stage 1's "rejection-is-permanent" semantics require the highest accountable role to override. If a multi-business organization needs broader access in Stage 2+, that's a sub-doc decision; Stage 1 keeps it Owner-scoped.
  - The override is exposed in a settings-level admin surface (not in the review queue itself).
  - Requires step-up auth (Block 02 Phase 06).
  - Audit-logged with mandatory reason text in `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED`.
  - This is the only path back from a rejection; the standard review-queue resolution actions don't expose un-reject (the rejection is meant to be permanent).
- **No undo via standard UI:**
  - The review queue's resolution actions never include "un-reject". Stage 1's "forever-remembered" decision is enforced by absence of an undo button at the user-facing surface.
  - If a user genuinely needs to re-suggest a previously rejected pair, they go through the privileged override path or manually create a new match via the "edit and confirm" flow on a different review issue.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention):
  - `MATCHING_REJECTION_RECORDED` (already declared in Phase 01)
  - `MATCHING_REJECTION_SUPPRESSED` (already declared in Phase 02)
  - `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` (this phase)

## Definition of Done

- Rejecting a match writes to `match_rejection_memory`; the row's `match_records` entry transitions to `REJECTED_MATCH`.
- The next workflow run for the same business never re-scores or re-suggests the rejected `(txn, doc)` pair (verified via integration test).
- Rejecting `(txn1, doc1)` does NOT affect scoring for `(txn1, doc2)` or `(txn2, doc1)`.
- The Owner-privileged override removes a rejection row, requires step-up, and audit-logs with reason.
- The standard UI has no "un-reject" button anywhere in the review queue.
- Tests cover: reject + suppression on next run, pair-scope isolation, privileged override.

## Sub-doc Hooks (Stage 4)

- **Common rejection reasons sub-doc** — the picklist content, free-text fallback, audit shape.
- **Privileged override UX sub-doc** — settings page layout, step-up flow, audit visibility.
- **Cleanup policy sub-doc** — when (if ever) `match_rejection_memory` rows are pruned; default: never within retention window.
- **User-education sub-doc** — how the UI communicates "this rejection is permanent" so users don't reject by mistake.
