# Stage 4 — Layer 2 Consistency Scan: Summary

**Scan date:** 2026-05-15  
**Corpus size:** 173 sub-docs  
**Total findings:** 14 — BLOCKING: 1 · HIGH: 2 · MEDIUM: 9 · LOW: 2

---

## Findings by severity

| Severity | Count |
|---|---|
| BLOCKING | 1 |
| HIGH | 2 |
| MEDIUM | 9 |
| LOW | 2 |

## Top 3 most impactful findings

**1. BLOCKING — ENUM_DRIFT — `soft_delete_vs_status_policy.md`**  
The policy applies the terminal state `COMPLETED` to `workflow_runs`, but the canonical `run_status_enum` has no `COMPLETED` value — the correct terminal success state is `FINALIZED`. `COMPLETED` is valid only for `phase_states` and `tool_invocations`. Any retention logic or status-sweep code that reads this policy and expects `COMPLETED` as a run terminal state will behave incorrectly.

**2. HIGH — DUPLICATE_DEFINITION — `workflow_approval_schema.md` + `human_review_approval_staleness_policy.md`**  
Two separate `CREATE TABLE workflow_run_approvals` definitions exist with irreconcilably different column sets. The staleness policy carries an older schema version (missing `approval_method`, `step_up_token_id`, `is_stale`, `stale_reason`, uses `id` instead of `approval_id`). Any code or migration generated from the wrong sub-doc will produce an incorrect table.

**3. HIGH — NAMING_VIOLATION — `gate_function_library_schema.md`**  
The schema asserts that gate names use block short-names from the `tool_naming_convention_policy` allowlist, but all registered gate names use `gate` as the first segment — a value absent from that allowlist. The naming pattern is also 3-part (`gate.<context>.<descriptor>`) rather than the 2-part tool convention. The documentation contradicts the examples throughout.

---

## Categories with the most hits

| Category | Count |
|---|---|
| MEDIUM TAXONOMY_GAP | 3 |
| MEDIUM POLICY_VIOLATION | 3 |
| MEDIUM CONSTRAINT_INCONSISTENCY | 2 |
| LOW FORWARD_REF_UNRESOLVED | 2 |
| HIGH DUPLICATE_DEFINITION | 2 (including 1 MEDIUM) |

## Systemic patterns

1. **Step-up token UUID drift** — Three documents (data_layer_conventions_policy, step_up_validity_window_policy, workflow_approval_schema) disagree on whether step-up token IDs use UUID v4 or v7. The policy doesn't mention step-up tokens; the token table uses v7; the approval schema claims v4 is required. This requires a coordinated 3-file fix with a decisions_log amendment (findings 5, 12).

2. **Taxonomy not kept in sync with sub-doc event declarations** — Three separate sub-docs declare or reference audit events that do not exist in `audit_event_taxonomy.md`: `STATEMENT_INGESTION_COMPLETED` (trigger event), four `IN_WORKFLOW_*` events claimed to be catalogued but absent, and five `LIVE_TEST_*` events under an unregistered domain. The taxonomy is the single source of truth, but Layer 2 docs diverge from it (findings 6, 7, 8).

3. **Write-surface mobile policy coverage gap** — Four tool sub-docs with `WRITES_RUN_STATE` side-effect class (`tool_credit_note_ledger_mapping`, `tool_invoice_lifecycle_integration`, `tool_vendor_memory_writeback`, `tool_vendor_memory_increment`) lack the required `mobile_write_rejection_endpoints` reference. Contrast with sibling tools (`tool_upload_pipeline_api`, `tool_bad_debt_expense`, `emit_audit_api`) which correctly include the reference (findings 9, 10, 11).

4. **Forward references not retired after the referenced files were written** — `adjustment_record_schema.md` has been created, but both `out_adjustment_type_definition.md` and `in_adjustment_type_definition.md` still carry the "forward reference, not yet written" qualifier (findings 13, 14).
