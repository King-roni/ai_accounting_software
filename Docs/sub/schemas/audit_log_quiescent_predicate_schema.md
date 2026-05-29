# audit_log_quiescent_predicate_schema

**Category:** Schemas · **Owning block:** 15 — Finalization & Secure Archive · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The exact definition of the eighth Phase 02 precondition gate, `engine.gate_audit_log_quiescent`. The gate guards finalization from racing with in-flight audit emissions for the same run — at the moment finalization commits, every upstream phase's audit events must already be on the chain.

This sub-doc pins the SQL predicate, the failure semantics, the integration with `tool_hash_chain_append`, and clarifies what the gate is NOT responsible for: chain-integrity verification is Block 05 Phase 03's concern, not this gate's.

---

## What "quiescent" means in this context

The audit subsystem is **quiescent for `workflow_run_id = $run`** when both:

1. **Audit subsystem reachable** — Block 05 Phase 02's `emitAudit()` connectivity probe returns OK (the chain-heads table is reachable; the chain-append tool can acquire a row lock)
2. **No pending audit appends for this run within the settle window** — no `audit_log` row for `workflow_run_id = $run` has been written in the last **5 seconds** (the Stage 1 canonical settle window per Block 15 Phase 02 scan)

The 5-second settle window is the Stage 1 default. The predicate shape is pinned; the numeric value may be tuned per Block 15 Phase 02 scan output but is bounded to `[1s, 30s]` per `audit_log_policies` chain throughput targets.

## Why this gate exists

Block 15's lock sequence emits `FINALIZATION_LOCK_COMMITTED` and `ARCHIVE_PROMOTION_COMPLETED` in a separate short transaction per the 2026-05-08 amendment. If an upstream phase (Block 11 ledger preparation, Block 14 review-issue resolution) is still flushing audit emissions for this run when the lock sequence starts, those audit events would arrive AFTER the commit event — confusing forensic readers who walk the chain expecting `FINALIZATION_LOCK_COMMITTED` to be the last event for the run.

The gate enforces emission-quiescence at run scope. **It does not verify chain integrity** — chain integrity is a global property managed by Block 05 Phase 03's RFC 3161 anchor + Block 05 Phase 07's periodic verification pass. Per Block 15 Phase 02's clarification: "the audit chain itself is global (not per-run), so no per-run chain check is required."

## SQL predicate

```sql
WITH subsystem_reachable AS (
  -- Block 05 Phase 02's connectivity probe: can we acquire a row lock
  -- on chain_heads for the business chain? A 100ms timeout on this
  -- statement means "yes, OK"; a timeout means subsystem stalled.
  SELECT EXISTS (
    SELECT 1
    FROM chain_heads
    WHERE chain_id = format('business:%s', $business_id)
    FOR SHARE NOWAIT                                    -- non-blocking lock probe
  ) AS reachable
),
recent_appends AS (
  SELECT EXISTS (
    SELECT 1
    FROM audit_log
    WHERE business_id = $business_id
      AND event_payload->>'workflow_run_id' = $workflow_run_id::text
      AND event_time > (now() - interval '5 seconds')
  ) AS has_recent
)
SELECT
  CASE
    WHEN NOT (SELECT reachable FROM subsystem_reachable) THEN 'HOLD_UNREACHABLE'
    WHEN (SELECT has_recent FROM recent_appends) THEN 'HOLD_PENDING'
    ELSE 'PASS'
  END AS gate_decision;
```

Returns `'PASS'` | `'HOLD_UNREACHABLE'` | `'HOLD_PENDING'`. The gate wrapper translates this into the canonical `GateResult` shape.

## Predicate breakdown

### `subsystem_reachable`

`FOR SHARE NOWAIT` attempts a non-blocking shared lock on the business chain's `chain_heads` row. Three outcomes:

| Outcome | Meaning |
| --- | --- |
| Lock acquired | Chain head is reachable; another writer may hold an EXCLUSIVE lock briefly but releases it quickly — the SHARE lock will wait at most milliseconds |
| `lock_not_available` error (NOWAIT) | Another writer is holding the chain head EXCLUSIVE — typically `tool_hash_chain_append` mid-append; we treat this as transient and re-evaluate |
| Connection error / timeout | Block 05's audit subsystem is unreachable — `HOLD_UNREACHABLE` |

Per `tool_hash_chain_append`: row-lock contention is bounded (single chain, single locker at a time). The non-blocking probe gives an honest answer in < 10 ms.

### `recent_appends`

The 5-second settle window. Reads via the `audit_log` index on `(business_id, event_time)` per `audit_log_policies`. Adds a payload filter on `workflow_run_id` to scope to this run.

A canonical Stage 1 commitment: upstream phases that emit audit events for the run flush within < 5 seconds of completing. A still-emitting upstream is a defect — the gate's HOLD is informational, not blocking forever.

Index choice: the predicate uses the existing `(business_id, event_time)` index; the payload filter is applied as a residual filter on the small range scan. Adding a generated column index on `(business_id, (event_payload->>'workflow_run_id'), event_time)` is deferred to Stage 2+ if profiling shows the residual filter is hot.

## `GateResult` translation

Per `tool_gate_function_signature`: the gate returns the canonical `GateResult` shape.

| Predicate result | `GateResult` |
| --- | --- |
| `'PASS'` | `{ decision: "PASS" }` |
| `'HOLD_UNREACHABLE'` | `{ decision: "HOLD", hold_reason: "Audit subsystem unreachable", severity: "HIGH", review_issue_type: "finalization.audit_log_subsystem_unreachable" }` |
| `'HOLD_PENDING'` | `{ decision: "HOLD", hold_reason: "Audit emissions pending; retry after settle window", severity: "MEDIUM", review_issue_type: "finalization.audit_log_pending_writes" }` |

`HOLD_PENDING` is `MEDIUM` severity because the condition is expected to clear on its own within seconds — the lock sequence's auto-retry per `lock_sequence_policies` typically resolves it without surfacing a review issue. The review issue only persists if the second retry also fails.

`HOLD_UNREACHABLE` is `HIGH` severity because audit-subsystem failure is an infrastructure-class problem that needs operator attention.

Neither holds at `BLOCKING` — the gate is recoverable and should not lock the user out of finalization permanently.

## Failure path

```
1. Gate evaluates → returns HOLD_PENDING or HOLD_UNREACHABLE
2. Lock-sequence policy applies auto-retry-once per lock_sequence_policies:
   - 5-second backoff
   - Re-invoke the composite gate
3. Second evaluation → if PASS, lock sequence proceeds
4. Second evaluation → if HOLD persists:
   - Run remains in AWAITING_APPROVAL
   - Review issue raised per review_issue_type above
   - User intervention required
```

Per the 2026-05-08 amendment: even if the operational transaction succeeds but audit emission fails, Block 03 Phase 07's resumability catches the gap with `FINALIZATION_LOCK_AUDIT_RECOVERED` — that mechanism is distinct from this gate's quiescence check.

## What this gate is NOT

Three explicit non-responsibilities:

1. **NOT chain-integrity verification.** Walking the hash chain to verify `chain_hash = sha256(prev || payload)` for every event in the run is Block 05 Phase 07's periodic background pass — invoked independently of any gate. This gate only checks emission-quiescence at run scope.

2. **NOT RFC 3161 anchor verification.** Anchor verification is Block 15 Phase 07's pre-read verification — fires on archive READs, not on finalization WRITES.

3. **NOT a guarantee of chain head equality across replicas.** Replica lag is handled by `audit_log_policies` Section 4 "Lock semantics" — the gate runs on the primary; replicas converge after commit.

These three concerns are SEPARATE gates / pipelines owned by Block 05. The audit-log-quiescent gate is a narrow check on "are upstream emissions flushed".

## Integration with `tool_hash_chain_append`

The gate consumes `tool_hash_chain_append`'s output observationally — it reads what the tool has written to `audit_log` and `chain_heads`. It does NOT call `tool_hash_chain_append`; gates are `READ_ONLY` per `tool_gate_function_signature`.

The relationship:

| Component | Role |
| --- | --- |
| `tool_hash_chain_append` | Writes audit events; locks `chain_heads` row briefly |
| `audit_log_quiescent` gate | Reads `chain_heads` (non-blocking lock probe) + `audit_log` (settle-window scan) |
| Block 05 Phase 03 | Walks `audit_log` to verify hash chain integrity |
| Block 05 Phase 07 | Periodic chain-integrity sweep + RFC 3161 anchor refresh |

This gate's coupling to the chain primitive is minimal — only the connectivity probe.

## Mobile rejection

The gate runs server-side as part of the composite precondition evaluation. The triggering API — `archive.finalize_period` / `archive.adjustment_finalize` — rejects `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints` before the gate ever evaluates. The gate itself does not check the form factor; the rejection happens at the edge.

## Audit events

| Event | Trigger |
| --- | --- |
| `FINALIZATION_PRECONDITION_EVALUATED` | Per evaluation (existing in taxonomy) |
| `FINALIZATION_PRECONDITION_FAILED` | Per `HOLD` decision (existing in taxonomy) |
| `FINALIZATION_AUDIT_LOG_QUIESCENT_EVALUATED` | Per evaluation with the resolved predicate value |
| `FINALIZATION_AUDIT_LOG_QUIESCENT_HOLD` | Per `HOLD` specifically — distinguishes "unreachable" vs "pending" via payload |
| `WORKFLOW_GATE_PASSED` / `WORKFLOW_GATE_HOLD` / `WORKFLOW_GATE_TIMEOUT` | Standard gate-framework emissions |

The `FINALIZATION_AUDIT_LOG_QUIESCENT_*` events provide forensic granularity beyond the generic `FINALIZATION_PRECONDITION_*` pair — they let an operator answer "exactly which case of the audit-quiescence check failed" without parsing the generic payload.

## Performance budget

Per `tool_gate_function_signature` and `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Connectivity probe (`FOR SHARE NOWAIT`) | 1 ms | 5 ms | 30 ms |
| Settle-window scan | 5 ms | 30 ms | 100 ms |
| Total gate evaluation | 10 ms | 50 ms | 200 ms |
| Adversarial cap | — | — | 30 s (gate timeout) |

The gate is comfortably within the 1-second composite-gate target.

## Idempotency

The gate is idempotent — same inputs → same `GateResult`. Two consecutive evaluations 5 seconds apart will return the same answer unless an audit emission lands in between. This is the desired property — the gate is a polling predicate, not a state-changing operation.

## Cross-references

- `tool_hash_chain_append` — chain primitive observed by this gate
- `audit_log_policies` — chain partitioning + RLS + settle-window framing
- `lock_sequence_policies` — what runs after this gate passes; auto-retry semantics
- `tool_gate_function_signature` — gate framework contract; `READ_ONLY` declaration
- `data_layer_conventions_policy` — canonical JSON for audit payloads; UUID v7 for `chain_id` resolution
- `audit_event_taxonomy` — event catalogue (existing + new entries)
- `severity_enum` — `{HIGH, MEDIUM}` predicate values
- `mobile_write_rejection_endpoints` — edge-level mobile rejection on the triggering API
- Block 15 Phase 02 — owner of the 8 baseline preconditions; this gate is gate 8
- Block 05 Phase 02 — `emitAudit()` + chain-heads schema
- Block 05 Phase 03 — chain-integrity verification (NOT this gate's responsibility)
- Block 05 Phase 07 — periodic chain sweep + RFC 3161 refresh
- Block 03 Phase 05 — gate evaluation framework
- Block 03 Phase 07 — resumability + `FINALIZATION_LOCK_AUDIT_RECOVERED`
- 2026-05-08 decisions-log amendment — audit emit as separate transaction
