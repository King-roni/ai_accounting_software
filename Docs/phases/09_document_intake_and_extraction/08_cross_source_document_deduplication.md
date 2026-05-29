# Block 09 — Phase 08: Cross-Source Document Deduplication

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Document Lifecycle — `documents.document_hash` and source-link tracking)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 03 — `documents.document_hash` column already exists)

## Phase Goal

Detect when the same document arrives via multiple paths — typically the same invoice landing in both Gmail and Drive, or the user manually uploading a file the email finder also picked up. After this phase, content-identical discoveries collapse into one `Document` row with multiple `document_source_links`, and the cross-source corroboration boosts the document's `discovery_confidence` so Block 10's matching engine has a stronger signal.

## Dependencies

- Phase 01 (`document_source_links` table)
- Phase 02 (state machine — content-dedup checks happen at `DISCOVERED → INGESTED` boundary)
- Phase 05 (email finder produces candidates)
- Phase 06 (Drive finder produces candidates)
- Phase 07 (manual upload produces candidates)
- Block 04 Phase 01 (`hashFile` for content hashing)
- Block 04 Phase 03 (`documents.document_hash` column)

## Deliverables

- **Cross-source dedup check** at the `DISCOVERED → INGESTED` boundary:
  1. After a finder fetches a candidate file, compute its content hash via `hashFile`.
  2. Query `documents WHERE business_id = ? AND document_hash = ?`.
  3. If a matching row exists:
     - **Do not create a new `Document`.**
     - Add a `document_source_links` row recording the new source (`source_kind` + `source_external_id`).
     - Update the existing document's `discovery_confidence` with the cross-source boost (see below).
     - Emit `DOCUMENT_CROSS_SOURCE_DUPLICATE_DETECTED` with both source kinds.
     - Skip OCR and extraction — they've already run on this content.
  4. If no match: proceed with the normal create flow (the document is genuinely new).
- **Cross-source confidence boost:**
  - When the same content hash is discovered via two independent sources, the merged `discovery_confidence` becomes `min(0.95, max_source_confidence + 0.10)`.
  - Three or more sources don't add further boost (cap is reached at two; third source is logged but doesn't move the number).
  - The boost reflects strong corroboration — the same invoice in both email and Drive is much less likely to be a wrong candidate than one source alone.
- **Source priority for the document's `source` column:**
  - The `documents.source` column reflects the **first** source that discovered the document (via the order finders run in: EMAIL first, then DRIVE, then MANUAL).
  - This preserves provenance — the audit trail can show which source initially led the system to the document, while `document_source_links` records every subsequent sighting.
- **Per-business idempotency:**
  - Cross-source dedup is scoped to `(business_id, document_hash)` — the same hash across two different businesses is two distinct documents (correctly, since the businesses are isolated).
- **Index strategy:**
  - The dedup check relies on the `(business_id, document_hash)` index from Block 04 Phase 03 / Phase 03 of this block. Performance is `O(1)` per check.
- **Audit events:** `DOCUMENT_CROSS_SOURCE_DUPLICATE_DETECTED` (info-level — strong signal, not an issue), `DOCUMENT_CONFIDENCE_BOOSTED_VIA_CROSS_SOURCE`, `DOCUMENT_THIRD_SOURCE_OBSERVED` (info-level for the cap-reached case).

## Definition of Done

- The same content uploaded via email finder and then Drive finder produces exactly one `Document` row with two `document_source_links`.
- The merged `discovery_confidence` reflects the boost (capped at 0.95).
- The document's `source` column shows the first finder's source, not the most recent one.
- A third source for the same hash is recorded in `document_source_links` but doesn't further boost confidence.
- Cross-business hash collisions are not treated as duplicates (verified via test).
- The dedup check completes in negligible time at expected production scale.
- Tests cover: email-then-Drive, Drive-then-email, email-then-manual, three-source case, cross-business collision (correctly NOT collapsed).

## Sub-doc Hooks (Stage 4)

- **Cross-source boost calibration sub-doc** — exact value, when to revisit, A/B testing approach.
- **Source priority sub-doc** — order of source resolution, what happens if the first finder later marks the source DISMISSED.
- **Index strategy sub-doc** — query plans, partial indexes if needed at scale.
- **Multi-business hash collision sub-doc** — security implication: a malicious user can't probe other businesses' documents by computing hashes (RLS prevents the lookup); confirm.
