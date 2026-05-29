# Block 15 — Phase 02: Finalization Preconditions & Gate Function Library

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Finalization Preconditions — the 8-item list)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 05 — gate evaluation framework; canonical `GateResult` shape)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 05 — gate-function library pattern)
- Block doc: `Docs/blocks/14_review_queue.md` (Phase 02 — `BLOCKING` severity; the gate predicate)

## Phase Goal

Encode the eight finalization preconditions from the architecture doc as registered gate functions; sequence them into a single composite gate `gate.finalization.preconditions_satisfied`; wire the first-failure-halts contract that re-routes to Block 14 with structured re-open issues. After this phase, the lock sequence (Phase 04) has a single deterministic guard before any side effect runs.

## Dependencies

- Phase 01 (`archive_packages` schema; `workflow_run_approvals` consumption)
- Block 03 Phase 05 (gate evaluation framework)
- Block 04 Phase 02 (`transactions` — preconditions check `transaction_type` for UNKNOWN)
- Block 04 Phase 03 (`match_records` — preconditions check evidence)
- Block 04 Phase 04 (`review_issues` — preconditions check zero BLOCKING; `draft_ledger_entries` — preconditions check entries produced)
- Block 05 Phase 02 (audit log — preconditions check no unwritten events)
- Block 11 Phase 09 (LEDGER_PREPARATION exit gate — Block 15 inherits the all-VAT-fields-populated invariant)
- Block 12 Phase 01 (`workflow_run_approvals`)
- Block 14 Phase 02 (severity enum — `BLOCKING` predicate)

## Deliverables

- **The eight preconditions** (encoded as individual gate functions; each takes `(run, business_id) → GateResult`):
  1. **`gate.finalization.transactions_processed`** — `ADVANCE` when every `transactions` row for the run has `processing_status ∈ {NEW, DUPLICATE_*, NEEDS_REVIEW_RESOLVED}`. `HOLD` if any row is mid-processing.
  2. **`gate.finalization.no_unknown_types`** — `ADVANCE` when `count(transactions WHERE workflow_run_id = $run AND transaction_type = 'UNKNOWN') = 0`. `HOLD` otherwise. UNKNOWN-typed rows would have been flagged by Block 14 Phase 02's `BLOCKING`-severity rule already, so this is a defense-in-depth check.
  3. **`gate.finalization.evidence_satisfied`** — for each in-scope OUT_EXPENSE / payroll-contractor / loan-shareholder / etc. row requiring evidence per Block 11 Phase 08's evidence-flag table: `ADVANCE` when each has a `MATCHED_*` `match_record` OR `transactions.effective_match_status = EXCEPTION_DOCUMENTED` (Block 12 Phase 06's path). `HOLD` otherwise.
  4. **`gate.finalization.draft_ledger_entries_complete`** — `ADVANCE` when every in-scope transaction has at least one `draft_ledger_entries` row OR is held with an audit-logged reason (UNKNOWN-type held; covered by gate 2). `HOLD` otherwise.
  5. **`gate.finalization.vat_classifications_complete`** — `ADVANCE` when every `draft_ledger_entries` row in the run has `vat_treatment != null` AND any `vat_treatment = UNKNOWN` rows have `requires_accountant_review = true` (advisory in MVP per Stage 1; the flag is captured but doesn't block — only the missing-VAT-field case blocks). `HOLD` if any non-UNKNOWN entry has null treatment.
  6. **`gate.finalization.zero_blocking_issues`** — `ADVANCE` when `count(review_issues WHERE workflow_run_id = $run AND severity IN ('HIGH', 'BLOCKING') AND status = 'OPEN') = 0`. The predicate matches Block 12 Phase 07 / Block 13 Phase 09's identical predicate. **Note:** Block 15's architecture doc (line 40) reads "Zero BLOCKING review issues open" using narrower wording, but the canonical post-2026-05-08-amendment predicate across every consumer block is `{HIGH, BLOCKING}` — Phase 02 adopts the wider predicate for consistency. The HIGH issues are exception-clearable per Block 14 Phase 04's rules (e.g., `Mark as no invoice available`); BLOCKING issues are not. `HOLD` otherwise.
  7. **`gate.finalization.approval_recorded`** — `ADVANCE` when `EXISTS(SELECT 1 FROM workflow_run_approvals WHERE run_id = $run AND revoked_at IS NULL AND approval_method = 'STEP_UP')`. Phase 03 owns the step-up requirement; this gate enforces it at lock time. `HOLD` if no qualifying approval exists.
  8. **`gate.finalization.audit_log_quiescent`** — `ADVANCE` when both: (a) the audit subsystem is reachable (Block 05 Phase 02's connectivity check returns OK), AND (b) no audit-log write for `workflow_run_id = $run` has occurred in the last 5 seconds (a "settle window" ensuring upstream emissions have flushed). The 5-second settle window is the canonical Stage 1 predicate — sub-doc may tune the value but the predicate shape is pinned. `HOLD` if either fails. The audit chain itself is global (not per-run), so no per-run chain check is required — the gate verifies emission-quiescence at the run scope, not chain integrity at the global scope (chain integrity is owned by Block 05 Phase 03 / Phase 07's verification pass, not by this gate).
- **Composite gate** — `gate.finalization.preconditions_satisfied`:
  - Invokes the eight gates above in order. **First failure halts**: returns `HOLD` with `failure_reason` set to the failing gate's name plus a structured `failure_payload`.
  - On `ADVANCE` from all eight, returns `ADVANCE` and the lock sequence (Phase 04) proceeds.
  - The composite gate is registered with Block 03 Phase 05's framework as the entry gate of the `FINALIZATION` phase.
- **First-failure re-open contract:**
  - When the composite gate returns `HOLD`, Block 15 invokes Block 14's review-queue surface to re-open or surface a finalization-blocking issue:
    - For gates 1–4: re-open the underlying upstream issue (e.g., gate 2 failure → `classification.unknown_type` issues already in the queue; the re-open is a no-op since they're already `OPEN`).
    - For gate 5: surface a `Possible Tax/VAT Issue` HIGH issue identifying the entry with null treatment.
    - For gate 6: this is the "blocking issues exist" path — the gate failure is informational; the user already sees the blocking issues in the queue.
    - For gate 7: surface a `finalization.approval_missing_or_not_step_up` HIGH issue (issue type registered in Phase 02's registry per the canonical namespacing convention).
    - For gate 8: surface `finalization.audit_log_pending_writes` HIGH issue.
  - The user resolves the issue(s) → Block 14 Phase 08's affected-set re-scan fires → the composite gate re-evaluates → on `ADVANCE`, the lock sequence proceeds.
- **Idempotency:**
  - The composite gate is idempotent — repeated invocation with the same inputs returns the same `GateResult`.
  - Re-evaluation cost is bounded — sub-doc owns the per-gate cost target; Stage 1 default: composite gate completes in under 1 second for typical periods.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_PRECONDITIONS_PASSED` (when the composite gate returns `ADVANCE`)
  - `FINALIZATION_PRECONDITIONS_FAILED` (with `failure_reason` and `failing_gate` fields)
  - `FINALIZATION_PRECONDITION_REOPEN_TRIGGERED` (one event per re-opened issue)

## Definition of Done

- All eight gate functions register at engine boot and are referenceable by name.
- The composite gate calls them in order; first-failure-halts works correctly.
- A test fixture with one open BLOCKING issue → gate 6 fails → composite returns `HOLD` with the right reason; gate 7 doesn't run.
- A test fixture with all preconditions met → composite returns `ADVANCE`; the lock sequence (Phase 04) starts.
- A test fixture with `approval_method = STANDARD` (not STEP_UP) → gate 7 fails; the issue surfaces.
- A re-evaluation after issue resolution returns `ADVANCE` cleanly.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Per-gate SQL plan sub-doc** — query plans; per-gate latency budget.
- **`audit_log_quiescent` predicate sub-doc** — exact definition; integration with Block 05's hash-chain commit semantics.
- **First-failure re-open mapping sub-doc** — exact `issue_type` per failing gate.
- **Gate sequencing sub-doc** — whether to short-circuit on first-fail or run all eight for richer diagnostics; Stage 1 default = short-circuit.
