# Classification Fixture Content

**Block:** classification
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This document defines four representative fixture scenarios for the classification engine test suite. Each fixture provides a full input transaction payload, the expected classification output, expected audit events, and edge case notes. Fixtures are consumed by the integration test runner and the live integration test runbook.

All UUIDs in fixtures use the `gen_uuid_v7()` format unless noted. Timestamps are fixed to a deterministic value to prevent test flakiness.

## Fixture Format Reference

See `/sub/fixtures/fixture_format_spec.md` for the canonical fixture envelope structure. Classification fixtures extend the base envelope with `expected_classification` and `expected_audit_events` sections.

---

## Fixture 1 — High-Confidence Vendor Memory Match

### Purpose

Validates that the engine correctly retrieves a previously learned vendor association from vendor memory and applies it with high confidence without invoking the rule engine or AI tier.

### Input Transaction

```json
{
  "fixture_id": "clf-001",
  "description": "High-confidence vendor memory match — OTE S.A. telecom bill",
  "transaction": {
    "id": "018f4e2a-1b3c-7d8e-9f0a-1b2c3d4e5f60",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "transaction_date": "2026-01-15",
    "amount": -124.80,
    "currency": "EUR",
    "vendor_raw": "OTE S.A.",
    "reference": "TEL-2026-01-0041",
    "description": "Monthly telephone subscription",
    "transaction_type": "DEBIT",
    "source": "BANK_IMPORT",
    "dedup_status": "NEW"
  },
  "vendor_memory_seed": {
    "vendor_normalized": "OTE SA",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "category": "TELECOMMUNICATIONS_EXPENSE",
    "confidence_accumulated": 0.97,
    "match_count": 14,
    "last_confirmed_at": "2025-12-01T00:00:00Z"
  }
}
```

### Expected Classification Output

```json
{
  "transaction_id": "018f4e2a-1b3c-7d8e-9f0a-1b2c3d4e5f60",
  "category": "TELECOMMUNICATIONS_EXPENSE",
  "confidence": 0.97,
  "source": "VENDOR_MEMORY",
  "match_level": "EXACT",
  "review_required": false,
  "dedup_status": "NEW",
  "vies_eligible": false,
  "reverse_charge": false,
  "vat_rate": 0.19,
  "applied_rule_id": null,
  "ai_invoked": false,
  "classification_override": false
}
```

### Expected Audit Events

```json
[
  {
    "event_type": "CLASSIFICATION_APPLIED",
    "severity": "LOW",
    "entity_type": "transaction",
    "entity_id": "018f4e2a-1b3c-7d8e-9f0a-1b2c3d4e5f60",
    "metadata": {
      "source": "VENDOR_MEMORY",
      "category": "TELECOMMUNICATIONS_EXPENSE",
      "confidence": 0.97
    }
  }
]
```

### Edge Cases

- If `vendor_raw` is "OTE SA." (trailing period) the normalizer must strip it and still hit the vendor memory record.
- If the vendor memory record has `match_count < 3`, confidence should be downgraded to 0.70 and `source` changes to `VENDOR_MEMORY_LOW_SIGNAL`. This fixture assumes `match_count = 14`.
- If `confidence_accumulated` has drifted below 0.90 since the seed, the rule engine should be invoked as a secondary check. This fixture holds confidence at 0.97 to exercise the happy path.

---

## Fixture 2 — Rule Engine Match (Utility Expense)

### Purpose

Validates that a deterministic classification rule with `confidence = 1.0` fires correctly for a known utility vendor, bypasses AI, and marks the result as non-reviewable.

### Input Transaction

```json
{
  "fixture_id": "clf-002",
  "description": "Rule engine match — Cyprus Electricity Authority utility bill",
  "transaction": {
    "id": "018f4e2b-2c4d-7e9f-a0b1-2c3d4e5f6071",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "transaction_date": "2026-03-28",
    "amount": -340.22,
    "currency": "EUR",
    "vendor_raw": "CYPRUS ELECTRICITY AUTHORITY",
    "reference": "EAC-BILL-2026-03",
    "description": "Electricity bill March 2026",
    "transaction_type": "DEBIT",
    "source": "BANK_IMPORT",
    "dedup_status": "NEW"
  },
  "rule_seed": {
    "rule_id": "rule-utility-eac-001",
    "predicate_vendor_contains": "CYPRUS ELECTRICITY",
    "category": "UTILITIES_EXPENSE",
    "confidence": 1.0,
    "priority": 100,
    "enabled": true
  }
}
```

### Expected Classification Output

```json
{
  "transaction_id": "018f4e2b-2c4d-7e9f-a0b1-2c3d4e5f6071",
  "category": "UTILITIES_EXPENSE",
  "confidence": 1.0,
  "source": "RULE",
  "match_level": "EXACT",
  "review_required": false,
  "dedup_status": "NEW",
  "vies_eligible": false,
  "reverse_charge": false,
  "vat_rate": 0.19,
  "applied_rule_id": "rule-utility-eac-001",
  "ai_invoked": false,
  "classification_override": false
}
```

### Expected Audit Events

```json
[
  {
    "event_type": "CLASSIFICATION_APPLIED",
    "severity": "LOW",
    "entity_type": "transaction",
    "entity_id": "018f4e2b-2c4d-7e9f-a0b1-2c3d4e5f6071",
    "metadata": {
      "source": "RULE",
      "rule_id": "rule-utility-eac-001",
      "category": "UTILITIES_EXPENSE",
      "confidence": 1.0
    }
  }
]
```

### Edge Cases

- Reference "EAC-BILL-2026-03" alone would not match if vendor is absent; the predicate checks `vendor_raw` not reference.
- If the rule is disabled (`enabled: false`), the engine must fall through to AI tier. Fixture clf-002-b (not defined here) covers that path.
- Vendor name "EAC" (abbreviation) should NOT match this rule; the predicate requires the string "CYPRUS ELECTRICITY". A separate vendor memory record for "EAC" would be needed.
- Amount sign is always DEBIT for utility bills; a CREDIT with this vendor name is anomalous and should produce a `review_issue` of type `SIGN_ANOMALY`.

---

## Fixture 3 — Low Confidence (Manual Review Required)

### Purpose

Validates that the engine correctly creates a `review_issue` of type `MANUAL_REQUIRED` when classification confidence falls below the review threshold (default: 0.70) and no rule matches.

### Input Transaction

```json
{
  "fixture_id": "clf-003",
  "description": "Low confidence — ambiguous vendor with no rule or memory match",
  "transaction": {
    "id": "018f4e2c-3d5e-7f90-b1c2-3d4e5f607182",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "transaction_date": "2026-02-10",
    "amount": -5000.00,
    "currency": "EUR",
    "vendor_raw": "ALPHA SERVICES LTD",
    "reference": "",
    "description": "",
    "transaction_type": "DEBIT",
    "source": "BANK_IMPORT",
    "dedup_status": "NEW"
  },
  "vendor_memory_seed": null,
  "rule_seed": null,
  "ai_mock_response": {
    "category": "PROFESSIONAL_SERVICES",
    "confidence": 0.62,
    "reasoning": "Vendor name is generic; no reference or description to disambiguate."
  }
}
```

### Expected Classification Output

```json
{
  "transaction_id": "018f4e2c-3d5e-7f90-b1c2-3d4e5f607182",
  "category": "PROFESSIONAL_SERVICES",
  "confidence": 0.62,
  "source": "AI",
  "match_level": "WEAK_POSSIBLE",
  "review_required": true,
  "dedup_status": "NEW",
  "vies_eligible": false,
  "reverse_charge": false,
  "vat_rate": 0.19,
  "applied_rule_id": null,
  "ai_invoked": true,
  "classification_override": false
}
```

### Expected Review Issue Created

```json
{
  "issue_type": "MANUAL_REQUIRED",
  "severity": "MEDIUM",
  "entity_type": "transaction",
  "entity_id": "018f4e2c-3d5e-7f90-b1c2-3d4e5f607182",
  "suggested_category": "PROFESSIONAL_SERVICES",
  "suggested_confidence": 0.62,
  "description": "Classification confidence 0.62 is below threshold 0.70. Manual review required.",
  "status": "OPEN"
}
```

### Expected Audit Events

```json
[
  {
    "event_type": "CLASSIFICATION_APPLIED",
    "severity": "LOW",
    "entity_type": "transaction",
    "entity_id": "018f4e2c-3d5e-7f90-b1c2-3d4e5f607182",
    "metadata": {
      "source": "AI",
      "confidence": 0.62,
      "review_required": true
    }
  },
  {
    "event_type": "REVIEW_ISSUE_CREATED",
    "severity": "MEDIUM",
    "entity_type": "transaction",
    "entity_id": "018f4e2c-3d5e-7f90-b1c2-3d4e5f607182",
    "metadata": {
      "issue_type": "MANUAL_REQUIRED"
    }
  }
]
```

### Edge Cases

- Empty `reference` and `description` fields remove two signal sources from the AI prompt. The AI mock must reflect the lower confidence that results.
- Amount of €5,000 does not by itself trigger HIGH severity; the MEDIUM severity here comes from the review issue type. A separate threshold rule (e.g., amounts > €10,000 with low confidence) would escalate to HIGH.
- If the accountant resolves this review issue and confirms PROFESSIONAL_SERVICES, the engine must update `classification_override = true` and create a vendor memory record for "ALPHA SERVICES LTD" with initial confidence 0.75.
- Repeated identical transactions from this vendor after confirmation should route through vendor memory (fixture clf-003-b not defined here).

---

## Fixture 4 — Intra-EU Supply (VIES Eligible, Reverse Charge)

### Purpose

Validates that the engine correctly identifies an intra-EU B2B transaction, sets `vies_eligible = true`, applies reverse charge treatment, and sets `vat_rate = 0`.

### Input Transaction

```json
{
  "fixture_id": "clf-004",
  "description": "Intra-EU supply — Amazon EU SARL, Luxembourg VAT number present",
  "transaction": {
    "id": "018f4e2d-4e6f-7091-c2d3-4e5f60718293",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "transaction_date": "2026-04-05",
    "amount": -2890.00,
    "currency": "EUR",
    "vendor_raw": "AMAZON EU SARL",
    "reference": "AMZ-EU-2026-04-00091",
    "description": "AWS cloud services April 2026",
    "transaction_type": "DEBIT",
    "source": "MANUAL_ENTRY",
    "dedup_status": "NEW",
    "supplier_vat_number": "LU26375245",
    "supplier_country_code": "LU"
  },
  "rule_seed": {
    "rule_id": "rule-intraeu-cloud-001",
    "predicate_vendor_contains": "AMAZON EU",
    "predicate_supplier_country_not_cy": true,
    "category": "PROFESSIONAL_SERVICES",
    "confidence": 0.95,
    "priority": 80,
    "enabled": true,
    "vies_eligible": true,
    "reverse_charge": true
  }
}
```

### Expected Classification Output

```json
{
  "transaction_id": "018f4e2d-4e6f-7091-c2d3-4e5f60718293",
  "category": "PROFESSIONAL_SERVICES",
  "confidence": 0.95,
  "source": "RULE",
  "match_level": "STRONG_PROBABLE",
  "review_required": false,
  "dedup_status": "NEW",
  "vies_eligible": true,
  "reverse_charge": true,
  "vat_rate": 0,
  "applied_rule_id": "rule-intraeu-cloud-001",
  "ai_invoked": false,
  "classification_override": false,
  "vies_metadata": {
    "supplier_vat_number": "LU26375245",
    "supplier_country_code": "LU",
    "vies_value": 2890.00,
    "reporting_period": "2026-Q2"
  }
}
```

### Expected Audit Events

```json
[
  {
    "event_type": "CLASSIFICATION_APPLIED",
    "severity": "LOW",
    "entity_type": "transaction",
    "entity_id": "018f4e2d-4e6f-7091-c2d3-4e5f60718293",
    "metadata": {
      "source": "RULE",
      "rule_id": "rule-intraeu-cloud-001",
      "category": "PROFESSIONAL_SERVICES",
      "confidence": 0.95,
      "vies_eligible": true,
      "reverse_charge": true
    }
  },
  {
    "event_type": "VIES_RECORD_STAGED",
    "severity": "LOW",
    "entity_type": "transaction",
    "entity_id": "018f4e2d-4e6f-7091-c2d3-4e5f60718293",
    "metadata": {
      "supplier_vat_number": "LU26375245",
      "vies_value": 2890.00,
      "period": "2026-Q2"
    }
  }
]
```

### Edge Cases

- If `supplier_vat_number` is absent but `supplier_country_code` is a non-CY EU member state, the engine should still flag `vies_eligible = true` with `match_level = WEAK_POSSIBLE` and create a review issue of type `VIES_VAT_NUMBER_MISSING`.
- If `supplier_country_code` is not an EU member state (e.g., "GB" post-Brexit), `vies_eligible` must be `false` even if the vendor name matches the rule.
- Purchases from EU vendors that are not B2B (B2C scenario) should not receive reverse charge treatment. The rule requires the buyer to be VAT-registered (checked via the business entity's VAT number presence).
- Currency must be EUR for VIES reporting; if the transaction is in a foreign currency, the engine converts using the ECB rate and records the EUR equivalent in `vies_metadata.vies_value`.

---

## SQL Assertions for Test Suite

```sql
-- Fixture 1: Vendor memory match result
SELECT
  category,
  confidence,
  source,
  ai_invoked
FROM transaction_classifications
WHERE transaction_id = '018f4e2a-1b3c-7d8e-9f0a-1b2c3d4e5f60';
-- Expected: TELECOMMUNICATIONS_EXPENSE, 0.97, VENDOR_MEMORY, false

-- Fixture 3: Review issue created
SELECT COUNT(*) FROM review_issues
WHERE entity_id = '018f4e2c-3d5e-7f90-b1c2-3d4e5f607182'
  AND issue_type = 'MANUAL_REQUIRED'
  AND status = 'OPEN';
-- Expected: 1

-- Fixture 4: VIES record staged
SELECT vies_eligible, reverse_charge, vat_rate
FROM transaction_classifications
WHERE transaction_id = '018f4e2d-4e6f-7091-c2d3-4e5f60718293';
-- Expected: true, true, 0

SELECT COUNT(*) FROM vies_staging
WHERE transaction_id = '018f4e2d-4e6f-7091-c2d3-4e5f60718293';
-- Expected: 1
```

## Related Documents

- `/sub/fixtures/fixture_format_spec.md`
- `/sub/fixtures/classification_per_type_fixture_content.md`
- `/sub/reference/classification_rule_catalog` (if present)
- `/sub/reference/vat_treatment_enum.md`
- `/sub/reference/match_level_enum.md`
- `/sub/runbooks/classification_rule_conflict_runbook.md`
- `/sub/runbooks/bulk_classification_runbook.md`
