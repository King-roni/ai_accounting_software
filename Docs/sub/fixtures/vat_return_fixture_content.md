# VAT Return Fixture Content

**Block:** ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines two VAT return fixture scenarios for testing the `tool_vat_calc` engine tool and the `vat_return_schema` output. All fixtures are deterministic with fixed EUR amounts. Business entity: `018f4e2a-0000-7000-8000-000000000001` (Georgiou & Partners Ltd), VAT number `CY10099887L`, quarterly filer. Period: Q1 2026 (2026-01-01 to 2026-03-31).

Cyprus VAT rates in scope: standard 19%, reduced 9% (hotels / restaurant services), reduced 5% (books, food, medicine). Zero-rated: 0%.

---

## Fixture 1 — Standard Quarterly VAT Return (Mixed Domestic Rates)

### Purpose

Validates that `tool_vat_calc` correctly aggregates output VAT and input VAT across all three domestic rates and produces the correct net payable figure.

### Line Items

#### Output VAT (Sales)

| # | Description | Amount excl. VAT (EUR) | VAT Rate | VAT Amount (EUR) |
|---|---|---|---|---|
| 1 | Consulting services — Marcos Shipping Ltd | 42,000.00 | 19% | 7,980.00 |
| 2 | Consulting services — Phivos Imports Ltd | 15,000.00 | 19% | 2,850.00 |
| 3 | Hotel management advisory — Aphrodite Beach Hotel | 8,400.00 | 9% | 756.00 |
| 4 | Restaurant consulting — Taverna tis Kypriakas | 3,200.00 | 9% | 288.00 |
| 5 | Educational materials supplied — Nicosia Academy | 1,800.00 | 5% | 90.00 |

**Output VAT subtotals:**

| Rate | Net Sales | Output VAT |
|---|---|---|
| 19% | 57,000.00 | 10,830.00 |
| 9% | 11,600.00 | 1,044.00 |
| 5% | 1,800.00 | 90.00 |
| **Total** | **70,400.00** | **11,964.00** |

#### Input VAT (Purchases)

| # | Description | Amount excl. VAT (EUR) | VAT Rate | VAT Amount (EUR) |
|---|---|---|---|---|
| 6 | Α/Φ Παπαδόπουλος — office supplies Jan–Mar | 3,200.00 | 19% | 608.00 |
| 7 | Νικολαΐδης & Υιοί ΕΠΕ — legal fees | 6,000.00 | 19% | 1,140.00 |
| 8 | Zenon IT Solutions Nicosia — IT infrastructure | 9,500.00 | 19% | 1,805.00 |

**Input VAT subtotals:**

| Rate | Net Purchases | Input VAT |
|---|---|---|
| 19% | 18,700.00 | 3,553.00 |
| **Total** | **18,700.00** | **3,553.00** |

### VAT Return Summary

```
Output VAT (all rates):       €11,964.00
Input VAT (recoverable):      € 3,553.00
                              ──────────
Net VAT Payable:              € 8,411.00
```

### Cyprus VAT Return Box Mapping (Fixture 1)

| Box | Description | Value |
|---|---|---|
| Box 1A | Output tax — standard rate (19%) supplies | 10,830.00 |
| Box 1B | Output tax — reduced rate (9%) supplies | 1,044.00 |
| Box 1C | Output tax — reduced rate (5%) supplies | 90.00 |
| Box 2 | Output tax on acquisitions from EU | 0.00 |
| Box 3 | Total output tax (1A + 1B + 1C + 2) | 11,964.00 |
| Box 4 | Tax on intra-EU acquisitions (input) | 0.00 |
| Box 5 | Input tax on domestic purchases | 3,553.00 |
| Box 6 | Total input tax (4 + 5) | 3,553.00 |
| Box 7 | Net tax payable (3 − 6) | 8,411.00 |
| Box 8 | Zero-rated supplies | 0.00 |
| Box 9 | Exempt supplies | 0.00 |
| Box 10 | Total value of sales (excl. VAT) | 70,400.00 |
| Box 11 | Total value of purchases (excl. VAT) | 18,700.00 |

### Expected vat_return_schema output (excerpt)

```json
{
  "vat_return_id": "018f7a01-0001-7000-8000-000000000001",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "vat_number": "CY10099887L",
  "period": "2026-Q1",
  "period_start": "2026-01-01",
  "period_end": "2026-03-31",
  "filing_frequency": "QUARTERLY",
  "filing_deadline": "2026-04-10",
  "status": "DRAFT",
  "box_1a": 10830.00,
  "box_1b": 1044.00,
  "box_1c": 90.00,
  "box_2": 0.00,
  "box_3": 11964.00,
  "box_4": 0.00,
  "box_5": 3553.00,
  "box_6": 3553.00,
  "box_7": 8411.00,
  "box_8": 0.00,
  "box_9": 0.00,
  "box_10": 70400.00,
  "box_11": 18700.00,
  "currency": "EUR"
}
```

---

## Fixture 2 — VAT Return with Intra-EU Acquisition, Zero-Rated Export, and Reverse Charge

### Purpose

Validates correct box mapping for cross-border transactions: an intra-EU acquisition (Box 4), a zero-rated export (Box 8), and a domestic reverse-charge supply.

### Line Items

#### Output VAT (Sales)

| # | Description | Amount excl. VAT (EUR) | VAT Rate | VAT Amount (EUR) | Notes |
|---|---|---|---|---|---|
| 1 | Standard domestic consulting — Kyriakos Consulting | 30,000.00 | 19% | 5,700.00 | Normal domestic |
| 2 | Export of services — TechCorp GmbH, Germany | 25,000.00 | 0% | 0.00 | Zero-rated export — Box 8 |
| 3 | Reverse charge services received — Dutch B.V. | 8,000.00 | 19% (self-assessed) | 1,520.00 | Output self-assessed — Box 2 |

**Output VAT subtotals:**

| Rate / Type | Net | VAT |
|---|---|---|
| 19% domestic | 30,000.00 | 5,700.00 |
| 0% zero-rated export | 25,000.00 | 0.00 |
| Reverse charge (output) | 8,000.00 | 1,520.00 |
| **Total output** | **63,000.00** | **7,220.00** |

#### Input VAT (Purchases / Acquisitions)

| # | Description | Amount excl. VAT (EUR) | VAT Rate | VAT Amount (EUR) | Notes |
|---|---|---|---|---|---|
| 4 | Intra-EU acquisition — office furniture from Ikea DE | 12,000.00 | 19% (self-assessed) | 2,280.00 | Box 4 + recoverable input |
| 5 | Domestic IT services — Zenon IT Solutions | 4,500.00 | 19% | 855.00 | Box 5 |
| 6 | Reverse charge services — Dutch B.V. (input side) | 8,000.00 | 19% (self-assessed) | 1,520.00 | Box 4 / recoverable |

**Input VAT subtotals:**

| Type | Net | VAT |
|---|---|---|
| Intra-EU acquisition (Box 4) | 12,000.00 | 2,280.00 |
| Reverse charge input (Box 4) | 8,000.00 | 1,520.00 |
| Domestic input (Box 5) | 4,500.00 | 855.00 |
| **Total input** | **24,500.00** | **4,655.00** |

### VIES Entry

```json
{
  "vies_entry_id": "018f7a02-0010-7000-8000-000000000001",
  "vat_return_id": "018f7a02-0001-7000-8000-000000000002",
  "counterparty_vat_number": "DE123456789",
  "counterparty_country_code": "DE",
  "counterparty_name": "Ikea Deutschland GmbH",
  "transaction_type": "INTRA_EU_ACQUISITION",
  "amount_excl_vat": 12000.00,
  "currency": "EUR",
  "period": "2026-Q1"
}
```

### VAT Return Summary

```
Output VAT:
  Standard (19%):              5,700.00
  Reverse charge (output):     1,520.00
  Zero-rated export:               0.00
  Total output VAT:            7,220.00

Input VAT:
  Intra-EU acquisition:        2,280.00
  Reverse charge (input):      1,520.00
  Domestic input:                855.00
  Total input VAT:             4,655.00
                               ────────
Net VAT Payable:               2,565.00
```

### Cyprus VAT Return Box Mapping (Fixture 2)

| Box | Description | Value |
|---|---|---|
| Box 1A | Output tax — standard rate (19%) domestic | 5,700.00 |
| Box 1B | Output tax — reduced rate (9%) | 0.00 |
| Box 1C | Output tax — reduced rate (5%) | 0.00 |
| Box 2 | Output tax on reverse charge / intra-EU acquisitions | 1,520.00 |
| Box 3 | Total output tax | 7,220.00 |
| Box 4 | Input tax on intra-EU acquisitions + reverse charge | 3,800.00 |
| Box 5 | Input tax on domestic purchases | 855.00 |
| Box 6 | Total input tax | 4,655.00 |
| Box 7 | Net VAT payable (Box 3 − Box 6) | 2,565.00 |
| Box 8 | Zero-rated supplies (exports) | 25,000.00 |
| Box 9 | Exempt supplies | 0.00 |
| Box 10 | Total value of sales (excl. VAT) | 63,000.00 |
| Box 11 | Total value of purchases (excl. VAT) | 24,500.00 |

### Expected vat_return_schema output (excerpt)

```json
{
  "vat_return_id": "018f7a02-0001-7000-8000-000000000002",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "vat_number": "CY10099887L",
  "period": "2026-Q1",
  "filing_deadline": "2026-04-10",
  "status": "DRAFT",
  "box_1a": 5700.00,
  "box_1b": 0.00,
  "box_1c": 0.00,
  "box_2": 1520.00,
  "box_3": 7220.00,
  "box_4": 3800.00,
  "box_5": 855.00,
  "box_6": 4655.00,
  "box_7": 2565.00,
  "box_8": 25000.00,
  "box_9": 0.00,
  "box_10": 63000.00,
  "box_11": 24500.00,
  "currency": "EUR",
  "vies_entries": ["018f7a02-0010-7000-8000-000000000001"]
}
```

---

## Related Documents

- `/sub/schemas/vat_return_schema.md` — `vat_returns` table definition and box mapping
- `/sub/tools/tool_vat_calc.md` — `tool_vat_calc` specification
- `/sub/reference/vat_account_code_reference.md` — VAT account codes
- `/sub/guides/cyprus_vat_compliance_guide.md` — Cyprus VAT rules and filing obligations
- `/sub/fixtures/vat_calculation_fixture_content.md` — Complementary ledger-level VAT fixture
