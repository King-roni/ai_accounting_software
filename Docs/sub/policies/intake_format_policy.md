# Intake Format Policy

**Category:** Policies · **Owning block:** 03 — Document Intake · **Stage:** 4 sub-doc (Layer 2)

This policy defines which file formats the platform accepts for document intake, the size limits per format, handling rules for multi-page documents, and the steps taken before a file is handed to the OCR or parsing pipeline.

---

## 1. Accepted Document Formats

### 1.1 Invoice and Receipt Documents

| Format | MIME Type | Max File Size | Notes |
|---|---|---|---|
| PDF | application/pdf | 50 MB | Primary invoice format. Up to 50 pages per file. |
| JPEG | image/jpeg | 10 MB | Single-page image of invoice or receipt. |
| PNG | image/png | 10 MB | Single-page image of invoice or receipt. |
| TIFF | image/tiff | 10 MB | Accepted for scanned documents. Multi-page TIFF treated as multi-page. |

TIFF files with more than 50 pages are rejected at intake with: `INTAKE_PAGE_LIMIT_EXCEEDED`.

Images (JPEG, PNG, TIFF) are treated as single documents containing one page each, unless the TIFF format carries multiple embedded pages. Multi-page TIFF files are split into individual page images before OCR processing.

### 1.2 Bank Statement Formats

| Format | Notes |
|---|---|
| OFX (Open Financial Exchange) | Structured format. Column mapping not required. |
| CSV | Flat file. Column mapping required (see Section 4). |
| MT940 | SWIFT bank statement format. Supported via the MT940 parser. |

Bank statement files do not have a fixed size limit, but individual files exceeding 100 MB are rejected: `INTAKE_BANK_STATEMENT_TOO_LARGE`. Bank statements submitted as PDF are handled by the document intake pipeline and parsed as text, not as structured OFX/CSV.

---

## 2. Rejected Formats

The following formats are explicitly rejected and will not be processed:

| Format | Reason |
|---|---|
| DOCX / DOC | Word-processing documents are not valid invoice source documents. |
| XLSX / XLS | Spreadsheets are not accepted as invoice source documents (use CSV for bank statements only). |
| HTML | Web-page exports contain rendering artefacts and are not reliably parseable as invoices. |
| ZIP / RAR | Archive containers are not accepted. Files must be uploaded individually or via the bulk upload interface which handles server-side extraction. |
| EML / MSG | Email files as invoices are not accepted. Use the Gmail integration to pull attachments directly from email threads. |

Rejected format submissions return HTTP 422 with error code `INTAKE_FORMAT_NOT_SUPPORTED`.

---

## 3. Multi-Page PDF Handling

PDFs are accepted with up to 50 pages per file. The page limit is enforced after decryption and before OCR queuing.

For PDFs containing multiple invoices (combined invoice PDFs), the OCR pipeline attempts to detect page boundaries and split the document into individual invoice records. This is a best-effort operation — users are shown the split proposals and must confirm or adjust before finalisation.

PDFs exceeding 50 pages are rejected with: `INTAKE_PAGE_LIMIT_EXCEEDED`. If a user needs to submit a multi-invoice PDF with more than 50 pages, they must split the file before upload.

Password-protected PDFs are rejected with: `INTAKE_PDF_ENCRYPTED`. The platform does not accept or store encryption passwords.

---

## 4. CSV Column Mapping for Bank Statements

CSV bank statement files require a column mapping to be defined before processing. The required columns are:

| Logical Column | Required | Description |
|---|---|---|
| `transaction_date` | Yes | Date of transaction. ISO 8601 or DD/MM/YYYY accepted. |
| `amount` | Yes | Transaction amount. Positive = credit, negative = debit (configurable per mapping). |
| `description` | Yes | Narrative / description field. Used for counterparty matching. |
| `reference` | No | Bank reference number. Used for deduplication. |
| `balance` | No | Running balance after transaction. Used for integrity checks. |

Column mappings are saved per bank account and reused for subsequent uploads. A mapping must be confirmed by the user on first use. If the CSV header row does not contain the mapped column names, intake is rejected with: `INTAKE_CSV_COLUMN_MISMATCH`.

---

## 5. MT940 Format Support

The platform parses MT940 files using the following field mappings:

- `:60F:` — Opening balance
- `:61:` — Statement line (date, amount, reference)
- `:86:` — Information to account owner (description/narrative)
- `:62F:` — Closing balance

MT940 files with unrecognised field tags are parsed on a best-effort basis. Unknown tags are logged but do not cause intake rejection. Opening and closing balance fields are used to validate the total debit/credit sum of the parsed lines; a mismatch triggers a warning: `MT940_BALANCE_MISMATCH` (non-blocking, severity LOW).

---

## 6. File Size Enforcement

Size limits are enforced at the API gateway before the file reaches the intake service:

- 50 MB for PDF files
- 10 MB for image files (JPEG, PNG, TIFF)
- 100 MB for bank statement files (OFX, CSV, MT940)

Files exceeding the limit are rejected with HTTP 413 and error code `INTAKE_FILE_TOO_LARGE`. The rejection happens before the file is written to storage; no partial file is stored.

---

## 7. Virus Scanning

Every uploaded file is passed through the platform's virus scanning service before being written to permanent storage. The scanning step occurs synchronously during the upload request.

If the scanner returns a positive detection, the file is rejected with HTTP 422 and error code `INTAKE_VIRUS_DETECTED`. The file is not stored. The event is logged as `INTAKE_VIRUS_SCAN_FAILED` with severity HIGH and routed to the security alert queue.

If the scanner is unavailable (service timeout or error), the upload is rejected with HTTP 503 and error code `INTAKE_VIRUS_SCAN_UNAVAILABLE`. The file is not stored. This is a fail-closed design: uploads do not bypass virus scanning under any circumstances.

---

## 8. Content Sniffing

Files are validated against their declared MIME type using content sniffing (magic byte inspection). A file declared as `application/pdf` but with a ZIP magic byte header is rejected. This check occurs after virus scanning and before storage.

Content sniffing rejection returns HTTP 422 with error code `INTAKE_CONTENT_TYPE_MISMATCH`. See `upload_content_sniff_policy.md` for the full sniffing logic.

---

## 9. Audit Events

| Event | Trigger |
|---|---|
| `INTAKE_DOCUMENT_ACCEPTED` | File passed all checks and written to storage |
| `INTAKE_DOCUMENT_REJECTED` | File failed format, size, or content checks |
| `INTAKE_VIRUS_SCAN_FAILED` | Virus detected in uploaded file |
| `INTAKE_PAGE_LIMIT_EXCEEDED` | PDF or TIFF exceeded 50-page limit |

---

## Related Documents

- `intake_file_schema.md` — DDL for the intake_files table
- `intake_size_limits_policy.md` — extended size limit configuration
- `upload_content_sniff_policy.md` — content type sniffing implementation
- `document_source_schema.md` — document source tracking after intake
- `ocr_engine_config_schema.md` — OCR pipeline configuration
- `bank_statement_schema.md` — bank statement parsing output
- `bank_statement_import_failure_runbook.md` — troubleshooting intake failures
