# Session End Handoff — 2026-05-28 (second long session)

**Date:** 2026-05-28 (second session — `b` suffix to distinguish from earlier same-day session)
**Stage:** Stage 3 (sub-doc backlog walk) — IN FLIGHT
**Cycles closed this session:** none (B02 + B10 already closed in prior 2026-05-28 session)
**Cycle in progress:** B03 (38/54 closed, 16 backlog remaining — opened at 26/54 / 28 backlog)
**Tickets closed across this session:** 12 (B03·P05 + B03·P06 + B03·P07 SD clusters)
**New canonical sub-docs authored:** 8 (all Layer 2 policies under `Docs/sub/policies/`)

Read this first on next session. Then load the project-meta drawer, then `retrieve_cycle` on Cycle B03.

---

## 1. What this session did

| Sub-cluster | Tickets closed | Sub-docs written | Cluster status |
|---|---|---|---|
| B03·P05 Gate evaluation | 4 (BOOK-272, 274, 278, 280) | 2 | ✅ Complete |
| B03·P06 Phase execution | 4 (BOOK-282, 284, 285, 287) | 4 | ✅ Complete |
| B03·P07 Resumability + idempotency | 4 (BOOK-290, 292, 294, 295) | 2 | ✅ Complete |

Per-ticket disposition:

- **BOOK-272** Gate function signature → VERIFY ✅ `tool_gate_function_signature.md`
- **BOOK-274** Gate composition → **WRITE** `gate_composition_policy.md`
- **BOOK-278** Side-phase routing → VERIFY ✅ `side_phase_routing_policy.md`
- **BOOK-280** Gate-throws semantics → **WRITE** `gate_throws_semantics_policy.md` (resolves drift)
- **BOOK-282** Execution loop → **WRITE** `phase_execution_loop_policy.md` (ASCII flow diagram)
- **BOOK-284** Progress query API → **WRITE** `engine_run_progress_api_policy.md`
- **BOOK-285** Locking strategy → **WRITE** `phase_execution_locking_policy.md` (closes 5× dangling ref)
- **BOOK-287** Estimated completion → **WRITE** `estimated_completion_heuristic_policy.md`
- **BOOK-290** Dedup-key generator → VERIFY ✅ `dedup_key_generator_policy.md`
- **BOOK-292** External request ID handling → **WRITE** `external_request_id_handling_policy.md`
- **BOOK-294** Crash recovery → **WRITE** `crash_recovery_policy.md` (complements `resumability_policy.md`)
- **BOOK-295** Tool atomicity pattern → VERIFY ✅ `tool_atomicity_policy.md`

---

## 2. New canonical sub-docs authored this session (8)

All under `Docs/sub/policies/`. Layer 2 cross-block policies.

1. **`gate_composition_policy.md`** (BOOK-274, ~140 lines) — `engine.evaluateGates` short-circuit semantics; gate ordering deterministic by declaration; parallel evaluation NOT supported in v1; introduces `boundary_eval_id uuid v7` as join key for composed gate-evaluation forensic reconstruction.

2. **`gate_throws_semantics_policy.md`** (BOOK-280, ~180 lines) — exception capture mechanism (TS code sketch); 3-stage severity progression (transient LOW → retry-exhaustion HIGH + BLOCKING HOLD); 11-field `WORKFLOW_GATE_THREW` payload; 4-row audience visibility table (Ops / Owner-Admin / Bookkeeper-Accountant / external audit); side-phase loop-protection forced-gate path (FORCED_PASS vs FORCED_HOLD). **Resolves drift** between phase doc (immediate HOLD+BLOCKING) and `tool_gate_function_signature` (retry then escalate) — retry layer sits between.

3. **`phase_execution_locking_policy.md`** (BOOK-285, ~160 lines) — two-tier lock model (`pg_advisory_xact_lock(bigint)` + `SELECT FOR UPDATE`); `engine.run_lock_key(uuid) RETURNS bigint IMMUTABLE` MD5-truncated; 5-second `lock_timeout`; deterministic acquisition order (advisory → row workflow_runs → row phase_states → operational); cross-run shared-phase locks acquired in ascending UUID order. **Closes pre-existing dangling reference** — file was referenced from 5 prior sub-docs but did not exist on disk; Pass-3 candidate `transaction_indexing_strategy.md` was wrong-topic.

4. **`estimated_completion_heuristic_policy.md`** (BOOK-287, ~150 lines) — P75 statistic (not median) over last 10 runs per (business, workflow_type); global fallback last 100 runs when business has &lt;3 history; cold-start defaults table (OUT_MONTHLY 4h / IN_MONTHLY 6h / OUT_ADJUSTMENT 2h / IN_ADJUSTMENT 3h); side-phase elapsed times excluded; NULL when user-blocked. Accuracy targets P50 ±25%, P75 ±50%, P95 asymmetric +100%/−50%. `WORKFLOW_RUN_ESTIMATE_UPDATED` audit with 4-value trigger enum.

5. **`engine_run_progress_api_policy.md`** (BOOK-284, ~150 lines) — `engine.fn_get_run_progress(uuid)` SECURITY DEFINER STABLE; runs as `engine.runtime_role` (BYPASSRLS=false); uniform `RUN_NOT_FOUND` for probing-resistance; full `RunProgress` TS type (current_phase / phases_completed / total_phases / blocking_issues_count / high_severity_issues_count / last_activity_at / estimated_completion / side_phase); Supabase Realtime channel `run_progress:<run_id>`; reads NOT audited (volume policy); `WORKFLOW_RUN_PROGRESS_ADMIN_READ` only for admin-tier reads.

6. **`phase_execution_loop_policy.md`** (BOOK-282, ~190 lines) — **ASCII flow diagram** for `engine.advanceRun` with 15 numbered steps and 3 error edges (E1 HOLD, E2 ROUTE_TO_SIDE_PHASE, E3 FATAL tool failure); transaction boundaries (one tx per phase boundary); idempotent re-entry rules (4-row state table); error-edge handling (lock timeout / gate throws / tool fatal / mid-boundary crash / side-phase loop); audit event sequence per boundary type; state-produced table; `engine.advance_run_max_boundaries=8` recursion cap with process-level yield.

7. **`external_request_id_handling_policy.md`** (BOOK-292, ~190 lines) — `tool_invocations.external_request_id text` + `.external_service text` columns + partial index; 3-state lifecycle `PENDING_EXTERNAL → AWAITING_RESULT → SUCCESS`; **7-row per-service matrix** (Gmail / Drive / Anthropic / Document AI / RFC 3161 TSA / Bank connectors / Sendgrid) with replay-supported flag + lookup mechanism; recovery flow (3-step decision tree); lint rule: replay-supported services MUST populate, replay-incapable MUST leave NULL; `WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID` audit with `replay_outcome` 3-value enum.

8. **`crash_recovery_policy.md`** (BOOK-294, ~170 lines) — Fleet-level companion to `resumability_policy.md`. Canonical enumeration SQL (`run_status IN ('RUNNING','COMPENSATING','FINALIZING') AND updated_at < now() - interval '30s' ORDER BY updated_at ASC LIMIT 500`); 30-second filter is load-bearing (eliminates cross-worker overlap). `crash_recovery_concurrency=4`, `_inter_run_delay_ms=250`, `_per_business_max=1`. Sequential degraded mode triggers (connection pool, budget, manual override). Token-bucket throttling per external service (Gmail 100/10s, Drive 100/10s, Anthropic 20/2s, Document AI 30/3s, TSA 10/1s, Bank 10/1s). `pg_try_advisory_xact_lock` non-blocking variant for cross-worker coordination. 4 new fleet-level audit events.

---

## 3. Cycle handoff docs to consult

| Doc | Purpose |
|---|---|
| `Docs/handoff/2026-05-28_session_end_handoff.md` | Prior session (P01-P04 SD clusters; B02 + B10 wrap-ups) |
| `Docs/handoff/2026-05-28b_session_end_handoff.md` | **THIS DOC** — this session (P05+P06+P07) |
| `Docs/handoff/2026-05-28_cycle_B02_complete.md` | B02 wrap-up |
| `Docs/handoff/2026-05-28_cycle_B10_complete.md` | B10 wrap-up |

---

## 4. Cycle B03 in-flight state

**Cycle UUID:** `430809b2-3204-4401-8bf9-833c7e2de000`
**Status:** 38/54 done, 16 backlog
**Done this session:** P05/P06/P07 SD clusters (12 tickets)
**Next ticket to pick up:** **BOOK-296 [B03·P08·SD] Error classification** — opens the P08 (Failure handling + retry) cluster.

**Remaining clusters (16 tickets total):**
- P08 Failure handling + retry: BOOK-296/298/300/302
- P09 Trigger engine: BOOK-305/307/308/310
- P10 Concurrency control: BOOK-312/318/319/320
- P11 Adjustment runs: BOOK-321/323/325/327

**Alignment notes for downstream clusters:**

- **P08 retry constants** are the canonical source — established in `retry_policy.md` already on disk: standard `N=3` retries with exponential backoff (base 2s, formula `base * 2^(attempt-1)`, cap 30s, ±10% uniform jitter); AI EXTERNAL tier `N=2` with base 5s. `gate_throws_semantics_policy` defers to retry_policy §2. `LOCK_BUSY` (Postgres `55P03`) classified as retryable (per `phase_execution_locking_policy`); `retry_allowed=false` for Anthropic + no-replay services (per `external_request_id_handling_policy`). **Note correction:** earlier triple cited `1s / 5s / 25s` for gate-throw retries; the canonical retry_policy values supersede.
- **P09 trigger engine** must coordinate with the crash-recovery sweep — both invoke `advanceRun` and contend for the advisory lock; trigger engine drains queue once recovery completes (per `crash_recovery_policy` §cross-block).
- **P10 concurrency** must implement the side-phase 5-entry loop counter (per `side_phase_routing_policy` + `gate_throws_semantics_policy` forced-gate path) and the UUID-ascending cross-run lock ordering (per `phase_execution_locking_policy`).
- **P11 adjustment runs** are largely independent of the engine internals but must respect the `tool_invocations.dedup_key` + `workflow_phase_states.idempotency_key` two-mechanism idempotency model.

---

## 5. Major Stage-6 doc-write candidates flagged this session

- **`audit_event_payload_schemas.md`** — STILL missing (carried over from prior session). The need has grown sharply: ~18 NEW event kinds were flagged this session alone (gate family, lock family, fleet recovery family, etc.) on top of the 15+ events from the prior session. Per-event-kind JSON Schema catalog. **HIGHEST PRIORITY.**
- **`audit_event_external_visibility_policy.md`** — which gate-throw / external-request-id / fleet-recovery events appear in external exports. Referenced from 4 docs this session.
- **`audit_pii_redaction_policy.md`** — `redactPII()` rules for `error_message` in gate-throw events. Referenced from `gate_throws_semantics_policy` + `external_request_id_handling_policy`.
- **`audit_log_volume_policy.md`** — exclusion rules for high-frequency read audits (e.g., progress reads).
- **`audit_log_visibility_policy.md`** — uniform `RUN_NOT_FOUND` for probing-resistance pattern.
- **`bank_connector_replay_capability_table.md`** — per-connector replay capability matrix (B07 reference). Lint dependency for `external_request_id_handling_policy`.
- **`cost_alerting_runbook.md`** — duplicate-call cost aggregation thresholds (Block 06 ops). Referenced from `external_request_id_handling_policy` + `crash_recovery_policy`.
- **`engine_estimator_accuracy_dashboard.md`** — 90-day P50/P75/P95 monitoring (B16).
- **`step_up_token_policy.md`** — ops-console raw-stack-trace access via step-up.

---

## 6. Stage-6 drift queue — additions from this session

### Major drift requiring retirement
- **`resumability_and_idempotency.md`** (file exists on disk) — defines a competing `caller_idempotency_key = SHA-256(run_id+phase_id+tool_name+call_seq)` construction that CONFLICTS with the canonical two-mechanism model. Stage-6 should retire this doc; the canonical model is:
  - `tool_invocations.dedup_key` (per `dedup_key_generator_policy`) — engine cache; skips invocation entirely on retry
  - `workflow_phase_states.idempotency_key` (per `tool_atomicity_policy`) — single-writer DB-write guard via `ON CONFLICT DO NOTHING`

### Drift resolved this session
- **Phase doc B03·P05 vs `tool_gate_function_signature`** on gate-throw outcome: phase doc said immediate HOLD+BLOCKING; tool sig said retry-then-escalate. RESOLVED via `gate_throws_semantics_policy` — retry layer sits between throw and final HOLD; both prior statements consistent under this policy.

### Pass-3 candidate-list staleness flagged this session
- **BOOK-285 Locking strategy** Pass-3 candidate was `transaction_indexing_strategy.md` (wrong topic — DB index strategy, not workflow-run locking).
- **BOOK-292 External request ID handling** Pass-3 candidates were `tool_step_up_request.md` + `error_handling_guide.md` (both wrong topic).
- **BOOK-294 Crash recovery** Pass-3 candidate was `backup_and_recovery_policy.md` (wrong topic — backup/restore, not runtime crash recovery).

---

## 7. Cross-block coordination — accumulated punch list (this session only)

See project-meta drawer for the full structured punch list. Highlights:

### B03·P01 schema additions (5 columns)
- `workflow_runs.estimated_completion timestamptz NULL`
- `tool_invocations.dedup_key text` (already implied; reaffirmed)
- `tool_invocations.external_request_id text NULL`
- `tool_invocations.external_service text NULL`
- partial index on `(external_service, external_request_id)` WHERE non-null

### B03·P03 tool_registry additions
- `external_service text NULL` column
- boot-time lint cross-ref against `bank_connector_replay_capability_table`

### B03·P05 implementation
- `engine.registerGate` distinct from `engine.registerTool`
- 5 CI lint rules for gate conformance
- `engine.evaluateGates` short-circuit semantics + `boundary_eval_id uuid v7` stamping

### B03·P06 implementation (the heaviest cluster's downstream load)
- `engine.run_lock_key(uuid) RETURNS bigint IMMUTABLE` SECURITY DEFINER function
- `engine.advance_run_max_boundaries=8` recursion cap with process-level yield
- `engine.fn_get_run_progress(uuid)` SECURITY DEFINER STABLE function in `engine.runtime_role`
- `engine.adminGetRunProgress` separate admin variant in `engine.admin_role`
- `engine.estimateCompletion(run_id)` + `engine_estimator_cold_start_constants` table (4h/6h/2h/3h)
- Crash recovery settings: `crash_recovery_concurrency=4`, `_inter_run_delay_ms=250`, `_per_business_max=1`
- Sweep startup hook on worker init
- `lock_timeout=5s` SET LOCAL pattern in every `advanceRun` transaction

### B03·P07 schema/RPC
- `crash_recovery_throttle_state` table
- `engine.acquire_recovery_token(service text)` SECURITY DEFINER RPC with advisory lock
- `engine.crashRecoverWorker` in-process flag for throttle scope

### B03·P08 retry policy constants (foundation for next session)
- Classify Postgres `55P03` (lock_not_available) as `LOCK_BUSY` retryable
- Canonical retry constants live in `retry_policy.md` (pre-session) — N=3, base 2s, cap 30s, ±10% jitter (standard); N=2, base 5s (AI EXTERNAL tier)
- Honor `gate_function_library_schema.retry_allowed`
- Honor `tool_registry.retry_allowed` (false for Anthropic + no-replay services)

### B03·P10 concurrency
- 5-entry-per-side-phase loop cap (per-side-phase counter, not shared)
- `SIDE_PHASE_LOOP_LIMIT_REACHED` event on cap hit
- UUID-ascending lock-ordering rule for cross-run advisory locks

### B05·P02 audit taxonomy — ~18 NEW event kinds
- Gate: `WORKFLOW_GATE_PASSED`, `_HOLD`, `_ROUTED_TO_SIDE_PHASE`, `_TIMEOUT`
- Throw: `WORKFLOW_GATE_THREW`, `_RETRY_EXHAUSTED`, `_FORCED_PASS`, `_FORCED_HOLD`, `SIDE_PHASE_LOOP_LIMIT_REACHED`
- Phase: `WORKFLOW_PHASE_ENTERED`, `_COMPLETED`, `_HOLDING`, `_ROUTED`, `WORKFLOW_RUN_TERMINAL_REACHED`, `WORKFLOW_RUN_STATE_CHANGED`, `WORKFLOW_TOOL_INVOKED`
- Composition: `boundary_eval_id` field on ALL `WORKFLOW_GATE_*` events (join key)
- Lock: `WORKFLOW_RUN_LOCK_ACQUIRED`, `WORKFLOW_RUN_LOCK_TIMEOUT`
- Estimate: `WORKFLOW_RUN_ESTIMATE_UPDATED` (4-value trigger enum)
- Progress: `WORKFLOW_RUN_PROGRESS_ADMIN_READ` (admin-tier only)
- External replay: `WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID`
- Fleet recovery: `WORKFLOW_FLEET_CRASH_RECOVERY_STARTED`, `_COMPLETED`, `_DEGRADED`, `WORKFLOW_RUN_RECOVERY_FAILED`

### B14 review queue — 4 new issue types
- `GATE_EVALUATION_FAILED` (post-retry-exhaustion BLOCKING)
- `GATE_INFINITE_LOOP_PROTECTION_TRIPPED` (forced HOLD on loop cap)
- `ENGINE_LOCK_CONTENTION` (lock-timeout retry exhaustion)
- `TOOL_FAILURE_POST_RETRY` (E3 path in execution loop)

### B16 dashboard
- run-list sort key by `estimated_completion`; NULL → em-dash; stale (>3× expected) → yellow indicator
- `engine_progress_api_latency` panel
- `engine_estimator_accuracy_dashboard` panel

### B12/B13 phase configs (binding)
- Gate ordering per phase is part of the contract; cheap-predicate-first binding for perf budgets
- CI gate-throw allowlist: `DatabaseError`, `NetworkError`, `InvalidGateInputError` only — throws on business-logic branches blocked

### B15 finalize (explicit non-goal of B03·P06)
- Boundary `AWAITING_APPROVAL → FINALIZING → FINALIZED` owned by B15, NOT B03·P06
- Uses same advisory-lock key as `advanceRun` (per `phase_execution_locking_policy` §cross-block)

---

## 8. Cadence reminder (unchanged)

| Ticket type | Per-turn cadence |
|---|---|
| Easy verify-only | 5-10 per turn, batched, one-line DoD |
| Verify-only with drift | 3-5 per turn, terser comments |
| Routine write-required | Write directly, ~120-180 lines / 8-10 sections, NO propose-wait |
| Novel write-required (anchor) | Keep propose-wait, ~180-280 lines / 10 sections max |

**Cross-references are LOAD-BEARING. Quality is KING. Speed is secondary.**

---

## 9. Pinned MemPalace queries

```
mempalace_status
mempalace_get_drawer(drawer_id="drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c")
mempalace_kg_query(entity="BOOK-272")  # example — substitute relevant ticket
mempalace_kg_query(entity="P07_cluster")
mempalace_kg_query(entity="P06_cluster")
```

Known mempalace bug: `mempalace_kg_query` occasionally returns "Internal tool error" (multi-session mount issue). KG _add_ is reliable. If query fails, drawer state holds canonical data.

**KG object-field 128-char limit**: keep `object` strings tight or splits will fail. Multiple short triples > one long one.

---

## 10. Next-session start checklist

1. **Load context in parallel:**
   ```
   mempalace_status
   mempalace_get_drawer(drawer_id="drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c")
   Read("Docs/handoff/2026-05-28b_session_end_handoff.md")  // THIS FILE
   mcp__plane__retrieve_cycle(project_id="28b250c0-d991-4dcb-a48c-51af27aa17dd", cycle_id="430809b2-3204-4401-8bf9-833c7e2de000")
   ```

2. **List Cycle B03 backlog** (large response — save to file):
   ```
   mcp__plane__list_cycle_work_items(project_id="28b250c0-d991-4dcb-a48c-51af27aa17dd", cycle_id="430809b2-3204-4401-8bf9-833c7e2de000")
   ```
   Then jq filter by Backlog state `06b2fd3b-5d0c-486a-9a37-fe086b725315`, sort by sequence_id, take lowest. Should be **BOOK-296** [B03·P08·SD] Error classification.

3. **Confirm orientation:** "Resuming Cycle B03. P01-P07 done (38/54). Lowest backlog ticket BOOK-296 — opens P08 (Failure handling + retry) cluster. P08 retry constants must align with N=3 + 1s/5s/25s backoff + LOCK_BUSY classification established this session."

4. **Proceed with the next ticket per cadence.**

---

## 11. KG triples filed at session end

- `session_2026_05_28b_long` → `closed` → 12 tickets across B03·P05 (4) + B03·P06 (4) + B03·P07 (4)
- `session_2026_05_28b_long` → `new_sub_docs` → 8 canonical sub-docs (all under Docs/sub/policies/)
- `stage3_next_action` → `resume_at` → Cycle B03 (UUID 430809b2-3204-4401-8bf9-833c7e2de000); 16 backlog; lowest BOOK-296

Plus per-ticket `BOOK-XXX → closed_as_verify/closed_as_write` + cross-block flag triples.

End of session. Welcome to the next one.
