# Expense Classification Fixture Content

**Category:** Fixtures · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

Test fixture data for expense classification scenarios. Each fixture provides an `expenses`
table row, an `ai_classification_results` row, expected audit events, and error conditions
covering a distinct classification outcome. Fixtures are consumed by the integration test
runner and the `bulk_classification_runbook.md` verification suite.

All UUIDs use `gen_uuid_v7()` format. Timestamps are fixed to `2026-02-10T09:00:00Z` unless
noted. Business entity is `Acme Cyprus Ltd` (VAT: CY12345678X, accounting_method: ACCRUAL).

See `fixture_format_spec.md` for the canonical fixture envelope structure.

---

## Fixture A — Office supplies, 19% VAT, fully recoverable

### Purpose

Validates that a standard office supply receipt from a Nicosia supplier is classified at the
Cyprus standard rate (19%) with full input VAT recovery.

### expenses table row

```json
{
  "id": "018f5a00-0001-7000-8000-000000000001",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "expense_date": "2026-02-05",
  "supplier_name": "Papeterie Nicosia Ltd",
  "supplier_vat_number": "CY98765432Z",
  "description": "A4 paper, printer cartridges, desk organiser",
  "total_amount": 87.40,
  "vat_amount": 13.57,
  "net_amount": 73.83,
  "currency": "EUR",
  "vat_category": "STANDARD_RATE",
  "vat_rate": 0.19,
  "recovery_percentage": 100,
  "recoverable_vat_amount": 13.57,
  "expense_status": "CLASSIFIED",
  "source": "MANUAL_UPLOAD",
  "document_id": "018f5a00-0001-7000-8000-000000000011",
  "created_at": "2026-02-10T09:00:00Z",
  "updated_at": "2026-02-10T09:04:12Z"
}
```

### ai_classification_results row

```json
{
  "id": "018f5a00-0001-7000-8000-000000000021",
  "expense_id": "018f5a00-0001-7000-8000-000000000001",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "classification_tier": "TIER_2",
  "suggested_category": "OFFICE_SUPPLIES_EXPENSE",
  "vat_treatment": "STANDARD_RATE",
  "confidence": 0.94,
  "recovery_percentage": 100,
  "model_version": "clf-cy-v3.1",
  "raw_response": {"category": "OFFICE_SUPPLIES_EXPENSE", "vat_treatment": "STANDARD_RATE"},
  "accepted": true,
  "accepted_by_user_id": null,
  "accepted_at": "2026-02-10T09:04:12Z"
}
```

### Expected audit events

1. `INTAKE_OCR_COMPLETED` (LOW) — after OCR on uploaded receipt. Payload: `document_id =
   "018f5a00-0001-7000-8000-000000000011"`, `confidence = 0.91`.
2. `CLASSIFICATION_LAYER_2_DECIDED` (LOW) — TIER_2 classification applied, confidence 0.94.
3. `CLASSIFICATION_VENDOR_MEMORY_MISS` (LOW) — no prior memory for Papeterie Nicosia Ltd.

### Error conditions

- If `supplier_vat_number` is absent: classification proceeds but recovery_percentage is set
  to 100 with a LOW-severity notice that VAT number was not verified via VIES.
- If `vat_amount` does not reconcile with `total_amount * 0.19 / 1.19` within 0.02 EUR
  tolerance: the expense is flagged `PENDING_REVIEW` with issue type `VAT_AMOUNT_MISMATCH`.

---

## Fixture B — Restaurant receipt, 9% VAT, 50% recovery

### Purpose

Validates that client entertainment expenses are classified at the Cyprus reduced rate (9%)
with 50% input VAT recovery per Cyprus VAT partial recovery rules for hospitality.

### expenses table row

```json
{
  "id": "018f5a00-0002-7000-8000-000000000002",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "expense_date": "2026-02-07",
  "supplier_name": "Agora Restaurant Limassol",
  "supplier_vat_number": "CY11223344V",
  "description": "Client dinner — Andreas Georgiou, contract discussion",
  "total_amount": 148.00,
  "vat_amount": 12.13,
  "net_amount": 135.87,
  "currency": "EUR",
  "vat_category": "REDUCED_RATE",
  "vat_rate": 0.09,
  "recovery_percentage": 50,
  "recoverable_vat_amount": 6.07,
  "expense_status": "CLASSIFIED",
  "source": "MANUAL_UPLOAD",
  "document_id": "018f5a00-0002-7000-8000-000000000012",
  "created_at": "2026-02-10T09:00:00Z",
  "updated_at": "2026-02-10T09:06:50Z"
}
```

### ai_classification_results row

```json
{
  "id": "018f5a00-0002-7000-8000-000000000022",
  "expense_id": "018f5a00-0002-7000-8000-000000000002",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "classification_tier": "TIER_2",
  "suggested_category": "CLIENT_ENTERTAINMENT_EXPENSE",
  "vat_treatment": "REDUCED_RATE",
  "confidence": 0.88,
  "recovery_percentage": 50,
  "recovery_reason": "HOSPITALITY_PARTIAL_RECOVERY_CY",
  "model_version": "clf-cy-v3.1",
  "raw_response": {
    "category": "CLIENT_ENTERTAINMENT_EXPENSE",
    "vat_treatment": "REDUCED_RATE",
    "recovery_percentage": 50,
    "recovery_note": "Cyprus VAT partial recovery rule for restaurant/entertainment"
  },
  "accepted": true,
  "accepted_by_user_id": null,
  "accepted_at": "2026-02-10T09:06:50Z"
}
```

### Expected audit events

1. `INTAKE_OCR_COMPLETED` (LOW) — Payload: `document_id = "018f5a00-0002-...0012"`,
   `confidence = 0.89`.
2. `CLASSIFICATION_LAYER_2_DECIDED` (LOW) — TIER_2 classification, reduced rate, 50% recovery.
3. `CLASSIFICATION_VENDOR_MEMORY_MISS` (LOW) — first time this supplier has been seen.

### Error conditions

- If an accountant manually sets `recovery_percentage` to 100 (overriding the 50% rule):
  emits `CLASSIFICATION_USER_RECLASSIFIED` (LOW) with `override_reason` required. A
  PENDING_REVIEW flag is set for OWNER approval.
- If `description` is blank and OCR yields no client name: confidence drops below 0.65 and
  the expense is escalated to TIER_3. If TIER_3 also cannot classify, the expense is placed
  in `PENDING_REVIEW` with issue type `CLASSIFICATION_CONFIDENCE_LOW`.

---

## Fixture C — Business flight to London, 0% VAT, fully recoverable

### Purpose

Validates that international air transport is classified at 0% VAT (zero-rated international
transport) with full input VAT recovery. No Cyprus VAT is chargeable on international flights.

### expenses table row

```json
{
  "id": "018f5a00-0003-7000-8000-000000000003",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "expense_date": "2026-02-03",
  "supplier_name": "Cyprus Airways",
  "supplier_vat_number": "CY55667788W",
  "description": "LCA-LHR return, business class — Maria Constantinou",
  "total_amount": 620.00,
  "vat_amount": 0.00,
  "net_amount": 620.00,
  "currency": "EUR",
  "vat_category": "ZERO_RATE",
  "vat_rate": 0.00,
  "recovery_percentage": 100,
  "recoverable_vat_amount": 0.00,
  "expense_status": "CLASSIFIED",
  "source": "MANUAL_UPLOAD",
  "document_id": "018f5a00-0003-7000-8000-000000000013",
  "created_at": "2026-02-10T09:00:00Z",
  "updated_at": "2026-02-10T09:08:20Z"
}
```

### ai_classification_results row

```json
{
  "id": "018f5a00-0003-7000-8000-000000000023",
  "expense_id": "018f5a00-0003-7000-8000-000000000003",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "classification_tier": "TIER_1",
  "suggested_category": "TRAVEL_EXPENSE",
  "vat_treatment": "ZERO_RATE",
  "confidence": 0.97,
  "recovery_percentage": 100,
  "recovery_reason": "ZERO_RATED_INTERNATIONAL_TRANSPORT",
  "model_version": "clf-cy-v3.1",
  "raw_response": {
    "category": "TRAVEL_EXPENSE",
    "vat_treatment": "ZERO_RATE",
    "zero_rate_reason": "International air transport — N.95(I)/2000 schedule"
  },
  "accepted": true,
  "accepted_by_user_id": null,
  "accepted_at": "2026-02-10T09:08:20Z"
}
```

### Expected audit events

1. `INTAKE_OCR_COMPLETED` (LOW) — Payload: `document_id = "018f5a00-0003-...0013"`,
   `confidence = 0.93`.
2. `CLASSIFICATION_VENDOR_MEMORY_HIT` (LOW) — Cyprus Airways previously confirmed.
3. `CLASSIFICATION_LAYER_1_DECIDED` (LOW) — TIER_1 vendor memory match, confidence 0.97.

### Error conditions

- If `vat_amount` is non-zero on a ZERO_RATE classified expense: emits a MEDIUM-severity
  `VAT_AMOUNT_NONZERO_ON_ZERO_RATE` review issue. Expense transitions to `PENDING_REVIEW`.
- If the route cannot be determined from OCR (no origin/destination extracted): classification
  falls to TIER_2. Confidence may be lower; ZERO_RATE is still applied if category matches
  TRAVEL_EXPENSE with international indicators.

---

## Fixture D — Personal Amazon purchase, flagged for rejection

### Purpose

Validates that a personal purchase accidentally uploaded is detected and flagged for rejection.
The AI classification should identify non-business intent and set `expense_status = REJECTED`.

### expenses table row

```json
{
  "id": "018f5a00-0004-7000-8000-000000000004",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "expense_date": "2026-02-08",
  "supplier_name": "Amazon EU S.a.r.l.",
  "supplier_vat_number": "LU26375245",
  "description": "Sony WH-1000XM5 Wireless Headphones — personal order",
  "total_amount": 299.00,
  "vat_amount": 0.00,
  "net_amount": 299.00,
  "currency": "EUR",
  "vat_category": "UNCLASSIFIED",
  "vat_rate": null,
  "recovery_percentage": 0,
  "recoverable_vat_amount": 0.00,
  "expense_status": "REJECTED",
  "rejection_reason": "NON_BUSINESS_EXPENSE",
  "source": "MANUAL_UPLOAD",
  "document_id": "018f5a00-0004-7000-8000-000000000014",
  "created_at": "2026-02-10T09:00:00Z",
  "updated_at": "2026-02-10T09:11:05Z"
}
```

### ai_classification_results row

```json
{
  "id": "018f5a00-0004-7000-8000-000000000024",
  "expense_id": "018f5a00-0004-7000-8000-000000000004",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "classification_tier": "TIER_3",
  "suggested_category": "PERSONAL_EXPENSE",
  "vat_treatment": null,
  "confidence": 0.79,
  "recovery_percentage": 0,
  "recovery_reason": "NON_BUSINESS_FLAGGED",
  "model_version": "clf-cy-v3.1",
  "raw_response": {
    "category": "PERSONAL_EXPENSE",
    "flag": "NON_BUSINESS_INTENT_DETECTED",
    "signals": ["description contains 'personal order'", "consumer product category"]
  },
  "accepted": false,
  "accepted_by_user_id": null,
  "accepted_at": null,
  "rejection_applied": true
}
```

### Expected audit events

1. `INTAKE_OCR_COMPLETED` (LOW) — Payload: `document_id = "018f5a00-0004-...0014"`,
   `confidence = 0.88`.
2. `CLASSIFICATION_LAYER_3_DECIDED` (LOW) — TIER_3 invoked due to non-business signals.
3. `AI_CLASSIFICATION_LAYER_3_INVOKED` (LOW) — escalation event before TIER_3 call.
4. `CLASSIFICATION_USER_RECLASSIFIED` (LOW) — emitted if an accountant manually confirms
   the rejection, providing the audit trail for the final status transition.

### Error conditions

- If the user contests the PERSONAL_EXPENSE flag and reclassifies manually: emits
  `CLASSIFICATION_USER_RECLASSIFIED` (LOW). The expense moves to `CLASSIFIED` with the
  manually assigned category and vat_category. A OWNER approval is required before posting.
- If the rejection_reason is not set when `expense_status` transitions to REJECTED: the
  transition is blocked at the application layer with error `EXPENSE_REJECTION_REASON_REQUIRED`.

---

## Related Documents

- `out_workflow_per_fixture_content.md` — OUT workflow fixture envelope
- `fixture_format_spec.md` — canonical fixture structure
- `cyprus_vat_rule_catalog.md` — VAT rate schedule and recovery rules
- `classification_fixture_content.md` — transaction classification fixtures (bank import)
- `expense_list_ui_spec.md` — Expense list page (status badges, filter bar)
- `classification_review_ui_spec.md` — review panel for PENDING_REVIEW expenses
- `bulk_classification_runbook.md` — bulk classification operating procedures
- `audit_event_taxonomy.md` — `INTAKE_OCR_COMPLETED`, `CLASSIFICATION_LAYER_2_DECIDED`,
  `CLASSIFICATION_LAYER_3_DECIDED`, `CLASSIFICATION_VENDOR_MEMORY_HIT`,
  `CLASSIFICATION_USER_RECLASSIFIED`
