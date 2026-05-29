# Archive Browser UI Spec

**Category:** UI · **Owning block:** 15 — Archive · **Stage:** 4 sub-doc (Layer 2)

UI specification for the Archive browser. This screen provides a read-mostly interface for
viewing, verifying, and downloading documents that have been promoted to the archive zone.
Access is restricted. Most actions require step-up authentication.

---

## Access control

| Role | View list | Preview | Download | Bulk verify | Admin actions |
| --- | --- | --- | --- | --- | --- |
| OWNER | Yes | Yes | Yes (step-up) | Yes | No |
| ADMIN | Yes | Yes | Yes (step-up) | Yes | Yes |
| ACCOUNTANT | Yes | Yes | Yes (step-up) | No | No |
| BOOKKEEPER | Yes | No | No | No | No |
| READ_ONLY | No | No | No | No | No |

Admin actions (legal hold, restore) are visible only to ADMIN role. BOOKKEEPER can view the
list but cannot open document previews.

Download requires step-up MFA for all roles. The step-up prompt appears when the user clicks
"Download". On success, the download URL is generated and the file is served. Emits
`ARCHIVE_BUNDLE_DOWNLOADED` (LOW).

---

## Page structure

The Archive browser is accessible at `/archive`. It consists of:

1. Page header — title "Archive", integrity summary pill (see below), "Verify All" button.
2. Filter bar — below the header.
3. Paginated table.
4. Admin action panel — footer bar, visible to ADMIN only.

---

## Integrity summary pill

Located in the page header, adjacent to the title. Shows:

- Green pill: "All documents verified" — when all visible records have `integrity_status = VERIFIED`.
- Yellow pill: "{N} unverified" — when unverified records exist.
- Red pill: "{N} tampered" — when any record has `integrity_status = TAMPERED`. This state
  takes priority over unverified.

Hovering the pill shows a tooltip with the exact counts for each status.

---

## Table columns

| Column | Content | Width | Notes |
| --- | --- | --- | --- |
| Document Type | `document_type` label | 160px | Human-readable label from document_type enum |
| Run | Run reference | 140px | Links to the run detail page |
| Period | `accounting_period` (YYYY-MM) | 100px | Tabular-nums |
| Archive Date | `archived_at` | 140px | Local date-time, tabular-nums |
| RFC 3161 Timestamp | `timestamp_token` present indicator | 100px | Checkmark icon (token present) or dash |
| Integrity Status | Integrity badge | 120px | See badge spec below |
| Actions | Icon buttons | 120px | Preview, Download, Admin (role-gated) |

Default sort: `archived_at` DESC. Columns sortable: Document Type, Period, Archive Date,
Integrity Status.

---

## Integrity status badges

| integrity_status | Label | Background | Text | Notes |
| --- | --- | --- | --- | --- |
| VERIFIED | Verified | `--color-success-200` | `--color-success-800` | Hash chain confirmed |
| UNVERIFIED | Unverified | `--color-warning-100` | `--color-warning-800` | Not yet verified |
| TAMPERED | Tampered | `--color-danger-200` | `--color-danger-800` | Hash mismatch detected |

TAMPERED rows also receive a left-border highlight in `--color-danger-600` to draw immediate
attention. The row is not expandable; instead a "View Incident" link opens the relevant
`ARCHIVE_INTEGRITY_FAILURE` audit event.

---

## Filter bar

| Filter | Control | Field |
| --- | --- | --- |
| Document type | Multi-select dropdown | `document_type` |
| Period | Month/year range picker | `accounting_period` |
| Integrity status | Multi-select chip group | `integrity_status` |
| Run | Run ID search input | `run_id` |
| Archive date range | Date range picker | `archived_at` |

Active filters render as dismissible chips. "Clear all filters" link when any filter is active.

---

## Document preview

Clicking the Preview icon (or clicking the document row) opens the document in an in-app PDF
viewer as a side panel (560px, right edge, overlaying the table).

The viewer panel header contains:
- Document filename.
- Archive date.
- Integrity status badge.
- RFC 3161 timestamp string (formatted): TSA provider name, token issue timestamp (ISO 8601),
  and a "Copy token" icon button.

The PDF viewer is read-only. Text selection is disabled for archived documents per
`archive_access_control_policy`. The panel footer contains: "Download for legal purposes" and
"Close" buttons.

For BOOKKEEPER role, the Preview icon is hidden and clicking the row does not open the viewer.

---

## RFC 3161 timestamp display

When a document has a `timestamp_token`, the archive date column shows a clock-with-checkmark
icon. Hovering shows a tooltip:

  "RFC 3161 timestamp issued by {tsa_provider_name} at {timestamp_issued_at} UTC"

In the document preview panel, the full timestamp details are shown in a monospace block:
- Token hash (truncated to 16 chars + "...")
- TSA provider name
- Issued at (ISO 8601)
- Signed algorithm

A "Verify timestamp" link opens the raw token in a new tab pointing to the configured TSA
verification endpoint.

---

## Download for legal purposes

Download is available from:
1. The Actions column icon in the table row.
2. The "Download for legal purposes" button in the document preview panel.

Both paths trigger the step-up MFA flow. After step-up:
- Calls `archive.generate_download_url` with `bundle_id` and the consumed step-up token.
- A signed download URL is generated (15-minute expiry).
- The browser begins download automatically.
- Emits `ARCHIVE_BUNDLE_DOWNLOADED` (LOW) and `ARCHIVE_DOCUMENT_ACCESSED` (LOW).

Download of multiple documents is not supported in a single step-up. Each document requires
its own step-up challenge.

---

## Bulk verify action

Available to OWNER and ADMIN. The "Verify All" button in the page header triggers hash chain
verification for all unverified documents currently visible (respecting active filters).

A progress modal shows:
- "Verifying {N} documents..."
- A progress bar advancing as documents are checked.
- On completion: "Verification complete. {N} verified, {M} tampered."

If any tampered documents are found, the modal switches to an error summary listing the
affected documents. Each row has a "View Incident" link.

Bulk verify calls `archive.verify_hash_chain` with `manifest_ids[]`. Emits
`ARCHIVE_INTEGRITY_VERIFIED` (LOW) per document or `ARCHIVE_INTEGRITY_FAILURE` (BLOCKING) per
tampered document.

---

## Admin-only actions

Visible and available only to ADMIN role. A footer action bar appears at the bottom of the
page when ADMIN is logged in:

| Action | Notes |
| --- | --- |
| Set legal hold | Opens a modal with a required reason textarea. Calls `archive.set_legal_hold`. Emits `ARCHIVE_LEGAL_HOLD_SET` (MEDIUM). |
| Remove legal hold | Available only when a legal hold is active. Requires confirmation. Emits `ARCHIVE_LEGAL_HOLD_REMOVED` (MEDIUM). |
| Request restore | Initiates archive restore for selected documents. Emits `ARCHIVE_RESTORE_REQUESTED` (MEDIUM). |

All admin actions require ADMIN role check at API layer — UI role-gating alone is not
sufficient.

---

## Mobile layout

On viewports below 768px:
- Table collapses to a card list. Each card shows: document type, period, archive date,
  integrity status badge.
- Card tap opens the full-screen document preview (PDF viewer, full screen).
- RFC 3161 timestamp details are shown in a collapsible section within the preview.
- Download is available on mobile after step-up.
- Bulk verify is not available on mobile. The "Verify All" button is hidden.
- Admin actions are not available on mobile.
- Filter control collapses behind a "Filter" button (bottom sheet).

---

## Empty states

No archived documents:
  "No documents have been archived yet. Documents are promoted to the archive after run
  finalization."

No documents match active filters:
  "No archived documents match the current filters."

---

## Related Documents

- `archive_schema.md` — archive zone table structure, integrity_status enum
- `archive_manifest_schema.md` — manifest schema, RFC 3161 fields
- `archive_restore_runbook.md` — restore procedure
- `accountant_pack_tamper_runbook.md` — tamper response procedure
- `tamper_detection_forensic_runbook.md` — forensic analysis after ARCHIVE_INTEGRITY_FAILURE
- `document_viewer_ui_spec.md` — in-app PDF viewer component
- `step_up_ui_spec.md` — step-up MFA challenge flow
- `audit_event_taxonomy.md` — `ARCHIVE_BUNDLE_DOWNLOADED`, `ARCHIVE_DOCUMENT_ACCESSED`,
  `ARCHIVE_INTEGRITY_VERIFIED`, `ARCHIVE_INTEGRITY_FAILURE`, `ARCHIVE_LEGAL_HOLD_SET`,
  `ARCHIVE_LEGAL_HOLD_REMOVED`, `ARCHIVE_RESTORE_REQUESTED`
- `design_system_tokens.md` — colour, spacing, typography tokens
