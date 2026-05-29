# workflow_type_phase_optionality

**Category:** Reference · **Owning block:** 03 — Workflow Engine · **Co-owners:** 12 — OUT Workflow, 13 — IN Workflow · **Stage:** 4 sub-doc (Layer 2)

The per-workflow-type matrix of **which phases are optional vs mandatory**, with per-phase rationale. Companion to `workflow_type_registry_schema.md` (which defines the phase sequence) and `matching_phase_definitions.md` (which defines the by-name cross-block phase contract).

**Optionality model:** the workflow engine does NOT carry an explicit `is_optional` boolean on each phase. Instead, optionality is encoded as **entry-gate conditions** on the phase. A phase whose entry-gate evaluates to "no work needed" emits a `WORKFLOW_PHASE_SKIPPED` audit event and the run advances to the next phase without invoking the phase's tools. Phases with no entry-gate or whose entry-gate always evaluates to "advance" are mandatory.

---

## 1. The optionality model

### 1.1 Entry-gate-based skip mechanism

When the workflow engine reaches a phase boundary, it evaluates the phase's entry gate per `workflow_type_registry_schema.md` §Gate Sequence:

```
1. Engine reaches phase P with phase_states.status='PENDING'
2. Evaluate P's entry gate (per workflow_type_registry.gate_sequence)
3a. Gate returns ADVANCE → set status='RUNNING', invoke phase tools
3b. Gate returns SKIP → set status='SKIPPED', emit WORKFLOW_PHASE_SKIPPED, advance to next phase
3c. Gate returns HOLD → set status='HOLDING', transition run to REVIEW_HOLD
```

The SKIP return is the optionality mechanism. A gate may return SKIP based on data conditions (e.g., "no documents to match" → skip MATCHING), business-config conditions (e.g., "AI classification disabled for this business" → skip CLASSIFICATION), or workflow-type conditions (e.g., "OUT_ADJUSTMENT skips INGESTION because no new statement is needed").

### 1.2 What "mandatory" means

A phase is **mandatory** when:
- It has no entry gate (always invoked), OR
- Its entry gate cannot return SKIP — only ADVANCE or HOLD.

Mandatory phases ALWAYS produce at least one tool invocation per run. Skipping them would corrupt the run's accounting integrity (e.g., skipping LEDGER_PREP means no ledger entries; skipping FINALIZATION means the period isn't sealed).

### 1.3 Audit event

```
WORKFLOW_PHASE_SKIPPED (LOW severity)
Payload:
  workflow_run_id
  phase_name
  skip_reason       (one of: NO_INPUT_DATA, BUSINESS_CONFIG_DISABLED, WORKFLOW_TYPE_NOT_APPLICABLE, OPTIONAL_PER_TYPE)
  gate_function_called
  evaluated_at
```

**Cross-block coordination flagged for B05·P02 taxonomy:** verify <code>WORKFLOW_PHASE_SKIPPED</code> exists and supports the 4 skip_reason enum values.

---

## 2. OUT_MONTHLY phase optionality

Per `workflow_type_registry_schema.md` example, OUT_MONTHLY has 6 phases:

| # | Phase | Optionality | Skip reason | Rationale |
|---|---|---|---|---|
| 1 | INGESTION | **Mandatory** | — | A monthly run requires a statement; no statement = no run created (enforced at run creation per `workflow_run_creation_policy.md`). |
| 2 | CLASSIFICATION | **Mandatory** | — | Every transaction must have a classification before matching can find candidates. AI-disabled businesses still classify (deterministic rules engine fallback). |
| 3 | EVIDENCE_DISCOVERY | **Optional** | `BUSINESS_CONFIG_DISABLED` (no Gmail/Drive connected) OR `NO_INPUT_DATA` (no transactions classified as needing evidence) | Businesses without Gmail/Drive integration skip this phase; the matching engine then runs against locally-uploaded documents only. |
| 4 | MATCHING | **Optional** | `NO_INPUT_DATA` (zero unmatched transactions OR zero candidate documents) | If there are no transactions or no candidates, scoring is meaningless. Both being non-zero is required to invoke `matching.score_pair`. |
| 5 | LEDGER_PREP | **Mandatory** | — | Every confirmed match produces ledger entries. Even runs with zero confirmed matches must emit phase events to record the empty-period status. |
| 6 | REVIEW | **Optional** | `NO_INPUT_DATA` (zero review issues raised) | If matching + duplicate detection produced no review issues, REVIEW phase has nothing to do. Auto-advances to FINALIZATION. |
| 7 | FINALIZATION | **Mandatory** | — | The lock sequence MUST run to seal the period and create the archive bundle. Empty-period runs still finalize. |

### Notable OUT_MONTHLY behaviours

- **Phase 3 + Phase 4 both optional** but `EVIDENCE_DISCOVERY` skipping does NOT cause `MATCHING` to skip — `MATCHING` may still find candidates from previously-uploaded documents.
- **`MATCHING` skipping after `EVIDENCE_DISCOVERY` ran** is a "no candidates found" signal worth surfacing in audit; the gate function emits `MATCHING_NO_CANDIDATES_FOUND` (LOW) in addition to `WORKFLOW_PHASE_SKIPPED`.

---

## 3. IN_MONTHLY phase optionality

IN_MONTHLY phases (referencing `in_monthly_phase_sequence.md` canonical sequence):

| # | Phase | Optionality | Skip reason | Rationale |
|---|---|---|---|---|
| 1 | INGESTION | **Mandatory** | — | Same as OUT_MONTHLY — statement upload is the run trigger. |
| 2 | CLASSIFICATION | **Mandatory** | — | Same rationale. |
| 3 | INCOME_MATCHING | **Optional** | `NO_INPUT_DATA` (zero IN_INCOME transactions OR zero active invoices) | If the business has no active invoices (rare — Cyprus SMEs typically have outstanding invoices), the engine skips invoice-matching and routes all IN_INCOME transactions to `NO_MATCH` for manual reclassification. |
| 4 | LEDGER_PREP | **Mandatory** | — | Same rationale as OUT_MONTHLY. |
| 5 | REVIEW | **Optional** | `NO_INPUT_DATA` | Same rationale. |
| 6 | FINALIZATION | **Mandatory** | — | Same rationale. |

### Notable IN_MONTHLY behaviours

- IN_MONTHLY does NOT have an `EVIDENCE_DISCOVERY` phase — invoices are internal records (Block 13's Invoice Generator), not externally-discovered documents.

---

## 4. OUT_ADJUSTMENT phase optionality

Adjustment runs follow a different sequence per `workflow_run_schema.md` §parent_run_id — they re-process a FINALIZED period:

| # | Phase | Optionality | Skip reason | Rationale |
|---|---|---|---|---|
| 1 | INGESTION | **Always SKIPPED** | `WORKFLOW_TYPE_NOT_APPLICABLE` | Adjustment runs don't ingest new statements; they re-process the parent run's data. The phase is in the sequence for symmetry but always skips. |
| 2 | CLASSIFICATION | **Optional** | `NO_INPUT_DATA` (no transactions need re-classification) | Adjustments may re-classify if the user changed a VAT treatment or reclassified a transaction's type; otherwise skipped. |
| 3 | EVIDENCE_DISCOVERY | **Always SKIPPED** | `WORKFLOW_TYPE_NOT_APPLICABLE` | Same rationale as INGESTION — no new evidence discovery during adjustments. |
| 4 | MATCHING | **Optional** | `NO_INPUT_DATA` (no transactions need re-matching) | Adjustments may re-match if the user manually overrode a match; otherwise skipped. |
| 5 | LEDGER_PREP | **Mandatory** | — | Adjustments MUST produce delta ledger entries per Block 13 Phase 11's adjustment manifest. Even zero-change adjustments emit a "no-delta" marker. |
| 6 | REVIEW | **Optional** | `NO_INPUT_DATA` | Same as OUT_MONTHLY. |
| 7 | FINALIZATION | **Mandatory** | — | Adjustments must re-seal the period with a new manifest version (v≥2) per `archive_finalization_policy.md`. |

### Notable OUT_ADJUSTMENT behaviours

- **3 of 7 phases always skipped** — INGESTION, EVIDENCE_DISCOVERY (the deterministic skips). Adjustments are deliberately narrow.
- **The `always SKIPPED` phases are present in the registered sequence** rather than omitted, so that the phase-state state machine sees a consistent shape across run types — the gate evaluation handles the skip uniformly.

---

## 5. IN_ADJUSTMENT phase optionality

Mirror of OUT_ADJUSTMENT but for IN_MONTHLY:

| # | Phase | Optionality |
|---|---|---|
| 1 | INGESTION | Always SKIPPED |
| 2 | CLASSIFICATION | Optional |
| 3 | INCOME_MATCHING | Optional (re-matching) |
| 4 | LEDGER_PREP | Mandatory |
| 5 | REVIEW | Optional |
| 6 | FINALIZATION | Mandatory |

Same rationales as OUT_ADJUSTMENT.

---

## 6. INGESTION standalone workflow type

The `INGESTION` workflow type (NOT the INGESTION phase of OUT_MONTHLY / IN_MONTHLY — the standalone type for bulk historical data import) has its own optionality profile:

| # | Phase | Optionality | Rationale |
|---|---|---|---|
| 1 | RAW_INTAKE | Mandatory | Read statement files. |
| 2 | NORMALISATION | Mandatory | Convert to canonical transactions table shape. |
| 3 | DUPLICATE_DETECTION | Optional (NO_INPUT_DATA) | If only one statement uploaded, no inter-statement duplicates possible. |
| 4 | COMPLETION_REPORT | Mandatory | Emit run-completion summary. |

INGESTION runs do NOT have CLASSIFICATION / MATCHING / FINALIZATION phases — those belong to OUT_MONTHLY / IN_MONTHLY runs that consume the ingested data.

---

## 7. Phase-skip implications for downstream

When a phase is skipped, downstream consumers need to know:

| Consumer | Behaviour when phase skipped |
|---|---|
| Block 16 dashboard (run timeline) | Renders skipped phases with a "skipped" badge + tooltip showing skip_reason. Does NOT hide them — the user should see the full intended sequence. |
| Block 05 audit-chain integrity | Skipped phases still emit `WORKFLOW_PHASE_SKIPPED` audit; the chain remains complete. No missing-link forensic concern. |
| Block 14 review queue | Skipped phases don't produce review issues. The queue view filters skipped phases out of "phase had issues" counts. |
| `workflow_run_audit_trail_reconstruction.md` §2.2 (BOOK-249) | Phase-state transitions query returns rows for SKIPPED phases with exit_event=`WORKFLOW_PHASE_SKIPPED`. |

---

## 8. Cross-references

- `workflow_type_registry_schema.md` — phase_sequence + gate_sequence DDL; the registered phases this doc annotates with optionality
- `matching_phase_definitions.md` (BOOK-229) — MATCHING + INCOME_MATCHING canonical phase definitions
- `workflow_phase_states_schema.md` — phase-state status enum (PENDING, RUNNING, COMPLETED, FAILED, **SKIPPED**, HOLDING)
- `workflow_state_enum.md` (BOOK-245) — run-level state machine; phase skips don't affect run status
- `workflow_run_audit_trail_reconstruction.md` (BOOK-249) — §2.2 surfaces skipped phases
- `workflow_run_creation_policy.md` — enforces "no statement = no run" precondition
- `out_monthly_phase_sequence.md` — full OUT_MONTHLY phase + gate sequence
- `in_monthly_phase_sequence.md` — full IN_MONTHLY phase + gate sequence
- `out_adjustment_type_definition.md` — OUT_ADJUSTMENT-specific phase sequence
- `archive_finalization_policy.md` — FINALIZATION mandatory rationale + adjustment manifest v≥2
- `audit_event_taxonomy.md` — `WORKFLOW_PHASE_SKIPPED` event + skip_reason enum (cross-block flagged for B05·P02)
- `gate_function_library_schema.md` — registered gate functions that return ADVANCE/SKIP/HOLD
- Block 03 Phase 02 — workflow type registry + config (owning phase)
- Block 03 Phase 05 — gate evaluation framework
- Block 03 Phase 06 — phase execution
- Block 12 — OUT_MONTHLY + OUT_ADJUSTMENT consumer
- Block 13 — IN_MONTHLY + IN_ADJUSTMENT consumer
- Stage 1 decision — optionality via gates, not via per-phase boolean
