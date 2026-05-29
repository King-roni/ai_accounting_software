# Block 07 — Phase 03: PDF Parser via Google Document AI

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 7.2 — Parsing; PDF path)
- Decisions log: `Docs/decisions_log.md` (Google Document AI as the OCR engine across the platform)

## Phase Goal

Implement the PDF statement parser as a registered `(REVOLUT, PDF)` parser that delegates OCR + table extraction to Google Document AI, then converts the extracted tables into the same `ParsedRow[]` shape Phase 02's CSV parser produces. After this phase, PDF statements flow through the same normalization, dedup, and evidence pipeline as CSV — at lower confidence, but with the same downstream contract.

## Dependencies

- Phase 01 (upload pipeline produces PDF `statement_uploads` rows)
- Phase 02 (parser framework registry — this phase registers the `(REVOLUT, PDF)` entry)
- Block 04 Phase 06 (Processing zone — OCR text and intermediate Document AI artefacts live here)
- Block 05 Phase 01 (TLS + cert pinning for outbound to Google APIs)
- Block 05 Phase 07 (Document AI service-account credentials via `getSecret`)
- Block 06 Phase 02 (Privacy Gateway — Document AI dispatched as a Tier 3 call through the gateway with redaction policy applied)
- Block 06 Phase 03 (redaction policy applied to the PDF payload before it reaches Document AI)

## Deliverables

- **Google Document AI client:**
  - Configured with an EU-region processor (Stage 1 hosting decision).
  - Service-account credentials fetched at runtime via `getSecret('google_document_ai_credentials')`.
  - Specialised processor selected per provider — for Revolut PDFs, a generic table-extraction processor is sufficient; provider-specific tuning lives in a sub-doc.
- **Pipeline within the parser:**
  1. Read the PDF from Raw Upload via signed URL.
  2. Submit to Document AI; persist the raw response in the Processing zone (`AI_PAYLOAD` artifact type per Block 04 Phase 06).
  3. Extract the transaction table from the Document AI response.
  4. Map columns to `ParsedRow` fields using the same target shape as Phase 02.
  5. Attach per-row `extraction_confidence_per_field` (JSONB) so Phase 04 can flag low-confidence rows.
- **Confidence threshold:**
  - Each extracted field carries a confidence score from Document AI.
  - Rows where any required field falls below a configurable threshold (default 0.85) are marked `parser_confidence: LOW` and downstream phases route them through additional review.
- **Cost tracking:**
  - Document AI bills per page; each invocation records page count + cost estimate via the same `ai_usage_records` mechanism Block 06 Phase 07 owns (this phase's calls are Tier 3 in the AI taxonomy — they go off-device).
  - Note: the gateway invocation here is bundled into Block 06's framework — Document AI is dispatched through the Privacy Gateway with redaction policy applied (statements have IBANs and personal addresses on them).
- **Failure handling:**
  - Document AI 5xx → `MODEL_ERROR` with `transient: true`; Block 03 Phase 08's retry policy applies.
  - Document AI 4xx (unsupported PDF, corrupted file) → status `FAILED` + review issue.
  - Empty extraction (no tables found) → `FAILED` + review issue suggesting the user re-export as CSV.
- **Audit events:** `STATEMENT_PDF_OCR_STARTED`, `STATEMENT_PDF_OCR_COMPLETED` (with page count + cost), `STATEMENT_PDF_OCR_FAILED`, `STATEMENT_PDF_PARSE_LOW_CONFIDENCE_ROW` — using the `STATEMENT_*` prefix to keep the Block 07 audit family coherent.

## Definition of Done

- A Revolut PDF statement processed end-to-end produces `ParsedRow[]` matching the CSV path's shape.
- Low-confidence rows are flagged and propagate `parser_confidence: LOW` to downstream phases.
- Service credentials are fetched via `getSecret`; an attempt to read them from environment fails the lint rule.
- Document AI calls go through the Privacy Gateway and produce `ai_usage_records` rows.
- A simulated Document AI outage produces a transient `MODEL_ERROR`; persistent failures land as `FAILED` with a review issue.
- Tests cover at least: clean PDF extraction, low-confidence rows, malformed PDF, transient API error.

## Sub-doc Hooks (Stage 4)

- **Document AI processor configuration sub-doc** — processor type, EU region, version pinning, schema mapping.
- **Confidence threshold sub-doc** — default value, per-field overrides, escalation behaviour for low-confidence rows.
- **PDF-to-`ParsedRow` mapping sub-doc** — exact column mapping for Revolut PDF statement layouts.
- **Cost tracking sub-doc** — page-count metering, cost-estimate formula, per-business cost ceiling interaction.
- **Privacy Gateway integration sub-doc** — how PDF parsing routes through Block 06's gateway given that the entire PDF is the payload.
