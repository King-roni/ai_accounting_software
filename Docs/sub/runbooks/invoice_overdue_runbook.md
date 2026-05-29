# Runbook: Invoice Overdue Management

**Block:** in_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook describes the five-step process for detecting, chasing, escalating, writing off,
and legally documenting overdue invoices. An invoice becomes `OVERDUE` when its `due_date` has
passed and its status remains `SENT` or `PARTIALLY_PAID`.

Under Cyprus accrual accounting, output VAT is due on the invoice date regardless of whether
the invoice has been paid. Overdue invoices must still be included in the VAT return for the
period in which they were issued. This runbook covers the operational steps but does not replace
the VAT return process — see `vat_return_schema.md` and `vat_recalculation_runbook.md`.

---

## Step 1: Detect Overdue Invoices

### Scheduled Job

A nightly scheduled job (Supabase cron, 00:05 UTC) transitions eligible invoices to `OVERDUE`:

```sql
-- Transition SENT invoices that have passed their due_date
UPDATE invoices
SET    status    = 'OVERDUE',
       updated_at = now()
WHERE  status    = 'SENT'
  AND  due_date  < CURRENT_DATE
  AND  remaining_balance > 0;

-- Transition PARTIALLY_PAID invoices that have passed their due_date
UPDATE invoices
SET    status    = 'OVERDUE',
       updated_at = now()
WHERE  status    = 'PARTIALLY_PAID'
  AND  due_date  < CURRENT_DATE
  AND  remaining_balance > 0;
```

The job logs the count of transitioned invoices. If the count exceeds 50 in a single run, a
`MEDIUM` severity alert is raised for the accountant to review (possible bulk billing issue or
job catch-up after outage).

### Pre-Due Reminders

`business_settings.reminder_days_before_due` controls pre-due reminder dispatch. Default: 7
days before `due_date`. If set to 0, pre-due reminders are disabled.

```sql
-- Pre-due reminder candidates
SELECT id, invoice_number, client_id, due_date, remaining_balance
FROM invoices
WHERE status = 'SENT'
  AND due_date = CURRENT_DATE + business_settings.reminder_days_before_due
  AND remaining_balance > 0;
```

Pre-due reminders are sent via `email_delivery_integration.md` using the `invoice_reminder_pre`
template. They are logged in `invoice_activity_log` but do not emit an `INVOICE_OVERDUE` audit
event (the invoice has not yet crossed the due date).

### Overdue Detection Query for Manual Review

```sql
SELECT
  i.id,
  i.invoice_number,
  i.due_date,
  i.remaining_balance,
  i.status,
  (CURRENT_DATE - i.due_date) AS days_overdue,
  c.name AS client_name,
  c.email AS client_email
FROM invoices i
JOIN clients c ON c.id = i.client_id
WHERE i.status = 'OVERDUE'
  AND i.business_id = :business_id
ORDER BY i.due_date ASC;
```

---

## Step 2: Send Reminders

### Reminder Schedule

| Reminder | Trigger | Template |
|---|---|---|
| Reminder 1 | `due_date` (day invoice becomes overdue) | `invoice_overdue_r1` |
| Reminder 2 | `due_date + 7 days` | `invoice_overdue_r2` |
| Reminder 3 | `due_date + 14 days` | `invoice_overdue_r3_final` |

All reminders are dispatched via `email_delivery_integration.md`. Each dispatch is logged in
`invoice_activity_log` with `activity_type = 'REMINDER_SENT'` and `reminder_number = 1|2|3`.

### Reminder Schedule Query

```sql
-- Invoices due for Reminder 1 (just became overdue, no prior reminder)
SELECT i.id
FROM invoices i
LEFT JOIN invoice_activity_log ial
  ON ial.invoice_id = i.id AND ial.activity_type = 'REMINDER_SENT'
WHERE i.status = 'OVERDUE'
  AND (CURRENT_DATE - i.due_date) = 0
  AND ial.id IS NULL;

-- Invoices due for Reminder 2 (7+ days overdue, only R1 sent)
SELECT i.id
FROM invoices i
JOIN invoice_activity_log r1
  ON r1.invoice_id = i.id AND r1.activity_type = 'REMINDER_SENT' AND r1.reminder_number = 1
LEFT JOIN invoice_activity_log r2
  ON r2.invoice_id = i.id AND r2.activity_type = 'REMINDER_SENT' AND r2.reminder_number = 2
WHERE i.status = 'OVERDUE'
  AND (CURRENT_DATE - i.due_date) >= 7
  AND r2.id IS NULL;

-- Invoices due for Reminder 3 (14+ days overdue, R1 and R2 sent, no R3)
SELECT i.id
FROM invoices i
JOIN invoice_activity_log r2
  ON r2.invoice_id = i.id AND r2.activity_type = 'REMINDER_SENT' AND r2.reminder_number = 2
LEFT JOIN invoice_activity_log r3
  ON r3.invoice_id = i.id AND r3.activity_type = 'REMINDER_SENT' AND r3.reminder_number = 3
WHERE i.status = 'OVERDUE'
  AND (CURRENT_DATE - i.due_date) >= 14
  AND r3.id IS NULL;
```

### Reminder Suppression

Reminders are suppressed if:
- `business_settings.reminders_enabled = false`
- The client has `clients.reminder_opt_out = true`
- The invoice has `invoices.reminder_suppressed = true` (manual suppression by accountant)

---

## Step 3: Escalation Options

After Reminder 3 (14 days past due), the invoice is surfaced to the accountant in the review
queue with issue type `OVERDUE_ESCALATION`. The accountant chooses from three escalation paths:

### Option A: Manual Follow-Up

The accountant contacts the client directly (phone, email, or meeting). Communication is logged
as a note on the client record via `tool_clients_registry.md`. No automated action.

### Option B: Late Payment Interest

Under Cyprus Late Payment Law (Law 123(I)/2012, implementing EU Directive 2011/7/EU):

- Interest accrues from 30 days after the invoice date (B2B) or 60 days after invoice date
  (public authority).
- Interest rate: ECB reference rate + 8 percentage points, revised every 6 months.
  - Example (2025 H1): ECB rate 3.15% + 8% = 11.15% per annum.
- Interest is calculated on a daily basis:
  `daily_interest = remaining_balance * (ecb_rate + 0.08) / 365`

To add late payment interest to an overdue invoice:
1. Create a new invoice line via `tool_invoice_lifecycle_integration.md` (or amend the original
   if still in an amendable state per `invoice_amendment_policy.md`).
2. Line description: "Late payment interest — [days] days at [rate]% per annum."
3. VAT rate: 0% (interest is VAT-exempt under Cyprus VAT Law).
4. Post to Chart of Accounts: `LATE_PAYMENT_INCOME` account.

### Option C: Debt Collection Referral

If the debt is deemed unrecoverable after good-faith attempts:
1. Export the invoice PDF and all reminder correspondence from the Operational zone.
2. Provide the exported package to the appointed debt collection agency or legal counsel.
3. Mark the invoice with `invoices.debt_collection_referred = true` and log the referral date.
4. Continue to include the invoice in VAT returns until it is written off or paid.

---

## Step 4: Bad Debt Write-Off

If the debt is confirmed unrecoverable (debt collection failed, debtor insolvent, or
statute of limitations reached):

### Step 4a: Void the Invoice

Call `in_workflow.void_invoice` with:
```
void_reason: "Bad debt write-off — unrecoverable after [N] days. [Context]."
```

Voiding removes the invoice from the accounts receivable balance.

### Step 4b: Create Bad Debt Expense Entry

Call `tool_bad_debt_expense.md` to post the write-off:

```json
{
  "business_id":    "<uuid>",
  "invoice_id":     "<uuid>",
  "amount_eur":     1250.00,
  "write_off_date": "2025-11-30",
  "reason":         "Debt unrecoverable after 90 days and referral to collection agency."
}
```

This posts a double-entry:
```
DEBIT  Bad Debt Expense (P&L — OPEX)      1250.00
CREDIT Accounts Receivable (Balance Sheet) 1250.00
```

### Step 4c: VAT Adjustment

Under Cyprus VAT Law (Law 95(I)/2000, Article 17), a business can claim back output VAT on
bad debts if:
- The debt is more than 12 months old from the supply date.
- The business has written off the debt in its books.
- All reasonable steps have been taken to recover the debt.

File a VAT adjustment in the next VAT return. Flag via `vat_recalculation_runbook.md`. The
adjustment reduces output VAT for the period.

---

## Step 5: Legal Documentation and VAT Return Obligation

### Records Retention

All communication records related to overdue invoices — reminders, escalation notes, debt
collection correspondence, court filings — must be retained in the Operational zone for a
minimum of 7 years from the invoice date, per Cyprus Companies Law Cap. 113 and
`data_retention_policy.md`.

Records are stored in:
```
s3://operational-zone/<business_id>/invoices/<invoice_id>/correspondence/
```

### VAT Return Obligation (Cyprus Accrual Basis)

Under Cyprus accrual accounting:
- **Output VAT is due on the invoice date**, not the payment date.
- Overdue invoices must be included in the VAT return for the period in which they were issued.
- The fact that a client has not paid does not defer the VAT liability.
- Recovery of VAT on bad debts (Step 4c) requires a separate adjustment in a subsequent return.

**SQL check: overdue invoices in current VAT period**

```sql
SELECT
  i.id,
  i.invoice_number,
  i.invoice_date,
  i.vat_amount_eur,
  i.status,
  i.remaining_balance,
  i.vat_return_id
FROM invoices i
WHERE i.business_id = :business_id
  AND i.status      = 'OVERDUE'
  AND i.invoice_date BETWEEN :vat_period_start AND :vat_period_end
  AND i.vat_return_id IS NULL;  -- not yet included in a VAT return
```

Any row returned here indicates an overdue invoice that has not yet been added to the VAT
return. This is a blocking issue in the VAT return preparation workflow.

### Audit Events Generated During This Runbook

| Event | Severity | Step |
|---|---|---|
| `INVOICE_OVERDUE` | LOW | Step 1 — nightly status transition |
| `INVOICE_REMINDER_SENT` | LOW | Step 2 — each reminder dispatch |
| `INVOICE_OVERDUE_ESCALATED` | MEDIUM | Step 3 — escalation flag set |
| `INVOICE_BAD_DEBT_WRITTEN_OFF` | HIGH | Step 4 — write-off recorded |
| `INVOICE_VOIDED` | MEDIUM | Step 4a — void called |
| `VAT_ADJUSTMENT_REQUIRED` | MEDIUM | Step 5 — VAT bad debt recovery flagged |

---

## Escalation Contacts

| Severity | Action |
|---|---|
| Invoice 30+ days overdue | Accountant manual review |
| Invoice 60+ days overdue | Notify business owner; recommend Option B or C |
| Invoice 90+ days overdue | Recommend Option C (debt collection) or Step 4 (write-off) |

---

## Related Documents

- `invoice_schema.md` — invoice status machine and overdue fields
- `vat_return_schema.md` — VAT return and invoice inclusion
- `vat_recalculation_runbook.md` — VAT adjustment after void or write-off
- `tool_bad_debt_expense.md` — bad debt write-off tool
- `tool_invoice_void.md` — void tool (Step 4a)
- `data_retention_policy.md` — 7-year retention requirement
- `invoice_overpayment_policy.md` — overpayment handling
- `emit_audit_api.md` — audit event contract
- `invoice_amendment_policy.md` — rules for amending sent invoices
