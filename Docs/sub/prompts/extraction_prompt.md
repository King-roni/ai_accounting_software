# Document Extraction Prompt

**Block:** 09 — Document Intake
**Category:** Prompts
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Specifies the prompt used to extract structured fields from the raw OCR text of an
invoice or receipt document. This prompt is the AI fallback path in Block 09's field
extraction pipeline; it fires after the deterministic extraction pass has failed to
produce a result with sufficient confidence. The output feeds the document's Processing
zone scratch record and, after review or auto-confirm, the `documents` operational
table.

---

## Prompt Key and Versioning

```
prompt_key:     document_extraction_v1
prompt_version: 1.0.0
```

`prompt_version` follows semver. A major bump requires deprecating the old version and
updating the version table in `prompt_management_policies.md`. Both the old and new
versions remain registered for at least one full workflow-run cycle (30 days) before
the old version is removed, per the deprecation policy in
`tool_naming_convention_policy.md` Section "Schema versioning".

---

## Tier Assignment

**TIER_2 by default.** TIER_2 is the locally-operated model. The input may contain
vendor names and invoice amounts; keeping the extraction on TIER_2 avoids sending
potentially sensitive commercial data to a third-party provider in the common case.

**Escalates to TIER_3** if the first-pass `confidence` output is below 0.65, per
`ai_tier_escalation_policy.md`. Escalation is a second, independent `ai.invoke` call
with the same prompt key and input but `min_tier = TIER_3`. One `AI_TIER_ESCALATED`
event is emitted per escalation step. `INTAKE_OCR_ESCALATED` is emitted immediately
before the TIER_3 call.

Maximum two invocations per document per workflow run phase execution: one TIER_2 pass
and, if needed, one TIER_3 pass. There is no TIER_3-to-higher escalation path.

---

## Input Schema

```typescript
{
  raw_text:    string,                               // OCR-extracted plain text
  source_type: 'PDF' | 'IMAGE' | 'EMAIL_ATTACHMENT', // document origin
  page_count:  number                               // integer >= 1
}
```

`raw_text` is the full plain-text output of the OCR pipeline. It is pre-processed
through the AI privacy gateway (Block 06 Phase 02) before reaching the prompt: any
field values matching the `redaction_field_map.md` PII patterns that are unrelated to
the invoice content (e.g. an email footer containing a personal email address) are
redacted to `[REDACTED]`.

`page_count` informs the model that a multi-page document may have continuation pages
with additional line items.

---

## Output Schema

```typescript
{
  invoice_number:     string | null,
  issue_date:         string | null,    // ISO 8601 date "YYYY-MM-DD"
  due_date:           string | null,    // ISO 8601 date "YYYY-MM-DD"
  vendor_name:        string | null,
  vendor_vat_number:  string | null,    // raw VAT number string as printed
  line_items:         LineItem[] | null,
  total_amount:       number | null,    // decimal; same unit as printed on document
  currency:           string | null,    // ISO 4217 three-letter code
  vat_amount:         number | null,    // decimal; null if not printed on document
  confidence:         number            // 0.0–1.0 aggregate confidence
}

// LineItem shape:
{
  description:  string,
  quantity:     number | null,
  unit_price:   number | null,
  line_total:   number | null
}
```

### Null field semantics

A null value means the field was not found in the document. Callers must treat null
as "not extracted", not as zero or empty string. Specifically:

- `total_amount: null` means the total could not be identified, not that the invoice
  is for zero. A zero-amount invoice would appear as `total_amount: 0`.
- `line_items: null` means no line items were identifiable (e.g. a single-total
  receipt with no itemisation). An empty array `[]` is not a valid output; if no line
  items exist, the field is null.
- `vat_amount: null` means VAT was not separately stated on the document; this is
  common for VAT-exempt invoices or simplified receipts.

These semantics are enforced by the output-schema validation step in `ai.invoke`
before the result is returned to the caller.

---

## Confidence Scoring

`confidence` is the model's aggregate certainty across all extracted fields. It is not
a per-field score; it is a single value representing overall extraction quality for the
document.

Two rules cap confidence below 1.0 regardless of the model's self-assessment:

1. **Missing mandatory field:** If either `invoice_number` or `total_amount` is null
   in the output, confidence is capped at 0.70. These fields are mandatory for an
   invoice to be processable; their absence signals a document that is incomplete,
   illegible, or not an invoice.
2. **Model self-assessment:** The model's own `confidence` value is taken at face
   value when neither mandatory field is null. The cap in rule 1 overrides any higher
   self-assessed value.

The resulting `confidence` value drives:
- **< 0.65 on TIER_2:** escalation to TIER_3.
- **< 0.65 on TIER_3:** the document is flagged for manual review
  (`CLASSIFICATION_CONFIDENCE_LOW` review issue; document state set to `NEEDS_REVIEW`).
- **>= 0.65:** result is accepted; document state advances to `EXTRACTED`.

---

## Prompt Design Notes

The system prompt instructs the model to:
- Return JSON only, with no markdown wrapper or explanatory text.
- Preserve exact strings for fields like `invoice_number` and `vendor_vat_number`
  (do not normalise or reformat).
- Use ISO 8601 format for all dates.
- Infer currency from the document's printed currency symbol if the `currency` field
  is not explicitly stated; default to `EUR` if ambiguous and the document appears to
  be a Cyprus-issued invoice.
- Sum line items to validate `total_amount` where possible; flag a discrepancy by
  reducing `confidence` rather than overriding the printed total.
- Not invent data: a field absent from the document must be null.

---

## Cross-references

- `tool_ocr_extract_document.md` — `intake.ocr_and_extract` tool; calls this prompt
  on the AI fallback path after the deterministic extraction pass
- `evidence_pdf_schema.md` — `documents` table and Processing zone scratch record
  that receives the extracted fields
- `classification_confidence_output_schema.md` — confidence threshold definitions used
  downstream of extraction
- `prompt_management_policies.md` — versioning lifecycle, deprecation, active-version
  table
- `ai_tier_escalation_policy.md` — TIER_2 → TIER_3 escalation rules
- `ai_cache_schema.md` — within-run cache; extraction results cached per
  `(workflow_run_id, cache_key)`
- Block 09 Phase 04 — Field extraction: deterministic and AI fallback (phase doc)
