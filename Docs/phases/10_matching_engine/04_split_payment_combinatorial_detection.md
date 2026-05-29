# Block 10 — Phase 04: Split-Payment Combinatorial Detection

## References

- Block doc: `Docs/blocks/10_matching_engine.md` (Multi-Match Relationships — split payments)
- Decisions log: `Docs/decisions_log.md` (proactive combinatorial detection — Stage 1 user upgrade from the recommended user-driven path)

## Phase Goal

Implement the proactive search for combinations of unmatched invoices whose totals sum to a transaction amount the engine couldn't match cleanly to a single invoice. After this phase, when a transaction's amount doesn't match any individual invoice but does match a sum of two or more, the engine surfaces the proposed split as a review issue for user confirmation. Stage 1 chose this proactive path over the recommended user-driven model — meaning the engine does the combinatorial work upfront, the user just reviews the proposal.

## Dependencies

- Phase 01 (`split_payment_groups` table; `match_records` `split_payment_flag` + `split_payment_group_id`)
- Phase 02 (scoring engine; combinatorial detection runs after no clean Level 1/2 single match is found)
- Block 04 Phase 03 (`documents` for the unmatched-invoice candidate set)

## Deliverables

- **Trigger condition:**
  - For each OUT-side transaction (or IN-side transaction in Phase 08's variant), if Phase 02 produced no Level 1 match and no Level 2 auto-confirm, and the transaction is `OUT_EXPENSE` (or `IN_INCOME` for the IN variant), the combinatorial detector runs.
  - Skipped for transaction types where split payments are implausible (`INTERNAL_TRANSFER`, `BANK_FEE`, `FX_EXCHANGE`).
- **Candidate set:**
  - Unmatched documents in `EXTRACTED` state for the same business, within the cross-period window (Phase 02's 1–2 month look-back).
  - Limit: max **20 candidate invoices** to combine. If more, narrow by amount-range (only invoices whose amount could plausibly be a constituent — typically 5–95% of the transaction amount) and date-proximity (closest first), then truncate at 20.
- **Combinatorial search:**
  - **Bounded** to combinations of size 2–5 (max 5 invoices in a single split). A typical split has 2 or 3 constituents; 5 is the realistic upper bound.
  - For each combination, sum the amounts; check whether the sum matches the transaction amount within rounding tolerance (default `±0.05` for cumulative rounding; sub-doc tunes).
  - Score each candidate combination:
    - Same supplier across all constituents → strong (`+0.3`).
    - Close dates among constituents (within 14 days of each other) → moderate (`+0.15`).
    - Each constituent has its own per-pair signal score from Phase 02's engine (averaged into the combination's score).
  - Top **3 candidate combinations** ranked by combined score are surfaced.
- **Review-issue creation:**
  - Each candidate combination creates a `split_payment_groups` row with `status = PROPOSED`.
  - A single review issue per transaction (not one per candidate) is raised: `issue_type = 'matching.split_payment_proposal'`, `issue_group = 'Possible Wrong Match'`, severity `MEDIUM`.
  - The issue's payload lists the top candidates with their constituent invoices and confidence.
- **User actions** (resolution actions on the issue):
  - **Confirm a candidate** — transitions the chosen `split_payment_groups` row to `CONFIRMED`; creates a `match_records` row for each constituent invoice with `split_payment_flag = true` and `split_payment_group_id = group.id`; rejects the other proposed groups (transitions them to `REJECTED`).
  - **Reject all** — all proposed groups transition to `REJECTED`; the transaction stays in `NO_MATCH` for now; user can manually upload an invoice or document a stub later.
  - **Edit a candidate** — adjusts which invoices are in the group before confirming; same effect as confirm but with the user's modifications.
- **Computational bounds:**
  - The combinatorial space for `n=20` candidates and combinations of size 2–5 is `C(20,2) + C(20,3) + C(20,4) + C(20,5) ≈ 21,699` combinations. Tractable but not free; sub-doc tracks performance budget.
  - When the candidate set exceeds 20 even after narrowing, the engine emits `MATCHING_SPLIT_PAYMENT_CANDIDATE_SET_TRUNCATED` and proceeds with the top-20 by amount-range relevance.
- **Idempotency:**
  - Running the detector twice for the same transaction produces the same proposed candidates (deterministic ordering).
  - Already-`CONFIRMED` or already-`REJECTED` groups are not re-proposed.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention):
  - `MATCHING_SPLIT_PAYMENT_DETECTOR_RAN`
  - `MATCHING_SPLIT_PAYMENT_CANDIDATE_PROPOSED`
  - `MATCHING_SPLIT_PAYMENT_CANDIDATE_SET_TRUNCATED`
  - `SPLIT_PAYMENT_GROUP_CONFIRMED` (transition; already declared in Phase 01 — this phase is the producer of CONFIRMED transitions)
  - `SPLIT_PAYMENT_GROUP_REJECTED` (transition; companion to the Phase 01 `SPLIT_PAYMENT_GROUP_STATUS_CHANGED` event — the named transition is preferred for queryability)

## Definition of Done

- A transaction whose amount equals the sum of two unmatched invoices from the same supplier produces a high-confidence split-payment proposal.
- A transaction whose amount equals a 3-invoice sum across mixed suppliers produces a lower-confidence proposal that may still surface but with lower ranking.
- The detector skips non-applicable transaction types.
- Candidate-set truncation kicks in correctly when more than 20 candidates exist; the right audit event is emitted.
- User confirms a proposal: the right `split_payment_groups` row transitions to `CONFIRMED`, three `match_records` rows are created with the flag + group id, the other proposed groups transition to `REJECTED`.
- The detector is idempotent on re-run.
- Performance budget is met for typical workloads (sub-doc tracks numbers).

## Sub-doc Hooks (Stage 4)

- **Combinatorial bounds sub-doc** — max combination size, max candidate set, narrowing rules, performance budget.
- **Candidate-scoring rubric sub-doc** — exact weights per signal, calibration.
- **Review-issue payload sub-doc** — exact JSON shape for the proposed-candidates list, UI rendering.
- **Performance sub-doc** — typical combination counts, optimisation strategies (e.g., dynamic programming for subset-sum) if needed at scale.
- **Idempotency sub-doc** — what counts as "already proposed"; how re-runs interact with already-confirmed/rejected groups.
