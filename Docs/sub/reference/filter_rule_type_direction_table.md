# Filter Rule Type-Direction Table

**Category:** Reference data · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 reference)

The canonical mapping from `transaction_type` to which filter (`OUT_FILTER`, `IN_FILTER`, both, or neither) accepts the transaction. Filter routing happens after classification (Block 08) and before the type-aware workflow paths. The 12 transaction types from `transaction_type_enum` each get a row here.

Per the 2026-05-08 Block 12 fix, the `LOAN_OR_SHAREHOLDER_MOVEMENT` direction is split per direction-of-flow at filter time. Per Stage 1, `INTERNAL_TRANSFER` passes through both filters but produces a single deduplicated ledger entry. Per the Block 12 fix, the filter decision lives in two columns (one per direction) — there's no single multi-valued column.

---

## The mapping

| `transaction_type` | OUT_FILTER | IN_FILTER | Block 11 ledger path |
| --- | --- | --- | --- |
| `OUT_EXPENSE` | ✓ (always) | ✗ | `prepareExpenseEntry` |
| `IN_INCOME` | ✗ | ✓ (always) | `prepareIncomeEntry` |
| `INTERNAL_TRANSFER` | ✓ + ✓ (both) | ✓ + ✓ (both) | `prepareInternalTransferEntry` (single writer per Stage 1) |
| `FX_EXCHANGE` | ✓ (multi-leg, OUT leg) | ✓ (multi-leg, IN leg) | `prepareFxExchangeEntry` (one transaction, paired legs) |
| `BANK_FEE` | ✓ | ✗ | `prepareBankFeeEntry` |
| `REFUND_IN` | ✗ | ✓ | `prepareRefundInEntry` |
| `REFUND_OUT` | ✓ | ✗ | `prepareRefundOutEntry` |
| `CHARGEBACK` | direction-dependent | direction-dependent | `prepareChargebackEntry` |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` (OUT direction — loan disbursement, capital return) | ✓ | ✗ | `prepareLoanOrShareholderEntry` (OUT path) |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` (IN direction — capital injection, loan receipt) | ✗ | ✓ | `prepareLoanOrShareholderEntry` (IN path) |
| `PAYROLL_OR_TEAM_PAYMENT` | ✓ | ✗ | `preparePayrollEntry` |
| `TAX_PAYMENT` | ✓ | ✗ | `prepareTaxPaymentEntry` |
| `UNKNOWN` | held | held | (none — blocks at REVIEW_HOLD until reclassified) |

## Direction-of-flow detection

For types that route per direction (`LOAN_OR_SHAREHOLDER_MOVEMENT`, `CHARGEBACK`, `FX_EXCHANGE`, `INTERNAL_TRANSFER`):

```
direction_of_flow = sign(transactions.amount_signed)
where positive amount → IN side
      negative amount → OUT side
```

This is the canonical Cyprus banking convention: deposits to the business account are positive; debits / payments are negative. The classifier (Block 08) populates `amount_signed` based on the parsed statement row; Block 11 Phase 04 / 07 consumes it.

### Edge case: zero-amount FX leg

An FX exchange transaction has paired legs in `fx_paired_legs` JSONB; the top-level `amount_signed` may sum to zero (the legs cancel). The direction-of-flow rule uses the **outgoing** leg's amount sign (always negative); both filters see the transaction once.

### Edge case: INTERNAL_TRANSFER visible on both statements

When the user uploads statements for both source and destination accounts, the same INTERNAL_TRANSFER appears on both:

- Source statement: negative amount → OUT_FILTER picks it up
- Destination statement: positive amount → IN_FILTER picks it up

Block 11's `prepareInternalTransferEntry` deduplicates these via the canonical INTERNAL_TRANSFER dedup rule per `internal_transfer_cross_workflow_dedup_policy`. Only one ledger entry is produced; the audit trail records both filter decisions.

When the user uploads only one of the two statements, the other side never enters the system — Block 11's dedup is a no-op (only one filter included the transaction).

## Storage

Per the Block 12 Phase 03 fix, the filter decision lives in two columns on `transactions`:

```sql
out_filter_decided_at         timestamptz,
out_filter_decided_by_run_id  uuid,
in_filter_decided_at          timestamptz,
in_filter_decided_by_run_id   uuid,
```

A transaction passing through both filters has both pairs populated. A transaction passing through one has the other pair NULL. The pair populates only after the filter's decision is committed.

## Filter rule eligibility (gate-side)

The actual filter logic (which transactions are **included** vs **excluded** within a filter direction) is governed by per-block filter-rule sub-docs:

- `out_filter_rule_canonical_table` (Block 12) — OUT rule precedence and overrides
- `in_filter_rule_canonical_table` (Block 13) — IN rule precedence and overrides

This sub-doc commits to which filter direction sees which transaction type; the within-filter inclusion logic is separate.

## Filter re-run semantics

Per `filter_rerun_semantics_policy` (Block 12 + 13 co-owned): a re-run of the filter (via adjustment workflow or schema migration) emits `OUT_FILTER_RAN` / `IN_FILTER_RAN` and re-evaluates every transaction in scope. The per-transaction `*_decided_at` is overwritten; the per-transaction audit trail captures the prior decision via the audit log's hash chain.

## Per-business toggles

Per `per_business_toggle_short_circuit_policy` (Block 12 + 13 co-owned): when `out_workflow_business_config.enabled = false`, OUT_FILTER short-circuits (no rows enter the OUT side regardless of `transaction_type`). The IN_FILTER is independently toggleable.

Note: this is a coarse toggle. Per-type disabling (e.g., "this business doesn't use bank fees so route BANK_FEE differently") is a Stage 2+ deferral.

## Lint rules

1. Every transaction in a finalized period has at least one of `(out_filter_decided_at, in_filter_decided_at)` set; both null is a data-integrity violation caught by Block 04 Phase 10's retention engine
2. A transaction with `transaction_type = UNKNOWN` MUST NOT have either filter timestamp set — held until reclassified
3. Direction-dependent types (`LOAN_OR_SHAREHOLDER_MOVEMENT`, `CHARGEBACK`) MUST have exactly one of the two pairs set (never both)
4. `INTERNAL_TRANSFER` and `FX_EXCHANGE` MAY have both pairs set (canonical case when both statements were uploaded)

## Cross-references

- `transaction_type_enum` — the 12 types
- `internal_transfer_cross_workflow_dedup_policy` (Block 12) — single-writer rule
- `filter_rerun_semantics_policy` — re-run audit shape
- `per_business_toggle_short_circuit_policy` — coarse toggle
- `out_filter_rule_canonical_table` (Block 12) — OUT inclusion logic
- `in_filter_rule_canonical_table` (Block 13) — IN inclusion logic
- Block 12 Phase 03 — `OUT_FILTER` phase
- Block 13 Phase 08 — `IN_FILTER` phase
- Block 11 Phase 07 — type-aware ledger preparation paths
- 2026-05-08 decisions-log amendment — LOAN_OR_SHAREHOLDER_MOVEMENT direction split

---

## Rationale column

Why each rule type applies to each direction — or why it doesn't.

| `transaction_type` | OUT_FILTER rationale | IN_FILTER rationale |
| --- | --- | --- |
| `OUT_EXPENSE` | Outgoing payment for a business purchase; the OUT workflow owns the evidence-matching and VAT reclaim chain | Not an income event; IN workflow has no ledger path for it |
| `IN_INCOME` | Not a payment event; OUT workflow has no ledger path for it | Incoming customer payment; IN workflow owns invoice matching and revenue recording |
| `INTERNAL_TRANSFER` | The source-account debit is a transfer; OUT filter records the outgoing leg | The destination-account credit is the incoming leg; IN filter records it. Both filters see the transaction to allow either statement to trigger the entry; Block 11 deduplicates |
| `FX_EXCHANGE` | The outgoing (sell) leg is an OUT-side event from the business perspective; multi-leg structure means both sides of the exchange are in scope | The incoming (buy) leg appears on the account as a credit; IN filter sees it |
| `BANK_FEE` | Bank charges are outgoing debits; OUT workflow handles them as zero-evidence expenses (no invoice expected) | Banks never charge fees that appear as IN credits to the customer; IN has no path for bank fees |
| `REFUND_IN` | A supplier refund arrives as a credit; not an OUT debit | The credit from a supplier goes through IN workflow — it reduces a prior OUT_EXPENSE exposure |
| `REFUND_OUT` | A credit note issued to a client is processed as an OUT event; it reduces the original IN_INCOME | Not an IN income event — the outgoing credit note is an OUT-side ledger adjustment |
| `CHARGEBACK` | When the chargeback debit hits the business account (the business loses money), it's an OUT event | When the chargeback credit arrives (the business wins the dispute), it's an IN event |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` (OUT direction) | Loan disbursements and capital returns are outgoing cash events; OUT workflow ledgers them under the appropriate equity/liability account | Capital injections flow in, not out; IN handles them separately |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` (IN direction) | Loan receipts flow in, not out; OUT has no path for incoming capital | Incoming shareholder capital or director loans hit the account as credits; IN workflow ledgers them |
| `PAYROLL_OR_TEAM_PAYMENT` | Salaries and contractor payments are outgoing debits; OUT owns payroll | Payroll payments never arrive as credits to the business account under normal operations |
| `TAX_PAYMENT` | Tax remittances are outgoing debits; OUT workflow handles them with a `TAX_PAYMENT` ledger path | Tax refunds from the government are a special case — they're handled as `REFUND_IN` in practice, not as `TAX_PAYMENT` |
| `UNKNOWN` | Held in REVIEW_HOLD — cannot enter either filter until the type is resolved | Same |

---

## Edge cases for ambiguous transaction types

### `CHARGEBACK` direction uncertainty

A chargeback from the card network arrives with ambiguous sign on some bank statements — the narration says "CHARGEBACK" but the sign may reflect the bank's perspective rather than the business's perspective. The classifier (Block 08 Phase 02) applies the following tiebreak: if the transaction row has `amount_signed > 0`, it's a chargeback WIN (IN); if `amount_signed < 0`, it's a chargeback LOSS (OUT). If `amount_signed = 0` (rare — some banks net chargebacks to zero before posting), the classifier raises a `Needs Confirmation` issue and defers to the user.

### `FX_EXCHANGE` with missing legs

An FX_EXCHANGE transaction whose `fx_paired_legs` JSONB is empty (bank statement didn't include the leg breakdown) passes through both OUT and IN filters but with a warning. Block 11 Phase 07's `prepareFxExchangeEntry` cannot decompose the legs correctly; it raises a `Needs Confirmation` issue. The filter decision is still recorded for both directions so the transaction doesn't disappear from either filter's audit trail.

### `INTERNAL_TRANSFER` with only one statement uploaded

If only one of the two account statements is uploaded (the source or the destination but not both), the INTERNAL_TRANSFER will appear in exactly one filter. Block 11's dedup finds no counterpart and produces a single ledger entry for that leg only. The resulting ledger entry flags `dedup_counterpart_missing = true` and raises a `Needs Confirmation` issue at MEDIUM severity so the bookkeeper is aware the other side is not recorded.

---

## Cross-references (extended)

- `out_phase_gate_policy` — gate that guards OUT_FILTER completion and evaluates filter results
- `in_phase_gate_policy` — gate that guards IN_FILTER completion and evaluates filter results
- `filter_rerun_semantics_policy` — what happens when filter decisions are re-evaluated after the initial run
