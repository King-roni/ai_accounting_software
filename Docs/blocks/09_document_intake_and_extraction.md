# Block 09 — Document Intake & Extraction

## Role in the System

This block is responsible for finding and processing every document that supports a transaction: invoices, receipts, contracts, proofs of payment. Documents arrive through three paths — connected email, connected Google Drive folders, or manual upload — and each is processed into a structured `Document` record with extracted fields.

The block does not match documents to transactions; that's Block 10's job. It does, however, decide *what to look for* based on the transaction context (counterparty, amount, date, tag), so its searches are scoped, not blanket.

---

## Scope

### In scope
- Email finder: scoped Gmail search per transaction or per workflow run
- Drive finder: folder-restricted Google Drive search
- Manual upload UI integration
- OCR for image-based or scanned documents
- Structured field extraction (supplier, dates, amounts, VAT, totals)
- Document hashing and persistence to Raw Upload
- Source-of-truth tracking: where did each document come from, with audit context

### Out of scope (covered elsewhere)
- Matching documents to transactions → Block 10 (Matching Engine)
- OAuth grant management for Gmail and Drive → Block 02 (Tenancy & Access Control)
- Storage zones and retention → Block 04 (Data Architecture)
- AI calls used for extraction → Block 06 (AI Layer / Privacy Gateway)
- Invoice PDFs produced by Block 13's Invoice Generator — these originate as structured records inside the platform and bypass this block's intake pipeline → Block 13

---

## The Three Source Paths

### 9.1 — Email Finder (Gmail)
Searches the connected Gmail account for invoices and receipts that support a given transaction or set of transactions.

The search is **always scoped**, never blanket. Queries are drawn from a **fixed library of query patterns** keyed by supplier type and transaction context — not generated per-call by an LLM. Fixed templates are auditable, testable, and don't burn AI cost on the discovery step. New templates are added as the supplier set grows.

Search inputs per transaction:

- Amount and currency (exact match priority)
- Date window around the transaction date
- Counterparty / merchant name (normalized)
- Known supplier email domain (from recurring vendor memory)
- Description keywords
- Payment reference if present

**Spam/phishing filtering:** the finder skips emails Gmail has labelled as spam, and applies a **per-business sender allowlist**. Senders outside the allowlist that aren't already-known suppliers don't reach the matching engine. This protects against phishing invoices that happen to match an amount.

Result candidates carry a `discovery_reason` (which query yielded them) and feed into Block 10.

### 9.2 — Drive Finder (Google Drive)
Searches a connected Drive folder for documents not found via email — particularly relevant for businesses where contractor invoices and team-member receipts live in Drive rather than email.

The user **explicitly connects one root invoice folder per business**; the finder cannot read folders outside it. The operator's convention is **2-week date subfolders** (e.g. `2026-04-01_to_2026-04-14/`, `2026-04-15_to_2026-04-28/`), and the Drive finder uses this convention to **scope searches by transaction date** — only the subfolder(s) covering the transaction date and adjacent windows are searched.

Search uses file names, folder structure, OCR text (if already extracted), and basic metadata.

### 9.3 — Manual Upload
The user uploads a missing document directly. The intake pipeline normalizes the upload exactly as for email/Drive: hash it, persist it to Raw Upload, OCR if needed, extract fields, link by source.

The manual path also handles negative cases: "no invoice available", "internal transfer — no document needed", "non-deductible — keep as record". These produce a `Document Stub` record that records the user's reasoning for the audit trail without claiming an underlying file exists.

---

## OCR & Field Extraction

### OCR
Documents arriving as images, scanned PDFs, or photos pass through **Google Document AI** for OCR + structured extraction. The same engine is used by Block 07 for PDF bank statements, so there's a single OCR vendor across the platform.

**Attachment formats supported:** PDF, DOCX, JPG, PNG, HEIC, and other common image types. Non-supported formats are rejected with a clear message and a suggestion to convert.

### Field Extraction
Extraction targets the canonical document field set:

```text
supplier name
supplier address
supplier country
supplier VAT number
invoice number
invoice date
due date
service period
line item summaries
subtotal
VAT rate
VAT amount
total amount
currency
payment reference
client/business name
```

Extraction is layered:

1. **Deterministic parsing** — for digital PDFs with extractable text, regex/template parsing handles the structured cases (e.g., common SaaS invoice formats).
2. **Local AI (Block 06 Tier 2)** — for OCR'd or non-templated documents, the local model on the operator's dedicated machine produces a typed JSON of fields.
3. **External AI (Block 06 Tier 3)** — only when local extraction fails confidence checks; the document text passes through the Privacy Gateway with full redaction policy applied.

Output is always a typed `Document` record with extracted fields plus a confidence score per field. Low-confidence fields go to Block 14 as confirmation issues, not as failures.

---

## Document Lifecycle

```text
DISCOVERED       (found by email/Drive search; unprocessed)
INGESTED         (file hashed and stored; OCR'd if needed)
EXTRACTED        (fields extracted; confidence scored)
LINKED_CANDIDATE (sent to Block 10 as a candidate for matching)
MATCHED          (linked to a transaction; updated by Block 10)
DISMISSED        (rejected: not relevant, or already matched elsewhere)
```

Every transition produces an audit event with the source path (email message id / Drive file id / manual upload) preserved, so an auditor can always answer "where did this document come from?".

---

## Interfaces

### Inputs
- Workflow run context (which business, which period, which transactions need evidence)
- Transactions from Block 07 + classifications from Block 08 (so the finder knows what to look for)
- OAuth tokens for Gmail/Drive (managed by Block 02; refreshable by any Owner/Admin per the Stage 1 decision)
- Manual uploads from the UI

### Outputs
- `Document` records with extracted fields and confidence scores
- File payloads in Raw Upload (Supabase Storage)
- Discovery candidates passed to Block 10 (Matching Engine)
- Confirmation issues for low-confidence extractions (consumed by Block 14)
- Audit events for every external API call and every ingestion event

---

## Operating Rules

- **Principle 4 (Security by Design):** Gmail and Drive scopes are read-only and explicitly bounded; the finder never reads outside the configured scope.
- **Data minimization (sub-rule of Principle 4):** queries are derived from transaction context — not "give me all email from the last month".
- **Principle 2 (Structured Data is Truth):** extracted fields populate the structured `Document` record; the file is stored as evidence but not parsed on demand for queries.
- **Principle 4 (Security by Design — gateway-only AI):** all extraction AI passes through Block 06's Privacy Gateway; raw email content and full invoice text are never sent to Tier 3 unless the redaction policy permits.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **OCR engine:** Google Document AI — covered in OCR & Field Extraction.
- **Email search queries:** fixed library of query patterns — covered in Phase 9.1.
- **Drive folder discovery:** user-mapped root folder with 2-week date subfolder convention — covered in Phase 9.2.
- **Non-PDF attachments:** convert + OCR for all common types — covered in OCR & Field Extraction.
- **Spam filtering:** Gmail spam labels + per-business sender allowlist — covered in Phase 9.1.

### Deferred

- **Attachment-depth limit and forwarded-chain handling** — exact rules tuned during phase decomposition based on real Gmail traffic.
