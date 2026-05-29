# classification_entry_exit_gates_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification & Tagging · **Co-owners:** 03, 12, 13 · **Stage:** 4 sub-doc (Layer 2)

The SQL contract behind the CLASSIFICATION phase's entry and exit gates. Per Block 08 Phase 09's sub-doc hook, this document fixes the exact queries — column projections, predicates, index usage — that back the gate functions registered against the workflow engine. Gates are pure read-only predicates per `tool_gate_function_signature`; this sub-doc pins the SQL each predicate compiles down to, the latency budget per the Block 08 row of `fixture_performance_budget`, and the indexes on `transactions_schema` the queries depend on.

The CLASSIFICATION phase is shared between `OUT_MONTHLY` and `IN_MONTHLY` per `shared_phase_coordination_policy`. The same gate functions evaluate identically in either workflow — Block 03 Phase 10's shared-phase coordination ensures only one CLASSIFICATION instance runs per upload.

---

## Gate scope and registration

| Gate | Phase boundary guarded | Workflow types | Decision values |
| --- | --- | --- | --- |
| `classification_entry_gate` | INGESTION → CLASSIFICATION | `OUT_MONTHLY`, `IN_MONTHLY` | PASS, HOLD |
| `classification_exit_gate` | CLASSIFICATION → next phase (OUT_FILTER / IN_FILTER) | `OUT_MONTHLY`, `IN_MONTHLY` | PASS, HOLD |

Both gates conform to `tool_gate_function_signature` — `READ_ONLY`, AI tier `NONE`, 30 s hard time budget. Concrete registrations:

```ts
engine.registerTool({
  name: "classification.evaluate_entry_gate",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  audit_events: ["WORKFLOW_GATE_PASSED", "WORKFLOW_GATE_HOLD"],
  description_ref: "Docs/sub/schemas/classification_entry_exit_gates_schema.md",
});
engine.registerTool({
  name: "classification.evaluate_exit_gate",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  audit_events: ["WORKFLOW_GATE_PASSED", "WORKFLOW_GATE_HOLD"],
  description_ref: "Docs/sub/schemas/classification_entry_exit_gates_schema.md",
});
```

The gate names live in the `classification` namespace per `tool_naming_convention_policy` — both gates are evaluations *of* the classification phase boundary, so the namespace expresses responsibility correctly.

## Entry gate — "CLASSIFICATION may begin"

Two preconditions per Block 08 Phase 09:

1. **All transactions from the run's source statement exist** with non-null `classification_status` of value `PENDING` (or `NULL` for legacy rows pre-classification-status).
2. **No PENDING dedup outcomes remain** — every transaction has `dedup_status` ∈ `{NEW, DUPLICATE_EXACT, DUPLICATE_PROBABLE}`, never `NEEDS_REVIEW`. The `NEEDS_REVIEW` state is a Block 07 Phase 05 artefact that must be resolved by user action before classification can run.

### Backing SQL — predicate 1 (ingestion complete)

```sql
SELECT
  COUNT(*) AS pending_count,
  COUNT(*) FILTER (WHERE classification_status IS NULL) AS null_status_count
FROM transactions
WHERE business_id  = $1
  AND statement_upload_id = $2;
```

The gate passes predicate 1 when `pending_count > 0` (at least one transaction exists) AND `null_status_count = 0` (no row missed the classification-status default during INGESTION). The `null_status_count` check is paranoid — the `classification_status_enum DEFAULT 'PENDING'` constraint in `transactions_schema` should guarantee zero — but the gate verifies the invariant explicitly.

A zero `pending_count` (no rows ingested) routes to HOLD with `severity = MEDIUM` and `hold_reason = "Ingestion produced no transactions"`.

### Backing SQL — predicate 2 (no pending dedup)

```sql
SELECT COUNT(*) AS pending_dedup_count
FROM transactions
WHERE business_id  = $1
  AND statement_upload_id = $2
  AND dedup_status = 'NEEDS_REVIEW';
```

`pending_dedup_count = 0` is the PASS condition. Non-zero routes to HOLD with `severity = HIGH` and `review_issue_type = 'STATEMENT_DEDUP_NEEDS_REVIEW'` per `issue_type_to_group_mapping`. The user must resolve the dedup decisions (via the review queue) before the gate re-evaluates.

### Latency budget

Per the Block 08 row of `fixture_performance_budget`:

| Metric | Budget |
| --- | --- |
| Entry-gate evaluation, 100 transactions | P50 < 50 ms, P95 < 200 ms, P99 < 500 ms |
| Entry-gate evaluation, 1000 transactions | P50 < 100 ms, P95 < 400 ms, P99 < 800 ms |

Well within the 30 s hard limit from `tool_gate_function_signature`. Both queries are single-index lookups; cost is linear in result size, which is bounded by the upload's row count.

## Exit gate — "CLASSIFICATION may end"

Three preconditions per Block 08 Phase 09's exit gate:

1. **No transaction in `PENDING` state** — every transaction's `classification_status` is either `CONFIRMED` or `NEEDS_CONFIRMATION` (or `FAILED`, treated as HOLD-blocking).
2. **No transaction with `transaction_type IS NULL`** — even `UNKNOWN` is acceptable; null is not.
3. **All `NEEDS_CONFIRMATION` rows have review issues** — for every transaction in `NEEDS_CONFIRMATION`, exactly one row exists in `review_issues` keyed by `(business_id, target_record_kind = 'transactions', target_record_id = transaction_id, issue_type = 'CLASSIFICATION_NEEDS_CONFIRMATION')`.

### Backing SQL — predicate 1 (no PENDING / FAILED)

```sql
SELECT
  COUNT(*) FILTER (WHERE classification_status = 'PENDING') AS pending_count,
  COUNT(*) FILTER (WHERE classification_status = 'FAILED')  AS failed_count
FROM transactions
WHERE business_id  = $1
  AND statement_upload_id = $2;
```

Gate passes when both counts are zero. `pending_count > 0` → HOLD with `severity = HIGH`, `hold_reason = "Classification incomplete"`. `failed_count > 0` → HOLD with `severity = BLOCKING`, `hold_reason = "Classification failed on N rows"`.

### Backing SQL — predicate 2 (transaction_type set)

```sql
SELECT COUNT(*) AS null_type_count
FROM transactions
WHERE business_id  = $1
  AND statement_upload_id = $2
  AND transaction_type IS NULL;
```

`null_type_count = 0` PASS condition. Per `transaction_type_enum`, `UNKNOWN` is the canonical placeholder for deferred classification — `NULL` is a schema-invariant violation and routes to HOLD with `severity = BLOCKING`.

### Backing SQL — predicate 3 (review issues covered)

```sql
WITH needs_confirm AS (
  SELECT transaction_id
  FROM transactions
  WHERE business_id  = $1
    AND statement_upload_id = $2
    AND classification_status = 'NEEDS_CONFIRMATION'
),
covered AS (
  SELECT DISTINCT target_record_id AS transaction_id
  FROM review_issues
  WHERE business_id  = $1
    AND target_record_kind = 'transactions'
    AND issue_type = 'CLASSIFICATION_NEEDS_CONFIRMATION'
    AND status IN ('OPEN', 'SNOOZED')
)
SELECT COUNT(*) AS uncovered_count
FROM needs_confirm nc
LEFT JOIN covered c USING (transaction_id)
WHERE c.transaction_id IS NULL;
```

`uncovered_count = 0` is the PASS condition. A non-zero count is a `classification.assign_status` writer bug — every `NEEDS_CONFIRMATION` write is supposed to raise an issue in the same operational transaction. The gate emits HOLD with `severity = BLOCKING` and `hold_reason = "Review issue coverage incomplete"` to halt finalization rather than silently advance with an unsurfaced confirmation backlog.

### Latency budget

Per the Block 08 row of `fixture_performance_budget` and the Block 14 row for review-queue queries:

| Metric | Budget |
| --- | --- |
| Exit-gate evaluation, 100 transactions | P50 < 100 ms, P95 < 300 ms, P99 < 800 ms |
| Exit-gate evaluation, 1000 transactions | P50 < 300 ms, P95 < 1 s, P99 < 3 s |

The exit gate is heavier than the entry gate because predicate 3 joins `transactions` to `review_issues`. Both tables carry tenant-prefixed indexes the join uses.

## Index dependencies on `transactions_schema`

Per `transactions_schema`, the following indexes are required for the SQL above to meet budget:

```sql
-- Entry / exit predicate 1 (statement-scoped scan)
CREATE INDEX idx_transactions_statement
  ON transactions(business_id, statement_upload_id);

-- Entry predicate 2 (NEEDS_REVIEW filter)
CREATE INDEX idx_transactions_dedup_review
  ON transactions(business_id, statement_upload_id, dedup_status)
  WHERE dedup_status = 'NEEDS_REVIEW';

-- Exit predicate 1 (status filter for the same statement)
CREATE INDEX idx_transactions_classification_queue
  ON transactions(business_id, classification_status, transaction_date)
  WHERE classification_status = 'NEEDS_CONFIRMATION';
```

The first two indexes are already declared on `transactions_schema`. The partial dedup index is additive — added by Block 07 Phase 05's deduplication-engine sub-doc and consumed here. The classification-queue index is the same partial index used for the review-queue list view.

For `review_issues`, the join predicate 3 uses the existing `(business_id, target_record_kind, target_record_id)` index from `review_issues_schema`.

## Re-evaluation semantics

When predicate 2 or 3 of the exit gate fails, the engine holds the phase. After a user resolves the gating review issue (via `review_queue.apply_resolution_action`), the gate re-evaluates. Re-evaluation is invoked by Block 03 Phase 05's `WORKFLOW_GATE_PASSED` / `WORKFLOW_GATE_HOLD` audit-event subscription — there is no manual gate-poke surface.

Each re-evaluation emits a fresh `WORKFLOW_GATE_PASSED` or `WORKFLOW_GATE_HOLD` event per `audit_event_taxonomy`, in its own short transaction per `audit_log_policies` emit-as-separate-transaction rule. The hash-chain partitioning is per-business; gate evaluations on different businesses do not contend.

## Per-business config interaction

Per Block 08 Phase 09: a business may disable `apply_layer3`. The exit gate is identical regardless of this toggle. When Layer 3 is disabled, transactions flow through Layers 1 + 2 only; unresolved rows reach `NEEDS_CONFIRMATION` with `classification_method = NO_AI_AVAILABLE`. Predicate 3 still requires a review issue to be present — the disabled-Layer-3 path uses the same issue_type as the enabled path.

## Shared-phase coordination interaction

Per `shared_phase_coordination_policy`, when both `OUT_MONTHLY` and `IN_MONTHLY` are triggered from the same upload, CLASSIFICATION runs once and both runs share the result. The entry gate evaluates per-run (each run independently observes the same passing predicates); the exit gate likewise evaluates per-run. The shared `statement_upload_id` in the SQL is the binding key — both runs query the same `transactions` rows.

## Audit emission

Each gate evaluation emits exactly one event per call:

- PASS → `WORKFLOW_GATE_PASSED` with `{ gate_name, phase_name = "CLASSIFICATION", evaluated_at }`.
- HOLD → `WORKFLOW_GATE_HOLD` with `{ gate_name, phase_name, hold_reason, severity, review_issue_type? }`.

Both events follow `audit_log_policies` Section 1 conventions and are recorded in the canonical taxonomy already. The `severity` field uses `severity_enum` — exactly one of `LOW`, `MEDIUM`, `HIGH`, `BLOCKING`.

## Mobile considerations

Gate evaluation is server-side and never exposed to a user surface — there is no mobile rejection concern for the gate itself. The downstream resolution actions a user takes when a gate HOLDS (e.g., resolving a `NEEDS_CONFIRMATION` issue) are mobile-rejected per `mobile_write_rejection_endpoints`.

## Cross-references

- `transactions_schema` — base table and index inventory
- `tool_gate_function_signature` — gate signature contract (READ_ONLY, AI tier NONE, 30 s budget)
- `data_layer_conventions_policy` — UUID v7 for `transaction_id`, canonical JSON in gate audit payloads
- `audit_log_policies` — `WORKFLOW_GATE_PASSED` / `WORKFLOW_GATE_HOLD` emit rules, per-business chain
- `audit_event_taxonomy` — both events already catalogued
- `transaction_type_enum` — `UNKNOWN` is acceptable, NULL is not
- `severity_enum` — gate HOLD severities only from the closed 4-value set
- `fixture_performance_budget` — Block 08 latency targets
- `review_issues_schema` — join target for exit-gate predicate 3
- `issue_type_to_group_mapping` — `CLASSIFICATION_NEEDS_CONFIRMATION`, `STATEMENT_DEDUP_NEEDS_REVIEW`
- `shared_phase_coordination_policy` — OUT/IN shared evaluation
- Block 08 Phase 09 — CLASSIFICATION phase registration
- Block 03 Phase 05 — gate evaluation framework
