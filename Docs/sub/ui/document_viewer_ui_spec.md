# Document Viewer — UI Spec
**Category:** UI · Block 09 — Document Intake
**Last updated:** 2026-05-16

---

## 1. Purpose

The document viewer provides an inline view of uploaded documents — invoices, receipts, bank statements — alongside their OCR extraction results. It is the primary interface for inspecting what was captured from a document and diagnosing extraction issues.

---

## 2. Access

All roles may open and view documents. Write actions (re-OCR, download) are gated as described below.

---

## 3. Entry Points

- From the document intake list — clicking a document row.
- From a review issue that references a `document_id`.
- Direct deep link: `#doc-{document_id}`.

---

## 4. Layout

Two-pane layout on desktop (min-width 1024px):

| Pane | Width | Content |
|---|---|---|
| Left — Document pane | 55% | Rendered document |
| Right — Extracted data pane | 45% | OCR results and metadata |

A draggable divider separates the panes (min left 35%, min right 30%).

---

## 5. Document Pane

### 5.1 Supported Formats

- **PDF:** rendered inline using the application's built-in PDF renderer. All PDF versions supported.
- **Image (JPG, PNG):** rendered inline with pan and zoom.

Unsupported formats display a message: "Preview not available for this file type. Use Download to view the original."

### 5.2 Controls

| Control | Detail |
|---|---|
| Zoom in / Zoom out | Buttons + keyboard shortcuts (`+` / `-`). Zoom range 50%–400%. |
| Fit to pane | Resets zoom to fit the document within the pane. |
| Page navigation | Previous / Next page buttons + "Page N of M" indicator. Shown only for multi-page PDFs. |
| Scroll | Vertical scroll within the pane. For multi-page PDFs, continuous scroll is supported (page navigation buttons sync to current scroll position). |

### 5.3 Redaction Banner

If `redacted_at` is set on the document record, a sticky banner is shown at the top of the document pane:

> "This document has been redacted. Original field values are not displayed."

Redacted fields in the rendered document are replaced with `[REDACTED]` overlays at the coordinates provided by `redaction_field_map.md`.

---

## 6. Extracted Data Pane

### 6.1 OCR Status Indicator

A status pill shown at the top of the pane:

| Status | Appearance | Meaning |
|---|---|---|
| PENDING | Grey spinner | Document queued; OCR not yet started |
| IN_PROGRESS | Blue spinner | OCR actively running |
| COMPLETE | Green badge | Extraction finished |
| FAILED | Red badge + error message | OCR failed; see error_code |

When status is FAILED, the error message from `extraction_policies.md` is shown below the badge (e.g., "Unsupported language detected" or "File corrupt — re-upload required").

### 6.2 Document Type Badge

Shows the classified `document_type` (e.g., INVOICE, RECEIPT, BANK_STATEMENT, OTHER). Derived from the OCR result.

### 6.3 Confidence Score Bar

- Overall extraction confidence: 0–100%, horizontal bar.
- Colour thresholds: 0–60% = red, 61–80% = yellow, 81–100% = green (consistent with application-wide confidence display).

### 6.4 Extracted Fields Table

A table of all fields extracted from the document.

| Column | Content |
|---|---|
| Field name | Human-readable label (e.g., "Invoice Number", "Supplier VAT", "Total Amount") |
| Extracted value | The value as captured by OCR |
| Confidence | Per-field confidence percentage, with a colour dot (same thresholds as 6.3) |

If `redacted_at` is set, fields listed in `redaction_field_map.md` display `[REDACTED]` in the extracted value column. The confidence column is blank for redacted fields.

### 6.5 Raw Extraction JSON Toggle

A collapsible section at the bottom of the pane, collapsed by default. Label: "Raw extraction JSON."

When expanded, shows the full unprocessed JSON payload returned by the OCR engine. Intended for debugging by ADMIN/OWNER. Visible to all roles but most useful for technical review.

---

## 7. Actions

### 7.1 Re-OCR

- Available to ADMIN and OWNER only.
- Visible (but disabled with tooltip) for ACCOUNTANT role.
- Enabled when `ocr_status = FAILED` or `confidence_score < 0.6`.
- Calls `intake.ocr_retry` with the current `document_id`.
- On trigger: status indicator switches to IN_PROGRESS; the extracted data pane shows a loading skeleton.
- Audit event: `DOCUMENT_OCR_RETRIED`.
- If the re-OCR also fails, the FAILED state is restored with updated error details.

### 7.2 Download Original

- Available to OWNER and ADMIN.
- Not shown to ACCOUNTANT or Viewer roles.
- If `redacted_at` is set, the download serves the redacted version of the document, not the original. The button label changes to "Download Redacted Copy" and a tooltip explains this. Governed by `redaction_at_write_policy.md`.
- If `redacted_at` is null, the original file is served.
- Audit event: `DOCUMENT_DOWNLOADED`.

### 7.3 Link to Transaction

If the document record has an associated `transaction_id`, a "View Transaction" link is shown in the header of the right pane (above the OCR status indicator). Clicking it opens the transaction detail drawer (transaction_detail_ui_spec.md) for that transaction.

---

## 8. Header Bar

Shown at the top of the viewer (spanning both panes):

- Document filename
- Upload timestamp (`uploaded_at`)
- Uploaded by (user email or "System" if ingested automatically)
- "View Transaction" link (if applicable, per 7.3)
- Close button (`X`)

---

## 9. Error States

| Condition | Behaviour |
|---|---|
| Document not found | Full viewer shows "Document not found." with a close button |
| Download fails | Toast: "Download failed. Try again." |
| Re-OCR fails to start | Toast: "Could not start OCR retry. Try again." Status reverts to previous state. |

---

## 10. Mobile Behaviour

On viewports below 768px:

- The two-pane layout collapses to a single-column, full-page view.
- The document pane is shown first.
- The extracted data pane collapses to an accordion below the document. Tap "Extraction results" to expand.
- Zoom controls are touch-native (pinch to zoom).
- Page navigation is shown as a persistent bottom bar for multi-page PDFs.
- The raw extraction JSON toggle is hidden on mobile.

---

## Cross-references

- `document_schema.md` — `document_type`, `ocr_status`, `confidence_score`, `redacted_at` field definitions
- `extraction_policies.md` — OCR engine, supported languages, error codes
- `redaction_at_write_policy.md` — what triggers redaction, which version is served on download
- `redaction_field_map.md` — field names and coordinates subject to redaction
- `upload_content_sniff_policy.md` — content-type validation on ingest
- `transaction_detail_ui_spec.md` — entry from linked transaction
