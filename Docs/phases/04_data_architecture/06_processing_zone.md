# Block 04 — Phase 06: Processing Zone

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Zone 2 — Processing)
- Block doc: `Docs/blocks/06_ai_layer.md` (AI payloads stored here in redacted form)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 4 — data minimization sub-rule)

## Phase Goal

Stand up the Processing zone — a short-lived staging area for OCR text, extracted-field candidates, AI payloads, and other intermediate artefacts produced during a workflow run. After this phase, every block that produces a temporary artefact has a clean, audited place to put it, and the lifecycle (TTL + prune-on-completion) keeps the zone from accumulating long-tail data that doesn't belong in operational or archive zones.

## Dependencies

- Phase 01 (hashing — artefact integrity)
- Phase 02–04 (operational tables — artefacts reference operational entities)
- Phase 05 (Raw Upload — large source files OCR'd into Processing artefacts)
- Block 03 Phase 01 (`workflow_runs` — artefacts scoped to runs)

## Deliverables

- **`processing_artifacts` table** in the operational schema:
  - `id` (UUID v7), `organization_id`, `business_id`, `workflow_run_id`
  - `artifact_type` (`OCR_TEXT`, `EXTRACTED_FIELDS_DRAFT`, `AI_PAYLOAD_REDACTED`, `AI_RESPONSE`, `MATCH_CANDIDATE_BUNDLE`)
  - `source_reference_type`, `source_reference_id` (polymorphic reference to the entity this artefact derives from — a transaction, a document, a match record). Integrity is enforced via a CHECK constraint on the `(source_reference_type, source_reference_id)` pair plus a write-time validator; this is **not** a Postgres-native FK.
  - `payload_inline` (JSONB, nullable; for small artefacts)
  - `payload_storage_path` (nullable; for large artefacts in the `processing-zone` Storage bucket)
  - `payload_hash` (Phase 01)
  - `expires_at` (governs the prune job)
  - `created_at`
- **Supabase Storage bucket** `processing-zone` for large artefacts:
  - Private, EU region.
  - Same tenancy folder convention as Raw Upload.
  - Storage RLS scoped by `(organization_id, business_id)`.
- **TTL semantics:**
  - **On run completion (`FINALIZED`):** artefacts scheduled for prune 24 hours later (short window for diagnostic purposes).
  - **On run failure or abort:** artefacts retained 30 days for post-mortem, then pruned.
  - **Default for runs in progress longer than 90 days:** soft alert, no auto-prune (a long-running run probably needs a person to look at it).
- **Prune background job** — scheduled (per Stage 1, this is an internal background job, not a workflow trigger) to delete artefacts whose `expires_at` has passed; deletes both the DB row and the Storage object.
- **Data minimization at write time** — artefacts that originate from AI calls store the **redacted** payload (post-Privacy Gateway, per Block 06), never the raw input. The Privacy Gateway is the single chokepoint that produces the redacted form.
- **Audit events:** `PROCESSING_ARTIFACT_CREATED`, `PROCESSING_ARTIFACT_PRUNED`, `PROCESSING_ARTIFACT_PRUNE_SKIPPED` (with reason: legal hold, run still active, etc.).

## Definition of Done

- The table and bucket exist and are tenant-scoped via the standard RLS template.
- A typical OCR pipeline (Block 09 calls) produces an `OCR_TEXT` artefact and references it from the `documents.ocr_text_reference` column.
- An AI call (Block 06 Tier 3) produces an `AI_PAYLOAD_REDACTED` and `AI_RESPONSE` pair, the payload is the redacted form (validated by absence of any IBAN-shaped string in the stored payload).
- The prune job removes expired artefacts from both DB and Storage.
- A run under legal hold (Phase 11) does not have its artefacts pruned even past `expires_at`.

## Sub-doc Hooks (Stage 4)

- **Processing artefact taxonomy sub-doc** — exact `artifact_type` values, what each represents, who produces it.
- **TTL & prune policy sub-doc** — windows per artefact type, override mechanism, interaction with legal hold.
- **Redaction-at-write pattern sub-doc** — how the Privacy Gateway is the only writer of `AI_PAYLOAD_REDACTED`.
- **Inline-vs-storage decision sub-doc** — when to embed in `payload_inline` vs offload to Storage; size thresholds.
