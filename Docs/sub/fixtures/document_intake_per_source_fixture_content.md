# Document Intake Per-Source Fixture Content

**Category:** Fixtures · **Owning block:** 09 — Document Intake · **Stage:** 4 sub-doc (Layer 2)

Canonical fixture corpus for Block 09 Document Intake live integration tests, organised by document source type. Each fixture exercises a distinct intake path through the `intake.ocr_and_extract` tool and the surrounding ingestion phase. Fixtures are also used as development seed data for local integration runs.

---

## Purpose

These fixtures establish a shared, version-controlled baseline for:

- Live integration test assertions against `intake.ocr_and_extract` and the document intake pipeline
- Per-source confidence and extraction assertions used in `document_intake_live_integration_runbook.md`
- Duplicate detection path verification
- Audit event emission assertions for Gmail-sourced documents

The fixture files referenced by `fixture_filename` are stored in `fixtures/document_intake/`. The metadata in this document is the authoritative source; fixture files on disk must match the descriptions here.

---

## Fixture format

Each fixture object carries these top-level fields:

| Field | Type | Description |
|---|---|---|
| `fixture_id` | string | Stable identifier; never reused after deletion |
| `source_type` | string | `PDF`, `IMAGE`, `EMAIL_ATTACHMENT`, or `MANUAL_UPLOAD` |
| `fixture_filename` | string | Relative path under `fixtures/document_intake/` |
| `expected_extracted_fields` | object | Expected extraction output for passing assertions |
| `expected_confidence_min` | number | Minimum acceptable confidence score (0.00–1.00) |
| `expected_review_issue` | string or null | Review issue type raised on this fixture, if any |
| `expected_audit_event` | string or null | Audit event that must be emitted for this fixture, if any |

`expected_extracted_fields` shape:

```
{
  "invoice_number": string,
  "total_amount": string,       // decimal string, e.g. "1250.00"
  "issue_date": "YYYY-MM-DD"
}
```

---

## Fixtures

### Fixture 1 — PDF (clean, machine-generated)

```json
{
  "fixture_id": "DIF-001",
  "source_type": "PDF",
  "fixture_filename": "pdf/clean_machine_invoice_a4.pdf",
  "expected_extracted_fields": {
    "invoice_number": "INV-2026-0101",
    "total_amount": "1250.00",
    "issue_date": "2026-04-03"
  },
  "expected_confidence_min": 0.90,
  "expected_review_issue": null,
  "expected_audit_event": null
}
```

**Scenario description.** An A4-format, machine-generated PDF invoice produced by a standard invoicing application. All text layers are embedded; no rasterisation step is required. The `intake.ocr_and_extract` tool must extract all three fields (`invoice_number`, `total_amount`, `issue_date`) with a composite confidence score of at least 0.90. No review issue is raised. No special audit event is asserted beyond the standard `INTAKE_OCR_COMPLETED`.

This fixture is the baseline for any regression involving the clean-PDF path. If this fixture fails, the extraction pipeline has regressed and all other fixtures are unreliable.

---

### Fixture 2 — IMAGE (low-quality scan)

```json
{
  "fixture_id": "DIF-002",
  "source_type": "IMAGE",
  "fixture_filename": "image/receipt_72dpi_scan.png",
  "expected_extracted_fields": {
    "invoice_number": null,
    "total_amount": "87.50",
    "issue_date": "2026-03-22"
  },
  "expected_confidence_min": 0.00,
  "expected_confidence_max": 0.65,
  "expected_review_issue": "DOCUMENT_OCR_CONFIDENCE_LOW",
  "expected_escalation_tier": "TIER_3",
  "expected_audit_event": null
}
```

**Scenario description.** A scanned receipt at 72 DPI. The rasterised image produces an OCR confidence score below 0.65 on the TIER_2 first-pass. The `invoice_number` field is expected to be unextractable (`null`). The `intake.ocr_and_extract` tool must:

1. Attempt TIER_2 extraction first.
2. Detect that the composite confidence is below 0.65.
3. Emit `INTAKE_OCR_ESCALATED` with `escalation_reason: "LOW_CONFIDENCE"`.
4. Invoke the TIER_3 AI gateway for a second-pass extraction attempt.
5. Persist the result (even if confidence remains below 0.65 after escalation).
6. Raise a `DOCUMENT_OCR_CONFIDENCE_LOW` review issue with severity `MEDIUM`.

The `expected_confidence_max` field is not part of the standard fixture schema but is used by the runbook assertion to validate the upper bound. The test asserts that confidence is strictly less than 0.65, not merely that it is non-zero.

This fixture does not assert a specific confidence value after TIER_3 escalation; it asserts that the review issue is raised regardless of the escalated result.

---

### Fixture 3 — EMAIL_ATTACHMENT (Gmail query match)

```json
{
  "fixture_id": "DIF-003",
  "source_type": "EMAIL_ATTACHMENT",
  "fixture_filename": "pdf/email_attached_invoice_clean.pdf",
  "expected_extracted_fields": {
    "invoice_number": "INV-2026-0205",
    "total_amount": "3400.00",
    "issue_date": "2026-04-10"
  },
  "expected_confidence_min": 0.90,
  "expected_review_issue": null,
  "expected_audit_event": "INTAKE_GMAIL_QUERY_MATCHED"
}
```

**Scenario description.** A machine-generated PDF invoice delivered as an email attachment. The Gmail finder (`intake.fetch_gmail_attachments`) discovers the email by matching against the active `document_gmail_queries` entry for the business. The attachment is extracted from the email, staged, and passed to `intake.ocr_and_extract`.

The test asserts that `INTAKE_GMAIL_QUERY_MATCHED` is emitted with the correct `query_id` and `business_id` before the OCR step runs. Extraction quality is the same as DIF-001 (clean PDF path); the fixture reuses a clean PDF file to isolate the Gmail source path from extraction quality.

The `expected_audit_event` field is asserted by the runbook before the standard `INTAKE_OCR_COMPLETED` assertion. Both events must appear in the business audit log for this fixture's run, in order.

---

### Fixture 4 — MANUAL_UPLOAD (direct upload, no Gmail)

```json
{
  "fixture_id": "DIF-004",
  "source_type": "MANUAL_UPLOAD",
  "fixture_filename": "pdf/manual_upload_invoice_clean.pdf",
  "expected_extracted_fields": {
    "invoice_number": "INV-2026-0310",
    "total_amount": "720.00",
    "issue_date": "2026-04-15"
  },
  "expected_confidence_min": 0.90,
  "expected_review_issue": null,
  "expected_audit_event": null
}
```

**Scenario description.** A clean machine-generated PDF uploaded directly via the manual upload endpoint (`POST /api/documents/upload`). The source path bypasses the Gmail finder entirely. No `INTAKE_GMAIL_QUERY_MATCHED` event must be emitted for this fixture. The `DOCUMENT_MANUAL_UPLOAD_RECEIVED` event is emitted instead.

The runbook asserts that `INTAKE_GMAIL_QUERY_MATCHED` is absent from the audit log for this fixture's run. Extraction confidence and field quality must match the clean PDF baseline (DIF-001). This fixture isolates the manual upload path from the Gmail intake path to ensure the two paths do not bleed events into each other.

**Mobile write rejection.** The manual upload endpoint is listed in `mobile_write_rejection_endpoints.md`. Requests originating from a mobile client (`client_form_factor = MOBILE`) must be rejected before the document row is created. The runbook includes a sub-assertion confirming that a mobile upload attempt returns the standard mobile rejection response with no `DOCUMENT_MANUAL_UPLOAD_RECEIVED` event emitted.

---

### Fixture 5 — Duplicate detection

```json
{
  "fixture_id": "DIF-005",
  "scenario_name": "duplicate_detection_same_pdf_twice",
  "source_type": "PDF",
  "fixture_filename": "pdf/clean_machine_invoice_a4.pdf",
  "submission_sequence": [
    { "submission_index": 1, "expected_review_issue": null },
    { "submission_index": 2, "expected_review_issue": "DOCUMENT_DUPLICATE_SUSPECTED" }
  ],
  "expected_confidence_min": 0.90
}
```

**Scenario description.** The same file as DIF-001 (`clean_machine_invoice_a4.pdf`) is submitted twice in the same run for the same business. The first submission is processed normally with no review issue. The second submission triggers the cross-source deduplication check: the `content_hash` of the second file matches the `content_hash` of the already-ingested document. The intake pipeline raises a `DOCUMENT_DUPLICATE_SUSPECTED` review issue on the second submission with severity `MEDIUM` and sets the second document's state to `DUPLICATE_HOLD`.

The `DOCUMENT_CROSS_SOURCE_DEDUPED` audit event must be emitted on the second submission. The first document must remain in its normal post-extraction state; only the duplicate is held.

The `submission_sequence` field is specific to the duplicate detection fixture and is not part of the standard fixture schema. The runbook treats the two submissions as sequential test steps within the same test case.

---

## Storage

Fixture files on disk are stored under `fixtures/document_intake/` with subdirectories matching the `source_type` value (lowercased). Metadata in this document is the source of truth; the runbook reads the JSON blocks in this file to build test input lists.

Adding a new fixture requires: adding a new numbered section in this document, placing the fixture file under the appropriate subdirectory, and adding the corresponding runbook assertion in `document_intake_live_integration_runbook.md`.

---

## Cross-references

- `tool_ocr_extract_document.md` — `intake.ocr_and_extract` tool; TIER_2/TIER_3 escalation logic; confidence threshold definitions
- `document_intake_live_integration_runbook.md` — test step definitions and per-fixture assertions
- `evidence_pdf_schema.md` — `evidence_pdfs` table DDL; `content_hash` field used in duplicate detection
