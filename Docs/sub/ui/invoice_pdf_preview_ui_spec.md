# Invoice PDF Preview UI Spec

**Category:** UI · Block 13 — IN Workflow + Invoice Generator
**Status:** Authoritative
**Cross-ref:** invoice_pdf_generation_schema.md, invoice_pdf_policies.md, pdf_generation_integration.md, invoice_list_ui_spec.md, transactional_email_service_integration.md

---

## 1. Overview

This document specifies the inline PDF preview modal, download experience, and email-send flow for invoices. PDF generation is asynchronous; the UI handles all generation states gracefully. The preview is read-only — no invoice editing occurs from this surface.

---

## 2. Access

- **Roles:** ACCOUNTANT, OWNER, ADMIN.
- VIEWER role does not have access to invoice PDF preview or download.

---

## 3. Entry Points

There are three entry points into the invoice PDF preview:

### 3.1 Invoice List — Row Action

- Location: the actions menu (`...` button) on each row in the invoice list table.
- Action label: "Preview PDF".
- Availability: shown for invoices in any non-DRAFT status. DRAFT invoices show "Preview PDF (draft)" — the preview is available but is watermarked "DRAFT" in the rendered PDF.
- Behaviour: opens the preview modal (Section 4).

### 3.2 Invoice Detail View — Download Button

- Location: the top action bar of the invoice detail page.
- Button label: "Download PDF".
- Availability: always shown for ACCOUNTANT, OWNER, ADMIN.
- Behaviour: if a COMPLETE `invoice_pdf_jobs` record exists, immediately triggers the signed URL download (Section 6). If no COMPLETE job exists, the modal opens and generation is triggered first.

### 3.3 Invoice Send Flow — Email Compose Step

- Location: the email compose step of the DRAFT → SENT transition workflow.
- Context: the accountant sees a preview thumbnail of the invoice PDF alongside the email compose form.
- Clicking the thumbnail opens the full-screen preview modal (Section 4).
- The send action remains available while the modal is open; closing the modal returns to the email compose step.

---

## 4. Preview Modal

### 4.1 Modal Structure

- **Type:** Full-screen modal (100vw × 100vh on desktop; full-screen on mobile).
- **Header bar:** Contains the invoice number (e.g., "INV-2025-0042"), a "Download" button (right-aligned), and a close button (X icon, far right).
- **Body:** The PDF viewer occupies all remaining height below the header bar.
- **PDF viewer:** Browser native `<embed>` or `<iframe>` with the PDF blob URL, with PDF.js as a fallback for browsers that do not support native PDF rendering in iframes.
- **Background:** `--color-overlay` behind the modal; clicking outside does not close the modal (prevents accidental dismissal).
- **Close:** Only via the X button or keyboard Escape.

### 4.2 Generation States

When the preview modal opens, the system checks for an existing `invoice_pdf_jobs` record with `status = COMPLETE` for the invoice.

#### State: QUEUED or GENERATING

- The PDF viewer area displays a centred spinner (`--color-icon-secondary`, 32px).
- Below the spinner: "Generating PDF… This may take a few seconds."
- `--font-size-sm`, `--color-text-secondary`.
- The "Download" button in the header is disabled (greyed out) while in this state.
- The UI polls `GET /invoices/{id}/pdf-job` every 2 seconds to check for status change.
- No user action is required; the PDF appears automatically when `status` transitions to COMPLETE.

#### State: COMPLETE

- The PDF is displayed immediately in the viewer.
- The "Download" button is enabled.
- If the user opened the modal while status was GENERATING and polling detected the COMPLETE transition, the spinner fades out and the PDF fades in (200ms opacity transition).

#### State: FAILED

- The spinner is replaced by an error state:
  - Icon: `x-circle`, `--color-icon-error`.
  - Text: "PDF generation failed. Retry?"
  - Button: "Retry" — calls the PDF generation retry endpoint (`POST /invoices/{id}/pdf-job/retry`).
  - After clicking Retry, the state reverts to GENERATING and polling resumes.
- The "Download" button remains disabled in the FAILED state.

#### State: No existing job

- If no `invoice_pdf_jobs` record exists for the invoice, the modal automatically triggers PDF generation on open (`POST /invoices/{id}/pdf-job`).
- The UI transitions immediately to the QUEUED/GENERATING display (Section 4.2, first state above).

---

## 5. PDF Viewer Controls

When a PDF is loaded in the viewer:

- **Native browser controls** are shown (zoom, page navigation, full-screen) for the native embed.
- **PDF.js fallback:** Renders PDF.js toolbar with page navigation, zoom in/out, and rotate controls.
- **Page count:** Displayed in the header bar: "Page X of N".
- **Zoom:** Default zoom is "fit to width" — the PDF fills the available width of the modal body.

---

## 6. Download

### 6.1 Trigger

- Clicking "Download" in the modal header calls `GET /invoices/{id}/pdf-job/download-url`.
- The server returns a signed S3 URL from the `export-temp` bucket.
- The URL is opened via `window.open(url, '_blank')` or a programmatic anchor `<a href="{url}" download>` click — triggering a browser download.

### 6.2 Filename

- The downloaded file is named `{invoice_number}.pdf`.
- Example: `INV-2025-0042.pdf`.
- The filename is set via the `Content-Disposition` header on the signed URL: `attachment; filename="INV-2025-0042.pdf"`.

### 6.3 Link Expiry

- Signed URLs expire after 1 hour.
- If the user attempts a download more than 1 hour after the modal was opened (or after the URL was last generated), the server returns a 410 Gone response.
- The UI detects the 410 and shows an inline message in the modal header, replacing the "Download" button: "Link expired — click to regenerate." Clicking this link calls the download URL endpoint again and immediately triggers the download with a fresh signed URL.
- The expiry message is `--font-size-sm`, `--color-text-warning`.

---

## 7. Send via Email — Invoice Send Flow

### 7.1 Flow Position

The send-via-email action occurs as part of the DRAFT → SENT invoice status transition. The email compose step is a full-page form (not a modal).

### 7.2 Email Compose Step

- **Fields:** To (client email, pre-filled from client record; editable), Subject (pre-filled: "Invoice {invoice_number} from {business_name}"; editable), Body (pre-filled with branded template from pdf_generation_integration.md; editable).
- **PDF attachment indicator:** Below the body field, a static row shows: `[PDF icon] {invoice_number}.pdf — attached automatically`. Not removable; the PDF is always attached.
- **Preview thumbnail:** A small (120px wide) thumbnail preview of the first page of the invoice PDF, generated from the PDF blob. Clicking the thumbnail opens the full-screen preview modal.

### 7.3 Send Action

- Button: "Send Invoice" — primary action in the email compose step.
- On click: the invoice transitions to SENT status; the transactional email service (transactional_email_service_integration.md) sends the email with the PDF attached.
- A success toast is shown: "Invoice {invoice_number} sent to {client_email}." (auto-dismiss, 5 seconds).
- Audit event emitted: `INVOICE_SENT`.

### 7.4 Draft Watermark

If the invoice is previewed from DRAFT status during the send flow before the send button is clicked, the PDF preview does not show a watermark (the PDF is a clean version). The DRAFT watermark is only applied if explicitly previewed from the invoice list while the invoice remains in DRAFT status and no send action has been initiated.

---

## 8. Mobile Behaviour

| Feature                    | Desktop                              | Mobile                                         |
|----------------------------|--------------------------------------|------------------------------------------------|
| Preview modal              | Full-screen modal                    | Full-screen native view                        |
| PDF viewer                 | Embedded in modal body               | Download replaces inline viewer (browsers handle PDF download natively on mobile) |
| Download button            | In modal header                      | Sticky button at bottom of screen              |
| Generation spinner         | Centred in modal body                | Centred in screen                              |
| Email compose thumbnail    | 120px inline thumbnail               | Hidden; replaced by "Tap to preview PDF" link  |

On mobile, the inline PDF viewer is not used. When a user taps "Preview PDF" or "Download PDF" on mobile, the system generates the PDF (if needed), obtains a signed URL, and triggers a native browser download. The downloaded PDF opens in the device's default PDF viewer.

---

## 9. Error States Summary

| Scenario                       | UI response                                       |
|--------------------------------|---------------------------------------------------|
| PDF generation FAILED          | Error state in modal; Retry button                |
| Download URL expired (410)     | "Link expired — click to regenerate" inline       |
| Network error during generation poll | Component error boundary with retry        |
| Invoice not found (404) on open | Modal closes; page-level 404 (error_boundary_ui_spec.md Section 2.1) |
| Permission denied (403)        | Modal does not open; 403 toast shown             |

---

## 10. Audit Events

| Event                    | Trigger                                 | Severity |
|--------------------------|-----------------------------------------|----------|
| `INVOICE_PDF_DOWNLOADED` | User downloads a PDF via signed URL     | LOW      |
| `INVOICE_SENT`           | Invoice send action completes           | LOW      |
| `INVOICE_PDF_RETRY`      | User clicks Retry on a FAILED PDF job   | LOW      |
