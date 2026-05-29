# extraction_policies

**Category:** Policies · **Owning block:** 09 — Document Intake · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the binding rules governing how data is extracted from uploaded documents — invoices, receipts, and contracts. These rules are constraints on the extraction pipeline, not implementation detail. Every tool in the `intake` namespace that touches document extraction must comply; non-compliant tools are rejected at code review.

---

## Section 1 — Extraction engine selection

**Primary:** Google Document AI (Block 09 Phase 03, Phase 04).

**Fallback:** Anthropic Claude via Block 06 AI gateway (Tier 3 — declared `EXTERNAL` in the tool registration).

The fallback path is invoked when Document AI returns an error after the retry sequence described in Section 4. It is not invoked when Document AI succeeds with a low-confidence result — that case routes to the review queue (Section 3), not to the Claude fallback. Claude is a fallback for unavailability, not for low confidence.

**No other extraction engines** are permitted in MVP without a `decisions_log.md` amendment.

Both engines are invoked exclusively through `intake.ocr_and_extract`; no code path may call the Document AI SDK or the Block 06 Claude gateway directly from outside this tool. The bypass-detection guard pattern from Block 06 Phase 05 applies to the Claude invocation within this tool. Tool registration declares AI tier `EXTERNAL` because the Claude path is reachable; the Document AI path is an `EXTERNAL_CALL` that does not involve the Block 06 gateway.

---

## Section 2 — Write zone constraint

Extraction results are **always** written to the Processing zone first (`WRITES_PROCESSING_ZONE` side-effect class per `tool_naming_convention_policy`). This applies to all extraction outputs: parsed field values, confidence scores, document type labels, and raw OCR text.

Extraction results are **never** written directly to the `transactions` table, the `documents` table, or any operational-zone table during the extraction step. Promotion from Processing zone to operational tables is a separate step owned by `intake.promote_extracted_fields`, which runs after human review confirms the extraction result (or auto-confirms it when confidence is sufficient).

**Violation of this rule** (writing extraction output directly to `transactions` or `documents`) is a code-review-blocking violation. The side-effect class declaration on the tool registration enforces this at the tooling layer; the code review check validates the implementation.

---

## Section 3 — Confidence thresholds and review routing

Confidence scores are produced per field and as an overall document-level score. The document-level score drives review routing.

| Condition | Action |
|---|---|
| Overall confidence ≥ 0.70 | Extraction result is eligible for auto-confirmation; no review issue required unless individual field scores are low |
| Overall confidence < 0.70 and ≥ 0.40 | Review issue raised with severity `MEDIUM`; extraction result held in Processing zone pending reviewer confirmation |
| Overall confidence < 0.40 | Review issue raised with severity `HIGH`; extraction result held in Processing zone; accountant notification triggered |

Thresholds are system-level defaults. No per-business override for confidence thresholds is supported in MVP. An override mechanism is a Stage 2 deferral.

Per-field confidence scores below 0.50 are surfaced individually in the review card regardless of the overall document score, so reviewers can confirm or correct specific fields without rejecting the entire extraction result.

---

## Section 4 — Document AI retry and fallback sequence

1. `intake.ocr_and_extract` calls Google Document AI.
2. On a transient error (HTTP 429, 503, 504, or timeout), the tool retries with exponential backoff up to **3 attempts** total (1 initial call + 2 retries). Backoff intervals: 2 s, 8 s.
3. If all 3 attempts fail with transient errors, **one** Claude fallback invocation is made via the Block 06 AI gateway (Tier 3). The Claude invocation carries the raw OCR text (if partial OCR was returned by Document AI) or the raw file bytes (if no OCR was returned).
4. If Document AI returns a non-transient 4xx error (not 429), retries are skipped and the Claude fallback is attempted immediately. Rationale: a 4xx likely indicates a request-shape problem with the specific document; Claude can handle unstructured content.
5. If the Claude fallback also fails or returns an unusable result, the document is moved to `EXTRACTION_FAILED` state, a `HIGH`-severity review issue is raised, and the workflow phase records `FAILED` for this document.
6. A successful Claude fallback result is written to the Processing zone with `extraction_engine = CLAUDE_FALLBACK` tagged on the extracted fields row. The confidence threshold logic in Section 3 applies identically to Claude-produced results.

---

## Section 5 — Immutability of extraction output

Once an extraction result is written to the Processing zone by `intake.ocr_and_extract`, it is **immutable**. The row is never updated by subsequent processing steps.

Corrections go through the review queue:
- A reviewer edits a field value via the review queue UI.
- The edit creates a new `extraction_corrections` row referencing the original extracted-fields row.
- `intake.promote_extracted_fields` applies the correction on promotion, writing the corrected value to the `documents` table.
- The original extraction result is preserved unchanged for audit traceability.

Direct `UPDATE` of the Processing-zone extraction row by any tool other than the initial writer is a code-review-blocking violation.

The immutability rule applies equally to the Claude fallback extraction result. Whether the extraction was produced by Document AI or by Claude, once written to the Processing zone the row is immutable. Corrections always go through the `extraction_corrections` path.

---

## Section 6 — Document type detection

Document type detection (invoice vs receipt vs contract vs unknown) is a **pre-extraction classification step** that runs before OCR and field extraction.

Sequence:
1. `intake.classify_document_type` runs on the uploaded file.
2. If the detected type is `INVOICE`, `RECEIPT`, or `CONTRACT`, the OCR and extraction pipeline proceeds for that document type (different field schemas apply per type).
3. If the detected type is `UNKNOWN`, the document type is surfaced to the reviewer before extraction proceeds; extraction is not triggered until the reviewer assigns a type.
4. If the detected type is a type the system explicitly does not support (e.g., a bank statement submitted to the document intake path, a scanned page from a booklet), the document is rejected with error code `DOCUMENT_TYPE_UNSUPPORTED`.

`DOCUMENT_TYPE_UNSUPPORTED` is a terminal rejection. The document does not enter the extraction pipeline. A `MEDIUM`-severity review issue is raised informing the user that the file type is not supported in the document intake path.

---

## Section 7 — Tool ownership

`intake.ocr_and_extract` is the **sole tool** that owns the OCR-and-extraction path. No other tool may invoke Document AI or the Claude extraction prompt directly. The tool is declared with side-effect classes `WRITES_PROCESSING_ZONE | EXTERNAL_CALL | WRITES_AUDIT` and AI tier `EXTERNAL` per `tool_naming_convention_policy`.

Auxiliary tools that operate on the extraction output (e.g., `intake.promote_extracted_fields`, `intake.classify_document_type`) are declared separately with their own side-effect classes. The ownership boundary is: `intake.ocr_and_extract` writes to Processing zone; all other tools read from it.

---

## Section 8 — Mobile write rejection

Document extraction is a server-side pipeline operation. No write surfaces in the extraction pipeline are available on mobile clients. The manual upload endpoint (which triggers extraction) is a write surface and is rejected for mobile clients per `mobile_write_rejection_endpoints.md`. Read access to extracted field values (via the review queue) is permitted on mobile.

---

## Section 9 — Audit events

Extraction tools emit the following audit events via `emitAudit()` per `audit_log_policies`:

| Event | When | Severity |
|---|---|---|
| `DOCUMENT_INTAKE_STARTED` | `intake.ocr_and_extract` begins processing a document | LOW |
| `DOCUMENT_INTAKE_COMPLETED` | Extraction result written to Processing zone successfully | LOW |
| `DOCUMENT_EXTRACTED_FIELDS_PERSISTED` | Extracted fields promoted from Processing zone to `documents` table | LOW |
| `DOCUMENT_OCR_COMPLETED` | OCR step succeeded (Document AI or Claude fallback) | LOW |
| `DOCUMENT_OCR_FAILED` | All retry and fallback attempts exhausted; no usable OCR result | MEDIUM |

A `DOCUMENT_OCR_FAILED` event triggers a `HIGH`-severity review issue when the document is an invoice or receipt required for matching. For contracts and other optional documents, the review issue is `MEDIUM`.

---

## Workflow run states applicable to extraction

A document-intake workflow run that enters the extraction phase may occupy the following run states from the canonical 10-value set: `CREATED`, `RUNNING`, `REVIEW_HOLD`, `FAILED`. The state `REVIEW_HOLD` is entered when a confidence threshold triggers a review issue. The state `FAILED` is entered when the retry and fallback sequence (Section 4) is exhausted without a usable result. States `PAUSED`, `AWAITING_APPROVAL`, `FINALIZING`, `FINALIZED`, `CANCELLED`, and `COMPENSATING` are not entered during the extraction phase itself.

---

## Cross-references

- `audit_log_policies` — `DOCUMENT_*` and `INTAKE_*` domains; audit events emitted by extraction tools
- `audit_event_taxonomy` — `DOCUMENT_INTAKE_STARTED`, `DOCUMENT_INTAKE_COMPLETED`, `DOCUMENT_EXTRACTED_FIELDS_PERSISTED`, `DOCUMENT_OCR_COMPLETED`, `DOCUMENT_OCR_FAILED`
- `document_source_schema` — source records that feed the extraction pipeline
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
- `tool_naming_convention_policy` — `intake.*` namespace; `WRITES_PROCESSING_ZONE` side-effect class; `EXTERNAL` AI tier
- `data_layer_conventions_policy` — Processing zone write semantics; canonical JSON for extracted field storage
- Block 06 Phase 05 — Anthropic Claude integration; fallback invocation path; Tier 3 gateway
- Block 09 Phase 02 — document lifecycle state machine; `EXTRACTION_FAILED` state
- Block 09 Phase 03 — OCR pipeline; Document AI client configuration; retry/backoff
- Block 09 Phase 04 — field extraction; deterministic and AI fallback paths; per-field confidence
- Block 09 Phase 07 — manual upload path; the trigger point for extraction on manually uploaded documents
- Block 14 — Review Queue; review issues raised on low confidence; correction workflow; `extraction_corrections` table
- Block 03 Phase 07 — resumability and idempotency; `intake.ocr_and_extract` retry semantics
