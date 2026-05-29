# Workflow Run Creation Policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine / 12 — OUT Workflow / 13 — IN Workflow · **Stage:** 4 sub-doc (Layer 2)

**Purpose.** Define the constraints that govern when a new workflow run may be created, what authorisation is required for non-standard triggers, how duplicate periods are prevented, and what re-run semantics apply. This policy is binding for all workflow types that use the shared `workflow_runs` table. Blocks 12 and 13 each have an additional type-specific config row (`out_run_configs`, `in_run_configs`) that extends the base run row; those schemas defer period-uniqueness enforcement to the base-layer constraint defined here.

---

## Duplicate period prevention

Only one **active** run per `(business_id, workflow_type, period_year, period_month)` is permitted. A run is active when its `status` is not in `{FINALIZED, FAILED, CANCELLED}`.

Enforcement is by a partial unique index on `workflow_runs`:

```sql
CREATE UNIQUE INDEX idx_workflow_runs_active_period_uniq
    ON workflow_runs (business_id, workflow_type, period_year, period_month)
    WHERE status NOT IN ('FINALIZED', 'FAILED', 'CANCELLED');
```

When a duplicate is detected (unique index violation or pre-flight check), the engine rejects the creation request with error code `WORKFLOW_RUN_DUPLICATE_PERIOD` and emits audit event `ENGINE_RUN_CREATION_REJECTED_DUPLICATE`.

The pre-flight check runs inside a serializable transaction before the insert. The unique index provides the final enforcement guarantee in case of concurrent creation attempts.

**What counts as an active run for the purpose of this constraint:**

| Status | Counted as active? |
|---|---|
| `CREATED` | Yes |
| `RUNNING` | Yes |
| `PAUSED` | Yes |
| `REVIEW_HOLD` | Yes |
| `AWAITING_APPROVAL` | Yes |
| `FINALIZING` | Yes |
| `COMPENSATING` | Yes |
| `FINALIZED` | No |
| `FAILED` | No |
| `CANCELLED` | No |

---

## Backdated run rules

**Definition:** a run is backdated when `(period_year, period_month)` is more than 13 calendar months before the current month at creation time. Example: if today is 2026-05-16, runs for periods earlier than 2025-04 are backdated.

**Rule:** creating a backdated run requires OWNER-level authorisation. The engine checks `auth.can_perform(user_id, business_id, 'WORKFLOW', 'CREATE_BACKDATED_RUN')`. If the check fails, the run is rejected with `ENGINE_RUN_CREATION_REJECTED_BACKDATED` and audit event `ENGINE_RUN_CREATION_REJECTED_BACKDATED` is emitted.

OWNER authorisation alone is sufficient; no additional step-up MFA is required for backdated run creation. A step-up is required only at the finalization gate per `workflow_run_approvals_schema`.

**Future periods:** creating a run for a period that has not yet started (i.e., `period_year > current_year` or `period_year = current_year AND period_month > current_month`) is prohibited for all roles. Attempting to create a future-period run returns `WORKFLOW_RUN_FUTURE_PERIOD_REJECTED`. No audit event is emitted for rejected future-period attempts (they are treated as a validation error, not a security event).

---

## Trigger sources

Three trigger sources are recognised. Each has a minimum role requirement and a distinct `trigger_kind` value on the `workflow_runs` row.

### 1. Monthly scheduler

- `trigger_kind = 'SCHEDULER'`
- Initiated by the platform's monthly cron at the configured `auto_start_day` for each business
- No user session required; `triggered_by_user_id = null`
- No role check applied (scheduler has system-level authority)
- If `auto_start_suppressed = true` on `business_workflow_configs`, the scheduler does not create the run and emits `OUT_WORKFLOW_AUTO_START_SUPPRESSED` (OUT) or `IN_WORKFLOW_AUTO_START_SUPPRESSED` (IN)

### 2. Operator manual trigger

- `trigger_kind = 'MANUAL'`
- Requires ACCOUNTANT role minimum
- `triggered_by_user_id` is set to the acting user's ID
- Session must be active and not expired
- Manual trigger does not override duplicate-period prevention; the constraint applies regardless of `trigger_kind`

### 3. Re-run after FAILED status

- `trigger_kind = 'RERUN'`
- Requires OWNER role
- Creates a new `workflow_run_id`; does NOT resume the failed run
- The failed run's `status` remains `FAILED` and its data is preserved in the Processing zone until the 7-day TTL post-run expires
- The new run starts from Phase 1 regardless of which phase the previous run failed in
- `triggered_by_user_id` is required and must match an OWNER-role session

---

## Re-run semantics

A re-run is a full restart. It is not a resume. The distinction matters for:

**Data:** the failed run's Processing-zone scratch data (classification outputs, intermediate ledger entries, etc.) has a 7-day TTL from the failed run's `ended_at`. The new run creates its own Processing-zone rows independently; it does not inherit the failed run's Processing-zone state.

**Audit trail:** the failed run's audit events remain in the chain. The new run emits `ENGINE_RUN_CREATED` with `trigger_kind = 'RERUN'` and `prior_run_id` referencing the failed run.

**Sequence numbers:** no invoice or report sequence numbers are pre-allocated for a run until the relevant phase executes. A re-run allocates fresh sequence numbers as it reaches those phases.

**Compensation:** if the failed run triggered a compensation sequence (status `COMPENSATING`), the compensation must reach `FAILED` or `AWAITING_APPROVAL` before a re-run is permitted. A re-run attempt against a run in `COMPENSATING` status is rejected with `WORKFLOW_RUN_RERUN_BLOCKED_COMPENSATING`.

---

## Concurrency limit

A business may not have more than **2 active runs simultaneously**. The intended maximum is one `OUT_MONTHLY` and one `IN_MONTHLY` run active at the same time.

If a third active run creation is attempted (for any workflow type), the engine rejects it with `WORKFLOW_RUN_CONCURRENCY_LIMIT_EXCEEDED` before the insert. This is enforced by a pre-flight count query inside the serializable creation transaction.

Adjustment runs (`OUT_ADJUSTMENT`, `IN_ADJUSTMENT`) count toward the 2-run limit during their active lifecycle.

---

## Audit events

| Event | Severity | Emitted when |
|---|---|---|
| `ENGINE_RUN_CREATED` | LOW | A new `workflow_runs` row is successfully inserted |
| `ENGINE_RUN_CREATION_REJECTED_DUPLICATE` | MEDIUM | A duplicate-period constraint violation is detected |
| `ENGINE_RUN_CREATION_REJECTED_BACKDATED` | MEDIUM | A backdated run is attempted without OWNER authorisation |

`ENGINE_RUN_CREATION_REJECTED_DUPLICATE` is MEDIUM because a duplicate attempt may indicate a scheduling misconfiguration or a concurrent operator action that requires investigation.

`ENGINE_RUN_CREATION_REJECTED_BACKDATED` is MEDIUM because an unauthorised backdated run creation is an access boundary event.

**`ENGINE_RUN_CREATED` payload:**

```json
{
  "workflow_run_id": "<uuid>",
  "business_id": "<uuid>",
  "workflow_type": "OUT_MONTHLY",
  "period_year": 2026,
  "period_month": 5,
  "trigger_kind": "SCHEDULER",
  "triggered_by_user_id": null,
  "prior_run_id": null
}
```

`prior_run_id` is populated only for `trigger_kind = 'RERUN'`.

---

## Cross-references

- `out_run_config_schema.md` — OUT_MONTHLY-specific config row that extends the base run row
- `in_run_config_schema.md` — IN_MONTHLY-specific config row that extends the base run row
- `workflow_run_schema.md` — base `workflow_runs` table DDL, `run_status_enum`, partial unique index
- `workflow_type_registry_schema.md` — registered workflow types; `OUT_MONTHLY` and `IN_MONTHLY` registration
