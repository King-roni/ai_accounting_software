# workflow_approval_schema

**Category:** Schemas · **Owning block:** 12 — OUT Workflow (co-owner: 13 — IN Workflow) · **Stage:** 4 sub-doc (Layer 2)

The `workflow_run_approvals` table records every approval action taken against a workflow run at the `HUMAN_REVIEW_HOLD` gate. Both `OUT_MONTHLY` and `IN_MONTHLY` runs write approval rows here; the table is block-neutral and is queried by Block 03's gate evaluation engine, Block 15's finalization precondition checks, and the Block 15 archive bundle assembly. Approval rows are never deleted from the live table during the retention window; they are also exported into the finalization archive bundle at lock time so that the sealed archive is self-contained.

---

## Table definition

```sql
-- Canonical DDL: see workflow_run_approvals_schema.md (Block 12/13). This file documents the approval policy layer; the table definition is owned by workflow_run_approvals_schema.md.
```

## Column rationale

### `approval_id` (UUID v7)

Primary key via `gen_uuid_v7()`. UUID v7 is correct here — this is a business-data record and the time-prefix is not security-sensitive.

### `workflow_run_id` (FK)

References `workflow_runs.workflow_run_id`. Multiple approval rows per run are permitted. After a revocation, a fresh approval row is inserted; the gate counts only rows where `revoked_at IS NULL AND is_stale = false`. This means a run can accumulate several approval rows over its lifetime — the audit history is preserved in full.

### `approval_method`

Three values:

| Value | Meaning |
| --- | --- |
| `STANDARD` | No step-up challenge; user is authenticated via their active session. MVP default. |
| `STEP_UP_TOTP` | Step-up challenge completed using TOTP factor (Block 02 Phase 08). |
| `STEP_UP_PASSKEY` | Step-up challenge completed using WebAuthn/passkey factor (Block 02 Phase 08). |

The MVP default is `STANDARD` per Block 12 Phase 07: "step-up auth is NOT required by default in MVP." The `requires_step_up` flag on the permission surface (Block 02 Phase 04) can elevate this per-business; when it does, the approval tool rejects `STANDARD` and requires one of the `STEP_UP_*` variants.

### `approval_context` (JSONB)

Captures what the approver explicitly confirmed at the moment of approval. Shape:

```json
{
  "workflow_run_id": "<uuid>",
  "workflow_type": "OUT_MONTHLY",
  "business_id": "<uuid>",
  "period_start": "2026-01-01",
  "period_end": "2026-01-31",
  "open_issue_count_at_approval": 0,
  "confirmed_at": "2026-02-03T14:22:00Z"
}
```

The context is canonical JSON per `data_layer_conventions_policy` so it can feed the audit-chain hash without re-serialization. The `open_issue_count_at_approval` field provides a point-in-time snapshot of the review queue state the approver saw.

### `step_up_token_id` (UUID v4, nullable)

References the step-up token consumed during this approval. UUID v4 is mandated here (not v7) because step-up token IDs are security-sensitive — a time-ordered prefix would leak the approximate creation time to anyone who can read the column. Per `data_layer_conventions_policy` exception table: "Step-up token IDs use UUID v4."

Null when `approval_method = STANDARD`.

### `is_stale` / `stale_reason`

An approval becomes stale under two conditions:

1. **`ROLE_CHANGED`** — the approving user's role is downgraded after approval (e.g., from Admin to Bookkeeper). The gate re-evaluates and flags this approval as stale because the user no longer holds the `WORKFLOW_APPROVE` surface.
2. **`PERIOD_AMENDED`** — the run's period boundaries are revised after approval (rare; only possible while the run is still in `AWAITING_APPROVAL`). The approval is stale because the approver confirmed a different period.
3. **`APPROVAL_REVOKED`** — the approver or an Owner explicitly revokes the approval via `out_workflow.user_revoke_approval` / `in_workflow.user_revoke_approval`. The row is NOT deleted; `is_stale` is set to true with reason `APPROVAL_REVOKED`, and `revoked_by_user_id` / `revoked_at` are populated.

The `CONSTRAINT stale_reason_requires_stale` ensures `stale_reason` is never set on a non-stale row.

Stale approvals remain in the audit log permanently. They are included in the archive bundle export so that finalization reviewers can reconstruct the full approval history including any revocations.

### `revoked_by_user_id` / `revoked_at`

Populated only when `stale_reason = APPROVAL_REVOKED`. The `CONSTRAINT revoked_requires_revoked_at` ensures the two columns are always in sync (both null or both non-null).

## Indexes

```sql
CREATE INDEX idx_workflow_approvals_run
  ON workflow_run_approvals(workflow_run_id);

CREATE INDEX idx_workflow_approvals_user
  ON workflow_run_approvals(approved_by_user_id);
```

The `(workflow_run_id)` index is the hot-path for gate evaluation: `WHERE workflow_run_id = $run AND revoked_at IS NULL AND is_stale = false`. The `(approved_by_user_id)` index supports the role-change staleness sweep (when a user's role changes, the system must find all non-stale approvals by that user and mark them stale where applicable).

## RLS

```sql
CREATE POLICY workflow_run_approvals_isolation ON workflow_run_approvals
  FOR ALL
  USING (
    workflow_run_id IN (
      SELECT workflow_run_id FROM workflow_runs
      WHERE business_id = ANY(auth.business_ids_for_session())
    )
  );
```

## Permission gate

Inserting an approval row requires the `WORKFLOW_APPROVE` surface (Block 02 Phase 04). In MVP this grants Owner, Admin, and Bookkeeper. Accountant, Reviewer, and Read-only receive 403.

Mobile write rejection: approval is a write action. Any approval attempt from `client_form_factor = MOBILE` is rejected with `MOBILE_WRITE_REJECTED` before the permission check.

## Retention and archive export

`workflow_run_approvals` rows are retained for the full retention window (default 6 years per Cyprus VAT requirements). At lock time (Block 15 Phase 04), the finalization process exports all approval rows for the run's `workflow_run_id` into the finalization archive bundle. The export is a canonical JSON array included in the bundle manifest so that the sealed archive is self-contained and audit-verifiable without querying the live table.

## Gate evaluation query

Block 03's `engine.gate_human_review_hold_clear` (and the symmetric IN-side gate) uses:

```sql
SELECT COUNT(*) > 0
FROM workflow_run_approvals
WHERE workflow_run_id = $run_id
  AND revoked_at IS NULL
  AND is_stale = false;
```

A result of `true` satisfies the "non-revoked approval exists" gate condition. The "zero blocking issues open" condition is evaluated separately against `review_issues`.

## Audit events

| Event | Trigger |
| --- | --- |
| `WORKFLOW_APPROVAL_RECORDED` | A new approval row is inserted (non-stale, non-revoked) |
| `WORKFLOW_RUN_APPROVAL_STALE` | An existing approval row is marked stale (any `stale_reason`) |

Domain `WORKFLOW` per `audit_log_policies`. Both events exist in `audit_event_taxonomy` under the WORKFLOW / WORKFLOW_GATE / WORKFLOW_TOOL domain block.

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for `approval_id`; UUID v4 for `step_up_token_id`; canonical JSON for `approval_context`
- `audit_log_policies` — WORKFLOW domain; past-tense naming convention
- `audit_event_taxonomy` — `WORKFLOW_APPROVAL_RECORDED`, `WORKFLOW_RUN_APPROVAL_STALE` under WORKFLOW domain
- `workflow_run_schema` — `workflow_run_id` FK; run status `AWAITING_APPROVAL`
- Block 12 Phase 07 — HUMAN_REVIEW_HOLD gate; `out_workflow.user_approval` and `out_workflow.user_revoke_approval` tools
- Block 13 Phase 09 — symmetric IN-side HUMAN_REVIEW_HOLD gate
- Block 15 Phase 04 — finalization archive bundle export of approval rows
- Block 02 Phase 04 — `WORKFLOW_APPROVE` permission surface; step-up flag
- Block 02 Phase 08 — step-up token lifecycle
