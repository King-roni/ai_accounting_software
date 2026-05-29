# Retention Deletion Atomicity Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

Binding rules for the atomicity of the per-business retention deletion: the exact transaction shape, ordering of Storage delete vs DB delete, inconsistency-detection logic, and the audit + review-issue surface raised when partial failure occurs. Per the Phase 10 phase doc: "Each business's retention pass is wrapped in a transaction. The Storage bundle delete and the DB row delete commit together or both roll back. Partial failure is detected and surfaced both as a `RETENTION_INCONSISTENCY_DETECTED` audit event and as a HIGH-severity review issue."

The atomicity contract here is distinct from `tool_atomicity_policy.md` (workflow-tool proposer + single-writer) and `zone_promotion_policy.md` (Processing → Operational atomic move). This is the archive-deletion atomicity specifically — crossing Postgres and Supabase Storage.

---

## 1. The challenge

Archive deletion crosses two systems:

1. The DB — `archive.archive_packages`, `archive.archive_manifests`, `archive.locked_ledger_entries`, `archive.transactions`, `archive.documents`, etc. Postgres-transactional.
2. The Storage bucket — `archive-bundles/<business_id>/<period>/.../bundle-vN.zip`. External API, NOT transactional with Postgres.

A naive ordering (DELETE-then-Storage-delete, or Storage-delete-then-DELETE) leaves the system in an inconsistent state if the second step fails. The atomicity contract defines an ordering with verification + an in-progress marker that lets a subsequent pass reconcile orphans deterministically.

---

## 2. Per-bundle deletion ordering

Each archive bundle is deleted via the following ordered procedure inside a single DB transaction:

```
0. legal_hold_check = legalHoldHook(business_id)              -- per §3
   IF on_hold: emit RETENTION_DELETION_SKIPPED_LEGAL_HOLD; return
1. BEGIN
2. SELECT id, bundle_object_uri FROM archive.archive_packages
   WHERE deletable AND deletion_state = 'PENDING'
   FOR UPDATE                                                  -- mutex per row
3. UPDATE archive_packages SET deletion_state = 'IN_PROGRESS'  -- DB write 1; in-progress marker
4. Storage DELETE(bundle_object_uri)                           -- external call (see §4)
5. Verify Storage DELETE succeeded (HTTP 200/204 OR 404)
6. DELETE archive.locked_ledger_entries WHERE archive_package_id = $1
   DELETE archive.archive_manifests       WHERE archive_package_id = $1
   DELETE archive.transactions            WHERE archive_package_id = $1
   DELETE archive.documents               WHERE archive_package_id = $1
   DELETE archive.match_records           WHERE archive_package_id = $1
   DELETE archive.review_issues           WHERE archive_package_id = $1
   DELETE archive.archive_packages        WHERE id = $1         -- DB writes 2-8
7. COMMIT
```

Mutex: `SELECT ... FOR UPDATE` in step 2 prevents concurrent deletion attempts on the same bundle. The `deletion_state` column on `archive_packages` is the in-progress marker (§6).

Row count: a single archive package can have thousands of `locked_ledger_entries` and `transactions` rows; the DELETEs cascade by `archive_package_id` and are bounded by indexes on that column (per `archive_schema.md`).

---

## 3. Legal-hold check ordering

The legal-hold hook (per `retention_legal_hold_hook_contract.md`, B04·P10 seq 418) is called BEFORE step 1's transaction begins:

```
legal_hold_check = legalHoldHook(business_id)
IF legal_hold_check.on_hold:
  emit RETENTION_DELETION_SKIPPED_LEGAL_HOLD with hold_reasons; return
ELSE:
  continue to step 1
```

The hook is consulted per-business (NOT per-bundle) because `legal_holds` is business-scoped. A held business has ALL its archive bundles skipped in the current pass — the per-bundle iteration short-circuits at this check.

---

## 4. Storage DELETE semantics

The Storage DELETE call uses the Supabase Storage admin API with the `retention_engine` service role's signed credential:

| Response | Behavior |
|---|---|
| HTTP 200 / 204 | Bundle successfully deleted; proceed to step 6 |
| HTTP 404 | Bundle was already deleted (previous pass succeeded on Storage but DB rolled back). Proceed to step 6 — DB cleanup of the orphan |
| HTTP 409 (Object Lock still active) | Should never occur — eligibility check verifies Object Lock expiry. If it does, abort + emit `RETENTION_PASS_AUTH_ERROR` (HIGH) |
| HTTP 5xx / network error | Transient. Retry per `retry_policy.md` standard tool tier (N=3, base 2s, exponential, ±10% jitter, cap 30s) |
| HTTP 403 / 401 | Credential issue. Abort pass + emit `RETENTION_PASS_AUTH_ERROR` (HIGH) |

The retry budget is encapsulated inside the Storage-delete helper; from the caller's perspective the call either succeeds or returns a final failure.

---

## 5. Inconsistency detection

If Storage DELETE in step 4 succeeds but the DB transaction in steps 6-7 fails (e.g., FK violation, connection loss, replication lag triggering retry), the DB transaction rolls back leaving a **Storage-deleted-DB-present orphan**.

Detection: at the start of each pass, the engine runs a pre-flight reconciliation:

```sql
-- Identify rows with deletion_state = 'IN_PROGRESS' from a prior pass
SELECT id, business_id, bundle_object_uri
FROM archive.archive_packages
WHERE deletion_state = 'IN_PROGRESS';
```

For each candidate orphan:

1. Issue Storage `HEAD` on `bundle_object_uri`.
2. **If HEAD returns 404** → bundle is missing in Storage; DB cleanup proceeds (steps 6-7); emit `RETENTION_DELETION_RECONCILED_ORPHAN` (MEDIUM).
3. **If HEAD returns 200** → bundle still exists in Storage; reset `deletion_state = 'PENDING'` and let the normal pass logic re-evaluate; emit `RETENTION_PASS_DELETION_STATE_RESET` (LOW).
4. **If HEAD returns 5xx / fails repeatedly** → mark `deletion_state = 'INCONSISTENT'`; emit `RETENTION_INCONSISTENCY_DETECTED` (HIGH); raise the operator review issue (§8).

The inverse case — DB cleanup completed but Storage DELETE leaked because Postgres committed locally without the Storage call having succeeded — should not occur given the §2 ordering (Storage delete BEFORE DB commit). If it does occur (e.g., due to a misbehaving Storage-helper wrapper), the orphan surfaces as a Storage object with no `archive_packages` row referencing it; cleanup happens via the prefix-listing reconciler per `retention_orphan_cleanup_policy.md` (Stage-2 instrumentation; cross-block coordination flagged for B15).

---

## 6. The `deletion_state` column

```sql
CREATE TYPE archive_deletion_state_enum AS ENUM (
  'PENDING',       -- eligible for deletion; awaiting next pass
  'IN_PROGRESS',   -- deletion currently underway (Storage call in flight or DB commit pending)
  'HELD_LEGAL',    -- legal hold active; skip until hold clears
  'INCONSISTENT'   -- pre-flight scan flagged for operator review; manual intervention required
);

ALTER TABLE archive.archive_packages
  ADD COLUMN deletion_state archive_deletion_state_enum NOT NULL DEFAULT 'PENDING';

CREATE INDEX idx_archive_packages_deletion_state
  ON archive.archive_packages(deletion_state)
  WHERE deletion_state != 'PENDING';
```

Transitions:

- `PENDING → IN_PROGRESS` (step 3 of normal pass)
- `IN_PROGRESS → row removed` (step 6-7 commit)
- `IN_PROGRESS → PENDING` (orphan reconciliation reset on HEAD=200)
- `PENDING → HELD_LEGAL` (legal hold detected mid-pass; restored to `PENDING` when the hold lifts)
- `* → INCONSISTENT` (operator escalation; manual intervention required)

Cross-block coordination flagged for B04·P07 `archive_schema.md` — the new column + enum must be added to the canonical schema doc.

---

## 7. Audit events

| Event | Severity | When | Payload key fields |
|---|---|---|---|
| `RETENTION_DELETION_PLANNED` | LOW | Per-bundle: eligibility computed + not on hold; bundle is about to be deleted | `business_id`, `archive_package_id`, `bundle_object_uri`, `bundle_size_bytes`, `archived_at`, `eligibility_threshold`, `pass_id` |
| `RETENTION_DELETION_EXECUTED` | LOW | Per-bundle: deletion procedure completed cleanly | `business_id`, `archive_package_id`, `bundle_object_uri`, `bundle_size_bytes`, `deleted_at`, `pass_id` |
| `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` | LOW | Per-business: hook returned on_hold=true; all bundles for the business skipped | `business_id`, `hold_reasons`, `skipped_bundle_count`, `skipped_at`, `pass_id` |
| `RETENTION_INCONSISTENCY_DETECTED` | HIGH | Pre-flight scan + HEAD repeatedly failed; orphan marked INCONSISTENT | `archive_package_id`, `bundle_object_uri`, `last_head_status`, `attempts`, `detected_at`, `pass_id` |
| `RETENTION_DELETION_RECONCILED_ORPHAN` | MEDIUM | Pre-flight scan + HEAD returned 404; DB cleanup completed | `archive_package_id`, `cleanup_action`, `reconciled_at`, `pass_id` |
| `RETENTION_PASS_DELETION_STATE_RESET` | LOW | Pre-flight scan + HEAD returned 200; row reset to PENDING for retry | `archive_package_id`, `reset_at`, `pass_id` |
| `RETENTION_PASS_AUTH_ERROR` | HIGH | Storage credential failure mid-pass; pass aborted | `attempted_at`, `error_class`, `pass_id` |

All in the Block 04 RETENTION domain per `audit_event_taxonomy.md`. **Cross-block coordination flagged for B05·P02:** `RETENTION_DELETION_EXECUTED` + `_SKIPPED_LEGAL_HOLD` + `INCONSISTENCY_DETECTED` already exist in taxonomy; 4 NEW event kinds (`_PLANNED`, `_RECONCILED_ORPHAN`, `_DELETION_STATE_RESET`, `PASS_AUTH_ERROR`).

---

## 8. Operator review issue

`RETENTION_INCONSISTENCY_DETECTED` (HIGH) raises a `review_issues` row of type `RETENTION_INCONSISTENCY` (NEW issue type — cross-block coordination flagged for B14·P02 issue_type_registry):

| Field | Value |
|---|---|
| `issue_type` | `RETENTION_INCONSISTENCY` |
| `severity` | HIGH |
| `business_id` | From the orphan row |
| `context_json` | `{archive_package_id, bundle_object_uri, last_head_status, attempts, first_detected_at, pass_id}` |
| `raised_by_tool_name` | `archive.run_retention_pass` |
| `default_group` | `DATA_INTEGRITY` |

The issue appears in the next operator review pass per Block 14's review queue. Resolution is operator-driven via the DBA console: either (a) confirm Storage state and clean up the DB row manually, or (b) restore the bundle from a Storage backup and reset `deletion_state = 'PENDING'`.

---

## 9. Mobile rejection

Retention pass execution is backend-only; no mobile surface exists.

---

## 10. Cross-references

- `retention_policies_schema.md` — per-business `retention_years` consumer
- `retention_scheduling_policy.md` (B04·P10 seq 414) — when the pass runs + concurrency model
- `retention_legal_hold_hook_contract.md` (B04·P10 seq 418) — hook called pre-deletion (§3)
- `retention_dry_run_mode_policy.md` (B04·P10 seq 420) — non-deleting alternative; skips this policy's deletion steps
- `archive_schema.md` (B04·P07) — must add `deletion_state` column + enum; cross-block coordination flagged
- `object_lock_integration.md` — Storage DELETE API + Object Lock expiry semantics
- `tool_atomicity_policy.md` — sibling policy; this policy does NOT use the proposer + single-writer pattern (deletion path, no proposer)
- `retry_policy.md` — standard tool tier retry constants for transient Storage errors (§4)
- `audit_event_taxonomy.md` — RETENTION + ARCHIVE domains
- `archive_promotion_failure_runbook.md` — related runbook for the inverse (promotion failure) atomicity case
- Block 04 Phase 10 — owning phase
- Block 14·P02 — NEW `RETENTION_INCONSISTENCY` review issue type; cross-block coordination flagged
- Block 15 — `retention_orphan_cleanup_policy` Stage-2 (cross-block coordination flagged)
