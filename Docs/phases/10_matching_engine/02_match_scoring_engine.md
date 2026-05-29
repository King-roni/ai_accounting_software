# Block 10 — Phase 02: Match Scoring Engine

## References

- Block doc: `Docs/blocks/10_matching_engine.md` (Match Score Components, Date Proximity Windows, Cross-Period, Cross-Currency)
- Decisions log: `Docs/decisions_log.md` (date windows ±3/±10/±30; 1–2 month cross-period look-back; bank-recorded FX rate with ECB fallback)

## Phase Goal

Build the deterministic scoring engine that produces a per-pair `(transaction, document) → score` breakdown and a match level (1–4). After this phase, Phase 03 can apply auto-confirm rules, Phase 04 can build on the per-pair scoring for combinatorial detection, and the engine has reproducible, audit-ready scoring across both OUT and IN matching.

## Dependencies

- Phase 01 (`match_rejection_memory` for suppression lookup)
- Block 04 Phase 02 (`transactions` with `fx_paired_legs` for cross-currency)
- Block 04 Phase 03 (`documents` and `match_records`)
- Block 08 Phase 03 (`recurring_vendor_memory` for the recurring-pattern signal)

## Deliverables

- **Signal computation** — `computeSignals(transaction, document) → SignalBreakdown`:
  - `amount_exact_match` — `1.0` if amounts match within rounding tolerance (default `±0.01` of the smaller currency unit), else `0.0`.
  - `currency_match` — `1.0` if currencies are identical, otherwise resolved via cross-currency below.
  - `supplier_exact_match` — `1.0` if normalized supplier names match exactly (using the same normalization as Block 08 Phase 03's vendor signature).
  - `supplier_fuzzy_match` — `0.0`–`1.0` based on Levenshtein/Jaro-Winkler distance between normalized names; sub-doc tunes the choice.
  - `date_proximity` — **stage 1 windowed**:
    - `1.0` if `|transaction_date - invoice_date| ≤ 3 days`.
    - `0.7` if within ±10 days.
    - `0.4` if within ±30 days.
    - `0.0` outside.
  - `invoice_number_match` — `1.0` if both transaction reference and document invoice-number match exactly; `0.0` if both are present but differ; `0.5` if only one side has the field.
  - `recurring_vendor_signal` — pulled from Block 08 Phase 03's vendor memory: `0.6` for medium tier (1 confirmation), `0.72` for 2 confirmations, `0.88` for high tier (3+ confirmations); `0.0` if no memory for the supplier.
  - `email_sender_domain_match` — `1.0` if the document came from email and the sender domain matches the supplier-name domain; `0.0` otherwise.
  - `drive_folder_relevance` — `0.0`–`1.0` based on whether the document was in the date-window subfolder per Block 09 Phase 06's 2-week convention.
  - `business_name_on_invoice` — `1.0` if the document's `client_name` matches the business; `0.0` otherwise.
  - `vat_number_relevance` — `1.0` when both supplier and business VAT numbers are present and consistent with the transaction's expected VAT treatment; `0.0` otherwise.
- **Weighted score** — `score = Σ(signal_value × weight)`; weights stored in a `match_signal_weights` config (sub-doc tunes the values; defaults set per architecture's signal hierarchy).
- **Match-level assignment:**
  - **Level 1 (`EXACT`)** — `amount_exact_match=1.0`, `currency_match=1.0` (post FX), `supplier_exact_match=1.0`, `date_proximity ≥ 0.7` (within ±10 days), AND `invoice_number_match` is `1.0` if both sides have one (else permitted absent).
    - **Date-proximity widening note:** Level 1 deliberately accepts `≥ 0.7` (±10 days) rather than the tightest `1.0` (±3 days) because in real bookkeeping the "exact" pattern frequently has multi-day gaps — invoices issued on Friday may settle Monday or Tuesday; vendor billing windows commonly post several days before settlement. The other Level 1 signals (`amount_exact`, `currency_match`, `supplier_exact`) are strong enough to carry a 10-day date window without false-positive risk. Tightening to ±3 days would push genuine exact matches into Level 2 and create unnecessary review-queue load.
  - **Level 2 (`STRONG_PROBABLE`)** — `amount_exact_match=1.0`, `currency_match=1.0`, `supplier_fuzzy_match ≥ 0.8`, `date_proximity ≥ 0.4` (within ±30 days), `recurring_vendor_signal` strong if no exact-supplier match.
  - **Level 3 (`WEAK_POSSIBLE`)** — some signals align; weighted score above the minimum threshold but below Level 2.
  - **Level 4 (`NO_MATCH`)** — score below threshold; no `match_records` row created.
- **Cross-period look-back** (Stage 1):
  - Candidate document set for a transaction includes documents from the **prior 1–2 months** that are in `EXTRACTED` state but not `MATCHED`.
  - The window is `[transaction_date - 60 days, transaction_date + 30 days]` by default; sub-doc tunes the bounds.
  - **Asymmetry rationale:** the look-back side (`-60 days`) is intentionally wider than the look-forward side (`+30 days`). The dominant pattern in expense matching is *invoice issued before payment* — typical net-30/net-60 terms mean payment commonly trails the invoice by 30–60 days, so a 60-day look-back catches the long tail. Invoices issued *after* the payment date occur in only two minor cases: (a) advance payments where an invoice is later issued (rare in expense flow; more common on the IN side, where Block 08's variant uses different windows tied to `due_date`), and (b) document upload lag where an invoice was issued before the payment but not uploaded until after — for which the match is anchored by `invoice_date`, not upload time, and the +30-day forward window adequately covers the realistic delta. Widening the forward side beyond +30 days adds candidate noise (invoices that postdate the payment by more than a month are almost never the right match) without catching meaningful additional true positives.
- **Cross-currency matching** (Stage 1):
  - When the transaction currency differs from the document currency, the engine checks `transactions.fx_paired_legs` for the bank-recorded conversion rate.
  - If no paired leg exists for that pair, the engine falls back to **ECB daily reference rate** for the transaction date (sourced via a sub-doc-tracked vendor or cached daily snapshot).
  - The amount comparison happens after both sides are converted to a comparison currency (sub-doc tracks whether comparison is in transaction currency, document currency, or a fixed reference).
- **Rejection suppression:**
  - Before scoring, the engine checks `match_rejection_memory` for `(business_id, transaction_id, document_id)`. If present, the pair is skipped entirely (no score computed; no `match_records` row created).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `MATCHING`):
  - `MATCHING_SCORE_COMPUTED` (with breakdown)
  - `MATCHING_LEVEL_ASSIGNED`
  - `MATCHING_REJECTION_SUPPRESSED` (when a memory hit blocks scoring)
  - `MATCHING_CROSS_CURRENCY_FX_RESOLVED` (when a non-direct-match currency conversion happens)
  - `MATCHING_CROSS_PERIOD_CANDIDATE_FOUND`

## Definition of Done

- Every (transaction, document) pair produces a deterministic `SignalBreakdown` and a level assignment.
- A pair in `match_rejection_memory` is correctly suppressed and never produces a `match_records` row.
- Cross-period look-back surfaces an invoice from the prior month for a transaction in the current month, when the dates fall within the window.
- Cross-currency matching uses `fx_paired_legs` rate first; falls back to ECB rate when no paired leg exists.
- Tests cover: each match level, each signal individually, cross-period happy path, cross-currency with paired leg, cross-currency with ECB fallback, rejection suppression.

## Sub-doc Hooks (Stage 4)

- **Signal weights sub-doc** — exact default weights per signal, calibration methodology, A/B testing approach.
- **Fuzzy-match algorithm sub-doc** — Levenshtein vs Jaro-Winkler choice, threshold values, internationalisation considerations.
- **Cross-period window tuning sub-doc** — exact day counts, per-business override (post-MVP).
- **ECB rate cache sub-doc** — daily snapshot source, cache TTL, what to do when the rate is unavailable.
- **Currency comparison reference sub-doc** — whether to compare in transaction currency, document currency, or always-EUR.
