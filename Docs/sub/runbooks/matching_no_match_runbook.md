# Matching NO_MATCH Runbook

**Block:** Matching
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook defines the response procedure when one or more transactions in a workflow run reach `NO_MATCH` status after the matching engine has completed its proposal phase. `NO_MATCH` is not an error — it is a normal matching outcome for transactions that have no corresponding invoice in the system. However, unresolved `NO_MATCH` transactions with no documented exception block run finalization.

This runbook applies to both `in_workflow` (income matching) and `out_workflow` (expense matching) runs. The responsible party is the accountant assigned to the run, with escalation to the business owner if a resolution requires creating new invoices or writing off amounts.

**SLA:** `NO_MATCH` transactions in a run must be resolved or documented within 5 business days of the matching phase completing. Runs with open `NO_MATCH` issues older than 5 business days are escalated automatically to the business owner via notification.

## Prerequisites

- Access to the review queue for the run.
- `ACCOUNTANT` or `ORG_OWNER` role in the business.
- The workflow run must be in `REVIEW_HOLD` status. If the run is in another status, contact the run owner.

## Impact on Finalization

The finalization gate (`tool_finalization_gate_check.md`) evaluates the following predicate before allowing a run to advance to `FINALIZING`:

```sql
SELECT COUNT(*) = 0
FROM match_proposals mp
WHERE mp.run_id = :run_id
  AND mp.match_level = 'NO_MATCH'
  AND (
    mp.exception_documented = false
    OR mp.exception_documented IS NULL
  );
```

If this returns false (i.e. there are `NO_MATCH` proposals without a documented exception), the run cannot be finalized. The finalization gate check returns a `BLOCKING` issue of type `UNRESOLVED_NO_MATCH`. Every `NO_MATCH` transaction must either be:
- Linked to a correct invoice via `matching.confirm_match`, OR
- Documented as a known exception via `matching.reject_match` with `exception_documented = true`.

A NO_MATCH transaction that is explicitly documented does not block finalization. Silence does.

---

## Step 1: Identify NO_MATCH Transactions

### 1.1 Query the Matching Proposals Table

```sql
SELECT
  mp.id                    AS proposal_id,
  mp.transaction_id,
  t.value_date,
  t.amount,
  t.currency,
  t.description            AS bank_description,
  mp.match_level,
  me.exception_type,
  me.exception_detail
FROM match_proposals mp
JOIN transactions t ON t.id = mp.transaction_id
LEFT JOIN matching_exceptions me ON me.proposal_id = mp.id
WHERE mp.run_id = :run_id
  AND mp.match_level = 'NO_MATCH'
ORDER BY t.value_date ASC;
```

### 1.2 Check the Review Queue

In the review queue, filter by:
- `run_id = :run_id`
- `issue_type = 'NO_MATCH_TRANSACTION'`

Each `NO_MATCH` transaction should have a corresponding review issue. If a transaction shows `NO_MATCH` in `match_proposals` but has no review issue, this indicates a workflow anomaly — raise it with engineering and continue with the manual steps below.

### 1.3 Check the Matching Exceptions Table

```sql
SELECT
  me.proposal_id,
  me.exception_type,
  me.exception_detail,
  me.created_at
FROM matching_exceptions me
JOIN match_proposals mp ON mp.id = me.proposal_id
WHERE mp.run_id = :run_id
  AND mp.match_level = 'NO_MATCH';
```

Common `exception_type` values:

| exception_type | Meaning |
|---|---|
| `NO_CANDIDATE` | No invoice in the system matches any signal from this transaction. |
| `AMBIGUOUS_MULTIPLE` | Two or more invoices scored equally — the engine could not select one. |
| `CURRENCY_MISMATCH` | Payment currency differs from all candidate invoice currencies. |
| `AMOUNT_OUT_OF_RANGE` | Payment amount does not fall within any invoice amount + tolerance band. |
| `PERIOD_MISMATCH` | Best-matching invoice belongs to a different (locked) period. |
| `COUNTERPARTY_NOT_FOUND` | Counterparty could not be resolved from bank reference or description. |

---

## Step 2: Diagnose by Exception Type

Work through each `NO_MATCH` transaction using the exception type as the starting point.

### NO_CANDIDATE

The engine found no invoices with any overlapping signals.

Checks to perform:
1. Is the transaction a **cash sale**? Cash sales may have no invoice. Check with the business owner.
2. Is there a **pro-forma invoice** that was never converted to a final invoice?
3. Was the transaction processed in the **wrong period**? Check whether the invoice exists in an adjacent period's run.
4. Is the transaction a **bank charge or fee** that should be classified directly rather than matched?
5. Is the counterparty a **new vendor** whose invoices have not yet been uploaded?

### AMBIGUOUS_MULTIPLE

Two invoices scored equally and the engine could not break the tie.

Checks to perform:
1. Review both candidate invoices in the review issue detail. The UI shows both candidates side by side.
2. Check `invoice.payment_reference` against the bank statement's reference field — this is often the tiebreaker.
3. Check invoice dates vs. payment date — the closer invoice date is usually the correct match.
4. Ask the business owner which invoice this payment covers if the documentary evidence is ambiguous.

### CURRENCY_MISMATCH

The payment arrived in a different currency than the invoice.

Checks to perform:
1. Confirm whether the business operates in multiple currencies and whether this is expected.
2. Check whether the invoice has a multi-currency equivalent (some invoices are issued in USD but accepted in EUR).
3. Apply `tool_fx_convert.md` manually to compute the EUR equivalents of both amounts and check whether they agree within 2% (the `STRONG_PROBABLE` FX tolerance defined in `fx_conversion_policy.md`).
4. If amounts agree within tolerance: use `matching.confirm_match` to link them. The FX_DIFF entry will be created automatically.

### PERIOD_MISMATCH

The best candidate invoice belongs to a period that is already locked.

Checks to perform:
1. Confirm whether the invoice in the locked period is genuinely unpaid or was already matched to a different payment.
2. If the invoice is unpaid: the period may need to be reopened via `tool_period_lock.md` (ADMIN action). Escalate to the business owner.
3. If the payment is a late receipt for a prior-period invoice: this is a legitimate prior-period adjustment. Document with `matching.reject_match` and create an adjustment entry referencing the original invoice.

---

## Step 3: Resolution Options

Choose the appropriate resolution for each `NO_MATCH` transaction.

### Option A: Link to Existing Invoice

Use when you have identified the correct invoice and the engine simply failed to find it.

```
Tool: matching.confirm_match
Inputs:
  proposal_id: :proposal_id
  invoice_id: :correct_invoice_id
  confirmed_by: :user_id
  confirmation_note: "Manually matched: [reason]"
```

After confirmation:
- `match_proposals.match_level` updates to `EXACT` or `STRONG_PROBABLE` based on signal agreement.
- `match_proposals.confirmed_by` and `confirmed_at` are populated.
- The review issue is resolved.
- Audit event `MATCH_MANUALLY_CONFIRMED` (LOW) is emitted.

### Option B: Create a New Invoice

Use when the transaction represents a genuine sale or expense for which no invoice was ever created in the system.

1. Navigate to the invoice creation screen for the business.
2. Create the invoice with the correct counterparty, amount, and period.
3. Return to the review queue and use Option A to link the new invoice to the transaction.

Note: creating an invoice for a period that is not the current run's period may require accountant approval. New invoices should match the transaction's `value_date` period unless there is a documented reason for a different invoice date.

### Option C: Classify as Unmatched Income/Expense

Use when no invoice exists and none should be created (e.g. a bank interest payment, a government grant, a refund from an unknown source).

1. Classify the transaction directly via `tool_classification_apply.md` without matching.
2. Assign to the appropriate chart of accounts category (e.g. `OTHER_INCOME`, `BANK_CHARGES`, `MISCELLANEOUS_EXPENSE`).
3. Call `matching.reject_match` with `exception_documented = true` and a detailed note explaining why no invoice is expected.
4. The review issue is resolved with status `EXCEPTION_DOCUMENTED`.

### Option D: Defer to Next Period

Use when the corresponding invoice is expected to arrive after the current run closes (e.g. a supplier invoice is in transit).

1. Call `matching.reject_match` with `exception_documented = true` and `deferral_reason` set to the expected invoice arrival date and reference.
2. Add a note in the run's adjustment log cross-referencing the deferred transaction.
3. In the next period's run, flag this transaction reference in the matching engine setup so it is prioritized.

Deferral does not delete the transaction from the current period. The transaction is posted to a `DEFERRED_MATCHING` holding account and reversed into the next period via an adjustment entry.

---

## Step 4: Document Exceptions

For every `NO_MATCH` transaction resolved via Options C or D, a formal exception record must be created. This is required for the finalization gate to pass.

```
Tool: matching.reject_match
Inputs:
  proposal_id: :proposal_id
  rejection_reason: TEXT (minimum 20 characters)
  exception_documented: true
  exception_type: [NO_INVOICE_EXPECTED | DEFERRED | CASH_SALE | BANK_CHARGE | OTHER]
  exception_detail: TEXT (free text, minimum 30 characters for OTHER type)
```

After calling `matching.reject_match` with `exception_documented = true`:
- Audit event `MATCHING_EXCEPTION_DOCUMENTED` (LOW) is emitted.
- The `match_proposals.exception_documented` flag is set to `true`.
- The finalization gate predicate passes for this transaction.
- The review issue transitions to status `RESOLVED`.

Do not close a review issue manually before calling `matching.reject_match`. The issue should be resolved through the tool call, not through the review queue UI directly, to maintain the audit trail.

---

## Step 5: Prevent Recurrence

After resolving all `NO_MATCH` transactions in the run, perform a brief root cause review to reduce future occurrences.

### Invoice Date vs. Payment Date Alignment

Review whether invoices were issued with due dates that fall outside the current period. If invoices are consistently dated one or two periods after the payments they correspond to, the invoice creation workflow needs adjustment.

```sql
SELECT
  inv.id,
  inv.issue_date,
  inv.due_date,
  t.value_date AS payment_date,
  (t.value_date - inv.issue_date) AS days_lag
FROM invoices inv
JOIN match_proposals mp ON mp.invoice_id = inv.id
JOIN transactions t ON t.id = mp.transaction_id
WHERE mp.run_id = :run_id
  AND mp.match_level IN ('EXACT', 'STRONG_PROBABLE')
ORDER BY days_lag DESC
LIMIT 20;
```

A consistently high `days_lag` (over 60 days) indicates that invoices are being created well after payments are received, which will produce `NO_MATCH` outcomes in future runs until the invoice is uploaded.

### Bank Statement Period Coverage

Verify that bank statement uploads cover the full period without gaps. Gaps in bank statement coverage cause valid transactions to be absent from a run, leading to NO_CANDIDATE outcomes in the following run.

```sql
SELECT
  MIN(value_date) AS earliest,
  MAX(value_date) AS latest,
  COUNT(*) AS row_count
FROM transactions
WHERE run_id = :run_id
  AND business_id = :business_id;
```

Compare `earliest` and `latest` against the period start and end dates. Any gap of more than 3 calendar days at the start or end of the period should be investigated.

### VIES Counterparty Records

For `NO_CANDIDATE` outcomes where the counterparty is an EU business, verify that the counterparty's VAT number is recorded and validated in the system. Unregistered counterparties produce weaker matching signals and are more likely to produce `NO_MATCH` outcomes.

Run `ledger.validate_vies` for any EU counterparties appearing in `NO_MATCH` transactions that lack a `vies_record` entry.

---

## Escalation

If all 5 steps are completed and one or more `NO_MATCH` transactions cannot be resolved because:
- The business owner cannot identify the transaction source.
- The amount is significant (> €1,000) and the exception type is `OTHER`.
- The transaction has characteristics suggesting fraud or unauthorized access.

Escalate via the review queue escalation action (severity HIGH) and notify the business owner with a formal written explanation request. Do not advance the run to finalization with a BLOCKING issue outstanding.

## Related Documents

- `matching_policy.md` — overall matching logic and signal weights
- `match_proposal_schema.md` — match_proposals table DDL
- `matching_exception_schema.md` — matching_exceptions table DDL
- `tool_match_confirm.md` — confirm a manual match
- `tool_match_reject.md` — reject with exception documentation
- `tool_classification_apply.md` — classify an unmatched transaction
- `finalization_gate_sql_schema.md` — gate predicate for NO_MATCH blocking
- `out_exception_documented_policy.md` — policy for documented exceptions
- `fx_conversion_policy.md` — FX tolerance for multi-currency matching
- `matching_live_integration_runbook.md` — end-to-end matching testing
- `ledger_imbalance_runbook.md` — if exception resolution creates a debit/credit imbalance
