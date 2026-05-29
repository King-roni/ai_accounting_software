# filter_rerun_semantics_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The semantics for re-running OUT_FILTER or IN_FILTER on a transaction or set of transactions. Per Block 12 Phase 03 fix: the filter decision lives in two columns (one per direction); re-running a filter overwrites these. This policy pins when re-runs fire, the transition audit shape, and downstream impact.

---

## When filter re-runs fire

| Trigger | Scope |
| --- | --- |
| Schema migration affecting filter logic | All transactions for affected businesses |
| Adjustment workflow run (OUT_ADJUSTMENT / IN_ADJUSTMENT) | Transactions touched by the adjustment |
| Late statement upload (a statement arrives for a period whose runs have already advanced past FILTER) | Newly-imported transactions |
| Operator manual re-run via `engine.rerun_filter(business_id, scope)` | Scope-specified transactions |
| Classification correction (a transaction's `transaction_type` changes via `tool_invoice_lifecycle_integration` or `RECLASSIFY_TYPE` action) | The single transaction |

Filter re-runs are NOT triggered by:
- Routine workflow phase advancement (filters run once per workflow run; that's normal, not a re-run)
- Transaction edits that don't affect `transaction_type` (e.g., changing notes)

## Re-run vs initial run

| Property | Initial run | Re-run |
| --- | --- | --- |
| `out_filter_decided_at` | NULL → timestamp | Old timestamp → new timestamp |
| `out_filter_decided_by_run_id` | NULL → run_id | Old run_id → new run_id |
| Audit event | `OUT_FILTER_INCLUDED_TRANSACTION` (per-row) OR `OUT_FILTER_RAN` (aggregate per Block 12 scan fix) | Same — but with `re_run_count` incremented |
| Downstream cascade | First-time classification → ledger prep → review queue | Re-evaluation: comparing new filter decision to existing downstream state |

The decision columns are overwritten (not appended). Forensic history lives in the audit log.

## Aggregate event shape

Per the 2026-05-08 Block 12 scan fix: per-row events were collapsed into the aggregate `OUT_FILTER_RAN` / `IN_FILTER_RAN`:

```ts
emitAudit("OUT_FILTER_RAN", {
  workflow_run_id,
  business_id,
  filter_run_kind: "INITIAL" | "RE_RUN",
  scope_kind: "FULL_PERIOD" | "ADJUSTMENT" | "SINGLE_TRANSACTION" | "LATE_UPLOAD",
  transaction_count_evaluated: integer,
  transaction_count_included: integer,
  transaction_count_excluded: integer,
  cause: "..."                                     // free-text for re-runs: which migration / which adjustment
});
```

Symmetric for `IN_FILTER_RAN`. The per-transaction inclusion/exclusion decisions live in the `transactions.*_filter_decided_*` columns; the aggregate event captures the run-level outcome.

## Re-run cascade

When a filter re-run changes a transaction's inclusion status (excluded → included OR included → excluded):

| Case | Cascade |
| --- | --- |
| Was excluded, now included | The transaction enters the downstream pipeline — Block 11 ledger prep, then Block 14 review queue (if not already cleared) |
| Was included, now excluded | The transaction's ledger entries are voided per `ledger_recompute_side_effects_policy`; review-queue issues against the transaction are auto-resolved per Block 14 Phase 08's re-scan |
| Status unchanged | No cascade |

Block 11's `ledger.recompute_entries` (per Block 11 Phase 09) reads the new filter decisions and replaces affected ledger rows in one transaction.

## Audit forensic capture

For a re-run that flipped a transaction's filter status, the audit log carries:

```
WORKFLOW_TOOL_INVOKED              (re-run dispatch)
OUT_FILTER_RAN                     (aggregate per the new run)
TRANSACTION_FILTER_STATUS_CHANGED  (per-transaction flip, when status differs from prior)
LEDGER_ENTRIES_RECOMPUTED          (per affected transaction)
```

The `TRANSACTION_FILTER_STATUS_CHANGED` event is the only per-row event emitted on re-run (initial runs use only the aggregate). It captures:

```ts
{
  transaction_id,
  direction: "OUT" | "IN",
  old_decision: { decided_at, decided_by_run_id, was_included },
  new_decision: { decided_at, decided_by_run_id, was_included },
  cause
}
```

## Concurrency

Re-runs serialize per business per direction via advisory lock. Two concurrent re-runs on the same business + same direction wait for each other.

Re-runs in different directions (OUT + IN) on the same business proceed independently.

Cross-business re-runs do not contend.

## Downstream notification

After a filter re-run completes, the trigger engine per `event_subscription_pipeline_integration` notifies:

- Block 14 (review queue) — to re-evaluate any open issues against the affected transactions
- Block 11 (ledger preparation) — to recompute affected entries
- Block 16 (dashboard) — to invalidate cached aggregates via `dashboard_card_policies`

## In-flight run protection

A filter re-run cannot fire on transactions inside a workflow run that's currently in `LEDGER_PREPARATION`, `HUMAN_REVIEW_HOLD`, `AWAITING_APPROVAL`, or `FINALIZING` states. The engine rejects with `RE_RUN_BLOCKED_BY_ACTIVE_RUN`.

The user must wait for the active run to complete (or cancel it) before re-running the filter. Per `out_adjustment_policies`: the supported mid-period correction path is an adjustment run, not a filter re-run.

## Cross-references

- `filter_rule_type_direction_table` — filter routing rules
- `transactions_schema` — `*_filter_decided_*` columns
- `ledger_recompute_side_effects_policy` — Block 11 recompute
- `audit_log_policies` — `OUT_FILTER_RAN` / `IN_FILTER_RAN` / `TRANSACTION_FILTER_STATUS_CHANGED` events
- `out_adjustment_policies` (consolidated) — adjustment-run path
- `per_business_toggle_short_circuit_policy` — sibling policy
- `event_subscription_pipeline_integration` — downstream notification
- Block 12 Phase 03 — OUT_FILTER (architecture)
- Block 13 Phase 08 — IN_FILTER (architecture)
- 2026-05-08 Block 12 scan fix — aggregate event collapsing

---

## Filter re-run trigger examples

**Example 1: Operator manually overrides a filter decision**

The operator (Owner/Admin role via `engine.rerun_filter`) determines that a transaction was incorrectly excluded from the OUT_FILTER because the rule engine had a stale vendor classification at the time of the initial run. Steps:

1. Operator invokes `engine.rerun_filter(business_id, scope = { transaction_id: "txn_abc" })`
2. Engine acquires advisory lock for OUT direction on this business
3. Single transaction is re-evaluated against the current rule set
4. Decision changes from EXCLUDED to INCLUDED; `out_filter_decided_at` is overwritten; `out_filter_decided_by_run_id` is set to a system-generated re-run ID
5. `TRANSACTION_FILTER_STATUS_CHANGED` emitted; cascade to Block 11 and Block 14 fires
6. The transaction enters the downstream pipeline; a new ledger entry is prepared

The advisory lock ensures no concurrent re-run for OUT direction on this business during the operation.

**Example 2: New rule version deployed mid-run**

A schema migration updates the OUT filter rule set (e.g., a new rule for a new bank fee pattern is added). The migration runs the `engine.rerun_filter` for all businesses affected:

1. Migration detects which businesses have transactions classified under the old rule version
2. Batched `engine.rerun_filter(business_id, scope = "FULL_PERIOD", cause = "rule_migration_v2.3.1")` is enqueued for each
3. Each business's re-run fires in sequence (per the advisory lock — businesses don't contend with each other)
4. `OUT_FILTER_RAN` aggregate event includes `cause = "rule_migration_v2.3.1"` for traceability
5. Any status-changed transactions get `TRANSACTION_FILTER_STATUS_CHANGED` with `cause` set to the migration reference

The migration cause string is free-text; it is preserved in the audit log for forensic queries like "which transactions changed filter status due to this migration?"

---

## Idempotency guarantees

A filter re-run is idempotent when the rule set and transaction data have not changed between re-runs. Specifically:

- If the same `engine.rerun_filter` call is made twice with identical parameters and no data has changed between the two calls, the second call produces identical `*_filter_decided_at` timestamps and `*_filter_decided_by_run_id` values — OR the second call sees that the current filter decision already matches the re-run result and skips the write entirely (no-op detection)
- The `TRANSACTION_FILTER_STATUS_CHANGED` event fires only when the decision actually changes; a no-op re-run emits only the aggregate `OUT_FILTER_RAN` with `scope_kind = RE_RUN` and `transaction_count_evaluated = N`, `transaction_count_included = N` (unchanged)
- Downstream cascade (Block 11, Block 14) fires only when `TRANSACTION_FILTER_STATUS_CHANGED` is emitted — idempotent re-runs do not trigger unnecessary ledger recomputes

The idempotency guarantee relies on the rule set being deterministic for a given transaction's data. If the rule set is non-deterministic (e.g., uses a timestamp-relative rule like "transactions from the last 30 days"), re-runs at different times may produce different results for the same transaction data — this is expected and not a violation of idempotency; it's a property of time-relative rules.

---

## Additional cross-references

- `out_phase_gate_policy` — the gate that decides whether OUT_FILTER results are acceptable to advance; re-runs may affect gate outcomes
- `retry_policy` — retry behavior for filter re-runs that fail partway through (e.g., database error mid-batch)
