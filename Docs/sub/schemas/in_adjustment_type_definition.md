# in_adjustment_type_definition

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

The `IN_ADJUSTMENT` workflow type — its trigger conditions, schema extensions beyond the base `workflow_runs` row, the adjustment scope it targets, and the abbreviated phase sequence it executes. `IN_ADJUSTMENT` is the income-side parallel to `OUT_ADJUSTMENT` (Block 12 Phase 09). Both types share the base `workflow_runs` table; `IN_ADJUSTMENT` contributes the `adjustment_reason` and `adjustment_scope` fields documented here.

---

## Type registration overview

```ts
engine.registerWorkflowType({
  type_name: "IN_ADJUSTMENT",

  phases: [
    {
      phase_name: "IN_FILTER",
      is_side_phase: false,
      tools: ["in_workflow.run_in_filter"],
      // Scoped to adjustment_scope invoice IDs and transaction IDs only.
      // Full-period re-scan is not performed.
    },
    {
      phase_name: "INCOME_MATCHING",
      is_side_phase: false,
      tools: [
        "matching.score_income_pairs",
        "matching.propose_multi_invoice_allocation",
        "in_workflow.record_income_matching_outcome",
      ],
    },
    {
      phase_name: "LEDGER_PREPARATION",
      is_side_phase: false,
      tools: [
        "ledger.resolve_counterparty",
        "ledger.decide_vat_treatment",
        "ledger.prepare_income_entries",
        "ledger.prepare_invoice_lifecycle_entries",
      ],
    },
    {
      phase_name: "HUMAN_REVIEW_HOLD",
      is_side_phase: true,
      tools: [
        "in_workflow.record_approval",
        "in_workflow.revoke_approval",
        "review_queue.unsnooze_at_run_start",
      ],
    },
    {
      phase_name: "FINALIZATION",
      is_side_phase: false,
      tools: [
        "archive.lock_period",
        "in_workflow.finalize_invoice",
        "report.generate_period_report",
      ],
    },
  ],

  triggers: {
    manual: {
      tool: "in_workflow.start_adjustment_run",
    },
  },
  // No event-driven trigger for IN_ADJUSTMENT. Manual only (Stage 1).

  per_business_config_table: "in_workflow_business_config",
});
```

---

## What is skipped vs IN_MONTHLY

`IN_ADJUSTMENT` skips `INGESTION` and `CLASSIFICATION`. These phases are omitted because the adjustment operates on a delta scope (specific invoice IDs and transaction IDs) within a period that was already ingested and classified. Re-running the full ingestion pipeline would not change the base data — it would only add new rows, which is not the purpose of an adjustment.

| Phase | IN_MONTHLY | IN_ADJUSTMENT |
| --- | --- | --- |
| `INGESTION` | Yes | **Skipped** |
| `CLASSIFICATION` | Yes | **Skipped** |
| `IN_FILTER` | Yes | Yes — delta scope only |
| `INCOME_MATCHING` | Yes | Yes — delta scope only |
| `LEDGER_PREPARATION` | Yes | Yes — delta scope only |
| `AI_END_SCAN` | Yes | **Skipped** — adjustment scope is human-reviewed via HUMAN_REVIEW_HOLD gate |
| `HUMAN_REVIEW_HOLD` | Side phase | **Always entered** (not conditional; see below) |
| `FINALIZATION` | Yes | Yes — additive interleave only |

`AI_END_SCAN` is skipped in `IN_ADJUSTMENT` because the adjustment scope is small and explicitly human-reviewed via the mandatory `HUMAN_REVIEW_HOLD`. Routing to a side phase conditionally on AI findings is unnecessary overhead for a targeted correction.

`HUMAN_REVIEW_HOLD` is mandatory for `IN_ADJUSTMENT` (not a side phase in practice): the `IN_FILTER` gate always routes to `HUMAN_REVIEW_HOLD` after the adjustment phases complete, regardless of blocking issue count. An adjustment must always be explicitly approved before finalization.

---

## Schema extensions on `workflow_runs`

`IN_ADJUSTMENT` runs use the standard `workflow_runs` row (defined in `workflow_run_schema`). No additional columns are added to that table. The adjustment-specific fields are carried in additional columns that are populated for `workflow_type = 'IN_ADJUSTMENT'` rows and NULL for other types.

These columns are defined in `workflow_run_schema` under the "Adjustment lineage" section and additionally:

| Column | Type | Constraint | Description |
| --- | --- | --- | --- |
| `parent_run_id` | uuid | NOT NULL for IN_ADJUSTMENT; FK → `workflow_runs` | References the original `IN_MONTHLY` run or the most recent `IN_ADJUSTMENT` for the same period |
| `adjustment_reason` | text | NOT NULL for IN_ADJUSTMENT | Free-text reason for the adjustment; minimum 10 characters enforced at application layer |
| `adjustment_scope` | jsonb | NOT NULL for IN_ADJUSTMENT | Structured scope descriptor; see shape below |

`adjustment_reason` and `adjustment_scope` are carried on `workflow_runs` via a forward migration. They are always NULL for `OUT_MONTHLY`, `IN_MONTHLY`, `OUT_ADJUSTMENT`, and other non-adjustment run types.

### `adjustment_scope` shape

```json
{
  "affected_invoice_ids": ["<uuid>", "<uuid>"],
  "affected_transaction_ids": ["<uuid>"],
  "scope_description": "Missed invoice INV-2026-0042 for client Acme Ltd"
}
```

At least one of `affected_invoice_ids` or `affected_transaction_ids` must be non-empty. `scope_description` is optional free text summarising what the scope covers; it is not the same as `adjustment_reason` (which explains why the adjustment is needed). Both fields are canonical JSON per `data_layer_conventions_policy`.

---

## `parent_run_id` constraint

`parent_run_id` must reference a FINALIZED run (`workflow_runs.status = 'FINALIZED'`). This constraint is enforced at the application layer by `in_workflow.start_adjustment_run` before the `IN_ADJUSTMENT` run row is inserted. A run whose parent is not FINALIZED is rejected with structured error `IN_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`.

The `parent_run_id` may reference:
- The original `IN_MONTHLY` run for the period (most common).
- The most recent `IN_ADJUSTMENT` run for the same period (when a second correction is applied to a period that has already had one adjustment). Chained adjustments reference the prior adjustment, not the original monthly run, to form an explicit lineage chain.

The `workflow_run_schema` CHECK constraint `(workflow_type NOT IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT')) OR (parent_run_id IS NOT NULL)` enforces that `parent_run_id` is never null for adjustment types.

---

## Retention cap

`in_workflow.start_adjustment_run` checks that the parent period's `period_start` is within the 6-year Cyprus VAT statutory retention window:

```
parent_run.period_start >= now() - INTERVAL '6 years'
```

Periods outside the window are rejected before the run row is created, with audit event `IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`. This matches the symmetric cap in `out_config_schema` (`out_adjustment_max_lookback_years = 6`).

---

## Delta and adjustment record

On completion of the `LEDGER_PREPARATION` phase, the `IN_ADJUSTMENT` run produces one or more `adjustment_record` rows (defined in `adjustment_record_schema`). Each `adjustment_record` row describes a single change made to a ledger entry, invoice allocation, or income match record, including the before/after state. The `adjustment_record` rows are additive — original FINALIZED rows are never modified.

---

## Concurrency

`IN_ADJUSTMENT` runs may run concurrently with the next `IN_MONTHLY` run per the Stage 1 concurrency invariant exception (see `workflow_state_enum`, concurrency invariants section). The engine's one-active-run-per-business-per-type rule is scoped to `(business_id, workflow_type)` — `IN_ADJUSTMENT` and `IN_MONTHLY` are different `workflow_type` values and do not contend. An `IN_ADJUSTMENT` for an old period and an `IN_MONTHLY` for the current period can both be active simultaneously.

---

## Trigger

Manual only for Stage 1. The user initiates an `IN_ADJUSTMENT` run from the Block 16 dashboard's "Adjust this period" surface. The tool is `in_workflow.start_adjustment_run`. No event-driven trigger for adjustment runs is planned in MVP.

---

## Permission gate

Owner, Admin, and Bookkeeper may initiate `IN_ADJUSTMENT` runs (same as `IN_MONTHLY`). Accountant, Reviewer, and Read-only are denied. Any initiation attempt from `client_form_factor = MOBILE` is rejected with `MOBILE_WRITE_REJECTED`. Reference: `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | Domain | Severity | Trigger |
| --- | --- | --- | --- |
| `IN_ADJUSTMENT_RUN_CREATED` | IN_ADJUSTMENT | MEDIUM | New `IN_ADJUSTMENT` run row inserted; payload includes `parent_run_id`, `adjustment_reason`, scope summary |

Additional events from `IN_WORKFLOW` and `IN_ADJUSTMENT` domains fire during the phases (e.g., `IN_ADJUSTMENT_CREATED`, `IN_ADJUSTMENT_APPROVED`, `IN_ADJUSTMENT_RECORD_CREATED` per `audit_event_taxonomy`).

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for run IDs; canonical JSON for `adjustment_scope`
- `audit_log_policies` — `IN_ADJUSTMENT` domain; past-tense event naming
- `audit_event_taxonomy` — `IN_ADJUSTMENT_RUN_CREATED`, `IN_ADJUSTMENT_CREATED`, `IN_ADJUSTMENT_APPROVED` under IN_ADJUSTMENT domain
- `workflow_run_schema` — base `workflow_runs` table; `parent_run_id` lineage; adjustment constraint
- `workflow_state_enum` — concurrency invariant exception for adjustment types
- `in_monthly_type_definition` — parallel IN_MONTHLY phase sequence; shared phase contracts
- `adjustment_record_schema` — delta record produced by the adjustment phases
- `mobile_write_rejection_endpoints` — mobile write rejection enforcement
- Block 12 Phase 09 — `OUT_ADJUSTMENT` parallel structure; concurrency decision
- Block 13 Phase 11 — IN_ADJUSTMENT implementation; `v_invoices_with_adjustments` view
- Block 15 Phase 04 — additive finalization interleave for adjustment runs
- Block 03 Phase 11 — adjustment runs framework; `parent_run_id` additive-only enforcement
