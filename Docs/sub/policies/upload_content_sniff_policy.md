# Upload Content Sniff Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

Binding rules for server-side content-type validation of all uploaded files. Every upload endpoint and every engineer adding an upload path binds to this document. Content-type validation is a security control, not a UX convenience: a malicious actor who can upload an HTML file disguised as a CSV has a path to stored XSS or data exfiltration. This policy eliminates that path.

---

## 1. Trust model

The `Content-Type` header in an upload request is **not trusted**. It is read and logged, but it does not determine whether the upload is accepted. The authoritative content-type determination is made by reading the file's magic bytes — the first N bytes of the file content that identify its format — server-side, after the file bytes are received.

This means:
- A file named `statement.csv` with `Content-Type: text/csv` that is actually a PDF (magic bytes `%PDF`) is rejected.
- A file named `invoice.pdf` with `Content-Type: application/octet-stream` that is actually a valid PDF is accepted (with the corrected content-type recorded).

Content-type mismatch between the header and the detected type is logged in the rejection payload but is not itself a fatal error — the sniff result governs.

---

## 2. Allowed content types by upload category

### Bank statements

| MIME type | Description |
| --- | --- |
| `text/csv` | CSV (comma-separated values) |
| `application/vnd.ms-excel` | Legacy Excel `.xls` |
| `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | Modern Excel `.xlsx` |

Bank statement uploads that produce a detected type outside this list are rejected.

### Supporting documents

| MIME type | Description |
| --- | --- |
| `application/pdf` | PDF (any version) |
| `image/jpeg` | JPEG image |
| `image/png` | PNG image |
| `image/tiff` | TIFF image |

Supporting document uploads that produce a detected type outside this list are rejected.

Adding new allowed types to either list requires a `Docs/decisions_log.md` amendment and a corresponding update to this policy and to the upload pipeline's content-sniff implementation.

---

## 3. Magic byte detection rules

The server reads the first 8 bytes of every uploaded file and matches against the following signatures:

| Detected type | Magic bytes (hex) | Offset |
| --- | --- | --- |
| `application/pdf` | `25 50 44 46` (`%PDF`) | 0 |
| `image/jpeg` | `FF D8 FF` | 0 |
| `image/png` | `89 50 4E 47 0D 0A 1A 0A` | 0 |
| `image/tiff` (little-endian) | `49 49 2A 00` | 0 |
| `image/tiff` (big-endian) | `4D 4D 00 2A` | 0 |
| `application/vnd.ms-excel` / `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | `50 4B 03 04` (ZIP/OOXML) | 0 (further disambiguation via internal structure) |
| `text/csv` | No magic bytes — text heuristic (UTF-8 or ASCII printable, comma or tab delimiters in first line) | N/A |

For `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` vs `application/vnd.ms-excel`: both may begin with the ZIP signature (`50 4B 03 04`). The server reads the ZIP central directory to distinguish OOXML (contains `xl/workbook.xml`) from generic ZIP. A generic ZIP that is not an OOXML workbook is rejected.

For `text/csv`: CSV has no magic bytes. Detection falls back to a UTF-8/ASCII heuristic on the first 512 bytes. A file that is not valid UTF-8 or ASCII is rejected as `text/csv`. A file that is valid UTF-8/ASCII but contains no delimiter-separated structure in the first line is also rejected.

---

## 4. Rejection behavior

A file failing content sniff is **rejected with a structured error**. It is never silently discarded and never written to storage. The rejection response:

```json
{
  "error": "UPLOAD_CONTENT_SNIFF_REJECTED",
  "detected_type": "<detected mime type or null>",
  "declared_type": "<Content-Type header value>",
  "upload_category": "bank_statement | supporting_document",
  "reason": "type_not_allowed | zero_byte | magic_byte_mismatch | size_exceeded"
}
```

The rejection is also logged as the `UPLOAD_CONTENT_SNIFF_REJECTED` audit event (MEDIUM severity). See Section 7.

---

## 5. Maximum upload sizes

| Upload category | Maximum size |
| --- | --- |
| Bank statement | 50 MB |
| Supporting document | 25 MB |

Size is checked before content sniff. A file exceeding the size limit is rejected with `reason: "size_exceeded"` without reading any bytes. The size check uses the `Content-Length` request header as a first-pass gate; if `Content-Length` is absent or inconsistent with the actual bytes received, the server enforces the limit on the received byte count.

---

## 6. Zero-byte rejection

Zero-byte files are rejected unconditionally, regardless of content type or upload category. A file with zero bytes cannot be a valid bank statement or supporting document. The rejection reason is `reason: "zero_byte"`. Zero-byte rejection is checked before the magic-byte detection step.

---

## 7. Execution order

The content sniff pipeline executes in this strict order:

```
1. Authentication + canPerform check (Block 02)
2. Mobile client rejection (mobile_write_rejection_endpoints)
3. Size limit check (Content-Length or received byte count)
4. Zero-byte check
5. Magic-byte content sniff
6. MIME type allowlist check
7. On pass: write to storage.objects (raw-uploads bucket)
8. On pass: create DB row (statement_uploads or documents)
9. On pass: emit successful upload audit event
```

Steps 3–6 are the content sniff pipeline. A failure at any step aborts the pipeline, emits `UPLOAD_CONTENT_SNIFF_REJECTED`, and returns the structured rejection response. No processing-zone write occurs for rejected files.

**OCR and processing-zone writes happen after step 8, not during the content sniff.** The content sniff is a precondition for any downstream processing.

---

## 8. Audit event: `UPLOAD_CONTENT_SNIFF_REJECTED`

| Field | Value |
| --- | --- |
| Domain | `UPLOAD` |
| Event name | `UPLOAD_CONTENT_SNIFF_REJECTED` |
| Severity | MEDIUM |
| Trigger | Any rejection in steps 3–6 of the content sniff pipeline |
| Payload fields | `detected_type`, `declared_type`, `upload_category`, `reason`, `file_size_bytes`, `business_id`, `actor_id` |

This event is in `audit_event_taxonomy` under the `UPLOAD` domain. If the `UPLOAD` domain does not exist in the taxonomy, it must be added (see the taxonomy extension in Step 3 of the authoring instructions).

A burst of `UPLOAD_CONTENT_SNIFF_REJECTED` events from the same `actor_id` within a short window triggers a security alert rule in Block 05 Phase 10. The alert threshold is configurable; the default is 10 rejections in 60 seconds.

---

## 9. Mobile write surface note

Mobile clients are rejected at all upload surfaces per `mobile_write_rejection_endpoints`. Mobile rejection occurs at step 2, before the content sniff pipeline runs. Content sniff never executes for mobile requests.

---

## Cross-references

- `data_layer_conventions_policy` — SHA-256 hex encoding for the content hash stored after a successful upload; UUID v7 for file identifiers
- `storage_bucket_configuration` — the `raw-uploads` bucket that accepted uploads are written to; size limits cross-referenced here
- `audit_event_taxonomy` — `UPLOAD_CONTENT_SNIFF_REJECTED` (MEDIUM) event entry under the `UPLOAD` domain
- `audit_log_policies` — `UPLOAD` domain addition; event naming convention
- `mobile_write_rejection_endpoints` — mobile rejection at step 2 of the upload pipeline
- `Docs/phases/04_data_architecture/05_raw_upload_zone.md` — Phase 05 that owns the upload pipeline; this policy is a sub-doc of that phase's content-sniff hook
- `Docs/phases/05_security_and_audit/10_security_alerting_internal.md` — Phase 10 alert rule for burst `UPLOAD_CONTENT_SNIFF_REJECTED` events
