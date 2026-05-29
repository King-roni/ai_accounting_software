# Block 07 — Bank Statement Pipeline

## Role in the System

This block converts a raw uploaded bank statement into a set of normalized, deduplicated, hashed transaction records — and produces a clean evidence PDF for each accepted transaction. It is the entry point for both the OUT and IN workflows; without it, no downstream block has anything to work on.

The pipeline has one job, expressed in five phases: receive the file, parse it, normalize each row, deduplicate against prior imports, generate per-transaction evidence. After this block, every transaction is queryable, fingerprinted, and ready for classification.

---

## Scope

### In scope
- Statement upload handling: file format detection, hash computation, persistence to the Raw Upload zone
- CSV parsing — Revolut export structures first, with the parser designed to extend to other banks
- PDF parsing — for banks or periods where only PDF exports exist; relies on OCR
- Row normalization (date, amount, currency, direction, counterparty, description, reference)
- Source-row hashing and per-transaction fingerprinting
- Deduplication against earlier imports for the same business and bank account
- Generation of one evidence PDF per accepted transaction, written to the Raw Upload zone

### Out of scope (covered elsewhere)
- Type and tag assignment → Block 08 (Transaction Classification & Tagging)
- Searching for or extracting invoices and receipts → Block 09 (Document Intake & Extraction)
- Matching transactions to documents → Block 10 (Matching Engine)
- Storage zone semantics and retention → Block 04 (Data Architecture)
- Workflow orchestration, retries, gating → Block 03 (Workflow Engine)

---

## The Five Phases

### 7.1 — Statement Upload
The file arrives via UI upload. The pipeline computes its SHA-256, persists the original byte stream to Raw Upload (Supabase Storage), and creates a `Statement Upload` record linking the file hash to the business, bank account, declared period, and uploader. Re-uploading the exact same file is detected by hash and rejected with a clear message rather than re-processed.

### 7.2 — Parsing
The parser is selected by `(provider, file_format)`. Initial coverage:

- `revolut, csv` — the primary path, expected to handle the bulk of uploads
- `revolut, pdf` — supported via **Google Document AI** for OCR + table extraction; lower confidence than CSV
- `other_bank, csv` — extensible by adding format definitions; not in MVP scope
- `other_bank, pdf` — same; deferred

Parsing converts file rows into raw transaction candidates with provider-native fields preserved alongside normalized fields.

**Partial uploads:** if the file is truncated or corrupted, the parser processes what's parseable and raises a HIGH-severity review issue describing the gap. The user can re-upload a complete file as an additive import.

**Statement period:** the user declares the period at upload; the parser warns (without rejecting) if rows fall outside the declared period. This catches user error without overriding intent.

### 7.3 — Normalization
Every raw candidate is normalized into the canonical transaction shape: ISO date, decimal amount, ISO currency, direction (`IN`/`OUT`), clean description, counterparty candidate, reference.

**FX exchange rows:** a Revolut FX conversion (e.g. EUR → USD) becomes **one transaction with paired legs** — a single record with explicit fields for both currencies, both amounts, and the bank-recorded rate. Block 11 derives multiple ledger entries from this single transaction. This avoids the duplication that splitting into two transactions would create.

This phase produces:

- `source_row_hash` — SHA-256 over the raw row content; used by deduplication
- `transaction_fingerprint` — a normalized signature (date + amount + currency + cleaned description) used as a softer dedup signal

### 7.4 — Deduplication
Every candidate is checked against earlier imports for the same `business_id` and `bank_account_id`. Statuses produced:

- `NEW` — no prior match; proceeds to evidence generation
- `DUPLICATE_EXACT` — same source row hash; rejected silently with an audit event
- `DUPLICATE_POSSIBLE` — same fingerprint, different hash; routed to a review issue
- `NEEDS_REVIEW` — ambiguous case; routed to a review issue

The deduplication rules are deliberately strict on the auto-accept side and lenient on the auto-reject side. When in doubt, raise a review issue rather than silently drop or duplicate a row.

### 7.5 — Evidence PDF Generation
For every `NEW` transaction, the pipeline generates a clean PDF page using the transaction's structured fields. The PDF is generated from the data, never the other way around (Principle 2). It includes business name, bank account, statement period, transaction date, booking date, amount, currency, direction, counterparty, description, reference, transaction id, and source statement id. The PDF is written to Raw Upload, hashed, and linked to the transaction via an `Evidence PDF` record.

---

## Key Concepts

- **Statement Upload** — the original file, hashed, stored in Raw Upload, and linked to a record in the operational DB.
- **Parse Strategy** — a pluggable definition keyed by `(provider, file_format)`.
- **Normalized Transaction** — the canonical row shape that downstream blocks consume.
- **Source Row Hash / Fingerprint** — paired identifiers used for strict (hash) and soft (fingerprint) deduplication.
- **Evidence PDF** — generated artifact, hashed, linked, but not authoritative; the structured row is.

---

## Interfaces

### Inputs
- Statement files uploaded by the user, scoped by business and bank account
- Workflow run context from Block 03 (which run, which period, which bank account)

### Outputs
- `Statement Upload` records and the original file in Raw Upload
- `Transaction` records in the operational DB
- `Evidence PDF` records and the generated files in Raw Upload
- Review issues for ambiguous duplicates (`DUPLICATE_POSSIBLE`, `NEEDS_REVIEW`)
- Audit events on every state transition

---

## Operating Rules

- **Principle 2 (Structured Data is Truth):** evidence PDFs are generated from structured rows; rows are never re-parsed from PDFs to "refresh" them.
- **Principle 1 (Workflow-First):** the pipeline runs as registered phases of the OUT and IN workflows; there is no direct "import this file" path outside Block 03.
- **Principle 4 (Security by Design):** every uploaded file is hashed and stored encrypted at rest in Raw Upload; access goes through signed URLs.
- **Triggers:** Block 03's manual + event-based triggers apply — uploading a statement raises an event that can auto-start the OUT workflow for the corresponding period.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **OCR engine:** Google Document AI (managed, EU) — covered in Phase 7.2.
- **FX representation:** one transaction with paired legs — covered in Phase 7.3.
- **Partial uploads:** accept and warn — covered in Phase 7.2.
- **Statement period:** trust user's declared period, warn on outliers — covered in Phase 7.2.

### Deferred

- **Non-Revolut bank support order** — beyond MVP. The parser is structured by `(provider, file_format)` so additional banks can be added incrementally.
