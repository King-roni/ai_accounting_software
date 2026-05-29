# VAT Calculation Fixture Content

**Block:** ledger
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This document defines three VAT calculation fixture scenarios for the ledger and reporting engine test suite. Each fixture specifies the input transaction set, expected ledger entries, expected VAT return fields, and SQL assertions. Fixtures are deterministic: all amounts are fixed; no randomisation is used.

All fixtures assume a Cyprus-registered business entity (`business_id = 018f4e2a-0000-7000-8000-000000000001`) with VAT number `CY10012345L`, filing quarterly.

VAT account codes reference `/sub/reference/vat_account_code_reference.md`. Ledger entry format follows the double-entry schema in the codebase.

---

## Fixture 1 — Standard Quarterly VAT (Cyprus Domestic)

### Purpose

Validates a clean quarterly VAT calculation with a single domestic rate (19%) on both sales and purchases. No intra-EU transactions. Net payable position.

### Input: Sales Transactions (Output VAT)

```json
[
  {
    "fixture_id": "vat-001-s01",
    "transaction_type": "INVOICE_ISSUED",
    "invoice_id": "018f5a01-0001-7000-8001-000000000001",
    "amount_excl_vat": 46052.63,
    "vat_rate": 0.19,
    "vat_amount": 8750.00,
    "amount_incl_vat": 54802.63,
    "currency": "EUR",
    "period": "2026-Q1",
    "category": "CONSULTING_REVENUE"
  }
]
```

Total output VAT: **€8,750.00**
Total sales excl. VAT: **€46,052.63**

### Input: Purchase Transactions (Input VAT)

```json
[
  {
    "fixture_id": "vat-001-p01",
    "transaction_type": "EXPENSE",
    "transaction_id": "018f5a01-0002-7000-8001-000000000002",
    "amount_excl_vat": 15000.00,
    "vat_rate": 0.19,
    "vat_amount": 2850.00,
    "amount_incl_vat": 17850.00,
    "currency": "EUR",
    "period": "2026-Q1",
    "category": "PROFESSIONAL_SERVICES"
  }
]
```

Total input VAT: **€2,850.00**
Total purchases excl. VAT: **€15,000.00**

### Expected Net VAT Position

```
Output VAT (Box 1A):     €8,750.00
Input VAT  (Box 3):      €2,850.00
Net VAT payable (Box 4): €5,900.00
```

### Expected Ledger Entries

```json
[
  {
    "entry_id": "le-vat001-01",
    "description": "Output VAT 19% — Q1 2026",
    "debit_account": "1100_ACCOUNTS_RECEIVABLE",
    "credit_account": "2200_VAT_OUTPUT_19",
    "amount": 8750.00,
    "currency": "EUR",
    "period": "2026-Q1"
  },
  {
    "entry_id": "le-vat001-02",
    "description": "Input VAT 19% — Q1 2026",
    "debit_account": "1300_VAT_INPUT_19",
    "credit_account": "2100_ACCOUNTS_PAYABLE",
    "amount": 2850.00,
    "currency": "EUR",
    "period": "2026-Q1"
  },
  {
    "entry_id": "le-vat001-03",
    "description": "VAT control account settlement — Q1 2026",
    "debit_account": "2200_VAT_OUTPUT_19",
    "credit_account": "1300_VAT_INPUT_19",
    "amount": 2850.00,
    "currency": "EUR",
    "period": "2026-Q1",
    "note": "Offset input against output"
  },
  {
    "entry_id": "le-vat001-04",
    "description": "Net VAT payable — Q1 2026",
    "debit_account": "2200_VAT_OUTPUT_19",
    "credit_account": "2300_VAT_PAYABLE",
    "amount": 5900.00,
    "currency": "EUR",
    "period": "2026-Q1"
  }
]
```

### VAT Control Account Balance Check

After settlement:
- `2200_VAT_OUTPUT_19` balance: €0 (fully offset + transferred to payable)
- `1300_VAT_INPUT_19` balance: €0 (fully offset)
- `2300_VAT_PAYABLE` balance: **€5,900.00** (payable to Tax Department)

### Expected VAT Return Fields

| Box | Label | Value |
|---|---|---|
| 1A | Taxable sales at 19% | €46,052.63 |
| 1B | Output VAT at 19% | €8,750.00 |
| 3 | Total input VAT | €2,850.00 |
| 4 | Net VAT payable (1B minus 3) | €5,900.00 |
| 8 | VIES value | €0.00 |

### Expected Audit Events

```json
[
  {
    "event_type": "VAT_CALCULATION_RUN",
    "severity": "LOW",
    "metadata": {
      "period": "2026-Q1",
      "output_vat": 8750.00,
      "input_vat": 2850.00,
      "net_payable": 5900.00
    }
  },
  {
    "event_type": "LEDGER_ENTRIES_POSTED",
    "severity": "LOW",
    "metadata": {
      "entry_count": 4,
      "period": "2026-Q1"
    }
  }
]
```

---

## Fixture 2 — Mixed Rate VAT Period

### Purpose

Validates a period with both 19% standard rate and 9% reduced rate (restaurant/hospitality services) sales, and standard 19% input VAT. Tests that the engine correctly segregates output VAT by rate and combines them for the net payable.

### Input: Sales Transactions

```json
[
  {
    "fixture_id": "vat-002-s01",
    "transaction_type": "INVOICE_ISSUED",
    "invoice_id": "018f5a02-0001-7000-8002-000000000001",
    "amount_excl_vat": 12000.00,
    "vat_rate": 0.19,
    "vat_amount": 2280.00,
    "amount_incl_vat": 14280.00,
    "currency": "EUR",
    "period": "2026-Q1",
    "category": "CONSULTING_REVENUE"
  },
  {
    "fixture_id": "vat-002-s02",
    "transaction_type": "INVOICE_ISSUED",
    "invoice_id": "018f5a02-0002-7000-8002-000000000002",
    "amount_excl_vat": 3000.00,
    "vat_rate": 0.09,
    "vat_amount": 270.00,
    "amount_incl_vat": 3270.00,
    "currency": "EUR",
    "period": "2026-Q1",
    "category": "RESTAURANT_REVENUE"
  }
]
```

### Input: Purchase Transactions

```json
[
  {
    "fixture_id": "vat-002-p01",
    "transaction_type": "EXPENSE",
    "transaction_id": "018f5a02-0003-7000-8002-000000000003",
    "amount_excl_vat": 4500.00,
    "vat_rate": 0.19,
    "vat_amount": 855.00,
    "amount_incl_vat": 5355.00,
    "currency": "EUR",
    "period": "2026-Q1",
    "category": "COST_OF_GOODS"
  }
]
```

### Expected VAT Breakdown

```
Output VAT 19% (on €12,000):    €2,280.00
Output VAT 9%  (on €3,000):       €270.00
Total output VAT:               €2,550.00

Input VAT 19% (on €4,500):        €855.00

Net VAT payable:                €1,695.00
```

### Expected Ledger Entries

```json
[
  {
    "entry_id": "le-vat002-01",
    "description": "Output VAT 19% — Q1 2026",
    "debit_account": "1100_ACCOUNTS_RECEIVABLE",
    "credit_account": "2200_VAT_OUTPUT_19",
    "amount": 2280.00,
    "currency": "EUR",
    "period": "2026-Q1"
  },
  {
    "entry_id": "le-vat002-02",
    "description": "Output VAT 9% — Q1 2026",
    "debit_account": "1100_ACCOUNTS_RECEIVABLE",
    "credit_account": "2201_VAT_OUTPUT_09",
    "amount": 270.00,
    "currency": "EUR",
    "period": "2026-Q1"
  },
  {
    "entry_id": "le-vat002-03",
    "description": "Input VAT 19% — Q1 2026",
    "debit_account": "1300_VAT_INPUT_19",
    "credit_account": "2100_ACCOUNTS_PAYABLE",
    "amount": 855.00,
    "currency": "EUR",
    "period": "2026-Q1"
  },
  {
    "entry_id": "le-vat002-04",
    "description": "VAT offset — input against 19% output — Q1 2026",
    "debit_account": "2200_VAT_OUTPUT_19",
    "credit_account": "1300_VAT_INPUT_19",
    "amount": 855.00,
    "currency": "EUR",
    "period": "2026-Q1"
  },
  {
    "entry_id": "le-vat002-05",
    "description": "Net VAT payable (19% remainder + 9%) — Q1 2026",
    "debit_account": "2200_VAT_OUTPUT_19",
    "credit_account": "2300_VAT_PAYABLE",
    "amount": 1425.00,
    "currency": "EUR",
    "period": "2026-Q1",
    "note": "€2280 - €855 offset = €1425"
  },
  {
    "entry_id": "le-vat002-06",
    "description": "Transfer 9% output VAT to payable — Q1 2026",
    "debit_account": "2201_VAT_OUTPUT_09",
    "credit_account": "2300_VAT_PAYABLE",
    "amount": 270.00,
    "currency": "EUR",
    "period": "2026-Q1"
  }
]
```

### VAT Control Account Balance Check

After all entries:
- `2200_VAT_OUTPUT_19`: €0
- `2201_VAT_OUTPUT_09`: €0
- `1300_VAT_INPUT_19`: €0
- `2300_VAT_PAYABLE`: **€1,695.00**

### Expected VAT Return Fields

| Box | Label | Value |
|---|---|---|
| 1A | Taxable sales at 19% | €12,000.00 |
| 1B | Output VAT at 19% | €2,280.00 |
| 1C | Taxable sales at 9% | €3,000.00 |
| 1D | Output VAT at 9% | €270.00 |
| 3 | Total input VAT | €855.00 |
| 4 | Net VAT payable | €1,695.00 |

---

## Fixture 3 — Intra-EU Period (VIES Included)

### Purpose

Validates a period containing both domestic sales (with 19% output VAT) and intra-EU service supplies to Germany (zero-rated, reverse charge, VIES reportable). Tests that the engine correctly zero-rates the EU supply, excludes it from output VAT, and populates the VIES report.

### Input: Sales Transactions

```json
[
  {
    "fixture_id": "vat-003-s01",
    "transaction_type": "INVOICE_ISSUED",
    "invoice_id": "018f5a03-0001-7000-8003-000000000001",
    "amount_excl_vat": 20000.00,
    "vat_rate": 0.19,
    "vat_amount": 3800.00,
    "amount_incl_vat": 23800.00,
    "currency": "EUR",
    "period": "2026-Q2",
    "category": "CONSULTING_REVENUE",
    "customer_country_code": "CY",
    "vies_eligible": false,
    "reverse_charge": false
  },
  {
    "fixture_id": "vat-003-s02",
    "transaction_type": "INVOICE_ISSUED",
    "invoice_id": "018f5a03-0002-7000-8003-000000000002",
    "amount_excl_vat": 15000.00,
    "vat_rate": 0,
    "vat_amount": 0.00,
    "amount_incl_vat": 15000.00,
    "currency": "EUR",
    "period": "2026-Q2",
    "category": "CONSULTING_REVENUE",
    "customer_country_code": "DE",
    "customer_vat_number": "DE811184117",
    "vies_eligible": true,
    "reverse_charge": true
  }
]
```

### Input: Purchase Transactions

No purchase transactions in this fixture (testing output VAT only).

### Expected VAT Breakdown

```
Domestic sales 19% (on €20,000):   output VAT €3,800.00
EU supply to DE (zero-rated):       output VAT €0.00
────────────────────────────────────────────────────────
Total output VAT:                              €3,800.00
Total input VAT:                                   €0.00
Net VAT payable:                               €3,800.00

VIES reportable value:                        €15,000.00 (to DE)
```

### Expected Ledger Entries

```json
[
  {
    "entry_id": "le-vat003-01",
    "description": "Output VAT 19% domestic — Q2 2026",
    "debit_account": "1100_ACCOUNTS_RECEIVABLE",
    "credit_account": "2200_VAT_OUTPUT_19",
    "amount": 3800.00,
    "currency": "EUR",
    "period": "2026-Q2"
  },
  {
    "entry_id": "le-vat003-02",
    "description": "Intra-EU supply zero-rated — Q2 2026 (reverse charge, no VAT entry)",
    "debit_account": "1100_ACCOUNTS_RECEIVABLE",
    "credit_account": "4000_INTRAEU_REVENUE",
    "amount": 15000.00,
    "currency": "EUR",
    "period": "2026-Q2",
    "note": "Zero VAT per Art. 11 reverse charge. No VAT account movement."
  },
  {
    "entry_id": "le-vat003-03",
    "description": "Net VAT payable — Q2 2026",
    "debit_account": "2200_VAT_OUTPUT_19",
    "credit_account": "2300_VAT_PAYABLE",
    "amount": 3800.00,
    "currency": "EUR",
    "period": "2026-Q2"
  }
]
```

### Expected VAT Return Fields

| Box | Label | Value |
|---|---|---|
| 1A | Taxable sales at 19% (domestic) | €20,000.00 |
| 1B | Output VAT at 19% | €3,800.00 |
| 2A | Intra-EU supplies (zero-rated) | €15,000.00 |
| 3 | Total input VAT | €0.00 |
| 4 | Net VAT payable | €3,800.00 |
| 8 | VIES total value | €15,000.00 |

### Expected VIES Record

```json
{
  "period": "2026-Q2",
  "business_vat_number": "CY10012345L",
  "records": [
    {
      "customer_vat_number": "DE811184117",
      "customer_country_code": "DE",
      "supply_type": "SERVICES",
      "total_value_eur": 15000.00
    }
  ]
}
```

### Expected Audit Events

```json
[
  {
    "event_type": "VAT_CALCULATION_RUN",
    "severity": "LOW",
    "metadata": {
      "period": "2026-Q2",
      "output_vat": 3800.00,
      "input_vat": 0.00,
      "net_payable": 3800.00,
      "vies_value": 15000.00
    }
  },
  {
    "event_type": "VIES_RECORD_FINALISED",
    "severity": "LOW",
    "metadata": {
      "period": "2026-Q2",
      "record_count": 1,
      "total_value_eur": 15000.00
    }
  }
]
```

---

## SQL Assertions for Test Suite

```sql
-- Fixture 1: Net VAT payable
SELECT SUM(amount) FROM ledger_entries
WHERE period = '2026-Q1'
  AND credit_account = '2300_VAT_PAYABLE'
  AND business_id = '018f4e2a-0000-7000-8000-000000000001';
-- Expected: 5900.00

-- Fixture 2: VAT control account zero balance after settlement
SELECT balance FROM vat_control_accounts
WHERE account_code = '2200_VAT_OUTPUT_19'
  AND period = '2026-Q1'
  AND business_id = '018f4e2a-0000-7000-8000-000000000001';
-- Expected: 0.00

SELECT balance FROM vat_control_accounts
WHERE account_code = '2201_VAT_OUTPUT_09'
  AND period = '2026-Q1'
  AND business_id = '018f4e2a-0000-7000-8000-000000000001';
-- Expected: 0.00

-- Fixture 2: Correct net payable
SELECT SUM(amount) FROM ledger_entries
WHERE period = '2026-Q1'
  AND credit_account = '2300_VAT_PAYABLE'
  AND business_id = '018f4e2a-0000-7000-8000-000000000001';
-- Expected: 1695.00

-- Fixture 3: VIES record present
SELECT total_value_eur FROM vies_records
WHERE period = '2026-Q2'
  AND customer_vat_number = 'DE811184117'
  AND business_id = '018f4e2a-0000-7000-8000-000000000001';
-- Expected: 15000.00

-- Fixture 3: Zero-rated supply not in VAT output accounts
SELECT COUNT(*) FROM ledger_entries
WHERE period = '2026-Q2'
  AND credit_account IN ('2200_VAT_OUTPUT_19', '2201_VAT_OUTPUT_09')
  AND business_id = '018f4e2a-0000-7000-8000-000000000001'
  AND description LIKE '%DE%';
-- Expected: 0
```

## Related Documents

- `/sub/reference/vat_account_code_reference.md`
- `/sub/reference/vat_rate_table_reference.md`
- `/sub/reference/cyprus_vat_rule_catalog.md`
- `/sub/reference/vat_treatment_enum.md`
- `/sub/reference/vies_record_format.md`
- `/sub/fixtures/fixture_format_spec.md`
- `/sub/runbooks/vat_recalculation_runbook.md`
- `/sub/runbooks/vat_submission_rejection_runbook.md`
- `/sub/runbooks/vies_submission_failure_runbook.md`
