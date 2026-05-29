# Block 07 — Phase 01: Upload Pipeline & File Intake

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 7.1 — Statement Upload)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 02 `statement_uploads`, Phase 05 Raw Upload zone)
- Decisions log: `Docs/decisions_log.md` (Supabase Storage; EU only; CSV preferred, PDF supported)

## Phase Goal

Stand up the file-intake side of the statement pipeline: a permissioned upload API that lands Revolut CSVs (and PDFs) into the Raw Upload zone with a content hash, a `statement_uploads` row, and a clean status lifecycle. After this phase, parsing (Phase 02) has files queued and ready, and the audit log has a complete trail from request through landing.

## Dependencies

- Block 02 Phase 01 (`bank_accounts` table — uploads scope to a specific bank account)
- Block 02 Phase 04 (`canPerform` for the `WORKFLOW_EXECUTE` surface)
- Block 04 Phase 01 (hashing helpers)
- Block 04 Phase 02 (`statement_uploads` schema)
- Block 04 Phase 05 (Raw Upload zone, signed-URL flow)
- Block 05 Phase 02 (audit log emission)

## Deliverables

- **Upload-sign endpoint** — `POST /statement-uploads/sign` with body `{ business_id, bank_account_id, declared_period_start, declared_period_end, file_format, original_filename }`. Validates `canPerform`, returns a signed upload URL scoped to the right `raw-uploads` path (per Block 04 Phase 05's folder convention).
- **Upload-completion handler** — webhook/callback after the client uploads to Storage:
  1. Computes `file_hash` via Block 04 Phase 01's `hashFile`.
  2. Checks for an existing `statement_uploads` row with the same `(bank_account_id, file_hash)` — if found, returns `409 Conflict` with `STATEMENT_UPLOAD_REJECTED_DUPLICATE_HASH` audit event. (Re-uploading the exact same file is rejected, not silently ignored.)
  3. Persists a `statement_uploads` row with `file_id`, `file_hash`, declared period, `file_format` (`CSV` / `PDF`), `provider` (`REVOLUT` for MVP, extensible).
  4. Emits `STATEMENT_UPLOAD_COMPLETED` (payload defined in Phase 09). **Phase 01 ends here at status `UPLOADED`** — it never invokes the parser directly and never advances status further. The workflow engine's INGESTION phase (registered in Phase 07) is what owns every subsequent transition (`UPLOADED → PARSING → PARSED → ACCEPTED`) per Block 01 Principle 1 (no direct import path outside Block 03).
- **Status lifecycle** on `statement_uploads.upload_status`:
  - `UPLOADED` — file landed; awaiting parser.
  - `PARSING` — parser working.
  - `PARSED` — rows extracted; awaiting normalization + dedup.
  - `ACCEPTED` — rows persisted into `transactions` and `evidence_pdfs`; ready for downstream workflow phases.
  - `FAILED` — parser or normalization unrecoverable; review issue raised per Phase 08.
- **Orphan cleanup** — signed URLs that get used but whose completion handler never fires are cleaned up after a configured window (extends Block 04 Phase 05's orphan rule).
- **Audit events:** `STATEMENT_UPLOAD_REQUESTED` (sign), `STATEMENT_UPLOAD_COMPLETED` (the same event whose payload is defined in Phase 09 — Phase 01 is the emission point; Block 03 Phase 09 is the consumer), `STATEMENT_UPLOAD_REJECTED_DUPLICATE_HASH`, `STATEMENT_UPLOAD_REJECTED_PERMISSION`, `STATEMENT_UPLOAD_FAILED`.

## Definition of Done

- An authenticated user with `WORKFLOW_EXECUTE` permission can request a signed URL, upload a Revolut CSV, and have the completion handler create a `statement_uploads` row with the right hash and status `UPLOADED`.
- Re-uploading the same file (same hash) under the same `bank_account_id` is rejected with `409` and the right audit event.
- An attempt to upload to a bank account the user has no permission on is rejected at the sign endpoint.
- Tests cover happy path, duplicate-hash rejection, permission denial, orphan cleanup.

## Sub-doc Hooks (Stage 4)

- **Upload API endpoint sub-doc** — request/response shapes, error codes, rate limits.
- **Status transition sub-doc** — exact transitions, who triggers each, audit pairing.
- **Duplicate-hash policy sub-doc** — same-hash rule across bank accounts (currently per-account; cross-account rule is post-MVP).
- **Orphan cleanup sub-doc** — completion-window TTL, audit-event shape.
