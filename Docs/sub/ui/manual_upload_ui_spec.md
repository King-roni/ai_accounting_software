# manual_upload_ui_spec

**Category:** UI specs · **Owning block:** 09 — Document Intake & Extraction · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

The user-facing UX for manual document upload during `MANUAL_UPLOAD_HOLD`. Per `side_phase_routing_policy`: the workflow holds at this side phase when OUT_MATCHING completes with unmatched transactions awaiting evidence. The user uploads documents to resolve them.

Stripe / Linear / Mercury polish. Per-transaction context drives the upload UX so users know exactly which transaction each upload supports.

---

## Entry point

The user reaches this UI by:

1. Clicking a `Missing Documents` review-queue issue per `issue_group_enum`
2. Clicking "Resolve" on a transaction's detail drawer
3. The dashboard `Missing Documents` card → click-through to the queue → click an issue

In all cases, the user lands on the transaction's detail page (per `drill_down_per_record_kind_schema`) with the upload affordance highlighted.

## Layout

```
┌────────────────────────────────────────────────────────────────┐
│  Transaction                                                   │
│  €1,250.00  •  Andreas Karasidis Constructions  •  15 Jan 2026 │
│  OUT_EXPENSE                                                   │
│                                                                │
│  Missing evidence                                              │
│  Upload an invoice or receipt for this transaction.            │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                                                          │  │
│  │  Drop a file here, or click to browse                    │  │
│  │  PDF, JPG, PNG, DOCX up to 50 MB                         │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  [Mark as no invoice available]                                │
│                                                                │
│  Or, choose an existing document:                              │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Recent uncategorized documents                          │  │
│  │  • <doc> — €1,250.00 — 14 Jan 2026  [Match this]         │  │
│  │  • <doc> — €1,180.00 — 12 Jan 2026  [Match this]         │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

## Drop zone

Per `component_library_ui_spec`'s `FileDrop` component:

- Bordered rectangle, border-color `--color-border-subtle`
- Hover state: border `--color-border-strong`, background `--color-bg-canvas` for visual lift
- Drag-over state: border `--color-action-primary`, fill `--color-bg-raised`
- Click anywhere → opens system file picker
- Accepts: PDF, JPG, PNG, HEIC, DOCX, DOC, ODT per Stage 1 "non-PDF attachments: convert and OCR all common types"
- Max size: 50 MB per file per `tool_upload_pipeline_api`

## During upload

```
┌──────────────────────────────────────────────────────────┐
│  📄 invoice_jan_2026.pdf — 1.2 MB                        │
│                                                          │
│  ████████░░░░░░░░░░░░░░░░░░░  43% — Uploading...        │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

Note: this is the only place in the project where an icon glyph (📄) is intentional — it's a literal representation of the file. Per `design_system_tokens`: emojis are forbidden in the design system EXCEPT for this file-icon convention which uses the Lucide `FileText` icon (not an emoji glyph) — the diagram above is descriptive shorthand.

Progress bar uses `--color-action-primary` fill against `--color-bg-canvas` track. Progress text in tabular-num.

## Post-upload states

| State | UI |
| --- | --- |
| Processing | "Processing... extracting fields"; spinner; the file thumbnail visible |
| Match found | "Document matched: <invoice_number>" + the match score; "Confirm match" / "Reject" buttons |
| Multiple match candidates | List of candidate matches with score; "Choose match" / "Mark as new" options |
| Match failed | "No matching document; this will be saved as a new evidence record"; "Continue" / "Cancel" buttons |
| Upload failed (network) | "Upload didn't complete. Try again or check connection."; retry button |
| File rejected (size / format) | "File too large" or "Format not supported"; help link |

## "Mark as no invoice available" path

A button beneath the drop zone. Clicking opens a small inline form:

```
Why is there no invoice for this transaction?

[ ] Receipt is on paper only (will scan later)
[ ] Vendor doesn't issue invoices (e.g., personal contribution)
[ ] Below evidence threshold (<€15)
[ ] Other — please describe

[Confirm]   [Cancel]
```

Per Stage 1 + `resolution_action_enum`: this action calls `mark_as_no_invoice_available` and sets `effective_match_status = EXCEPTION_DOCUMENTED`. Audit event `OUT_WORKFLOW_DOCUMENT_EXCEPTION_RECORDED`.

Per Block 14 fix: Accountant CANNOT trigger this — they reassign back to a Bookkeeper instead.

## Existing-document picker

Below the drop zone, the UI shows up to 5 recent uncategorized documents (uploaded but unmatched). Per Block 09 Phase 02's document lifecycle:

- Documents with `status = NEW` and matching the transaction's amount range (±20%) and date range (±30 days)
- "Match this" button per row triggers `tool_manual_upload_re_entry` per the locked sub-doc

The pre-filtering helps users who uploaded an invoice before processing the transaction — they don't need to re-upload.

## Per-state mobile rejection

Per `mobile_write_rejection_endpoints`: uploads reject mobile. On mobile clients reaching this screen (shouldn't happen since the queue is mobile-readable but resolution is desktop-only):

```
This action is desktop-only.
Open Cyprus Bookkeeping on a laptop to upload documents.
```

## Accessibility

Per `component_library_ui_spec`:

- Drop zone has `role="button"` and `aria-label="Click to browse for a document"` for screen readers
- Keyboard navigation: Tab to drop zone, Enter to open file picker
- Live region announces "Uploading..." / "Processing..." / "Match found" so screen reader users follow progress
- Focus management: after upload completes, focus moves to the next actionable element (Confirm match, etc.)

## Token bindings

| Element | Tokens |
| --- | --- |
| Drop zone | `--color-border-subtle` + `--color-bg-raised` + `--radius-lg` + `--space-8` padding |
| Hover/drag-over | `--color-border-strong` / `--color-action-primary` |
| Progress bar | `--color-action-primary` fill, `--color-bg-canvas` track, `--text-sm` tabular-num |
| File name | `--text-sm` + `--color-text-primary` |
| Helper text | `--text-xs` + `--color-text-muted` |

## Component bindings

| Component | Source |
| --- | --- |
| FileDrop | `component_library_ui_spec` |
| ProgressBar | `component_library_ui_spec` |
| Button | `component_library_ui_spec` |
| Card (existing-docs section) | `component_library_ui_spec` |
| Modal (Mark as no invoice...) | `component_library_ui_spec` |

## Cross-references

- `tool_upload_pipeline_api` — backend API
- `tool_manual_upload_re_entry` — re-entry for matched-but-rejected docs
- `resolution_action_enum` — `mark_as_no_invoice_available`
- `issue_group_enum` — Missing Documents bucket
- `drill_down_per_record_kind_schema` — transaction detail page
- `mobile_write_rejection_endpoints` — mobile rejection
- `component_library_ui_spec` — components used
- `design_system_tokens` — tokens
- Block 09 Phase 07 — manual upload path (architecture)
- Block 12 Phase 06 — MANUAL_UPLOAD_HOLD phase
- Block 14 Phase 03 — issue card rendering
