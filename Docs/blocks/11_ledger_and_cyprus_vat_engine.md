# Block 11 — Ledger & Cyprus VAT Engine

## Role in the System

This block converts classified, evidence-matched transactions into draft ledger entries and applies Cyprus-specific VAT and tax classification. It is the layer where bookkeeping data finally becomes accounting data — debit/credit, account code, VAT treatment, VIES relevance, accountant-review flag.

Crucially, this block produces *drafts*. Drafts are queryable, auditable, and can be re-derived if upstream data changes. They become locked, immutable ledger entries only when Block 15 finalizes the period.

The Cyprus VAT logic and the ledger preparation logic are tightly coupled here on purpose: VAT treatment is a per-entry decision, and pulling these into separate blocks would force constant cross-references for every transaction.

---

## Scope

### In scope
- Type-aware draft ledger entry generation (one path per transaction type)
- Account code mapping (per-business chart of accounts)
- The eight Cyprus VAT treatment values
- Counterparty country and VAT number determination
- VIES relevance flag
- Reverse-charge logic
- Input VAT reclaimability calculation
- Output VAT due calculation
- Accountant-review flag for cases the rules cannot decide
- Required-evidence flag (`requires_invoice`, `requires_receipt`, `requires_contract`)

### Out of scope (covered elsewhere)
- Locking the ledger / period → Block 15 (Finalization & Secure Archive)
- Reports and dashboards built on ledger data → Block 16 (Dashboard & Reporting)
- AI explanation generation → Block 06 (AI Layer)
- Storage of locked ledger entries → Block 04 (Finalized Archive zone)

---

## Type-Aware Ledger Preparation

Each of the 12 transaction types from Block 08 has its own ledger preparation path. The path determines which accounts move, what evidence is required, and what VAT logic applies.

| Transaction type | Ledger path | Evidence requirement |
| --- | --- | --- |
| `OUT_EXPENSE` | Expense ledger tool | Invoice or receipt |
| `IN_INCOME` | Income ledger tool | Invoice (created in Block 13) |
| `INTERNAL_TRANSFER` | Inter-account movement | None (transaction itself is evidence) |
| `FX_EXCHANGE` | Currency movement tool | Bank-generated FX evidence |
| `BANK_FEE` | Bank fee tool | Bank-generated evidence |
| `REFUND_IN` | Refund reconciliation | Original transaction reference |
| `REFUND_OUT` | Refund reconciliation | Original transaction reference |
| `CHARGEBACK` | Refund reconciliation (variant) | Bank-generated evidence + dispute record |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` | Equity / loan tool | Contract or shareholder agreement |
| `PAYROLL_OR_TEAM_PAYMENT` | Contractor / payroll tool | Invoice, contract, or payroll record |
| `TAX_PAYMENT` | Tax payment tool | Tax authority confirmation |
| `UNKNOWN` | Hold pending classification | Cannot proceed until reclassified |

Each path produces one or more `Draft Ledger Entry` rows with the appropriate debits, credits, and VAT fields.

---

## The Eight VAT Treatments

```text
DOMESTIC_CYPRUS_VAT
EU_REVERSE_CHARGE
NON_EU_SERVICE
EXEMPT
NO_VAT
OUTSIDE_SCOPE
IMPORT_OR_ACQUISITION
UNKNOWN
```

Treatment is decided per ledger entry, not per transaction (a single transaction may produce multiple entries with different treatments — e.g. an expense plus its associated VAT reclaim).

The classifier uses these inputs:

- Counterparty country (from extracted document fields, fallback to known supplier registry)
- Counterparty VAT number presence and validity
- Transaction direction (`IN` vs `OUT`)
- Transaction tag (services vs goods, where the distinction matters)
- Business's own VAT registration status
- Service nature flags from extraction (digital services, professional services, etc.)

The classifier is rules-first. Where rules cannot decide unambiguously, the entry is flagged `requires_accountant_review` and the treatment defaults to `UNKNOWN`. The AI layer (Block 06) can be asked to *explain* a tentative classification in plain language, but never to *choose* it.

---

## Compliance Fields per Ledger Entry

Each draft ledger entry carries:

```text
counterparty_country
counterparty_vat_number
vat_treatment              (one of the eight)
input_vat_reclaimable       (boolean + amount)
output_vat_due              (boolean + amount)
reverse_charge_relevant     (boolean)
vies_relevant               (boolean — affects VIES export)
requires_contract           (boolean)
requires_invoice            (boolean)
requires_receipt            (boolean)
requires_accountant_review  (boolean + reason)
```

These fields drive the VAT summary, VIES export preparation, and the missing-evidence reports in Block 16.

---

## Chart of Accounts

Each business has its own chart of accounts. **MVP ships with a Cyprus-friendly standard chart** that the user can extend or override per business. Account codes are mapped to:

- The 12 transaction types
- Common tag → account associations (e.g., "Software tool" → IT expenses)

Mapping rules are versioned per business so historical periods continue to render correctly even after the chart is changed.

**Accounting method:** **accrual only** in MVP. Revenue is recognized when invoiced (Block 13), not when paid; expenses are recognized when matched to an invoice/receipt, not on bank settlement. Cash basis is not supported in MVP.

**Owner / director / shareholder movements:** represented through **dedicated equity and loan accounts** (Director's Loan Account, Shareholder Capital, etc.) plus the `LOAN_OR_SHAREHOLDER_MOVEMENT` transaction type. This provides the chart-of-accounts entries Cyprus reporting needs.

**Non-deductible expenses:** represented as **separate sub-accounts per category** (e.g., `Travel — deductible` and `Travel — non-deductible`), so reports preserve category visibility for both deductible and non-deductible spending.

**Multi-line invoices:** an invoice with many line items (e.g., an AWS invoice covering 12 services) becomes **one consolidated ledger entry**; the line-item detail is preserved on the underlying `Document` record for drill-down in Block 16.

---

## Accountant Review Flag

The block's role is to apply rules confidently and *flag* (not guess) when rules cannot decide. Cases that get flagged include:

- VAT treatment cannot be determined from available data
- Counterparty country is unclear
- Counterparty VAT number is missing or invalid
- The transaction tag mismatches the inferred VAT logic (e.g., contractor payment with no contract)
- Reverse charge is plausible but not confirmable
- Cross-period adjustment may be needed

A flagged entry remains in the run but is surfaced in Block 14 as a "Possible Tax/VAT Issue". In MVP the flag is advisory — Block 15's finalization does not require accountant signoff (Stage 1 decision) — but the flag is preserved into the finalized archive so the accountant can review historically.

---

## Interfaces

### Inputs
- Typed and tagged transactions from Block 08
- Match records from Block 10 (with extracted document fields from Block 09 reachable through them)
- Per-business chart of accounts and VAT registration profile
- AI explanations through Block 06 (Tier 2 or 3, for reasons only)

### Outputs
- `Draft Ledger Entry` rows in the operational DB
- Review issues for `requires_accountant_review` cases (consumed by Block 14)
- Inputs to Block 15 for finalization
- Inputs to Block 16 for VAT summary, **full VIES file export to current specification**, missing-evidence reports

---

## Operating Rules

- **Principle 3 (AI Assists, Rules Decide):** VAT treatment is determined by rules; AI never picks a treatment.
- **Principle 1 (Workflow-First):** ledger entries are written by registered phases; no UI shortcut creates a ledger entry directly.
- **Principle 2 (Structured Data is Truth):** every entry's compliance fields are stored explicitly, not derived on demand.
- **Principle 5 (Simple Interface):** users see plain-language descriptions of VAT treatment; the eight-value enum is internal.
- **Adjustment runs (Stage 1 decision):** corrections to finalized ledger entries happen via adjustment records carrying explicit reason + delta — never as edits.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Default chart of accounts:** Cyprus-friendly standard + per-business customization — covered in Chart of Accounts.
- **Accounting method:** accrual only in MVP — covered in Chart of Accounts.
- **Owner/director/shareholder movements:** dedicated equity/loan accounts — covered in Chart of Accounts.
- **Non-deductible expenses:** separate sub-accounts per category — covered in Chart of Accounts.
- **VIES scope:** full file export to current specification — covered in Interfaces / Outputs.
- **Multi-line invoices:** one consolidated entry with line detail preserved — covered in Chart of Accounts.

### Deferred

- **Cyprus VAT rate table sourcing and version-stamping** — resolved at sub-doc stage when VAT rules are codified.
- **Mid-period rate change handling** — resolved at sub-doc stage alongside VAT rate sourcing.
