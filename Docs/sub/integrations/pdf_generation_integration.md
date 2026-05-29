# Integration: PDF Generation Service

**Category:** Integrations · Block 13 — IN Workflow + Invoice Generator
**Integration type:** Internal service call (not a third-party SaaS)
**Direction:** Outbound (application to rendering service)

---

## Purpose

Renders invoice and report documents as PDF/A-1b files for delivery, storage, and
archiving. The rendering service is self-hosted within the same infrastructure as the
application — it is not a third-party vendor.

Invoice PDFs are attached to sent invoices, provided to clients, and included in
accountant archive bundles. Credit note PDFs follow the same pipeline with a modified
template header.

---

## Rendering Service

The rendering service is a Puppeteer/Chromium-based HTML-to-PDF processor running as an
internal sidecar or dedicated pod, depending on the deployment environment. It exposes
an HTTP API on an internal network interface only — it is not reachable from the public
internet.

Template files are stored in the application codebase, not in the database. Template
updates require a code deployment and template version bump.

---

## Invoice PDF Template

Templates are HTML/CSS files that reference design token variables defined in
`design_system_tokens.md`. This ensures invoice visual output stays in sync with the
application's design system without duplicating color, typography, or spacing values.

| Template property     | Value                                          |
|-----------------------|------------------------------------------------|
| Format                | HTML/CSS with design token variables           |
| Version pinning       | `invoice_pdf_jobs.template_version` per job    |
| Version source        | Application codebase (not database)            |
| Output format         | PDF/A-1b (ISO 19005-1 archive-safe)            |
| Accessibility         | Per `pdf_accessibility_policy.md`              |

---

## Rendering Input Payload

The application sends a JSON payload to the rendering service containing:

```json
{
  "invoice_id": "uuid",
  "template_version": "string",
  "client_name": "string",
  "client_address": "object",
  "business_name": "string",
  "business_logo_url": "string | null",
  "invoice_number": "string",
  "invoice_date": "date",
  "due_date": "date",
  "payment_terms": "string",
  "line_items": "array",
  "vat_breakdown": "array",
  "total_amount": "numeric",
  "currency": "string",
  "payment_link_url": "string | null",
  "document_type": "TAX_INVOICE | CREDIT_NOTE",
  "linked_invoice_number": "string | null"
}
```

`linked_invoice_number` is required when `document_type = CREDIT_NOTE`. It is printed in
the credit note header.

---

## Credit Note PDFs

Credit note PDFs use the same template set as invoices with two differences:

1. The header reads "CREDIT NOTE" instead of "TAX INVOICE".
2. The `linked_invoice_number` of the original invoice is printed in the header.

No separate template file is required — the document_type field in the payload controls
the header rendering.

---

## Generation Flow

1. An `invoice_pdf_jobs` row is created with `status = QUEUED` and
   `pk = gen_uuid_v7()`.
2. The job dispatcher sends the payload to the rendering service's `/render` endpoint.
3. The rendering service loads the template pinned to `template_version`.
4. It injects invoice data into the HTML template using the design token variables.
5. Chromium renders the HTML and converts the output to PDF/A-1b.
6. The resulting file is uploaded to the export-temp bucket.
7. `invoice_pdf_jobs` is updated to `status = COMPLETE` with `storage_path` set to
   the export-temp bucket path.

---

## Retry Policy

On rendering failure (non-2xx response from the rendering service, or timeout):

- Retry up to 3 times with exponential backoff (1s, 4s, 16s).
- After 3 failures, set `invoice_pdf_jobs.status = FAILED`.
- Emit `IN_WORKFLOW_INVOICE_PDF_FAILED` (MEDIUM) via `security.emit_audit`.
- Alert the ops team via the configured alerting channel.
- The invoice remains in its current status (SENT or DRAFT); PDF generation failure does
  not block invoice delivery if the PDF was optional at that point.

---

## Archive Copy

When an invoice PDF is included in an accountant pack or year-end archive bundle:

- The export-temp copy is read before TTL expiry.
- A permanent copy is written to the Archive zone as part of the bundle construction
  process defined in `archive_bundle_construction_schema.md`.
- The permanent copy is immutable after the bundle is sealed. The export-temp copy may
  expire normally.

---

## Accessibility Requirements

All generated PDFs must conform to the tagging and metadata requirements defined in
`pdf_accessibility_policy.md`. The rendering service applies these requirements at the
Chromium PDF export step. Jobs that produce non-conforming output are treated as failures
and are retried per the retry policy above.

---

## Audit Events

| Event                           | Severity | Trigger                                    |
|---------------------------------|----------|--------------------------------------------|
| IN_WORKFLOW_INVOICE_PDF_FAILED  | MEDIUM   | 3 rendering retries exhausted              |

Successful PDF generation does not emit a dedicated audit event. The job status
transition to COMPLETE is the authoritative record.

---

## Cross-References

- `invoice_pdf_generation_schema.md` — invoice_pdf_jobs table definition
- `invoice_pdf_policies.md` — naming, versioning, and storage policy
- `pdf_accessibility_policy.md` — accessibility conformance requirements
- `design_system_tokens.md` — token variable definitions used in templates
- `archive_bundle_construction_schema.md` — permanent copy bundling process
