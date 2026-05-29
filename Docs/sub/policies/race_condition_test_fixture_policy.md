# race_condition_test_fixture_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owner:** 05 — Security & Audit (test infrastructure) · **Stage:** 4 sub-doc (Layer 2)

The contract for deterministically reproducing trigger / concurrency / advisory-lock races in CI. Race conditions are inherently non-deterministic in production, but CI assertions must be reliable — flaky tests are worse than no tests. This policy pins the harness primitives, the canonical fixture set covering every documented race in `out_run_concurrency_policy`, `shared_phase_coordination_policy`, `phase_execution_locking_policy`, and `gate_throws_semantics_policy`, and the CI integration contract.

---

## What makes a race test deterministic

A flaky race test is one whose pass/fail depends on OS scheduler timing. To eliminate that dependency, every fixture in this policy uses ONE of three deterministic synchronisation primitives:

| Primitive | Used for | Mechanism |
| --- | --- | --- |
| **Postgres advisory lock barrier** | Force two transactions to arrive at the same boundary | Test acquires an external advisory lock; both transactions block on it; test releases atomically; both proceed |
| **Statement-timeout injection** | Reproduce slow-IO / lock-timeout paths | `SET LOCAL statement_timeout = '5s'` + `SELECT pg_sleep(6)` |
| **Custom GUC barrier** | Synchronise non-DB code (e.g., gate evaluation throw paths) | `app.test_barrier_<name>` GUC checked by test-hook in code; test toggles between values |

Tests NEVER rely on `pg_sleep` for synchronisation — sleeping is only used to provoke timeouts. Tests NEVER use OS-thread sleeps to wait for a peer transaction; they always join via Postgres advisory locks.

The harness lives at `tests/fixtures/race_conditions/` and is imported by every CI race test.

## Harness primitives

```ts
// tests/fixtures/race_conditions/barrier.ts

export class RaceBarrier {
  constructor(private name: string, private participantCount: number) {}

  // Each participant calls this. The Nth participant unblocks all N.
  async arriveAndWait(connection: PoolClient): Promise<void> {
    await connection.query(
      `SELECT engine.test_barrier_arrive($1, $2)`,
      [this.name, this.participantCount]
    );
    // SECURITY DEFINER function blocks on advisory lock until count is reached
  }
}
```

Server-side `engine.test_barrier_arrive(name, expected_count)`:

1. Increments a counter in `test_race_barriers` table.
2. If counter < `expected_count`: waits on advisory lock keyed on `name`.
3. If counter == `expected_count`: releases the advisory lock.

The function is `SECURITY DEFINER` and only callable in `engine.test_role` (CI environment) — production roles lack the grant.

Cleanup happens after each test via `engine.test_barrier_reset()` which truncates the table.

## Canonical fixtures (the binding set)

Every concurrency claim in B03's policies has at least one fixture below. CI fails if any fixture is removed or weakened.

### Fixture R1 — Simultaneous OUT_MONTHLY triggers

Asserts `out_run_concurrency_policy` §1 + §2.

```ts
await Promise.all([
  txn1.connect(),
  txn2.connect()
]);

const barrier = new RaceBarrier('R1_pre_create', 2);

await Promise.all([
  (async () => {
    await txn1.query('BEGIN');
    await barrier.arriveAndWait(txn1);                          // wait for both arrived
    return engine.create_run(txn1, { business_id, type: 'OUT_MONTHLY', period_start: '2026-04-01' });
  })(),
  (async () => {
    await txn2.query('BEGIN');
    await barrier.arriveAndWait(txn2);                          // unblock both
    return engine.create_run(txn2, { business_id, type: 'OUT_MONTHLY', period_start: '2026-04-01' });
  })()
]).then(results => {
  // Exactly one success, exactly one OUT_WORKFLOW_RUN_ALREADY_ACTIVE
  expect(results.filter(r => r.success).length).toBe(1);
  expect(results.filter(r => r.error_code === 'OUT_WORKFLOW_RUN_ALREADY_ACTIVE').length).toBe(1);
});
```

The barrier ensures both `create_run` calls execute their concurrency check at the same logical time. The advisory lock from §2 of `out_run_concurrency_policy` serialises them; the second sees the row the first wrote.

### Fixture R2 — OUT_ADJUSTMENT during active OUT_MONTHLY

Asserts `out_run_concurrency_policy` §4 (adjustment exemption).

Pre-condition: an `OUT_MONTHLY` run for `(business_id, '2026-04-01')` is in `RUNNING` state.

Action: trigger `OUT_ADJUSTMENT` for `(business_id, '2026-03-01')` (previous finalized period).

Assertion: succeeds. No `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` error.

No barrier needed; this is a sequential test of policy correctness.

### Fixture R3 — Double OUT_ADJUSTMENT, same period

Asserts `out_run_concurrency_policy` §4 conjunct (concurrent adjustments against same period rejected).

```ts
const barrier = new RaceBarrier('R3_pre_create', 2);

// Both transactions target the same finalized period
const results = await Promise.all([
  triggerAdjustment(txn1, period: '2026-03-01', barrier),
  triggerAdjustment(txn2, period: '2026-03-01', barrier)
]);

// Exactly one succeeds; the other gets adjustment-specific concurrent-blocking error
expect(results.filter(r => r.success).length).toBe(1);
expect(results.filter(r => r.error_code === 'OUT_ADJUSTMENT_PERIOD_BUSY').length).toBe(1);
```

### Fixture R4 — Paired OUT + IN trigger, shared-phase dedup

Asserts `shared_phase_coordination_policy` §3 (8-step ordering).

```ts
// Both runs created in same tx via event-triggered path
const barrier = new RaceBarrier('R4_ingestion', 2);

const [outRun, inRun] = await createPairedRuns(event_id);

await Promise.all([
  advanceRunToINGESTION(outRun, barrier),
  advanceRunToINGESTION(inRun, barrier)
]);

// Only ONE tool_invocations row for the INGESTION dedup_key
const rows = await db.query(
  `SELECT * FROM tool_invocations
   WHERE business_id = $1
     AND tool_name = 'intake.parse_statement'
     AND status = 'SUCCESS'`,
  [business_id]
);

expect(rows.length).toBe(1);

// Both runs see the shared dedup_key result
expect(getRunPhaseResult(outRun, 'INGESTION')).toEqual(getRunPhaseResult(inRun, 'INGESTION'));
```

This fixture exercises the dedup-key sharing across paired runs — the second run's INGESTION invocation cache-hits on the first run's result.

### Fixture R5 — Advisory lock timeout

Asserts `phase_execution_locking_policy` §5 (5s lock_timeout → LOCK_BUSY).

```ts
// Hold the lock externally for 10s
const holderConn = await pool.connect();
await holderConn.query('BEGIN');
await holderConn.query(
  `SELECT pg_advisory_xact_lock(engine.run_lock_key($1))`,
  [run_id]
);

// Now attempt advanceRun; should timeout after 5s
const start = Date.now();
const result = await engine.advanceRun(run_id);
const elapsed_ms = Date.now() - start;

expect(elapsed_ms).toBeGreaterThanOrEqual(5000);
expect(elapsed_ms).toBeLessThan(7000);                          // Should not exceed 5s + retry budget overhead
expect(result.error_class).toBe('TRANSIENT_NETWORK');           // 55P03 → LOCK_BUSY → TRANSIENT_NETWORK per error_classification_policy
expect(result.attempt_count).toBe(3);                            // Standard retry budget per retry_policy §2

await holderConn.query('ROLLBACK');                              // release for cleanup
```

This fixture uses real timing (the 5s timeout is a real clock) but asserts a bounded range so OS-scheduler jitter doesn't cause flakes.

### Fixture R6 — Gate-throw retry race

Asserts `gate_throws_semantics_policy` §3 + `retry_policy` §2.

Uses a custom GUC barrier: gate handler checks `app.test_barrier_R6_attempt` and throws `DatabaseError` on attempts 1+2, succeeds on attempt 3. Asserts:

- 2 `WORKFLOW_GATE_THREW` events emitted (LOW)
- 1 `WORKFLOW_GATE_PASSED` event emitted (LOW) — eventual success
- Phase advances normally; no review issue raised
- `boundary_eval_id` unique to this evaluation; shared across the 2 throw events + 1 pass event

```ts
await db.query(`SET LOCAL app.test_barrier_R6_attempt = '0'`);
await engine.advanceRun(run_id);

const events = await db.query(
  `SELECT event_kind, attempt_number FROM audit.audit_events
   WHERE boundary_eval_id = (
     SELECT boundary_eval_id FROM audit.audit_events
     WHERE workflow_run_id = $1
       AND event_kind LIKE 'WORKFLOW_GATE_%'
     ORDER BY emitted_at DESC LIMIT 1
   )
   ORDER BY emitted_at ASC`,
  [run_id]
);

expect(events).toEqual([
  { event_kind: 'WORKFLOW_GATE_THREW', attempt_number: 1 },
  { event_kind: 'WORKFLOW_GATE_THREW', attempt_number: 2 },
  { event_kind: 'WORKFLOW_GATE_PASSED', attempt_number: 3 }
]);
```

### Fixture R7 — Cross-run shared phase deadlock avoidance

Asserts `phase_execution_locking_policy` §6 (cross-run UUID-ascending lock acquisition).

Two paired runs (A, B with A.id < B.id) both reaching a shared phase from opposite directions. Even if scheduled to acquire locks in B → A order at the application level, the engine's `_acquire_cross_run_locks(...)` helper sorts UUIDs ascending before acquiring. No deadlock.

```ts
const [runA, runB] = await createPairedRuns(event_id);
expect(uuidCompare(runA.id, runB.id)).toBeLessThan(0);          // A.id < B.id by paired-creation invariant

// Both try to advance the shared phase from opposite directions
await Promise.all([
  engine.acquireCrossRunLocks([runB.id, runA.id]),               // requested in B,A order
  engine.acquireCrossRunLocks([runA.id, runB.id])                // requested in A,B order
]);

// Both succeed; engine sorted internally; no deadlock
```

## Test data structure

Each fixture lives at `tests/fixtures/race_conditions/r<N>_<descriptor>.test.ts`. The fixture imports:

- `RaceBarrier` from the harness
- `engine.test_role` connection from the CI pool
- `tests/fixtures/test_factories.ts` for `createBusinessEntity`, `createWorkflowRun`, etc.

Pre-conditions are set up in `beforeEach`; the barrier is reset in `afterEach`.

## CI integration

Race tests run in a dedicated CI job named `engine-race`:

- Database is fresh (migrations applied; no seed data beyond what fixtures create).
- `engine.test_role` is granted (CI-only; production roles do not have this grant).
- `app.test_mode = 'true'` GUC is set at session start; engine code respects this to enable the test-barrier code paths.
- Job runs with `--maxWorkers=1` to prevent fixtures from contending with each other (they share `business_id` namespaces).
- Failure of any race fixture is a CI block — no merge.

The `engine-race` job is separate from the unit-test job because:
1. It needs the test_role grant + GUC
2. It is serialised (no parallelism) — slower
3. Failures here indicate concurrency-policy regressions, not unit bugs

## Anti-flakes guidance

If a race fixture starts flaking:

1. **Check timing assertions** — fixtures use bounded ranges (e.g., `>=5000 && <7000`); too-tight ranges cause flakes on slow CI runners.
2. **Check barrier participant count** — if a fixture's barrier waits for N=2 but only 1 participant arrives (due to a bug in the fixture, not the engine), the test hangs. Use Jest's `testTimeout: 30s` to fail rather than hang.
3. **Check connection-pool exhaustion** — race fixtures hold N connections; CI pool size must be >= max(fixture connections) + 5 for the test infrastructure.
4. **Never disable a flaky race fixture without root-cause analysis** — the flake is signal, not noise. A race test that flakes 1% of the time may indicate a real 1%-of-the-time bug.

## Cross-block contract

- **Block 03 Phase 06** owns the engine code paths these fixtures exercise.
- **Block 03 Phase 10** owns the concurrency-rule + advisory-lock semantics being tested.
- **Block 05 (test infrastructure)** owns `engine.test_role` + `test_race_barriers` table + barrier RPC.
- **CI configuration** (Block 03 ops) maintains the `engine-race` job + serialisation requirement.

## Cross-references

- `out_run_concurrency_policy` — fixture R1, R2, R3 source policy
- `shared_phase_coordination_policy` — fixture R4 source policy
- `phase_execution_locking_policy` — fixtures R5, R7 source policy
- `gate_throws_semantics_policy` — fixture R6 source policy
- `retry_policy` — fixtures R5, R6 retry-budget assertions
- `error_classification_policy` — fixture R5 error-class mapping
- `dedup_key_generator_policy` — fixture R4 INGESTION dedup_key construction
- `phase_execution_loop_policy` — engine.advanceRun under test in multiple fixtures
- `test_factories` reference — common fixture helpers
- `audit_event_payload_schemas` (Stage-6 catalog) — `boundary_eval_id` field used by R6 assertions
- Block 03 Phase 06 / 10 — engine code paths
- Block 05 — test infrastructure ownership
- CI ops — `engine-race` job definition
