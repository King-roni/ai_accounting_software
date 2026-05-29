# Block 09 — Phase 07: Manual Upload Path

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Phase 9.3 — Manual Upload)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 05 — Raw Upload zone primitive)
- Block doc: `Docs/blocks/14_review_queue.md` (consumer — manual uploads originate from review-queue resolution actions)

## Phase Goal

Provide the third source path: the user uploads a missing invoice, receipt, or contract directly, OR documents an exception ("no invoice available", "internal transfer — no document needed", "non-deductible"). After this phase, every OUT transaction can either get its supporting document via manual upload or have its missing-evidence status formally documented through a `Document Stub`.

## Dependencies

- Phase 01 (`document_source_links` for the manual provenance)
- Phase 02 (state machine — manual file path runs the full lifecycle; stubs skip OCR/extraction)
- Phase 03 (OCR pipeline for uploaded files)
- Phase 04 (field extraction)
- Block 02 Phase 04 (`canPerform` — `WORKFLOW_EXECUTE`)
- Block 04 Phase 05 (Raw Upload zone — signed-URL upload primitive)
- Block 14 (consumer — the missing-evidence review issue is where users initiate manual upload / stub creation)

## Deliverables

- **Manual-upload UI entry points:**
  - From a "Missing Documents" review issue (Block 14 — phase docs not yet written; this phase contributes the contract).
  - From the transaction detail view directly.
  - Drag-drop multi-file upload supported; each file produces an independent `Document` candidate scoped to one transaction (or to multiple transactions when the user explicitly assigns).
- **Manual-upload flow:**
  1. User initiates upload from a review issue or transaction view.
  2. Backend issues a signed URL via Block 04 Phase 05's primitive (`entity_type = DOCUMENT_MANUAL`).
  3. Client uploads to Storage.
  4. Backend confirms: creates a `Document` row with `source = MANUAL` and `source_location = "manual:{upload_id}"`, creates a `document_source_links` row, transitions `null → DISCOVERED` (candidate created); then hashes the file via `hashFile`, persists to Raw Upload, and transitions `DISCOVERED → INGESTED` per Phase 02's state-machine boundaries.
  5. Phase 03 OCR + Phase 04 extraction proceed automatically.
  6. The document is linked to the originating transaction by user intent (the review issue carries the `transaction_id`); a manual `Match Record` is created with `match_status = MATCHED_NEEDS_CONFIRMATION` (Block 10 confirms or a user confirms via the review queue).
- **`Document Stub` flow** — when the user explicitly says "there is no document":
  - Stub creation actions surfaced from the Missing Documents review issue:
    - **`Mark as no invoice available`** — the user attests no invoice exists; reason text required.
    - **`Mark as internal transfer`** — confirms the transaction is a transfer between own accounts; closes the missing-evidence requirement.
    - **`Mark as non-deductible`** — non-deductible expense with documented reason; no invoice required for accounting purposes.
    - **`Mark as bank fee`** — confirms bank-generated evidence is sufficient.
    - **`Mark as awaiting accountant review`** — punts the decision; flagged for accountant review per Block 11.
  - For each: a `Document` row with `document_type = STUB`, `file_id = NULL`, `source = MANUAL`, the structured stub reason (in a new column `stub_reason` if not already present, or in `notes`).
  - **Note:** `add explanation note` (a Block 12 `MANUAL_UPLOAD_HOLD` resolution action) is **not** a stub variant — it attaches a free-text comment to the existing missing-evidence review issue without creating a `Document` row. Phase 07's stub variants are reserved for actions that close the missing-evidence requirement.
  - State transition: `null → DISCOVERED → DISMISSED` with the structured stub reason as the dismissal reason (per Phase 02's manual-stub bypass).
  - The stub satisfies Block 12's evidence requirement for the transaction (so OUT_EXPENSE no longer counts as missing).
- **Permission and step-up:**
  - Manual upload requires `WORKFLOW_EXECUTE` permission.
  - Document Stub creation for `mark as no invoice available` requires step-up (it's an attestation that affects the audit record).
- **Audit events:** `MANUAL_UPLOAD_INITIATED`, `MANUAL_UPLOAD_COMPLETED`, `DOCUMENT_STUB_CREATED` (with `stub_reason`), `DOCUMENT_MANUAL_LINKED_TO_TRANSACTION`.

## Definition of Done

- A user with the right permission can upload a PDF invoice via drag-drop; the file lands in Raw Upload, OCR/extraction runs, a candidate match is created against the originating transaction.
- A user can mark a transaction as "no invoice available" with a reason; a Document Stub is created and the transaction's missing-evidence requirement is satisfied.
- All five stub variants work and produce the right `stub_reason` on the document row.
- Step-up auth gates the `no invoice available` and `non-deductible` paths.
- Multi-file drag-drop produces N independent documents.
- Tests cover: single file upload, multi-file upload, each stub variant, permission denial, step-up requirement.

## Sub-doc Hooks (Stage 4)

- **Manual upload UX sub-doc** — drag-drop interactions, multi-file UX, progress indicators, error recovery.
- **Document Stub reasons taxonomy sub-doc** — exact reason strings, when each is appropriate, audit-trail expectations.
- **Linking manual upload to a specific transaction sub-doc** — single-transaction vs multi-transaction (e.g., one consolidated invoice covering multiple payments) UX.
- **Bulk-upload sub-doc** — handling 50+ files at once (e.g., end-of-quarter catch-up), backpressure, OCR queueing.
- **Step-up policy sub-doc** — exactly which stub reasons require step-up; calibration based on legal exposure.
