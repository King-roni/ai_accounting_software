# adjustment_finalization_precondition_schema

**Category:** Schemas · **Owning block:** 15 — Finalization & Secure Archive · **Co-owners:** 03, 12, 13 · **Stage:** 4 sub-doc (Layer 2)

The composite-gate registration for `ADJUSTMENT_FINALIZATION` per Block 15 Phase 08. Adjustment runs reuse Phase 02's 8 baseline gates AND layer 3 adjustment-specific gates that monthly finalization does NOT need. This sub-doc pins the gate ordering, SQL shape, and the typed registration shape that `engine.registerGate` consumes.

The composite is `engine.gate_adjustment_preconditions_satisfied`. It short-circuits on first failure (Stage 1 default). The `adjustment_archive_handoff_integration` integration consumes this gate as the entry guard of the adjustment-bundle construction.

---

## Why a distinct precondition surface

Monthly finalization creates a new `archive_packages` row. Adjustment finalization writes a new manifest version against an existing package — additive, not creative. Three risks that monthly finalization does not face:

1. **No parent to attach to** — the adjustment must point at a finalized period
2. **Retention expired** — Cyprus 6-year cap may have elapsed since the parent period
3. **Concurrent adjustment racing for the same `manifest_version_number`** — two in-flight adjustment runs against the same parent

Phase 02's 8 gates do not cover these. This sub-doc layers them on.

## Gate composition order

`engine.gate_adjustment_preconditions_satisfied` invokes gates in this order. First failure halts.

| Order | Gate name | Source | Why this order |
| --- | --- | --- | --- |
| 1 | `engine.gate_adjustment_parent_finalized` | This sub-doc | Cheap; rejects the most common error first |
| 2 | `engine.gate_adjustment_within_retention` | This sub-doc | Cheap; date arithmetic |
| 3 | `engine.gate_adjustment_records_present` | This sub-doc | Cheap; existence check |
| 4 | `engine.gate_adjustment_no_concurrent_conflict` | This sub-doc | Cheap; existence check |
| 5–12 | The 8 baseline gates from Phase 02, in Phase 02's order | Phase 02 | The expensive ones — only run if the cheap adjustment checks passed |

The baseline gates 1–8 from Phase 02 run unchanged: `transactions_processed`, `no_unknown_types`, `evidence_satisfied`, `draft_ledger_entries_complete`, `vat_classifications_complete`, `zero_blocking_issues`, `approval_recorded`, `audit_log_quiescent`.

Per `tool_gate_function_signature`: each gate is `READ_ONLY`, AI tier `NONE`, returns the canonical `GateResult` shape.

## Adjustment-specific gate definitions

### 1. `engine.gate_adjustment_parent_finalized`

```sql
SELECT EXISTS (
  SELECT 1
  FROM workflow_runs wr
  WHERE wr.workflow_run_id = $adjustment_run.parent_run_id
    AND wr.state = 'FINALIZED'
    AND wr.business_id = $adjustment_run.business_id
);
```

`HOLD` with `hold_reason = "Parent run is not finalized"`, `severity = BLOCKING`, `review_issue_type = "finalization.adjustment_parent_not_finalized"` when false.

Audit event on failure: `FINALIZATION_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED` with `{ adjustment_run_id, parent_run_id, parent_state }`.

### 2. `engine.gate_adjustment_within_retention`

```sql
SELECT (now() - parent_run.period_start) <= interval '6 years'
FROM workflow_runs parent_run
WHERE parent_run.workflow_run_id = $adjustment_run.parent_run_id;
```

The 6-year Cyprus retention cap per Block 04 Phase 10. Defense-in-depth — intake (Block 12 Phase 09 / Block 13 Phase 11) already checks it.

`HOLD` with `severity = BLOCKING`, `review_issue_type = "finalization.adjustment_retention_expired"` when false.

Audit event on failure: `FINALIZATION_ADJUSTMENT_REJECTED_RETENTION_EXPIRED` with `{ adjustment_run_id, parent_period_start, age_days }`.

### 3. `engine.gate_adjustment_records_present`

```sql
SELECT EXISTS (
  SELECT 1
  FROM adjustment_records ar
  WHERE ar.workflow_run_id = $adjustment_run.workflow_run_id
    AND ar.business_id = $adjustment_run.business_id
    AND ar.reason IS NOT NULL
    AND length(trim(ar.reason)) > 0
);
```

Per `adjustment_record_schema`: `reason` is mandatory. This gate enforces it again at lock time as defense-in-depth.

`HOLD` with `severity = BLOCKING`, `review_issue_type = "finalization.adjustment_records_empty"` when false. Issue group: `Needs Confirmation`.

### 4. `engine.gate_adjustment_no_concurrent_conflict`

```sql
SELECT NOT EXISTS (
  SELECT 1
  FROM workflow_runs sibling
  WHERE sibling.parent_run_id = $adjustment_run.parent_run_id
    AND sibling.workflow_run_id != $adjustment_run.workflow_run_id
    AND sibling.state IN ('FINALIZING', 'AWAITING_APPROVAL')
    AND sibling.business_id = $adjustment_run.business_id
);
```

Two in-flight adjustments against the same parent CAN both exist per Stage 1 ("Multiple adjustments per period — both can run concurrently"), but only ONE may be at the lock-sequence boundary at a time. The earlier one commits first; the second re-evaluates with the new `manifest_version_number` per `adjustment_archive_handoff_integration` ordering rule.

`HOLD` with `severity = HIGH`, `review_issue_type = "finalization.adjustment_concurrent_conflict"`. The gate is auto-retried per `lock_sequence_policies` after a 5-second backoff; the conflicting sibling typically commits within that window.

Audit event on failure: `FINALIZATION_ADJUSTMENT_REJECTED_CONCURRENT_CONFLICT` with `{ adjustment_run_id, conflicting_sibling_run_id, sibling_state }`.

## Typed registration shape

Each gate registers via `engine.registerGate` per `tool_gate_function_signature`:

```ts
engine.registerGate({
  gate_name: "engine.gate_adjustment_parent_finalized",
  guards_phase: "ADJUSTMENT_FINALIZATION",
  exit_only: false,                            // entry gate
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY"],
  ai_tier: "NONE",
  cache_disabled: false,
  description_ref: "Docs/sub/schemas/adjustment_finalization_precondition_schema.md",
});
```

The composite gate registers the same way under `engine.gate_adjustment_preconditions_satisfied`. Its `description_ref` points at this sub-doc.

## Composite gate behaviour

```ts
const compositeResult: GateResult = await (async () => {
  for (const gate of [
    "engine.gate_adjustment_parent_finalized",
    "engine.gate_adjustment_within_retention",
    "engine.gate_adjustment_records_present",
    "engine.gate_adjustment_no_concurrent_conflict",
    ...phase02BaselineGates,
  ]) {
    const r = await engine.invokeGate(gate, input);
    if (r.decision !== "PASS") return r;
  }
  return { decision: "PASS" };
})();
```

The composite is idempotent — re-invocation with the same input returns the same result. Re-evaluation cost is bounded; the 4 adjustment gates together complete in < 100 ms for typical periods.

Per `tool_gate_function_signature`: composite gate evaluations have a 30-second hard timeout; the adjustment gates' SQL is indexed for sub-second response on `workflow_runs(parent_run_id, state)` and `adjustment_records(workflow_run_id)`.

## On `PASS` — handoff to lock sequence

Per `lock_sequence_policies` and `adjustment_archive_handoff_integration`: the lock-sequence engine sets `app.adjustment_lock_active = true`, invokes the 8-step adjustment-bundle construction, and emits `FINALIZATION_ADJUSTMENT_PRECONDITIONS_PASSED` before step 1.

`FINALIZATION_PRECONDITION_EVALUATED` fires per individual gate evaluation (granular trace); `FINALIZATION_ADJUSTMENT_PRECONDITIONS_PASSED` fires once at composite-PASS (Phase 08 summary event).

## On failure — review-queue re-open

Mirrors Phase 02's first-failure-re-open contract:

| Failing gate | review_issues row written |
| --- | --- |
| `adjustment_parent_finalized` | `issue_group = Needs Confirmation`, `severity = BLOCKING`, `subject_kind = workflow_runs` |
| `adjustment_within_retention` | `issue_group = Needs Confirmation`, `severity = BLOCKING`, `subject_kind = workflow_runs` |
| `adjustment_records_present` | `issue_group = Needs Confirmation`, `severity = BLOCKING`, `subject_kind = workflow_runs` |
| `adjustment_no_concurrent_conflict` | `issue_group = Needs Confirmation`, `severity = HIGH`, `subject_kind = workflow_runs` |
| Baseline gates 1–8 | Per Phase 02's mapping |

Audit event per re-open: `FINALIZATION_PRECONDITION_FAILED` (existing in taxonomy) plus the specific `FINALIZATION_ADJUSTMENT_REJECTED_*` event for the adjustment-specific gates.

## Mobile rejection

Adjustment finalization is a write surface — `archive.adjustment_finalize` rejects `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints`. The composite gate evaluation itself runs server-side and does not see a form-factor header; rejection happens at the API edge before the gate ever evaluates.

## Audit events emitted by this surface

| Event | Trigger |
| --- | --- |
| `FINALIZATION_PRECONDITION_EVALUATED` | Per individual gate evaluation |
| `FINALIZATION_PRECONDITION_FAILED` | Per individual gate `HOLD` |
| `FINALIZATION_ADJUSTMENT_PRECONDITIONS_PASSED` | Composite `PASS` |
| `FINALIZATION_ADJUSTMENT_PRECONDITIONS_FAILED` | Composite `HOLD` (carries failing gate name) |
| `FINALIZATION_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED` | Gate 1 failure |
| `FINALIZATION_ADJUSTMENT_REJECTED_RETENTION_EXPIRED` | Gate 2 failure |
| `FINALIZATION_ADJUSTMENT_REJECTED_CONCURRENT_CONFLICT` | Gate 4 failure |
| `WORKFLOW_GATE_PASSED` / `WORKFLOW_GATE_HOLD` / `WORKFLOW_GATE_TIMEOUT` | Standard gate framework emissions |

## Cross-references

- `lock_sequence_policies` — what runs after this composite gate passes
- `adjustment_archive_handoff_integration` — caller pattern + handoff payload
- `tool_gate_function_signature` — gate framework contract
- `data_layer_conventions_policy` — UUID v7 + canonical JSON for audit payloads
- `audit_log_policies` — `FINALIZATION_*` domain + RLS overlay
- `audit_event_taxonomy` — event catalogue
- `adjustment_record_schema` — `adjustment_records` consumed by gate 3
- `severity_enum` — `{BLOCKING, HIGH}` predicate
- `issue_group_enum` — `Needs Confirmation` group used for re-opens
- `mobile_write_rejection_endpoints` — `archive.adjustment_finalize` rejection
- Block 15 Phase 02 — baseline 8 gates
- Block 15 Phase 08 — adjustment finalization wiring
- Block 03 Phase 05 — gate evaluation framework
- Block 03 Phase 11 — adjustment runs (architecture)
- 2026-05-08 decisions-log amendment — `{HIGH, BLOCKING}` gate-hold predicate
