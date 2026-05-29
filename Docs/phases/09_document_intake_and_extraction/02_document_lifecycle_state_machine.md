# Block 09 — Phase 02: Document Lifecycle State Machine

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Document Lifecycle section)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 04's pattern — single-chokepoint state machine with audit coupling)

## Phase Goal

Build the state machine that governs every document's progression through intake, extraction, candidacy for matching, and final outcome. Mirrors Block 03's run-lifecycle pattern — one chokepoint, declarative transition table, audit-coupled emission. After this phase, no code in Phases 03–10 changes a document's state without going through this single function.

## Dependencies

- Phase 01 (schema; `document_extraction_results` for extraction completion signals)
- Block 04 Phase 03 (`documents.extraction_status` column already exists with the canonical state values)
- Block 05 Phase 02 (audit log emission)

## Deliverables

- **State machine** — declarative transition table:
  - `null → DISCOVERED` — created by a source finder (Phase 05 Email, Phase 06 Drive) when a candidate document is identified but not yet fetched.
  - `DISCOVERED → INGESTED` — file fetched from the source, hashed (`hashFile` from Block 04 Phase 01), persisted to Raw Upload.
  - `INGESTED → EXTRACTED` — at least one extraction layer (Phase 04) has produced a result (success or partial).
  - `EXTRACTED → LINKED_CANDIDATE` — published to Block 10's matching engine as a candidate for one or more transactions.
  - `LINKED_CANDIDATE → MATCHED` — Block 10 has confirmed a match and produced a `match_records` row in `MATCHED_AUTO_HIGH_CONFIDENCE` or `MATCHED_CONFIRMED` state.
  - `LINKED_CANDIDATE → DISMISSED` — Block 10 found no match, or the user rejected the candidate, or the document is otherwise no longer relevant.
  - `MATCHED → DISMISSED` — rare; e.g., user later un-matches and rejects the document.
  - **`DISMISSED` is terminal.** A dismissed document does not transition back; if the same content is later re-discovered or re-uploaded, it produces a new candidate (per Phase 08's content-hash dedup, which would either collapse it onto the existing dismissed row or, if the dedup's source-priority logic decides differently, create a fresh document — see Phase 08's source-priority sub-doc).
- **Single chokepoint:** `transitionDocument(document_id, target_state, context) → DocumentState`. Direct UPDATEs to `documents.extraction_status` are forbidden in production code paths.
- **Audit coupling:** every successful transition emits `DOCUMENT_STATE_CHANGED` via Block 05's `emitAudit`, in the same transaction as the column write.
- **Manual upload entry point:** the `Document Stub` rows from Phase 07 (manual upload — no actual file) skip `INGESTED` and `EXTRACTED`, transitioning `null → DISCOVERED → DISMISSED` (with a structured reason) for the "no invoice available" / "internal transfer — no document needed" cases.
- **Re-entry semantics:** transitioning a document to a state it's already in is a no-op (idempotent re-entry, same as Block 03 Phase 06's pattern). The use case: a phase that retries after a crash safely re-runs the transition.
- **Transition validator** — illegal transitions (e.g., `DISCOVERED → MATCHED` skipping intermediate states) are rejected with a structured reason and emit `DOCUMENT_STATE_CHANGE_REJECTED`.
- **Audit events:** `DOCUMENT_STATE_CHANGED`, `DOCUMENT_STATE_CHANGE_REJECTED` (illegal transition), `DOCUMENT_STUB_CREATED` (the manual-stub bypass).

## Definition of Done

- The transition table is data, not scattered conditionals — printable for review.
- Every illegal transition is rejected with a structured reason and a `DOCUMENT_STATE_CHANGE_REJECTED` event.
- Idempotent re-entry returns the current state without re-emitting.
- Manual `Document Stub` flow correctly skips intermediate states.
- A direct UPDATE to `documents.extraction_status` from application code is blocked by the lint rule + database privilege grant (only the chokepoint function has `UPDATE` privilege through the application role).
- Tests cover every legal transition + a representative set of illegal ones + the manual-stub path.

## Sub-doc Hooks (Stage 4)

- **Transition table sub-doc** — the canonical printable table; the source of truth for reviews.
- **State-change emission sub-doc** — exact payload for `DOCUMENT_STATE_CHANGED`, ordering guarantees relative to schema writes.
- **Manual stub flow sub-doc** — exact reasons that justify a stub, audit-trail expectations, UX for "no invoice available".
- **Idempotency sub-doc** — what happens on re-entry; how it interacts with Block 03 Phase 07's resumability.
