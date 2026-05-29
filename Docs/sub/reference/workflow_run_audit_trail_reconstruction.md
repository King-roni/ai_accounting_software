# workflow_run_audit_trail_reconstruction

**Category:** Reference · **Owning block:** 03 — Workflow Engine · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

**Query patterns** for reconstructing a workflow run's complete audit trail from `audit_events`, `workflow_runs`, `workflow_phase_states`, and `tool_invocations`. This is the canonical reference for forensic investigators, auditors, and any UI that needs to render a run's chronological narrative (Block 16's run-detail page, Block 14's review-queue context drawer, post-incident analysis runbooks).

Companion to `audit_event_taxonomy.md` (event catalogue), `workflow_run_schema.md` (workflow_runs DDL), `tool_invocation_schema.md` (tool_invocations DDL), `workflow_state_enum.md` (state machine).

---

## 1. The reconstruction model

A workflow run's audit trail is reconstructable by joining four tables:

```
workflow_runs (the run)
   └─ workflow_phase_states (per-phase status changes)
   └─ tool_invocations (per-tool calls within phases)
   └─ audit_events (every state change, gate decision, tool result, security event)
```

`audit_events` is the **primary timeline source** — every meaningful event in the system emits an audit row with a `workflow_run_id` foreign key (where applicable). The other tables provide structural context: which phases existed, which tools were invoked, what state the run was in at each moment.

---

## 2. The four canonical query patterns

### 2.1 Full chronological timeline

Returns every event ordered by emission time, with denormalised actor + phase context for display.

```sql
SELECT
  e.id                                              AS event_id,
  e.event_kind                                      AS event_kind,
  e.severity                                        AS severity,
  e.occurred_at                                     AS occurred_at,
  e.actor_user_id                                   AS actor_user_id,
  u.full_name                                       AS actor_display,
  e.actor_role_at_event                             AS actor_role,
  e.actor_system                                    AS actor_system,
  e.payload                                         AS payload,
  COALESCE(e.payload->>'phase_name', wr.current_phase_name) AS phase_context
FROM audit_events e
LEFT JOIN users u
  ON u.id = e.actor_user_id
LEFT JOIN workflow_runs wr
  ON wr.workflow_run_id = e.workflow_run_id
WHERE e.workflow_run_id = $1
ORDER BY e.occurred_at ASC, e.id ASC;
```

The `id ASC` tiebreaker ensures stable ordering when two events share an `occurred_at` timestamp (rare — UUID v7's time-prefix bytes provide microsecond resolution but truncation to `timestamptz` can collide).

`actor_display` falls back to `actor_system` for SYSTEM-actor events per `audit_event_payload_schemas.md` actor-kind XOR constraint.

### 2.2 Phase-state transitions only

Returns the state transitions at the phase level (PENDING / RUNNING / COMPLETED / FAILED / SKIPPED / HOLDING):

```sql
SELECT
  ps.phase_name,
  ps.status                                         AS phase_status,
  ps.entered_at                                     AS entered_at,
  ps.exited_at                                      AS exited_at,
  (ps.exited_at - ps.entered_at)                    AS duration,
  e.event_kind                                      AS exit_event,
  e.payload->>'exit_reason'                         AS exit_reason
FROM workflow_phase_states ps
LEFT JOIN audit_events e
  ON e.workflow_run_id = ps.workflow_run_id
 AND e.event_kind IN ('WORKFLOW_PHASE_COMPLETED', 'WORKFLOW_PHASE_FAILED', 'WORKFLOW_PHASE_HOLDING')
 AND e.payload->>'phase_name' = ps.phase_name
 AND e.occurred_at BETWEEN ps.entered_at AND COALESCE(ps.exited_at, now())
WHERE ps.workflow_run_id = $1
ORDER BY ps.entered_at ASC;
```

This view answers: "what phases did this run go through, in what order, with what outcome?"

### 2.3 Tool-invocation trail for a specific phase

Returns all tool invocations within a single phase + their audit events:

```sql
SELECT
  ti.id                                             AS invocation_id,
  ti.tool_name                                      AS tool_name,
  ti.status                                         AS invocation_status,
  ti.started_at                                     AS started_at,
  ti.completed_at                                   AS completed_at,
  ti.input_payload_hash                             AS input_hash,
  ti.external_request_id                            AS external_request_id,
  e_start.id                                        AS start_event_id,
  e_end.id                                          AS end_event_id,
  e_end.event_kind                                  AS end_event_kind,
  ti.error_details                                  AS error_details
FROM tool_invocations ti
LEFT JOIN audit_events e_start
  ON e_start.workflow_run_id = ti.workflow_run_id
 AND e_start.event_kind = 'WORKFLOW_TOOL_INVOCATION_STARTED'
 AND e_start.payload->>'tool_invocation_id' = ti.id::text
LEFT JOIN audit_events e_end
  ON e_end.workflow_run_id = ti.workflow_run_id
 AND e_end.event_kind IN ('WORKFLOW_TOOL_INVOCATION_COMPLETED', 'WORKFLOW_TOOL_INVOCATION_FAILED', 'WORKFLOW_TOOL_DEDUP_HIT')
 AND e_end.payload->>'tool_invocation_id' = ti.id::text
WHERE ti.workflow_run_id = $1
  AND ti.phase_name = $2
ORDER BY ti.started_at ASC NULLS LAST, ti.created_at ASC;
```

This view answers: "what tools did this phase invoke, with what input hashes, and what was the outcome?" Critical for crash-recovery analysis (per `tool_invocation_schema.md` Phase 07 boundary reconstruction).

### 2.4 Errors-only timeline

Returns only HIGH and BLOCKING events — the "what went wrong" reconstruction:

```sql
SELECT
  e.id,
  e.event_kind,
  e.severity,
  e.occurred_at,
  e.actor_user_id,
  e.payload->>'error_message'                       AS error_message,
  e.payload->>'failure_class'                       AS failure_class,
  e.payload                                         AS full_payload
FROM audit_events e
WHERE e.workflow_run_id = $1
  AND e.severity IN ('HIGH', 'BLOCKING')
ORDER BY e.occurred_at ASC, e.id ASC;
```

Used as the entry-point query for incident response post-mortems.

---

## 3. Time-bounded variants

Each query supports a `BETWEEN $from AND $to` time bound for partial reconstruction:

```sql
-- Window the timeline query (§2.1) to a specific phase's duration
WHERE e.workflow_run_id = $1
  AND e.occurred_at BETWEEN
        (SELECT entered_at FROM workflow_phase_states
         WHERE workflow_run_id = $1 AND phase_name = $2)
        AND
        (SELECT COALESCE(exited_at, now()) FROM workflow_phase_states
         WHERE workflow_run_id = $1 AND phase_name = $2)
```

For very large runs (>10,000 audit events), time-windowing is essential — the unfiltered timeline query can return enough rows to overwhelm a UI render. Block 16's run-detail page paginates the timeline at 100 events per page using `(occurred_at, id) > ($cursor_at, $cursor_id)` keyset pagination.

---

## 4. Per-actor filtering

Filter timeline events by actor (user or SYSTEM):

```sql
WHERE e.workflow_run_id = $1
  AND (
    e.actor_user_id = $actor_user_id      -- specific user actions
    OR (e.actor_user_id IS NULL AND e.actor_system = $actor_system)  -- specific job actions
  )
```

Useful for compliance investigations ("what did Owner-X do during this run?") and for the personal audit feed per BOOK-241 (`audit.read_personal_feed` consumes a similar pattern but with the additional cross-tenant redaction layer from BOOK-241 §4).

---

## 5. JOIN-path correctness

| Join target | Foreign key on `audit_events` | Notes |
|---|---|---|
| `workflow_runs.workflow_run_id` | `audit_events.workflow_run_id` | Primary linkage. NULL for events that don't belong to any run (e.g., AUTH_LOGIN_SUCCEEDED, system-level events). |
| `workflow_phase_states` row | `(workflow_run_id, payload->>'phase_name')` | Indirect — `audit_events` doesn't have a direct phase_state_id FK. Match on phase_name + occurred_at within phase window. |
| `tool_invocations.id` | `audit_events.payload->>'tool_invocation_id'` | Stored as text in payload; cast to UUID when joining. |
| `users.id` | `audit_events.actor_user_id` | Standard user join. LEFT JOIN because GDPR-erased users return NULL with a tombstone marker per `principal_context_schema.md` §14. |

The phase-state JOIN is the weakest link — it relies on payload extraction. A future migration to add `phase_state_id` as a direct FK on `audit_events` would tighten this; flagged for Stage-6 schema-hardening pass.

---

## 6. Performance considerations

| Query | Typical row count | P95 latency target |
|---|---|---|
| Full timeline (§2.1) | 100-2,000 events | < 200 ms |
| Phase-state transitions (§2.2) | 8-15 rows | < 50 ms |
| Tool-invocation trail per phase (§2.3) | 1-200 rows | < 100 ms |
| Errors-only (§2.4) | 0-20 rows | < 50 ms |

The indexes that support these queries:

- `audit_events(workflow_run_id, occurred_at, id)` — supports §2.1 + §2.3 + §2.4 (Block 05 P02 ships this)
- `audit_events(workflow_run_id, severity)` partial index WHERE severity IN ('HIGH','BLOCKING') — supports §2.4 efficient scan
- `workflow_phase_states(workflow_run_id, entered_at)` — supports §2.2 ordering
- `tool_invocations(workflow_run_id, phase_name, status)` already exists per `tool_invocation_schema.md`

**Cross-block coordination flagged for B05·P02 indexes:** confirm the partial index on `severity IN ('HIGH', 'BLOCKING')` exists; create if missing.

---

## 7. Sample reconstruction — narrative form

A typical incident-response reconstruction follows this sequence:

1. **Start with §2.4 (Errors-only)** — identify the HIGH/BLOCKING event that triggered the investigation.
2. **§2.2 (Phase transitions)** — locate which phase contained the failure.
3. **§2.3 (Tool invocations)** — within that phase, find the specific tool invocation that failed.
4. **§2.1 (Full timeline)** with `BETWEEN $phase_entered_at AND $phase_exited_at` window — see all events in the failed phase's window for context.
5. **§4 (Per-actor)** if the failure relates to a specific user action — filter to that actor.

The 5-step procedure is the canonical incident-response runbook per `cross_tenant_alerting_runbook.md` (cross-tenant variant) and `out_workflow_failure_runbook.md` (workflow-failure variant — Stage-6 candidate to verify exists).

---

## 8. Edge cases

| Case | Behaviour |
|---|---|
| Run was force-resumed (BOOK-245 §"Force-resume") | `WORKFLOW_RUN_FORCE_RESUMED` HIGH event appears in timeline; reconstruct context by joining `payload.force_resume_reason`. |
| Run finalised then later compensated (FINALIZING → COMPENSATING → FAILED) | All transitions appear in §2.1 in order; the COMPENSATING phase shows distinct rows in §2.2. |
| Tool invocation dedup-hit (SKIPPED_IDEMPOTENT) | §2.3 returns the SKIPPED_IDEMPOTENT row + `WORKFLOW_TOOL_DEDUP_HIT` audit. The original COMPLETED row's `id` is referenced via the dedup row's `output_payload.ref_invocation_id` (Phase 07 contract). |
| Crash-recovered run with IN_FLIGHT row | §2.3 returns the IN_FLIGHT row; Phase 07's crash-recovery `WORKFLOW_RUN_RECOVERED` event appears in §2.1 at the recovery moment. |
| Audit-event hash-chain break detected post-emission | `AUDIT_HASH_CHAIN_MISMATCH` BLOCKING event appears in §2.4; investigation requires chain-verification per Block 05 Phase 02. |
| Run created by SYSTEM actor (background scheduler — currently out of MVP scope) | §2.1 returns `actor_user_id = NULL` + `actor_system = '<job_name>'`. <code>actor_display</code> falls back to actor_system per JOIN COALESCE. |
| Run on a business that was later deactivated | <code>workflow_runs.business_id</code> still references the deactivated business; reconstruction works. <code>users.id</code> joins to deactivated owners return their last known display. |

---

## 9. Cross-references

- `audit_event_taxonomy.md` — catalogue of all event kinds referenced in queries
- `audit_event_payload_schemas.md` — payload-field shapes consumed by §2.1, §2.3, §2.4
- `audit_log_policies.md` — actor-kind XOR constraint relevant to §2.1 actor_display fallback
- `workflow_run_schema.md` — workflow_runs DDL (BOOK-243)
- `tool_invocation_schema.md` — tool_invocations DDL (BOOK-247)
- `workflow_state_enum.md` — state-machine context (BOOK-245)
- `workflow_phase_states_schema.md` — phase-state DDL consumed by §2.2 + JOIN
- `personal_audit_feed_policy.md` (BOOK-241) — per-actor filtering pattern (§4) shares the actor-redaction infrastructure but adds cross-tenant safeguards
- `cross_tenant_alerting_runbook.md` — incident-response consumer of §7
- `principal_context_schema.md` §14 — GDPR-erased-user behaviour at §5 users-JOIN
- Block 03 Phase 01 — workflow_runs + tool_invocations tables (architecture)
- Block 03 Phase 07 — resumability + dedup; consumer of §2.3 for crash-boundary reconstruction
- Block 05 Phase 02 — audit_events table + indexes (consumer of §6 index requirements)
- Block 14 — review-queue context drawer (consumer of §2.1 + §2.4)
- Block 16 — run-detail page (consumer of §2.1 with keyset pagination per §3)
- Stage 1 decision — audit trail is the single canonical reconstruction source
