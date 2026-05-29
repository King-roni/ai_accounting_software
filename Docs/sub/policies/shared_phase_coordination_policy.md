# shared_phase_coordination_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 07, 12 · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The coordination rule for phases that are shared between OUT and IN workflow types — INGESTION, CLASSIFICATION, EVIDENCE_DISCOVERY-shared subsets. Per Stage 1: "OUT/IN trigger order: when a single statement upload triggers both, they run in parallel after the shared INGESTION and CLASSIFICATION phases. The engine deduplicates the shared work."

This policy pins the dedup-key sharing pattern, ordering guarantees, hash strategy, and retention.

---

## Shared phases

| Phase | Always shared? | Notes |
| --- | --- | --- |
| INGESTION | Yes | A statement upload produces transactions once; both workflows read them |
| CLASSIFICATION | Yes | Each transaction is classified once regardless of which workflow consumes it |
| EVIDENCE_DISCOVERY | Partially | Block 09's email/Drive finder runs once per OUT_EXPENSE transaction; IN doesn't fetch evidence per Stage 1 |
| MATCHING | No | Separate per direction — OUT matches against documents; IN matches against invoices |
| INCOME_MATCHING | No | IN-only |
| LEDGER_PREPARATION | No | Separate per direction (different dispatcher paths) |

The shared phases run as logically singular operations; the engine deduplicates concurrent invocations.

## Dedup-key sharing

The mechanism is a per-phase dedup key bound to the input:

```
shared_phase_dedup_key = sha256_hex(canonical_json({
  business_id,
  phase_name,                                      // "INGESTION" | "CLASSIFICATION" | ...
  input_signature                                  // per-phase: e.g., statement_upload_id for INGESTION
}))
```

`input_signature` per phase:

| Phase | input_signature |
| --- | --- |
| INGESTION | `statement_upload_id` |
| CLASSIFICATION | `transaction_ids_sha256_hex(sorted)` — the canonical hash of the sorted transaction ID list |
| EVIDENCE_DISCOVERY | `(transaction_id, finder_kind)` per row — separate dedup key per transaction × finder |

The dedup key lives in `tool_invocations` per Block 03 Phase 03 — when a tool is invoked with the same `dedup_key`, the engine returns the cached result without re-invoking the tool.

## Ordering guarantee

When OUT_MONTHLY and IN_MONTHLY are both triggered by the same `STATEMENT_UPLOAD_COMPLETED`:

1. Engine creates both runs (OUT_MONTHLY first, IN_MONTHLY second, paired_run_id linked)
2. Both runs begin advancing
3. Both runs reach INGESTION concurrently
4. The first run's INGESTION invocation acquires the per-business advisory lock (per `phase_execution_locking_policy`)
5. The second run waits on the lock
6. The first run completes INGESTION, releases the lock
7. The second run acquires the lock, computes the same dedup_key, finds the cached result, immediately returns
8. Both runs now have INGESTION results; both advance to CLASSIFICATION (same pattern)
9. After CLASSIFICATION, the two runs diverge: OUT_MONTHLY runs OUT_FILTER, IN_MONTHLY runs IN_FILTER; from there they're independent

The shared-phase work runs ONCE per business per phase per input. Both runs see the same results.

## Hash strategy

The dedup key uses SHA-256 hex per `data_layer_conventions_policy`. Canonical JSON input per the same convention. Same input always produces the same dedup key.

`input_signature` for CLASSIFICATION:

```sql
-- The hash of the sorted-by-id list of transactions in the period
SELECT encode(
  digest(
    string_agg(transaction_id::text, ',' ORDER BY transaction_id),
    'sha256'
  ),
  'hex'
)
FROM transactions
WHERE statement_upload_id = $upload_id
  AND business_id = $business_id;
```

If the transaction set differs (e.g., one upload produced 50 transactions, another produced 51), the dedup keys differ; cached results don't apply.

## Retention of shared-phase results

Per `tool_invocations` retention: cached results live for the lifetime of the workflow runs that reference them, plus a 30-day grace period. After both runs complete, the cache entry is purged per `retention_policies_schema`.

This means: a re-trigger of the same workflow against the same statement upload (rare, but possible via operator manual_trigger) within the grace period finds the cached results and runs INSTANTLY without re-classifying.

Beyond 30 days: the dedup cache expires; a re-trigger re-classifies.

## Audit shape

Per Block 03 Phase 06 + Phase 07:

```ts
emitAudit("WORKFLOW_TOOL_INVOKED", {
  workflow_run_id,
  tool_name: "classification.classify_transaction",
  dedup_key,
  cache_hit: boolean,                              // true on the second invocation
  ai_tier_dispatched: "NONE" | "LOCAL" | "EXTERNAL"
});
```

Per `audit_log_policies` aggregation: per-row classification events aggregate to one event per phase per run.

The `cache_hit = true` on the second run's invocation tells operators the work was deduplicated.

## Concurrency edge cases

| Case | Behavior |
| --- | --- |
| Both runs start concurrently; both reach INGESTION at the same nanosecond | Advisory lock serializes; first wins; second cache-hits |
| First run fails INGESTION (e.g., parser error); second run also tries | Both fail with the same error; the per-run failure is recorded; no infinite loop |
| First run completes INGESTION; second run starts much later (e.g., 2 days later due to manual trigger) | Within 30-day grace period: cache-hits; beyond: re-runs |

## Failure isolation

A failure in a shared-phase invocation propagates to BOTH runs that share it. They both fail, both get the same failure_class. Per Block 03 Phase 08's retry policy: transient failures retry; permanent failures halt both runs.

This is intentional — the failure is real (the underlying data couldn't be processed), and both directions need to see the failure.

## Coordination failure mode

If two runs attempt to advance the same shared phase simultaneously without the advisory lock being respected (e.g., two replicas of the workflow engine start at the same nanosecond before lock acquisition), the dedup_key constraint on `tool_invocations` acts as a secondary guard: only one invocation with the same `(dedup_key, workflow_run_id)` pair can be committed. The second insert fails with a unique-constraint violation, which the engine catches and treats as a cache-hit (the result already exists). This ensures correctness even under lock-bypass edge cases.

A coordination failure that produces divergent phase results (two different ingestion passes producing different transaction sets for the same upload) is detectable: the CLASSIFICATION dedup key is computed over the transaction ID list; if the two INGESTION runs produced different sets, their downstream CLASSIFICATION dedup keys would differ. This scenario is caught by the `WORKFLOW_PHASE_COORDINATION_MISMATCH` audit event (BLOCKING), which halts both runs and raises an operator alert.

## Cross-references

- `tool_naming_convention_policy` — dedup_key construction
- `data_layer_conventions_policy` — SHA-256 + canonical JSON
- `phase_execution_locking_policy` (consolidated) — advisory lock
- `workflow_phase_states_schema` — phase state machine; terminal states; coordination state columns
- `audit_log_policies` — `WORKFLOW_TOOL_*` events
- `out_adjustment_policies` (consolidated) — adjustment runs do NOT share with monthly
- `filter_rule_type_direction_table` — separation point (filter is direction-specific)
- `retention_policies_schema` — tool_invocations retention
- Block 03 Phase 03 — tool registration + dedup_key column
- Block 03 Phase 06 — phase execution engine
- Block 03 Phase 07 — resumability + idempotency
- Block 07 Phase 09 — event-driven workflow trigger (the entry point that creates both runs)
- Block 12 Phase 04 — OUT/IN parallel coordination (architecture)
- Stage 1 decision — OUT/IN in parallel after shared phases
