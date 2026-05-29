# Transaction Type Enum

**Category:** Reference data · **Owning block:** 08 — Transaction Classification & Tagging · **Co-owners:** 04, 11, 12, 13 · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The closed 12-value transaction-type enum pinned in Block 08's architecture. Every transaction is classified into exactly one of these types. The type drives the workflow side (`OUT_FILTER` vs `IN_FILTER`), the ledger-preparation dispatcher path in Block 11, and the review-issue routing in Block 14. Adding a value requires a `Docs/decisions_log.md` amendment.

---

## The 12 values

| Value | Direction | Ledger path (Block 11 Phase 07) | Notes |
| --- | --- | --- | --- |
| `OUT_EXPENSE` | OUT | `prepareExpenseEntry` | Standard outgoing expense; requires evidence document |
| `IN_INCOME` | IN | `prepareIncomeEntry` | Incoming customer payment; matches against invoice |
| `INTERNAL_TRANSFER` | BOTH | `prepareInternalTransferEntry` (single-writer per Stage 1) | Between own accounts; deduplicated across OUT/IN visibility |
| `FX_EXCHANGE` | BOTH | `prepareFxExchangeEntry` (multi-leg) | One transaction, paired legs in `fx_paired_legs` JSONB |
| `BANK_FEE` | OUT | `prepareBankFeeEntry` | Bank charges, account fees, wire fees |
| `REFUND_IN` | IN | `prepareRefundInEntry` | Refund credited from a previous OUT_EXPENSE supplier |
| `REFUND_OUT` | OUT | `prepareRefundOutEntry` | Refund issued to a previous IN_INCOME client |
| `CHARGEBACK` | OUT or IN | `prepareChargebackEntry` | Disputed transaction reversal; direction-dependent |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` | BOTH | `prepareLoanOrShareholderEntry` (direction-aware) | Director loans, capital injections, dividends |
| `PAYROLL_OR_TEAM_PAYMENT` | OUT | `preparePayrollEntry` | Salaries, contractor payments, bonuses |
| `TAX_PAYMENT` | OUT | `prepareTaxPaymentEntry` | VAT remittances, corporate tax payments |
| `UNKNOWN` | (deferred) | (none — blocks until reclassified) | Canonical BLOCKING per Block 14 Phase 02 |

## Direction → workflow routing

The `direction` field maps each type to which side of the workflow (OUT or IN) processes it after classification.

| Direction | Routes to | Notes |
| --- | --- | --- |
| OUT | `OUT_FILTER` (Block 12 Phase 03) | Outgoing-money types |
| IN | `IN_FILTER` (Block 13 Phase 08) | Incoming-money types |
| BOTH | Both filters per direction-detection | Per-row evaluation: `LOAN_OR_SHAREHOLDER_MOVEMENT` and `INTERNAL_TRANSFER` need direction-of-flow detection at filter time |
| (deferred) | Held at REVIEW_HOLD | `UNKNOWN` is canonically BLOCKING |

### LOAN_OR_SHAREHOLDER_MOVEMENT split

Per the Block 12 scan fix (2026-05-08): the LOAN direction split per direction-of-flow:
- OUT direction (loan disbursement, capital return) → OUT_FILTER
- IN direction (capital injection, loan receipt) → IN_FILTER

Block 12 Phase 02 + Phase 03 own the split logic.

### INTERNAL_TRANSFER single-writer

Per the Stage 1 decision: INTERNAL_TRANSFER passes through both OUT_FILTER and IN_FILTER (because the same flow shows up on two account statements), but Block 11's inter-account-movement tool produces a **single deduplicated ledger entry**. The dedup contract is `internal_transfer_cross_workflow_dedup_policy` (Block 12, co-owners 11 + 13).

## UNKNOWN — canonically BLOCKING

`UNKNOWN` is a deferred-classification placeholder. It surfaces in the review queue as a BLOCKING issue (per Block 14 Phase 02). The classification pipeline (Layers 1–3 in Block 08) makes a deterministic-or-AI attempt; an entry exits `UNKNOWN` via:

1. User reclassification (manual selection of one of the 11 other types)
2. Updated vendor memory after a confirmed match elsewhere (back-propagates)
3. Custom-tag mapping (per `custom_tag_policies`)

`UNKNOWN` blocks finalization until reclassified — period.

## Direction of `UNKNOWN`

`UNKNOWN` carries no direction. The bank-statement sign (positive vs negative amount) is preserved on the row for reclassification context but does NOT trigger filter routing. The transaction sits in REVIEW_HOLD until classified.

This rules out the historical `UNKNOWN_POSITIVE` form caught in the Stage 1 cross-block scan — that form was non-canonical and has been removed.

## VAT-treatment relationship

Transaction type does NOT directly determine VAT treatment. Block 11 Phase 05 computes VAT treatment from a combination of (transaction type, counterparty country, counterparty VAT number, document type). The 8-value `vat_treatment_enum` is orthogonal to the 12-value transaction type enum — see `vat_treatment_enum`.

## Custom tags

Per the Stage 1 decision: every per-business custom tag maps to exactly one of the 12 transaction types. The mapping is recorded in the custom-tag definition and applied at classification time (per `custom_tag_policies` and Block 08 Phase 06).

## Storage

`transactions.transaction_type` column. Postgres ENUM:

```sql
CREATE TYPE transaction_type_enum AS ENUM (
  'OUT_EXPENSE',
  'IN_INCOME',
  'INTERNAL_TRANSFER',
  'FX_EXCHANGE',
  'BANK_FEE',
  'REFUND_IN',
  'REFUND_OUT',
  'CHARGEBACK',
  'LOAN_OR_SHAREHOLDER_MOVEMENT',
  'PAYROLL_OR_TEAM_PAYMENT',
  'TAX_PAYMENT',
  'UNKNOWN'
);
```

A repo-wide lint check asserts no doc references a non-enumerated type (the `transaction_type_drift_lint_check` fixture per Block 08 Phase 10).

## Cross-references

- `vat_treatment_enum` — 8-value VAT taxonomy (orthogonal)
- `match_level_enum` — match-level taxonomy
- `issue_group_enum` — review-queue routing
- `severity_enum` — `UNKNOWN` is canonically BLOCKING
- `custom_tag_policies` — Stage 1 decision on per-business tag → type mapping
- `internal_transfer_cross_workflow_dedup_policy` — single-writer rule
- Block 08 Phase 02 — Layer 1 classifier (deterministic rules)
- Block 11 Phase 07 — type-aware ledger preparation dispatcher
- Block 12 Phase 02 + 03 — OUT routing
- Block 13 Phase 08 — IN routing
- Block 14 Phase 02 — UNKNOWN as BLOCKING

---

## VAT treatment implications per transaction type

Transaction type does NOT directly determine VAT treatment (the classifier in Block 11 Phase 05 does that), but each type has a default starting point and a set of treatments that are valid or invalid for it. The table below captures the default assumption and the valid range. Actual treatment may differ based on counterparty country, VAT number validity, and manual override.

| `transaction_type` | Default VAT treatment | Other valid treatments | Invalid treatments | Notes |
| --- | --- | --- | --- | --- |
| `OUT_EXPENSE` | `DOMESTIC_STANDARD` | `DOMESTIC_REDUCED`, `DOMESTIC_ZERO`, `IMPORT_OR_ACQUISITION`, `OUTSIDE_SCOPE`, `UNKNOWN` | `NON_EU_SERVICE`, `EU_REVERSE_CHARGE` (from buyer's perspective — Cyprus is the buyer, not the reverse-charge provider) | Standard 19% Cyprus VAT applies to most domestic expenses; imports use `IMPORT_OR_ACQUISITION` |
| `IN_INCOME` | `DOMESTIC_STANDARD` | `DOMESTIC_REDUCED`, `DOMESTIC_ZERO`, `EU_REVERSE_CHARGE`, `NON_EU_SERVICE`, `OUTSIDE_SCOPE`, `UNKNOWN` | `IMPORT_OR_ACQUISITION` | `EU_REVERSE_CHARGE` applies when supplying B2B services to EU clients who account for VAT themselves |
| `INTERNAL_TRANSFER` | `OUTSIDE_SCOPE` | (none) | All other treatments | Always outside the VAT regime; no VAT return line item |
| `FX_EXCHANGE` | `OUTSIDE_SCOPE` | (none) | All other treatments | Currency exchange is outside VAT scope per Cyprus VAT Law Article 26(1)(b) |
| `BANK_FEE` | `OUTSIDE_SCOPE` | `DOMESTIC_STANDARD` (rare — some advisory fee types are VATable) | `EU_REVERSE_CHARGE`, `IMPORT_OR_ACQUISITION`, `NON_EU_SERVICE` | Most bank charges are exempt; standard-rate VAT only when the fee is explicitly VATable per bank invoice |
| `REFUND_IN` | Mirrors the original `OUT_EXPENSE` treatment | Per original treatment | — | The refund reverses the original VAT treatment; Block 11 retrieves the original entry's treatment for the refund entry |
| `REFUND_OUT` | Mirrors the original `IN_INCOME` treatment | Per original treatment | — | Same mirroring logic; credit note to a client uses the original invoice's treatment |
| `CHARGEBACK` | `OUTSIDE_SCOPE` | `DOMESTIC_STANDARD` if the original transaction was VATable | — | Depends on the original transaction; defaults to OUTSIDE_SCOPE until Block 11 traces the original |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` | `OUTSIDE_SCOPE` | (none) | All other treatments | Director loans, capital injections, dividends — all outside VAT scope |
| `PAYROLL_OR_TEAM_PAYMENT` | `OUTSIDE_SCOPE` | (none) | All other treatments | Payroll is outside the VAT regime in Cyprus; not reported on the VAT return |
| `TAX_PAYMENT` | `OUTSIDE_SCOPE` | (none) | All other treatments | Tax remittances are outside VAT scope |
| `UNKNOWN` | `UNKNOWN` (deferred) | Resolved to any other treatment after reclassification | — | Cannot finalize until resolved |

Cyprus VAT rates for reference: standard 19%, reduced 9% (hotel accommodation, restaurants), reduced 5% (books, medical equipment, social housing), zero 0% (exports, specific services).

---

## OUT/IN workflow scope notes

Which transaction types appear exclusively in the OUT workflow, exclusively in the IN workflow, or in both:

| `transaction_type` | Workflow scope | Key implication |
| --- | --- | --- |
| `OUT_EXPENSE` | OUT only | The full expense → evidence → VAT chain is OUT-side; IN never sees these |
| `IN_INCOME` | IN only | Invoice matching and revenue recording is IN-side only |
| `INTERNAL_TRANSFER` | Both (see filter table) | Block 11 dedup ensures single ledger entry regardless of which side processes it first |
| `FX_EXCHANGE` | Both | Multi-leg; both sides carry a leg in their respective filters |
| `BANK_FEE` | OUT only | Bank charges appear as debits on the business account |
| `REFUND_IN` | IN only | A credit from a supplier is processed by the IN workflow |
| `REFUND_OUT` | OUT only | A credit note issued to a client is processed by the OUT workflow |
| `CHARGEBACK` | Both (direction-dependent) | The filter routes per amount sign at the time of filtering |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` | Both (direction-dependent) | Split per direction-of-flow per the 2026-05-08 fix |
| `PAYROLL_OR_TEAM_PAYMENT` | OUT only | Payroll debits are always OUT-side events |
| `TAX_PAYMENT` | OUT only | Tax remittances are always debits |
| `UNKNOWN` | Neither until reclassified | Held in REVIEW_HOLD |

---

## Classification rule cross-references

The Layer 1 deterministic classifier (`layer1_rule_evaluation_schema`) applies an ordered rule set to assign the type. The rule set is evaluated top-to-bottom; the first matching rule wins. Key rule anchors per type:

- `OUT_EXPENSE`: rules match on `amount_signed < 0` AND counterparty NOT in the known-internal-account set AND type-hint from document is `INVOICE` or `RECEIPT`
- `IN_INCOME`: rules match on `amount_signed > 0` AND counterparty IS a known client OR a matched outstanding invoice exists
- `INTERNAL_TRANSFER`: rules match on counterparty IBAN being in the business's registered own-account list
- `BANK_FEE`: rules match on bank-narration patterns (`/FEE/`, `/CHARGE/`, `/SERVICE FEE/`) combined with the bank's own account as counterparty
- `PAYROLL_OR_TEAM_PAYMENT`: rules match on `amount_signed < 0` AND counterparty is in the `payroll_vendor_set` OR narration matches payroll patterns

Full rule set: `layer1_rule_evaluation_schema` (Block 08 Reference data).
