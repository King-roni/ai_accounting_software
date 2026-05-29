# Block 10 — Phase 05: Duplicate Detection

## References

- Block doc: `Docs/blocks/10_matching_engine.md` (Duplicate Detection section)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 05 — transaction dedup); `Docs/blocks/09_document_intake_and_extraction.md` (Phase 08 — cross-source document dedup)

## Phase Goal

Catch the duplicate-match patterns Block 10 owns: a single document attached to multiple unrelated transactions, and a single transaction matched to multiple unrelated documents (when not a confirmed split-payment group). Patterns that are owned by upstream blocks are referenced — not re-detected — to keep responsibility clean.

## Dependencies

- Phase 01 (`match_rejection_memory`, `split_payment_groups`)
- Phase 02 (scoring produces match records)
- Phase 04 (split-payment groups are legitimate multi-links; this phase distinguishes them from duplicates)
- Block 04 Phase 03 (`match_records`)

## Deliverables

- **Patterns this phase detects:**
  - **Pattern A — One document, multiple transactions, no split-payment group:**
    - Two or more `match_records` rows reference the same `document_id` but different `transaction_id`s.
    - **Split-payment-group exclusion (precise rule):** the pattern is suppressed when ALL of the constituent `match_records` rows share the same `split_payment_group_id` AND that group's status is in `{PROPOSED, CONFIRMED}`. A group in `REJECTED` status does NOT confer the exclusion (the rejected proposal is no longer a valid multi-link justification). Mixed-group rows (some in group X, some in group Y, some not in any group) raise the pattern.
    - Raise `matching.document_used_multiple_times` review issue with `issue_group = 'Possible Wrong Match'`, severity `HIGH`. Resolution actions: confirm-as-split-payment (creates a `split_payment_groups` row tying them together), reject one of the matches (populates `match_rejection_memory`), mark document as duplicate (links to a duplicate-document path).
  - **Pattern B — One transaction, multiple unrelated matches:**
    - A single transaction has multiple `MATCHED_*` `match_records` rows pointing at different documents.
    - None is part of a confirmed split-payment group.
    - Raise `matching.transaction_multi_match` review issue, `'Possible Wrong Match'` bucket, severity `HIGH`. Resolution: pick the right match (rejects others), mark as legitimate multi-match (e.g., a transaction that genuinely covers multiple invoices and should become a split-payment group), edit the matches.
- **Patterns owned by upstream blocks (referenced, not re-detected):**
  - **Duplicate uploaded invoice file** (same hash) → owned by **Block 09 Phase 08** (cross-source dedup).
  - **Same content via email and Drive** → owned by **Block 09 Phase 08**.
  - **Duplicate statement upload** (same statement file hash) → owned by **Block 07 Phase 01** (rejected at intake).
  - **Same bank row imported twice** → owned by **Block 07 Phase 05** (dedup engine, status `DUPLICATE_EXACT`).
- **Detection timing:**
  - Runs as part of the `MATCHING` phase exit gate (Phase 09 wires this).
  - Re-runs whenever a new match record is created mid-run (e.g., user manually creates one), so patterns stay current.
- **Idempotency:**
  - The same pattern detected twice in the same run produces only one review issue (deduplicated by `(pattern_kind, primary_id)` where primary id is the document or transaction at the centre of the pattern).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention):
  - `MATCHING_DUPLICATE_PATTERN_DETECTED` (with `pattern_kind`)
  - `MATCHING_DUPLICATE_PATTERN_RESOLVED`

## Definition of Done

- Two `match_records` rows pointing at the same document but different transactions, with no split-payment group, raise Pattern A.
- The same setup with a confirmed split-payment group does NOT raise Pattern A.
- A transaction with two unrelated matches raises Pattern B.
- The phase doesn't re-detect upstream-owned patterns (verified by inspecting that no Block 09/Block 07 dedup logic is duplicated here).
- Tests cover both Patterns A and B, including the split-payment-group exception.

## Sub-doc Hooks (Stage 4)

- **Pattern detection rules sub-doc** — exact SQL queries, performance.
- **Resolution actions sub-doc** — UI for "confirm as split-payment" vs "reject one match" vs "mark as duplicate", audit shape per resolution.
- **Cross-block ownership sub-doc** — the canonical map of which dedup pattern is owned by which block, kept in sync if patterns move between blocks.
