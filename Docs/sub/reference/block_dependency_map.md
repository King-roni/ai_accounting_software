# Block Dependency Map

**Category:** Reference · **Owning block:** cross-block · **Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Documents the inter-block dependency graph: which blocks depend on which, what type of contract governs each dependency, and where the contract is defined. This map is the authoritative source for ordering decisions (build order, test order, migration sequencing) and for detecting circular dependency violations.

---

## Dependency table

| Block | Depends on | Contract type | Contract file |
|---|---|---|---|
| 02 — Tenancy & Access | 01 — Core Principles | Architectural contract — all platform behaviour respects the invariants in Block 01 | `Docs/blocks/01_core_principles.md` |
| 03 — Workflow Engine | 02 — Tenancy & Access | Runtime contract — `auth.can_perform` is called at run creation to verify the actor has the `RUN_CREATE` operation on surface `WORKFLOW` | `tool_can_perform_helper.md` |
| 04 — Data Architecture | 02 — Tenancy & Access | Schema contract — every business-data table carries `business_id` FK → `business_entities.id`; tenant isolation is enforced by RLS policies that reference `auth.role_on_business()` | `tenancy_schema_definition.md` |
| 05 — Security & Audit | 02 — Tenancy & Access | Identity contract — `emitAudit()` resolves `actor_user_id` and `business_id` from the authenticated session; RLS on `audit_log` uses Block 02 role resolution | `audit_log_policies.md` |
| 05 — Security & Audit | 03 — Workflow Engine | Emission contract — `emitAudit()` is called inside workflow-run transactions; the audit chain appends to the business chain scoped by `workflow_run_id` | `audit_log_policies.md` |
| 05 — Security & Audit | 04 — Data Architecture | Storage contract — archive bundle hash verification and canonical JSON serialization use Block 04 hashing utilities (`data.hash_sha256`, `data.canonical_json`) | `hash_chain_schema.md` |
| 06 — AI Layer | 03 — Workflow Engine | Run context contract — every AI gateway invocation is scoped to a `workflow_run_id`; the gateway reads the run's `business_id` for cost ceiling and redaction policy lookup | `ai_gateway_schema.md` |
| 06 — AI Layer | 05 — Security & Audit | Audit emission contract — every `ai.invoke` call emits `AI_GATEWAY_INVOKED` and outcome events via `emitAudit()` | `audit_event_taxonomy.md` |
| 07 — Bank Statement Pipeline | 03 — Workflow Engine | Run context contract — bank statement parsing runs as phases inside an `OUT_MONTHLY` workflow run; `engine.gate_ingestion_complete` evaluates parse completion | `gate_function_library_schema.md` |
| 07 — Bank Statement Pipeline | 04 — Data Architecture | Schema contract — parsed transactions write to `transactions` (Operational zone); `source_row_hash` and `fingerprint` use Block 04 hashing utilities | `bank_statement_schema.md` |
| 07 — Bank Statement Pipeline | 05 — Security & Audit | Audit emission contract — upload, parse, and ingestion events emitted via `emitAudit()` | `audit_event_taxonomy.md` |
| 08 — Transaction Classification | 06 — AI Layer | AI gateway contract — Layer 3 classifier calls `ai.invoke` with tier `EXTERNAL`; cost ceiling and redaction policies are enforced by the gateway | `ai_tier_escalation_policy.md` |
| 08 — Transaction Classification | 07 — Bank Statement Pipeline | Data contract — classifier operates on `transactions` rows written by Block 07; reads `source_row_canonical_json` for AI input construction | `bank_statement_schema.md` |
| 09 — Document Intake | 06 — AI Layer | AI gateway contract — OCR escalation path calls `ai.invoke` with tier `EXTERNAL` | `ai_tier_escalation_policy.md` |
| 09 — Document Intake | 07 — Bank Statement Pipeline | Run context contract — document intake runs inside the INGESTION phase alongside bank statement parsing; shares `bank_upload_id` context | `document_schema.md` |
| 10 — Matching Engine | 07 — Bank Statement Pipeline | Data contract — matcher reads `transactions` rows by `workflow_run_id` | `match_record_schema.md` |
| 10 — Matching Engine | 08 — Transaction Classification | Data contract — matcher reads `transactions.transaction_type` and `transactions.vat_treatment` from classification output to filter candidates | `match_record_schema.md` |
| 10 — Matching Engine | 09 — Document Intake | Data contract — matcher reads `documents` rows (invoices, receipts) to form match candidates | `match_record_schema.md` |
| 11 — Ledger & Cyprus VAT | 08 — Transaction Classification | Data contract — ledger entry preparation reads `transactions.transaction_type` and classification confidence from Block 08 output | `ledger_entry_schema.md` |
| 11 — Ledger & Cyprus VAT | 10 — Matching Engine | Data contract — VAT treatment decision for reverse-charge transactions reads `match_records.invoice_id` to resolve the counterparty VAT number | `ledger_entry_schema.md` |
| 12 — OUT Workflow | 07 — Bank Statement Pipeline | Run contract — `OUT_MONTHLY` run is triggered by `STATEMENT_INGESTION_COMPLETED` | `out_monthly_type_definition.md` |
| 12 — OUT Workflow | 08 — Transaction Classification | Data contract — OUT filter reads `transactions.transaction_type` for inclusion logic | `out_filter_policy.md` |
| 12 — OUT Workflow | 09 — Document Intake | Data contract — OUT run reads `documents` for document-exception handling | `out_exception_documented_policy.md` |
| 12 — OUT Workflow | 10 — Matching Engine | Gate contract — `engine.gate_matching_complete` evaluates `match_records` completeness before advancing to finalization | `gate_function_library_schema.md` |
| 12 — OUT Workflow | 11 — Ledger & Cyprus VAT | Gate contract — `engine.gate_ledger_complete` evaluates `ledger_entries` readiness | `gate_function_library_schema.md` |
| 12 — OUT Workflow | 14 — Review Queue | Issue registration contract — Block 12 registers issues via `review_queue.register_issue`; review completion gates OUT finalization | `review_queue_card_layout_ui_spec.md` |
| 13 — IN Workflow | 11 — Ledger & Cyprus VAT | Data contract — IN ledger entries for invoice payments reference `ledger_entries` from Block 11 | `ledger_entry_schema.md` |
| 13 — IN Workflow | 14 — Review Queue | Issue registration contract — Block 13 registers income matching issues via `review_queue.register_issue` | `review_queue_card_layout_ui_spec.md` |
| 14 — Review Queue | 03 — Workflow Engine | Gate evaluation contract — `engine.gate_review_complete` evaluates open review issues before a run advances past `REVIEW_HOLD` | `gate_function_library_schema.md` |
| 14 — Review Queue | 05 — Security & Audit | Audit emission contract — every issue state transition emits via `emitAudit()` | `audit_event_taxonomy.md` |
| 15 — Finalization & Archive | 11 — Ledger & Cyprus VAT | Data contract — finalization seals `ledger_entries` and `vat_entries` into the archive bundle | `archive_bundle_construction_schema.md` |
| 15 — Finalization & Archive | 12 — OUT Workflow | Run contract — finalization is the terminal phase of a completed `OUT_MONTHLY` or `OUT_ADJUSTMENT` run | `out_monthly_type_definition.md` |
| 15 — Finalization & Archive | 13 — IN Workflow | Run contract — finalization is the terminal phase of a completed `IN_MONTHLY` or `IN_ADJUSTMENT` run | `in_monthly_type_definition.md` |
| 15 — Finalization & Archive | 14 — Review Queue | Gate contract — no open BLOCKING review issues may exist at finalization; `engine.gate_finalization_ready` checks this | `gate_function_library_schema.md` |
| 15 — Finalization & Archive | 05 — Security & Audit | Hash chain contract — archive bundle construction reads `audit_log.chain_hash` for the business chain head; bundle includes the chain anchor | `archive_verification_policy.md` |
| 16 — Dashboard & Reporting | 15 — Finalization & Archive | Data contract — period reports and analytics snapshots read from `archive_packages` and `analytics_snapshots` (Operational zone, post-finalization) | `analytics_snapshot_schema.md` |
| 16 — Dashboard & Reporting | 11 — Ledger & Cyprus VAT | Live data contract — dashboard cards for in-progress periods read from `ledger_entries` and `vat_entries` directly | `dashboard_widget_config_schema.md` |
| 16 — Dashboard & Reporting | 12 — OUT Workflow | Run status contract — dashboard shows OUT run progress by querying `workflow_runs` | `dashboard_widget_config_schema.md` |
| 16 — Dashboard & Reporting | 13 — IN Workflow | Run status contract — dashboard shows IN run progress and invoice pipeline status | `dashboard_widget_config_schema.md` |

---

## Canonical cross-block tool contracts

Five tool contracts define the primary inter-block coupling surfaces. All blocks that cross a boundary do so through one of these contracts:

| Contract | Tool | Producer block | Consumer blocks | Notes |
|---|---|---|---|---|
| Permission check | `auth.can_perform` | 02 | 03, 12, 13, 14, 15, 16 | Every run-creation and finalization-approval action calls this before writing state |
| Gate evaluation | `engine.gate_<phase_descriptor>` | 03 | 07, 08, 09, 10, 11, 12, 13, 14, 15 | Gate functions return `PASS` / `HOLD` / `FAIL`; the engine advances or holds the run accordingly |
| Audit emission | `security.emit_audit` | 05 | All 15 blocks | Every tool that writes state calls `emitAudit()` within the same transaction |
| Operational promotion | `archive.promote_to_operational` | 15 | 04 (retention engine), 16 (analytics rebuild) | Emits `ARCHIVE_PROMOTION_COMPLETED`; triggers downstream analytics rebuild and retention clock start |
| Period report | `report.generate_period_report` | 16 | External consumers (export, accountant pack) | Reads from finalized archive data; never reads Processing zone data |

---

## Circular dependency prohibition

No block may depend on a block with a higher block number. Dependencies flow strictly from lower to higher block numbers with one documented exception:

**Exception — Block 14 (Review Queue):** Blocks 07 through 13 call `review_queue.register_issue` to create review issues. This is an issue registration call, not a runtime state dependency. Block 14 does not call back into Blocks 07–13 at runtime; it only stores issue metadata and emits audit events. The gate evaluation path (`engine.gate_review_complete`) is owned by Block 03, not Block 14, so the circular reference does not extend to the engine layer.

This exception was ratified in `Docs/decisions_log.md` at Stage 4. It is the only permitted backward dependency. Any new backward dependency proposed for blocks other than 14 requires a `decisions_log.md` amendment and explicit review.

---

## Dependency rule enforcement

This map is enforced at two levels:

1. **Code review.** A PR that introduces a cross-block tool call, FK, or event subscription without a corresponding row in this map is rejected.
2. **Architecture lint (Stage 2+).** A planned CI step will parse tool registration calls and FK definitions to verify all cross-block references appear in this map. The lint is a future addition; until it ships, code review is the sole enforcement mechanism.

Block short names in tool calls must match the namespace allowlist in `tool_naming_convention_policy.md`. A tool in the `matching` namespace cannot carry a dependency on Block 12 tables — if a matching tool needs an invoice, it reads via the `documents` table (Block 09's contract), not via Block 13's tables directly.

---

## Gate function naming

All gate functions follow the pattern `engine.gate_<phase_descriptor>` (two-part name: namespace `engine`, action prefixed `gate_`). Gate functions are READ_ONLY tools that evaluate run state and return one of `PASS`, `HOLD`, or `FAIL`. They do not write run state; the engine writes the resulting state transition.

| Gate function | Evaluates | Used by blocks |
|---|---|---|
| `engine.gate_ingestion_complete` | All bank statement rows parsed; evidence PDF generated | 07, 12 |
| `engine.gate_classification_complete` | All transactions have a confirmed classification | 08, 12 |
| `engine.gate_matching_complete` | All OUT transactions have a confirmed match, rejected match, or documented exception | 10, 12 |
| `engine.gate_ledger_complete` | All transactions have finalized ledger entries with no `UNKNOWN` VAT treatment | 11, 12 |
| `engine.gate_review_complete` | No open HIGH or BLOCKING severity review issues exist | 14, 12, 13 |
| `engine.gate_finalization_ready` | All prior gates passed; no BLOCKING issues; finalization approval received | 15, 12, 13 |

Gate functions are registered at boot via `engine.registerTool`. Adding a new gate requires an entry in `gate_function_library_schema.md` and an amendment to this map.

---

## Event subscription contracts

Three events create cross-block coupling via the event subscription pipeline rather than direct tool calls:

| Subscribed event | Producer | Subscriber | Effect |
|---|---|---|---|
| `STATEMENT_INGESTION_COMPLETED` | Block 07 | Block 12 trigger engine | Creates `OUT_MONTHLY` run for the uploaded period |
| `STATEMENT_INGESTION_COMPLETED` | Block 07 | Block 13 trigger engine | Creates `IN_MONTHLY` run paired to the OUT run |
| `ARCHIVE_PROMOTION_COMPLETED` | Block 15 | Block 04 retention engine | Starts the 7-year retention clock |
| `ARCHIVE_PROMOTION_COMPLETED` | Block 15 | Block 16 analytics builder | Triggers analytics snapshot rebuild |
| `WORKFLOW_RUN_STATE_CHANGED` | Block 03 | Block 14 | Triggers issue carry-forward evaluation on run state change |

These subscriptions are registered at boot via `engine.registerEventSubscription`. The subscription contract is owned by the producer block; the consumer must not depend on the event payload schema changing without a producer-side amendment.

---

## Reading this map

- "Contract type" describes the nature of the coupling: architectural (foundational invariants), runtime (live function calls during workflow execution), schema (FK and column-level dependencies), data (read access on another block's rows), gate (gate function evaluation), or run (workflow type lifecycle ownership).
- "Contract file" is the sub-doc that defines the interface — the file the consuming block must consult before calling the producing block's tools or reading its tables.
- This map is updated whenever a new inter-block tool call, FK reference, or event subscription is introduced. A PR that adds a new cross-block call without updating this map is incomplete.

---

## Cross-references

- `tool_naming_convention_policy.md` — tool name format; namespace-to-block mapping
- `gate_function_library_schema.md` — all `engine.gate_*` function signatures and pass/hold/fail semantics
- `tool_can_perform_helper.md` — `auth.can_perform` contract, surface and operation enums
- `audit_event_taxonomy.md` — cross-block events table (producer/consumer mapping)
- `event_subscription_pipeline_integration.md` — subscription registration and dispatch
- `Docs/decisions_log.md` — Block 14 backward dependency exception rationale
