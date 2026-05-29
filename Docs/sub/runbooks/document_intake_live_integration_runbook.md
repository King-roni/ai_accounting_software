# document_intake_live_integration_runbook

**Category:** Runbooks · **Owning block:** 09 — Document Intake & Extraction · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 09 Phase 02 (`intake.ocr_and_extract` — OCR and field extraction); Block 09 Phase 10 (end-to-end document intake tests).

**Purpose:** Cadence, fixture set, test steps, acceptance criteria, and failure handling for the Document Intake live integration test suite. Validates the full intake path — OCR invocation, field extraction, confidence scoring, tier escalation, audit event emission, and review issue creation for low-quality documents.

---

## Cadence

| Trigger | Schedule | Scope |
|---|---|---|
| Pre-deploy | Before every production release | Full fixture set (4 fixtures) |
| Weekly scheduled | Monday 04:00 UTC | Full fixture set |
| Post-incident | After a Google Document AI API change or OCR accuracy regression | Re-record affected fixtures in live mode; full regression pass |
| Manual | Engineering investigation | As needed |

Document AI invocations (`intake.ocr_and_extract`) call the Google Document AI EU API. Per `live_integration_test_runbook`, per-fixture cost is approximately $0.02–$0.05. Full weekly run: 4 fixtures × $0.05 = $0.20 maximum. Default CI runs use `ai_response_recording_fixtures` replay; live mode is activated by `TEST_LIVE_MODE=true`.

---

## Fixture set

Four fixtures cover the acceptance-critical paths:

| Fixture ID | Source type | Description | Purpose |
|---|---|---|---|
| `doc_intake_clean_invoice` | `DOCUMENT_PDF` | Single-page, machine-generated PDF invoice with clear typography | Happy path; validates full field extraction at high confidence |
| `doc_intake_low_quality_scan` | `DOCUMENT_PDF` | Scanned physical invoice, skewed and low-resolution | Validates confidence threshold, tier escalation, and review issue creation |
| `doc_intake_multi_page` | `DOCUMENT_PDF` | Multi-page document (3-page invoice with cover sheet and payment terms) | Validates page-count handling; field extraction from non-first page |
| `doc_intake_email_attachment` | `EMAIL_ATTACHMENT` | PDF attached to an incoming Gmail integration email | Validates the email-sourced intake path through `intake.ocr_and_extract` |

Fixture files are stored in `fixtures/document_intake/` as PDF files with `.expected.json` companion files per `fixture_format_spec`. The email attachment fixture additionally provides a mock Gmail message ID in the companion file.

---

## Test steps

The following 5 steps execute for each of the 4 fixtures.

### Step 1 — Submit via `intake.ocr_and_extract`

```bash
intake.ocr_and_extract({
  document_id: "<fixture document UUID>",
  source_type: "<fixture source_type>",   // DOCUMENT_PDF or EMAIL_ATTACHMENT
  business_id: "<fixture business UUID>",
  workflow_run_id: "<fixture run UUID>",
  storage_key: "<fixture PDF storage key>"
})
```

For `doc_intake_email_attachment`: include `gmail_message_id: "<fixture mock message ID>"` in the call.

Assert: the call returns without error. The returned object includes `extraction_result`, `confidence`, `tier_used`, and `escalated` (boolean).

### Step 2 — Field extraction assertion (clean fixture only)

For `doc_intake_clean_invoice` only:

Assert:
- `extraction_result.invoice_number` is non-null and non-empty
- `extraction_result.total_amount` is non-null and a valid decimal

The specific expected values (`expected_invoice_number`, `expected_total_amount`) are pinned in `doc_intake_clean_invoice.expected.json`. Assert exact string match for `invoice_number` and numeric equality (±0.01) for `total_amount`.

For `doc_intake_multi_page` and `doc_intake_email_attachment`: assert `invoice_number` and `total_amount` are non-null. Exact value assertions are not required for these fixtures (page layout variability is acceptable); presence of the fields is the assertion.

For `doc_intake_low_quality_scan`: skip this step — field extraction quality is intentionally degraded; the fixture exists to test the escalation and review issue path.

### Step 3 — Confidence threshold and tier escalation assertion

For `doc_intake_low_quality_scan`:

Assert:
- `returned.confidence < 0.65` (this fixture is calibrated to fall below the TIER_3 escalation threshold)
- `returned.escalated = true`
- `returned.tier_used = 'EXTERNAL'` (TIER_3 Anthropic Claude was invoked for the escalation attempt)

For all other fixtures:
- Assert `returned.confidence >= 0.65`
- Assert `returned.escalated = false` (no tier escalation triggered)

For `doc_intake_clean_invoice` specifically:
- Assert `returned.confidence >= 0.80` (clean machine-generated invoice should meet the high-confidence bar)

### Step 4 — `INTAKE_OCR_COMPLETED` audit event assertion

Query the audit log for `event_type = 'INTAKE_OCR_COMPLETED'` with `subject_id = <document_id>`. Assert:
- Exactly 1 event found
- `confidence` in event payload matches `returned.confidence` (within 0.001 tolerance)
- `tier_used` in event payload matches `returned.tier_used`
- `escalated` in event payload matches `returned.escalated`

For `doc_intake_low_quality_scan`: additionally query for `event_type = 'INTAKE_OCR_ESCALATED'`. Assert exactly 1 escalation event with `escalation_reason` non-null and `tier_2_confidence < 0.65`.

### Step 5 — Review issue assertion for low-quality scan

For `doc_intake_low_quality_scan` only:

Query `review_issues WHERE subject_id = <document_id> AND issue_type = 'DOCUMENT_OCR_CONFIDENCE_LOW'`. Assert:
- Exactly 1 open review issue found
- `severity` is MEDIUM or higher
- `workflow_run_id` on the issue matches the fixture's run UUID

For all other fixtures: assert 0 review issues of type `DOCUMENT_OCR_CONFIDENCE_LOW` exist for the fixture's `document_id`.

---

## Acceptance criteria

| Condition | Result |
|---|---|
| Clean invoice fixture extracts `invoice_number` and `total_amount` with confidence ≥ 0.80 | Required |
| Low-quality scan confidence < 0.65 and `escalated = true` | Required |
| Low-quality scan raises `DOCUMENT_OCR_CONFIDENCE_LOW` review issue | Required |
| All 4 fixtures emit `INTAKE_OCR_COMPLETED` audit event | Required |
| No `DOCUMENT_OCR_CONFIDENCE_LOW` review issues on clean, multi-page, or email attachment fixtures | Required |

Any single failure blocks the deploy.

---

## Failure handling

On any step failure:

1. Emit `LIVE_TEST_FAILED` with:
   - `fixture_name`: e.g., `doc_intake_low_quality_scan`
   - `step_number`: 1–5
   - `failure_detail`: the specific assertion that failed (missing field, wrong confidence, missing review issue, etc.)
2. Block deploy.
3. Operator investigation paths: Document AI API model update (re-record fixtures), confidence calibration drift (check `classification_confidence_output_schema` recalibration), review issue registration missing (check Block 09 Phase 05 issue type registration), clean fixture field extraction regression (check Block 09 Phase 03 extraction rules for invoice fields).

---

## Cross-references

- `tool_ocr_extract_document` — `intake.ocr_and_extract` tool definition; side-effect classes and AI tier declaration
- `evidence_pdf_schema` — schema for the document records produced by this intake path
- `live_integration_test_runbook` — cross-block cadence, cost containment, recording procedure, and drift detection infrastructure
- `audit_event_taxonomy` — `INTAKE_OCR_COMPLETED`, `INTAKE_OCR_ESCALATED`, `INTAKE_OCR_FAILED`, `LIVE_TEST_FAILED`
- `google_document_ai_integration` — Document AI EU endpoint, credential management, and error handling
- `ai_response_recording_fixtures` — fixture replay for Document AI responses in standard CI runs
- Block 09 Phase 02 — `intake.ocr_and_extract` implementation; confidence computation
- Block 09 Phase 05 — review issue creation for OCR confidence failures
- Block 09 Phase 10 — end-to-end document intake tests; primary fixture host
