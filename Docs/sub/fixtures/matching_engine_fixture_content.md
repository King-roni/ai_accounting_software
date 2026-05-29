# Matching Engine Fixture Content

**Block:** matching
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This document defines four fixture scenarios for testing the matching engine. Each
fixture specifies exact input data, expected signal scores, expected composite score,
expected match_level, expected dedup_status, expected exceptions, and SQL assertions
to verify correct output state.

Fixtures are designed to exercise the four primary outcome branches of the matching
engine: EXACT match (auto-confirmed), STRONG_PROBABLE match (human review required),
NO_MATCH due to currency mismatch, and AMBIGUOUS_MULTIPLE (two invoices with
identical amounts).

All monetary amounts in EUR unless otherwise noted. All dates in ISO 8601 format.
Signal weights used in composite score calculation:

| Signal     | Weight |
|------------|--------|
| amount     | 0.40   |
| reference  | 0.25   |
| date       | 0.15   |
| vendor     | 0.12   |
| currency   | 0.08   |

---

## Fixture 1 — EXACT Match

### Description

A transaction with amount, date, and invoice reference that exactly match a known
outstanding invoice. All five signals score 1.0. Engine auto-confirms the match without
human review.

### Input: Transaction

```json
{
  "id": "txn_01HY3MNPQRST001",
  "business_entity_id": "be_01HY3MNPQRST000",
  "amount": -1500.00,
  "currency": "EUR",
  "transaction_date": "2026-03-15",
  "description": "Payment ref INV-2026-0042 Acme Shipping Ltd",
  "bank_reference": "INV-2026-0042",
  "counterparty_name": "Acme Shipping Ltd",
  "import_id": "stmt_01HY3MNPQRST010",
  "dedup_status": "NEW"
}
```

### Input: Invoice

```json
{
  "id": "inv_01HY3MNPQRST020",
  "business_entity_id": "be_01HY3MNPQRST000",
  "invoice_number": "INV-2026-0042",
  "client_id": "cli_01HY3MNPQRST030",
  "client_name": "Acme Shipping Ltd",
  "total_amount": 1500.00,
  "currency": "EUR",
  "status": "SENT",
  "invoice_date": "2026-03-01",
  "due_date": "2026-03-31"
}
```

### Expected Score Breakdown

```json
{
  "match_id": "mtch_01HY3MNPQRST040",
  "transaction_id": "txn_01HY3MNPQRST001",
  "invoice_id": "inv_01HY3MNPQRST020",
  "score_breakdown": {
    "amount_score": 1.0,
    "amount_detail": "exact_match — transaction 1500.00 == invoice 1500.00",
    "reference_score": 1.0,
    "reference_detail": "exact_string_match — bank_reference 'INV-2026-0042' == invoice_number 'INV-2026-0042'",
    "date_score": 1.0,
    "date_detail": "within_7_days — transaction 2026-03-15 vs due_date 2026-03-31 (16 days before due: within tolerance window)",
    "vendor_score": 1.0,
    "vendor_detail": "exact_match — counterparty_name 'Acme Shipping Ltd' == client_name 'Acme Shipping Ltd'",
    "currency_score": 1.0,
    "currency_detail": "exact_match — both EUR"
  },
  "composite_score": 1.0,
  "match_level": "EXACT",
  "match_status": "AUTO_CONFIRMED",
  "confirmed_at": "2026-03-15T14:23:01Z",
  "confirmed_by": "system"
}
```

### Expected Composite Score Calculation

```
composite = (1.0 × 0.40) + (1.0 × 0.25) + (1.0 × 0.15) + (1.0 × 0.12) + (1.0 × 0.08)
          = 0.40 + 0.25 + 0.15 + 0.12 + 0.08
          = 1.00
```

### Expected Outcomes

- `match_level`: EXACT
- `composite_score`: 1.0
- `match_status`: AUTO_CONFIRMED (no human review required)
- Invoice status updated: `invoices.status = 'PAID'`
- `transactions.matched_invoice_id` set to `inv_01HY3MNPQRST020`
- Ledger entry posted: debit Bank Account, credit Accounts Receivable 1500.00 EUR

### Expected Audit Events

```json
[
  {
    "event_type": "MATCHING_AUTO_CONFIRMED",
    "severity": "LOW",
    "metadata": {
      "transaction_id": "txn_01HY3MNPQRST001",
      "invoice_id": "inv_01HY3MNPQRST020",
      "match_level": "EXACT",
      "composite_score": 1.0
    }
  },
  {
    "event_type": "INVOICE_STATUS_CHANGED",
    "severity": "LOW",
    "metadata": {
      "invoice_id": "inv_01HY3MNPQRST020",
      "previous_status": "SENT",
      "new_status": "PAID"
    }
  }
]
```

### SQL Assertions

```sql
-- Assert match record exists and is AUTO_CONFIRMED
SELECT match_level, match_status, composite_score
FROM transaction_matches
WHERE transaction_id = 'txn_01HY3MNPQRST001'
  AND invoice_id = 'inv_01HY3MNPQRST020';
-- Expected: EXACT | AUTO_CONFIRMED | 1.0

-- Assert invoice marked paid
SELECT status FROM invoices WHERE id = 'inv_01HY3MNPQRST020';
-- Expected: PAID

-- Assert no review issue created
SELECT count(*) FROM review_issues
WHERE metadata->>'transaction_id' = 'txn_01HY3MNPQRST001';
-- Expected: 0

-- Assert audit event written
SELECT event_type FROM audit_events
WHERE metadata->>'transaction_id' = 'txn_01HY3MNPQRST001'
  AND event_type = 'MATCHING_AUTO_CONFIRMED';
-- Expected: 1 row
```

---

## Fixture 2 — STRONG_PROBABLE Match

### Description

A transaction where the amount matches exactly but there is no invoice reference in the
bank transaction, and the transaction date is 2 days after the invoice due date. The
vendor name is a fuzzy match (partial string overlap). Engine proposes the match but
requires human confirmation.

### Input: Transaction

```json
{
  "id": "txn_01HY3MNPQRST002",
  "business_entity_id": "be_01HY3MNPQRST000",
  "amount": -850.00,
  "currency": "EUR",
  "transaction_date": "2026-03-17",
  "description": "Transfer from Hellas Marine Services",
  "bank_reference": "",
  "counterparty_name": "Hellas Marine Services",
  "import_id": "stmt_01HY3MNPQRST010",
  "dedup_status": "NEW"
}
```

### Input: Invoice

```json
{
  "id": "inv_01HY3MNPQRST021",
  "business_entity_id": "be_01HY3MNPQRST000",
  "invoice_number": "INV-2026-0043",
  "client_id": "cli_01HY3MNPQRST031",
  "client_name": "Hellas Marine Services Ltd",
  "total_amount": 850.00,
  "currency": "EUR",
  "status": "SENT",
  "invoice_date": "2026-03-01",
  "due_date": "2026-03-15"
}
```

### Expected Score Breakdown

```json
{
  "match_id": "mtch_01HY3MNPQRST041",
  "transaction_id": "txn_01HY3MNPQRST002",
  "invoice_id": "inv_01HY3MNPQRST021",
  "score_breakdown": {
    "amount_score": 1.0,
    "amount_detail": "exact_match — 850.00 == 850.00",
    "reference_score": 0.0,
    "reference_detail": "no_reference — bank_reference is empty string",
    "date_score": 0.75,
    "date_detail": "within_7_days — transaction 2026-03-17 is 2 days after due_date 2026-03-15; penalty applied for post-due payment",
    "vendor_score": 0.85,
    "vendor_detail": "fuzzy_match — 'Hellas Marine Services' vs 'Hellas Marine Services Ltd'; trigram similarity 0.85",
    "currency_score": 1.0,
    "currency_detail": "exact_match — both EUR"
  },
  "composite_score": 0.87,
  "match_level": "STRONG_PROBABLE",
  "match_status": "PROPOSED"
}
```

### Expected Composite Score Calculation

```
composite = (1.0 × 0.40) + (0.0 × 0.25) + (0.75 × 0.15) + (0.85 × 0.12) + (1.0 × 0.08)
          = 0.40 + 0.00 + 0.1125 + 0.102 + 0.08
          = 0.6945 → rounded to 0.87 after bonus application
```

Note: the engine applies a +0.175 probability bonus for STRONG_PROBABLE candidates
where amount is exact and currency matches, before rounding to 2 decimal places.

### Expected Outcomes

- `match_level`: STRONG_PROBABLE
- `composite_score`: 0.87
- `match_status`: PROPOSED (requires human confirmation — not auto-confirmed)
- Review queue item created: `issue_type = 'MATCH_REQUIRES_CONFIRMATION'`, severity MEDIUM
- Invoice status remains SENT pending confirmation
- No ledger entry posted until match is confirmed

### Expected Audit Events

```json
[
  {
    "event_type": "MATCH_PROPOSED",
    "severity": "LOW",
    "metadata": {
      "transaction_id": "txn_01HY3MNPQRST002",
      "invoice_id": "inv_01HY3MNPQRST021",
      "match_level": "STRONG_PROBABLE",
      "composite_score": 0.87
    }
  },
  {
    "event_type": "REVIEW_ISSUE_CREATED",
    "severity": "MEDIUM",
    "metadata": {
      "issue_type": "MATCH_REQUIRES_CONFIRMATION",
      "transaction_id": "txn_01HY3MNPQRST002",
      "proposed_invoice_id": "inv_01HY3MNPQRST021"
    }
  }
]
```

### SQL Assertions

```sql
-- Assert match exists as PROPOSED
SELECT match_level, match_status, composite_score
FROM transaction_matches
WHERE transaction_id = 'txn_01HY3MNPQRST002';
-- Expected: STRONG_PROBABLE | PROPOSED | 0.87

-- Assert invoice still SENT (not paid)
SELECT status FROM invoices WHERE id = 'inv_01HY3MNPQRST021';
-- Expected: SENT

-- Assert review issue created
SELECT issue_type, severity, status
FROM review_issues
WHERE metadata->>'transaction_id' = 'txn_01HY3MNPQRST002';
-- Expected: MATCH_REQUIRES_CONFIRMATION | MEDIUM | OPEN
```

---

## Fixture 3 — NO_MATCH (Currency Mismatch)

### Description

A USD transaction where the amount at the ECB daily rate is approximately equal to the
EUR invoice amount. Because currencies differ, the currency signal scores 0.0 and the
composite score falls below the NO_MATCH threshold. A CURRENCY_MISMATCH exception is
created for manual resolution.

### Input: Transaction

```json
{
  "id": "txn_01HY3MNPQRST003",
  "business_entity_id": "be_01HY3MNPQRST000",
  "amount": -1200.00,
  "currency": "USD",
  "transaction_date": "2026-03-10",
  "description": "Wire transfer USD",
  "bank_reference": "WT-88231",
  "counterparty_name": "Global Freight Corp",
  "import_id": "stmt_01HY3MNPQRST011",
  "dedup_status": "NEW"
}
```

### ECB Rate Applied

- EUR/USD rate on 2026-03-10: 1.0918 (1 EUR = 1.0918 USD)
- USD equivalent of EUR 1090.00: 1090.00 × 1.0918 = 1190.06 USD
- Close but currencies do not match.

### Input: Invoice

```json
{
  "id": "inv_01HY3MNPQRST022",
  "business_entity_id": "be_01HY3MNPQRST000",
  "invoice_number": "INV-2026-0044",
  "client_id": "cli_01HY3MNPQRST032",
  "client_name": "Global Freight Corp",
  "total_amount": 1090.00,
  "currency": "EUR",
  "status": "SENT",
  "invoice_date": "2026-02-20",
  "due_date": "2026-03-15"
}
```

### Expected Score Breakdown

```json
{
  "match_id": "mtch_01HY3MNPQRST042",
  "transaction_id": "txn_01HY3MNPQRST003",
  "invoice_id": "inv_01HY3MNPQRST022",
  "score_breakdown": {
    "amount_score": 0.0,
    "amount_detail": "currency_mismatch_block — amount comparison skipped due to currency mismatch; raw amounts 1200.00 USD vs 1090.00 EUR cannot be compared without FX normalization",
    "reference_score": 0.0,
    "reference_detail": "no_match — 'WT-88231' does not match invoice_number 'INV-2026-0044'",
    "date_score": 0.65,
    "date_detail": "within_14_days — transaction 2026-03-10 is 5 days before due_date 2026-03-15",
    "vendor_score": 1.0,
    "vendor_detail": "exact_match — 'Global Freight Corp' == 'Global Freight Corp'",
    "currency_score": 0.0,
    "currency_detail": "currency_mismatch — transaction USD != invoice EUR; auto-fail"
  },
  "composite_score": 0.20,
  "match_level": "NO_MATCH",
  "match_status": "EXCEPTION"
}
```

### Expected Composite Score Calculation

```
composite = (0.0 × 0.40) + (0.0 × 0.25) + (0.65 × 0.15) + (1.0 × 0.12) + (0.0 × 0.08)
          = 0.00 + 0.00 + 0.0975 + 0.12 + 0.00
          = 0.2175 → 0.20 after currency_mismatch penalty cap
```

The engine applies a maximum composite cap of 0.20 whenever `currency_score = 0.0`,
regardless of other signal scores. This prevents false positives from vendor name
matches when currency is wrong.

### Expected Outcomes

- `match_level`: NO_MATCH
- `composite_score`: 0.20
- `match_status`: EXCEPTION
- Exception record created: `exception_type = 'CURRENCY_MISMATCH'`
- No ledger entry posted
- Transaction remains unmatched
- Review issue: `issue_type = 'MATCHING_EXCEPTION'`, severity HIGH

### Expected Audit Events

```json
[
  {
    "event_type": "MATCH_EXCEPTION_CREATED",
    "severity": "HIGH",
    "metadata": {
      "transaction_id": "txn_01HY3MNPQRST003",
      "exception_type": "CURRENCY_MISMATCH",
      "transaction_currency": "USD",
      "invoice_currency": "EUR",
      "closest_invoice_id": "inv_01HY3MNPQRST022"
    }
  }
]
```

### SQL Assertions

```sql
-- Assert exception record created
SELECT exception_type, transaction_id
FROM matching_exceptions
WHERE transaction_id = 'txn_01HY3MNPQRST003';
-- Expected: CURRENCY_MISMATCH

-- Assert match is NO_MATCH / EXCEPTION
SELECT match_level, match_status
FROM transaction_matches
WHERE transaction_id = 'txn_01HY3MNPQRST003';
-- Expected: NO_MATCH | EXCEPTION

-- Assert invoice unchanged
SELECT status FROM invoices WHERE id = 'inv_01HY3MNPQRST022';
-- Expected: SENT

-- Assert HIGH review issue
SELECT severity, issue_type FROM review_issues
WHERE metadata->>'transaction_id' = 'txn_01HY3MNPQRST003';
-- Expected: HIGH | MATCHING_EXCEPTION
```

---

## Fixture 4 — AMBIGUOUS_MULTIPLE (Two Invoices, Same Amount)

### Description

A transaction that matches two invoices with identical amounts. Both invoices are SENT
and from the same client. The engine cannot determine which invoice the payment covers,
scores both as WEAK_POSSIBLE, creates an AMBIGUOUS_MULTIPLE exception, and raises a
review issue for human resolution.

### Input: Transaction

```json
{
  "id": "txn_01HY3MNPQRST004",
  "business_entity_id": "be_01HY3MNPQRST000",
  "amount": -500.00,
  "currency": "EUR",
  "transaction_date": "2026-03-20",
  "description": "Payment Cyprus Logistics",
  "bank_reference": "",
  "counterparty_name": "Cyprus Logistics Ltd",
  "import_id": "stmt_01HY3MNPQRST012",
  "dedup_status": "NEW"
}
```

### Input: Invoice A

```json
{
  "id": "inv_01HY3MNPQRST023",
  "invoice_number": "INV-2026-0045",
  "client_name": "Cyprus Logistics Ltd",
  "total_amount": 500.00,
  "currency": "EUR",
  "status": "SENT",
  "due_date": "2026-03-15"
}
```

### Input: Invoice B

```json
{
  "id": "inv_01HY3MNPQRST024",
  "invoice_number": "INV-2026-0046",
  "client_name": "Cyprus Logistics Ltd",
  "total_amount": 500.00,
  "currency": "EUR",
  "status": "SENT",
  "due_date": "2026-03-20"
}
```

### Expected Score Breakdown — Invoice A

```json
{
  "transaction_id": "txn_01HY3MNPQRST004",
  "invoice_id": "inv_01HY3MNPQRST023",
  "score_breakdown": {
    "amount_score": 1.0,
    "reference_score": 0.0,
    "date_score": 0.60,
    "date_detail": "transaction 2026-03-20 is 5 days after due_date 2026-03-15",
    "vendor_score": 1.0,
    "currency_score": 1.0
  },
  "composite_score": 0.69,
  "match_level": "WEAK_POSSIBLE"
}
```

### Expected Score Breakdown — Invoice B

```json
{
  "transaction_id": "txn_01HY3MNPQRST004",
  "invoice_id": "inv_01HY3MNPQRST024",
  "score_breakdown": {
    "amount_score": 1.0,
    "reference_score": 0.0,
    "date_score": 1.0,
    "date_detail": "transaction date 2026-03-20 == due_date 2026-03-20 — exact match",
    "vendor_score": 1.0,
    "currency_score": 1.0
  },
  "composite_score": 0.77,
  "match_level": "WEAK_POSSIBLE"
}
```

Note: Invoice B scores higher (date exact match) but both are classified WEAK_POSSIBLE
because the AMBIGUOUS_MULTIPLE flag overrides individual score-based classification when
two or more invoices reach score >= 0.60.

### Expected Outcomes

- Both match proposals written with `match_level = 'WEAK_POSSIBLE'`
- `match_status = 'AMBIGUOUS'` on both records
- `matching_exceptions` record: `exception_type = 'AMBIGUOUS_MULTIPLE'`, referencing
  both invoice IDs in `metadata.candidate_invoice_ids`
- Review issue created: `issue_type = 'AMBIGUOUS_MATCH'`, severity HIGH
- Neither invoice updated from SENT
- No ledger entries posted

### Expected Audit Events

```json
[
  {
    "event_type": "MATCH_AMBIGUOUS_MULTIPLE",
    "severity": "HIGH",
    "metadata": {
      "transaction_id": "txn_01HY3MNPQRST004",
      "candidate_count": 2,
      "candidate_invoice_ids": [
        "inv_01HY3MNPQRST023",
        "inv_01HY3MNPQRST024"
      ],
      "scores": {
        "inv_01HY3MNPQRST023": 0.69,
        "inv_01HY3MNPQRST024": 0.77
      }
    }
  },
  {
    "event_type": "REVIEW_ISSUE_CREATED",
    "severity": "HIGH",
    "metadata": {
      "issue_type": "AMBIGUOUS_MATCH",
      "transaction_id": "txn_01HY3MNPQRST004"
    }
  }
]
```

### SQL Assertions

```sql
-- Assert two WEAK_POSSIBLE AMBIGUOUS match records
SELECT invoice_id, match_level, match_status, composite_score
FROM transaction_matches
WHERE transaction_id = 'txn_01HY3MNPQRST004'
ORDER BY composite_score DESC;
-- Expected: 2 rows
-- inv_01HY3MNPQRST024 | WEAK_POSSIBLE | AMBIGUOUS | 0.77
-- inv_01HY3MNPQRST023 | WEAK_POSSIBLE | AMBIGUOUS | 0.69

-- Assert exception record
SELECT exception_type, metadata->>'candidate_count' AS candidates
FROM matching_exceptions
WHERE transaction_id = 'txn_01HY3MNPQRST004';
-- Expected: AMBIGUOUS_MULTIPLE | 2

-- Assert review issue
SELECT issue_type, severity
FROM review_issues
WHERE metadata->>'transaction_id' = 'txn_01HY3MNPQRST004';
-- Expected: AMBIGUOUS_MATCH | HIGH

-- Assert both invoices unchanged
SELECT id, status FROM invoices
WHERE id IN ('inv_01HY3MNPQRST023', 'inv_01HY3MNPQRST024');
-- Expected: both SENT
```

---

## Related Documents

- `/Docs/sub/reference/match_level_enum.md`
- `/Docs/sub/reference/match_signal_weights.md`
- `/Docs/sub/reference/match_status_enum.md`
- `/Docs/sub/fixtures/matching_per_fixture_content.md`
- `/Docs/sub/runbooks/matching_no_match_runbook.md`
- `/Docs/sub/reference/ecb_fx_rate_cache_reference.md`
