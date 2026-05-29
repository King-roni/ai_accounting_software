# income_outcome_enum

**Category:** Reference data · Block 08 — Classification  
**Owner:** classification  
**Last updated:** 2026-05-17

---

## 1. Purpose

Reference for the `income_outcome_enum` Postgres type. This enum classifies every transaction as an inflow (income), an outflow (expense), an intra-business transfer, an internal movement, or unclassified. The value is used by the classification engine, the matching engine, and the VAT treatment pipeline to route each transaction to the correct processing path.

---

## 2. Type Definition

```sql
CREATE TYPE income_outcome_enum AS ENUM (
  'INCOME',
  'EXPENSE',
  'TRANSFER',
  'INTERNAL',
  'UNKNOWN'
);
```

---

## 3. Value Definitions

| Value | Description |
|---|---|
| `INCOME` | Money received by the business. Maps to credit entries on revenue accounts. Matched against sales invoices. Output VAT applies. |
| `EXPENSE` | Money paid out by the business. Maps to debit entries on expense accounts. Matched against vendor/purchase invoices. Input VAT applies. |
| `TRANSFER` | Intra-business movement between two accounts owned by the same business (e.g., EUR account to USD account, or operating account to savings account). No VAT. Not matched against invoices. |
| `INTERNAL` | Internal accounting entries: payroll, owner draws, inter-company loans, depreciation. No external invoice counterpart. Excluded from matching engine. |
| `UNKNOWN` | Pre-classification state. Set when the transaction is first ingested and before the classification engine runs. Matching is deferred until `UNKNOWN` is resolved. |

---

## 4. How the Value Is Set

### 4.1 Classification Engine

The classification engine (Block 08) determines `income_outcome` based on:

1. **Account normal_side from Chart of Accounts:**
   - If the transaction's counterparty account has `normal_side = CREDIT` → `INCOME`
   - If the transaction's counterparty account has `normal_side = DEBIT` → `EXPENSE`

2. **Vendor memory lookup:** If a counterparty has a confirmed `income_outcome` from prior transactions, that value is used as the default (with confidence boost).

3. **AI classification (Layer 2/3):** When the rule-based and memory paths do not resolve to INCOME or EXPENSE, AI classification provides a suggestion with confidence score.

4. **Manual override:** Owner/Admin may override the classification via the review queue. An overridden value is tagged `MANUAL_OVERRIDE` and takes precedence over all automated paths.

### 4.2 TRANSFER Detection

`TRANSFER` is set when:
- Both the source account (`transactions.account_id`) and the destination account (from counterparty resolution) are owned by the same `business_id`.
- The system detects bilateral intra-business movements via `INTERNAL_TRANSFER_DETECTED` / `INTERNAL_TRANSFER_BILATERAL_LINKED`.

### 4.3 INTERNAL Detection

`INTERNAL` is set when the counterparty is classified as an internal entity (payroll provider, owner entity, or linked company in the same org), determined by counterparty resolution flags.

---

## 5. Matching Engine Integration

The `income_outcome` value gates the matching engine's invoice search space:

| income_outcome | Invoice search space |
|---|---|
| `INCOME` | Sales invoices: `invoice_type IN ('TAX_INVOICE', 'PRO_FORMA')` for the same `business_id` |
| `EXPENSE` | Vendor invoices: `invoice_type = 'VENDOR'` for the same `business_id` |
| `TRANSFER` | Excluded from matching. No `match_record` is created. |
| `INTERNAL` | Excluded from matching. No `match_record` is created. |
| `UNKNOWN` | Matching deferred. A review issue `CLASSIFICATION_PENDING` is raised. |

The matching engine (Block 10) reads `transactions.income_outcome` before constructing the candidate invoice set. A transaction with `UNKNOWN` classification that reaches the MATCHING phase without being resolved will block that phase with a BLOCKING gate failure.

---

## 6. VAT Treatment Integration

`income_outcome` is an input to `ledger.compute_vat_amounts`:

| income_outcome | VAT direction | VAT account |
|---|---|---|
| `INCOME` | Output VAT (VAT collected from customer) | VAT Output Control (code `2401`) |
| `EXPENSE` | Input VAT (VAT paid to supplier, recoverable) | VAT Input Control (code `2402`) |
| `TRANSFER` | No VAT | N/A |
| `INTERNAL` | Context-dependent (payroll has no VAT; inter-company may have VAT) | Determined by transaction sub-type |
| `UNKNOWN` | Cannot determine VAT treatment | Blocks `VAT_TREATMENT_DECIDED` event |

See `vat_treatment_policy.md` for full VAT treatment rules including EU reverse charge and exempt categories.

---

## 7. IN Workflow and OUT Workflow Routing

The `income_outcome` enum also routes transactions to the correct workflow type:

- `INCOME` transactions are processed by the `IN_MONTHLY` workflow (Block 13 — Income workflow).
- `EXPENSE` transactions are processed by the `OUT_MONTHLY` workflow (Block 12 — Expense workflow).
- `TRANSFER` and `INTERNAL` transactions are processed in a simplified ledger path with no matching or invoice integration.
- `UNKNOWN` transactions are held in the `CLASSIFICATION_HOLD` phase until resolved.

The `Docs/blocks/13_in_workflow_and_invoice_generator.md` and `Docs/blocks/12_out_workflow.md` documents define the full phase sequences for each workflow type.

---

## 8. Enum Value Constraints

- A transaction cannot remain in `UNKNOWN` status past the `LEDGER_POST` phase gate. The gate `engine.gate_classification_complete` checks that no `UNKNOWN` rows exist for the run.
- `TRANSFER` and `INTERNAL` values are set only by the classification engine or via the bilateral transfer linking tool (`ledger.link_internal_transfer`). Manual override to `TRANSFER` is not permitted (risk of hiding income).
- The enum value is stored on the `transactions` table in the `income_outcome` column. It is set by `classification.apply_classification` and may be updated by `classification.manual_override` (INCOME and EXPENSE only).

---

## 9. Column Placement

```sql
-- On the transactions table:
income_outcome   income_outcome_enum   NOT NULL DEFAULT 'UNKNOWN'
```

The default `UNKNOWN` ensures every new transaction starts in the pre-classification state and requires explicit classification before ledger posting.

---

## 10. Cross-References

- `schemas/match_records_schema.md` — `income_outcome` determines which invoice type is searched
- `reference/match_level_enum.md` — match level enum used alongside income_outcome in matching
- `vat_treatment_policy.md` — VAT direction determined by income_outcome
- `matching_engine_policy.md` — candidate invoice search gated on income_outcome
- `tool_classification_apply.md` — sets income_outcome during classification phase
- `in_workflow.md` — INCOME transaction processing workflow
- `out_workflow.md` — EXPENSE transaction processing workflow
- `audit_event_taxonomy.md` — `CLASSIFICATION_LAYER_1_DECIDED`, `CLASSIFICATION_LAYER_2_DECIDED`, `CLASSIFICATION_LAYER_3_DECIDED`
