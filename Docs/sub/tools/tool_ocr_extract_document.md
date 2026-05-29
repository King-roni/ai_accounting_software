# Tool: intake.ocr_and_extract

**Category:** Tools · **Owning block:** 09 — Document Intake · **Stage:** 4 sub-doc (Layer 2)

Performs OCR and structured field extraction on a single document. The tool delegates to the AI gateway and returns a raw extraction envelope; it does not persist results to the `documents` table — that write is the caller's responsibility. The separation keeps the tool's side-effect surface minimal and makes replay safe.

---

## Block reference

Block 09 — Document Intake, INGESTION phase. This tool is called from within the intake pipeline after a document has passed content-sniff validation and been written to the Processing zone.

---

## Purpose

Given a document in the Processing zone, produce: a structured field map, a confidence score, the raw OCR text, and a page count. The caller uses the returned envelope to decide whether to proceed to classification or route the document to the review queue.

---

## Tool signature

```
intake.ocr_and_extract({
  document_id:  UUID,           // UUID v7; references documents.id
  business_id:  UUID,           // UUID v7; used for tenant isolation in the AI gateway call
  run_id:       UUID,           // UUID v7; the workflow run driving this invocation
  source_type:  'PDF' | 'IMAGE' | 'EMAIL_ATTACHMENT'
}) → {
  extracted_fields: object,     // key/value map of recognised fields; shape varies by source_type
  confidence:       number,     // raw score from AI model, 0.0–1.0; not calibrated here
  raw_text:         string,     // full OCR text string before field extraction
  page_count:       number      // integer; 0 if extraction failed before page enumeration
}
```

`extracted_fields` keys depend on the document type inferred by the AI model. Common keys include `vendor_name`, `invoice_number`, `invoice_date`, `total_amount`, `vat_amount`, `iban`, `currency`. The caller must treat all keys as nullable; absence of a key is meaningful.

---

## Registration shape

```ts
engine.registerTool({
  name: "intake.ocr_and_extract",
  schema_version: "1.0",
  side_effect_class: ["WRITES_PROCESSING_ZONE", "EXTERNAL_CALL", "WRITES_AUDIT"],
  ai_tier: "EXTERNAL",
  input_schema_ref: "tool_ocr_extract_document#v1.input",
  output_schema_ref: "tool_ocr_extract_document#v1.output",
  audit_events: [
    "INTAKE_OCR_COMPLETED",
    "INTAKE_OCR_FAILED",
    "INTAKE_OCR_ESCALATED"
  ],
  description_ref: "Docs/sub/tools/tool_ocr_extract_document.md",
});
```

---

## AI tier declaration

**Default path: TIER_2** — the locally-operated model handles the first OCR pass.

**Escalation to TIER_3:** if the returned `confidence` from the TIER_2 pass is below `0.65`, the tool automatically invokes the AI gateway a second time using the TIER_3 (Anthropic Claude) model. The escalated pass uses the same document bytes and a structured re-extraction prompt. The result of the second pass replaces the first; `confidence` in the returned envelope reflects the TIER_3 score.

The tool is registered with `ai_tier: "EXTERNAL"` because it may reach TIER_3. Per `tool_naming_convention_policy`, the tier declaration covers the maximum reachable tier, not the typical-path tier.

Escalation is recorded via `INTAKE_OCR_ESCALATED` before the TIER_3 gateway call. If escalation also fails, `INTAKE_OCR_FAILED` is emitted and the tool returns an error.

---

## Side-effect contract

| Class | Description |
| --- | --- |
| `WRITES_PROCESSING_ZONE` | Writes the raw OCR result (text + extracted fields) to the Processing zone scratch record for the document. Does NOT write to `documents` directly. |
| `EXTERNAL_CALL` | Calls the AI gateway (Block 06). TIER_2 for the first pass; TIER_3 on escalation. |
| `WRITES_AUDIT` | Emits one of `INTAKE_OCR_COMPLETED`, `INTAKE_OCR_FAILED`, or `INTAKE_OCR_ESCALATED` via `emitAudit()` from Block 05 Phase 02. |

The tool does NOT carry `WRITES_RUN_STATE`. Writing the extracted fields back to `documents.extracted_fields` and setting `documents.ocr_status` is the caller's responsibility. This is the proposer pattern from `tool_atomicity_policy`.

---

## Confidence passthrough

The `confidence` value in the returned envelope is the raw score from the AI model, passed through without modification. The caller applies calibration using the logic defined in `classification_confidence_output_schema`. Specifically:

- TIER_2 results: `confidence_calibrated = confidence_raw × 1.00`
- TIER_3 results: `confidence_calibrated = confidence_raw × 1.05`
- Multi-layer agreement and vendor memory boosts are applied by the classification pipeline, not here.

This tool has no visibility into calibration factors; it is a pure extraction primitive.

---

## Failure modes

| Error code | Trigger condition | Behaviour |
| --- | --- | --- |
| `DOCUMENT_UNREADABLE` | PDF is corrupted, password-protected, or the file bytes fail content validation after Processing-zone retrieval | Tool returns error; emits `INTAKE_OCR_FAILED`; Processing zone scratch record is marked `failed`. Caller routes to review queue. |
| `EXTRACTION_TIMEOUT` | AI gateway call does not return within 30 seconds (applies to both TIER_2 first pass and TIER_3 escalation pass independently) | Tool returns error; emits `INTAKE_OCR_FAILED`; caller may retry per `retry_policy`. |
| `UNSUPPORTED_FORMAT` | `source_type` is a valid enum value but the AI gateway rejects the MIME type (e.g., IMAGE subtype not supported) | Tool returns error without invoking AI; emits `INTAKE_OCR_FAILED`. Caller dismisses the document or requests re-upload. |

All three failure modes result in `INTAKE_OCR_FAILED`. The `error_code` field in the audit payload distinguishes which condition occurred.

Partial extractions (model returns fields but `confidence < 0.40`) are not a failure — they return a result with low confidence. The caller decides routing.

---

## Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `INTAKE_OCR_COMPLETED` | LOW | OCR and extraction succeeded; emitted after the Processing zone scratch write completes |
| `INTAKE_OCR_FAILED` | MEDIUM | Any failure mode above; includes `error_code` in payload |
| `INTAKE_OCR_ESCALATED` | LOW | TIER_2 confidence < 0.65; emitted immediately before the TIER_3 gateway call is made |

`INTAKE_OCR_ESCALATED` payload includes: `document_id`, `business_id`, `run_id`, `tier_2_confidence`, `escalation_reason: "LOW_CONFIDENCE"`.

`INTAKE_OCR_COMPLETED` payload includes: `document_id`, `business_id`, `run_id`, `source_type`, `page_count`, `confidence`, `tier_used`, `escalated`.

`INTAKE_OCR_FAILED` payload includes: `document_id`, `business_id`, `run_id`, `source_type`, `error_code`, `error_detail`.

---

## Mobile rejection

Write surfaces that invoke this tool are blocked on mobile clients. The `intake.ocr_and_extract` tool is called from within the document intake pipeline, which is a server-side workflow phase — it is not directly invokable by a client. Any API endpoint that triggers the intake pipeline rejects `client_form_factor = MOBILE` requests before the workflow run is created.

See `mobile_write_rejection_endpoints.md` for the full list of rejected endpoints and the `MOBILE_WRITE_REJECTED` audit event emitted on each rejection.

---

## Idempotency

The tool uses `run_id + document_id` as the dedup key. If the same `(run_id, document_id)` pair is replayed within the active workflow run cycle, the engine's dedup layer returns the cached output without re-invoking the AI gateway. See Block 03 Phase 07 for resumability and dedup semantics.

---

## Cross-references

- `document_gmail_query_schema.md` — upstream schema for Gmail-sourced documents that feed into this tool
- `evidence_pdf_schema.md` — evidence PDF structure; this tool may also be applied to evidence PDFs in some pipeline variants
- `classification_confidence_output_schema.md` — calibration logic the caller applies to the raw `confidence` value returned here
- `ai_gateway_schema.md` — gateway invocation contract, tier authorization, token usage recording
- `mobile_write_rejection_endpoints.md` — endpoints that gate access to the intake pipeline
- `tool_atomicity_policy` — proposer pattern: why this tool returns rather than writes
- Block 06 Phase 01 — AI tier authorization and escalation mechanics
- Block 09 — Document Intake phase doc (full pipeline context)
