# Block 15 — Finalization & Secure Archive

## Role in the System

Finalization is the single chokepoint for moving a workflow run from "in flight" to "locked". This block owns the gate, the lock, and the archive package construction. It is the irreversible step the entire pipeline points at: once a period is finalized, its transactions, evidence, matches, and ledger entries are immutable, the analytics layer is rebuilt, and reports become available.

Reaching Block 15 is the goal of every monthly run. Successfully exiting Block 15 is what turns a workflow run into accounting truth.

---

## Scope

### In scope
- Finalization preconditions check
- The lock sequence and its atomicity
- Archive package construction (what gets bundled, in what format)
- Immutability primitives at the schema and storage layer
- Re-finalization semantics for adjustment runs (additive archive entries)
- Approval recording (the explicit user act that triggers lock)
- Rollback policy during the brief lock-commit window

### Out of scope (covered elsewhere)
- The Finalized Archive zone's physical storage → Block 04
- The audit chain that records the finalization event → Block 05
- Generation of reports from finalized data → Block 16
- The workflow phase mechanics that lead to finalization → Block 03

---

## Finalization Preconditions

Before the engine can transition a run from `AWAITING_APPROVAL` to `FINALIZING`, every one of these must be true:

```text
- All transactions parsed, normalized, and dedup-resolved
- All transactions have a transaction_type (no UNKNOWN remaining)
- All required evidence is matched OR a documented exception exists
- All draft ledger entries are produced
- All VAT/tax classifications are complete OR flagged for accountant review (advisory in MVP)
- Zero BLOCKING review issues open
- An explicit user approval row is recorded for this run
- The audit log for this run has no unwritten events
```

Each precondition is a registered gate function (per Block 03's pattern). Block 15 calls them in order; the first failure halts the transition with a structured reason routed back to Block 14 as a re-opened issue.

---

## Approval Modality

Finalization requires an **explicit, recent, role-permitted approval**. In MVP:

- The approving user must hold a role with finalization rights (Owner or Admin per the Stage 1 decision; Accountant approval is not required in MVP).
- The approval is gated by a **step-up authentication** challenge using **the same TOTP or passkey factor used for login** (no dedicated finalization-only credential in MVP).
- The approval row records the user, the role, the run id, the timestamp, and the user's stated review summary (free text, optional but recommended).

The approval row itself is an audit event in Block 05's hash chain.

---

## The Lock Sequence

When all preconditions and approval are satisfied, Block 15 executes the lock as a single transactional sequence:

```text
1. Snapshot operational records (transactions, matches, draft ledger entries, review issues with resolutions)
2. Verify file hashes for every referenced evidence file
3. Write the archive package into Zone 4 (Finalized Secure Archive)
4. Promote draft ledger entries to locked Ledger Entries (separate schema)
5. Apply Storage Object Lock to the archive files
6. Mark the workflow run as FINALIZED with the archive package id
7. Emit a finalization audit event (timestamp, principal, run, archive id)
8. Enqueue the analytics rebuild job
```

If any step fails, the entire sequence is rolled back: no partial archive is written, no ledger entries are promoted, the run remains in `AWAITING_APPROVAL`. The engine **auto-retries the lock sequence once** to handle transient failures (storage hiccups, network blips). If the retry also fails, a HIGH-severity review issue is raised describing the failure and requiring user intervention before another attempt.

There is no user-initiated rollback after step 8 completes successfully. Corrections happen via adjustment runs.

---

## Archive Package

The archive package is the canonical, complete, self-contained record of one finalized period for one business. It is constructed at lock time and stored in Zone 4 as **a single sealed zip bundle** under Storage Object Lock. The zip is the immutable object — verifying integrity is one hash comparison.

Bundle contents:

```text
- manifest.json                  — version, business id, period bounds, run id, approval id, hash chain anchor, internal file hashes
- transactions.json              — one row per transaction with full structured shape
- matches.json
- ledger_entries.json            — locked-entry shape
- review_issues.json             — issues with their resolutions
- evidence_index.json            — hash + storage path per evidence file
- evidence/                      — directory of original evidence files (referenced by hash)
- vat_summary.json
- vies_export.<format>           — full VIES file to current specification (Stage 1 decision)
- finalization_summary.json      — derived from approval + run state
- period_report.pdf              — generated, paginated, period summary (distinct from the on-demand accountant export pack produced by Block 16)
```

Every internal file is hashed and the manifest enumerates every file hash plus the bundle's overall hash anchor. Verifying an archive package later is one operation: re-hash the bundle and compare to the recorded anchor.

**Manifest versioning:** when an adjustment run amends a finalized period, the new manifest is written as `manifest_v2.json` (then `_v3`, etc.) inside the same archive object family. **All prior manifest versions are preserved** under Object Lock; nothing is overwritten. A reader can reconstruct the period's complete history by walking manifests in version order.

---

## Immutability

Three layers protect the locked archive:

1. **Schema-level.** Locked ledger entries live in a separate Postgres schema (per Block 04) whose RLS policies forbid UPDATE and DELETE through any application role. INSERT is permitted only for adjustment runs producing additive records.
2. **Storage-level.** Archive files use Storage Object Lock — the storage layer itself refuses to overwrite or delete locked objects until retention expires.
3. **Audit-level.** Every read against archive data is logged (Block 05). Tampering is detectable via the hash chain checkpoints.

Together, these mean a locked period cannot be silently changed even by a privileged operator with database access. A change would require coordinated bypass of all three layers, which is exactly what the audit log exists to detect.

---

## Re-Finalization (Adjustment Runs)

Adjustment runs (`OUT_ADJUSTMENT`, `IN_ADJUSTMENT`) end with a re-finalization step that **adds** records to the existing archive package — never modifies it. The package gains:

- New adjustment records (with explicit reason + structured delta against original entries)
- A new approval row for the adjustment
- An updated manifest (which itself becomes a new versioned entry; the original manifest is preserved)

The result is an archive package whose history is fully reconstructable: an auditor can see the original lock, every adjustment that followed, and what each adjustment changed.

The 6-year amendment cap from Block 12 applies: adjustment runs cannot target periods outside the legal retention window.

---

## Interfaces

### Inputs
- A finalization request from the engine (Block 03), carrying the workflow run id and approval row
- Operational records, draft ledger entries, evidence file references
- Permission decisions from Block 05 (step-up authentication outcome)

### Outputs
- An archive package in Zone 4
- Locked ledger entries in the archive schema
- A finalization audit event in Block 05's hash chain
- An analytics rebuild job for Block 04 / Block 16
- A finalization-complete signal back to Block 03

---

## Operating Rules

- **Principle 1 (Workflow-First):** Block 15 is the only path to `FINALIZED`. There is no direct UI button that skips preconditions.
- **Principle 2 (Structured Data is Truth):** the archive's structured records are canonical; the human-readable PDF is generated from them.
- **Principle 3 (AI Assists, Rules Decide):** AI plays no role in the lock sequence. Preconditions are deterministic; approval is human; lock is a transactional state change.
- **Principle 4 (Security by Design):** approval requires step-up auth; immutability is enforced at three independent layers.
- **Stage 1 decisions applied:** Owner/Admin approval suffices in MVP; accountant approval is advisory; Storage Object Lock for archive files; hash-chained audit log + RFC 3161 timestamping; adjustments interleaved with explicit reason + delta.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Archive package format:** single sealed zip bundle with embedded manifest — covered in Archive Package.
- **Manifest versioning:** increment version, preserve all prior manifests — covered in Archive Package.
- **Step-up auth for approval:** same TOTP/passkey factor as login — covered in Approval Modality.
- **Lock-sequence failure recovery:** auto-retry once, then user intervention — covered in The Lock Sequence.
- **Analytics rebuild:** eventual-consistency background job (per Stage 1 foundation decision); finalization does not block on analytics rebuild.

### Deferred

- **Read-after-finalization caching strategy** — the archive is queryable directly; whether to introduce a read cache for high-traffic scenarios is deferred to phase docs based on observed performance.
