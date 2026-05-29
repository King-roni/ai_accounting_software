# Block 06 — Phase 11: End-Scan Engine

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (The End-Scan Engine section)
- Block doc: `Docs/blocks/12_out_workflow.md` (consumer — runs `AI_END_SCAN` phase)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (consumer — runs `AI_END_SCAN` phase)
- Block doc: `Docs/blocks/14_review_queue.md` (consumer of the issues this engine produces)

## Phase Goal

Implement the End-Scan engine: the registered workflow phase that runs after matching and ledger preparation in OUT and IN, performs the anomaly checks, and produces structured `review_issues` rows with plain-language content via Phase 10. The engine **never resolves issues, never advances workflow state, never writes to the ledger**. It only flags.

## Dependencies

- Phase 02 (gateway for AI calls)
- Phase 09 (cache for repeated checks within the same run)
- Phase 10 (plain-language pipeline for issue title/description)
- Block 03 Phase 03 (registers the engine as a tool/phase)
- Block 04 Phase 04 (`review_issues` table — the engine's only write target)
- Block 14 — consumer of the issues; **Block 14's resolution-driven re-scan trigger** sends the affected-only re-scan signal that this engine honours (cross-block dep finalised when Block 14 is decomposed).

## Deliverables

- **Phase registration** — End-Scan registers itself as the `AI_END_SCAN` phase in both `OUT_MONTHLY` and `IN_MONTHLY` via Block 03 Phase 03's tool registration framework. The `AI_END_SCAN` name is the durable contract; the integer phase index in Block 12 / Block 13 is finalised when those blocks are decomposed. Side-effect declaration: `WRITES_RUN_STATE` (it inserts `review_issues` rows; nothing else).
- **Check categories** — each category is one or more registered checks; categories together cover the anomaly catalogue from the Block 06 architecture and the core concept doc:
  - **Missing or weak evidence:** OUT_EXPENSE without invoice, missing receipt, missing contract for PAYROLL_OR_TEAM_PAYMENT, weak match score.
  - **Match quality:** weak score, duplicate-on-multiple-transactions, amount/currency mismatch, supplier mismatch.
  - **VAT and tax red flags:** unclear `vat_treatment`, missing VAT number where required, possible VIES issue, possible reverse-charge issue, VAT rate inconsistent with treatment.
  - **Suspect transaction shapes:** very large outliers, recurring payment without supporting agreement, refund not connected to original, internal transfer incorrectly typed as expense, bank fee incorrectly requiring an invoice.
  - **Lifecycle (IN-side):** invoice created but unpaid past due date, payment received without invoice, invoice paid wrong amount, payment in wrong currency, duplicate payment, late payment.
- **Issue construction** — each finding produces a structured `review_issues` row carrying:
  - `workflow_run_id`, `transaction_id` / `document_id` / `match_record_id` / `draft_ledger_entry_id` (whichever apply).
  - `issue_type` (internal taxonomy — namespaced by check, e.g. `out_evidence.missing_invoice`).
  - `issue_group` (one of the six fixed buckets per Block 14).
  - `severity` (`LOW`, `MEDIUM`, `HIGH`, `BLOCKING`).
  - `plain_language_title` and `plain_language_description` generated via Phase 10.
  - `recommended_action`.
  - `status = OPEN`.
- **Determinism-first checks:**
  - Most checks are **deterministic SQL queries or rule evaluations** — no AI required to detect "OUT_EXPENSE has no matching document".
  - AI is invoked only for:
    - Plain-language rendering of every finding (Phase 10).
    - The "explanation" pipeline when a finding's structured form is hard to express directly (e.g., a complex VAT case).
- **What the engine does NOT do** (block-architecture rules):
  - Never resolves issues — that's Block 14.
  - Never advances workflow state — Block 03 owns advancement.
  - Never writes to ledger entries — Block 11.
  - Never modifies match records — Block 10.
- **Idempotency:**
  - On re-entry (e.g., after a Phase 14 issue resolution that triggers re-scan affected issues only — Block 14 Phase 11), the engine recomputes only the affected checks rather than the whole catalogue.
  - Re-scan replaces existing OPEN issues for the affected entities; it does not duplicate them.
- **Audit events:** `END_SCAN_STARTED`, `END_SCAN_CHECK_RAN` (one per check), `END_SCAN_ISSUE_RAISED` (one per finding), `END_SCAN_COMPLETED`, `END_SCAN_RESCAN_AFFECTED` (when invoked for affected-only re-evaluation).

## Definition of Done

- The engine is registered as the `AI_END_SCAN` phase in both monthly workflow types.
- Running the engine on a representative test fixture produces the expected set of `review_issues` rows, each grouped into the right of the six buckets.
- Plain-language fields are populated via Phase 10.
- Re-scan after a resolution updates only the affected issues (not the whole catalogue).
- Verified: the engine does not write to `draft_ledger_entries`, `match_records`, `transactions`, or any other table outside `review_issues`.
- Verified: the engine never calls `transitionRun` — workflow advancement is Block 03's responsibility.
- Tests cover at least one happy path and one finding per check category.

## Sub-doc Hooks (Stage 4)

- **Check catalogue sub-doc** — exhaustive list of registered checks, their detection rules (mostly SQL), severity defaults, recommended-action templates.
- **Issue type → group mapping sub-doc** — namespaced internal `issue_type` strings and which of the six buckets each maps to (the canonical mapping table, jointly maintained with Block 14).
- **Affected-only re-scan sub-doc** — how Block 14 Phase 11 signals "these resolutions; please re-evaluate" and which checks are re-run for which entities.
- **Determinism-first vs AI-driven check sub-doc** — for each check, whether deterministic SQL is sufficient or whether AI assists; the rationale per check.
- **Severity calibration sub-doc** — how severity defaults are tuned in early production based on operator feedback.
