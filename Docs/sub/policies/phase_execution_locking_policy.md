# phase_execution_locking_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The locking contract that serialises operations against a single `workflow_run`. The workflow engine relies on TWO complementary lock primitives — Postgres advisory locks and row-level locks (`SELECT … FOR UPDATE`) — picked deliberately for different scopes. This policy pins which primitive is used where, the lock-key derivation, the serialisation guarantees, deadlock-avoidance ordering, and the test fixtures that exercise contention.

The policy is referenced from `tool_gate_function_signature` (concurrent gate evaluation), `gate_composition_policy` (composition layer rationale), `gate_throws_semantics_policy` (retry catch site), `tool_invoice_lifecycle_integration` (mid-run write serialisation), `shared_phase_coordination_policy` (cross-run advancement), and `trigger_events_processed_schema` (idempotent trigger processing). Any addition to those consumers' lock semantics must round-trip through this policy.

---

## Two-tier lock model

| Primitive | Scope | Use case | Lifetime |
| --- | --- | --- | --- |
| `pg_advisory_xact_lock(bigint)` | Logical lock keyed on a run | Cross-statement serialisation of engine operations on the same run (gate evaluation, advancement, status transitions) | Released at transaction commit / rollback |
| `SELECT … FOR UPDATE` on `workflow_runs` row | Physical row lock | Atomic single-statement updates inside a transaction | Released at transaction commit / rollback |
| `pg_advisory_lock(bigint)` (session-scoped) | NOT USED | — | — |

**Advisory locks** carry no physical row associated with them — they are pure logical locks scoped to the transaction. This makes them ideal for serialising multi-statement engine operations that don't always end with the same row update.

**Row locks** are acquired implicitly when the engine reads the run row with `FOR UPDATE` at the top of a phase boundary; they prevent another transaction from updating the same row mid-boundary.

The engine ALWAYS uses the transactional variant (`pg_advisory_xact_lock`) and never the session-scoped variant. Session-scoped advisory locks survive transaction rollback and are dangerous in pooled-connection environments — a leaked lock can block the run indefinitely. Per the project convention recorded in CLAUDE.md guidance, the engine only uses the `(bigint)` overload (NOT `(bigint, bigint)` — that signature does not exist).

## Advisory lock key derivation

A run's advisory lock key is a stable bigint derived from the run UUID:

```sql
CREATE OR REPLACE FUNCTION engine.run_lock_key(p_run_id uuid)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT ('x' || substr(md5(p_run_id::text), 1, 16))::bit(64)::bigint
$$;
```

Properties:

1. **Deterministic** — same `run_id` always yields the same key. Two transactions trying to lock the same run reach the same bigint and contend correctly.
2. **Collision rate** — 64-bit truncation of MD5 (chosen for speed, not cryptographic strength). Probability of two distinct run_ids hashing to the same key is ~2⁻³² across the whole system. The engine treats this as acceptable: a collision causes false serialisation (slower, never incorrect).
3. **Per-namespace** — the engine does NOT use `pg_advisory_xact_lock(int, int)` with a key class. Future namespaces (e.g., per-business locks) would use a different keying function with a separate name; key collisions across functions are not a concern because the bigint space is shared but the workload patterns make actual contention negligible.

Lock acquisition is always:

```sql
SELECT pg_advisory_xact_lock(engine.run_lock_key($run_id));
```

Block 03 Phase 06's `engine.advanceRun` is the canonical caller. Block 03 Phase 04's `transitionRun` re-uses the same key when called outside a `advanceRun` transaction (e.g., user-initiated approval finalization in Block 15).

## Where each primitive is used

| Operation | Primitive | Rationale |
| --- | --- | --- |
| `engine.advanceRun(run_id)` | Advisory lock on run | Multi-statement boundary execution; row lock alone wouldn't cover the inter-statement window |
| `engine.evaluateGates(...)` | Inherits caller's advisory lock | No separate lock; gate evaluation always runs within `advanceRun`'s transaction |
| `engine.invokeTool(...)` | Inherits caller's advisory lock | Same — tool dispatch is inside `advanceRun` |
| `transitionRun(run_id, …)` from Block 15 (finalize) | Advisory lock on run | Same run, separate caller |
| Status-only row update inside a single statement | `SELECT … FOR UPDATE` on `workflow_runs` | Single-statement atomicity is enough; advisory lock adds no value |
| Side-phase entry counter increment | Advisory lock (held by parent advanceRun) + `UPDATE … RETURNING` | Counter increment is within the parent's already-held lock |
| Trigger-engine processing of `trigger_events_processed` row | Advisory lock keyed on `(event_id, business_id)` | Different namespace key per `trigger_events_processed_schema`; not the per-run key |
| Audit-event emission via `audit.emit_audit` | None (audit table is append-only; uses sequence-based ordering) | Audit emission is intentionally lock-free |

The advisory lock is taken FIRST, before any row reads, to avoid a deadlock pattern where two concurrent `advanceRun` calls each acquire row locks for different runs and then try to acquire each other's advisory locks. Lock ordering: advisory ⇒ row.

## Serialisation guarantees

Under this policy:

1. **At most one `engine.advanceRun` per `run_id`** executes at a time. Concurrent callers serialise on the advisory lock. The second caller waits, then re-reads run state from scratch (which may now show the run has advanced; the second `advanceRun` becomes a no-op per `phase_execution_loop_policy`'s idempotent re-entry rule).
2. **At most one `transitionRun` per `run_id`** executes at a time, even when called from outside `advanceRun` (e.g., approval finalization).
3. **Gate evaluation against the same run** is serialised within the caller's transaction — two parallel gates for the same run cannot interleave.
4. **Different runs do not contend.** A 5,000-run system has 5,000 independent advisory keys.
5. **Status reads are non-blocking** — `SELECT` against `workflow_runs` without `FOR UPDATE` does not contend with the advisory lock. The progress API (`engine.getRunProgress`) reads with no lock.

## Lock-acquisition timeout

By default, `pg_advisory_xact_lock` waits indefinitely. The engine sets a transaction-scoped `lock_timeout` before acquiring:

```sql
BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT pg_advisory_xact_lock(engine.run_lock_key($run_id));
-- ... boundary work ...
COMMIT;
```

If the lock is not acquired within 5 seconds, Postgres raises `55P03` (`lock_not_available`). The engine treats this as a `LOCK_BUSY` retryable error and applies the retry policy from Block 03 Phase 08 (default `N=3` retries with backoff). After retry exhaustion, the error becomes a `HOLD` with severity HIGH and `review_issue_type = ENGINE_LOCK_CONTENTION`.

The 5-second budget is generous — a normal boundary completes in <1 second. The budget covers slow-IO scenarios (cold-cache reads from large tables) where the prior holder legitimately needed extra time.

## Deadlock avoidance

The engine acquires locks in deterministic order:

1. Advisory lock on `run_id` (first).
2. `SELECT … FOR UPDATE` on `workflow_runs` row (second; implicit through the engine's read).
3. `SELECT … FOR UPDATE` on `workflow_phase_states` row (third, if needed).
4. Row locks on operational tables (`transactions`, `match_records`, etc.) — fourth; their acquisition order is controlled by the tool currently invoked, not by the engine itself.

Cross-run operations (rare — only side-phase + shared-phase coordination per `shared_phase_coordination_policy`) acquire advisory locks in ascending UUID order to avoid the classic A→B / B→A deadlock cycle. The shared-phase coordinator code reorders run IDs before locking.

## Audit shape

The engine emits `WORKFLOW_RUN_LOCK_ACQUIRED` (severity LOW, internal-only) on lock acquisition and `WORKFLOW_RUN_LOCK_TIMEOUT` (severity HIGH) on `55P03` exhaustion after retry. These events join via `workflow_run_id` and `attempt_number` (1-indexed per `gate_throws_semantics_policy`'s retry pattern).

Lock-timeout events are visible to operations (ops dashboard) and aggregated for alerting per `cross_tenant_alerting_runbook` — sustained lock-timeout rate above 1% indicates contention pathology and warrants investigation.

## Testing fixtures

The Block 03 test suite covers:

| Fixture | Asserts |
| --- | --- |
| Two parallel `advanceRun(same_id)` callers | Second waits, then sees the run already advanced and no-ops |
| Two parallel `advanceRun(different_id)` callers | Both proceed independently |
| Killed transaction holding advisory lock | Lock released at rollback; next caller proceeds within the 5-second budget |
| Lock-timeout simulation (lock held >5s) | Caller sees `55P03`; retry budget consumed; emits `WORKFLOW_RUN_LOCK_TIMEOUT` |
| Cross-run shared phase lock ordering | UUIDs acquired in ascending order; no deadlock under randomized stress |

Race condition tests live in BOOK-320 (B03·P10·SD Race condition test fixture); this policy is the source of truth for the locking semantics they exercise.

## Cross-block contract

- **Block 03 Phase 04** (`transitionRun`) uses the same advisory lock key as `advanceRun` so user-initiated transitions serialise against engine-initiated ones.
- **Block 03 Phase 10** (concurrency control) extends this policy for cross-run advisory locks (shared phases between OUT+IN); see `shared_phase_coordination_policy`.
- **Block 12 + Block 13** tool implementations MUST NOT acquire advisory locks directly — all locking goes through the engine. Tools that need cross-row serialisation use row locks on operational tables only.
- **Block 15** (finalize) uses the same lock when invoking `transitionRun(AWAITING_APPROVAL → FINALIZING → FINALIZED)`.

## Cross-references

- `tool_gate_function_signature` — concurrent gate evaluation guarantee (per-run advisory lock)
- `gate_composition_policy` — composition layer relies on the advisory lock being already held
- `gate_throws_semantics_policy` — retry-exhaustion path for `LOCK_BUSY` (`55P03`)
- `shared_phase_coordination_policy` — cross-run lock ordering for shared phases
- `trigger_events_processed_schema` — different advisory-lock namespace for trigger processing
- `tool_invoice_lifecycle_integration` — mid-run write serialisation via the run advisory lock
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_RUN_LOCK_*` event shapes
- `cross_tenant_alerting_runbook` — ops alert thresholds on lock-timeout rate
- Block 03 Phase 04 — `transitionRun` re-uses the lock key
- Block 03 Phase 06 — `engine.advanceRun` canonical caller
- Block 03 Phase 08 — retry constants for `LOCK_BUSY`
- Block 03 Phase 10 — cross-run extensions
- Block 15 — finalize transition uses the lock
