# out_adjustment_type_definition

**Category:** Schemas · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

The `OUT_ADJUSTMENT` workflow type — its trigger conditions, schema extensions beyond the base `workflow_runs` row, the adjustment scope it targets, and the abbreviated phase sequence it executes. `OUT_ADJUSTMENT` is the expense-side parallel to `IN_ADJUSTMENT` (Block 13). The authoritative source phase doc is Block 12 Phase 09. This sub-doc is the normative schema companion to that phase doc.

---

## Type registration overview

```ts
engine.registerWorkflowType({
  type_name: "OUT_ADJUSTMENT",

  phases: [
    {
      phase_name: "OUT_FILTER",
      is_side_phase: false,
      tools: ["out_workflow.run_out_filter"],
      // Scoped to adjustment_scope transaction IDs only.
      // Full-period re-scan is not performed.
    },
    {
      phase_name: "MATCHING",
      is_side_phase: false,
      tools: [
        "matching.score_pair",
        "matching.confirm_match",
        "out_workflow.record_matching_outcome",
      ],
    },
    {
      phase_name: "LEDGER_PREPARATION",
      is_side_phase: false,
      tools: [
        "ledger.resolve_counterparty",
        "ledger.decide_vat_treatment",
        "ledger.prepare_entries",
        "ledger.prepare_invoice_lifecycle_entries",
      ],
      // Block 11 Phase 09 consolidation: covers both ledger preparation
      // and VAT reclassification in a single phase, scoped to the delta.
    },
    {
      phase_name: "HUMAN_REVIEW_HOLD",
      is_side_phase: false,
      // Not a conditional side phase in OUT_ADJUSTMENT — always entered.
      tools: [
        "out_workflow.user_approval",
        "out_workflow.user_revoke_approval",
        "review_queue.unsnooze_at_run_start",
      ],
    },
    {
      phase_name: "FINALIZATION",
      is_side_phase: false,
      tools: [
        "archive.lock_period",
        "report.generate_period_report",
      ],
    },
  ],

  triggers: {
    manual: {
      tool: "out_workflow.start_adjustment_run",
    },
  },
  // No event-driven trigger for OUT_ADJUSTMENT. Manual only (Stage 1).

  per_business_config_table: "out_workflow_configs",
});
```

---

## What is skipped vs OUT_MONTHLY

`OUT_ADJUSTMENT` skips `INGESTION`, `CLASSIFICATION`, `EVIDENCE_DISCOVERY_EMAIL`, `EVIDENCE_DISCOVERY_DRIVE`, and `AI_END_SCAN`. These phases are omitted because the adjustment targets a specific delta scope within a period that was already fully processed. Evidence discovery is unnecessary because any new evidence is submitted directly via the `adjustment_scope`'s `ADD_EVIDENCE` delta kind. `AI_END_SCAN` is replaced by the mandatory `HUMAN_REVIEW_HOLD` — the adjustment is always human-reviewed.

| Phase | OUT_MONTHLY | OUT_ADJUSTMENT |
| --- | --- | --- |
| `INGESTION` | Yes | **Skipped** |
| `CLASSIFICATION` | Yes | **Skipped** |
| `OUT_FILTER` | Yes | Yes — delta scope only |
| `EVIDENCE_DISCOVERY_EMAIL` | Yes | **Skipped** |
| `EVIDENCE_DISCOVERY_DRIVE` | Yes | **Skipped** |
| `MATCHING` | Yes | Yes — delta scope only |
| `MANUAL_UPLOAD_HOLD` | Side phase (conditional) | **Skipped** — evidence submitted via adjustment_scope |
| `LEDGER_PREPARATION` | Yes | Yes — delta scope only |
| `AI_END_SCAN` | Yes | **Skipped** |
| `HUMAN_REVIEW_HOLD` | Side phase (conditional) | **Always entered** |
| `FINALIZATION` | Yes | Yes — additive interleave only |

`HUMAN_REVIEW_HOLD` is mandatory for `OUT_ADJUSTMENT` (not conditional): every adjustment must be explicitly approved before finalization. This matches the `OTHER` delta-kind rule from Block 12 Phase 09 — ambiguous adjustments always require human review, so the simpler policy is to require review on all adjustment runs.

---

## Schema extensions on `workflow_runs`

`OUT_ADJUSTMENT` runs use the standard `workflow_runs` row per `workflow_run_schema`. The adjustment-specific fields are populated for `workflow_type = 'OUT_ADJUSTMENT'` rows and are NULL for other types:

| Column | Type | Constraint | Description |
| --- | --- | --- | --- |
| `parent_run_id` | uuid | NOT NULL for OUT_ADJUSTMENT; FK → `workflow_runs` | References the original `OUT_MONTHLY` run or the most recent `OUT_ADJUSTMENT` for the same period |
| `adjustment_reason` | text | NOT NULL for OUT_ADJUSTMENT | Free-text reason for the adjustment; minimum 10 characters enforced at application layer |
| `adjustment_scope` | jsonb | NOT NULL for OUT_ADJUSTMENT | Structured scope descriptor; see shape below |

These columns are NULL for `IN_MONTHLY`, `OUT_MONTHLY`, `IN_ADJUSTMENT`, and all other non-adjustment run types.

### `adjustment_scope` shape

```json
{
  "affected_transaction_ids": ["<uuid>", "<uuid>"],
  "delta_kinds": ["RECLASSIFY_TRANSACTION", "CORRECT_VAT_TREATMENT"],
  "scope_description": "Reclassify bank fee as professional services; correct VAT treatment for EU B2B"
}
```

`affected_transaction_ids` must be non-empty — an `OUT_ADJUSTMENT` must target at least one transaction. `delta_kinds` is a non-empty array of values from the delta kind taxonomy defined in Block 12 Phase 09: `RECLASSIFY_TRANSACTION`, `ADD_EVIDENCE`, `CORRECT_VAT_TREATMENT`, `ADJUST_AMOUNT`, `OTHER`. `scope_description` is optional free text. All fields use canonical JSON per `data_layer_conventions_policy`.

---

## `parent_run_id` constraint

`parent_run_id` must reference a FINALIZED run. This constraint is enforced at the application layer by `out_workflow.start_adjustment_run` before the run row is inserted. A parent that is not FINALIZED is rejected with audit event `OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`.

The `parent_run_id` may reference:
- The original `OUT_MONTHLY` run for the period.
- The most recent `OUT_ADJUSTMENT` for the same period (for chained corrections). Chained adjustments reference the prior adjustment to form an explicit lineage chain.

The `workflow_run_schema` CHECK constraint enforces `parent_run_id IS NOT NULL` for all `*_ADJUSTMENT` types.

---

## Retention cap

`out_workflow.start_adjustment_run` checks the parent period's `period_start` against the 6-year Cyprus VAT statutory retention window, consistent with `out_config_schema.out_adjustment_max_lookback_years`:

```
parent_run.period_start >= now() - INTERVAL '? years'
```

where `?` is the business's `out_adjustment_max_lookback_years` (default 6, maximum 6). Periods outside the window are rejected with `OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED` before any run row is created.

---

## Delta and adjustment record

On completion of the `LEDGER_PREPARATION` phase, the `OUT_ADJUSTMENT` run produces one or more `adjustment_record` rows (defined in `adjustment_record_schema`). Each row describes a single change to a ledger entry, VAT classification, or match record, including before/after state. Original FINALIZED rows are never modified (additive-only enforcement per Block 03 Phase 11).

The adjustment delta kinds supported are:

| Kind | Description |
| --- | --- |
| `RECLASSIFY_TRANSACTION` | Change `transaction_type` on a previously classified transaction |
| `ADD_EVIDENCE` | Attach new evidence document to an unmatched or partially matched transaction |
| `CORRECT_VAT_TREATMENT` | Update VAT treatment on a ledger entry (uses Block 11's manual-override path) |
| `ADJUST_AMOUNT` | Correct an amount on a ledger entry (rare; most amount changes route through reclassify or add evidence) |
| `OTHER` | Free-form; always sets `requires_accountant_review = true` on all produced adjustment records; `HUMAN_REVIEW_HOLD` is mandatory |

---

## Concurrency invariant exception

`OUT_ADJUSTMENT` runs may run concurrently with the next `OUT_MONTHLY` run. This is an explicit Stage 1 decision (see `workflow_state_enum` concurrency invariants and `decisions_log.md`). The engine's one-active-run-per-type rule is scoped per `(business_id, workflow_type)` — `OUT_ADJUSTMENT` and `OUT_MONTHLY` are different `workflow_type` values and do not contend.

Two `OUT_ADJUSTMENT` runs against the same period may not run concurrently — the one-active-run-per-type rule still applies within the `OUT_ADJUSTMENT` type itself for the same period. The engine enforces this via `(business_id, workflow_type, period_start, period_end)` uniqueness among non-terminal runs.

Cross-run consistency: if an `OUT_ADJUSTMENT` finalizes after a downstream `OUT_MONTHLY` has already started for the next period, the adjustment is interleaved into the older period's archive only — it does not affect the newer period's draft entries.

---

## Trigger

Manual only for Stage 1. The user initiates an `OUT_ADJUSTMENT` run from the Block 16 dashboard's "Adjust this period" surface. No event-driven adjustment triggers are planned in MVP. The tool is `out_workflow.start_adjustment_run`.

---

## Permission gate

Owner, Admin, and Bookkeeper may initiate `OUT_ADJUSTMENT` runs (same as `OUT_MONTHLY`). Accountant, Reviewer, and Read-only are denied. Any initiation attempt from `client_form_factor = MOBILE` is rejected with `MOBILE_WRITE_REJECTED`. Reference: `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | Domain | Severity | Trigger |
| --- | --- | --- | --- |
| `OUT_ADJUSTMENT_RUN_CREATED` | OUT_ADJUSTMENT | MEDIUM | New `OUT_ADJUSTMENT` run row inserted; payload includes `parent_run_id`, `adjustment_reason`, scope summary |

Additional events from `OUT_ADJUSTMENT` domain fire during the phases per `audit_event_taxonomy`: `OUT_ADJUSTMENT_CREATED`, `OUT_ADJUSTMENT_LEDGER_PREP_COMPLETED`, `OUT_ADJUSTMENT_HUMAN_REVIEW_HELD`, `OUT_ADJUSTMENT_APPROVED`, `OUT_ADJUSTMENT_RECORD_CREATED`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for run IDs; canonical JSON for `adjustment_scope`
- `audit_log_policies` — `OUT_ADJUSTMENT` domain; past-tense event naming
- `audit_event_taxonomy` — `OUT_ADJUSTMENT_RUN_CREATED` and full OUT_ADJUSTMENT domain
- `workflow_run_schema` — base `workflow_runs` table; `parent_run_id` lineage; adjustment constraint
- `workflow_state_enum` — concurrency invariant exception for adjustment types
- `out_config_schema` — `out_adjustment_max_lookback_years` cap; per-business config
- `out_monthly_phase_sequence` — full OUT_MONTHLY phase sequence for comparison
- `adjustment_record_schema` — delta record produced by the adjustment phases
- `mobile_write_rejection_endpoints` — mobile write rejection enforcement
- Block 12 Phase 09 — authoritative source phase doc for `OUT_ADJUSTMENT`; delta kinds; additive enforcement
- `in_adjustment_type_definition` — parallel IN-side structure for comparison
- Block 15 Phase 04 — additive finalization interleave for adjustment runs
- Block 03 Phase 11 — adjustment runs framework; additive-only enforcement
- `decisions_log.md` — Stage 1 OUT_ADJUSTMENT concurrency decision; 6-year retention cap
