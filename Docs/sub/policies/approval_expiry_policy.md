# approval_expiry_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2 policy)

Defines when workflow approval records expire, how expiry is detected, and what the engine and users must do to unblock a run after expiry.

---

## Scope

This policy applies to all `workflow_run_approvals` rows with `status = PENDING`. The approval mechanism is used when a workflow run's phase gate returns `AWAITING_APPROVAL`, transitioning the run to `AWAITING_APPROVAL` status.

---

## Approval TTL

A `workflow_run_approvals` row in `PENDING` status expires 72 hours after `requested_at`. The expiry timestamp is stored in the `expires_at` column:

```sql
expires_at = requested_at + INTERVAL '72 hours'
```

The 72-hour window applies universally across all workflow types and approval tiers. There is no configurable TTL per workflow type in MVP.

---

## Expiry detection: lazy evaluation

Expiry is detected lazily, not by a background job. The workflow engine evaluates whether a PENDING approval has expired at the point when it attempts to assess the approval gate:

1. The gate handler reads the `workflow_run_approvals` row(s) for the run.
2. For each row with `status = PENDING`, the engine compares `expires_at` to `now()`.
3. If `expires_at < now()`, the engine transitions that row's status to `EXPIRED` and emits `ENGINE_APPROVAL_EXPIRED`.
4. The gate is then evaluated as if those rows were never approved.

No background timer or scheduled job performs expiry transitions. An approval that has passed its TTL but has not been evaluated remains in `PENDING` status in the database until the gate is next evaluated.

---

## Effect of expiry on run status

When an approval expires:

- The `workflow_run_approvals` row transitions from `PENDING` to `EXPIRED`.
- The `workflow_runs` row remains in `AWAITING_APPROVAL` status. The run does not self-advance.
- All further gate evaluations for the same phase will fail until a new PENDING approval is created.

Expiry does not transition the run to `FAILED` or `CANCELLED`. The run is stalled, not terminated.

---

## Re-requesting approval

After expiry, the accountant or any user with role ADMIN may re-request approval via `review_queue.request_approval`. This creates a new `workflow_run_approvals` row with:

- `status = PENDING`
- `requested_at = now()`
- `expires_at = now() + INTERVAL '72 hours'`

The prior EXPIRED row is retained for audit. Multiple expired rows may accumulate if the approval is re-requested and allowed to expire multiple times. Each is a distinct record with its own `expires_at` and audit trail.

The audit event `ENGINE_APPROVAL_REREQUESTED` is emitted by `review_queue.request_approval` when a new approval is created for a run that already has at least one EXPIRED row.

---

## Multi-approver scenarios

Some phase gates require multiple approvals (for example, HIGH-value finalization may require both ADMIN and OWNER approval). In multi-approver configurations:

- The gate passes only when all required approvals have `status = APPROVED`.
- If any approval is `EXPIRED`, the gate fails.
- The expired approval must be re-requested individually; the other already-APPROVED approvals are not invalidated by an unrelated expiry.
- Re-requesting only the expired approval is sufficient. The APPROVED approvals from earlier in the same 72-hour window remain valid provided they are still within their own `expires_at`.

Multi-approver configuration is stored in the phase gate definition within `workflow_type_registry`.

---

## Step-up auth linkage

Approval is gated by step-up authentication per `archive_step_up_policy.md`. The approver must hold a valid step-up token at the moment of approving:

- If the step-up token is expired or consumed at approval time, the approval action fails with `STEP_UP_REQUIRED` before any `workflow_run_approvals` state change occurs.
- A technically in-window approval (within 72 hours) will still fail if the approver's step-up token has expired.
- These are independent validity windows: the 72-hour approval TTL applies to the approval record; the step-up token validity window (defined in `step_up_validity_window_policy.md`) applies to the approver's session at the time of the approval action.

An expired step-up token does not set the approval row to `EXPIRED`. The row remains `PENDING` until its own `expires_at` is reached. The approver re-authenticates with step-up and then approves within the remaining 72-hour window.

---

## No auto-escalation

Expired approvals do not auto-escalate to a higher severity level or trigger alerts to a different approver tier. They simply block the gate. The system emits `ENGINE_APPROVAL_EXPIRED` (LOW severity) and waits for an explicit re-request.

There is no automated chaser notification on expiry. Notification behavior is controlled by the alerting configuration in `alert_rule_configuration_schema.md` and may be configured at the business level.

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `ENGINE_APPROVAL_EXPIRED` | LOW | PENDING approval row transitions to EXPIRED during gate evaluation |
| `ENGINE_APPROVAL_REREQUESTED` | LOW | New PENDING approval created for a run with at least one EXPIRED row |

Both events include: `run_id`, `approval_id`, `business_id`, `requested_at`, `expires_at`.

---

## Approval status lifecycle

The full `workflow_run_approvals.status` lifecycle for reference:

| Status | Terminal? | Description |
| --- | --- | --- |
| `PENDING` | No | Awaiting approver action; subject to the 72-hour TTL |
| `APPROVED` | No | Approver granted approval; gate may now pass (if all others also APPROVED) |
| `REJECTED` | Yes | Approver explicitly rejected; run transitions to REVIEW_HOLD for accountant review |
| `EXPIRED` | No | TTL elapsed without action; re-request required |
| `REVOKED` | Yes | Run was aborted or compensated; approval no longer valid |

EXPIRED is not terminal because a re-request creates a new PENDING row for the same run. REVOKED is terminal; a revoked approval cannot be reinstated.

---

## Interaction with run cancellation

If the run is cancelled while a PENDING approval exists, the PENDING approval transitions to `EXPIRED` as part of the abort sequence (see `out_run_abort_policy.md`). This prevents a late approver from acting on a defunct approval request after the run is gone.

The engine checks for PENDING approvals before completing the CANCELLED transition and expires them atomically within the same abort transaction.

---

## Cross-references

- `workflow_run_approvals_schema.md` — `workflow_run_approvals` table DDL and status enum
- `step_up_validity_window_policy.md` — step-up token TTL and validity semantics
- `human_review_approval_staleness_policy.md` — staleness rules for human review (distinct from engine approval TTL)
- `archive_step_up_policy.md` — step-up auth requirement for finalization approval
- `out_run_abort_policy.md` — how approval rows are handled on run cancellation
- `audit_log_policies.md` — audit event naming convention
- `alert_rule_configuration_schema.md` — configurable notification rules
