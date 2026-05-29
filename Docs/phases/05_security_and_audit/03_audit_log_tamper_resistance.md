# Block 05 — Phase 03: Audit Log Tamper Resistance

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Tamper Resistance section)
- Block doc: `Docs/blocks/04_data_architecture.md` (hash anchor written into archive manifests at finalization)
- Decisions log: `Docs/decisions_log.md` (hash-chained log + RFC 3161 third-party timestamping)

## Phase Goal

Make the audit log tamper-evident: each event hash-chains to the previous one, the chain head is periodically anchored to a third-party RFC 3161 timestamping service, and a verification job walks the chain on a schedule to catch retroactive rewrites. After this phase, an attacker who modifies a stored audit row breaks the chain, and the timestamps at the chain head prove the rewrite happened after a published moment in real-world time.

## Dependencies

- Phase 02 (audit log schema and `emitAudit()` API; this phase fills in the hash columns)
- Block 04 Phase 01 (`hashChainAppend` helper, canonical JSON serialization)

## Deliverables

- **Chain hashing in `emitAudit()`:**
  - On every emission, compute `event_hash = hashChainAppend(prev_event_hash, canonicalJSON(event_payload))`.
  - `prev_event_hash` reads from a `chain_heads` row in the same transaction; the new hash atomically replaces the head.
  - Done inside the same transaction that emits the event — atomic chain advance.
- **`chain_heads` table:**
  - One row per chain (default: one chain per `organization_id`; sub-doc may permit further partitioning).
  - Columns: `chain_id`, `latest_event_id`, `latest_event_hash`, `latest_event_at`, `chain_started_at`.
  - Updated via row-level locking inside the `emitAudit()` transaction.
- **RFC 3161 timestamping checkpoints:**
  - Periodic job (default: hourly) takes the current `chain_heads.latest_event_hash` and submits it to a third-party RFC 3161 timestamping authority (vendor TBD in sub-doc; EU-region or eIDAS-qualified service preferred).
  - Returns a signed timestamp token; stored in `chain_checkpoints`.
- **`chain_checkpoints` table:**
  - `id`, `chain_id`, `event_hash` (the chain head at checkpoint time), `event_id`, `timestamp_token` (binary), `tsa_provider`, `created_at`.
- **Chain integrity verification job:**
  - Scheduled (default: daily) — walks every chain end-to-end, recomputing hashes and comparing to stored values.
  - Cross-checks: every checkpoint's `event_hash` must match the actual `event_hash` of the event with the same `event_id`.
  - Verification failure raises a `CRITICAL` alert (Phase 10) and emits `CHAIN_VERIFICATION_FAILED` with the detected break point.
- **Restore-time verification:**
  - When backups are restored (Phase 08), the chain is re-verified before the restored data is considered authoritative.
- **Hash anchor for archive manifests:**
  - Block 04 Phase 08's archive manifest carries the chain head's hash at finalization time. This phase exposes a function `currentChainAnchor(business_id) → { event_hash, event_id, checkpointed_at? }` for the promotion pipeline to read.
- **Audit events for the system itself:** `CHAIN_VERIFIED`, `CHAIN_VERIFICATION_FAILED`, `CHAIN_CHECKPOINTED`, `CHAIN_CHECKPOINT_FAILED`, `CHAIN_RESTORED_AND_VERIFIED`.

## Definition of Done

- Every audit event written has a non-null `event_hash` that matches `hashChainAppend(prev_event_hash, canonicalJSON(payload))`.
- A test that modifies a stored audit row directly causes the verification job to fail at that exact event.
- A test that deletes a chain checkpoint and substitutes a forged one fails verification because the forged token doesn't match the chain head.
- RFC 3161 checkpoints are obtained and stored on the configured cadence.
- The verification job runs successfully on a clean log and reports zero discrepancies.
- `currentChainAnchor()` returns the expected anchor; Block 04 Phase 08's promotion pipeline can read and write it into the archive manifest.

## Sub-doc Hooks (Stage 4)

- **Chain partitioning sub-doc** — one chain per organization vs per business vs global; trade-offs and the chosen default.
- **`chain_heads` schema and locking sub-doc** — exact lock acquisition pattern inside `emitAudit()`, throughput characteristics under load.
- **RFC 3161 service sub-doc** — vendor selection, fallback if the primary is unavailable, EU-residency / eIDAS considerations.
- **Verification job sub-doc** — cadence, batching, failure escalation, false-positive handling.
- **Restore-time verification sub-doc** — exact pre-promotion check, what happens if a restored chain fails verification.
