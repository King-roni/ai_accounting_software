# phase_renumbering_migration_runbook

**Category:** Runbooks · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block runbook)

The procedure for migrating workflow phase sequences when a workflow type's registered phases change (add / remove / reorder). Per the Block 12 Phase 02 scan fix (11-vs-12 phase consolidation): the canonical 5-phase OUT_ADJUSTMENT and 11-phase OUT_MONTHLY mental models are governed by the registry, not by phase docs.

Used when introducing a new phase, retiring one, or reordering existing phases — operations that affect both in-flight runs and finalized runs whose audit trail references phase names.

---

## Triggering scenarios

| Scenario | Example | Impact scope |
| --- | --- | --- |
| **Add a phase** | New `OUT_DUPLICATE_REVIEW` phase between MATCHING and LEDGER_PREPARATION | New runs only; old runs continue with old sequence |
| **Retire a phase** | Remove an experimental Tier 2 classification side-phase | Old runs continue; new runs skip the phase |
| **Reorder phases** | Move OUT_FILTER before INGESTION (hypothetical) | All future runs; per-run snapshot preserves history |
| **Rename a phase** | `OUT_MATCHING` → `MATCHING` (post-Block 12 scan consolidation) | Downstream consumers (Block 14, Block 16) must accept the rename |

## Procedure

### Step 1 — Pre-migration verification

```sql
-- Confirm no monthly run is in flight for the affected workflow_type
SELECT business_id, workflow_run_id, status, current_phase_name
FROM workflow_runs
WHERE workflow_type = $affected_type
  AND status IN ('CREATED', 'RUNNING', 'REVIEW_HOLD', 'AWAITING_APPROVAL', 'FINALIZING');
```

If any runs are in flight: defer migration. Wait for completion or operator-coordinate the cutover. Per `out_adjustment_policies`: adjustment runs may run concurrently with monthly runs; both must complete before migration.

### Step 2 — Register the new phase sequence

```ts
// In code — update the registry at deploy time
engine.registerWorkflowType("OUT_MONTHLY", {
  phases: [
    "INGESTION",
    "CLASSIFICATION",
    // ... etc, with the migration applied
  ],
  registry_version: "<new_version>"
});
```

Per Block 03 Phase 02's workflow type registry: registry has a version number. The version bump is recorded in audit per `audit_event_taxonomy`:

```
WORKFLOW_TYPE_REGISTRY_UPDATED { workflow_type, old_version, new_version, change_description }
```

### Step 3 — Verify existing runs' snapshots are intact

Per `workflow_run_schema`'s `effective_phase_sequence_json` column: every run carries a snapshot of the phase sequence at run start. Migration does NOT modify these snapshots.

```sql
-- A run started under the old sequence retains the old sequence
SELECT workflow_run_id, effective_phase_sequence_json, current_phase_index
FROM workflow_runs
WHERE workflow_type = $affected_type
  AND completed_at IS NOT NULL
LIMIT 5;
```

Visual check: old runs' snapshots reflect the old phase sequence; new runs (after Step 2) reflect the new sequence. Co-existence is by design — finalized runs' audit trails reference the names they saw at run time.

### Step 4 — Update downstream consumers

Per the Block 16 scan fix: Block 16 reads `current_phase_index` against `effective_phase_sequence_json` dynamically — no hard-coded phase numbers. The migration should not require Block 16 changes.

Block 14's `engine.gate_finalization_preconditions_satisfied` (per `lock_sequence_policies`) reads the canonical phase names directly; if a phase rename is part of the migration, Block 14's predicates need code changes alongside the registry update.

Per Block 12 Phase 02 fix: downstream consumers query for `LEDGER_PREPARATION` and similar canonical phase names. Renames must coordinate cross-block updates.

### Step 5 — Audit recording

```ts
emitAudit("WORKFLOW_PHASE_SEQUENCE_MIGRATED", {
  workflow_type: $type,
  old_sequence: $old_sequence,
  new_sequence: $new_sequence,
  migration_run_id: $migration_run_id,
  migrated_by_operator: $operator_user_id
});
```

The audit event records both old and new sequences. Future investigations can reconstruct the migration history.

### Step 6 — Verification

```bash
# Run a smoke test of the affected workflow type
pnpm test fixtures/<workflow_type>/smoke.fixture.ts

# Verify run progress API matches the new sequence
curl /workflow-runs/<test_run_id>/progress
```

The progress API per `tool_engine_get_run_progress` should reflect the new phase names and indices.

## Phase rename special case

A pure rename (no behavioral change) follows a slightly different procedure:

1. Old phase name registered with `deprecated = true, deprecated_at = now()`
2. New phase name registered as the primary
3. Audit events use the new name from that point forward
4. Old phase name remains in the registry for ≥ 30 days for backward-compat reads

Per `tool_naming_convention_policy` Section 5 deprecation rules: the deprecation period gives downstream consumers time to update.

## Failure handling

| Failure | Behavior |
| --- | --- |
| Mid-migration: an in-flight run becomes orphaned (its phase no longer in registry) | Engine catches at next state-machine evaluation; treats run as `FAILED` with `failure_class = PHASE_REGISTRY_DRIFT`; operator escalation |
| Audit emission fails | Migration is reversible; rollback per Step 7 |
| Downstream consumer breaks | Block 14/16 patches deploy alongside migration; if not synchronized, revert |

## Step 7 — Rollback procedure

```ts
// Revert the registry to the prior version
engine.registerWorkflowType("OUT_MONTHLY", {
  phases: $old_sequence,
  registry_version: "<reverted_to>"
});

// Emit
emitAudit("WORKFLOW_PHASE_SEQUENCE_MIGRATION_REVERTED", {
  workflow_type,
  reverted_from_version,
  reverted_to_version,
  reverted_by_operator
});
```

Rollback is supported because runs persist `effective_phase_sequence_json` — the registry is the only authoritative source of "what phase comes next" for in-flight runs, and rolling it back is safe.

## Audit events

| Event | When |
| --- | --- |
| `WORKFLOW_TYPE_REGISTRY_UPDATED` | New version registered |
| `WORKFLOW_PHASE_SEQUENCE_MIGRATED` | Step 5 |
| `WORKFLOW_PHASE_SEQUENCE_MIGRATION_REVERTED` | Step 7 (rollback) |

## Cross-references

- `workflow_run_schema` — `effective_phase_sequence_json` column
- `tool_naming_convention_policy` — deprecation rules
- `audit_log_policies` — event naming
- `out_adjustment_policies` — concurrency rules
- `tool_engine_get_run_progress` — progress API consumer
- Block 03 Phase 02 — workflow type registry & per-business config
- Block 12 Phase 02 — OUT_MONTHLY workflow definition
- Block 13 Phase 07 — IN_MONTHLY workflow definition
- 2026-05-08 Block 12 scan fix — 11 vs 12 phase consolidation
