# Block 04 — Phase 01: Hashing & ID Utilities

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Hashing Strategy section)
- Block doc: `Docs/blocks/05_security_and_audit.md` (hash-chain audit log)
- Block doc: `Docs/blocks/03_workflow_engine.md` (dedup keys reference these helpers)

## Phase Goal

A small, stable library of hashing and ID-generation primitives that every other phase consumes. After this phase, deterministic hashing of files, records, rows, and bundles is a single import away — and every subsequent phase can rely on the same canonical implementations.

## Dependencies

- None at the database level; runs as soon as the codebase scaffolding exists.

## Deliverables

- **SHA-256 helpers:**
  - `hashFile(buffer | stream) → string` — content hash for any uploaded or generated file (statements, invoices, evidence PDFs, archive bundles).
  - `hashRecord(record) → string` — content hash for a structured record (uses canonical JSON serialization).
  - `hashChainAppend(prevHash, eventPayload) → string` — used by Block 05's tamper-resistant audit log.
- **Domain-specific identifiers:**
  - `sourceRowHash(rawRow) → string` — SHA-256 over the raw bank-statement row content; consumed by Block 07's deduplication.
  - `transactionFingerprint(normalizedTransaction) → string` — softer signature (date + amount + currency + cleaned description); consumed by Block 07's `DUPLICATE_POSSIBLE` detection.
  - `archiveBundleHash(bundle) → string` — overall hash anchor for the sealed archive zip per Block 15.
- **Dedup-key default:**
  - `defaultDedupKey(toolName, input) → string` — fallback when a tool doesn't supply its own generator (Block 03 Phase 03's contract).
- **Canonical JSON serialization:**
  - `canonicalJSON(obj) → string` — sorted-keys, deterministic number formatting, deterministic array ordering (where order is semantic), used by every record-hashing helper.
- **UUID generation:**
  - UUID v7 (time-sortable) for primary keys across the operational schema. Helper `newUuid()` returning a v7 UUID.
- **Tests** with golden values for every helper — input → expected hash. Stability across releases is part of the contract; changing a helper's output is a breaking change.

## Definition of Done

- All helpers exported from a single library module.
- Test suite covers each helper with at least one golden-value test.
- The same input always produces the same hash within and across processes.
- UUID v7 outputs are sortable in insertion order.
- `canonicalJSON` produces identical strings for objects with the same content but different key insertion orders.
- Dedup-key fallback is wired into Block 03's tool-invocation path.

## Sub-doc Hooks (Stage 4)

- **Hashing algorithm choice sub-doc** — SHA-256 rationale; what changes if a future migration to BLAKE3 or similar is considered.
- **UUID generation sub-doc** — v7 vs v4 trade-offs, time-skew tolerance, monotonic guarantees.
- **Canonical JSON sub-doc** — key ordering, number precision, null/undefined handling, array semantics.
- **Hash chain pattern sub-doc** — exact `hashChainAppend` contract used by Block 05.
- **Domain identifier sub-doc** — `sourceRowHash`, `transactionFingerprint`, `archiveBundleHash` derivations and their semantic meanings.
