# Block 10 — Phase 03: Strong Probable Auto-Confirm Rule

## References

- Block doc: `Docs/blocks/10_matching_engine.md` (Level 2 — Strong Probable Match)
- Decisions log: `Docs/decisions_log.md` (Strong Probable auto-confirms only with strong recurring pattern)

## Phase Goal

Apply the level-to-status mapping and decide which matches auto-confirm vs which route to the review queue. The Stage 1 rule for Level 2 is the discriminator: auto-confirm **only** when the recurring-pattern signal is strong; otherwise route to `MATCHED_NEEDS_CONFIRMATION`. Level 1 always auto-confirms; Levels 3 and 4 always route to review or no-match.

## Dependencies

- Phase 02 (match scoring produces level + signal breakdown)
- Block 08 Phase 03 (vendor memory tiers — the `recurring_vendor_signal` source)
- Block 04 Phase 04 (`review_issues` for `MATCHED_NEEDS_CONFIRMATION` and `POSSIBLE_MATCH` rows)
- **Block 14 is a downstream consumer, not a dependency.** This phase writes `review_issues` rows directly via Block 04's table contract. Block 14 (Review Queue) reads, renders, and routes resolution actions for those rows — it does not need to exist for this phase to be complete. The cross-block contract is the `review_issues` schema and the `issue_group` / severity fields, both owned by Block 04. When Block 14's phase docs land, they must conform to the issue-group taxonomy this phase emits.

## Deliverables

- **Level → Status mapping:**
  - **Level 1 (`EXACT`)** → `match_status = MATCHED_AUTO_HIGH_CONFIDENCE`. Match record persisted with no review issue (auto-confirmed).
  - **Level 2 (`STRONG_PROBABLE`)** — Stage 1 rule applied:
    - **Auto-confirm path:** if `recurring_vendor_signal ≥ 0.88` (high tier from Block 08 Phase 03) AND `amount_exact_match = 1.0`, status `MATCHED_AUTO_HIGH_CONFIDENCE`.
    - **Review path:** otherwise, status `MATCHED_NEEDS_CONFIRMATION`. A review issue is created in Block 14 with `issue_group = 'Needs Confirmation'`, severity `MEDIUM`.
    - **Cutoff source-of-truth:** the `0.88` threshold is the high-tier value emitted by Block 08 Phase 03's vendor-memory tiering rules; it is NOT a free-floating Block 10 constant. If Block 08 Phase 03 changes its tier values (e.g., re-calibrates so high tier emits `0.90`), Block 10 must reference the tier symbolically rather than the numeric. Stage 1: keep the numeric `0.88` to preserve fixture stability; Stage 4 sub-doc tracks moving to a symbolic tier reference (`vendor_memory.tier == HIGH`) once Block 08's contract pins one.
  - **Level 3 (`WEAK_POSSIBLE`)** → `match_status = POSSIBLE_MATCH`. Always to review; severity `MEDIUM` for OUT_EXPENSE (where evidence is required), `LOW` for less-stringent types.
  - **Level 4 (`NO_MATCH`)** → no `match_records` row created. The transaction's `match_status` column (Block 04 Phase 02) is set to `NO_MATCH` directly. For OUT_EXPENSE, this raises a `'Missing Documents'` review issue with severity `HIGH` (per Block 14's bucket mapping).
- **Auto-confirm side-effects:**
  - On `MATCHED_AUTO_HIGH_CONFIDENCE`: Block 08 Phase 03's vendor memory `confirmations_count` is incremented for the matched supplier.
  - **Counter-source contract (avoids double-count):** the increment fires from exactly **one** path per logical event:
    - **Engine-driven auto-confirm of a match** (this phase, `MATCHED_AUTO_HIGH_CONFIDENCE`) → calls the helper with `source = 'matching.auto_confirm'`.
    - **User-confirmed match** (this phase, on Confirm action against `MATCHED_NEEDS_CONFIRMATION` / `POSSIBLE_MATCH`) → calls the helper with `source = 'matching.user_confirm'`.
    - **Block 08's classification auto-confirm** (Phase 07) → calls the helper with `source = 'classification.auto_confirm'`.
    - The helper's idempotency key is `(business_id, vendor_signature, source, source_record_id)` — the source distinguishes the path so a single match-record auto-confirm cannot also be counted via classification, and a re-run of the same workflow cannot double-count.
  - This is the same helper Block 08 Phase 07's auto-confirm uses; both call in with their distinct `source` value.
- **User confirmation flow** (resolution actions on `MATCHED_NEEDS_CONFIRMATION` / `POSSIBLE_MATCH` review issues):
  - **Confirm** — transitions to `MATCHED_CONFIRMED`; vendor memory incremented.
  - **Reject** — transitions to `REJECTED_MATCH`; **adds a row to `match_rejection_memory`** (Phase 06 enforces the forever-remembered rule); the `match_records` row remains with status `REJECTED_MATCH` for audit traceability.
  - **Edit and confirm** — user picks a different document or supplies additional context (e.g., marks split-payment); the original match record is rejected, a new match record is created with the user's input.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `MATCHING`):
  - `MATCHING_AUTO_CONFIRMED`
  - `MATCHING_NEEDS_CONFIRMATION_RAISED`
  - `MATCHING_POSSIBLE_RAISED`
  - `MATCHING_USER_CONFIRMED`
  - `MATCHING_USER_REJECTED`
  - `MATCHING_USER_EDITED_AND_CONFIRMED`

## Definition of Done

- A Level 1 match auto-confirms and increments vendor memory.
- A Level 2 match with `recurring_vendor_signal = 0.88` (high tier) AND amount-exact auto-confirms.
- A Level 2 match with `recurring_vendor_signal = 0.72` (medium tier) does NOT auto-confirm; it raises a `MATCHED_NEEDS_CONFIRMATION` issue.
- A Level 3 match always raises a `POSSIBLE_MATCH` issue.
- A Level 4 (no candidate above threshold) for an OUT_EXPENSE raises a HIGH-severity `Missing Documents` issue.
- User reject correctly populates `match_rejection_memory` so the same pair is suppressed in subsequent runs (verified via test).
- Tests cover: each level, both Level 2 paths, edit-and-confirm, reject-and-suppress.

## Sub-doc Hooks (Stage 4)

- **Strong-Probable threshold sub-doc** — exact `recurring_vendor_signal` cutoff, calibration approach, per-business override (post-MVP).
- **Vendor-memory increment helper sub-doc** — shared with Block 08 Phase 07; idempotency rules.
- **Review-issue card layout sub-doc** — per status type, recommended-action set, plain-language template references (Phase 07).
- **Edit-and-confirm flow sub-doc** — UX for picking a different candidate, audit trail, what happens to the original match record.
