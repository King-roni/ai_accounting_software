# Block 10 — Phase 09: MATCHING + INCOME_MATCHING Workflow Phase Registration

## References

- Block doc: `Docs/blocks/10_matching_engine.md`
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 03 tool registration; Phase 05 gates; Phase 06 execution)
- Block doc: `Docs/blocks/12_out_workflow.md` (consumer — `MATCHING` is a phase of `OUT_MONTHLY`)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (consumer — `INCOME_MATCHING` is a phase of `IN_MONTHLY`)

## Phase Goal

Wire the matching engine (Phases 02–07) and the IN-side variant (Phase 08) into the workflow engine as the `MATCHING` phase of `OUT_MONTHLY` and the `INCOME_MATCHING` phase of `IN_MONTHLY`. After this phase, the engine knows how to invoke the matching tools, what gates govern advancement, and how the two variants share core scoring while wiring different candidate sources.

## Dependencies

- Phase 02 (scoring engine)
- Phase 03 (auto-confirm rule)
- Phase 04 (split-payment combinatorial)
- Phase 05 (duplicate detection)
- Phase 06 (rejection memory)
- Phase 07 (match reason generation)
- Phase 08 (IN-side income matching variant)
- Block 03 Phase 03 (tool registration)
- Block 03 Phase 04 (state machine)
- Block 03 Phase 05 (gates)
- Block 03 Phase 06 (phase execution)

## Deliverables

- **Tool registrations** with `engine.registerTool`:
  - `matching.score_pair` — scores a single `(transaction, document)` pair via Phase 02 + checks Phase 06 rejection memory + applies Phase 03 auto-confirm rule. Side-effect: `WRITES_RUN_STATE` (creates `match_records` row when applicable). AI tier: `NONE`.
  - `matching.detect_split_payments` — runs Phase 04's combinatorial detection over remaining unmatched transactions. Side-effect: `WRITES_RUN_STATE` (creates `split_payment_groups` rows in `PROPOSED` state and review issues). AI tier: `NONE`.
  - `matching.detect_duplicates` — runs Phase 05's pattern detection. Side-effect: `WRITES_RUN_STATE` (raises review issues for Patterns A and B). AI tier: `NONE`.
  - `matching.generate_reasons` — runs Phase 07's plain-language reason generation for new `match_records` rows. Side-effect: `WRITES_RUN_STATE` (writes `match_reason_plain_language` and updates `match_signals`). AI tier: `EXTERNAL_LLM` (max tier the tool can reach — Tier 2 default with Tier 3 escalation per Phase 07).
  - `matching.income_match_outcome` — runs Phase 08's IN-side outcome computation; calls Block 13's lifecycle-transition functions for invoices. Side-effect: `WRITES_RUN_STATE` (writes `match_records` rows AND triggers `Invoice` lifecycle transitions). AI tier: `NONE` (deterministic; Phase 07's reason generation handles AI separately).
- **Side-effect contract — deviation from Block 08's READ_ONLY-proposer + single-writer pattern (rationale):**
  - Block 08's classification used pure read-only "Layer N proposers" producing in-memory `LayerNResult` objects, with a single `assign_status` writer at the end. That pattern fits classification because all layers contribute to the same row (`transactions.classification_status`) and the right shape is "compute-then-commit".
  - Block 10 matching is structurally different: each `(transaction, document)` pair is independently scored, and the auto-confirm decision is per-pair (not aggregated). A "proposer" wrapping `score_pair` would defer writes that have no other consumer — every score must either become a `match_records` row or be suppressed (rejection-memory hit) or contribute nothing (Level 4). There is no aggregate write step downstream of scoring that would benefit from delayed commits.
  - Each tool registered above is therefore inherently a writer. The contract durability comes from the side-effect being declared up front (`WRITES_RUN_STATE`) so the engine's audit and replay machinery (Block 03) can govern the writes.
  - For replay/idempotency: `score_pair` is idempotent because Phase 06's unique constraint on `(transaction_id, document_id)` plus the rejection-memory suppression check ensure re-running produces the same result; `detect_split_payments` and `detect_duplicates` are idempotent per Phase 04 / Phase 05's deterministic-ordering rules.
- **Phase definitions:**
  - **`MATCHING`** (registers as a phase of `OUT_MONTHLY`; integer phase index resolved at Block 12 decomposition):
    - Sequenced tools: for each unmatched OUT transaction × each candidate document (cross-product within the cross-period window), invoke `matching.score_pair`. Then `matching.detect_split_payments` for transactions still without clean matches. Then `matching.detect_duplicates` at phase exit. Then `matching.generate_reasons` for all new match records.
    - Entry gate: EVIDENCE_DISCOVERY phases (Block 09's) complete; OUT_EXPENSE transactions and their candidate documents are present.
    - Exit gate: every OUT_EXPENSE transaction has a `match_status` set on its `transactions` row (one of the 6 statuses); duplicate-detection pass complete.
  - **`INCOME_MATCHING`** (registers as a phase of `IN_MONTHLY`; integer phase index resolved at Block 13 decomposition):
    - Sequenced tools: for each IN-side transaction × each candidate `Invoice` record, invoke `matching.income_match_outcome` (which internally uses `matching.score_pair`'s scoring). Then `matching.detect_split_payments` for `MULTIPLE_INVOICES_ONE_PAYMENT` cases. Then `matching.detect_duplicates` at phase exit (covers the IN-side equivalents of Patterns A and B — one invoice referenced by multiple unrelated incoming-payment match records, or one incoming payment matched to multiple unrelated invoices outside a confirmed group). Then `matching.generate_reasons`.
    - Entry gate: CLASSIFICATION complete; IN-side transactions and active invoices are present.
    - Exit gate: every IN-side transaction has a `match_status` set; every affected invoice has its lifecycle status correctly updated; duplicate-detection pass complete.
- **Cross-block dependencies for invoice lifecycle:**
  - `INCOME_MATCHING` calls into Block 13's invoice-lifecycle functions (`invoice.markPaid`, `invoice.markPartiallyPaid`, `invoice.markOverpaid`). The contract is one-way: matching tells Block 13 to transition; Block 13 owns the lifecycle state machine.
- **Failure paths:**
  - AI failure on `matching.generate_reasons` → Phase 07's failure-handling rule applies: deterministic structured-fallback string written to `match_reason_plain_language`, full `match_signals` retained, `MATCHING_REASON_FALLBACK_APPLIED` audit event emitted, LOW-severity review issue raised. The run continues.
  - Other tool failures → bounded retry per Block 03 Phase 08; persistent failure holds the phase.
- **Audit events:** `MATCHING_PHASE_STARTED`, `MATCHING_PHASE_COMPLETED` (with per-status counts), `MATCHING_PHASE_HOLDING`, `INCOME_MATCHING_PHASE_STARTED`, `INCOME_MATCHING_PHASE_COMPLETED`, `INCOME_MATCHING_PHASE_HOLDING`.

## Definition of Done

- All five tools register at engine startup with the right schemas, side-effects, and AI tiers.
- A test `OUT_MONTHLY` run reaches MATCHING; every OUT_EXPENSE transaction lands with a `match_status`; the phase exits cleanly.
- A test `IN_MONTHLY` run reaches INCOME_MATCHING; invoices transition to the right lifecycle states; outcomes are correctly assigned.
- Phase index references in Block 12 / Block 13 are deferred to those blocks' decompositions (durable contract is the phase name).
- An AI failure on reason generation degrades gracefully (placeholder text, LOW issue, run continues).
- Replaying either phase produces identical results.

## Sub-doc Hooks (Stage 4)

- **Tool I/O schema sub-doc** — JSON schemas per tool.
- **Phase definition sub-doc** — canonical definitions referenced by Block 12 and Block 13.
- **Entry/exit gate functions sub-doc** — SQL-backed gates.
- **Failure-mode mapping sub-doc** — full table per tool → review-issue templates.
- **Cross-product candidate set sub-doc** — performance characteristics for `transactions × documents` and `transactions × invoices` at typical scale.
