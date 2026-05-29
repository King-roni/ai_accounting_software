# Tool: intake.ocr_and_extract

**Category:** Tools · Block 07 — Document Intake  
**Tool name:** `intake.ocr_and_extract`  
**Owner:** intake  
**Last updated:** 2026-05-17  
**WRITES_AUDIT:** Yes — emits `INTAKE_OCR_COMPLETED`, `INTAKE_OCR_FAILED`, `INTAKE_OCR_ESCALATED`

---

## 1. Purpose

`intake.ocr_and_extract` performs OCR (Optical Character Recognition) on a PDF bank statement and extracts structured transaction rows from the raw text. It is the primary tool for handling `PDF_OCR` format bank statements that cannot be parsed by the structured CSV/MT940 parsers.

This tool is used exclusively for `detected_format = 'PDF_OCR'` files. For `PDF_NATIVE` files where text can be extracted directly from the PDF structure (no OCR needed), use `intake.extract_pdf_native` instead.

---

## 2. Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| `file_id` | uuid | Yes | FK to `bank_statement_raw.id`. The file to OCR and extract. |
| `ocr_engine` | string enum | No | OCR engine to use: `'TESSERACT'`, `'GOOGLE_VISION'`, `'AWS_TEXTRACT'`. Defaults to the business's configured primary OCR engine (see `ocr_engine_config_schema.md`). |
| `language_hint` | string | No | BCP 47 language hint passed to the OCR engine. Defaults to `'el,en'` (Greek + English) for Cyprus bank statements. Override to `'en'` for purely English statements. |
| `force_engine` | boolean | No | If `true`, do not fall back to secondary engine on failure. Used for testing. Defaults to `false`. |
| `run_id` | uuid | Yes | FK to `workflow_runs.id`. The parent workflow run. |

---

## 3. Outputs

| Field | Type | Description |
|---|---|---|
| `extracted_rows` | array | Structured transaction rows extracted from the document. See Row Schema below. |
| `confidence_score` | float (0.0–1.0) | Overall confidence score for the extraction. Computed as the weighted mean of per-row confidence scores. |
| `ocr_engine_used` | string | The engine that produced the final result (`TESSERACT`, `GOOGLE_VISION`, or `AWS_TEXTRACT`). |
| `page_count` | integer | Number of PDF pages processed. |
| `extraction_duration_ms` | integer | Total elapsed time for OCR + extraction in milliseconds. |
| `rows_flagged_needs_review` | integer | Count of rows with confidence < 0.70 that are flagged `NEEDS_REVIEW`. |
| `fallback_engine_used` | boolean | `true` if the primary engine failed and a secondary engine was used. |

### 3.1 Extracted Row Schema

Each element of `extracted_rows` has:

| Field | Type | Nullable | Description |
|---|---|---|---|
| `row_index` | integer | No | 1-based row index within the extracted output. |
| `date` | string (ISO 8601) | Yes | Transaction date parsed from the OCR text. Null if unparseable. |
| `description` | string | Yes | Transaction description/narrative text. |
| `amount` | decimal string | Yes | Transaction amount (positive = credit, negative = debit). Null if unparseable. |
| `currency` | string (ISO 4217) | Yes | Currency code. Defaults to the statement's detected currency. |
| `balance` | decimal string | Yes | Running balance after this transaction. Null if not present in the document. |
| `raw_text_line` | string | No | The raw OCR text line(s) from which this row was extracted. Preserved for debugging and manual review. |
| `confidence` | float (0.0–1.0) | No | Per-row confidence score. |
| `needs_review` | boolean | No | `true` if `confidence < 0.70`. |

---

## 4. Pipeline

The tool executes the following steps in sequence:

### Step 1: PDF → Image Conversion

The PDF is rendered to images (one image per page) using poppler (`pdftocairo`). Resolution: 300 DPI for standard pages; 400 DPI for pages with small text (detected via page size heuristic). Images are stored in the Processing zone S3 scratch area under `processing/{business_id}/{run_id}/ocr_images/`.

### Step 2: OCR

Images are passed to the configured OCR engine with the `language_hint`. The OCR engine returns raw text with bounding box coordinates per character/word.

**Engine selection:**
- `TESSERACT` — open-source; lowest cost; best for Greek + English mixed text; used as default for most Cyprus banks.
- `GOOGLE_VISION` — cloud API; higher accuracy on handwritten or low-quality scans; higher cost.
- `AWS_TEXTRACT` — cloud API; best for structured table extraction; used for bank statements with clear table formatting (Hellenic Bank, Bank of Cyprus modern statements).

### Step 3: Structured Extraction

The raw OCR text is parsed by the extraction engine (`intake.parse_statement_text`) to identify transaction rows. The extraction engine uses:
- Column alignment heuristics (date column, description column, amount column, balance column).
- Greek-specific number format parsing (period as thousands separator, comma as decimal separator: `1.234,56` = 1234.56).
- Date format detection (DD/MM/YYYY, DD-MM-YYYY, and abbreviated month names in Greek: Ιαν, Φεβ, etc.).

### Step 4: Confidence Scoring

Each extracted row receives a confidence score based on:
- Date parseable and plausible (within ±90 days of the statement period): +0.30
- Amount parseable and within ±6 decimal places: +0.30
- Description non-empty: +0.20
- Balance parseable and consistent with prior balance + amount (within ±0.01 EUR): +0.20

Rows with `confidence < 0.70` are flagged `needs_review = true`. These rows are written to the Processing zone but require accountant review before the run can advance past the INTAKE phase.

### Step 5: Fallback Engine

If the primary OCR engine fails (API error, timeout, or `overall_confidence < 0.50` on first attempt), the tool automatically retries with the secondary OCR engine. The fallback order:

1. Primary engine (from `ocr_engine_config_schema.md` for the business)
2. `AWS_TEXTRACT` (if primary was not TEXTRACT)
3. `GOOGLE_VISION` (if not already tried)
4. `TESSERACT` (always available; last resort)

If all engines fail or all produce `overall_confidence < 0.50`, the tool returns an error and the `INTAKE_OCR_FAILED` event is emitted.

---

## 5. Confidence Threshold and NEEDS_REVIEW Handling

- `confidence >= 0.90` → row is accepted without review flag.
- `0.70 <= confidence < 0.90` → row is accepted but flagged `needs_review = true`. The accountant sees a visual indicator in the intake review UI.
- `confidence < 0.70` → row is flagged `needs_review = true` AND a review issue of type `OCR_LOW_CONFIDENCE_ROW` is raised in Block 14 for accountant action.
- `overall_confidence < 0.50` → extraction is considered failed; fallback engine is tried.

---

## 6. Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `INTAKE_OCR_COMPLETED` | LOW | OCR and extraction completed successfully |
| `INTAKE_OCR_FAILED` | MEDIUM | All OCR engines failed or overall confidence too low |
| `INTAKE_OCR_ESCALATED` | LOW | Tier-2 first-pass confidence < 0.65; escalating to Tier-3 AI |

### INTAKE_OCR_COMPLETED Payload

```json
{
  "document_id": "<file_id>",
  "business_id": "<uuid>",
  "run_id": "<uuid>",
  "source_type": "PDF_OCR",
  "page_count": 4,
  "confidence": 0.87,
  "tier_used": 2,
  "escalated": false,
  "ocr_engine_used": "TESSERACT",
  "rows_extracted": 42,
  "rows_flagged_needs_review": 3,
  "extraction_duration_ms": 4821
}
```

### INTAKE_OCR_FAILED Payload

```json
{
  "document_id": "<file_id>",
  "business_id": "<uuid>",
  "run_id": "<uuid>",
  "source_type": "PDF_OCR",
  "error_code": "ALL_ENGINES_FAILED",
  "error_detail": "TESSERACT: timeout; GOOGLE_VISION: confidence=0.31; AWS_TEXTRACT: unsupported_language"
}
```

---

## 7. Language Support for Greek Bank Statements

Cyprus bank statements (Hellenic Bank, Bank of Cyprus, AstroBank, Eurobank Cyprus) are issued in Greek, English, or bilingual format. The tool supports:

- Greek (el): full support for Greek character OCR, Greek date formats, Greek number separators.
- English (en): full support.
- Bilingual (el + en): `language_hint = 'el,en'` causes the OCR engine to attempt recognition in both scripts on each page.

Greek-specific parsing rules:
- Date abbreviations: Ιαν (Jan), Φεβ (Feb), Μαρ (Mar), Απρ (Apr), Μαϊ (May), Ιουν (Jun), Ιουλ (Jul), Αυγ (Aug), Σεπ (Sep), Οκτ (Oct), Νοε (Nov), Δεκ (Dec).
- Amount format: `1.234,56` → 1234.56. `1,234.56` → 1234.56 (English format also accepted).
- Debit/credit indicators: `ΧΡ` (debit), `ΠΙΣ` (credit); also `DR` / `CR` for English statements.

---

## 8. Mobile

This tool is **not directly callable from mobile clients**. It is triggered server-side by the intake pipeline when a document is uploaded via mobile. There is no mobile-facing API endpoint that invokes `intake.ocr_and_extract` directly.

**Minimal mobile interaction pattern:**

1. The mobile client uploads a document (PDF bank statement) via the upload pipeline API (`tool_upload_pipeline_api.md`).
2. The upload pipeline classifies the file as `PDF_OCR` format and enqueues an OCR extraction job server-side.
3. `intake.ocr_and_extract` is invoked by the workflow engine as part of the INTAKE phase — this step is entirely server-side and asynchronous relative to the mobile upload call.
4. Mobile receives an async notification (`INTAKE_OCR_COMPLETED` or `INTAKE_OCR_FAILED`) via the push notification channel when extraction completes. See `tool_notify_send.md` for the notification dispatch.
5. The mobile client may then poll or receive a push update to display the extracted transaction rows for review.

All invocations are from the service role within the workflow execution context. `MOBILE_WRITE_REJECTED` is not applicable because this tool is never exposed at the authenticated mobile API layer.

---

## 9. Error Codes

| Code | Description |
|---|---|
| `FILE_NOT_FOUND` | `file_id` does not exist in `bank_statement_raw` |
| `FILE_NOT_PDF_OCR` | `detected_format != 'PDF_OCR'`; wrong tool for this file type |
| `PDF_RENDER_FAILED` | poppler failed to render PDF to images (corrupt PDF or unsupported version) |
| `OCR_ENGINE_TIMEOUT` | OCR engine did not respond within 120 seconds |
| `OCR_ENGINE_API_ERROR` | Cloud OCR engine returned an API error |
| `ALL_ENGINES_FAILED` | All configured OCR engines failed or produced insufficient confidence |
| `EXTRACTION_PARSE_ERROR` | Extraction engine failed to parse OCR output into rows |

---

## Mobile

This tool runs server-side only and is not directly invocable from mobile clients. The mobile client uploads a document via the intake upload endpoint; the OCR extraction pipeline is triggered asynchronously. Mobile receives an async push notification (INTAKE_OCR_COMPLETED or INTAKE_OCR_FAILED) when extraction completes.

---

## 10. Cross-References

- `bank_statement_raw_schema.md` — `file_id` source table; `parse_status` transitions
- `ocr_engine_config_schema.md` — per-business OCR engine configuration
- `audit_event_taxonomy.md` — `INTAKE_OCR_COMPLETED`, `INTAKE_OCR_FAILED`, `INTAKE_OCR_ESCALATED`
- `intake_size_limits_policy.md` — page count limits (max 200 pages per file)
- `tool_intake_parse.md` — sibling tool for CSV/MT940/CAMT053 formats
- `policies/tool_schema_definition_policy.md` — tool definition standards
- Block 07 Phase 02 — intake OCR pipeline implementation
