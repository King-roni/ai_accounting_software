# Block 07 — Phase 06: Evidence PDF Generation

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 7.5 — Transaction Evidence PDF Generation)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 2 — Structured Data Is the Source of Truth)
- Decisions log: `Docs/decisions_log.md` (PDFs generated from structured rows; structured row remains canonical)

## Phase Goal

Generate one clean evidence PDF per accepted transaction. The PDF is rendered from the structured `transactions` row (Principle 2 — never the other way around), hashed via Block 04 Phase 01's `hashFile`, written to Raw Upload, and linked back to the transaction via an `evidence_pdfs` row. After this phase, every transaction in the system has a human-readable artefact that an auditor or accountant can open without querying the database.

## Dependencies

- Phase 04 (normalization produces `transactions` rows)
- Phase 05 (dedup; only `NEW` transactions get evidence PDFs)
- Block 04 Phase 01 (`hashFile` for content hash)
- Block 04 Phase 02 (`evidence_pdfs` schema; FK to `transactions`)
- Block 04 Phase 05 (Raw Upload zone — generated PDFs land here)

## Deliverables

- **PDF generator service** — `generateEvidencePDF(transaction) → { bytes, filename, hash }`:
  - Renders a single-page A4 PDF with a clean, scannable layout.
  - Fields included:
    - Business name and registration number.
    - Bank account name + masked IBAN.
    - Statement period start/end.
    - Transaction date + booking date.
    - Amount + currency + direction.
    - Counterparty name + masked counterparty identifier.
    - Description (cleaned `normalized_description`).
    - Reference.
    - Transaction id (UUID).
    - Source statement id + source row index.
    - `generated_from_transaction_version` (for snapshot semantics — see below).
    - Generation timestamp.
  - Rendering library is sub-doc-tracked (typical choices: `puppeteer`, `weasyprint`, server-side ReactPDF). The choice doesn't change the contract.
- **Generation pipeline:**
  - Invoked for each `NEW` transaction after Phase 05.
  - PDF bytes hashed via `hashFile`.
  - Written to Raw Upload at `{org_id}/{business_id}/evidence_pdf/{file_id}`.
  - `evidence_pdfs` row inserted with `transaction_id`, `file_id`, `file_hash`, `generated_from_transaction_version`, `generated_at`.
- **Re-entry path for resolved duplicates:**
  - When a row that was initially `DUPLICATE_POSSIBLE` or `NEEDS_REVIEW` is later resolved by the user as confirm-as-new (via Phase 05's resolution actions), evidence generation runs as a **follow-up tool invocation** scoped to that specific row — not as part of the original bulk batch.
  - The follow-up has its own dedup key (`(transaction_id, transaction_version)`) so it never duplicates an existing `evidence_pdfs` row.
- **Snapshot semantics:**
  - The PDF is a snapshot of the transaction at generation time. If the transaction is later edited (e.g., user retags it), the PDF is **not** auto-regenerated. The structured row remains canonical (Principle 2).
  - Re-generation is explicit — a future user-driven action ("regenerate evidence PDF") creates a new `evidence_pdfs` row with a higher `generated_from_transaction_version`. Old rows remain for audit traceability.
- **Bulk generation:**
  - All `NEW` transactions from a single statement upload generate their PDFs in parallel (bounded concurrency).
  - A failure on one PDF doesn't block the others; failed ones produce a HIGH-severity review issue and the phase continues.
  - The bulk operation registers as a Block 03 tool with idempotent semantics — replaying produces the same `evidence_pdfs` rows (matched by `(transaction_id, file_hash)`).
- **Audit events:** `EVIDENCE_PDF_GENERATED`, `EVIDENCE_PDF_GENERATION_FAILED`, `EVIDENCE_PDF_REGENERATED` (for the explicit re-generation path).

## Definition of Done

- Every `NEW` transaction from a representative Revolut CSV gets exactly one `evidence_pdfs` row with a non-null `file_hash` and a fetchable file in Raw Upload.
- The PDF, when opened, shows the structured fields legibly with masked IBANs and counterparty identifiers (never plaintext).
- Editing a transaction does NOT silently regenerate its PDF; explicit regeneration produces a new versioned row.
- Bulk generation across a 200-row statement completes within a sensible time bound (sub-doc tracks performance budget).
- A simulated PDF generation failure on one transaction produces a HIGH review issue and does not block the rest of the batch.
- Tests cover happy path, single-PDF failure-doesn't-block-batch, regeneration semantics, snapshot-vs-current-row divergence.

## Sub-doc Hooks (Stage 4)

- **PDF template & layout sub-doc** — exact field placement, typography, branding, accessibility.
- **PDF rendering library sub-doc** — choice between Puppeteer / WeasyPrint / ReactPDF, perf characteristics, failure modes.
- **Snapshot vs current-row divergence sub-doc** — UX for "this PDF reflects the transaction as of [date]", regenerate flow.
- **Bulk generation perf sub-doc** — concurrency limits, queue management, budget per statement.
- **Re-generation policy sub-doc** — who can trigger, what triggers it implicitly (probably nothing in MVP), audit shape.
