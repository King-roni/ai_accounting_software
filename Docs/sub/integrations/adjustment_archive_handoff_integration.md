# adjustment_archive_handoff_integration

**Category:** Integrations · **Owning block:** 03 — Workflow Engine · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The handoff contract from Block 03's adjustment workflow runs (`OUT_ADJUSTMENT`, `IN_ADJUSTMENT`) to Block 15's finalization engine. Unlike monthly runs which finalize via the standard FINALIZATION phase, adjustment runs commit by triggering a NEW archive bundle version per `archive_bundle_layout_schema` and Block 15 Phase 06.

This sub-doc pins the handoff contract — when, what payload, what state transitions, what audit events.

---

## When the handoff fires

An adjustment run reaches the handoff after:

1. The adjustment's user-confirmation gate has passed (the user approved the adjustment delta)
2. Block 11's `recompute_ledger_entries` has produced the adjustment-side ledger entries
3. Block 14's review queue is clean for the adjustment scope (no HIGH or BLOCKING issues)
4. The run's status transitions to `AWAITING_APPROVAL`

At that point, Block 15's adjustment-finalization is invoked per Block 15 Phase 08.

## Handoff signal

```ts
// Block 03's state-machine engine fires this on AWAITING_APPROVAL → FINALIZING transition
archive.handoff_adjustment_finalization({
  adjustment_run_id: uuid,
  parent_run_id: uuid,                      // the original finalized run
  business_id: uuid,
  period_start: date,
  period_end: date,
  delta_record_ids: uuid[],                 // adjustment_records.adjustment_record_id list
  approval_step_up_token_id: uuid,
});
```

Block 15 Phase 08 receives this signal, validates the preconditions, and begins the adjustment-bundle construction.

## Preconditions Block 15 verifies

Per Block 15 Phase 08:

1. The parent run's most recent archive_package exists and is intact (re-read verification per `archive_pre_read_verification_policy`)
2. The adjustment_record_ids are all under the same adjustment_run_id
3. The adjustment scope doesn't conflict with another in-flight adjustment on the same period (per `out_adjustment_policies` ordering rule)
4. The step-up token is valid per `step_up_validity_window_policy`

A precondition failure raises `archive.finalization_precondition_failed` (BLOCKING per `severity_enum`) and reverts the run state to `AWAITING_APPROVAL`. User intervention required.

## What Block 15 does on receipt

1. **Snapshot operational records** at the moment of handoff (lock-sequence step 1 equivalent)
2. **Compute the adjustment overlay** — for each `adjustment_record`, project the delta onto the parent's locked state
3. **Generate `period_report_v2.pdf`** via `tool_period_report_generator` with the snapshot including both original-locked + adjustment-draft entries (per the 2026-05-09 amendment)
4. **Build the new manifest** — `manifest_v{N+1}.json` per `archive_bundle_layout_schema`, with `prior_manifest_hash` pointing at v{N}
5. **Construct the new bundle** — `archive_v{N+1}_bundle.zip` per `archive_bundle_policies`
6. **Apply Object Lock** per `object_lock_integration`
7. **Anchor the new manifest hash** per `archive_hash_anchor_integration`
8. **Emit `ARCHIVE_PROMOTION_COMPLETED`** per `archive_promotion_completed_event_integration`
9. **Transition the adjustment run** to `FINALIZED`

The original bundle is NOT modified. The original Object Lock retention continues. The new bundle is a separate object with its own Object Lock.

## Audit events

| Event | When |
| --- | --- |
| `WORKFLOW_RUN_STATE_CHANGED` | Block 03 transitions to FINALIZING |
| `ADJUSTMENT_ARCHIVE_HANDOFF_REQUESTED` | Block 03's handoff signal fired |
| `FINALIZATION_PRECONDITION_EVALUATED` | Block 15's precondition check |
| `FINALIZATION_LOCK_STARTED` | Block 15 begins adjustment-bundle construction |
| `FINALIZATION_LOCK_COMMITTED` | Adjustment bundle promoted |
| `ARCHIVE_PROMOTION_COMPLETED` | Canonical cross-block trigger fired |
| `OUT_ADJUSTMENT_APPROVED` / `IN_ADJUSTMENT_APPROVED` | Block 03 final state transition |

The `FINALIZATION_LOCK_COMMITTED` and `ARCHIVE_PROMOTION_COMPLETED` events fire as a coordinated pair per Block 15's lock-sequence step 7 — the audit emission runs in a separate short transaction per the 2026-05-08 amendment.

## Failure handling

| Failure | Block 15 response | Block 03 response |
| --- | --- | --- |
| Adjustment-bundle construction fails | Auto-retry once per `lock_sequence_policies` | Stays in FINALIZING; if persistent, raise HIGH issue |
| `tool_period_report_generator` fails | Auto-retry once | Raise `archive.finalization_period_report_failed` (HIGH); run stays in FINALIZING |
| Storage upload fails | Retry; cleanup partial bundle | Same — run stays in FINALIZING |
| Object Lock setting fails | Retry; raise `ARCHIVE_PROMOTION_FAILED` if persistent | Per `archive_promotion_failure_runbook` |
| Audit emission fails after commit | Per Block 03 Phase 07 resumability — `FINALIZATION_LOCK_AUDIT_RECOVERED` on next run start | Run state recovered |
| Manifest hash anchor fails | Best-effort; bundle is committed, anchor retries on next run start | Run continues |

The run **never silently fails forward**. A failure either retries or surfaces as a review issue requiring user resolution.

## Concurrency

Two adjustment runs against the same parent_run_id can run concurrently per Stage 1 ("Multiple adjustments per period — both can run concurrently"). They handoff in serial commit order:

1. Adjustment A handoff arrives first → Block 15 builds `archive_v2_bundle.zip` referencing `manifest_v1` as prior
2. Adjustment B handoff arrives second (potentially in flight already) → Block 15 builds `archive_v3_bundle.zip` referencing `manifest_v2` as prior

Per `concurrent_adjustments_ordering_policy` (merged into `archive_bundle_policies` cross-references): the manifest-version-collision unique constraint prevents lost updates. If two handoffs race for the same v{N+1}, the second is rejected with `manifest_version_collision`; auto-retry per `lock_sequence_policies` re-reads the latest version and assigns v{N+2}.

## Step-up

The adjustment-finalization step-up requirement is the same as monthly finalization per `step_up_validity_window_policy`. The `approval_step_up_token_id` in the handoff payload references the token issued at user-approval time; Block 15 verifies it's still within the step-up window.

## Audit visibility for adjustment

The adjustment_records (per `adjustment_record_schema`) become the historical proof of what was adjusted. The new bundle includes them in its `locked_review_issues.json` (the resolved BLOCKING issues that triggered the adjustment) and its manifest references the prior version.

Future audit-history-slice queries (per `audit_history_slice_query_schema`) traverse the full chain from current manifest back to v1.

## Cross-references

- `adjustment_record_schema` — the adjustment_records consumed
- `archive_bundle_layout_schema` — new bundle structure
- `archive_promotion_completed_event_integration` — canonical event emission
- `archive_hash_anchor_integration` — new manifest anchored externally
- `object_lock_integration` — per-bundle Object Lock
- `tool_period_report_generator` — period_report_v2.pdf rendering
- `lock_sequence_policies` (consolidated from `lock_sequence_*` policies) — retry behavior
- `archive_bundle_policies` (consolidated) — bundle determinism + version-collision retry
- `step_up_validity_window_policy` — step-up freshness
- `audit_log_policies` — event family
- `permission_matrix` — FINALIZATION surface
- Block 03 Phase 11 — adjustment runs (architecture)
- Block 15 Phase 06 — manifest versioning for adjustments
- Block 15 Phase 08 — re-finalization for adjustment runs
- 2026-05-09 decisions-log amendment — snapshot-input contract for adjustment reports

---

## Handoff contract — data format

The `archive.handoff_adjustment_finalization` signal carries a structured payload (described in the "Handoff signal" section above). What Block 15 receives and what format it expects:

| Field | Type | Format | Contract |
| --- | --- | --- | --- |
| `adjustment_run_id` | uuid (v7) | `gen_uuid_v7()` | The Block 03 run ID for the adjustment run |
| `parent_run_id` | uuid (v7) | `gen_uuid_v7()` | The original finalized run whose archive is being amended; must reference an existing `FINALIZED` run with a committed archive package |
| `business_id` | uuid (v7) | `gen_uuid_v7()` | Used by Block 15 to scope all archive operations |
| `period_start` / `period_end` | date | ISO 8601 (`YYYY-MM-DD`) | Must match the parent run's period exactly — Block 15 rejects if they differ |
| `delta_record_ids` | uuid[] (v7) | Array of `adjustment_records.adjustment_record_id` | All records must be in status `APPROVED` at handoff time; Block 15 reads their `delta_kind` and `delta_payload` |
| `approval_step_up_token_id` | uuid (v4 — step-up tokens use `gen_random_uuid()`) | Standard UUID | Must be unconsumed and within the step-up validity window at the point Block 15 validates it |

The payload is signed with the workflow engine's internal signing key (per Block 03 Phase 11) — Block 15 verifies the signature before processing. A forged or malformed handoff signal is rejected with `ADJUSTMENT_HANDOFF_INVALID_SIGNATURE`.

---

## Failure modes

| Failure scenario | Block 15 response | Block 03 run state | User action required |
| --- | --- | --- | --- |
| Parent archive package not found or integrity check fails | Raises `ARCHIVE_INTEGRITY_CHECK_FAILED` (BLOCKING); halts handoff | Reverts to `AWAITING_APPROVAL`; BLOCKING issue raised in review queue | Owner/Admin must investigate the archive state; contact support if archive corruption is confirmed |
| `delta_record_ids` contains a record not in `APPROVED` status | Precondition check fails; `FINALIZATION_PRECONDITION_EVALUATED` emitted with failure | Reverts to `AWAITING_APPROVAL` | User must ensure all delta records are in APPROVED state before re-triggering |
| Archive storage unavailable during bundle upload | Block 15 retries upload up to 3 times per `lock_sequence_policies`; if all fail, emits `ARCHIVE_PROMOTION_FAILED` | Run stays in `FINALIZING`; HIGH severity issue raised | If persistent, operator must resolve storage availability; run can be re-triggered once storage is healthy |
| Object Lock setting fails after bundle upload | Bundle is uploaded but unlocked; Block 15 retries Object Lock setting independently | Run stays in `FINALIZING`; `ARCHIVE_OBJECT_LOCK_FAILED` event emitted (HIGH) | Operator must manually confirm Object Lock is set before declaring the run FINALIZED |
| Step-up token expired between approval and Block 15 validation | `STEP_UP_TOKEN_EXPIRED` precondition failure; handoff rejected | Reverts to `AWAITING_APPROVAL` | User must re-approve with a fresh step-up token |
| Manifest version collision (concurrent adjustment) | Block 15 catches unique constraint violation; auto-retries per `lock_sequence_policies`; assigns the next available version number | Run continues in `FINALIZING` during retry; advances to `FINALIZED` on success | None — automatic |
| `tool_period_report_generator` produces invalid PDF | Block 15 retries once; if still invalid, raises `archive.finalization_period_report_failed` (HIGH) | Stays in `FINALIZING` | User must review the period data; may require re-running the report generator after data correction |

---

## Compensation behavior

If a handoff partially succeeds (bundle built but not locked, or locked but not anchored), the system does not silently complete the run. The compensation path:

1. Block 15 emits `ARCHIVE_PROMOTION_FAILED` with the failure step identifier
2. Block 03 transitions the adjustment run to `COMPENSATING` (per `run_status_enum`) — not FINALIZED, not FAILED
3. A background compensation job (per Block 03 Phase 07 resumability) retries the failed step(s) on next system startup or via manual operator trigger
4. Once the specific failed step is completed (e.g., Object Lock is applied to the uploaded bundle), the job re-evaluates whether all handoff steps are now complete
5. If complete: run transitions from `COMPENSATING` to `FINALIZED`; `ARCHIVE_PROMOTION_COMPLETED` emitted
6. If compensation is not possible (e.g., the uploaded bundle was deleted by a storage cleanup job before Object Lock was set): run transitions to `FAILED`; manual operator intervention required per `archive_promotion_failure_runbook`

The `COMPENSATING` state is visible in the dashboard and the review queue (as a LOW-severity informational issue) so the bookkeeper is aware the finalization is in-progress but not yet complete.

---

## Additional cross-references

- `adjustment_finalization_precondition_schema` — the precondition rules Block 15 evaluates at handoff, including the full list of checks beyond those summarized in this sub-doc
- `archive_schema` — the physical storage schema for archive bundles, Object Lock configuration, and bundle naming conventions
