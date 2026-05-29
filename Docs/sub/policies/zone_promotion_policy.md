# Zone Promotion Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

Binding rules governing the promotion of data from the Processing zone to the Operational zone. Promotion is the controlled movement of proposed, extracted, and classified data into the authoritative operational tables after a gate evaluation confirms the data is ready. These rules enforce the boundary between scratch computation and committed fact.

---

## Section 1 — Zone boundary definitions

| Zone | Tables | Characteristic |
| --- | --- | --- |
| **Processing zone** | Extraction result tables, classifier output scratch, proposed match objects, pre-commit staging rows | Short-lived, non-durable scratch state; 7-day TTL per `storage_bucket_configuration` |
| **Operational zone** | `transactions`, `match_records`, `ledger_entries`, `documents`, `review_issues` | Authoritative committed facts; subject to RLS, audit trail, and retention rules |

The Processing zone is the proposer's domain. The Operational zone is the single-writer's domain. The zone boundary is crossed exactly once per record per phase, under gate control.

The two zones exist as a separation of concern: the Processing zone enables iterative, re-computable computation without audit-trail side effects; the Operational zone holds the committed facts that the accounting record depends on. Data in the Processing zone is never shown directly to end users as authoritative — only promoted Operational-zone rows are displayed in the review queue, matching surface, and ledger views.

---

## Section 2 — Gate prerequisite

Processing-zone data is promoted to the Operational zone **only when the relevant workflow phase gate evaluates to `ADVANCE`**. No promotion occurs on `HOLD` or `FAIL` gate decisions.

Gate decisions use the `gate_decision_enum` from `workflow_phase_states_schema`:

| Gate decision | Promotion action |
| --- | --- |
| `ADVANCE` | Promotion proceeds; promoting single-writer tool runs |
| `HOLD` | Promotion deferred; phase enters `HOLDING`; run enters `REVIEW_HOLD` |
| `FAIL` | Promotion blocked; phase enters `FAILED`; run enters `FAILED` |

The gate evaluation is owned by the Block 03 gate framework (`engine.evaluate_gate`). The promoting tool must not evaluate the gate itself — it receives the `ADVANCE` decision as a verified input from the engine after the gate phase completes. Direct promotion by a tool that bypasses gate evaluation is a PR-blocking violation.

Gate evaluation may occur at phase entry (pre-promotion guard), at phase exit (standard promotion gate), or both. When both are present, the exit gate is the definitive gate for promotion. The entry gate acts as a fast-fail precondition that prevents the phase from executing if preconditions are not met; it does not itself authorize promotion.

The sequence is invariant:
```
Phase entry gate (optional) → tool execution → exit gate evaluation
    → ADVANCE → promoting single-writer tool runs
    → HOLD    → phase enters HOLDING; no promotion
    → FAIL    → phase enters FAILED; no promotion
```

---

## Section 3 — Atomicity rule

Promotion is **atomic at the phase level** — all Operational-zone rows for a phase are promoted in a single database transaction or none are.

The atomicity boundary is the database transaction held by the promoting single-writer tool. No partial result is visible to any reader between row writes within the promotion transaction.

Partial promotions are not permitted. If the transaction fails mid-write (deadlock, connection loss, constraint violation), the phase retries from scratch using the `idempotency_key` per `tool_atomicity_policy`. The idempotency guard (`INSERT ... ON CONFLICT DO NOTHING` on the Operational table's unique key) ensures that a re-attempted promotion does not insert duplicate rows.

The promoting tool carries `WRITES_RUN_STATE` side-effect class per `tool_naming_convention_policy`. No tool that lacks this declaration may write to Operational-zone tables.

---

## Section 4 — Source row marking

After a successful promotion transaction, the source Processing-zone rows are marked `promoted = true`. They are **not deleted at promotion time**. The `promoted` flag:

- Prevents the engine from re-promoting the same rows if the phase is re-entered after a crash (the idempotency guard on the Operational table is the primary protection; `promoted = true` is a secondary marker).
- Provides a stable audit link between the Processing-zone record and the Operational-zone record for forensic queries.

Marked Processing-zone rows are purged by the retention engine per `data_retention_policy` after the standard Processing-zone TTL expires. They are not purged at promotion time.

---

## Section 5 — Re-promotion protection

Re-promotion of already-promoted rows is blocked at the Operational table level via `ON CONFLICT DO NOTHING` on the table's unique key (typically a combination of `(business_id, idempotency_key)` or the domain-specific dedup key). A conflict indicates the row was already written in a prior (deduplicated) invocation; the promoting tool returns the existing row's ID as if it had just written it.

This guard is **not** satisfied by checking `promoted = true` on the Processing-zone row. The Processing-zone flag is advisory; the Operational table's unique constraint is authoritative.

---

## Section 6 — Restricted call site

Only Block 03 execution engine calls may initiate a zone promotion. Application code, API endpoints, and Block 16 reporting tools may not write directly to Operational-zone tables outside the engine invocation path. This restriction is enforced by:

1. RLS on Operational-zone tables permitting INSERT only for the `service_role` and the workflow engine's internal database role.
2. The `WRITES_RUN_STATE` side-effect class restriction in `tool_naming_convention_policy`, which is enforced by code review and the tool registration framework.
3. The engine's phase definition enforcement: a tool with `WRITES_RUN_STATE` in a phase must be preceded by a proposer per `tool_atomicity_policy`.

### Mobile

Mobile clients never reach Operational-zone write paths. Write surfaces at all API endpoints that accept operational data reject requests from `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints.md`. This applies to any endpoint that eventually calls a promoting tool.

---

## Section 7 — Zone promotion and the archive path

After a period is finalized (Block 15), Operational-zone rows are promoted a second time — into the Finalized Archive zone (`archive.*` tables and the `archive-bundles` Storage bucket). This second promotion is governed by Block 15's lock sequence and is out of scope for this policy. This policy covers only the Processing → Operational promotion.

The archive promotion's atomicity model is distinct — it uses Block 15's advisory-lock and two-phase commit semantics per `lock_sequence_policies`, not the standard `tool_atomicity_policy` pattern.

---

## Section 8 — Mobile

Mobile clients never call zone-promoting tools directly. All write surfaces that accept data eventually promoted to the Operational zone are rejected for mobile clients per `mobile_write_rejection_endpoints.md`, returning HTTP 405 with audit event `MOBILE_WRITE_REJECTED`. Read operations against Operational-zone tables are permitted from mobile clients (subject to RLS).

---

## Section 9 — Constraint summary

The following are absolute constraints enforced by code review, boot-time registration checks, and RLS:

1. No tool lacking the `WRITES_RUN_STATE` side-effect class may write to Operational-zone tables.
2. No gate evaluation (`HOLD` or `FAIL`) may be followed by a promotion write in the same phase execution.
3. Promotion is always a single transaction covering all Operational-zone rows for the phase — no row-by-row commits.
4. The `promoted = true` marker on Processing-zone rows is set inside the same promotion transaction — it is not a subsequent update.
5. Operational-zone rows that were written by a prior promotion attempt (idempotency conflict) are returned as-is without error. Callers must not treat a conflict as a failure.

---

## Audit events (indirect)

Zone promotion does not emit a dedicated audit event. The operational-zone write emits the standard domain audit event for the record type (e.g., `LEDGER_ENTRY_CREATED`, `MATCH_CONFIRMED`) per the relevant schema sub-doc. The gate evaluation that gates the promotion emits `WORKFLOW_GATE_PASSED` per the Block 03 gate framework.

The absence of a dedicated `ZONE_PROMOTION_COMPLETED` event is intentional. The combination of `WORKFLOW_GATE_PASSED` (gate allowed promotion) and the domain event for the promoted record type (e.g., `LEDGER_ENTRY_CREATED`) provides the complete audit trace. A dedicated promotion event would duplicate information already captured by these two signals, increasing audit volume without adding forensic value.

Forensic query pattern for promotion history: join `audit_log` on `(workflow_run_id, event_type = 'WORKFLOW_GATE_PASSED')` with the domain-specific record audit events on `subject_id` and `event_time` within the run's execution window.

---

## Cross-references

- `data_retention_policy` — TTL and purge rules for Processing-zone rows after `promoted = true`
- `storage_bucket_configuration` — 7-day TTL for Processing-zone bucket objects
- `tool_atomicity_policy` — proposer + single-writer pattern; `idempotency_key` guard; `WRITES_RUN_STATE` side-effect class requirement
- `tool_naming_convention_policy` — `WRITES_RUN_STATE` side-effect class; `WRITES_PROCESSING_ZONE` class for scratch tools
- `tool_side_effect_taxonomy` — closed enum of side-effect classes referenced above
- `workflow_phase_states_schema` — `idempotency_key` column that anchors the promoting single-writer
- `mobile_write_rejection_endpoints.md` — mobile client rejection at write-surface endpoints
- `Docs/phases/04_data_architecture/08_zone_promotion_pipeline.md` — owning phase (promotion API, atomicity contract, archive path)
- `Docs/phases/04_data_architecture/06_processing_zone.md` — Processing-zone table definitions
- `Docs/phases/03_workflow_engine/05_gate_evaluation_framework.md` — gate framework that gates promotion
