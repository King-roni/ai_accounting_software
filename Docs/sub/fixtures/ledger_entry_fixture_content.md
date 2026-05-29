# Ledger Entry Fixture Content

**Category:** Fixtures · **Block:** Ledger · **Stage:** 4 sub-doc (Layer 2)
**Status:** Draft · **Last updated:** 2026-05-17

Test fixture data for double-entry ledger scenarios. Each example provides complete
`ledger_entries` table rows grouped under a `journal_entry_id`, with totals balance check.

All amounts are EUR. Cyprus chart of accounts codes used throughout. Rounding uses
`HALF_UP` rounding to two decimal places. UUIDs follow `gen_uuid_v7()` format.

Business context: `business_id = 018f4e2a-0000-7000-8000-000000000001`, VAT number
`CY10012345L`, quarterly filing. `period_id = 018f4e2a-0001-7000-8000-000000000001`
(Q1 2026: 2026-01-01 to 2026-03-31). `run_id = 01900000-0001-7000-8000-000000000001`.

---

## Cyprus Chart of Accounts Reference (Used Below)

| Code | Account Name                      | Type      |
|------|-----------------------------------|-----------|
| 1100 | Bank — ING Cyprus Current         | Asset     |
| 1200 | Accounts Receivable               | Asset     |
| 2100 | Accounts Payable                  | Liability |
| 2300 | VAT Output                        | Liability |
| 2400 | VAT Input                         | Asset     |
| 2500 | VAT Payable                       | Liability |
| 6100 | Professional Services Expense     | Expense   |

---

## Example 1 — Sales Invoice Payment Received

**Scenario:** Customer pays Invoice INV-2026-0042 in full. EUR 5,000.00 net + EUR 950.00
VAT (19%) = EUR 5,950.00 total. Payment clears Accounts Receivable to Bank. A paired VAT
settlement entry moves the output VAT balance to VAT Payable.

`journal_entry_id = 01900001-0000-7000-8000-000000000001`

```sql
INSERT INTO ledger_entries
  (id, journal_entry_id, business_id, period_id, account_code, account_name,
   entry_type, debit_amount, credit_amount, currency, description,
   transaction_date, run_id, created_at)
VALUES
  -- Debit Bank
  ('01900001-0001-7000-8000-000000000001',
   '01900001-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '1100', 'Bank — ING Cyprus Current', 'DEBIT',
   5950.00, 0.00, 'EUR',
   'Payment received: INV-2026-0042 — Acme Ltd',
   '2026-02-14', '01900000-0001-7000-8000-000000000001', '2026-02-14T10:22:00Z'),
  -- Credit Accounts Receivable
  ('01900001-0001-7000-8000-000000000002',
   '01900001-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '1200', 'Accounts Receivable', 'CREDIT',
   0.00, 5950.00, 'EUR',
   'Payment received: INV-2026-0042 — Acme Ltd',
   '2026-02-14', '01900000-0001-7000-8000-000000000001', '2026-02-14T10:22:00Z'),
  -- Debit VAT Output (VAT settlement)
  ('01900001-0001-7000-8000-000000000003',
   '01900001-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '2300', 'VAT Output', 'DEBIT',
   950.00, 0.00, 'EUR',
   'VAT settlement on payment: INV-2026-0042',
   '2026-02-14', '01900000-0001-7000-8000-000000000001', '2026-02-14T10:22:01Z'),
  -- Credit VAT Payable
  ('01900001-0001-7000-8000-000000000004',
   '01900001-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '2500', 'VAT Payable', 'CREDIT',
   0.00, 950.00, 'EUR',
   'VAT settlement on payment: INV-2026-0042',
   '2026-02-14', '01900000-0001-7000-8000-000000000001', '2026-02-14T10:22:01Z');
```

**Totals balance check:** Debits 5950.00 + 950.00 = 6,900.00. Credits 5950.00 + 950.00 =
6,900.00. BALANCED.

---

## Example 2 — Supplier Invoice Recorded

**Scenario:** Supplier invoice received — Deloitte Advisory, Jan 2026 retainer.
EUR 3,000.00 net + EUR 570.00 VAT (19%) = EUR 3,570.00. Expense recorded; input VAT
captured for recovery; liability in Accounts Payable.

`journal_entry_id = 01900002-0000-7000-8000-000000000001`

```sql
INSERT INTO ledger_entries
  (id, journal_entry_id, business_id, period_id, account_code, account_name,
   entry_type, debit_amount, credit_amount, currency, description,
   transaction_date, run_id, created_at)
VALUES
  -- Debit Expense
  ('01900002-0001-7000-8000-000000000001',
   '01900002-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '6100', 'Professional Services Expense', 'DEBIT',
   3000.00, 0.00, 'EUR',
   'Supplier invoice: Deloitte Advisory — Jan 2026 retainer',
   '2026-01-31', '01900000-0001-7000-8000-000000000001', '2026-01-31T16:05:00Z'),
  -- Debit VAT Input
  ('01900002-0001-7000-8000-000000000002',
   '01900002-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '2400', 'VAT Input', 'DEBIT',
   570.00, 0.00, 'EUR',
   'Input VAT: Deloitte Advisory',
   '2026-01-31', '01900000-0001-7000-8000-000000000001', '2026-01-31T16:05:00Z'),
  -- Credit Accounts Payable
  ('01900002-0001-7000-8000-000000000003',
   '01900002-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '2100', 'Accounts Payable', 'CREDIT',
   0.00, 3570.00, 'EUR',
   'Supplier invoice payable: Deloitte Advisory',
   '2026-01-31', '01900000-0001-7000-8000-000000000001', '2026-01-31T16:05:00Z');
```

**Totals balance check:** Debits 3000.00 + 570.00 = 3,570.00. Credits 3,570.00. BALANCED.

---

## Example 3 — Period-End VAT Settlement

**Scenario:** Q1 2026 period-end. VAT Output (collected) = EUR 8,750.00. VAT Input
(recoverable) = EUR 2,850.00. Net payable to Tax Department = EUR 5,900.00. Both VAT
accounts are cleared; net posts to VAT Payable.

`journal_entry_id = 01900003-0000-7000-8000-000000000001`

```sql
INSERT INTO ledger_entries
  (id, journal_entry_id, business_id, period_id, account_code, account_name,
   entry_type, debit_amount, credit_amount, currency, description,
   transaction_date, run_id, created_at)
VALUES
  -- Debit VAT Output (clear balance)
  ('01900003-0001-7000-8000-000000000001',
   '01900003-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '2300', 'VAT Output', 'DEBIT',
   8750.00, 0.00, 'EUR',
   'Period-end VAT settlement Q1 2026 — clear VAT Output',
   '2026-03-31', '01900000-0001-7000-8000-000000000001', '2026-03-31T23:59:00Z'),
  -- Credit VAT Input (clear balance)
  ('01900003-0001-7000-8000-000000000002',
   '01900003-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '2400', 'VAT Input', 'CREDIT',
   0.00, 2850.00, 'EUR',
   'Period-end VAT settlement Q1 2026 — clear VAT Input',
   '2026-03-31', '01900000-0001-7000-8000-000000000001', '2026-03-31T23:59:00Z'),
  -- Credit VAT Payable (net due)
  ('01900003-0001-7000-8000-000000000003',
   '01900003-0000-7000-8000-000000000001',
   '018f4e2a-0000-7000-8000-000000000001',
   '018f4e2a-0001-7000-8000-000000000001',
   '2500', 'VAT Payable', 'CREDIT',
   0.00, 5900.00, 'EUR',
   'Period-end VAT settlement Q1 2026 — net payable',
   '2026-03-31', '01900000-0001-7000-8000-000000000001', '2026-03-31T23:59:00Z');
```

**Totals balance check:** Debits 8,750.00. Credits 2,850.00 + 5,900.00 = 8,750.00.
BALANCED.

**Verification assertions:**
- `vat_periods.vat_output_total = 8750.00`
- `vat_periods.vat_input_total = 2850.00`
- `vat_periods.vat_payable_total = 5900.00`
- `SELECT COUNT(*) FROM ledger_entries WHERE journal_entry_id =
  '01900003-0000-7000-8000-000000000001'` returns 3.

---

## Related Documents

- `fixtures/vat_calculation_fixture_content.md` — VAT calculation fixture scenarios
- `runbooks/ledger_imbalance_runbook.md` — resolving ledger imbalances
- `runbooks/ledger_live_integration_runbook.md` — live integration tests for ledger
- `reference/vat_account_code_reference.md` — Cyprus chart of accounts VAT codes
