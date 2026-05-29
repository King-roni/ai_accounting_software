# Block 15 — Phase 09: Failure Handling & Rollback Semantics

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (The Lock Sequence — failure handling; auto-retry once)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 07 — resumability; Phase 08 — failure policy)
- Block doc: `Docs/blocks/14_review_queue.md` (HIGH severity issue contract)
- Decisions log: `Docs/decisions_log.md` (lock-sequence failure recovery: auto-retry once, then user intervention)

## Phase Goal

Pin the canonical failure-handling and rollback contract for Phase 04's lock sequence and Phase 08's adjustment-finalization sequence: pre-step-8 atomicity, storage-layer rollback compensation, auto-retry-once with bounded backoff, HIGH review issue templates per failure category, post-step-8 immutability, and resumability after engine restart mid-sequence. After this phase, every failure mode has a deterministic recovery path.

## Dependencies

- Phase 04 (lock sequence — owns the per-step failure semantics)
- Phase 06 (adjustment lock — symmetric failure handling)
- Phase 07 (Object Lock — failure paths for steps 5)
- Block 03 Phase 07 (resumability framework)
- Block 03 Phase 08 (failure policy — bounded retry primitives)
- Block 04 Phase 07 (Finalized Secure Archive zone — storage compensation API)
- Block 05 Phase 02 (audit-log emergency-write path)
- Block 14 Phase 02 (review-issue producer — HIGH severity templates)

## Deliverables

- **Failure-mode taxonomy** (canonical; sub-doc owns per-mode runbooks):

  | Failure mode | Step | Class | Auto-retry? | Outcome on persistent failure |
  | --- | --- | --- | --- | --- |
  | Snapshot read fails (DB connection blip) | 1 | TRANSIENT | yes | HIGH issue: `finalization.snapshot_failed` |
  | Evidence file hash mismatch | 2 | DETERMINISTIC | no | BLOCKING issue: `finalization.evidence_hash_mismatch` (the file is corrupt; no retry will fix) |
  | Evidence file missing in storage | 2 | DETERMINISTIC | no | BLOCKING issue: `finalization.evidence_missing` |
  | Bundle write to storage fails (transient) | 3 | TRANSIENT | yes | HIGH issue: `finalization.bundle_write_failed` |
  | Bundle write fails (permanent — quota, permissions) | 3 | DETERMINISTIC | no | BLOCKING issue: `finalization.bundle_write_permanent` |
  | Period report PDF generation fails | 3 (sub-step) | TRANSIENT | yes | HIGH issue: `finalization.period_report_failed` |
  | VIES export generation fails | 3 (sub-step) | TRANSIENT | yes | HIGH issue: `finalization.vies_export_failed` |
  | `locked_ledger_entries` INSERT fails (RLS rejection — should not happen) | 4 | DETERMINISTIC | no | BLOCKING issue: `finalization.ledger_promotion_rls_rejected` |
  | Object Lock API failure (transient — service blip) | 5 | TRANSIENT | yes | HIGH issue: `finalization.object_lock_failed` |
  | Object Lock API failure (permanent — config error) | 5 | DETERMINISTIC | no | BLOCKING issue: `finalization.object_lock_misconfigured` |
  | State transition fails (concurrency conflict) | 6 | TRANSIENT | yes | HIGH issue: `finalization.state_transition_conflict` |
  | Audit-log write fails | 7 | TRANSIENT | yes | BLOCKING issue: `finalization.audit_write_failed` (audit integrity is non-negotiable; persistent failure halts any further finalization globally) |
  | Analytics enqueue fails | 8 | TRANSIENT | no (post-commit) | HIGH issue: `finalization.analytics_enqueue_failed` (the lock IS committed; the issue is informational; analytics catches up via reconciliation) |
  | Manifest-version collision (concurrent adjustment runs against same parent) | 4 | TRANSIENT | yes | Auto-retry re-reads `MAX(manifest_version_number)` and increments; if persistent, HIGH issue `finalization.manifest_version_collision` (rare — implies a deeper concurrency problem) |

- **Pre-step-8 atomicity contract:**
  - Steps 1–7 run inside a single Postgres transaction.
  - Postgres-transactional failures (DB constraint violation, connection drop) automatically roll back the transaction; no `archive_packages` / `archive_manifests` / `archive_files` / `locked_ledger_entries` rows persist.
  - **Storage-layer side effects** (steps 3 and 5) are NOT Postgres-transactional. Compensation:
    - **Step 3 (bundle write) compensation:** if step 3 wrote a bundle but step 4 / 5 / 6 / 7 fails, the lock-sequence rollback path issues a delete API call against the storage zone for the bundle file. The compensation runs BEFORE the Postgres transaction rolls back, so on restart there's no orphan bundle.
    - **Step 5 (Object Lock) compensation:** Object Lock on a freshly-written bundle that's about to be deleted is a contradiction; in practice, step 5 is the LAST storage-side effect before the Postgres commit, so compensation just means deleting the bundle (Object Lock applied to a now-deleted file is harmless).
  - **Step 7 (audit emission) is a SEPARATE short transaction** per Phase 04's pinned atomicity decision — append-only hash-chain writes work best as their own transactions to avoid chain-head contention. The lock sequence's true commit point is the end of step 7, not step 6. A crash-window between step 6's commit and step 7's audit write is handled by Block 03 Phase 07's resumability + a recovery emission `FINALIZATION_LOCK_AUDIT_RECOVERED` (sub-doc owns).
- **Auto-retry-once mechanism:**
  - Per Stage 1, each TRANSIENT failure triggers exactly one auto-retry with a 5-second backoff (sub-doc tunes; jitter `±2s`).
  - **Per-step retry vs whole-sequence retry:**
    - **Whole-sequence retry** (Stage 1 default): on any transient failure during steps 1–6, the entire sequence rolls back, then re-runs from step 1. Steps that already succeeded re-run idempotently (snapshot is re-read; the second-pass content is identical for a deterministic period; bundle is re-constructed and re-written if step 3 failed; Object Lock re-attempted if step 5 failed).
    - **Per-step retry** is rejected for Stage 1 — too risky (mid-sequence state is hard to make consistent across step boundaries).
  - **Persistent failure** (the second attempt also fails): the run remains in `AWAITING_APPROVAL`; the relevant HIGH or BLOCKING review issue is raised; no further auto-retry until the user intervenes.
- **Resumability after engine restart:**
  - Block 03 Phase 07's resumability framework detects runs in `FINALIZING` state at engine startup. For each:
    - If the Postgres transaction was committed (state = `FINALIZED` confirmed in DB), no action — the run is finalized; only step 8 may be missing. The resumability layer fires the analytics-enqueue reconciliation.
    - If the Postgres transaction was not committed (state = `FINALIZING` still), the resumability layer re-invokes `finalization.execute_lock_sequence` from step 1.
  - **Storage-layer orphan detection:** on restart, a sweeper queries the storage zone for any bundle files that don't have a corresponding `archive_packages` row; orphan files are logged (`STORAGE_ORPHAN_DETECTED`) and queued for cleanup. Stage 1 cleanup is manual (Owner-level review); sub-doc tracks the automated-cleanup option for Stage 2+.
- **HIGH-issue and BLOCKING-issue templates:**
  - Each entry in the failure-mode taxonomy maps to a `review_issues` row registered via Block 14 Phase 02's `registerIssueType`.
  - Issue type strings follow the canonical convention `finalization.<failure_mode>` per Block 14 Phase 02's H4 fix.
  - **HIGH** issues block the next finalization attempt for the same run until resolved; user resolution paths typically include `Re-run scan after change`, `Send to accountant review`, or (for evidence-related) `Upload document` to remediate.
  - **BLOCKING** issues require explicit Owner / Admin investigation; some (e.g., `finalization.audit_write_failed`) are infrastructure-level and may require operator intervention.
- **Audit-log failure handling at step 7** (Stage 1 — no emergency hash-chain bypass; Block 05's chain integrity is non-negotiable):
  - The lock sequence's step 7 audit write uses the standard Block 05 Phase 02 API. Failure cases:
    - **Hash-chain mismatch (chain head moved between read and write):** Block 05 Phase 02's API automatically retries with the new head. The mismatch resolves transparently within a few attempts.
    - **Audit log table unavailable** (infrastructure failure): step 7 fails. Per Phase 04's atomicity contract, this is a critical state — the operational DB has committed steps 1-6 but the audit chain has no record. The run is in `FINALIZED` state but unaudited. **No emergency-audit-bypass mechanism exists in Stage 1** — Block 05's hash-chain integrity is non-negotiable; bypassing it would create the very tampering vulnerability Layer 3 detects.
    - **Recovery path:** Block 03 Phase 07's resumability detects the unaudited-finalized run on next health check and re-attempts the audit write. Block 05 Phase 02's API is idempotent on the same `(run_id, event_type)` key so retries don't double-count.
    - **Persistent audit-system failure** (the audit system stays down): ALL finalizations halt globally — Block 03 Phase 09's scheduler suspends new run starts, in-flight runs that reach `FINALIZING` cannot pass step 7. The operator is alerted via Block 05 Phase 10's security-alerting. No bypass is offered. This is the correct behavior — finalization without audit integrity is worse than delayed finalization.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_FAILURE_DETECTED` (per failure; payload = step number, failure-mode classification, transient/deterministic flag)
  - `FINALIZATION_AUTO_RETRY_FIRED` (per retry; payload = attempt-2 indicator)
  - `FINALIZATION_PERSISTENT_FAILURE_HIGH` (after retry exhaustion; HIGH issue raised)
  - `FINALIZATION_PERSISTENT_FAILURE_BLOCKING` (after retry exhaustion; BLOCKING issue raised)
  - `FINALIZATION_STORAGE_COMPENSATION_RAN` (per bundle-cleanup compensation)
  - `FINALIZATION_RESUMED_AFTER_RESTART` (per Block 03 Phase 07 resumability invocation)
  - `FINALIZATION_LOCK_AUDIT_RECOVERED` (per recovery emission for crash-window between step 6 commit and step 7 write)
  - `STORAGE_ORPHAN_DETECTED` (per orphan bundle file)

## Definition of Done

- A simulated transient failure at step 5 triggers auto-retry; the second attempt succeeds; the run finalizes.
- A simulated persistent failure at step 5 triggers two attempts; both fail; HIGH issue raised; bundle file cleaned up via compensation; the run remains `AWAITING_APPROVAL`.
- A simulated evidence-hash-mismatch at step 2 immediately raises BLOCKING (no auto-retry — the failure is deterministic).
- A simulated engine restart mid-sequence (between step 4 and step 5) is detected by the resumability layer; the sequence re-runs from step 1; no orphans.
- A simulated step-8 failure (analytics enqueue) does NOT roll back the lock; the run is `FINALIZED`; HIGH issue surfaces.
- A simulated audit-write failure rolls back the lock; the emergency audit path records the failure.
- Each failure mode produces the right `issue_type` string and severity per the taxonomy table.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Per-failure-mode runbook sub-doc** — operator instructions per HIGH/BLOCKING issue.
- **Storage-compensation timing sub-doc** — exact ordering of API calls during rollback.
- **Backoff jitter sub-doc** — exact ms values; per-step variation.
- **Per-step vs whole-sequence retry trade-off sub-doc** — Stage 2+ exploration.
- **Storage-orphan automated-cleanup sub-doc (Stage 2+)** — sweeper schedule; safety checks.
- **Audit emergency-path sub-doc** — exact mechanism; recovery from persistent audit failure.
- **Lock-sequence performance budget sub-doc** — failure-mode-specific timing.
