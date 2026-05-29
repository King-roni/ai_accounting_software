# Block 09 — Phase 03: OCR Pipeline

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (OCR & Field Extraction section)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 03 — Document AI client setup, reused here)
- Decisions log: `Docs/decisions_log.md` (Google Document AI; convert + OCR all common attachment types)

## Phase Goal

Run uploaded documents through OCR + structured extraction using the Google Document AI client established in Block 07. Handle attachment conversion (DOCX, JPG, PNG, HEIC → suitable input). After this phase, every `INGESTED` document has either a successful OCR pass producing usable text + per-field confidence, or a flagged failure that downstream extraction (Phase 04) deals with.

## Dependencies

- Phase 02 (state machine; OCR transitions documents to `EXTRACTED` on completion)
- Block 04 Phase 06 (Processing zone — OCR text and Document AI raw responses live here)
- Block 06 Phase 02 (Privacy Gateway — Document AI dispatched as Tier 3 with redaction policy applied to the document payload)
- Block 06 Phase 03 (redaction policy)
- Block 07 Phase 03 (Document AI client — reused; this phase configures an invoice/receipt-tuned processor on top of the same client)
- Block 05 Phase 07 (Document AI service-account credentials via `getSecret`)

## Deliverables

- **Document AI processor selection:**
  - The Block 07 client is reused, but the **processor id** is invoice/receipt-specific (e.g., a Document AI invoice processor distinct from the bank-statement processor).
  - Processor id resolved per document type: invoices → invoice processor, receipts → receipt processor, contracts → general OCR processor (no structured extraction at the OCR layer; field extraction handles it in Phase 04).
- **Attachment conversion** before OCR:
  - **DOCX** → converted to PDF via a headless conversion utility (sub-doc tracks the choice — likely LibreOffice headless or a similar EU-compatible service); the resulting PDF is fed to Document AI.
  - **JPG / PNG / HEIC** → fed directly to Document AI as image inputs (no conversion needed).
  - **PDF** → fed directly to Document AI.
  - Any other format → rejected with a clear `DOCUMENT_FORMAT_UNSUPPORTED` review issue (severity `MEDIUM`); user can re-upload as PDF or image.
- **OCR pipeline steps:**
  1. Read the document file from Raw Upload.
  2. Convert if needed (DOCX path).
  3. Dispatch to Document AI through Block 06's gateway (Tier 3; redaction applied to the raw bytes per the redaction policy — IBANs in invoices get masked before they go to Google).
  4. Persist the raw Document AI response in the Processing zone (`AI_PAYLOAD_REDACTED` artefact type per Block 04 Phase 06).
  5. Capture per-field confidence in `document_extraction_results` (Phase 01) at `extraction_layer = 'TIER3_AI'`. **Document AI is always Tier 3** (an external Google API call routed through the Privacy Gateway); the row never uses `DETERMINISTIC` for OCR output. `DETERMINISTIC` is reserved exclusively for Phase 04 Layer 1's regex/template matches on digital PDF text.
- **Cost tracking** via Block 06 Phase 07's `ai_usage_records` — Document AI calls are page-billed; `compute_seconds` and `cost_estimate` populate per call.
- **Confidence threshold:**
  - Per-field default `0.85`. Below-threshold fields are passed through to Phase 04's deterministic + AI fallback layers for further refinement.
- **Error mapping** (consumed by Block 03 Phase 08):
  - 429 / 5xx / timeout → `MODEL_ERROR transient: true`.
  - 4xx (unsupported format, corrupted file) → moves the document to a flagged-failure state in Phase 02 with a review issue.
  - Document AI returns no extractable content → flagged-failure with a recommendation to re-upload as a different format.
- **Audit events:** `DOCUMENT_OCR_STARTED`, `DOCUMENT_OCR_COMPLETED` (with page count + cost + confidence summary), `DOCUMENT_OCR_FAILED`, `DOCUMENT_FORMAT_REJECTED_UNSUPPORTED`, `DOCUMENT_FORMAT_CONVERTED` (DOCX → PDF case).

## Definition of Done

- A representative invoice PDF (Google, AWS, Anthropic style) goes through OCR end-to-end and produces structured extracted fields with per-field confidence.
- A DOCX uploaded by the user is converted to PDF before OCR and then OCR'd successfully.
- A JPG/PNG/HEIC receipt OCRs directly without conversion.
- An unsupported format is rejected at conversion with a clear review issue; the user is prompted to re-upload.
- Document AI calls go through Block 06's gateway (verified by `AI_GATEWAY_INVOKED` events for each call) and the redaction policy strips IBANs before submission.
- Cost is captured per call in `ai_usage_records`.
- Tests cover happy path per format, conversion path (DOCX), unsupported format, transient-error retry, persistent-error path.

## Sub-doc Hooks (Stage 4)

- **Invoice/receipt processor configuration sub-doc** — exact processor ids, region, version pinning, processor-specific schemas.
- **Attachment conversion library sub-doc** — final choice (LibreOffice headless vs hosted service), EU-residency considerations, sandboxing.
- **Per-field confidence threshold sub-doc** — values per field (some fields like `total` should have stricter thresholds than `description`).
- **Format-rejection UX sub-doc** — message text, list of supported alternatives, when to suggest CSV.
- **Redaction-of-document-content sub-doc** — exact bytes-level redaction for invoice content (masking IBANs in the PDF payload before Document AI sees it is non-trivial).
