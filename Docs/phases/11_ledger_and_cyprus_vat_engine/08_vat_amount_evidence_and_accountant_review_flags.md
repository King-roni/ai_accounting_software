# Block 11 — Phase 08: Input VAT, Output VAT, Evidence & Accountant-Review Flags

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Compliance Fields per Ledger Entry — `input_vat_reclaimable`, `output_vat_due`, `requires_contract` / `requires_invoice` / `requires_receipt`, `requires_accountant_review`; Accountant Review Flag section)
- Block doc: `Docs/blocks/14_review_queue.md` (the `Possible Tax/VAT Issue` bucket — consumer of the flag)
- Decisions log: `Docs/decisions_log.md` (Block 15 finalization does NOT require accountant signoff in MVP — flag is advisory)

## Phase Goal

Compute the VAT amounts (`input_vat_reclaimable_amount`, `output_vat_due_amount`), set the per-entry evidence flags, and apply the accountant-review flag for cases the rules cannot decide. After this phase, every draft ledger entry is fully populated with all 11 compliance fields and any review issues are sitting in Block 14's `Possible Tax/VAT Issue` bucket.

## Dependencies

- Phase 01 (`input_vat_reclaimable_*`, `output_vat_due_*`, `requires_*`, `requires_accountant_review`, `accountant_review_reason` columns)
- Phase 04 (counterparty resolved)
- Phase 05 (`vat_treatment` decided)
- Phase 06 (`reverse_charge_relevant`, `vies_relevant` set)
- Phase 07 (draft entries created with debit/credit and amounts; this phase enriches them)
- Block 04 Phase 04 (`review_issues`)
- Block 09 Phase 04 (extracted invoice fields — VAT amount on the source document)
- Block 14 (consumer of the review issues; phase docs not yet written — `Possible Tax/VAT Issue` bucket from Block 14 architecture)

## Deliverables

- **VAT amount calculator** — `computeVatAndEvidenceFlags(draft_entry, vat_rate_table_version) → { input_vat_reclaimable_amount, output_vat_due_amount, vies_value_basis_eur, requires_invoice, requires_receipt, requires_contract }`:
  - Renamed from `computeVatAmounts` to reflect Phase 09's `ledger.compute_vat_and_evidence_flags` tool name; this single function covers both the VAT amount derivation AND the per-type evidence flags (the prior split between two paragraphs in this phase is preserved below; the function emits both as a single result).
  - **`vies_value_basis_eur` population:** when `vies_relevant = true` (set by Phase 06), this calculator computes the entry's bookkeeping-currency-EUR amount. For a Cyprus business with EUR bookkeeping currency (Stage 1 default), this is the entry's primary amount. For non-EUR bookkeeping currencies (out of MVP scope), the sub-doc handles the conversion. The FX rate source for the EUR conversion (when the transaction was settled in a non-EUR currency) follows Block 10 Phase 02's paired-leg / ECB-fallback chain, with the chosen rate version stamped on the entry per Phase 07's cross-currency rule.
  - **Source preference (in order):**
    1. **Document-extracted VAT amount** — when the matched document carries an explicit VAT line (Block 09 Phase 04), use it directly. This is the highest-fidelity source — handles odd rounding, mixed-rate invoices, etc.
    2. **Rate-derived calculation** — when the document doesn't carry a VAT amount, derive it from the entry's gross amount × the Cyprus VAT rate that matches the entry's category (standard, reduced, zero — sub-doc owns the table). The `vat_rate_table_version` pinned on the draft entry (Phase 01) drives which rate version applies.
    3. **Zero** — when `vat_treatment ∈ {EXEMPT, NO_VAT, OUTSIDE_SCOPE}` or the entry is `OUTSIDE_SCOPE` for any other reason, both amounts are `0`.
  - **Treatment → flag/amount table** (Stage 1 canonical):

    | `vat_treatment` | `input_vat_reclaimable_flag` | `input_vat_reclaimable_amount` | `output_vat_due_flag` | `output_vat_due_amount` |
    | --- | --- | --- | --- | --- |
    | `DOMESTIC_CYPRUS_VAT` (OUT-side) | `true` (when business is VAT-registered AND expense category is reclaimable) | document or rate-derived | `false` | `0` |
    | `DOMESTIC_CYPRUS_VAT` (IN-side) | `false` | `0` | `true` | document or rate-derived |
    | `EU_REVERSE_CHARGE` (OUT-side) | `true` | document or rate-derived (matches `VAT_RECLAIM` derived entry from Phase 07) | `true` | same amount (matches `VAT_OUTPUT` derived entry; net VAT = 0) |
    | `EU_REVERSE_CHARGE` (IN-side, supplier-side) | `false` | `0` | `false` | `0` (customer self-accounts) |
    | `IMPORT_OR_ACQUISITION` | `true` (when reclaimable per category) | rate-derived | `true` | rate-derived (acquisitions reverse-charge) |
    | `NON_EU_SERVICE` (OUT-side) | depends on category — sub-doc owns the rule | rate-derived if reclaimable | `false` | `0` |
    | `NON_EU_SERVICE` (IN-side, export of services) | `false` | `0` | `false` | `0` |
    | `EXEMPT` | `false` | `0` | `false` | `0` |
    | `NO_VAT` | `false` | `0` | `false` | `0` |
    | `OUTSIDE_SCOPE` | `false` | `0` | `false` | `0` |
    | `UNKNOWN` | `false` | `0` (placeholder until resolved) | `false` | `0` |

  - **Derived-entry kinds** (`VAT_RECLAIM`, `VAT_OUTPUT`, `ROUNDING`, `FX_DELTA`) inherit the parent transaction's VAT treatment for compliance-field purposes. `ROUNDING` and `FX_DELTA` never carry VAT amounts on themselves (always zero for both VAT amount columns); their PRIMARY-side and any paired `VAT_RECLAIM` / `VAT_OUTPUT` rows carry the actual VAT figures per the placement rules above.

  - **VAT-amount placement on paired entries (avoids double-counting):**
    - For a **Domestic Cyprus VAT** OUT-side entry: the PRIMARY row carries `input_vat_reclaimable_amount` non-zero. No `VAT_RECLAIM` derived row is produced (the amount lives on the PRIMARY).
    - For a **Domestic Cyprus VAT** IN-side entry: the PRIMARY row carries `output_vat_due_amount` non-zero. No `VAT_OUTPUT` derived row.
    - For an **EU_REVERSE_CHARGE** OUT-side entry: the PRIMARY row carries **zero** for both VAT amounts; the `VAT_RECLAIM` derived row carries the `input_vat_reclaimable_amount`; the `VAT_OUTPUT` derived row carries the `output_vat_due_amount`. Net VAT across the three rows = zero. Reports that aggregate VAT must sum across all `entry_kind` rows for a given `parent_transaction_id` — never just the PRIMARY — and Phase 10's tests verify there is no double-counting.
    - For an **IMPORT_OR_ACQUISITION** entry: same shape as EU_REVERSE_CHARGE OUT-side (PRIMARY zero; `VAT_RECLAIM` + `VAT_OUTPUT` derived rows carry the amounts).
    - For all other treatments: VAT amounts (when non-zero) live on the PRIMARY only.
  - **Mixed-rate invoices** — when the document has multiple VAT lines at different rates, the calculator handles the per-line breakdown when Phase 07's multi-line split-by-category produced separate PRIMARY entries. When Phase 07 consolidated them into a single PRIMARY, the calculator uses the document's total VAT figure as a single `input_vat_reclaimable_amount` on the consolidated entry. Sub-doc tracks the trade-off.
  - **Rounding** — VAT amounts round to two decimal places using `HALF_UP` (canonical project-wide rule per the hard conventions table); cumulative rounding deltas across paired entries (e.g., the OUT-side reverse-charge VAT_RECLAIM + VAT_OUTPUT pair) are reconciled by a `ROUNDING` derived entry when needed. Sub-doc owns the threshold (default `±0.02`).
- **Evidence flags** (`requires_invoice`, `requires_receipt`, `requires_contract`):
  - **Per transaction type** (Stage 1 default; per-business override deferred to sub-doc):

    | Transaction type | `requires_invoice` | `requires_receipt` | `requires_contract` |
    | --- | --- | --- | --- |
    | `OUT_EXPENSE` (≥ €15) | `true` | `false` | `false` |
    | `OUT_EXPENSE` (< €15) | `false` | `true` | `false` |
    | `IN_INCOME` | `true` (Block 13 always issues) | `false` | `false` |
    | `INTERNAL_TRANSFER` | `false` | `false` | `false` |
    | `FX_EXCHANGE` | `false` | `false` (bank-generated FX evidence is automatic) | `false` |
    | `BANK_FEE` | `false` | `false` (bank-generated) | `false` |
    | `REFUND_IN` | `false` | `false` (original transaction reference suffices) | `false` |
    | `REFUND_OUT` | `false` | `false` | `false` |
    | `CHARGEBACK` | `false` | `false` (bank evidence + dispute record) | `false` |
    | `LOAN_OR_SHAREHOLDER_MOVEMENT` | `false` | `false` | `true` |
    | `PAYROLL_OR_TEAM_PAYMENT` (contractor) | `true` | `false` | `true` (when contractor invoice is the only evidence) |
    | `PAYROLL_OR_TEAM_PAYMENT` (employee) | `false` | `false` (payroll record suffices) | `false` |
    | `TAX_PAYMENT` | `false` | `false` (tax authority confirmation; tracked via match record) | `false` |
    | `UNKNOWN` | flags not set; the entry is held |

  - **Credit notes (issued or received)** route through `REFUND_OUT` (when the business issued the credit note against a customer) or `REFUND_IN` (when a supplier issued one against the business). The credit-note number from Block 13 (or the supplier's credit-note reference) acts as the matched evidence; no separate `requires_invoice` is set. Phase 07's REFUND paths consume the credit-note reference — sub-doc tracks the exact contract with Block 13 for credit-note ↔ ledger-entry mapping.
  - **Threshold for the receipt-vs-invoice cutoff** (€15) is configurable per business via the chart-of-accounts mapping-version sub-doc; default is the Stage 1 value above.
  - When a flag is `true` AND the matched evidence does NOT satisfy the requirement (e.g., `requires_invoice = true` but the matched document is a receipt), the entry raises a `MISSING_REQUIRED_EVIDENCE` review issue in Block 14's `Missing Documents` bucket (severity `HIGH`).
- **Accountant-review flag** — `requires_accountant_review` set to `true` when ANY of:
  - `vat_treatment = UNKNOWN` (residual or unresolved counterparty) — `accountant_review_reason = "VAT treatment could not be determined."`
  - **Tag mismatch** detected by Phase 05 — reason carries the mismatch description.
  - **Cross-period adjustment** plausibly required (e.g., the entry's matched invoice falls in a finalized period; per Block 03 Phase 11 it must route through an adjustment run) — `accountant_review_reason = "Cross-period adjustment may be required for this entry."`
  - **Reverse-charge plausible but not confirmable** — counterparty country is EU, but VAT number is missing or invalid (so Phase 05's OUT-2 / OUT-3 rules couldn't fire definitively) — reason carries the missing-VAT-number detail.
  - **Counterparty country unclear** — Phase 04 returned `UNRESOLVED` for country.
  - **Counterparty VAT number missing or invalid** when the rule branch required it — reason includes `Phase04 / Phase05` rule pointer.
  - **Mapped account is disabled** — Phase 03's disabled-account semantics.
- **Review-issue producer** — for each entry where `requires_accountant_review = true`:
  - One `review_issues` row written (Block 04 Phase 04) with `issue_group = 'Possible Tax/VAT Issue'`, `severity` per the rule (`HIGH` for `vat_treatment = UNKNOWN`, `MEDIUM` for tag mismatches, etc. — sub-doc owns the severity table).
  - The issue's payload references `draft_ledger_entries.id` and the structured signals.
  - Resolution actions: confirm-as-is (the user accepts the rule's output and clears the flag), edit treatment (privileged; Owner/Admin only — opens a dialog to override the treatment manually with a mandatory reason and creates an audit-logged manual override), reclassify counterparty (re-runs Phase 04 with user-supplied country/VAT-number), re-run classifier (after upstream data changes).
- **Manual-override semantics:**
  - When the user picks "edit treatment", the override writes a new `vat_treatment` to the draft entry along with `manual_override_by`, `manual_override_reason`, and an audit event. The override is preserved on re-runs of the classifier (Phase 05 honors a manual-override flag and skips its rules for that entry) until the user explicitly clears the override.
  - Manual override is **Owner / Admin only**. Bookkeeper / Accountant / Reviewer can flag entries for re-review but cannot rewrite the treatment.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `LEDGER`):
  - `LEDGER_VAT_AMOUNTS_COMPUTED`
  - `LEDGER_EVIDENCE_FLAGS_SET`
  - `LEDGER_ACCOUNTANT_REVIEW_FLAGGED` (with reason category)
  - `LEDGER_MISSING_REQUIRED_EVIDENCE_RAISED`
  - `LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_APPLIED` (with before/after, user, reason)
  - `LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_CLEARED`

## Definition of Done

- A domestic Cyprus B2B `OUT_EXPENSE` with a document-stated VAT amount carries that exact amount in `input_vat_reclaimable_amount`.
- An expense without a document VAT line uses the rate-derived calculation; the `vat_rate_table_version` is pinned.
- A reverse-charge OUT-side entry has equal `input_vat_reclaimable_amount` and `output_vat_due_amount` (net zero).
- An `EXEMPT` / `NO_VAT` / `OUTSIDE_SCOPE` entry has both amounts `0` and both flags `false`.
- An `OUT_EXPENSE` of €12 sets `requires_receipt = true` and `requires_invoice = false`; an `OUT_EXPENSE` of €120 sets `requires_invoice = true`.
- A `LOAN_OR_SHAREHOLDER_MOVEMENT` sets `requires_contract = true`.
- An entry with `vat_treatment = UNKNOWN` raises a `Possible Tax/VAT Issue` review issue with `severity = HIGH` and the right reason text.
- A manual override by an Owner / Admin updates the treatment, audit-logs the change, and survives re-runs of Phase 05.
- A non-Owner/Admin attempting manual override is denied with the right error.
- A multi-rate invoice has its breakdown handled per the consolidation/split decision from Phase 07.
- Tests cover every treatment row in the table, both evidence-flag cases per type, every accountant-review trigger, and the manual-override happy + deny paths.

## Sub-doc Hooks (Stage 4)

- **VAT rate table sub-doc** — Cyprus standard, reduced, zero rates; mid-period rate change handling (the deferred Stage 1 item). **Shared with Phase 05** — single Stage 4 sub-doc covers the Cyprus VAT rate table for both phases (Phase 05 needs rates for category→rate mapping, Phase 08 needs them for rate-derived amount calculation).
- **Severity-mapping sub-doc** — exact severity per `accountant_review_reason` category.
- **Manual-override UX sub-doc** — dialog layout, mandatory reason, undo path.
- **Evidence-flag thresholds sub-doc** — per-business override, the €15 receipt-vs-invoice cutoff configuration.
- **Rounding policy sub-doc** — `HALF_UP` rounding (project-wide canonical), `ROUNDING` derived-entry trigger threshold.
- **Document-VAT extraction confidence sub-doc** — when to trust the document VAT figure vs derive (e.g., low-confidence Tier 2 extractions).
