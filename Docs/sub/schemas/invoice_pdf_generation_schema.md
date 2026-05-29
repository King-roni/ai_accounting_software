# Schema: invoice_pdf_jobs

**Category:** Schemas · Block 13 — IN Workflow + Invoice Generator
**Table:** `invoice_pdf_jobs`
**Last updated:** 2026-05-17

---

## Purpose

`invoice_pdf_jobs` tracks the asynchronous generation of invoice PDF files. Each row represents a single PDF generation request for one invoice or credit note. The table provides the state machine for the generation pipeline: `QUEUED` → `GENERATING` → `COMPLETE` or `FAILED`.

---

## DDL

```sql
CREATE TYPE invoice_pdf_document_type AS ENUM (
  'TAX_INVOICE',
  'PRO_FORMA',
  'CREDIT_NOTE'
);

CREATE TYPE invoice_pdf_generation_status AS ENUM (
  'QUEUED',
  'GENERATING',
  'COMPLETE',
  'FAILED'
);

CREATE TABLE invoice_pdf_jobs (
  id                    uuid                           PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Business scope
  business_id           uuid                           NOT NULL REFERENCES business_entities(id),

  -- The invoice this PDF is for.
  -- For TAX_INVOICE and PRO_FORMA: references invoices(id).
  -- For CREDIT_NOTE: references credit_notes(id).
  -- Both columns are nullable; application logic ensures exactly one is populated.
  invoice_id            uuid                           NULL REFERENCES invoices(id),
  credit_note_id        uuid                           NULL REFERENCES credit_notes(id),

  -- What kind of document this PDF represents
  document_type         invoice_pdf_document_type      NOT NULL,

  -- Semver of the PDF template used to generate this file.
  -- Allows identifying which version of the layout/branding was applied.
  -- Governed by invoice_pdf_policies.md.
  template_version      text                           NOT NULL,

  -- Current state of the generation job
  generation_status     invoice_pdf_generation_status  NOT NULL DEFAULT 'QUEUED',

  -- Lifecycle timestamps
  queued_at             timestamptz                    NOT NULL DEFAULT now(),
  generation_started_at timestamptz                    NULL,
  generation_completed_at timestamptz                  NULL,

  -- Set on COMPLETE. Path in the export-temp storage bucket.
  -- The file at this path has a 24-hour TTL; after that it must be re-generated on demand.
  storage_path          text                           NULL,

  -- SHA-256 of the PDF bytes, set on COMPLETE.
  -- Used to detect storage corruption and to verify downloads.
  file_hash             text                           NULL,

  -- File size in bytes, set on COMPLETE.
  file_size_bytes       integer                        NULL,

  -- Populated on FAILED status. Human-readable reason for logging and display.
  failure_reason        text                           NULL,

  -- Number of generation attempts made. Capped at 3 before the job is marked permanently FAILED.
  retry_count           integer                        NOT NULL DEFAULT 0 CHECK (retry_count <= 3),

  -- The user who triggered this generation, if triggered on demand via UI.
  -- NULL if triggered automatically by the IN workflow on invoice status transition.
  triggered_by_user_id  uuid                           NULL REFERENCES users(id),

  created_at            timestamptz                    NOT NULL DEFAULT now(),

  -- Exactly one of invoice_id or credit_note_id must be populated
  CONSTRAINT invoice_pdf_jobs_document_ref_check
    CHECK (
      (invoice_id IS NOT NULL AND credit_note_id IS NULL) OR
      (invoice_id IS NULL AND credit_note_id IS NOT NULL)
    )
);
```

---

## Indexes

```sql
-- Scope queries for a business
CREATE INDEX invoice_pdf_jobs_business_id_idx
  ON invoice_pdf_jobs (business_id);

-- Find PDF jobs for a specific invoice
CREATE INDEX invoice_pdf_jobs_invoice_id_idx
  ON invoice_pdf_jobs (invoice_id)
  WHERE invoice_id IS NOT NULL;

-- Queue processing: worker polls for QUEUED rows ordered by queued_at
CREATE INDEX invoice_pdf_jobs_generation_status_queued_at_idx
  ON invoice_pdf_jobs (generation_status, queued_at)
  WHERE generation_status IN ('QUEUED', 'GENERATING');
```

---

## Generation Triggers

PDF generation is triggered in two scenarios:

### 1. Workflow-Triggered (Automatic)

When an invoice transitions from `DRAFT` to `SENT` (or a credit note transitions to `ISSUED`), the IN workflow inserts a `QUEUED` row automatically. `triggered_by_user_id` is `NULL` in this case.

### 2. On-Demand (User-Triggered)

When a user clicks "Download PDF" in the invoice list UI, the API checks whether a `COMPLETE` job exists for the invoice with a `storage_path` that has not yet expired (within 24 hours of `generation_completed_at`).

- If a valid COMPLETE job exists, the API returns a presigned URL to `storage_path` directly.
- If no valid COMPLETE job exists (first download, or TTL expired), the API inserts a new `QUEUED` row with `triggered_by_user_id` populated, then polls until `COMPLETE`.

---

## State Machine

```
QUEUED → GENERATING → COMPLETE
                    ↘ FAILED (if retry_count reaches 3)

FAILED (retry_count < 3) → QUEUED (on retry)
```

State transitions are enforced by the PDF generation worker. The worker claims a row by setting `generation_status = 'GENERATING'` and `generation_started_at = now()` using an atomic `UPDATE ... WHERE generation_status = 'QUEUED' ... RETURNING id`.

---

## Storage

| Destination | TTL | Purpose |
|---|---|---|
| `export-temp` bucket | 24 hours | User-facing download; presigned URL served to UI |
| Archive zone | Permanent | Copy stored with the accountant pack bundle at period finalization |

The `storage_path` field always references the `export-temp` bucket. The Archive zone copy path is tracked in the `archive_document_refs` table.

---

## Retry Policy

On `FAILED` status where `retry_count < 3`:

1. The worker increments `retry_count`.
2. Sets `generation_status = 'QUEUED'`.
3. Clears `generation_started_at` and `failure_reason`.
4. The job re-enters the queue.

After the 3rd failure (`retry_count = 3`), the job remains `FAILED` permanently. A `review_queue` issue is created for ADMIN review.

---

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `IN_WORKFLOW_INVOICE_PDF_GENERATED` | LOW | PDF generation completed successfully; `storage_path` and `file_hash` set |
| `IN_WORKFLOW_INVOICE_PDF_FAILED` | MEDIUM | PDF generation failed after all retry attempts exhausted |

---

## Cross-references

- `invoice_schema.md` — the `invoices` table that `invoice_id` references
- `invoice_pdf_policies.md` — template versioning, branding rules, and VAT compliance requirements for invoice PDFs
- `pdf_generation_integration.md` — the PDF rendering service integration (Chromium headless or equivalent)
- `export_pipeline_policy.md` — how export-temp files are managed, TTL enforcement, and Archive zone promotion
