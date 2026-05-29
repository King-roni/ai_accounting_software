# Stage 4 Layer 2 Scan 2 — Cross-Corpus Consistency Findings

**Scan date:** 2026-05-15
**Corpus size:** 233 sub-docs (60 more than Scan 1 at 173)
**Total findings:** 60
**Severity breakdown:** BLOCKING 35 · HIGH 11 · MEDIUM 11 · LOW 3

---

## Executive summary

The dominant issue by count is LINE_COUNT: 35 files fall below the 140-line hard-fail threshold, all introduced in cycles 4–5. The gate naming migration (engine.gate_* canonical form per the 2026-05-15 decisions-log amendment) was applied to gate_function_library_schema.md but not propagated to 13 downstream policy, reference, and schema files that still use the deprecated gate.out.*, gate.in.*, and gate.finalization.* 3-part patterns. Two schema files have genuinely inconsistent duplicate DDL for credit_note_status_enum and dedup_status_enum. One policy file (export_pipeline_policy.md) states a 30-day Processing-zone retention for exports, contradicting the canonical 24-hour export-temp TTL. Two audit events are referenced but absent from the taxonomy.

---

## Check-by-check results

### 1. ENUM_DRIFT — 2 findings (MEDIUM)

Both findings are in Processing-zone purge descriptions that list the canonical terminal run state as `COMPLETED` rather than `FINALIZED`.

| # | File | Line | Issue |
|---|------|------|-------|
| 1 | `schemas/layer1_rule_evaluation_schema.md` | 103 | `COMPLETED` as terminal `workflow_runs.status`; must be `FINALIZED` |
| 2 | `schemas/bank_statement_rows_schema.md` | 88 | Same; purge trigger listed as `COMPLETED, FAILED, CANCELLED` |

**Fix:** Replace `COMPLETED` with `FINALIZED` in each terminal-state list.

---

### 2. TOOL_NAMESPACE — 0 findings

All tool names confirmed to use a namespace from the 14-item allowlist in the 2-part snake_case format. No violations found.

---

### 3. GATE_NAMING — 13 findings (HIGH × 6, MEDIUM × 7)

The 2026-05-15 decisions-log amendment locked canonical gate names at `engine.gate_<phase_descriptor>`. `gate_function_library_schema.md` was updated, but 13 other files retain the deprecated 3-part patterns.

**Files still using deprecated patterns:**

| Pattern | Files |
|---------|-------|
| `gate.in.*` | `policies/in_phase_gate_policy.md`, `reference/in_monthly_phase_sequence.md`, `schemas/allocation_invariant_schema.md` |
| `gate.out.*` | `policies/out_manual_hold_policy.md`, `policies/side_phase_routing_policy.md`, `reference/out_monthly_phase_sequence.md`, `tools/tool_gate_function_signature.md` |
| `gate.finalization.*` | `policies/archive_step_up_policy.md`, `policies/lock_sequence_policies.md`, `schemas/finalization_gate_sql_schema.md`, `schemas/adjustment_finalization_precondition_schema.md`, `schemas/audit_log_quiescent_predicate_schema.md`, `runbooks/phase_renumbering_migration_runbook.md` |

**Fix:** Global rename in each file: `gate.out.<d>` → `engine.gate_<d>`, `gate.in.<d>` → `engine.gate_<d>`, `gate.finalization.<d>` → `engine.gate_<d>`.

---

### 4. AUDIT_EVENT_ORPHAN — 2 findings (MEDIUM × 1, LOW × 1)

| # | File | Line | Orphan event | Should be |
|---|------|------|-------------|-----------|
| 16 | `runbooks/live_integration_test_runbook.md` | 74 | `INTEGRATION_REPLAY_DRIFT_DETECTED` | `LIVE_TEST_DRIFT_DETECTED` (taxonomy line 129 of same file) |
| 17 | `tools/tool_hash_chain_append.md` | 133 | `EVENT_AUDIT_RECOVERED` | Not in taxonomy; needs to be added or replaced with `FINALIZATION_LOCK_AUDIT_RECOVERED` |

---

### 5. UUID_MISMATCH — 0 findings

All UUID v4 uses confirmed as one of the 5 documented exceptions (session IDs, password-reset tokens, invitation tokens, OAuth state IDs, step-up MFA tokens). No v4 used for business-data PKs.

---

### 6. SEVERITY_DRIFT — 0 findings

No use of `CRITICAL` as a severity value. All severity references use the canonical `{LOW, MEDIUM, HIGH, BLOCKING}` enum.

---

### 7. DUPLICATE_DDL — 4 findings (HIGH × 2, MEDIUM × 1, LOW × 1)

| # | File | Object | Problem |
|---|------|--------|---------|
| 18 | `schemas/credit_note_cumulative_cap_schema.md` | `credit_note_status_enum` | Missing `DRAFT` value vs canonical 3-value enum in `credit_note_schema.md` |
| 19 | `schemas/credit_note_cumulative_cap_schema.md` | `CREATE TABLE credit_notes` | Conflicting column types (bigint vs numeric; missing status transition columns) |
| 20 | `schemas/deduplication_fingerprint_schema.md` | `dedup_status_enum` | Defines 3 conceptual values; canonical `transactions_schema.md` has 4 different operational values — same type name, different values |
| 21 | `reference/workflow_state_enum.md` | `run_status_enum` | Identical 10-value enum also defined in `workflow_run_schema.md`; reference doc should not contain DDL |

---

### 8. FORWARD_REF_STALE — 3 findings (LOW)

| # | File | Stale reference | Now-existing file |
|---|------|----------------|-------------------|
| 22 | `schemas/split_payment_relationship_schema.md` | `match_records_schema (forward reference)` | `match_record_schema.md` exists |
| 23 | `schemas/out_adjustment_type_definition.md` | `adjustment_record_schema (forward reference)` | `adjustment_record_schema.md` exists |
| 24 | `schemas/in_adjustment_type_definition.md` | `adjustment_record_schema (forward reference)` | `adjustment_record_schema.md` exists |

---

### 9. MOBILE_WRITE_MISSING — 0 findings

All write-side tools confirmed to either (a) carry a mobile rejection note, (b) be infrastructure-internal tools not reachable via mobile clients (tool_hash_chain_append, tool_period_report_generator are WRITES_AUDIT via internal paths only), or (c) be READ_ONLY (tool_clients_registry).

---

### 10. INVOICE_SERIES — 0 findings

All invoice series formats confirmed as `INV-YYYY-NNNN` / `PRO-YYYY-NNNN` / `CN-YYYY-NNNN`. Sequence allocation consistently documented as firing at `DRAFT → SENT` transition (ISSUED time), not DRAFT creation.

---

### 11. DATA_ZONE_DRIFT — 1 finding (HIGH)

| # | File | Line | Issue |
|---|------|------|-------|
| 25 | `policies/export_pipeline_policy.md` | 60 | States 30-day retention in Processing zone; canonical is 24-hour TTL in `export-temp` bucket per `data_retention_policy` |

---

### 12. LINE_COUNT — 35 findings (BLOCKING)

35 files fall below the 140-line minimum. All are in the 87–139 line range. The shortest files are concentrated in the `reference/` directory (enum docs) and shorter `integrations/` docs.

**Shortest files:**

| File | Lines |
|------|-------|
| `reference/match_level_enum.md` | 87 |
| `reference/severity_enum.md` | 93 |
| `policies/step_up_auth_for_workflow_approval_policy.md` | 101 |
| `reference/issue_group_enum.md` | 101 |
| `reference/filter_rule_type_direction_table.md` | 106 |

See findings #26–60 for the complete list with per-file fix guidance.

---

## Prioritised action plan

1. **LINE_COUNT (35 BLOCKING)** — Expand all 35 short sub-docs to ≥ 140 lines. Enum reference files can be expanded with per-value narrative, Cyprus VAT law citations, and cross-references. Policy files need additional edge-case coverage.

2. **GATE_NAMING (13 HIGH/MEDIUM)** — Global rename across 13 files; the pattern is mechanical (`gate.out.X` → `engine.gate_X`, `gate.in.X` → `engine.gate_X`, `gate.finalization.X` → `engine.gate_X`). Can be done in a single PR.

3. **DUPLICATE_DDL credit_notes (2 HIGH)** — Remove the duplicate `CREATE TYPE` and `CREATE TABLE` from `credit_note_cumulative_cap_schema.md`; replace with cross-references to `credit_note_schema.md`.

4. **DATA_ZONE_DRIFT (1 HIGH)** — Fix `export_pipeline_policy.md` line 60: change to 24-hour TTL in `export-temp` bucket.

5. **ENUM_DRIFT (2 MEDIUM)** — Replace `COMPLETED` with `FINALIZED` in two schema purge descriptions.

6. **AUDIT_EVENT_ORPHAN INTEGRATION_REPLAY_DRIFT_DETECTED (1 MEDIUM)** — Replace with `LIVE_TEST_DRIFT_DETECTED` on line 74 of `live_integration_test_runbook.md`.

7. **DUPLICATE_DDL dedup_status_enum (1 MEDIUM)** — Rename or remove the 3-value conceptual enum from `deduplication_fingerprint_schema.md`.

8. **Remaining LOW findings** — Stale forward references (#22–24), EVENT_AUDIT_RECOVERED orphan (#17), and run_status_enum DDL duplicate (#21) can be addressed in the same pass as higher-priority fixes.

---

## Comparison with Scan 1 (173 files)

Scan 1 found 14 findings at 173 files. This scan finds 60 findings at 233 files. The increase is driven almost entirely by the 35 LINE_COUNT failures in the 60 new cycle-4/5 files — many of which are smaller reference and integration docs that did not reach the 140-line threshold. The gate naming issue is a propagation failure from the 2026-05-15 amendment that updated the schema but not the downstream consumers. Non-line-count issues (ENUM_DRIFT, DUPLICATE_DDL, DATA_ZONE_DRIFT, AUDIT_EVENT_ORPHAN) total 10 findings, consistent with the prior scan's 14.
