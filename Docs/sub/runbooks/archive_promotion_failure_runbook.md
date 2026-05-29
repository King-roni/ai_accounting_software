# archive_promotion_failure_runbook

**Category:** Runbooks · **Owning block:** 04 — Data Architecture · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block runbook)

The operator-facing procedure for diagnosing and recovering from archive promotion failures. A promotion failure means the lock sequence reached the bundle-construction or Object-Lock-setting stage but couldn't commit — leaving operational data unfinalized OR (worst case) leaving a partial bundle in Storage.

Per `lock_sequence_policies` (consolidated): the system auto-retries once on transient failure. Persistent failure raises a HIGH-severity review issue and requires this runbook.

---

## Failure classes

The lock sequence categorizes failures into 13 classes per Block 15 Phase 09's failure-mode taxonomy. The runbook focuses on the operator-actionable ones:

| Class | Symptom | Persistence |
| --- | --- | --- |
| `BUNDLE_CONSTRUCTION_FAILED` | Storage upload errored mid-stream | Transient — auto-retry succeeds |
| `OBJECT_LOCK_RETENTION_SET_FAILED` | Storage returned 5xx on retention API | Transient — auto-retry succeeds |
| `PERIOD_REPORT_GENERATOR_FAILED` | `tool_period_report_generator` threw | Transient OR Permanent depending on cause |
| `RFC_3161_ANCHOR_FAILED` | All TSAs unreachable | Transient — anchor retries on next run |
| `MANIFEST_VERSION_COLLISION` | Two concurrent adjustment runs landed v{N} simultaneously | Transient — auto-retry assigns v{N+1} |
| `BUNDLE_DETERMINISM_VERIFICATION_FAILED` | Re-built bundle bytes != original bundle bytes | Permanent — code bug; halt |
| `OBJECT_LOCK_VIOLATION_DETECTED` | Pre-read verification showed unexpected retention attribute | Permanent — BLOCKING; business-wide halt |
| `CHART_MAPPING_VERSION_INCONSISTENT` | Pre-finalization invariant failed | Permanent — requires Block 11 recompute |
| `AUDIT_CHAIN_UNREACHABLE` | Audit emission failing persistently | Permanent — Block 05 issue |
| `STORAGE_QUOTA_EXCEEDED` | Per-business storage quota hit | Permanent — operator must upgrade |
| `LEGAL_HOLD_BLOCKS_RETENTION_DELETE` | Retention engine couldn't aggressive-delete a competing object | Permanent — investigate hold |
| `ADJUSTMENT_PARENT_BUNDLE_MISSING` | Adjustment finalization called but parent v1 bundle not found | Permanent — data corruption |
| `STEP_UP_TOKEN_EXPIRED` | Lock sequence took longer than step-up validity window | Transient — user re-step-ups |

## Step 1 — Determine class

Read the audit log:

```sql
SELECT event_type, event_payload, appended_at
FROM audit_log
WHERE business_id = $business_id
  AND event_type IN (
    'ARCHIVE_PROMOTION_FAILED',
    'FINALIZATION_FAILED',
    'FINALIZATION_LOCK_COMMITTED',         -- if missing, lock didn't reach commit
    'FINALIZATION_PRECONDITION_FAILED'
  )
  AND appended_at >= $finalization_attempted_at - INTERVAL '1 hour'
ORDER BY appended_at DESC
LIMIT 20;
```

The `failure_class` field in the most recent `_FAILED` event identifies the class.

## Step 2 — Look up the recovery procedure

| Class | Recovery procedure |
| --- | --- |
| `BUNDLE_CONSTRUCTION_FAILED` | Re-trigger the original FINALIZATION run; auto-retry succeeded? Then it's already resolved |
| `PERIOD_REPORT_GENERATOR_FAILED` (transient) | Re-trigger; verify report generates manually first |
| `PERIOD_REPORT_GENERATOR_FAILED` (permanent — e.g., snapshot has bug) | Escalate to engineering; Block 16 Phase 10 owns the renderer |
| `RFC_3161_ANCHOR_FAILED` | Resume `key_rotation_runbook`-style TSA check; if persistent, accept deferred anchor and retry on next finalization |
| `MANIFEST_VERSION_COLLISION` | Engine retries automatically; verify by reading `archive_manifests` table |
| `BUNDLE_DETERMINISM_VERIFICATION_FAILED` | Engineering escalation — bundle determinism is a code-level invariant per `archive_bundle_policies` |
| `OBJECT_LOCK_VIOLATION_DETECTED` | BLOCKING — see Step 3 (escalation procedure) |
| `CHART_MAPPING_VERSION_INCONSISTENT` | Invoke Block 11 Phase 09 `recompute_ledger_entries` to bring all entries to current version, then re-trigger finalization |
| `AUDIT_CHAIN_UNREACHABLE` | Block 05 issue; restore audit subsystem before retrying |
| `STORAGE_QUOTA_EXCEEDED` | Operator upgrades storage; manual finalization retry |
| `LEGAL_HOLD_BLOCKS_RETENTION_DELETE` | Verify legal hold is intentional; if accidental, lift hold per `legal_hold_policies` |
| `ADJUSTMENT_PARENT_BUNDLE_MISSING` | Data corruption — escalate to engineering |
| `STEP_UP_TOKEN_EXPIRED` | User re-authenticates with fresh step-up; re-trigger |

## Step 3 — `OBJECT_LOCK_VIOLATION_DETECTED` escalation

This is the most severe — it indicates either tampering attempted by an unauthorized actor, OR a configuration drift in Supabase Storage.

Per Block 15 Phase 07: the business is **halted business-wide** until investigated. No new finalizations or adjustments accept until the violation is cleared.

Procedure:

1. **Snapshot the state** — capture `archive_packages.bundle_object_uri`, `archive_packages.bundle_hash`, the Object Lock metadata at the current moment
2. **Re-verify** by re-reading the bundle bytes from Supabase Storage and recomputing the hash. Compare against `archive_packages.bundle_hash`
3. **If hash matches:** the alarm was a false positive (e.g., transient Storage API blip during pre-read verification). Update the Object Lock attributes; clear the BLOCKING issue; emit `ARCHIVE_TAMPER_FALSE_POSITIVE_CLEARED`
4. **If hash does NOT match:** real tampering or corruption. Halt the business; engineer + legal escalation. The RFC 3161 anchor remains the source of truth — the bundle CAN be reconstructed from the locked entries if necessary
5. **Operator alerts** fire per `cross_tenant_alerting_runbook`

## Step 4 — Lock state cleanup

The lock sequence may have left intermediate state:

```sql
-- Check for stale advisory locks
SELECT pg_advisory_unlock_all();             -- only if this session held the lock

-- Check for pending workflow_runs.status = FINALIZING with no recent activity
SELECT workflow_run_id, status, state_changed_at
FROM workflow_runs
WHERE business_id = $business_id
  AND status = 'FINALIZING'
  AND state_changed_at < now() - INTERVAL '30 minutes';
```

If a run is stuck in FINALIZING with no recent activity, force-transition it back to AWAITING_APPROVAL via `engine.force_resume_run(run_id, target_state)` (operator-only tool):

```bash
psql -c "SELECT engine.force_resume_run('<run_id>', 'AWAITING_APPROVAL', 'archive_promotion_failure_recovery')"
```

This emits `WORKFLOW_RUN_FORCE_RESUMED` with the operator's user_id.

## Step 5 — Verify recovery

```sql
-- The original archive bundle should exist and be intact
SELECT id, bundle_hash, current_manifest_version_number, object_lock_retention_until
FROM archive.archive_packages
WHERE business_id = $business_id
  AND period_start = $period_start
ORDER BY promoted_at DESC LIMIT 1;

-- The manifest chain should be unbroken
SELECT manifest_version_number, manifest_hash, prior_manifest_hash, rfc_3161_timestamp_id
FROM archive.archive_manifests
WHERE archive_package_id = $package_id
ORDER BY manifest_version_number;
```

If the manifest chain has gaps or invalid prior_manifest_hash values, engineering escalation. Per the three-layer immutability model, the chain integrity is non-negotiable.

## Audit events emitted by the runbook

| Event | When |
| --- | --- |
| `ARCHIVE_PROMOTION_RECOVERY_INITIATED` | Operator opens this runbook procedure |
| `WORKFLOW_RUN_FORCE_RESUMED` | Step 4 force-resume |
| `ARCHIVE_TAMPER_FALSE_POSITIVE_CLEARED` | Step 3 false-positive case |
| `ARCHIVE_PROMOTION_RECOVERY_COMPLETED` | After verification |

## Cross-references

- `lock_sequence_policies` — auto-retry semantics
- `archive_bundle_policies` — determinism verification
- `legal_hold_policies` — hold interaction
- `object_lock_integration` — pre-read verification
- `archive_promotion_completed_event_integration` — successful-promotion event
- `analytics_refresh_runbook` — sibling runbook
- `cross_tenant_alerting_runbook` — escalation channel
- `archive_manifest_schemas` — manifest chain integrity
- `audit_log_policies` — `ARCHIVE_*` event family
- Block 15 Phase 09 — failure handling & rollback (architecture)
- Block 15 Phase 07 — Object Lock & three-layer immutability
- 2026-05-08 decisions-log amendment — `manifest_version_collision` failure class
