# crash_recovery_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

The contract for fleet-level crash recovery when one or more engine worker processes restart. Defines the startup enumeration query, the choice between batch-parallel and sequential recovery, throttling for the upstream pressure recovery induces, connection-pool isolation, and the audit shape.

This policy complements `resumability_policy` — which defines per-run resume semantics — by pinning the *fleet-level* concerns: how many runs to recover at once, how to avoid thundering-herd against external services, and how to coordinate when multiple workers come up simultaneously.

---

## Startup enumeration query

On worker process start, the engine runs ONE canonical query to find runs that need attention:

```sql
SELECT id, business_id, current_phase_name, run_status, updated_at
FROM   workflow_runs
WHERE  run_status IN ('RUNNING', 'COMPENSATING', 'FINALIZING')
  AND  updated_at < now() - interval '30 seconds'
ORDER  BY updated_at ASC                                    -- oldest first
LIMIT  500;
```

| Filter | Reason |
| --- | --- |
| `run_status IN ('RUNNING', 'COMPENSATING', 'FINALIZING')` | These are the active states — they should be moving. CREATED has not started yet; PAUSED / REVIEW_HOLD / AWAITING_APPROVAL are waiting by design; FAILED / CANCELLED / FINALIZED are terminal |
| `updated_at < now() - interval '30 seconds'` | Excludes runs another worker is actively progressing right now (the 30 s grace gives the in-flight transaction time to commit before a peer treats it as stalled) |
| `ORDER BY updated_at ASC` | Oldest-stalled-first; the run that has been idle longest gets recovery priority |
| `LIMIT 500` | Per-worker batch cap; large fleets should NOT enumerate the entire stuck-runs set on a single worker. With multiple workers each capped at 500 and the `30s` filter eliminating overlap, fleet-level recovery scales linearly |

The 30-second filter is the load-bearing piece: it lets workers safely run this query in parallel without coordinating with each other. A run that is genuinely moving will have its `updated_at` refreshed within 30 s (per `phase_execution_loop_policy`'s boundary commit cadence); a run that hasn't been touched in 30 s is stalled and eligible for recovery regardless of which worker picks it up.

If the result set is empty: the worker enters normal operation (waits for the trigger engine + user-initiated calls). If non-empty: proceeds to §2.

## Batch parallelism — bounded and shared-resource-aware

Recovery is NOT sequential. The engine has `crash_recovery_concurrency` (default `4`) — that many recovery calls run in parallel within a single worker process. The choice of 4:

| Factor | Rationale |
| --- | --- |
| Connection pool | Each `engine.advanceRun` takes 1–2 connections; default pool size is 20; reserving 4 leaves 16 for normal workload during recovery |
| Bank API rate limits | Cyprus banks rate-limit at ~10 req/s per business; 4 parallel runs across distinct businesses stays well under |
| AI cost | Per `external_request_id_handling_policy`, Anthropic does not replay — recovery can double-bill; bounded parallelism caps the worst case |
| CPU | A single advanceRun is mostly I/O bound; 4 parallel is comfortably below CPU saturation |

Settings cascade:

- `crash_recovery_concurrency = 4` (per worker)
- `crash_recovery_inter_run_delay_ms = 250` (delay between starting consecutive recovery calls — smooths the connection-pool burst)
- `crash_recovery_per_business_max = 1` (no two recovery calls for the same business at once; prevents intra-tenant contention)

The per-business cap means a tenant with 200 stuck runs sees them recovered one at a time even if the worker has 4 parallel slots — the other 3 slots service other tenants in parallel. Fair share without explicit prioritisation.

## Sequential mode (degraded operation)

Three conditions force sequential mode (concurrency=1):

1. **Database connection pool below 50%** — measured by `pg_stat_activity` count; falling below 10 idle connections sets the limit to 1.
2. **Recovery budget exhausted** — per `cost_alerting_runbook`, if recovery has issued more than `crash_recovery_external_call_budget` (default 50) external calls in the last 10 minutes, drop to sequential.
3. **Manual override** — `ops.set_crash_recovery_mode('SEQUENTIAL')` via the ops console; persists until ops resets to AUTO.

Sequential mode emits `WORKFLOW_FLEET_CRASH_RECOVERY_DEGRADED` (HIGH) on entry and remains until the trigger condition clears for 5 minutes.

## Throttling — token-bucket per external service

For each external service named in `external_request_id_handling_policy`'s table, a token-bucket throttle bounds the rate of recovery-induced calls:

| Service | Bucket capacity | Refill rate |
| --- | --- | --- |
| Gmail | 100 | 10 / s |
| Drive | 100 | 10 / s |
| Anthropic | 20 | 2 / s (cost-protective) |
| Document AI (OCR) | 30 | 3 / s |
| RFC 3161 TSA | 10 | 1 / s |
| Bank connectors (per-connector) | 10 | 1 / s |

Buckets are SHARED across all workers via a `crash_recovery_throttle_state` table in the operational DB; SECURITY DEFINER RPC `engine.acquire_recovery_token(service text)` does the atomic decrement under advisory lock. A recovery call that cannot acquire a token waits (with `wait_timeout = 30s` and the standard retry policy on timeout) rather than failing.

The buckets do NOT apply to normal (non-recovery) workload — only to calls issued during the recovery sweep. This is enforced by an in-process flag set by `engine.crashRecoverWorker` for the duration of the sweep.

## Coordination across workers

Multiple workers starting at the same time MUST NOT all try to recover the same run. Coordination is via the advisory lock from `phase_execution_locking_policy`:

```sql
-- Each worker, for each enumerated run:
BEGIN;
SELECT pg_try_advisory_xact_lock(engine.run_lock_key(run_id));
-- If TRUE → this worker owns the recovery for this run; proceed.
-- If FALSE → another worker is already recovering it; skip to next run.
COMMIT;
```

`pg_try_advisory_xact_lock` (non-blocking variant) is used here, NOT `pg_advisory_xact_lock`. A miss is informative — proceed to the next candidate — not an error.

This means the enumeration query's overlap between workers (none with the 30s filter, but defensive anyway) is handled at lock-acquisition time without explicit cross-worker messaging.

## Recovery sequence per run

For each run the worker has lock-acquired:

1. Re-read run state (lock now held).
2. Determine recovery path:
   - `current_phase_state.status = RUNNING` → re-enter the phase per `phase_execution_loop_policy` §4 idempotent re-entry.
   - `current_phase_state.status = AWAITING_RESULT` (tool was mid-external-call) → per `external_request_id_handling_policy` §recovery flow; query upstream if replay supported.
   - `current_phase_state.status = COMPLETED` but `workflow_runs.current_phase_name` not yet advanced → the prior tx died mid-boundary-commit; complete the advancement.
3. Call `engine.advanceRun(run_id)` per `phase_execution_loop_policy` §2 (will internally re-acquire the lock; lock is reentrant for the same caller via the advisory-lock semantics).
4. Emit `WORKFLOW_RUN_FORCE_RESUMED` per `resumability_policy` §6.

If `advanceRun` returns `HOLDING` or `ROUTED_TO_SIDE_PHASE`, that is the correct outcome — the run is now in a coherent state and recovery for this run is done. The next normal trigger (gate clear, user action) will resume it.

If `advanceRun` throws, the worker emits `WORKFLOW_RUN_RECOVERY_FAILED` (HIGH) with the error class + boundary_eval_id, RELEASES the advisory lock, and proceeds to the next run. A failed-recovery run is picked up by the next worker startup sweep (after 30s) — the system is self-healing as long as the underlying error is transient.

## Audit shape

```ts
emitAudit("WORKFLOW_FLEET_CRASH_RECOVERY_STARTED", {
  worker_id,
  enumerated_run_count,
  mode: "BATCH" | "SEQUENTIAL",
  concurrency: integer,
  started_at
});

emitAudit("WORKFLOW_FLEET_CRASH_RECOVERY_COMPLETED", {
  worker_id,
  recovered_count, failed_count, skipped_count,
  duration_ms,
  completed_at
});

emitAudit("WORKFLOW_FLEET_CRASH_RECOVERY_DEGRADED", {
  worker_id,
  trigger: "CONNECTION_POOL" | "BUDGET" | "MANUAL",
  active_from
});

emitAudit("WORKFLOW_RUN_RECOVERY_FAILED", {
  worker_id, workflow_run_id, business_id,
  error_class, error_message_redacted, stack_hash,
  failed_at
});
```

Plus per-run `WORKFLOW_RUN_FORCE_RESUMED` events on individual successful recoveries. All severity LOW except `_FAILED` (HIGH) and `_DEGRADED` (HIGH).

## Non-goals

- Replacing the normal trigger engine — recovery only handles runs that should be moving but aren't.
- Promoting `PAUSED` / `REVIEW_HOLD` / `AWAITING_APPROVAL` runs — those are waiting by design.
- Compensating `FAILED` runs — that's a separate ops-driven path.
- Discovering "lost" runs (records that exist but should not) — that's audit-trail-reconstruction territory.

## Cross-block contract

- **Block 03 Phase 06** owns the runtime that this policy invokes (`engine.advanceRun`).
- **Block 03 Phase 07** owns the parent crash-recovery semantics; this policy is the fleet-level specialisation.
- **Block 03 Phase 09** trigger engine MUST coordinate with the recovery sweep — both invoke `advanceRun` and contend for the advisory lock; the trigger engine drains recovery's pending queue once recovery completes.
- **Block 03 Phase 10** concurrency control uses the same advisory lock; shared-phase coordination during recovery picks up the cross-run ordering rule.
- **Block 06 / 07 / 09** external-service throttle buckets are sized per their respective rate-limits.

## Cross-references

- `resumability_policy` — per-run resume contract (this policy's per-fleet companion)
- `phase_execution_loop_policy` — `engine.advanceRun` idempotent re-entry contract
- `phase_execution_locking_policy` — advisory lock acquisition; `pg_try_advisory_xact_lock` for non-blocking variant
- `external_request_id_handling_policy` — recovery path for AWAITING_RESULT rows
- `tool_atomicity_policy` — single-writer guard prevents double-commit during recovery
- `dedup_key_generator_policy` — engine-level dedup that protects from recovery-driven retries against non-replay services
- `gate_throws_semantics_policy` — retry-exhaustion path for `WORKFLOW_RUN_RECOVERY_FAILED`
- `cost_alerting_runbook` — budget thresholds for degraded-mode triggering
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_FLEET_*` + `WORKFLOW_RUN_RECOVERY_FAILED` payloads
- Block 03 Phase 06 — `engine.advanceRun` host
- Block 03 Phase 07 — owning phase
- Block 03 Phase 09 — trigger engine coordination
- Block 03 Phase 10 — concurrency control
- Block 06 / 07 / 09 — external-service throttle buckets
