# workflow_run_approvals Schema

**Category:** Schemas · **Owning block:** 12 — OUT Workflow / 13 — IN Workflow · **Block reference:** Block 12 § Phase 09 (Finalization Preconditions), Block 13 § Phase 08 (Finalization Preconditions) · **Stage:** 4 sub-doc (Layer 2 schema)

**Purpose:** Defines the `workflow_run_approvals` table, which records every formal approval request and resolution that gates workflow run progression. Two approval types require explicit accountant action: releasing a manual REVIEW_HOLD (`HUMAN_REVIEW_HOLD_RELEASE`) and authorising final period lock (`FINALIZATION`). This table is the authoritative record for both.

---

## Table DDL

```sql
CREATE TABLE workflow_run_approvals (
  id                     UUID        NOT NULL DEFAULT gen_uuid_v7(),
  workflow_run_id        UUID        NOT NULL REFERENCES workflow_runs(id),
  approval_type          approval_type_enum   NOT NULL,
  status                 approval_status_enum NOT NULL DEFAULT 'PENDING',
  requested_by_user_id   UUID        NOT NULL REFERENCES users(id),
  approved_by_user_id    UUID        REFERENCES users(id),
  step_up_token_id       UUID        REFERENCES step_up_tokens(id),   -- UUID v4 FK
  requested_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at            TIMESTAMPTZ,
  expires_at             TIMESTAMPTZ NOT NULL
                           GENERATED ALWAYS AS (requested_at + INTERVAL '72 hours') STORED,
  rejection_reason       TEXT        CHECK (char_length(rejection_reason) <= 500),

  CONSTRAINT wra_pk PRIMARY KEY (id)
);
```

**ID generation:** `id` uses `gen_uuid_v7()` — time-ordered primary key per `data_layer_conventions_policy`. The FK `step_up_token_id` references `step_up_tokens.id`, which uses `gen_random_uuid()` (UUID v4) per the `data_layer_conventions_policy` exceptions table: step-up MFA tokens are security tokens where a time-ordered prefix would leak creation time.

---

## Enums

### `approval_type_enum`

| Value | Trigger | Description |
| --- | --- | --- |
| `HUMAN_REVIEW_HOLD_RELEASE` | Accountant releases a REVIEW_HOLD | Confirms all issues in the review queue for the run have been resolved or explicitly accepted; unblocks the run from `REVIEW_HOLD`. Does not require step-up token. |
| `FINALIZATION` | Accountant authorises period lock | Confirms the run is ready to enter `FINALIZING` and the period archive can proceed. Requires a valid step-up token at resolution time. |

These two types are the only ones that require an approval row. All other run-state transitions are gated by `engine.gate_<phase_descriptor>` functions and do not create approval records.

### `approval_status_enum`

| Value | Terminal | Description |
| --- | --- | --- |
| `PENDING` | No | Awaiting accountant action. |
| `APPROVED` | Yes | Accountant confirmed; run may proceed. |
| `REJECTED` | Yes | Accountant declined. A new approval request can be opened after addressing the rejection reason. |
| `EXPIRED` | Yes | 72-hour window elapsed without resolution. The background expiry job set this status. |

---

## Expiry window

Approvals expire 72 hours after creation. The `expires_at` column is a generated column computed as `requested_at + INTERVAL '72 hours'` and cannot be overridden at insert time.

### Background expiry job

A scheduled job (cadence: every 15 minutes) scans `workflow_run_approvals` where `status = 'PENDING'` and `expires_at <= now()`. For each matching row it:

1. Updates `status` to `EXPIRED`.
2. Sets `resolved_at = now()`.
3. Emits `WORKFLOW_APPROVAL_EXPIRED` with payload `{ approval_id, workflow_run_id, approval_type, requested_by_user_id, expired_at }`.

After expiry, the run remains in its current status — the engine does not automatically transition. A new approval request must be created explicitly by the requestor. There is no automatic re-request.

---

## Step-up token validation (FINALIZATION type)

For `approval_type = FINALIZATION`:

- `step_up_token_id` **must** be non-null at insert time. An attempt to insert a `FINALIZATION` row with a null `step_up_token_id` is rejected by a `CHECK` constraint:

  ```sql
  CONSTRAINT wra_finalization_requires_step_up
    CHECK (
      approval_type <> 'FINALIZATION'
      OR step_up_token_id IS NOT NULL
    )
  ```

- At resolution time, the resolution handler calls `auth.validate_step_up_token(step_up_token_id, expected_action => 'FINALIZATION_APPROVAL')`. If the token has expired or has already been consumed, the resolution is rejected: `status` is set to `REJECTED` and `rejection_reason` is set to the string `'STEP_UP_EXPIRED'` (for expired tokens) or `'STEP_UP_ALREADY_CONSUMED'` (for consumed tokens). The rejected approval is terminal; a new approval request with a fresh step-up token must be created.

- On successful resolution, `auth.validate_step_up_token` marks the token consumed. The consumed event (`STEP_UP_TOKEN_CONSUMED`) is emitted by the auth layer.

For `approval_type = HUMAN_REVIEW_HOLD_RELEASE`, `step_up_token_id` must be null:

```sql
CONSTRAINT wra_hold_release_no_step_up
  CHECK (
    approval_type <> 'HUMAN_REVIEW_HOLD_RELEASE'
    OR step_up_token_id IS NULL
  )
```

---

## Concurrency guard

At most one `PENDING` approval for a given `(workflow_run_id, approval_type)` pair may exist at any time. This is enforced by a partial unique index:

```sql
CREATE UNIQUE INDEX uq_wra_one_pending_per_run_type
  ON workflow_run_approvals (workflow_run_id, approval_type)
  WHERE status = 'PENDING';
```

Attempting to insert a second `PENDING` row for the same pair raises a unique-constraint violation. The caller must check for an existing `PENDING` row before requesting a new approval; the constraint is a safety net, not the primary check path.

---

## Indexes

```sql
-- Primary lookup: all approvals for a run
CREATE INDEX idx_wra_workflow_run_id
  ON workflow_run_approvals (workflow_run_id, requested_at DESC);

-- Background job: all pending approvals past their expiry window
CREATE INDEX idx_wra_pending_expires
  ON workflow_run_approvals (expires_at)
  WHERE status = 'PENDING';

-- Audit query: approvals by actor
CREATE INDEX idx_wra_requested_by
  ON workflow_run_approvals (requested_by_user_id, requested_at DESC);
```

---

## Row-level security

The table inherits business-scoped RLS via a join to `workflow_runs.business_id`. The RLS policy:

- **Accountant / Owner / Admin / Bookkeeper:** can read all approval rows for their business.
- **Accountant:** can insert `PENDING` rows and update `status` to `APPROVED` or `REJECTED` on rows they did not create (i.e., they may not approve their own requests).
- **Self-approval prevention:** enforced by a `CHECK` constraint:

  ```sql
  CONSTRAINT wra_no_self_approval
    CHECK (approved_by_user_id IS NULL OR approved_by_user_id <> requested_by_user_id)
  ```

- Write actions on this table are blocked for mobile clients per `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | Severity | Emitted when |
| --- | --- | --- |
| `WORKFLOW_APPROVAL_REQUESTED` | LOW | A new `PENDING` row is inserted. |
| `WORKFLOW_APPROVAL_GRANTED` | LOW | `status` transitions to `APPROVED`. |
| `WORKFLOW_APPROVAL_REJECTED` | MEDIUM | `status` transitions to `REJECTED`. MEDIUM because rejection may indicate a data readiness issue or a step-up token problem that blocks finalization. |
| `WORKFLOW_APPROVAL_EXPIRED` | MEDIUM | `status` transitions to `EXPIRED` via the background job. MEDIUM because an expired approval stalls the run until a new request is raised. |

**Payload shape for `WORKFLOW_APPROVAL_REQUESTED`:**
`{ approval_id, workflow_run_id, approval_type, requested_by_user_id, expires_at }`

**Payload shape for `WORKFLOW_APPROVAL_GRANTED`:**
`{ approval_id, workflow_run_id, approval_type, approved_by_user_id, resolved_at, step_up_token_id (FINALIZATION type only) }`

**Payload shape for `WORKFLOW_APPROVAL_REJECTED`:**
`{ approval_id, workflow_run_id, approval_type, approved_by_user_id, rejection_reason, resolved_at }`

**Payload shape for `WORKFLOW_APPROVAL_EXPIRED`:**
`{ approval_id, workflow_run_id, approval_type, requested_by_user_id, expired_at }`

All four events are emitted on the business-scoped audit chain. Audit events follow `data_layer_conventions_policy` canonical JSON serialization.

---

## Relationship to run_status_enum

| Approval type | Run status before request | Run status after APPROVED | Run status after REJECTED / EXPIRED |
| --- | --- | --- | --- |
| `HUMAN_REVIEW_HOLD_RELEASE` | `REVIEW_HOLD` | Advance to next phase (gate re-evaluated) | Remains `REVIEW_HOLD` |
| `FINALIZATION` | `AWAITING_APPROVAL` | `FINALIZING` | Remains `AWAITING_APPROVAL` |

The `run_status_enum` values `CREATED · RUNNING · PAUSED · REVIEW_HOLD · AWAITING_APPROVAL · FINALIZING · FINALIZED · FAILED · CANCELLED · COMPENSATING` are defined in `workflow_runs` — this table does not duplicate them.

---

## Data retention

`workflow_run_approvals` rows are Operational zone data. They are retained for 7 years post-business-deactivation per the data zone definitions in `data_layer_conventions_policy`. Rows are not eligible for Processing zone TTL deletion (7-day post-run TTL does not apply to this table).

---

## Cross-references

- `workflow_approval_schema.md` — higher-level approval flow overview (Block 03 Phase 04)
- `step_up_validity_window_policy.md` — step-up token validity window and action-scope binding
- `human_review_approval_staleness_policy.md` — 72-hour expiry rationale and re-request flow
- `data_layer_conventions_policy` — UUID v7 / v4 rules, canonical JSON
- `audit_event_taxonomy` — `WORKFLOW_APPROVAL_REQUESTED`, `WORKFLOW_APPROVAL_GRANTED`, `WORKFLOW_APPROVAL_REJECTED`, `WORKFLOW_APPROVAL_EXPIRED`
- `mobile_write_rejection_endpoints.md` — mobile write blocking
- `out_monthly_phase_sequence.md` — which OUT phases trigger approval requests
- `in_monthly_phase_sequence.md` — which IN phases trigger approval requests
