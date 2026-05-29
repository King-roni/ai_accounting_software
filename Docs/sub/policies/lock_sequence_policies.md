# Lock Sequence Policies

**Category:** Policies · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Rules and invariants governing the Block 15 finalization lock sequence — the 5-step atomic procedure that transitions a workflow run from `AWAITING_APPROVAL` to `FINALIZED` and writes the immutable archive bundle. The lock sequence is the highest-consequence write surface in the system; every invariant here is binding and enforced at code review and runtime.

---

## 1. Pre-conditions for starting the lock sequence

The lock sequence begins only when all of the following are true:

1. **Run state is `AWAITING_APPROVAL`** — the run must be in exactly this state from the 10-value canonical state set (`CREATED · RUNNING · PAUSED · REVIEW_HOLD · AWAITING_APPROVAL · FINALIZING · FINALIZED · FAILED · CANCELLED · COMPENSATING`). Any other state causes the sequence-start call to return an immediate error.
2. **Valid approval row exists** — `workflow_run_approvals` contains at least one non-revoked row for the run with `approval_method = STEP_UP` and `data_state_hash` matching the run's current state. If the approval row is stale (see `archive_step_up_policy`), the sequence does not start.
3. **All 8 finalization gates pass** — `engine.gate_finalization_preconditions_satisfied` must return `ADVANCE` for all 8 gates defined in `finalization_gate_sql_schema`. The gate composite is evaluated immediately before the sequence-start transition; if any gate returns `HOLD`, the sequence is aborted without state transition.
4. **No concurrent lock sequence in progress** — only one lock sequence per `workflow_run_id` may be active at a time. A `FINALIZING` state on the run row is the mutex; attempting to start a second sequence while the run is already `FINALIZING` is rejected.

---

## 2. The 5 lock sequence steps

The lock sequence has exactly 5 steps in the following order. No step may be skipped or reordered.

### Step 1 — Ledger snapshot freeze

**Tool:** `archive.lock_period` (Block 15 Phase 04)
**Side-effect class:** `WRITES_ARCHIVE | WRITES_AUDIT`
**Action:** Write all `draft_ledger_entries` for the run to `archive.locked_ledger_entries`. Set the `app.original_lock_active` session variable to `'true'` for the duration of the INSERT transaction. After the INSERT completes, reset the session variable.
**Audit event:** `FINALIZATION_LEDGER_BULK_LOCKED` (one aggregate event, not per-row).
**Idempotency:** if `archive.locked_ledger_entries` already has rows for `archive_package_id` at `manifest_version_number = 1`, the step is a no-op. Safe to retry.

### Step 2 — Archive bundle creation

**Tool:** `archive.build_bundle` (Block 15 Phase 04)
**Side-effect class:** `WRITES_ARCHIVE | WRITES_AUDIT`
**Action:** Assemble the archive bundle ZIP per the file manifest in `archive_bundle_file_manifest`. Write the ZIP to a staging location. Compute SHA-256 of each file; populate the `files` array in `manifest.json`.
**Audit event:** `ARCHIVE_PACKAGE_BUILT`.
**Idempotency:** if an `archive_packages` row already exists for the run at the current `manifest_version_number`, the step checks whether the existing bundle hash matches. If it matches, the step is a no-op. If it does not match, a compensation error is raised (unexpected divergence).

### Step 3 — Object Lock application

**Tool:** `archive.apply_object_lock` (Block 15 Phase 04)
**Side-effect class:** `WRITES_ARCHIVE | WRITES_AUDIT | EXTERNAL_CALL`
**Action:** Upload the staging ZIP to the `archive-bundles` S3-compatible bucket with Object Lock mode `COMPLIANCE` and retention period matching the Cyprus 6-year regulatory window. Record the storage object key and ETag on the `archive_packages` row.
**Audit event:** `OBJECT_LOCK_RETENTION_SET`.
**Idempotency:** if the object already exists at the target key with Object Lock applied, the step verifies the ETag and is a no-op. Safe to retry.

### Step 4 — RFC 3161 timestamp

**Tool:** `archive.request_timestamp` (Block 15 Phase 04)
**Side-effect class:** `WRITES_ARCHIVE | WRITES_AUDIT | EXTERNAL_CALL`
**Action:** Call the external RFC 3161 Timestamp Authority (TSA) with the `bundle_hash` from Step 3. Record the TSA token and `tsa_token_hash` on the `archive_packages` row.
**Audit event:** `TIMESTAMP_RECORDED` (on success); `TIMESTAMP_AUTHORITY_UNREACHABLE` (on TSA unavailability — the step retries once after 10 seconds before proceeding; RFC 3161 failure is non-fatal to the sequence per the `audit_log_policies` anchoring policy, but is flagged in the manifest).
**Idempotency:** if `tsa_token_hash` is already populated on the `archive_packages` row, the step is a no-op. Safe to retry.

### Step 5 — Manifest promotion

**Tool:** `archive.promote_manifest` (Block 15 Phase 04)
**Side-effect class:** `WRITES_ARCHIVE | WRITES_AUDIT`
**Action:** Set `is_current = true` on the `archive_manifests` row for this `archive_package_id` and `manifest_version_number`. Set the workflow run state to `FINALIZED`. Emit `ARCHIVE_PROMOTION_COMPLETED`.
**Audit event:** `ARCHIVE_PROMOTION_COMPLETED`.
**Idempotency:** if `is_current = true` is already set and the run is already `FINALIZED`, the step is a no-op. Safe to retry.

---

## 3. Atomicity and compensation

### Atomicity guarantee

The sequence is executed as a durable, step-checkpointed workflow via Block 03 Phase 07's resumability framework. Each step's completion is checkpointed before the next step begins. The sequence is atomic from the perspective of external observers: the run is either in `AWAITING_APPROVAL` (sequence not yet complete) or `FINALIZED` (sequence complete). The intermediate `FINALIZING` state is only visible during execution.

### Failure and compensation

If any step fails and is not recoverable by idempotent retry:

1. The run transitions to `COMPENSATING`.
2. The compensating rollback runs in reverse step order, undoing writes where possible:
   - Step 5 compensation: revert `is_current` flag; revert run state to `AWAITING_APPROVAL`.
   - Step 4 compensation: RFC 3161 tokens cannot be revoked; the `tsa_token_hash` is cleared from `archive_packages`; the token itself is abandoned.
   - Step 3 compensation: the Object Lock object cannot be deleted (by design — it is immutable). The `archive_packages` row is marked `COMPENSATION_ORPHAN`; operators are alerted.
   - Step 2 compensation: the staging ZIP is deleted from the staging location.
   - Step 1 compensation: `archive.locked_ledger_entries` rows for `manifest_version_number = 1` are deleted (permitted only during compensation via the `app.compensation_active` session variable, which enables a narrow DELETE policy on the `archive` schema).
3. After compensation completes, the run transitions to `FAILED`.
4. **Auto-retry-once:** if the failure occurred in Steps 1 or 2 (before Object Lock was applied), the engine performs one automatic retry of the full sequence before invoking compensation. This handles transient DB errors. The retry is bounded to one attempt; a second failure triggers compensation unconditionally.

**Compensation audit events:** `FINALIZATION_ROLLED_BACK` (when compensation completes successfully) and `FINALIZATION_FAILED` (when the run transitions to `FAILED`). Both already exist in the `FINALIZATION` domain of `audit_event_taxonomy`.

---

## 4. Time budget and circuit breaker

The entire 5-step sequence must complete within **10 minutes** from sequence start. A circuit breaker in Block 03 Phase 07 monitors the elapsed time from the `FINALIZING` state entry timestamp. If 10 minutes elapse without the run transitioning to `FINALIZED`:

1. The circuit breaker emits `FINALIZATION_FAILED` with `reason = CIRCUIT_BREAKER_TRIPPED`.
2. The compensating rollback is initiated.
3. The run transitions `FINALIZING → COMPENSATING → FAILED`.

The 10-minute budget is generous for the typical period size (< 2,000 transactions). It exists to bound worst-case external API latency (TSA in Step 4) and very large evidence packs (Step 2).

---

## 5. Side-effect class restriction

Only Block 15 tools may carry the `WRITES_ARCHIVE` side-effect class. Code review blocks any tool outside Block 15 from registering with this class, per `tool_naming_convention_policy`. The `WRITES_ARCHIVE` class is also checked at runtime by the tool registry; an attempt to execute a `WRITES_ARCHIVE` tool from outside the lock sequence context raises a fatal registry error.

---

## 6. Step-up authentication requirement

Before the approval row that enables the lock sequence can be written, the approving user must complete step-up MFA authentication on the `WORKFLOW_APPROVE` surface. The full step-up flow, token validity window (5 minutes), and approval-method matrix are defined in `archive_step_up_policy`. The lock sequence's Step 1 verifies that the `workflow_run_approvals` row's `data_state_hash` still matches the run's current state at sequence-start time; a stale approval causes an immediate sequence abort (not compensation) with the run reverting to `AWAITING_APPROVAL`.

---

## 7. Mobile rejection

`archive.lock_period` and all lock-sequence tools are listed in `mobile_write_rejection_endpoints`. Mobile clients cannot initiate, retry, or interact with the lock sequence. The step-up authentication challenge UI is not presented on mobile. Read access to finalized archive data — viewing locked ledger entries, downloading archive packages — is available on mobile.

---

## 8. Audit events

| Event | Severity | When |
|---|---|---|
| `FINALIZATION_LOCK_STARTED` | — | Run transitions to `FINALIZING`; sequence begins |
| `FINALIZATION_LEDGER_BULK_LOCKED` | — | Step 1 completes |
| `ARCHIVE_PACKAGE_BUILT` | — | Step 2 completes |
| `OBJECT_LOCK_RETENTION_SET` | — | Step 3 completes |
| `TIMESTAMP_RECORDED` | — | Step 4 completes (TSA success) |
| `TIMESTAMP_AUTHORITY_UNREACHABLE` | — | Step 4 TSA call fails; sequence continues |
| `ARCHIVE_PROMOTION_COMPLETED` | — | Step 5 completes; run is now `FINALIZED` |
| `FINALIZATION_LOCK_COMMITTED` | — | Alias event emitted after Step 5 for downstream subscriber compatibility |
| `FINALIZATION_ROLLED_BACK` | — | Compensation completes |
| `FINALIZATION_FAILED` | — | Run transitions to `FAILED` after compensation |

All events exist in the `FINALIZATION` and `ARCHIVE` domains of `audit_event_taxonomy`.

---

## Cross-references

- `data_layer_conventions_policy` — SHA-256 bundle hash; UUID v7 IDs; canonical JSON for manifests
- `archive_step_up_policy` — step-up authentication requirement; token validity; approval-method matrix
- `finalization_gate_sql_schema` — the 8 precondition gates that must pass before sequence start
- `locked_ledger_entries_schema` — target of Step 1; RLS session-variable write gate
- `archive_bundle_file_manifest` — file composition for Step 2 bundle assembly
- `archive_manifest_schemas` — `archive_packages` and `archive_manifests` tables
- `tool_naming_convention_policy` — `WRITES_ARCHIVE` side-effect class; Block 15 namespace restriction
- `mobile_write_rejection_endpoints` — lock sequence tools listed as mobile-rejected
- `audit_log_policies` — event naming; anchoring policy for RFC 3161 TSA
- `audit_event_taxonomy` — `FINALIZATION` and `ARCHIVE` domain events
- Block 15 Phase 02 — preconditions architecture
- Block 15 Phase 03 — approval modality architecture
- Block 15 Phase 04 — `archive.lock_period` and related tools; lock sequence implementation
- Block 03 Phase 07 — resumability framework; step checkpointing; circuit breaker
- Block 04 Phase 07 — Finalized Archive zone; Object Lock bucket configuration
