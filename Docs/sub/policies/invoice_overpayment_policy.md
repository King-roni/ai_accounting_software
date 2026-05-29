# Policy: Invoice Overpayment Handling
**Category:** Policies · Block 13 — IN Workflow + Invoice Generator
**Last updated:** 2026-05-17

---

## Definition

An overpayment occurs when the confirmed matched amount for an invoice exceeds the invoice
total by more than the €0.01 rounding tolerance. Formally:

```
overpayment_amount = confirmed_allocation_total - invoice.total_amount
overpayment exists when: overpayment_amount > 0.01
```

Where `confirmed_allocation_total` is the sum of all `invoice_payment_allocations` rows for
the invoice with `status = CONFIRMED`.

Payments within €0.01 of the invoice total are treated as matched-in-full with no overpayment.

---

## Detection

The check is performed by `matching.confirm` at the point of confirming a payment allocation.
Before committing the allocation, the engine calculates the new `confirmed_allocation_total`:

```
new_total = existing_confirmed_allocations + proposed_allocation_amount
if new_total > invoice.total_amount + 0.01:
    overpayment_amount = new_total - invoice.total_amount
    apply overpayment handling policy
```

The allocation is still confirmed in full. The overpayment is not rejected — it is classified
separately.

---

## Auto Write-Off (Threshold <€0.50)

Overpayments with `overpayment_amount < 0.50` are auto-written-off as a rounding adjustment:

- A ledger entry is posted crediting a rounding income account.
- No review issue is created.
- `IN_WORKFLOW_OVERPAYMENT_WRITTEN_OFF` (LOW) is emitted.
- `invoice_payment_allocations.overpayment_disposition = AUTO_WRITTEN_OFF`.

This threshold applies per individual payment match, not cumulatively per client.

---

## Overpayment Handling Options

For overpayments ≥€0.50, the system applies the following logic in priority order:

### Option 1 — Auto-Apply to Another Outstanding Invoice (Preferred)

The system checks for other unpaid or partially-paid invoices from the same client
(`client_id`) within the same accounting period:

```sql
SELECT id, invoice_number, total_amount, amount_due
FROM invoices
WHERE client_id    = '<client_id>'
  AND status       IN ('SENT', 'PARTIALLY_PAID')
  AND period_id    = '<current_period_id>'
  AND id           != '<current_invoice_id>'
ORDER BY due_date ASC
LIMIT 1;
```

If a suitable invoice exists and `overpayment_amount <= candidate.amount_due`:

- A new `invoice_payment_allocations` row is created for the candidate invoice.
- `IN_WORKFLOW_CREDIT_BALANCE_CREATED` (LOW) is not emitted (the excess is consumed
  immediately).
- `IN_WORKFLOW_OVERPAYMENT_DETECTED` (MEDIUM) is emitted with
  `disposition = AUTO_APPLIED_TO_INVOICE`.

If no suitable same-period invoice exists, proceed to Option 2.

### Option 2 — Hold as Credit Balance

If no suitable outstanding invoice exists in the current period:

- A `client_credits` row is created for the `business_entity_id` + `client_id` pair.
- `credit_amount = overpayment_amount`
- `credit_source = OVERPAYMENT`
- `source_invoice_id = <original_invoice_id>`
- `IN_WORKFLOW_CREDIT_BALANCE_CREATED` (LOW) is emitted.
- `IN_WORKFLOW_OVERPAYMENT_DETECTED` (MEDIUM) is emitted with
  `disposition = HELD_AS_CREDIT`.

The credit balance is available for offset against future invoices from the same client.
When a future invoice is issued and confirmed, `matching.confirm` checks for available credit
balances for the client before creating a new bank allocation.

### Option 3 — Manual Review (Fallback)

If Option 1 and Option 2 cannot be completed automatically (e.g., system error, ambiguous
client identity), a review issue is created:

```
review_queue.create_issue(
  issue_type   = 'OVERPAYMENT',
  severity     = 'MEDIUM',
  invoice_id   = '<invoice_id>',
  amount       = <overpayment_amount>,
  description  = 'Overpayment of <amount> on invoice <number>. Manual disposition required.'
)
```

The accountant selects one of three actions:
1. Apply to a specific future invoice (creates a `client_credits` row with
   `reserved_for_invoice_id` set).
2. Write off as `OTHER_INCOME` (see Write-Off section below).
3. Initiate refund (see Refund section below).

---

## Write-Off as OTHER_INCOME

An `OWNER` or `ADMIN` may write off the overpayment as miscellaneous income:

```
ledger.post(
  business_entity_id = '<entity_id>',
  entry_type         = 'OVERPAYMENT_WRITE_OFF',
  amount             = <overpayment_amount>,
  credit_account     = OTHER_INCOME,
  debit_account      = BANK_CLEARING,
  reference_id       = '<invoice_id>',
  memo               = 'Overpayment write-off: invoice <number>'
)
```

`IN_WORKFLOW_OVERPAYMENT_WRITTEN_OFF` (LOW) is emitted with `disposition = MANUAL_WRITE_OFF`.

---

## Refund Process

If the overpayment is to be refunded to the client, the refund is initiated as a manual bank
transfer outside the system. The accountant:

1. Initiates the bank transfer externally.
2. On the next imported bank statement, the outgoing transfer appears as a debit transaction.
3. The accountant matches the debit transaction to the `client_credits` row (or to the
   overpayment review issue) using `matching.confirm` with `match_type = PAYMENT_REFUND`.
4. The `client_credits` row is closed (`status = REFUNDED`).
5. A ledger entry is posted debiting `ACCOUNTS_PAYABLE_OVERPAYMENT` and crediting `BANK`.

---

## VAT Treatment

Overpayments do not affect VAT calculations. VAT is computed on `invoice.total_amount`, not
on the amount received. The excess payment is a balance sheet item, not revenue. No VAT entry
is created for the overpayment amount.

If the overpayment is written off as `OTHER_INCOME`, it is classified as non-taxable other
income and does not attract VAT unless the written-off amount constitutes consideration for a
supply (edge case; escalate to accountant judgment).

---

## Credit Balance Offset on Future Invoices

When a new invoice is being confirmed for a client that has an outstanding `client_credits`
balance:

1. `matching.confirm` detects the credit balance automatically.
2. If `credit_amount >= invoice.total_amount`, the invoice is fully offset and marked
   `PAID` with `payment_method = CREDIT_BALANCE`.
3. If `credit_amount < invoice.total_amount`, the credit is partially applied and the
   remaining balance requires a bank payment.
4. The `client_credits` row is updated: `applied_amount += <offset>`,
   `status = FULLY_APPLIED` or `PARTIALLY_APPLIED`.

---

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `IN_WORKFLOW_OVERPAYMENT_DETECTED` | MEDIUM | Overpayment ≥€0.50 detected on invoice match |
| `IN_WORKFLOW_OVERPAYMENT_WRITTEN_OFF` | LOW | Overpayment written off (auto or manual) |
| `IN_WORKFLOW_CREDIT_BALANCE_CREATED` | LOW | Credit balance created for client |

---

## Cross-References

- `allocation_policy.md`
- `matching_policy.md`
- `invoice_schema.md`
- `invoice_payment_allocations_schema.md`
- `review_issues_schema.md`
- `ledger_entry_schema.md`
