# tool_upload_pipeline_api

**Category:** Tools · **Owning block:** 04 — Data Architecture · **Co-owner:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The unified HTTP API surface for both bank-statement and document uploads. One endpoint, routed by `upload_kind` into Block 07's statement intake or Block 09's document intake. Owns content-sniff validation per `upload_content_sniff_policy`, size limits, format detection, signed-URL generation, and the canonical `STATEMENT_UPLOADED` / `DOCUMENT_MANUAL_UPLOADED` audit emission.

Block 04 Phase 05 owns the Raw Upload zone and the API surface; Blocks 07 + 09 own the downstream pipelines.

---

## Endpoint

```
POST /uploads
Content-Type: multipart/form-data
Authorization: Bearer <session-token>
X-Client-Form-Factor: DESKTOP
```

### Request body

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `file` | binary | ✓ | The upload payload |
| `business_id` | uuid | ✓ | Target business |
| `upload_kind` | enum | ✓ | One of: `STATEMENT_CSV`, `STATEMENT_PDF`, `DOCUMENT_PDF`, `DOCUMENT_IMAGE`, `DOCUMENT_DOCX`, `DOCUMENT_OTHER` |
| `declared_format` | string | optional | User-declared format (e.g., `revolut_csv_v1`) — used for hint only; content-sniff is authoritative |
| `declared_period_start` | date | optional | For statements; user-declared period |
| `declared_period_end` | date | optional | For statements |
| `intake_intent` | enum | optional | One of: `OUT_WORKFLOW`, `IN_WORKFLOW`, `BOTH` — hints which workflow trigger fires; absent = both fire as applicable |
| `idempotency_key` | uuid | optional | Caller-supplied for retry-safe upload |

### Response

```
HTTP 202 Accepted
Content-Type: application/json

{
  "upload_id": "...",
  "raw_object_uri": "supabase://raw/<business_id>/<upload_id>",
  "content_sniff_result": { "format": "revolut_csv_v1", "size_bytes": 12345, "sha256": "..." },
  "downstream_kind": "STATEMENT",                 // or "DOCUMENT"
  "downstream_dispatch_status": "QUEUED",         // or "DEDUP_HIT" / "REJECTED"
  "dedup_hit_existing_id": "...",                 // present on DEDUP_HIT
  "rejection_reason": "..."                       // present on REJECTED
}
```

## Pipeline flow

```
1. Validate session + permissions (per permission_matrix)
2. Validate client form factor (reject MOBILE per mobile_write_rejection_endpoints)
3. Content-sniff per upload_content_sniff_policy
4. Validate against upload_kind allowlist:
   - STATEMENT_CSV → text/csv or text/plain
   - STATEMENT_PDF → application/pdf
   - DOCUMENT_PDF / _IMAGE / _DOCX / _OTHER → expected MIME types
5. Size check: ≤ 50 MB per file (configurable per business)
6. Idempotency: if idempotency_key + business_id + sha256 matches existing upload → return same upload_id
7. Stream-write to Raw Upload zone (Supabase Storage) with deterministic path
8. Emit STATEMENT_UPLOAD_COMPLETED or DOCUMENT_MANUAL_UPLOADED depending on upload_kind
9. Dispatch downstream:
   - STATEMENT_* → trigger Block 07 INGESTION workflow phase
   - DOCUMENT_* → trigger Block 09 EVIDENCE_DISCOVERY workflow phase
10. Return synchronously with upload_id
```

The downstream workflows run asynchronously. The API returns 202 with `upload_id` and `downstream_dispatch_status` so the client knows the upload is in flight without blocking.

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
- **AI tier:** `NONE`

The tool writes a row to `statement_uploads` or `documents` (depending on `upload_kind`), writes the raw bytes to the Raw Upload zone, and emits a canonical audit event. The downstream OCR / extraction / classification tools carry their own AI tiers separately.

## Audit events

| Event | When |
| --- | --- |
| `STATEMENT_UPLOADED` | `upload_kind` is `STATEMENT_*` |
| `STATEMENT_UPLOAD_COMPLETED` | Same upload — separate event consumed by Block 03 Phase 09 trigger engine |
| `DOCUMENT_MANUAL_UPLOADED` | `upload_kind` is `DOCUMENT_*` |
| `INTAKE_FIXTURE_LOADED` | Fixture-mode replay (Block 07 Phase 10 fixtures) — distinct from operational uploads |

`STATEMENT_UPLOAD_COMPLETED` is the canonical cross-block trigger event per `audit_event_taxonomy` — Block 03 Phase 09's trigger engine subscribes to this event to start the INGESTION workflow phase.

## Pre-conditions and rejections

| Rejection | HTTP status | Reason |
| --- | --- | --- |
| Session invalid / expired | 401 | Re-authenticate |
| Form factor mobile | 403 + `MOBILE_WRITE_REJECTED` | Upload is desktop-only |
| Permission denied | 403 | Insufficient permission (most uploads require `WORKFLOW_TRIGGER`) |
| Format unsupported | 415 + `UNSUPPORTED_MEDIA_TYPE` | Sniffed format not in allowlist |
| Size exceeded | 413 + `PAYLOAD_TOO_LARGE` | Over 50 MB |
| Content-sniff mismatch | 400 + `DECLARED_VS_SNIFFED_FORMAT_MISMATCH` | User declared CSV; sniff says PDF |
| Idempotency conflict | 409 + `IDEMPOTENCY_KEY_REUSED_DIFFERENT_PAYLOAD` | Same key, different SHA |

## Storage shape

Raw object stored at:

```
raw/<business_id>/<upload_kind>/<upload_id>.<extension>
```

The extension is determined by content-sniff (not the user-supplied filename, which can be misleading). Path is deterministic — same business_id + upload_id reproduces the same path.

`storage_folder_structure_policy` (Block 04) owns the path schema; Block 04 Phase 05 owns the Raw Upload zone.

## Idempotency

Per Block 03 Phase 07's resumability framework: an `idempotency_key` plus `(business_id, sha256_of_content)` allows safe retry. Repeated POSTs with the same triple return the same `upload_id` and `STATEMENT_UPLOAD_COMPLETED` is not re-emitted (per `audit_log_policies` event-aggregation rule).

A network retry that supplies the SAME `idempotency_key` but DIFFERENT content fails with `IDEMPOTENCY_KEY_REUSED_DIFFERENT_PAYLOAD` — this is the boundary between safe retry and accidental data corruption.

## Permission

| Upload kind | Required permission surface |
| --- | --- |
| `STATEMENT_*` | `WORKFLOW_TRIGGER` (Owner / Admin / Bookkeeper) |
| `DOCUMENT_*` (manual upload during OUT) | `WORKFLOW_TRIGGER` |
| `DOCUMENT_*` (manual upload during review queue resolution) | `REVIEW_QUEUE_RESOLVE` |

The permission is determined by the call site, not the endpoint. The endpoint accepts the request if EITHER surface is granted.

## Mobile rejection

REJECT — all uploads are write actions per `mobile_write_rejection_endpoints`.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Upload (5 MB CSV) | 500 ms | 1.5 s | 4 s |
| Upload (10 MB PDF) | 1 s | 3 s | 8 s |
| Upload (50 MB PDF — max) | 5 s | 15 s | 40 s |

Latency dominated by stream-write to Supabase Storage. Content-sniff is fast (< 50 ms).

## Concurrency

Concurrent uploads to the same business proceed independently — no per-business lock at the API level. Downstream pipeline workers handle their own per-statement concurrency control.

## Registration

```ts
engine.registerTool({
  name: "intake.upload_pipeline_api",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_upload_pipeline_api#v1.input",
  output_schema_ref: "tool_upload_pipeline_api#v1.output",
  audit_events: ["STATEMENT_UPLOADED", "STATEMENT_UPLOAD_COMPLETED", "DOCUMENT_MANUAL_UPLOADED"],
  description_ref: "Docs/sub/tools/tool_upload_pipeline_api.md",
});
```

## Cross-references

- `tool_naming_convention_policy` — naming + registration
- `audit_log_policies` — `STATEMENT_*` / `DOCUMENT_*` event family
- `upload_content_sniff_policy` (Block 04) — content-sniff magic-byte rules
- `storage_folder_structure_policy` (Block 04) — Raw Upload zone path schema
- `permission_matrix` — `WORKFLOW_TRIGGER` / `REVIEW_QUEUE_RESOLVE` surfaces
- `mobile_write_rejection_endpoints` — mobile rejection
- `event_subscription_pipeline_integration` (Block 03) — Block 03 Phase 09's subscription mechanism
- Block 04 Phase 05 — Raw Upload zone (implementation home)
- Block 07 Phase 01 — bank-statement upload pipeline & file intake
- Block 09 Phase 07 — document manual upload path
- Block 03 Phase 09 — event-driven workflow trigger (consumer)
