# Block 04 — Data Architecture & Storage Zones

## Role in the System

This block defines what the system stores, where it stores each kind of data, and how data moves between zones. It is the structural counterpart to Block 05 (Security & Audit Layer): Block 04 says where things live, Block 05 says how they are protected.

Every record in the system can be located by answering two questions: which zone does it belong to, and which entity in the canonical schema does it represent?

---

## Stack Choice

The system is built on **PostgreSQL via Supabase** (managed, EU regions). Supabase Storage handles all object storage — both Raw Upload and Finalized Archive zones. All infrastructure runs in EU regions; there are no exceptions for any service in MVP.

Tenant isolation leans on Postgres row-level security as the primary enforcement mechanism (Block 02 owns the policy model; this block describes where the data lives).

## Scope

### In scope
- The five storage zones and what each contains
- The canonical entity overview (high-level — full field lists live in the core concept doc, Section 6, and will be refined in phase docs)
- Movement of data between zones (promotion, demotion, archival)
- Retention policy hooks (≥ 6 years for VAT/books)
- Hashing strategy for files and records

### Out of scope (covered elsewhere)
- Encryption keys and key management → Block 05
- Access control on zones → Block 02 + Block 05
- The actual schema migrations and ORM specifics → phase docs and sub-docs

---

## Storage Zones

### Zone 1 — Raw Upload

Original, immutable copies of every uploaded file: bank statements, invoices, receipts, contracts, and any other supporting document. The source of evidence.

- Every file has a SHA-256 hash recorded at upload.
- Files are addressed by hash and metadata, never by filename.
- Direct public access is blocked; reads happen via signed temporary URLs.
- Zone is encrypted at rest and never exposes plaintext to non-tenant principals.

### Zone 2 — Processing

Short-lived intermediate artifacts produced during a workflow run: OCR text, parsed invoice fields before they're written to the operational record, candidate match payloads, AI-bound (redacted) prompts, AI responses prior to schema validation.

- Items in this zone are tagged with their parent workflow run.
- Items are pruned when the run completes successfully, or after a fixed TTL on failure.
- Sensitive fields are minimized before any item enters this zone (Block 06 owns the redaction; this zone owns the lifecycle).

### Zone 3 — Operational Database

The active, queryable system of record. Holds all in-flight and pre-finalization data:

- Tenancy: User, Organization, Business Entity, Bank Account
- Workflow: Workflow Run, Phase Status, Tool Invocations
- Domain: Statement Upload, Transaction, Evidence PDF link, Document, Match Record, Ledger Entry (draft), Review Issue
- Audit: links/pointers to audit events stored in Block 05's log

Every row carries `organization_id`, `business_id`, and the relevant lifecycle status fields (e.g. `match_status`, `review_status`, `finalization_status`).

### Zone 4 — Finalized Secure Archive

Locked, immutable accounting data for finalized periods. Once a period reaches `FINALIZED` (per Block 15), its transactions, ledger entries, evidence files, finalization summary, and approval record are written here and become read-only.

- **Physical model:** a separate Postgres schema with stricter RLS policies than the operational schema, plus Supabase Storage Object Lock for archive files. The schema lives in the same Supabase project to keep operational simplicity, but its policies are written so that operational service roles cannot read or write archive rows.
- File hashes recorded; retrieval is verified against hash on every read.
- Retention configurable per business; default ≥ 6 years for VAT and books.
- **Adjustments are interleaved with original records, additive only** — every adjustment row links to the original it amends with an explicit reason and a structured delta. Original records are never modified.

### Zone 5 — Analytics / Dashboard

Aggregated, summarized data for fast dashboard rendering. Built from the operational database and the finalized archive. Holds totals, counts, and aggregates — not raw document content.

- Drill-down requests escalate to the operational database or archive, gated by Block 02 permissions.
- **Refresh model:** eventual consistency via background jobs. Aggregates rebuild after finalization and on schedule. Dashboards may lag a few minutes after a period locks; this is acceptable for monthly bookkeeping cadence and avoids slowing the finalization path.

---

## Canonical Entities

The core concept doc (Section 6) defines the field-level shape of each entity. This block establishes their roles and where each lives.

| Entity | Primary zone | Notes |
| --- | --- | --- |
| User, Organization, Business Entity, Bank Account | Operational Database | Tenancy backbone |
| Statement Upload | Raw Upload (file) + Operational Database (record) | File hash links the two |
| Transaction | Operational Database | Promoted to Archive on finalization |
| Transaction Evidence PDF | Raw Upload (file, generated) + Operational Database (record) | Generated, not uploaded |
| Document (invoice, receipt, contract) | Raw Upload (file) + Operational Database (record) | Source can be email, drive, manual |
| Match Record | Operational Database | Promoted to Archive with its parent transaction |
| Draft Ledger Entry | Operational Database | Promoted to Archive on finalization (becomes immutable Ledger Entry) |
| Review Issue | Operational Database | Resolved or carried as resolved-record into Archive |
| Workflow Run | Operational Database | Frozen reference to its run summary moves to Archive on finalization |
| Audit Event | Block 05's audit log (logical zone, physically separate) | Tamper-resistant |

---

## Movement Between Zones

```text
Upload
  → Raw Upload (file)
  → Operational Database (record with file hash)

Workflow run
  → Operational Database (transactions, matches, draft ledger, review issues)
  ↔ Processing (OCR text, AI payloads, candidate fields) — pruned after run
  
Finalization (Block 15)
  → Finalized Archive (locked transactions, ledger, evidence file references, approval, finalization summary)
  → Analytics (aggregates rebuilt)

Adjustment run
  → New records in Operational Database
  → Promoted to Finalized Archive on adjustment finalization (additive, never destructive)
```

A record never moves "down" a zone. Demotion is impossible by construction; corrections happen via adjustment runs.

---

## Hashing Strategy

- Every uploaded file: SHA-256 computed on receipt, stored alongside the file record.
- Every generated file (e.g. evidence PDF, finalization package): SHA-256 computed on generation.
- Statement uploads: a `source_row_hash` is computed per row, used by the deduplication phase in Block 07.
- Finalized archive entries: a content hash is computed at lock time and used to verify immutability on every read.

---

## Retention

- Default retention for finalized archive: **6 years from the end of the accounting period** (the canonical "6-year legal retention window" referenced by Blocks 12 and 15).
- Operational Database records are kept until finalization, then either purged (processing artifacts), retained as audit references, or promoted (everything in the entity table above).
- Raw Upload files persist for the same retention window as the records that reference them.
- Audit events follow the same retention as the data they describe.

The retention engine runs as an **internal scheduled background job** (not a workflow trigger; Block 03's manual + event triggers are unaffected by this), with safeguards: nothing is deleted while any open workflow run, adjustment run, or legal hold references it.

**Legal hold:** implemented as a per-business flag. When set, automated retention deletion is suspended for the entire business until the hold is lifted. Setting and lifting the flag is a privileged action recorded in the audit log.

---

## Interfaces

### Inputs
- File uploads (via UI) and email/Drive ingestion (via Block 09)
- Workflow phase outputs (via Block 03)
- Processing-zone AI artefacts (payloads and responses) from Block 06, pruned post-run
- Finalization handoff (from Block 15)

### Outputs
- Records and files queryable by other blocks under the tenancy contract from Block 02
- Aggregates available to Block 16 (Dashboard & Reporting)
- Archive items available to exports (Block 16) and audits (Block 05)

---

## Operating Rules

- **Principle 2 (Structured Data is Truth):** every file has a structured record; queries hit records, not files.
- **Principle 4 (Security by Design):** zones are not interchangeable; a service account that can read Operational Database cannot, by default, read Finalized Archive.
- **Principle 1 (Workflow-First):** writes to the Operational Database happen via Block 03's tool invocations; direct writes outside a workflow are not permitted in production code paths.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Database:** PostgreSQL via Supabase, EU regions — covered in Stack Choice.
- **Object storage:** Supabase Storage — covered in Stack Choice.
- **Finalized Archive shape:** separate Postgres schema + Storage Object Lock — covered in Zone 4.
- **Analytics refresh:** eventual consistency via background jobs — covered in Zone 5.
- **Adjustment placement:** interleaved with original, additive — covered in Zone 4.
- **Legal hold:** per-business flag — covered in Retention.

No open questions remain at the architecture level. Phase docs will define schema migrations, exact RLS policies for each zone, the background job schedule for analytics, and the legal-hold UI flow.
