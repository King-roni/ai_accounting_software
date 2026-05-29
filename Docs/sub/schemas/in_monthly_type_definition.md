# in_monthly_type_definition

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

The exact TypeScript shape of the `IN_MONTHLY` workflow type registration call. This sub-doc is the normative source for the engine's boot-time registration of `IN_MONTHLY`. It is the parallel to Block 12 Phase 02's `OUT_MONTHLY` type definition. After boot, calling `engine.startWorkflowRun({ type: 'IN_MONTHLY', ... })` produces a run whose `effective_phase_sequence_json` column is derived from the `phases` array below.

---

## Registration call

```ts
engine.registerWorkflowType({
  type_name: "IN_MONTHLY",

  phases: [
    {
      phase_name: "INGESTION",
      is_side_phase: false,
      tools: [
        // Shared with OUT_MONTHLY; Block 12 Phase 04 owns the dedup contract.
        // The IN run does not re-invoke intake tools if the OUT run has
        // already completed INGESTION for the same paired_run_id.
        "intake.parse_statement",
        "intake.validate_statement_format",
        "intake.generate_evidence_pdf",
      ],
    },
    {
      phase_name: "CLASSIFICATION",
      is_side_phase: false,
      tools: [
        // Shared with OUT_MONTHLY; same dedup contract.
        "classification.run_layer_1",
        "classification.run_layer_2",
        "classification.run_layer_3",
        "classification.write_vendor_memory",
      ],
    },
    {
      phase_name: "IN_FILTER",
      is_side_phase: false,
      tools: [
        "in_workflow.run_in_filter",
      ],
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
        // Block 11 Phase 09 consolidation: INCOME_LEDGER_PREPARATION +
        // VAT_CLASSIFICATION are one runtime phase. Consumers query
        // LEDGER_PREPARATION only — there is no separate VAT_CLASSIFICATION_PHASE_*.
        "ledger.resolve_counterparty",
        "ledger.decide_vat_treatment",
        "ledger.prepare_income_entries",
        "ledger.prepare_invoice_lifecycle_entries",
      ],
    },
    {
      phase_name: "AI_END_SCAN",
      is_side_phase: false,
      tools: [
        "ai.run_end_scan",
      ],
    },
    {
      phase_name: "HUMAN_REVIEW_HOLD",
      is_side_phase: true,   // Entered conditionally; gate routes here when HIGH/BLOCKING issues exist
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
    event_driven: {
      event_type: "STATEMENT_INGESTION_COMPLETED",
      // Note: the subscription is to STATEMENT_UPLOAD_COMPLETED at the
      // outer handler level (Block 07 Phase 01 producer). The inner trigger
      // to create the IN_MONTHLY run fires after INGESTION is confirmed
      // complete for the paired OUT run's coordination signal.
      // See "Pair-trigger sequencing" below.
    },
    manual: {
      tool: "in_workflow.start_run_manually",
    },
  },

  parallel_with: ["OUT_MONTHLY"],
  // OUT_MONTHLY and IN_MONTHLY run in parallel after the shared
  // INGESTION + CLASSIFICATION phases complete for the period.

  per_business_config_table: "in_workflow_business_config",
  per_business_config_toggle: "auto_start_on_statement_upload",
});
```

## Phase sequence (canonical 8-position list)

| Position | Phase name | Side phase? | Notes |
| --- | --- | --- | --- |
| 1 | `INGESTION` | No | Shared with `OUT_MONTHLY`; dedup contract in Block 12 Phase 04 |
| 2 | `CLASSIFICATION` | No | Shared with `OUT_MONTHLY` |
| 3 | `IN_FILTER` | No | Selects `IN_INCOME`, `REFUND_IN`, `INTERNAL_TRANSFER` (IN-direction), `FX_EXCHANGE` (IN-direction), `LOAN_OR_SHAREHOLDER_MOVEMENT` (IN-direction), `CHARGEBACK` (IN-direction) transaction types |
| 4 | `INCOME_MATCHING` | No | Block 10 Phase 08; matches bank transactions against `invoices` |
| 5 | `LEDGER_PREPARATION` | No | Block 11 Phase 09 consolidation; covers income ledger entries + VAT classification |
| 6 | `AI_END_SCAN` | No | Block 06 Phase 11; produces review issues |
| 7 | `HUMAN_REVIEW_HOLD` | Yes | Entered when `AI_END_SCAN` gate routes `ROUTE_TO_SIDE_PHASE` |
| 8 | `FINALIZATION` | No | Block 15; terminal |

This 8-position list is stored in `workflow_runs.effective_phase_sequence_json` at run creation time. The engine's execution loop reads from this snapshot; changes to the registered sequence after run creation do not affect in-flight runs.

### Phase mapping note (architecture-doc reconciliation)

Block 13's architecture doc lists 9 phases (positions 5 + 6 = `INCOME_LEDGER_PREPARATION` + `VAT_CLASSIFICATION`). Block 11 Phase 09's consolidation collapses these into one runtime phase (`LEDGER_PREPARATION`). Block 14 and Block 16 consumers must query `LEDGER_PREPARATION` only — there is no `VAT_CLASSIFICATION_PHASE_*` event series. This matches the same consolidation in `OUT_MONTHLY` (Block 12 Phase 02).

### Evidence discovery is not a phase in IN_MONTHLY

`IN_MONTHLY` does NOT invoke Block 09's `EVIDENCE_DISCOVERY_EMAIL` or `EVIDENCE_DISCOVERY_DRIVE` phases. Income matching works against structured `Invoice` records from the Invoice Generator (Block 13 Phase 01), not externally discovered documents. This is a durable cross-block contract per Block 13 Phase 07.

---

## Pair-trigger sequencing

When a `STATEMENT_UPLOAD_COMPLETED` event arrives, the event handler creates both the `OUT_MONTHLY` and `IN_MONTHLY` run rows atomically in a single database transaction. The two runs are linked via `workflow_runs.paired_run_id` (the self-referential FK defined in `workflow_run_schema`). The DEFERRABLE INITIALLY DEFERRED constraint on `paired_run_id` allows both rows to be inserted in the same transaction.

The pair symmetry invariant (A.`paired_run_id` = B AND B.`paired_run_id` = A) is enforced by the engine at pair-creation time, not by SQL constraint. Block 03's `getCombinedRunProgress` consumer (Block 16) joins on `paired_run_id` to render the unified progress indicator.

If `auto_start_on_statement_upload = false` for the business, the event handler creates only the `OUT_MONTHLY` run; the IN side is suppressed and `IN_WORKFLOW_AUTO_START_SUPPRESSED` is emitted. The user must then trigger the IN run manually.

---

## Shared INGESTION + CLASSIFICATION phases

`INGESTION` and `CLASSIFICATION` are shared between `OUT_MONTHLY` and `IN_MONTHLY` runs for the same period. Block 12 Phase 04 owns the dedup contract: if the OUT run has already completed a phase for the period's documents, the IN run's execution of that phase is a no-op (dedup hit via `tool_invocations.dedup_key`) per Block 03 Phase 07's resumability framework.

The IN run's `workflow_run_id` differs from the OUT run's, but the tool invocations for shared phases reference the same `upload_id` and `transaction_id` values in their dedup keys — so the `WORKFLOW_TOOL_DEDUP_HIT` mechanism correctly short-circuits re-work.

---

## Per-business config

`in_workflow_business_config` table (Block 13 Phase 07):

| Column | Default | Effect |
| --- | --- | --- |
| `auto_start_on_statement_upload` | `true` | When `false`, event-driven trigger is suppressed; user must start manually |

The full `out_workflow_configs` table (`out_config_schema`) governs `OUT_MONTHLY`. The IN config is deliberately minimal — all phase-subset toggling for the IN side follows the same `enabled_phases` JSONB pattern as the OUT config if needed in Stage 2.

---

## Audit events

| Event | Trigger |
| --- | --- |
| `IN_WORKFLOW_RUN_CREATED` | New `IN_MONTHLY` run row inserted (event-driven or manual) |
| `IN_WORKFLOW_RUN_PAIR_LINKED` | The pair linkage between the IN and OUT runs is established in the atomic pair-creation transaction |

Additional `IN_WORKFLOW`-domain audit events (`IN_WORKFLOW_TYPE_REGISTERED`, `IN_WORKFLOW_CONFIG_INITIALIZED`, `IN_WORKFLOW_CONFIG_UPDATED`, `IN_WORKFLOW_RUN_STARTED_MANUALLY`, `IN_WORKFLOW_RUN_STARTED_BY_EVENT`, `IN_WORKFLOW_AUTO_START_SUPPRESSED`, `IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`, `IN_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED`) exist in `audit_event_taxonomy`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for run IDs; canonical JSON for `effective_phase_sequence_json` and `principal_context_snapshot_json`
- `audit_log_policies` — `IN_WORKFLOW` domain; past-tense naming
- `audit_event_taxonomy` — `IN_WORKFLOW_RUN_CREATED`, `IN_WORKFLOW_RUN_PAIR_LINKED` and full IN_WORKFLOW domain
- `workflow_run_schema` — `workflow_run_id`; `paired_run_id`; `effective_phase_sequence_json`
- `out_config_schema` — symmetric OUT-side per-business config; `auto_trigger_on_statement_upload`
- Block 13 Phase 07 — `IN_MONTHLY` type registration source; per-business IN config table; trigger contracts
- Block 12 Phase 04 — pair-trigger ownership; OUT/IN parallel coordination; dedup contract for shared phases
- Block 03 Phase 07 — resumability; dedup-hit mechanism for shared phases
- Block 03 Phase 02 — `engine.registerWorkflowType` framework
- `decisions_log.md` — Stage 1 "OUT/IN trigger order: parallel after shared INGESTION + CLASSIFICATION"
