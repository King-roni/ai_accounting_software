# Block 11 — Phase 07: Type-Aware Ledger Preparation Paths

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Type-Aware Ledger Preparation table; Multi-line invoices — one consolidated entry)
- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (the 12 transaction types — closed taxonomy)
- Decisions log: `Docs/decisions_log.md` (multi-line invoice → one consolidated ledger entry; line detail preserved on the Document)

## Phase Goal

Implement the dispatcher that converts each typed, classified, evidence-matched transaction into one or more `draft_ledger_entries` rows. One path per transaction type, each producing a `PRIMARY` entry plus any derived entries (`VAT_RECLAIM`, `VAT_OUTPUT`, `ROUNDING`, `FX_DELTA`) that the type and the resolved VAT treatment require. Multi-line invoices consolidate into a single `PRIMARY` entry; line-item detail stays on the underlying `Document`. After this phase, every typed transaction either has draft entries or is held pending re-classification.

## Dependencies

- Phase 01 (`draft_ledger_entries`, `chart_of_accounts_mappings`)
- Phase 03 (chart-mapping version pinning)
- Phase 04 (counterparty resolution already done)
- Phase 05 (VAT treatment already decided per `PRIMARY` entry — but the dispatcher invokes Phase 05 within its own flow when entry kinds split)
- Phase 06 (reverse-charge / VIES booleans set)
- Block 04 Phase 02 (`transactions`)
- Block 04 Phase 03 (`match_records` + extracted document fields)
- Block 08 Phase 03 (vendor memory; tags from Phase 05)

## Deliverables

- **Per-type ledger paths** — one path per Block 08 transaction type. Each path is a function `prepare<Type>Entries(transaction, match_record?, business_profile, mapping_version) → DraftEntry[]`. The dispatcher `prepareLedgerEntries(transaction, ...)` looks up the path by `transaction.type` and invokes it.

  | Transaction type | Path | `PRIMARY` entry shape | Derived entries |
  | --- | --- | --- | --- |
  | `OUT_EXPENSE` | `prepareOutExpenseEntries` | Debit expense account (resolved via mapping rule + tag), Credit bank account | `VAT_RECLAIM` (when `input_vat_reclaimable_flag=true`); `VAT_RECLAIM` + `VAT_OUTPUT` pair (when `reverse_charge_relevant=true` OUT-side) |
  | `IN_INCOME` | `prepareInIncomeEntries` | Debit bank account, Credit revenue account (resolved via mapping rule) | `VAT_OUTPUT` (when `output_vat_due_flag=true`) |
  | `INTERNAL_TRANSFER` | `prepareInternalTransferEntries` | Debit destination bank account, Credit source bank account | None |
  | `FX_EXCHANGE` | `prepareFxExchangeEntries` | Two PRIMARY entries — one per currency leg; bank-recorded FX rate from `transactions.fx_paired_legs` | `FX_DELTA` entry capturing realized gain/loss vs ECB rate (sub-doc owns the methodology) |
  | `BANK_FEE` | `prepareBankFeeEntries` | Debit Bank Charges (deductible or non-deductible per fee category), Credit bank account | None — fees are typically `OUTSIDE_SCOPE` per Phase 05 |
  | `REFUND_IN` | `prepareRefundInEntries` | Debit bank account, Credit the original expense account (reverses the original entry's account) | Reverses the original entry's `VAT_RECLAIM` if applicable |
  | `REFUND_OUT` | `prepareRefundOutEntries` | Debit the original revenue account (reverses), Credit bank account | Reverses the original `VAT_OUTPUT` if applicable |
  | `CHARGEBACK` | `prepareChargebackEntries` | Same shape as `REFUND_OUT` plus a Bank Charges line for any chargeback fee | None beyond REFUND_OUT |
  | `LOAN_OR_SHAREHOLDER_MOVEMENT` | `prepareLoanShareholderEntries` | Debit/Credit the relevant equity or loan account (Director's Loan Account, Shareholder Capital, etc., per the mapping rule and the movement direction); other side is bank | None — `OUTSIDE_SCOPE` |
  | `PAYROLL_OR_TEAM_PAYMENT` | `preparePayrollEntries` | Debit Salaries & Wages / Contractor Payments, Credit bank | `VAT_RECLAIM` only when contractor invoice has reclaimable VAT |
  | `TAX_PAYMENT` | `prepareTaxPaymentEntries` | Debit the relevant tax-liability account (VAT Payable, Income Tax, etc.), Credit bank | None — `OUTSIDE_SCOPE` |
  | `UNKNOWN` | (no path) | **No draft entries produced.** Held pending re-classification. | N/A |

- **Lifecycle-driven dispatcher path** — `prepare_invoice_lifecycle_entries(invoice, lifecycle_transition, context) → DraftEntry[]` (added per Block 13 Phase 06's cross-block coordination):
  - Invoked by lifecycle transitions that produce ledger entries WITHOUT a corresponding new transaction (the per-type dispatcher above is transaction-keyed and cannot cover these). Distinct from the per-type paths; selected when the trigger is an invoice lifecycle event rather than a bank-statement transaction.
  - Stage 1 lifecycle transitions covered:
    - **`WRITTEN_OFF`** — debit `Bad Debts — non-deductible` (Phase 02's seed catalog), credit `Trade Debtors`, for the invoice's residual unpaid amount (`total_amount - SUM(prior_paid_allocations.allocated_amount)`). VAT amounts on the entry are zero (Block 13 Phase 06's note: Cyprus VAT relief on bad debts is deferred Stage 2+; the bad-debt expense covers gross including VAT).
  - Future lifecycle transitions (e.g., retroactive `CREDITED` outside the credit-note path) would be added here.
  - Registered as `ledger.prepare_invoice_lifecycle_entries` by Phase 09's tool registration.
- **Multi-line invoice consolidation rule:**
  - When `match_record` references a `Document` whose extracted fields include multiple line items (e.g., AWS invoice with 12 service lines), the `PRIMARY` entry consolidates the totals into a single row.
  - The line-item detail remains on `documents.extracted_fields_json.line_items` and is reachable via drill-down from Block 16.
  - **Exception path** — when individual line items map to *different account categories* (e.g., one line is "Cloud compute → IT & Software", another is "Marketing — paid ads → Marketing"), the consolidation does NOT collapse them: one `PRIMARY` entry is produced per distinct destination account, all sharing the same `parent_transaction_id` and `match_record_id`. Sub-doc tracks the heuristic for "do these line items belong in different accounts?" — Stage 1 default: a tag-equality check on the line items' inferred tags.
- **Mapping rule resolution (per entry, per direction):**
  - For each entry side (debit and credit), the dispatcher consults `chart_of_accounts_mappings` filtered by `business_id` and the active `chart_mapping_version_id` (Phase 03), ordered by priority. The first applicable rule (matching transaction type, optionally tag, optionally vat_treatment, optionally entry_kind) wins.
  - **No applicable rule** → falls through to the default rule for the transaction type (which Phase 02's seed guarantees exists). If even the default rule resolves to a disabled account, the entry is flagged `requires_accountant_review` per Phase 03's disabled-account semantics.
- **Idempotency / re-derivation:**
  - The dispatcher is idempotent: invoking it twice for the same `(transaction_id, match_record_id, mapping_version_id)` produces the same draft entries. Existing draft entries for the same transaction are deleted-and-replaced as a single transaction (Phase 09 owns the replace-on-recompute side-effect contract); audit logs both the deletion and the new insertion via `LEDGER_DRAFT_ENTRY_RECOMPUTED` events.
  - Re-derivation is triggered by: a user-confirmed change to the transaction's tag (Block 08), a confirmed change to the matched document (Block 10), a chart-customization change while the period is still `DRAFT` (Phase 03), or an explicit re-run from the workflow engine.
- **Held entries (`UNKNOWN` type):**
  - When the transaction's type is `UNKNOWN`, no draft entries are produced and a single `LEDGER_HELD_PENDING_CLASSIFICATION` audit event fires. A review issue (severity HIGH) sits in the `Possible Tax/VAT Issue` bucket prompting re-classification.
- **Cross-currency consideration:**
  - When the transaction currency differs from the business's bookkeeping currency (typically EUR), all amounts on draft entries are stored in the bookkeeping currency, with the original currency + amount preserved in `entry_currency_original`, `entry_amount_original`. The FX rate source uses the same paired-leg / ECB-fallback chain as Block 10 Phase 02 (sub-doc pins the contract).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `LEDGER`):
  - `LEDGER_DRAFT_ENTRY_CREATED` (declared in Phase 01; emitted here per row inserted)
  - `LEDGER_DRAFT_ENTRY_RECOMPUTED` (emitted on re-derive; payload includes count of rows replaced)
  - `LEDGER_HELD_PENDING_CLASSIFICATION` (when type is `UNKNOWN`)
  - `LEDGER_MULTI_LINE_INVOICE_CONSOLIDATED` (with line-item count)
  - `LEDGER_MULTI_LINE_INVOICE_SPLIT_BY_CATEGORY` (when the exception path produces multiple PRIMARY entries)
  - `LEDGER_MAPPING_RULE_FALLBACK_USED` (when the resolver fell through to the default)

## Definition of Done

- A simple Cyprus B2B `OUT_EXPENSE` produces one `PRIMARY` entry plus one `VAT_RECLAIM` derived entry.
- A reverse-charge OUT-side `EU_REVERSE_CHARGE` expense produces one `PRIMARY` plus a paired `VAT_RECLAIM` and `VAT_OUTPUT` of equal amount.
- An `IN_INCOME` to an EU B2B customer produces one `PRIMARY` (revenue credit) and no domestic Output VAT entry; the `vies_relevant` flag from Phase 06 is preserved.
- An AWS-style multi-line invoice with all lines mapping to "IT & Software" produces one consolidated `PRIMARY`; the line items remain on the Document.
- A multi-line invoice spanning two account categories produces two `PRIMARY` entries.
- An `UNKNOWN`-type transaction produces zero entries and the held audit event fires.
- An `INTERNAL_TRANSFER` produces one `PRIMARY` with no VAT-derived entries.
- A re-run with the same inputs produces an identical set of draft entries (idempotent).
- All paths respect the version-pin: a re-run after a chart customization in a still-`DRAFT` period uses the new active version.
- Tests cover every transaction type's path, plus the consolidation rule (single account vs split), reverse-charge OUT/IN derived-entry shapes, and the `UNKNOWN` hold.

## Sub-doc Hooks (Stage 4)

- **Per-type ledger-path sub-doc (one per type)** — exact debit/credit logic, edge cases, derived-entry shapes per VAT treatment.
- **Multi-line consolidation heuristic sub-doc** — exact tag-equality rule, when to split.
- **FX rate source sub-doc** — contract with Block 10 Phase 02; per-entry version stamping.
- **Recompute side-effect sub-doc** — exact replace-on-recompute semantics; transactionality with audit emission.
- **Mapping-rule resolution algorithm sub-doc** — priority ordering, tag-match precedence, treatment-specific overrides.
- **`UNKNOWN`-type holding queue sub-doc** — UI surface, time-since-held metric, escalation rules.
