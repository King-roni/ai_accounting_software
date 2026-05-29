# Block 12 — Phase 02: `OUT_MONTHLY` Workflow Type Definition

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (Phase Sequence; Type-Aware Evidence Rules; Gate Conditions)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 02 — workflow type registry; Phase 03 — tool registration; Phase 04 — state machine; Phase 05 — gate evaluation; Phase 06 — phase execution)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 1 — Workflow-First; Principle 5 — Simple Interface)

## Phase Goal

Register the canonical `OUT_MONTHLY` static workflow type into Block 03's workflow type registry. Define the ordered 12-phase sequence with per-phase tool references (by name — durable cross-block contracts pinned in Blocks 07–11), per-phase gate-function references (resolved by Phase 05's library), the type-aware evidence rules table, and the per-business config interaction. After this phase, calling `engine.startWorkflowRun({ type: 'OUT_MONTHLY', business_id, period })` produces a fully-typed run that the engine can advance.

## Dependencies

- Phase 01 (`out_workflow_business_config`; the registration entry points)
- Phase 03 (`OUT_FILTER` phase + tool — referenced in the sequence below)
- Phase 05 (gate-function library — referenced by the gate references below)
- Phase 06 (`MANUAL_UPLOAD_HOLD` phase — referenced in the sequence below)
- Phase 07 (`HUMAN_REVIEW_HOLD` phase — referenced in the sequence below)
- Block 03 Phase 02 (`engine.registerWorkflowType`)
- Block 07 Phase 07 (`INGESTION` phase contract)
- Block 08 Phase 09 (`CLASSIFICATION` phase contract)
- Block 09 Phase 09 (`EVIDENCE_DISCOVERY_EMAIL` and `EVIDENCE_DISCOVERY_DRIVE` phase contracts)
- Block 10 Phase 09 (`MATCHING` phase contract)
- Block 11 Phase 09 (`LEDGER_PREPARATION` phase contract; the architecture doc lists this and `VAT_CLASSIFICATION` as separate phases — see "Phase mapping" below)
- Block 06 Phase 11 (`AI_END_SCAN` phase contract)
- Block 15 (`FINALIZATION` phase contract — Block 15 phase docs not yet written; the contract is the durable phase-name `FINALIZATION`)

## Deliverables

- **`OUT_MONTHLY` workflow type definition** — registered via `engine.registerWorkflowType(...)` with these properties:
  - **`type` = `'OUT_MONTHLY'`**
  - **Phase sequence** (11 registered positions, consolidated from the architecture doc's 12-phase conceptual list — see "Phase mapping note" below; integer phase indices `1..11` are local to this type — durable cross-block references are by phase name):
    1. `INGESTION` (Block 07)
    2. `CLASSIFICATION` (Block 08)
    3. `OUT_FILTER` (Block 12 Phase 03)
    4. `EVIDENCE_DISCOVERY_EMAIL` (Block 09)
    5. `EVIDENCE_DISCOVERY_DRIVE` (Block 09)
    6. `MATCHING` (Block 10)
    7. `MANUAL_UPLOAD_HOLD` (Block 12 Phase 06; **side phase** — entered conditionally per the gate)
    8. `LEDGER_PREPARATION` (Block 11; **encompasses both ledger preparation and VAT classification** — see "Phase mapping" below)
    9. `AI_END_SCAN` (Block 06)
    10. `HUMAN_REVIEW_HOLD` (Block 12 Phase 07; side phase — entered conditionally per the gate)
    11. `FINALIZATION` (Block 15)
  - **Phase mapping note (consumer-facing contract):** the architecture doc lists `LEDGER_PREPARATION` and `VAT_CLASSIFICATION` as separate phases (positions 8 and 9). Block 11's Phase 09 decomposition consolidated them into a single `LEDGER_PREPARATION` phase whose tool sequence covers both ledger entry creation and VAT classification (Block 11 Phase 09 sequences `resolve_counterparty → classify_vat → compute_reverse_charge_vies → prepare_entries → compute_vat_and_evidence_flags → flag_for_review → generate_vat_explanations` within the single phase). Block 12 honors that consolidation — the registered sequence uses one `LEDGER_PREPARATION` phase, not two. The numbering above (`1..11`) reflects the consolidation; the architecture doc's "12 phases" reads as the conceptual list.
  - **Downstream consumer guidance:** Block 14 (review queue), Block 16 (dashboard), and any caller that filters audit events by phase name MUST query `LEDGER_PREPARATION` only — there is no `VAT_CLASSIFICATION_PHASE_*` event series. The conceptual "VAT classification" work surfaces inside `LEDGER_PHASE_*` events (per Block 11 Phase 09's per-tool emission list). The architecture doc's two-phase mental model is preserved for documentation clarity; the runtime contract is one phase.
  - **Per-phase gate references** — every phase carries a `gateFunctionRef` resolved against Phase 05's library (the gates declared in Phase 05). Per Block 03 Phase 05, gates return `ADVANCE` / `HOLD` / `ROUTE_TO_SIDE_PHASE`.
  - **Per-phase tool sequences** — the tools each phase invokes, by name, are owned by the phase's source block (e.g., `MATCHING` runs the tools registered by Block 10 Phase 09). Block 12 doesn't redeclare them; the registration carries the phase name + the gate ref.
- **Type-aware evidence rules table** (encoded as a registry table; Phase 03's `OUT_FILTER` and Phase 05's gates consume it):

  | Transaction type | OUT_FILTER includes? | Evidence required |
  | --- | --- | --- |
  | `OUT_EXPENSE` | Yes | Invoice or receipt; OR documented exception with reason |
  | `INTERNAL_TRANSFER` | Yes (also IN_FILTER — see Phase 04 dedup) | None |
  | `FX_EXCHANGE` | Yes | Bank-generated FX evidence (auto-derived) |
  | `BANK_FEE` | Yes | Bank-generated evidence (auto-generated) |
  | `REFUND_OUT` | Yes | Reference to original transaction being refunded |
  | `PAYROLL_OR_TEAM_PAYMENT` | Yes | Invoice OR contract OR payroll record |
  | `TAX_PAYMENT` | Yes | Tax authority confirmation OR documented as expected payment |
  | `LOAN_OR_SHAREHOLDER_MOVEMENT` (OUT direction — outgoing loan / capital return) | Yes | Contract or shareholder agreement |
  | `LOAN_OR_SHAREHOLDER_MOVEMENT` (IN direction — capital injection / loan receipt) | No (handled by IN_FILTER, Block 13) | — |
  | `CHARGEBACK` | Yes | Bank-generated evidence + dispute record |
  | `IN_INCOME` | No (handled by IN_FILTER, Block 13) | — |
  | `REFUND_IN` | No (handled by IN_FILTER, Block 13) | — |
  | `UNKNOWN` | Yes (raised as blocking issue — must be reclassified before advance) | Cannot advance |

- **Per-business config interaction:**
  - Phase 01's `evidence_discovery_email_enabled = false` causes the engine to short-circuit `EVIDENCE_DISCOVERY_EMAIL`'s gate to `ADVANCE` immediately (the phase enters and exits in one step with a `OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG` audit event). Same for `evidence_discovery_drive_enabled = false`.
  - `MANUAL_UPLOAD_HOLD`'s reminder cadence is read from `manual_upload_hold_reminder_days`.
  - `auto_start_on_statement_upload` is consumed by Phase 08's trigger, not this phase.
- **Side-phase semantics:**
  - `MANUAL_UPLOAD_HOLD` and `HUMAN_REVIEW_HOLD` are side phases: the engine routes to them only when the prior phase's gate returns `ROUTE_TO_SIDE_PHASE`. When the routing condition is not met, they are skipped entirely and the next sequenced phase advances. Per Block 03 Phase 04, the run-level state during a side-phase enter is `REVIEW_HOLD` (or `AWAITING_APPROVAL` for HUMAN_REVIEW_HOLD), and `phase_state.status = HOLDING` per the two-level state semantics.
- **Audit-event domain split for Block 12** (declared once, applies to every Block 12 phase):
  - **Domain `OUT_WORKFLOW`** — covers `OUT_MONTHLY` events (run lifecycle, gate decisions, MANUAL_UPLOAD_HOLD, HUMAN_REVIEW_HOLD, triggers, filter decisions). Every Phase 01–08 event uses this domain.
  - **Domain `OUT_ADJUSTMENT`** — covers `OUT_ADJUSTMENT` events only (Phase 09's run lifecycle, intake, retention/parent rejections, archive interleave). The split is intentional — Block 14's review-queue queries and Block 16's dashboard queries can filter by domain to surface the right run type.
  - The split is documented in the audit-taxonomy sub-doc owned by Block 05 Phase 02; this phase pins the boundary.
- **Audit events emitted by this phase** (declared in Phase 01; emitted at boot and on type-instance progression):
  - `OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG` (when a per-business toggle short-circuits a phase)
  - `OUT_WORKFLOW_TYPE_REGISTERED` is owned by Phase 01 (the registration-entry-point phase); this phase consumes it but does not redeclare it.
  - The per-phase `_PHASE_STARTED` / `_PHASE_COMPLETED` / `_PHASE_HOLDING` events are owned by the source blocks (Blocks 07–11, 06, 15) and emitted by their phase implementations. Block 12 does not duplicate them.

## Definition of Done

- `OUT_MONTHLY` is registered at engine boot; the registration includes the 11-position phase sequence above (consolidated `LEDGER_PREPARATION`).
- A test `engine.startWorkflowRun({ type: 'OUT_MONTHLY', business_id, period })` creates a `Workflow Run` (Block 03) with `state = CREATED`; the engine advances through the sequence using each phase's registered tools and gates.
- A business with `evidence_discovery_email_enabled = false` skips `EVIDENCE_DISCOVERY_EMAIL` cleanly; the audit event fires.
- The architecture doc's "12-phase" mental model is honored — `LEDGER_PREPARATION` consumers (Block 14, Block 16) read the same phase name regardless of the consolidation.
- The type-aware evidence rules table is loaded into a runtime-queryable structure consumed by Phase 03's `OUT_FILTER` and Phase 05's gates.
- Per-business config toggles are honored on every run; changing the toggle takes effect on the next `startWorkflowRun`, not retroactively.

## Sub-doc Hooks (Stage 4)

- **`OUT_MONTHLY` type-definition sub-doc** — exact JSON / TypeScript shape of the registration call.
- **Phase-name canonical map sub-doc** — durable phase-name registry across all blocks; aliases / versioning.
- **Type-aware evidence rules table sub-doc** — runtime representation, future-tag compatibility.
- **Per-business toggle sub-doc** — exact short-circuit semantics, audit-event payload.
- **Phase-renumbering migration sub-doc** — what to do if the architecture-doc consolidation is later split back into two phases.
