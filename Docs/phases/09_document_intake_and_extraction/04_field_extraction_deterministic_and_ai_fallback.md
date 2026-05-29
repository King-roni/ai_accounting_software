# Block 09 — Phase 04: Field Extraction (Deterministic + AI Fallback)

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Field Extraction section)
- Block doc: `Docs/blocks/06_ai_layer.md` (Privacy Gateway, three tiers)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 3 — AI assists, rules decide)

## Phase Goal

Take the OCR output from Phase 03 and turn it into a typed, validated set of canonical document fields (supplier, dates, amounts, VAT, line items). Three-layer approach: deterministic patterns first, Tier 2 local LLM second, Tier 3 only when Tier 2 fails. After this phase, every `INGESTED` document either has a complete typed extraction with per-field confidence, or a flagged failure routed to the review queue.

## Dependencies

- Phase 01 (`document_extraction_results` table for per-layer attempts)
- Phase 02 (state machine; this phase transitions `INGESTED → EXTRACTED`)
- Phase 03 (OCR pipeline output is the input to deterministic parsing)
- Block 06 Phase 02 (Privacy Gateway — extraction AI dispatched here)
- Block 06 Phase 04 (prompt registry — extraction prompts registered here)
- Block 06 Phase 05 / 06 (Tier 3 / Tier 2 integrations — for the AI fallback path)

## Deliverables

- **Layer 1 — Deterministic parsing** (fast path for digital PDFs with extractable text and known templates):
  - Template library covering common SaaS invoice patterns: Google Workspace, Google Cloud, AWS, Anthropic, GitHub, Stripe, etc.
  - Each template defines field-extraction regexes / structural rules per field name (`supplier_name`, `invoice_number`, `invoice_date`, `due_date`, `amount_subtotal`, `amount_total`, `currency`, `vat_amount`, `vat_rate`, `payment_reference`).
  - Templates are versioned (sub-doc tracks evolution).
  - On a clean template match (every required field captured): writes a `document_extraction_results` row with `extraction_layer = 'DETERMINISTIC'`, the typed `extracted_fields`, confidence `1.0` per matched field.
  - On a **partial template match** (some required fields captured, others missing): does NOT persist a Layer 1 row. Passes the matched fields as a **hint** into Layer 2; Layer 2 fills the gaps and writes a single `document_extraction_results` row with `extraction_layer = 'TIER2_AI'` carrying the merged result. The final layer attribution reflects the layer that produced the complete output.
  - On no template match: passes through to Layer 2 with no hint.
- **Layer 2 — Tier 2 local LLM extraction** (for OCR'd documents and non-templated invoices):
  - Prompt: `09.extract_invoice_fields.tier2`, registered in Block 06 Phase 04.
  - Input: minimised payload (OCR text + document type hint + business context for VAT-relevance).
  - Output schema: typed `ExtractedFields` with per-field confidence. Schema-validated by the gateway.
  - On confidence ≥ threshold (default `0.75` average across required fields): writes a `document_extraction_results` row at `extraction_layer = 'TIER2_AI'`, returns the result.
  - On confidence < threshold: emits `DOCUMENT_EXTRACTION_TIER2_LOW_CONFIDENCE` and explicitly invokes Tier 3 (per Block 06 Phase 01's "explicit, not silent" rule).
- **Layer 3 — Tier 3 escalation** (Anthropic Claude through the gateway):
  - Prompt: `09.extract_invoice_fields.tier3`, registered in Block 06 Phase 04.
  - Same I/O contract as Tier 2.
  - Writes a `document_extraction_results` row at `extraction_layer = 'TIER3_AI'`.
- **Per-field validation** (applied to the final extracted set regardless of which layer produced it):
  - **VAT number** — country-aware format check (e.g., Cyprus VAT format `CY`+digit+8-digits+letter; EU member-state formats per VIES specification).
  - **Currency** — must be valid ISO-4217.
  - **Dates** — parseable; `invoice_date` must be ≤ `due_date` if both present.
  - **Amounts** — positive numbers; `amount_total = amount_subtotal + vat_amount` within rounding tolerance (sub-doc) when all three are present.
  - Validation failures don't reject the extraction — they flag the field with `validation_failed: true` and produce a MEDIUM review issue (`document.field_validation_failed`).
- **Output to the document:**
  - The final extracted-fields set is written to `documents.extracted_fields_json` (per Block 04 Phase 03's column shape) with `extraction_status` advanced to `EXTRACTED` via Phase 02.
  - The extraction layer used and per-field confidences populate `documents.extraction_confidence_per_field`.
- **Audit events:** `DOCUMENT_EXTRACTION_LAYER1_MATCHED` (deterministic template), `DOCUMENT_EXTRACTION_TIER2_INVOKED`, `DOCUMENT_EXTRACTION_TIER2_LOW_CONFIDENCE`, `DOCUMENT_EXTRACTION_TIER3_INVOKED`, `DOCUMENT_EXTRACTION_RESULT` (final), `DOCUMENT_EXTRACTION_FAILED`, `DOCUMENT_FIELD_VALIDATION_FAILED` (per failed field).

## Definition of Done

- A clean Google Workspace invoice PDF extracts via Layer 1 (deterministic template match) with confidence `1.0` per field.
- An OCR'd handwritten-style invoice extracts via Layer 2 (Tier 2 LLM); produces typed fields with realistic confidences.
- A Tier 2 result with average confidence below threshold escalates explicitly to Tier 3 (verified by audit-event sequence).
- VAT-number format validation catches a malformed VAT number; produces a `document.field_validation_failed` review issue.
- A document where every layer fails ends up in a flagged-failure state with a clear review issue; downstream Block 10 doesn't try to match it.
- Tests cover: deterministic happy path, Tier 2 happy path, Tier 2 → Tier 3 escalation, validation failure, all-layers-failed.

## Sub-doc Hooks (Stage 4)

- **Deterministic template library sub-doc** — exact templates per supplier, version evolution, governance for adding new templates.
- **Extraction prompt design sub-doc** — system + user prompt structure, edge-case handling per field type.
- **Field validation rules sub-doc** — per-field validators with country/locale variations (VAT formats per EU member state).
- **Per-tier confidence calibration sub-doc** — Tier 2 vs Tier 3 confidence scaling, threshold tuning over time.
- **Tolerance for amount-arithmetic sub-doc** — rounding tolerance for `total = subtotal + vat`, locale-specific rounding rules.
