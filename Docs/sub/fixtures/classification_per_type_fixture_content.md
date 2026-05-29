# classification_per_type_fixture_content

**Category:** Fixtures · **Owning block:** 08 — Transaction Classification & Tagging · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 08 Phase 02 (Layer 1 classifier); Block 08 Phase 10 (end-to-end classification tests).

**Purpose:** Canonical fixture corpus for the classification live integration test suite. One fixture object per `transaction_type_enum` value — 12 fixtures total. Each fixture is realistic: amounts, counterparty names, and descriptions are drawn from common Cyprus business contexts. Fixtures are used by `classification_live_integration_runbook` and as seed data for development environments.

---

## Format

Each fixture object contains:

| Field | Type | Description |
|---|---|---|
| `fixture_id` | UUID v7 | Stable, pinned identifier. Not regenerated between runs. |
| `transaction_type` | `transaction_type_enum` | The type this fixture exercises. Must match `expected_category`. |
| `amount_eur` | decimal string | Signed EUR amount. Negative = outflow. |
| `counterparty_name` | text | Raw counterparty name as it appears in a bank export. |
| `description_raw` | text | Raw transaction narrative; input to all three classifier layers. |
| `value_date` | date string (`YYYY-MM-DD`) | Transaction date. |
| `expected_category` | text | Expected `transaction_type` returned by `classification.classify_transaction`. |
| `expected_confidence_min` | decimal | Minimum calibrated confidence (0.00–1.00). Not asserted for `UNKNOWN`. |
| `has_vendor_memory_seed` | boolean | Whether the test business's vendor memory is pre-seeded with confirmed history for this counterparty. |

Amounts are stored as decimal strings per `data_layer_conventions_policy §3` (no floating-point in fixture JSON).

---

## Storage

These fixtures are defined inline below as JSON objects and are also exported to `fixtures/classification_fixtures.json` by the fixture export script:

```bash
pnpm fixture:export --block 08 --output fixtures/classification_fixtures.json
```

The export script reads this document, extracts all JSON code blocks tagged `fixture`, and writes them to the output file. The `.json` output is the authoritative input for the classification test harness; the inline definitions here are the human-readable source of truth.

---

## Fixtures

### OUT_EXPENSE

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2b3",
  "transaction_type": "OUT_EXPENSE",
  "amount_eur": "-1450.00",
  "counterparty_name": "ALPHA SIGMA ACCOUNTING SERVICES LTD",
  "description_raw": "Invoice payment - accounting services Q1 2026",
  "value_date": "2026-01-15",
  "expected_category": "OUT_EXPENSE",
  "expected_confidence_min": 0.85,
  "has_vendor_memory_seed": true
}
```

Notes: vendor memory seeded with 5 confirmed prior `OUT_EXPENSE` transactions to this counterparty. Layer 1 rule matches on `amount_signed < 0` AND counterparty not in own-account set. Vendor memory promotes to TIER_1.

---

### IN_INCOME

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2b4",
  "transaction_type": "IN_INCOME",
  "amount_eur": "3200.00",
  "counterparty_name": "NIKOLAOU ENTERPRISES LTD",
  "description_raw": "Payment for invoice INV-2026-0042",
  "value_date": "2026-02-03",
  "expected_category": "IN_INCOME",
  "expected_confidence_min": 0.85,
  "has_vendor_memory_seed": false
}
```

Notes: invoice reference `INV-2026-0042` is seeded in the test business's open invoices. Layer 1 matches on `amount_signed > 0` AND invoice reference present in description.

---

### INTERNAL_TRANSFER

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2b5",
  "transaction_type": "INTERNAL_TRANSFER",
  "amount_eur": "-5000.00",
  "counterparty_name": "ACME CYPRUS LTD - SAVINGS ACCOUNT",
  "description_raw": "Own account transfer - operational reserve",
  "value_date": "2026-01-20",
  "expected_category": "INTERNAL_TRANSFER",
  "expected_confidence_min": 0.90,
  "has_vendor_memory_seed": false
}
```

Notes: counterparty IBAN matches the test business's secondary bank account (seeded in `business_bank_accounts` fixture). Layer 1 rule matches on IBAN-in-own-account-set.

---

### FX_EXCHANGE

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2b6",
  "transaction_type": "FX_EXCHANGE",
  "amount_eur": "-2000.00",
  "counterparty_name": "REVOLUT LTD",
  "description_raw": "Currency exchange EUR to USD at 1.0821",
  "value_date": "2026-03-10",
  "expected_category": "FX_EXCHANGE",
  "expected_confidence_min": 0.80,
  "has_vendor_memory_seed": false
}
```

Notes: description contains `exchange` and counterparty is the bank itself (Revolut). Layer 1 matches on exchange-pattern in description AND counterparty = own bank.

---

### BANK_FEE

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2b7",
  "transaction_type": "BANK_FEE",
  "amount_eur": "-0.25",
  "counterparty_name": "REVOLUT LTD",
  "description_raw": "Card transaction fee",
  "value_date": "2026-01-08",
  "expected_category": "BANK_FEE",
  "expected_confidence_min": 0.90,
  "has_vendor_memory_seed": false
}
```

Notes: Layer 1 matches on `FEE` pattern in description AND counterparty = own bank. Small negative amount is consistent with bank fee signature.

---

### REFUND_IN

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2b8",
  "transaction_type": "REFUND_IN",
  "amount_eur": "240.00",
  "counterparty_name": "AMAZON WEB SERVICES EMEA SARL",
  "description_raw": "Refund - AWS credit memo CM-20260115",
  "value_date": "2026-01-22",
  "expected_category": "REFUND_IN",
  "expected_confidence_min": 0.78,
  "has_vendor_memory_seed": false
}
```

Notes: description contains `refund` and the amount is positive (credit from a supplier). Layer 1 matches on refund-keyword AND `amount_signed > 0`.

---

### REFUND_OUT

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2b9",
  "transaction_type": "REFUND_OUT",
  "amount_eur": "-180.00",
  "counterparty_name": "PAPADOPOULOS GEORGIOU & PARTNERS",
  "description_raw": "Refund issued to client - cancelled service",
  "value_date": "2026-02-14",
  "expected_category": "REFUND_OUT",
  "expected_confidence_min": 0.78,
  "has_vendor_memory_seed": false
}
```

Notes: description contains `refund issued` (outgoing refund keyword set). Layer 1 distinguishes REFUND_OUT from REFUND_IN by amount sign and keyword variant.

---

### CHARGEBACK

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2ba",
  "transaction_type": "CHARGEBACK",
  "amount_eur": "-320.00",
  "counterparty_name": "VISA CHARGEBACK PROCESSING",
  "description_raw": "Chargeback dispute CB-20260201-0099",
  "value_date": "2026-02-10",
  "expected_category": "CHARGEBACK",
  "expected_confidence_min": 0.82,
  "has_vendor_memory_seed": false
}
```

Notes: description contains `chargeback`. Layer 1 matches on chargeback-keyword regardless of amount sign (chargebacks can be either direction). Counterparty name pattern `VISA CHARGEBACK` is in the Layer 1 counterparty-pattern set.

---

### LOAN_OR_SHAREHOLDER_MOVEMENT

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2bb",
  "transaction_type": "LOAN_OR_SHAREHOLDER_MOVEMENT",
  "amount_eur": "10000.00",
  "counterparty_name": "CHRISTODOULOU NIKOS",
  "description_raw": "Director loan injection - working capital",
  "value_date": "2026-01-05",
  "expected_category": "LOAN_OR_SHAREHOLDER_MOVEMENT",
  "expected_confidence_min": 0.75,
  "has_vendor_memory_seed": false
}
```

Notes: description contains `director loan`. Layer 1 matches on loan/shareholder keyword set combined with counterparty being an individual (no company suffix). Layer 2 may be invoked for confidence boost if no vendor memory exists.

---

### PAYROLL_OR_TEAM_PAYMENT

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2bc",
  "transaction_type": "PAYROLL_OR_TEAM_PAYMENT",
  "amount_eur": "-2850.00",
  "counterparty_name": "MARIA PETROU",
  "description_raw": "Salary March 2026 - M. Petrou",
  "value_date": "2026-03-28",
  "expected_category": "PAYROLL_OR_TEAM_PAYMENT",
  "expected_confidence_min": 0.88,
  "has_vendor_memory_seed": true
}
```

Notes: counterparty is in the `payroll_vendor_set` (seeded). Description matches the `salary` payroll-keyword pattern. Layer 1 matches on keyword AND payroll_vendor_set membership.

---

### TAX_PAYMENT

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2bd",
  "transaction_type": "TAX_PAYMENT",
  "amount_eur": "-4750.00",
  "counterparty_name": "CYPRUS TAX DEPARTMENT",
  "description_raw": "VAT payment Q4 2025 - TD ref 20260115CY001",
  "value_date": "2026-01-15",
  "expected_category": "TAX_PAYMENT",
  "expected_confidence_min": 0.92,
  "has_vendor_memory_seed": false
}
```

Notes: counterparty matches the canonical `CYPRUS TAX DEPARTMENT` counterparty pattern (Layer 1 exact-match rule). Description contains `VAT payment`. Very high expected confidence because both signals align.

---

### UNKNOWN

```json fixture
{
  "fixture_id": "018f1a2b-3c4d-7e5f-a6b7-c8d9e0f1a2be",
  "transaction_type": "UNKNOWN",
  "amount_eur": "-67.50",
  "counterparty_name": "MISCELLANEOUS CREDIT 99812",
  "description_raw": "TRF 20260204 REF 00112233",
  "value_date": "2026-02-04",
  "expected_category": "UNCATEGORISED",
  "expected_confidence_min": 0,
  "has_vendor_memory_seed": false
}
```

Notes: description is opaque (reference number only, no human-readable narrative). Counterparty name is synthetic and not in any known counterparty set. Layer 1, Layer 2, and Layer 3 all fail to assign a category above threshold. The classifier returns `UNKNOWN` / `UNCATEGORISED`. Confidence is not asserted (`expected_confidence_min = 0`). This fixture creates a BLOCKING review issue in the test run per Block 14 Phase 02.

---

## Vendor memory seed inventory

The following fixtures have `has_vendor_memory_seed = true`. The test business's vendor memory is seeded with the corresponding confirmed history before the test run:

| Fixture | Counterparty | Confirmed count | Seeded category |
|---|---|---|---|
| `OUT_EXPENSE` | `ALPHA SIGMA ACCOUNTING SERVICES LTD` | 5 | `OUT_EXPENSE` |
| `PAYROLL_OR_TEAM_PAYMENT` | `MARIA PETROU` | 4 | `PAYROLL_OR_TEAM_PAYMENT` |

Confirmed count ≥ 3 qualifies as a HIGH-tier vendor memory hit per `vendor_memory_schema`. Both seeded fixtures should return `tier_used = 'TIER_1'` and `vendor_memory_hit = true` per the Step 4 assertion in `classification_live_integration_runbook`.

---

## Fixture count verification

The fixture corpus must contain exactly 12 entries, one per `transaction_type_enum` value:

```
OUT_EXPENSE, IN_INCOME, INTERNAL_TRANSFER, FX_EXCHANGE,
BANK_FEE, REFUND_IN, REFUND_OUT, CHARGEBACK,
LOAN_OR_SHAREHOLDER_MOVEMENT, PAYROLL_OR_TEAM_PAYMENT,
TAX_PAYMENT, UNKNOWN
```

A lint check in Block 08 Phase 10 (`classification_fixture_count_check`) asserts this count on every CI run. If a new value is added to `transaction_type_enum`, this fixture file must be updated in the same PR.

---

## Cross-references

- `transaction_type_enum` — the closed 12-value enum; one fixture per value
- `classification_live_integration_runbook` — test steps and acceptance criteria that consume these fixtures
- `classification_confidence_output_schema` — `confidence` field definition and calibration; `expected_confidence_min` values are calibrated against this schema
- `vendor_memory_schema` — vendor memory table; HIGH-tier threshold of ≥ 3 confirmed transactions
- `fixture_format_spec` — fixture file shape conventions and `.expected.json` companion format
- Block 08 Phase 02 — Layer 1 classifier; keyword and counterparty pattern rules referenced in per-fixture notes
- Block 08 Phase 10 — end-to-end classification tests; `classification_fixture_count_check` lint rule
