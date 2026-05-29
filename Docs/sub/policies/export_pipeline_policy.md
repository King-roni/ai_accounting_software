# Export Pipeline Policy

**Category:** Policies · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

Policy governing the 13 export pipelines declared in Block 16 Phase 09. Commits to sync-vs-async dispatch thresholds, signed-URL TTL, export-file retention rules, permission gates per export class, mobile access rules, and idempotency semantics. Every export initiation path — from the dashboard's "Export" button to a programmatic API call — binds to these rules.

---

## 1. Sync vs async dispatch threshold

Exports are generated synchronously (blocking the HTTP response) or asynchronously (job queued; signed URL returned when ready) depending on estimated size. The threshold is per-format:

| Format | Sync threshold | Above threshold behaviour |
|---|---|---|
| **CSV** | ≤ 10,000 rows | Queue job; return `export_id` with `status = PENDING` |
| **XLSX** | ≤ 1,000 rows | Queue job; lower threshold due to per-cell formatting memory overhead |
| **PDF** | Always async | PDF generation is always queued — no inline PDF generation in MVP |
| **JSON** | ≤ 5,000 rows / ≤ 2MB | Queue job above threshold |
| **XML** | ≤ 5,000 rows / ≤ 2MB | Queue job above threshold (applies to VIES export) |
| **ZIP** | Always async | Archive packages and accountant packs are always queued |

Row-count estimation: the dispatcher queries a per-`export_kind` count estimate (approximate, using `reltuples` for large tables) before rendering. If the estimate is unavailable or the actual row count exceeds threshold mid-generation, the job is promoted to async automatically (the HTTP response transitions to return an `export_id` with a 202 status).

For synchronous exports, the signed URL is included directly in the HTTP 200 response. For async exports, the client polls `GET /exports/{export_id}` or listens for an in-app notification (Block 14 Phase 06's notification surface) to learn when the export is `COMPLETED`.

---

## 2. Signed-URL TTL

All completed export files are served via signed URLs with a **30-minute TTL** regardless of format, size, or export kind. After 30 minutes the URL is no longer valid.

If a URL expires before the user downloads the file:
- The user re-requests the export via the same export-initiation UI.
- The dispatcher checks for an existing `COMPLETED` export matching `(export_type, workflow_run_id, format, scope)`.
- If the source data has not changed (per `source_data_hash` comparison), the existing storage object is used and a fresh signed URL is generated. No re-generation is required.
- If source data has changed, a new export is generated.

Each signed-URL generation increments `exports.download_count`. The `download_count` column is informational; it does not gate access.

`force_regenerate = true` in the dispatch request bypasses the idempotency check and always produces a new export, even if a valid cached copy exists.

---

## 3. Idempotency and cache semantics

The dispatcher is idempotent by `(business_id, export_kind, format, scope)`:

1. **Within-the-same-minute deduplication:** two requests for the same export within 60 seconds collapse to one export row. The second request returns the `export_id` of the first. This covers UI double-click and network-retry scenarios.
2. **Data-unchanged cache:** if a `COMPLETED` export exists for the same key and the `source_data_hash` has not changed since `completed_at`, the existing export is returned without re-generation.
3. **`force_regenerate = true`:** the caller explicitly requests a fresh export. The existing export row is superseded (its `status` remains `COMPLETED`; a new row is created). Emits `EXPORT_FORCE_REGENERATED`.

The `source_data_hash` is a SHA-256 (per `data_layer_conventions_policy`) of a per-`export_kind` digest of the source records at generation time. For locked-data exports (VAT prep, VIES, archive package, accountant pack), the hash is stable once the period is finalized. For operational exports (transaction CSV, missing-evidence report), the hash reflects the current state of the underlying tables and changes when records are updated.

---

## 4. Export retention

### Operational exports (13 kinds minus archive-derived)

Generated export files are staged in the `export-temp` bucket with a **24-hour TTL**, enforced by Supabase Storage lifecycle rules per `data_retention_policy.md`. After the TTL expires the storage object is automatically purged. The `exports` row remains in the operational database for audit purposes.

These exports are regenerable from source data at any time (subject to data availability within the retention window). A user who needs an export older than 24 hours must re-request it.

### Archive-derived exports (exceptions to 30-day rule)

The following two export kinds are retained **indefinitely** — they are the archive artifact itself, not a derivative:

| Export kind | Retention | Rationale |
|---|---|---|
| `finalized_archive_package` | Indefinite | The ZIP IS the Block 15 sealed archive bundle; Object Lock governs physical retention |
| `accountant_export_pack` | Indefinite | Accountant packs are composites of finalized data; Cyprus 6-year regulatory retention |

For these two kinds, the `exports` row points to the archive zone storage object (Block 04 Phase 07), not the Raw Upload zone. The retention engine's 30-day rule does not apply; the archive zone's Object Lock does.

---

## 5. Permission gates

Two permission surfaces govern export access per `permission_matrix`:

### `REPORT_EXPORT_BASIC`

Covers operational exports. Granted by default to Owner, Admin, Bookkeeper, Accountant. Reviewer and Read-only are denied.

Applicable export kinds:
- `transaction_report`
- `expense_report`
- `income_report`
- `missing_evidence_report`
- `invoice_match_report`
- `client_outstanding_report`
- `supplier_overview`
- `profit_loss_overview`
- `cashflow_overview`

### `REPORT_EXPORT_FULL`

Covers regulator-grade and archive exports. Granted by default to Owner, Admin, Accountant. Bookkeeper is explicitly excluded per the 2026-05-09 amendment: operational reports are part of the daily job; regulator-grade exports route through the Accountant or Owner/Admin.

Applicable export kinds:
- `vat_preparation_report`
- `vies_export_file`
- `finalized_archive_package`
- `accountant_export_pack`

### Permission-check failure

A role attempting an export for which they lack the required surface receives HTTP 403 with audit event `EXPORT_REQUEST_REJECTED_PERMISSION`. The rejection is logged to the business's audit chain.

---

## 6. Mobile access

Export initiation is a **read intent** surface: the user is requesting a file download, not mutating application state. Accordingly:

- **Export trigger allowed on mobile** — mobile clients may initiate any of the 13 export kinds. The download starts on the user's device via the signed URL.
- **Export parameter configuration surfaces are desktop-only** — screens that configure accountant-pack composition, custom date ranges, or per-format options are part of the settings/configuration surface and are desktop-only.

The `exports` table INSERT is not listed in `mobile_write_rejection_endpoints` (it is a read-intent write). The policy is intentional: blocking export downloads on mobile would be a significant UX regression for accountants who review data on the go.

---

## 7. Failure handling

Generation failures fall into two categories:

**Transient failures** (network timeout, DB query timeout, temporary unavailability):
- One auto-retry after a 5-second back-off.
- If retry succeeds, the export completes normally.
- Retry attempt is recorded in the audit payload of `EXPORT_GENERATED` (or `EXPORT_COMPLETED`).

**Persistent failures** (two consecutive failures):
- `exports.status` set to `FAILED`; `failure_message` populated.
- `EXPORT_FAILED` audit event emitted.
- User notified via in-app toast and notification inbox (Block 14 Phase 06 surface).
- The user may re-request the export manually.

There is no automatic re-queue after persistent failure. Re-request is always manual (this avoids repeatedly hammering a broken data source).

---

## 8. Per-format export memory bounds

To prevent runaway memory consumption from very large exports that incorrectly estimated as sync-eligible:

| Format | Max in-memory buffer before spill to disk |
|---|---|
| CSV | 128 MB |
| XLSX | 64 MB (lower: in-memory workbook model is expensive) |
| PDF | N/A (always async) |
| JSON | 64 MB |
| XML | 64 MB |
| ZIP | N/A (always async; streaming construction) |

Exports exceeding the in-memory buffer are spilled to a temp file during generation. The temp file is cleaned up on completion or failure.

---

## 9. Audit events

| Event | When |
|---|---|
| `EXPORT_GENERATED` | Export file produced (covers both sync and async completion) |
| `EXPORT_FAILED` | Persistent generation failure |

These two events (`EXPORT_GENERATED` and `EXPORT_FAILED`) are new and must be added to `audit_event_taxonomy` under the `EXPORT` domain (see Step 3 amendment note below). The existing taxonomy contains `EXPORT_COMPLETED` and `EXPORT_FAILED` from Block 16 Phase 09; `EXPORT_GENERATED` is a synonym for `EXPORT_COMPLETED` from this policy's perspective. On review, `EXPORT_COMPLETED` already exists in the taxonomy — this policy adopts `EXPORT_COMPLETED` as the canonical event name for successful export generation.

| Event (canonical from taxonomy) | When |
|---|---|
| `EXPORT_COMPLETED` | Export file produced successfully |
| `EXPORT_FAILED` | Persistent generation failure |

---

## Cross-references
- `permission_matrix` — `REPORT_EXPORT_BASIC`, `REPORT_EXPORT_FULL` surfaces; role grants
- `data_layer_conventions_policy` — SHA-256 `source_data_hash`; UUID v7 `export_id`
- `audit_log_policies` — `EXPORT_*` event naming convention
- `audit_event_taxonomy` — `EXPORT` domain events
- `mobile_write_rejection_endpoints` — export initiation not listed (read-intent); config surfaces are desktop-only
- Block 16 Phase 09 — export pipeline architecture; 13-item catalogue; `exports` table definition
- Block 16 Phase 10 — PDF generator called by this dispatcher
- Block 16 Phase 11 — accountant pack and VIES XML generators
- Block 04 Phase 05 — Raw Upload zone (30-day export storage)
- Block 04 Phase 07 — Finalized Archive zone (indefinite archive storage)
- Block 04 Phase 10 — retention engine; 30-day export purge rule registration
- Block 15 Phase 04 / 06 — `finalized_archive_package` source
