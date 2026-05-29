# Block 11 — Phase 09: LEDGER_PREPARATION Workflow Phase Registration

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md`
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 03 — tool registration; Phase 05 — gates; Phase 06 — phase execution)
- Block doc: `Docs/blocks/12_out_workflow.md` (consumer — `LEDGER_PREPARATION` is a phase of `OUT_MONTHLY`)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (consumer — `LEDGER_PREPARATION` is also a phase of `IN_MONTHLY`)

## Phase Goal

Wire Phases 04–08 into the workflow engine as the `LEDGER_PREPARATION` phase of both `OUT_MONTHLY` and `IN_MONTHLY`. After this phase, the engine knows which tools to call, in what order, what side-effects each carries, what AI tier (if any) each can reach, and what gates govern entry / exit.

## Dependencies

- Phase 04 (counterparty resolver)
- Phase 05 (VAT classifier)
- Phase 06 (reverse-charge / VIES)
- Phase 07 (type-aware preparer)
- Phase 08 (VAT amounts + evidence + accountant-review)
- Block 03 Phase 03 (tool registration)
- Block 03 Phase 04 (state machine)
- Block 03 Phase 05 (gates)
- Block 03 Phase 06 (phase execution)
- Block 06 Phase 04 (prompt registry — VAT-explanation prompt registered there)
- Block 06 Phase 10 (plain-language pipeline)

## Deliverables

- **Tool registrations** with `engine.registerTool`:
  - **`ledger.resolve_counterparty`** — runs Phase 04. Side-effect: `READ_ONLY` (returns the in-memory `CounterpartyResolution`; the persisted-row write happens later in `ledger.prepare_entries` once the full PRIMARY shape is assembled). AI tier: `NONE`. (The phase 04 review-issue emissions for `COUNTERPARTY_VAT_NUMBER_INVALID` etc. are persisted by `ledger.flag_for_review` at step 6 from the same in-memory resolution result, so the contract stays write-once.)
  - **`ledger.classify_vat`** — runs Phase 05's classifier. Side-effect: `READ_ONLY` (returns the in-memory `ClassificationResult`; persisted by `ledger.prepare_entries`). AI tier: `NONE` (rules-only — Principle 3).
  - **`ledger.compute_reverse_charge_vies`** — runs Phase 06. Side-effect: `READ_ONLY` (returns booleans + `vies_period`; persisted by `ledger.prepare_entries`). AI tier: `NONE`.
  - **`ledger.prepare_entries`** — runs Phase 07's dispatcher with the in-memory results from steps 1–3 already in hand. Side-effect: `WRITES_RUN_STATE` (creates / replaces `draft_ledger_entries` rows for the transaction; writes `counterparty_country`, `counterparty_vat_number`, `vat_treatment`, `reverse_charge_relevant`, `vies_relevant`, `vies_period`, `chart_mapping_version_id`, debit/credit accounts and amounts, `entry_kind`). AI tier: `NONE`.
  - **`ledger.compute_vat_and_evidence_flags`** — runs Phase 08's VAT amount calculator AND evidence-flag setter (renamed from `ledger.compute_vat_amounts` per the M6 contract clarification). Side-effect: `WRITES_RUN_STATE` (writes `input_vat_reclaimable_*`, `output_vat_due_*`, `vies_value_basis_eur`, `requires_invoice`, `requires_receipt`, `requires_contract`). AI tier: `NONE`.
  - **`ledger.flag_for_review`** — runs Phase 08's accountant-review-flag pass and the review-issue producer (issues from Phase 04 resolution problems, Phase 05 tag-mismatch, Phase 08 evidence-missing, etc.). Side-effect: `WRITES_RUN_STATE` (sets `requires_accountant_review`, `accountant_review_reason`; writes `review_issues` rows in the `Possible Tax/VAT Issue` and `Missing Documents` buckets). AI tier: `NONE`.
  - **`ledger.generate_vat_explanations`** — invokes Block 06 Phase 10's `generatePlainLanguage('VAT_TREATMENT_EXPLANATION', ...)` for every `PRIMARY` entry, populating `vat_treatment_explanation`. Side-effect: `WRITES_RUN_STATE` (writes the explanation field). AI tier: `EXTERNAL_LLM` (max tier the tool can reach — Tier 2 default with Tier 3 escalation per Block 06 Phase 10's complexity criteria).
- **Phase definition — `LEDGER_PREPARATION`** (registered as a phase of both `OUT_MONTHLY` and `IN_MONTHLY`; integer phase indices resolved at Block 12 / Block 13 decompositions; the durable contract is the phase name):
  - **Sequenced tools, per transaction:**
    1. `ledger.resolve_counterparty` — populates `counterparty_country`, `counterparty_vat_number` on a working in-memory shape (no DB write yet).
    2. `ledger.classify_vat` — picks `vat_treatment` from the resolved counterparty + business profile + tags. In-memory.
    3. `ledger.compute_reverse_charge_vies` — sets `reverse_charge_relevant`, `vies_relevant`, `vies_period` (booleans / period only — `vies_value_basis_eur` is populated later by `compute_vat_and_evidence_flags`). In-memory.
    4. `ledger.prepare_entries` — Phase 07's dispatcher reads the in-memory VAT decisions and emits the right shape: PRIMARY entries plus any derived entries (`VAT_RECLAIM` / `VAT_OUTPUT` for OUT-side reverse-charge, `FX_DELTA` for FX_EXCHANGE, etc.). This is the first DB write — every persisted `draft_ledger_entries` row already has `vat_treatment`, `reverse_charge_relevant`, `vies_relevant`, `counterparty_country`, `counterparty_vat_number` populated from the in-memory pipeline above. Side-effect: `WRITES_RUN_STATE`.
    5. `ledger.compute_vat_and_evidence_flags` — per persisted entry (PRIMARY and derived): computes `input_vat_reclaimable_*`, `output_vat_due_*`, `vies_value_basis_eur` (when `vies_relevant = true`), and the per-type evidence flags (`requires_invoice` / `requires_receipt` / `requires_contract`). Side-effect: `WRITES_RUN_STATE`.
    6. `ledger.flag_for_review` — per PRIMARY entry: applies the accountant-review-flag rules from Phase 08 and writes review issues for any flag that fires (including `MISSING_REQUIRED_EVIDENCE` based on the evidence flags from step 5).
  - After the per-transaction loop completes for the period, run `ledger.generate_vat_explanations` once over the batch of new / changed PRIMARY entries (so the AI calls can benefit from Block 06's within-run cache and cost-ceiling batching).
  - **In-memory pipeline rationale:** steps 1–3 do not write to the database. The dispatcher (step 4) is the single writer for entry creation, which avoids two-pass writes and keeps Phase 07's idempotency contract (delete-and-replace as a single transaction) intact. Steps 5–6 enrich the persisted rows in-place.
  - **Entry gate:** MATCHING (Block 10) and INCOME_MATCHING phases complete; every transaction in scope has a `match_status` set; every `MATCHED_*` row has a `match_record_id`; classification has assigned a transaction type other than `UNKNOWN` for every transaction the engine intends to ledger (entries with `UNKNOWN` type are held by Phase 07; the gate checks that the batch reached MATCHING-end with no engine-internal errors).
  - **Exit gate:** every in-scope transaction either has at least one `draft_ledger_entries` row with status `DRAFT`, OR is held with an audit-logged reason (held entries do NOT block phase exit — they surface as review issues for the user). Every produced entry has all 11 compliance fields populated subject to the canonical nullability rules:
    - `accountant_review_reason` may be null only when `requires_accountant_review = false`.
    - `counterparty_country` and `counterparty_vat_number` may be null when `vat_treatment ∈ {OUTSIDE_SCOPE, UNKNOWN}` (covers Phase 04's `UNRESOLVED` branch and Phase 05's pre-check unresolved-country handling, both of which produce held-flag entries with `requires_accountant_review = true`).
    - `vat_treatment_explanation`, `manual_override_*`, `entry_currency_original`, `entry_amount_original`, `vies_period`, `vies_value_basis_eur` are nullable per Phase 01's schema annotations and are not required to be populated by the exit gate.
    - All other compliance fields must be non-null.
  - **Pre-exit chart-version-uniformity recompute** (enforces C1's invariant): before evaluating the exit gate, the phase scans every `draft_ledger_entries` row in the period; if any row pins a `chart_mapping_version_id` that differs from the currently active version (because the user customized the chart between draft generation and exit), the phase replays Phase 07's dispatcher for those rows so the entire period uniformly pins the active version. Block 15 never receives a multi-version period.
- **Side-effect contract — pattern alignment:**
  - Steps 1–3 (`resolve_counterparty`, `classify_vat`, `compute_reverse_charge_vies`) follow Block 08 Phase 09's READ_ONLY-proposer pattern: each returns an in-memory result; the actual DB write happens at the dispatcher (`prepare_entries`).
  - Steps 4–7 (`prepare_entries`, `compute_vat_and_evidence_flags`, `flag_for_review`, `generate_vat_explanations`) declare `WRITES_RUN_STATE`. Step 4 is the single creator of `draft_ledger_entries` rows; steps 5–7 enrich existing rows.
  - **Idempotency:** the dispatcher's delete-and-replace transaction (Phase 07) ensures recomputes are deterministic; downstream enrichers are idempotent because they re-derive their fields from the persisted row's already-pinned VAT decisions.
- **Failure paths:**
  - **AI failure on `ledger.generate_vat_explanations`** → Phase 05's failure-handling rule applies: deterministic structured-fallback string written to `vat_treatment_explanation`, full structured signals retained, `LEDGER_VAT_EXPLANATION_FALLBACK_APPLIED` audit event emitted, LOW review issue raised. The run continues — the explanation is informational only; classification has already been decided by rules.
  - **Counterparty unresolved** (Phase 04) → ledger entry produced with `vat_treatment = UNKNOWN` and `requires_accountant_review = true`; the run continues; the review queue surfaces the issue.
  - **Mapping rule resolves to a disabled account** (Phase 03 / Phase 07) → entry produced with `requires_accountant_review = true`, reason `"Mapped account is disabled — please pick a successor."`; run continues.
  - **`UNKNOWN`-type transaction** (Phase 07) → no entries produced; held audit event fires; review issue surfaces; run continues.
  - **Unrecoverable tool failure** (e.g., DB write failure) → bounded retry per Block 03 Phase 08; persistent failure holds the phase via `phase_state.status = HOLDING` per Block 03's two-level state semantics.
- **Cross-block durable contracts (declared here for Block 12 / Block 13 / Block 16 alignment):**
  - **Phase name** `LEDGER_PREPARATION` is the durable identifier. Integer phase indices resolve at Block 12 / Block 13 decompositions.
  - **Block 16 VIES export** consumes `vies_relevant = true` rows from `draft_ledger_entries` ordered by `counterparty_vat_number` (per Phase 06's contract).
  - **Block 15 finalization** transitions `draft_ledger_entries.status` from `READY_FOR_FINALIZATION` to `LOCKED`; this phase produces only `DRAFT`. The transition `DRAFT → READY_FOR_FINALIZATION` is owned by the `AWAITING_APPROVAL` gate of the parent workflow (Block 12 / Block 13).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `LEDGER`):
  - `LEDGER_PHASE_STARTED`
  - `LEDGER_PHASE_COMPLETED` (with per-treatment counts and review-flag count)
  - `LEDGER_PHASE_HOLDING` — fired only when a tool failure transitions the phase to `phase_state.status = HOLDING` per Block 03 Phase 04's two-level state semantics; held-pending-classification entries (Phase 07's `LEDGER_HELD_PENDING_CLASSIFICATION`) do NOT fire this event because they don't hold the phase itself.
  - **Per-tool emissions:**
    - `ledger.resolve_counterparty` → `LEDGER_COUNTERPARTY_RESOLVED`, `LEDGER_COUNTERPARTY_UNRESOLVED`, `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED`
    - `ledger.classify_vat` → `LEDGER_VAT_TREATMENT_DECIDED`, `LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE`, `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED`, `LEDGER_VAT_TREATMENT_TAG_MISMATCH_DETECTED`
    - `ledger.compute_reverse_charge_vies` → `LEDGER_REVERSE_CHARGE_FLAGGED`, `LEDGER_VIES_RELEVANCE_DECIDED`, `LEDGER_VIES_VAT_NUMBER_MISSING_RAISED`
    - `ledger.prepare_entries` → `LEDGER_DRAFT_ENTRY_CREATED`, `LEDGER_DRAFT_ENTRY_RECOMPUTED`, `LEDGER_HELD_PENDING_CLASSIFICATION`, `LEDGER_MULTI_LINE_INVOICE_CONSOLIDATED`, `LEDGER_MULTI_LINE_INVOICE_SPLIT_BY_CATEGORY`, `LEDGER_MAPPING_RULE_FALLBACK_USED`
    - `ledger.compute_vat_and_evidence_flags` → `LEDGER_VAT_AMOUNTS_COMPUTED`, `LEDGER_EVIDENCE_FLAGS_SET`
    - `ledger.flag_for_review` → `LEDGER_ACCOUNTANT_REVIEW_FLAGGED`, `LEDGER_MISSING_REQUIRED_EVIDENCE_RAISED`, `LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_APPLIED`, `LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_CLEARED`
    - `ledger.generate_vat_explanations` → `LEDGER_VAT_EXPLANATION_GENERATED` (with `tier_used`), `LEDGER_VAT_EXPLANATION_FALLBACK_APPLIED` (with failure category)

## Definition of Done

- All seven tools register at engine startup with the correct schemas, side-effects, and AI tiers.
- A test `OUT_MONTHLY` run reaches LEDGER_PREPARATION; every classified transaction in scope produces draft entries (or is held with an audit-logged reason); the phase exits cleanly.
- A test `IN_MONTHLY` run reaches LEDGER_PREPARATION; revenue entries carry the right VIES flag where applicable.
- AI failure on the explanation tool degrades gracefully (placeholder text, LOW issue, run continues).
- Replaying either phase produces identical draft entries (within the same chart-mapping version).
- A held `UNKNOWN`-type transaction does not block phase exit but does produce a HIGH review issue.
- The exit-gate check correctly enforces all-fields-populated.

## Sub-doc Hooks (Stage 4)

- **Tool I/O schema sub-doc** — JSON schemas per tool.
- **Phase definition sub-doc** — canonical definition referenced by Block 12 and Block 13.
- **Entry/exit gate functions sub-doc** — SQL-backed gates.
- **Failure-mode mapping sub-doc** — full table per tool → review-issue templates and severity.
- **Per-transaction tool sequencing sub-doc** — performance and cache characteristics for typical batch sizes.
