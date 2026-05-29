# Schema: document_gmail_queries

**Category:** Schemas · **Owning block:** 09 — Document Intake · **Stage:** 4 sub-doc (Layer 2)

Defines the table that stores per-business Gmail search query templates used by the document intake pipeline to discover incoming documents from connected Gmail accounts. Each row is an independently activatable query; multiple rows can be active simultaneously for a single business.

---

## Block reference

Block 09 — Document Intake. The Gmail document finder phase reads from this table to construct search requests against the Gmail API. Results are passed downstream to `intake.ocr_and_extract`.

---

## Purpose

Store named, business-scoped Gmail query templates that the intake pipeline evaluates on each run. Templates encode the Gmail search syntax, optional sender restrictions, optional subject keyword filters, and allowed attachment MIME types. The pipeline composes these templates into Gmail API `users.messages.list` calls.

---

## Table DDL

```sql
CREATE TABLE document_gmail_queries (
  id                    UUID        NOT NULL DEFAULT gen_uuid_v7(),
  business_id           UUID        NOT NULL REFERENCES business_entities(id),
  query_name            TEXT        NOT NULL,
  gmail_query_string    TEXT        NOT NULL,
  sender_allowlist      TEXT[]      NULL,
  subject_keywords      TEXT[]      NULL,
  attachment_mime_types TEXT[]      NOT NULL DEFAULT ARRAY['application/pdf'],
  is_active             BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT document_gmail_queries_pkey PRIMARY KEY (id),
  CONSTRAINT document_gmail_queries_business_name_unique
    UNIQUE (business_id, query_name)
);

CREATE INDEX document_gmail_queries_business_active
  ON document_gmail_queries (business_id, is_active)
  WHERE is_active = TRUE;
```

All UUIDs are UUID v7 (`gen_uuid_v7()`) per `data_layer_conventions_policy`. The `UNIQUE (business_id, query_name)` constraint enforces that query names are distinct within a business but may repeat across businesses.

---

## Column reference

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| `id` | UUID | NOT NULL | `gen_uuid_v7()` | Primary key. UUID v7; time-ordered for B-tree efficiency. |
| `business_id` | UUID | NOT NULL | — | FK to `business_entities.id`. Tenant isolation column; RLS policies filter on this. |
| `query_name` | text | NOT NULL | — | Human-readable identifier for the template. Unique per business. Used in UI labels and audit payloads. |
| `gmail_query_string` | text | NOT NULL | — | Standard Gmail search syntax string. Evaluated server-side by the Gmail API. Must not be empty. |
| `sender_allowlist` | text[] | NULL | `NULL` | If non-null and non-empty, only messages from listed sender addresses match, regardless of the `gmail_query_string` result. NULL means no sender restriction. |
| `subject_keywords` | text[] | NULL | `NULL` | If non-null and non-empty, applied as an additional AND filter on the message subject client-side after Gmail API results are returned. NULL means no subject restriction. |
| `attachment_mime_types` | text[] | NOT NULL | `{application/pdf}` | MIME types the pipeline accepts from matching messages. Attachments with other MIME types are silently skipped. The default covers standard PDF invoices and statements. |
| `is_active` | boolean | NOT NULL | `TRUE` | Controls whether the pipeline evaluates this template on each run. Soft-delete pattern; rows are deactivated, not deleted. |
| `created_at` | timestamptz | NOT NULL | `now()` | Row creation timestamp. |
| `updated_at` | timestamptz | NOT NULL | `now()` | Last modification timestamp. Maintained by application layer on every UPDATE. |

---

## Default query templates

Three templates are seeded on business activation. Each is inserted with `is_active = TRUE`.

**Vendor invoices**

```json
{
  "query_name": "vendor_invoices",
  "gmail_query_string": "from:(invoice OR receipt) has:attachment",
  "sender_allowlist": null,
  "subject_keywords": null,
  "attachment_mime_types": ["application/pdf"]
}
```

Broad catch-all for vendor-sent invoices and receipts. No sender restriction at setup time; businesses narrow this by populating `sender_allowlist` after seeing false-positive results.

**Bank statements**

```json
{
  "query_name": "bank_statements",
  "gmail_query_string": "from:(statement OR bank) has:attachment",
  "sender_allowlist": null,
  "subject_keywords": ["statement", "account statement", "bank statement"],
  "attachment_mime_types": ["application/pdf"]
}
```

Subject keywords applied client-side reduce false positives from non-banking "statement" matches.

**Government documents**

```json
{
  "query_name": "government_documents",
  "gmail_query_string": "from:(tax OR vat OR government) has:attachment",
  "sender_allowlist": null,
  "subject_keywords": null,
  "attachment_mime_types": ["application/pdf"]
}
```

Targets VAT assessments, tax authority correspondence, and similar Cyprus Tax Department communications.

---

## Sender allowlist enforcement

When `sender_allowlist` is non-null and contains at least one entry, the intake pipeline applies the allowlist as a hard gate **after** the Gmail API returns matching messages. Messages whose `From` header (normalised to lowercase) does not match any entry in `sender_allowlist` are discarded regardless of whether they match `gmail_query_string`.

This means:

- A non-empty `sender_allowlist` always overrides `gmail_query_string` on sender dimension.
- Setting `gmail_query_string` to a broad pattern (e.g., `has:attachment`) combined with a tight `sender_allowlist` is a valid and common configuration for businesses with a known set of document senders.
- Sender comparison is case-insensitive exact match on the normalised email address (local-part + domain). Display names are ignored.

Empty array `{}` is treated identically to `NULL` — no restriction. The application layer normalises empty arrays to `NULL` on write.

---

## Gmail API scope and query evaluation

The intake pipeline calls `users.messages.list` with the `gmail_query_string` value as the `q` parameter. Query string evaluation is entirely server-side (Google's servers); the pipeline receives a list of message IDs.

Required OAuth scope: `https://www.googleapis.com/auth/gmail.readonly`. The pipeline never requests write scopes. Token storage and refresh are managed by the OAuth integration layer; see `gmail_oauth_integration.md`.

The pipeline then fetches message metadata and attachment data for each matching message ID. `subject_keywords` and `attachment_mime_types` filtering happens at this retrieval step, client-side.

Gmail API quota and rate limits are handled by Block 09's intake phase retry logic. Quota exhaustion results in a deferred retry on the next pipeline run, not a workflow failure.

---

## Audit event

| Event | Severity | Trigger |
| --- | --- | --- |
| `INTAKE_GMAIL_QUERY_UPDATED` | LOW | Any INSERT, UPDATE, or soft-delete (`is_active` set to `FALSE`) on a `document_gmail_queries` row |

`INTAKE_GMAIL_QUERY_UPDATED` payload: `query_id`, `business_id`, `query_name`, `change_kind` (`CREATED`, `UPDATED`, or `DEACTIVATED`), `changed_by_user_id`.

The event is emitted on every configuration change. Query execution results (how many messages matched, how many were ingested) are recorded via `DOCUMENT_EMAIL_FINDER_RAN` in the DOCUMENT domain (Block 09), not in this event.

---

## RLS

Row-level security uses `business_id`. The authenticated session must have an active role on the matching `business_id`. Cross-business reads are impossible regardless of role. Configuration changes (INSERT, UPDATE) require `Owner` or `Admin` role.

---

## Cross-references

- `tool_ocr_extract_document.md` — downstream consumer of documents discovered via these queries
- `evidence_pdf_schema.md` — schema for PDFs that may arrive via Gmail
- `gmail_oauth_integration.md` — OAuth token lifecycle and scope management for the Gmail connection
- `mobile_write_rejection_endpoints.md` — configuration endpoints for this table are blocked on mobile
- Block 09 — Document Intake phase doc (full Gmail finder pipeline)
- `data_layer_conventions_policy` — UUID v7 generation, canonical JSON
