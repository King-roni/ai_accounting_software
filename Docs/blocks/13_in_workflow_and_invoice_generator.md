# Block 13 — IN / Income Workflow + Invoice Generator

## Role in the System

This block has two distinct sub-systems that are intentionally bundled because one feeds the other:

1. **Invoice Generator** — a continuous, on-demand tool for creating, sending, and tracking invoices. Runs throughout the month, not as a workflow phase.
2. **IN Workflow (`IN_MONTHLY`)** — a periodic pipeline that matches incoming bank payments against invoices the Invoice Generator has produced and ends with a finalized monthly income ledger.

Splitting them into separate blocks would force constant cross-references — every IN_MONTHLY phase that consumes invoices would need to point at the generator's data model, and every invoice lifecycle transition would need to anticipate IN matching. Keeping them together makes the income side of the platform legible as a single concern.

---

## Scope

### In scope
- The Invoice Generator: invoice creation, lifecycle, recurring invoices, credit notes, PDF generation, numbering
- The `IN_MONTHLY` workflow type definition: phase sequence, gates, tool invocations
- Income-specific matching logic (partial / overpayment / multi-invoice patterns)
- Income-specific VAT handling (output VAT, VIES, reverse-charge text)
- The `IN_ADJUSTMENT` variant for corrections to finalized income periods

### Out of scope (covered elsewhere)
- Engine mechanics → Block 03
- Bank statement parsing → Block 07
- Transaction classification → Block 08
- General document intake (the generator produces structured invoices natively, not via Block 09's intake) → Block 09
- General matching engine → Block 10 (the IN matching variant lives there)
- General ledger and Cyprus VAT → Block 11
- AI End-Scan → Block 06
- Review queue UI → Block 14
- Finalization → Block 15

---

## Part A — Invoice Generator

### Role
The Invoice Generator is the system's source of truth for outgoing invoices. It is the canonical place an invoice is born, edited, sent, paid, credited, or written off. Every invoice consumed by IN matching originates here.

### Capabilities

- **Client database** — name, country, VAT number, billing address, default currency, default payment terms, default reverse-charge applicability.
- **Invoice composition** — invoice number (per-business sequence), issue date, supply/service date, payment terms, due date, line items with quantity/unit/price, currency, VAT treatment per line, subtotal, VAT amount, total.
- **VAT-aware rendering** — applies the correct Cyprus VAT treatment for the client's country and VAT-number status; emits the required reverse-charge text where applicable.
- **PDF rendering** — generates the human-facing invoice PDF from the structured record (Principle 2 — structured first, PDF second).
- **Pro-forma vs. tax invoice distinction.**
- **Recurring invoice templates** — monthly retainers, quarterly subscriptions, etc. The generator produces a fresh invoice on the configured cadence; users can review before sending.
- **Credit notes** — issued against an existing invoice, carrying explicit reference and amount; treated as negative-side ledger movements by Block 11.

### Invoice Lifecycle

```text
DRAFT
  → SENT
  → PAYMENT_EXPECTED
     → PARTIALLY_PAID
     → PAID
     → OVERPAID
     → REFUNDED
     → WRITTEN_OFF
  → CREDITED            (credit note issued)
  → FINALIZED           (period containing this invoice locks)
```

Most lifecycle transitions are driven by the IN workflow's matching results — `SENT` → `PAID` happens when a matched payment is confirmed. Some transitions are user-initiated (issuing a credit note, writing off an unpaid invoice).

`FINALIZED` is terminal: once the IN period containing the invoice locks, the invoice record itself becomes immutable. Corrections require an IN_ADJUSTMENT run.

### Numbering

The default invoice numbering format is **`INV-YYYY-NNNN`** per business — strict sequential within each business and year (e.g., `INV-2026-0001`). The format is auditable, easy to verify for gaps, and matches typical Cyprus invoice conventions.

Numbers are issued only when an invoice is moved out of `DRAFT`; deletion of a draft does not consume a number. Gaps in issued numbers are not permitted — voiding an issued invoice produces a credit note rather than a deletion.

**Credit notes** use a **separate per-business sequence** with format **`CN-YYYY-NNNN`**, distinct from the invoice sequence. This makes the credit-note vs. invoice distinction visually obvious in records and reports.

### Recurring Invoices

Recurring invoice templates are evaluated by a **background scheduler that runs daily**. When a template's next due date falls due, the scheduler generates a fresh invoice (in `DRAFT` or `SENT` depending on the template's auto-send setting). This is decoupled from the IN_MONTHLY run, so mid-month cadences (weekly retainers, etc.) work cleanly and don't depend on closeout timing.

### Multi-Currency Invoicing

Invoices are **locked in their issued currency at creation** and remain in that currency through the entire lifecycle. There is no mid-flight repricing to the client's preferred currency. If a client pays in a different currency, the FX is handled at the matching engine using the bank-recorded rate (per the Stage 1 FX rate decision).

---

## Part B — IN_MONTHLY Workflow

### Workflow Type Registration

`IN_MONTHLY` is a **static workflow type** compiled into the engine, with per-business config for optional phases. It runs against a single business and accounting period.

**Triggers:**
- **Manual.** User selects business + period and starts the run.
- **Event.** A successful statement upload triggers `IN_MONTHLY` alongside `OUT_MONTHLY`. INGESTION and CLASSIFICATION are shared and run once.

### Phase Sequence

```text
1.  INGESTION                 → Block 07 (shared with OUT)
2.  CLASSIFICATION            → Block 08 (shared with OUT)
3.  IN_FILTER                 → select IN-relevant transaction types
4.  INCOME_MATCHING           → Block 10 (variant: matches against Invoice records)
5.  INCOME_LEDGER_PREPARATION → Block 11 (income-side ledger paths)
6.  VAT_CLASSIFICATION        → Block 11 (output VAT, VIES, reverse-charge text)
7.  AI_END_SCAN               → Block 06 (income-specific checks)
8.  HUMAN_REVIEW_HOLD         → gated; only enters if blocking issues exist
9.  FINALIZATION              → Block 15
```

`IN_MONTHLY` does **not** run document discovery (email or Drive — Block 09's intake paths). Income matching consumes `Invoice` records produced by this block's Invoice Generator, not externally discovered documents. This is why Block 09 is not invoked from `IN_MONTHLY`.

### Type Set for IN_FILTER

```text
IN_INCOME                          → matches against issued invoices
REFUND_IN                          → matches against original outgoing transaction
UNKNOWN (with positive direction)  → flagged; user resolves (income, internal transfer, shareholder injection, etc.)
```

The taxonomy is closed (Block 08): there is no separate `UNKNOWN_POSITIVE` type. IN_FILTER selects `UNKNOWN`-typed rows whose direction is positive.

`INTERNAL_TRANSFER` and `LOAN_OR_SHAREHOLDER_MOVEMENT` rows on the IN side are recognized but processed by their type-specific ledger paths in Block 11, not by income matching.

`REFUND_OUT` is processed by OUT_FILTER (Block 12), not by IN_FILTER. Refund routing is symmetric across the two workflows — each refund stays on the side that matches its money-flow direction.

### Income Matching Outcomes

The income matching variant of Block 10 produces:

```text
FULL_MATCH                       — payment matches exactly one invoice's total
PARTIAL_PAYMENT                  — payment is less than the invoice total
OVERPAYMENT                      — payment exceeds the invoice total
MULTIPLE_INVOICES_ONE_PAYMENT    — single payment covers several invoices
ONE_INVOICE_MULTIPLE_PAYMENTS    — single invoice paid in installments
NO_MATCH                         — payment received without a corresponding invoice
POSSIBLE_REFUND_OR_TRANSFER      — incoming amount more likely a refund or internal transfer
```

Each outcome drives a specific invoice lifecycle transition and review-queue behavior.

**Allocation policy for `MULTIPLE_INVOICES_ONE_PAYMENT`:** the engine proposes the most likely allocation across affected invoices but **always requires user confirmation** before applying. Allocations have downstream consequences (which invoice ages, which gets credit-noted), so they are never applied silently.

**Pro-forma invoices in matching:** pro-forma invoices **cannot generate matching candidates**. The IN workflow requires a tax invoice for matching to proceed. When a deposit arrives against a pro-forma, the user converts the pro-forma to a tax invoice (which inherits the pro-forma's line items and a fresh tax-invoice number from the `INV-YYYY-NNNN` sequence), and matching proceeds against the tax invoice.

**Written-off invoices** post a **bad debt expense** when transitioned to `WRITTEN_OFF`. Block 11's ledger logic handles the offset against the original receivable. This is the standard Cyprus accounting treatment and produces clean P&L visibility.

---

## Gate Conditions (per phase exit)

- **INGESTION / CLASSIFICATION:** same as OUT (shared phases).
- **IN_FILTER exit:** IN-relevant subset identified.
- **INCOME_MATCHING exit:** every IN-relevant transaction has a matching outcome.
- **INCOME_LEDGER_PREPARATION exit:** every IN transaction has draft income ledger entries OR is typed as no-ledger-needed (e.g., `INTERNAL_TRANSFER`).
- **VAT_CLASSIFICATION exit:** every draft entry has a VAT treatment OR is flagged `requires_accountant_review`. VIES-relevant entries flagged.
- **AI_END_SCAN exit:** end-scan complete; income-specific issues raised.
- **HUMAN_REVIEW_HOLD exit:** zero blocking issues open AND user approval recorded.
- **FINALIZATION exit:** archive package built; invoice records affected by this period transition to `FINALIZED`; dashboard refresh enqueued.

---

## End-Scan Checks Specific to IN

Block 06's End-Scan, when running on an `IN_MONTHLY` run, checks:

- Invoice created but unpaid past due date
- Payment received without an invoice
- Invoice paid with wrong amount (partial or over)
- Payment in wrong currency
- Duplicate payment against the same invoice
- Late payment (past due date when received)
- Missing client VAT number on a VIES-relevant invoice
- Reverse-charge text missing where required
- Credit note required (e.g., overpayment + refund needed)
- Refund not connected to the original transaction
- Unusual income transaction (large outlier, unexpected counterparty)

All issues route through the same six-bucket grouping in Block 14 — no IN-specific UI taxonomy.

---

## IN_ADJUSTMENT Variant

Symmetric with OUT_ADJUSTMENT. Adjustments to a finalized IN period produce additive adjustment records carrying explicit reason + delta; original records remain untouched. Common cases include retroactive credit notes, reclassifying a `POSSIBLE_REFUND_OR_TRANSFER` after evidence emerges, and correcting a wrong-period assignment.

---

## Interfaces

### Inputs
- Invoice creation requests from the UI (Invoice Generator)
- Workflow start requests (manual or event-based) for `IN_MONTHLY`
- Tool registrations from Blocks 06–11

### Outputs
- `Invoice` records produced by the generator (operational DB)
- Invoice PDFs in Raw Upload
- A `Workflow Run` record (Block 03) for each IN_MONTHLY execution
- Income-side ledger entries, match records, review issues
- A finalized IN archive package via Block 15
- Audit events for every state transition

---

## Operating Rules

- **Principle 1 (Workflow-First):** the IN workflow advances state; UI does not bypass phases. The Invoice Generator is the exception — invoice creation is its own continuous process, not a workflow phase, but every invoice transition still emits an audit event via Block 05.
- **Principle 2 (Structured Data is Truth):** invoice PDFs are generated from the structured invoice record, never re-parsed back.
- **Principle 3 (AI Assists, Rules Decide):** matching outcomes are determined by deterministic scoring; AI rewrites or explains.
- **Principle 5 (Simple Interface):** invoice statuses shown in plain language; the lifecycle enum is internal.
- **Stage 1 decisions applied:** accrual accounting (revenue recognized when invoiced, not when paid); VIES export to current specification in MVP; full file format produced.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Invoice numbering:** `INV-YYYY-NNNN` per business — covered in Numbering.
- **Recurring cadence:** daily background scheduler — covered in Recurring Invoices.
- **Credit note numbering:** separate `CN-YYYY-NNNN` sequence — covered in Numbering.
- **Multi-currency invoices:** locked at issued currency through lifecycle — covered in Multi-Currency Invoicing.
- **Multi-invoice payment allocation:** always requires user confirmation — covered in Income Matching Outcomes.
- **Pro-forma matching:** only after conversion to tax invoice — covered in Income Matching Outcomes.
- **Written-off treatment:** bad debt expense — covered in Income Matching Outcomes.

No open questions remain at the architecture level. Phase docs will define exact lifecycle transition triggers, the recurring-template UI, and the conversion flow from pro-forma to tax invoice.
