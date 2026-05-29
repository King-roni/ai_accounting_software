# google_document_ai_integration

**Category:** Integrations · **Owning block:** 07 — Bank Statement Pipeline · **Co-owner:** 09 — Document Intake & Extraction · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The Google Document AI external API contract. Per Stage 1 cross-cutting decision: "OCR engine: Google Document AI (managed, EU regions). Used by Block 07 for PDF statements and Block 09 for image/scanned documents."

The integration is a Tier 3 AI call per Block 06's tier model — every invocation goes through the AI Privacy Gateway. Redaction applies; raw bytes leave EU-residency boundaries only within Google's EU multi-region.

---

## Provider configuration

| Setting | Value |
| --- | --- |
| Provider | Google Cloud Platform — Document AI |
| Region | EU multi-region (locked per Stage 1 — no exceptions) |
| Processors | Two distinct processors |
| Auth | Service account credentials, JSON-key, encrypted at rest per `oauth_token_encryption_schema` pattern |

### Processor 1 — Bank statement parser

| Property | Value |
| --- | --- |
| Type | `BANK_STATEMENT_PROCESSOR` (custom-trained) or `OCR_PROCESSOR` (text-only fallback) |
| Use | Block 07 PDF statement parsing (Revolut and other formats) |
| Per-call latency target | P95 < 8 seconds for typical statement |
| Cost | ~$0.02-0.05 per page (Cyprus-EU pricing) |

### Processor 2 — Invoice / document parser

| Property | Value |
| --- | --- |
| Type | `INVOICE_PROCESSOR` (form parser, structured invoice extraction) or `FORM_PARSER` (generic) |
| Use | Block 09 OCR pipeline for invoices, receipts, documents |
| Per-call latency target | P95 < 10 seconds |
| Cost | ~$0.02-0.05 per page |

Per-business processor IDs configurable in `business_workflow_config` (typically the project defaults are used).

## Request shape

```http
POST https://eu-documentai.googleapis.com/v1/projects/{project_id}/locations/eu/processors/{processor_id}:process
Authorization: Bearer <service-account-jwt>
Content-Type: application/json

{
  "rawDocument": {
    "content": "<base64-encoded file bytes>",
    "mimeType": "application/pdf"
  },
  "fieldMask": "text,pages.formFields,pages.tables,entities"
}
```

Pre-call redaction applies per `redaction_policies` — the file bytes themselves are NOT redacted (the bytes are the document), but the API response goes through the schema validator before persistence.

## Response shape (excerpts)

```json
{
  "document": {
    "text": "...full extracted text...",
    "pages": [
      {
        "pageNumber": 1,
        "formFields": [
          {"fieldName": {"textAnchor": {...}, "content": "Invoice Number"}, "fieldValue": {"content": "INV-2026-0142"}, "fieldNameConfidence": 0.97, "fieldValueConfidence": 0.95}
        ],
        "tables": [...]
      }
    ],
    "entities": [
      {"type": "supplier_name", "mentionText": "Andreas Karasidis Constructions Ltd", "confidence": 0.94},
      {"type": "total_amount", "mentionText": "3,929.50", "confidence": 0.91}
    ]
  }
}
```

Per Block 09 Phase 03: every response gets `extraction_layer = 'TIER3_AI'` per the 2026-05-07 Block 09 scan fix — Document AI output is a Tier 3 external call, not deterministic.

## Auth

Service account credentials with `documentai.processors.processDocuments` IAM permission. Credentials are stored encrypted via `oauth_token_encryption_schema` pattern (sibling — same Vault → DEK chain). Decrypted at call time via `auth.get_decrypted_oauth_token`-style wrapper.

Service account is shared across all businesses (not per-business). Cost is tracked per-business via the AI Gateway's `ai_usage_records` per `ai_usage_records_schema`.

## Tier 3 routing

Per `gateway_bypass_detection_policy` (now part of `redaction_policies` cross-references): Document AI is a Tier 3 invocation. The call path is:

```
Block 07/09 → intake.ocr_and_extract → AI Gateway → google_document_ai_integration → Google EU
```

The gateway:
- Applies cost-ceiling per `ai_cost_projection_policy`
- Records the call in `ai_usage_records`
- Emits `AI_GATEWAY_INVOKED` with `dispatched_tier = EXTERNAL`

Bypass detection: a tool that calls this integration directly without going through the gateway fails the `gateway_bypass_detection_guard` lint per the 2026-05-07 Block 07 scan.

## Error handling

| HTTP status | Class | Retry |
| --- | --- | --- |
| 200 | Success | — |
| 400 (invalid request, unsupported format) | Permanent | No |
| 401 (auth failure) | Permanent | No (rotate credentials) |
| 429 (rate limit) | Transient | Exponential backoff per `event_emission_transactional_policy` shape — 1s → 2s → 4s → 8s, max 4 retries |
| 5xx | Transient | Exponential backoff, max 4 retries |
| Network error | Transient | Exponential backoff, max 4 retries |

After retry exhaustion: emit `DOCUMENT_OCR_FAILED`, set extraction_layer = 'FAILED', raise `intake.ocr_failed` review issue (HIGH).

## Rate limits

Google Document AI default: 600 requests per minute per project (raisable on request).

The integration enforces a per-second rate cap of 10 calls (well under the 600/min ceiling) to leave headroom for retries.

Concurrent calls share the global per-project quota — a burst from one business doesn't starve other businesses, but operations monitors the call rate.

## EU residency

Stage 1 hard rule: "Hosting region: EU only (strict). No exceptions for databases, storage, processing, or AI calls."

The endpoint URL (`eu-documentai.googleapis.com`) is pinned in code. Configuration uses an allowlist of acceptable URLs; any other URL fails at request-time with `EU_RESIDENCY_VIOLATION`.

Document AI EU multi-region keeps data in EU. Google's documented behavior: input documents and extraction results stay in EU regions; no replication outside.

## Audit events

| Event | When |
| --- | --- |
| `AI_GATEWAY_INVOKED` | Gateway wraps the call — single event captures the whole invocation |
| `DOCUMENT_OCR_COMPLETED` | Successful extraction |
| `DOCUMENT_OCR_FAILED` | Final failure after retry exhaustion |

Per `audit_log_policies` aggregation: per-call events are aggregated when multiple files are processed in one workflow run.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Document AI invoice (typical, 1 page) | 4 s | 10 s | 25 s |
| Document AI statement (10 pages) | 8 s | 20 s | 45 s |

Beyond P99: timeout at 60 seconds per call; treated as transient failure and retried.

## Cost containment

Per `ai_cost_projection_policy` (now merged into the AI policy cluster): pre-call cost projection sums expected per-page cost; if the projection exceeds the per-run ceiling, the call goes through cost-ceiling-override per Block 06 Phase 08.

Typical OUT_MONTHLY run costs: 5-20 invoice OCR calls × $0.04 average ≈ $0.20-0.80 per run. The cost-ceiling default per Cyprus business: $10/run (configurable).

## Recording fixtures

Per `ai_response_recording_fixtures` (Fixtures, Block 07): every test that touches Document AI records the request + response pair so test runs are deterministic without re-invoking the live API. The `live_integration_test_runbook` describes the recording procedure.

## Cross-references

- `audit_log_policies` — `AI_*` / `DOCUMENT_*` events
- `redaction_policies` — pre-call redaction (out-of-scope for raw bytes; in-scope for response schema)
- `ai_cost_projection_policy` — cost-ceiling integration
- `ai_response_recording_fixtures` — test recording
- `live_integration_test_runbook` — live-API procedure
- `ai_usage_records_schema` (Block 06) — per-call usage record
- Block 06 Phase 02 — AI Privacy Gateway pipeline
- Block 07 Phase 03 — PDF parser via Google Document AI
- Block 09 Phase 03 — OCR pipeline
- Stage 1 decision — Google Document AI as OCR engine
- 2026-05-07 Block 09 scan fix — extraction_layer = 'TIER3_AI'
