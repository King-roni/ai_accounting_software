# workflow_pause_resume_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2 policy)

Defines the PAUSED run status: when it is set, what it means operationally, how a paused run resumes, and the automatic pause conditions the engine may apply.

---

## PAUSED vs. adjacent statuses

PAUSED is a distinct status from the other non-running statuses:

| Status | Cause | Who clears it |
| --- | --- | --- |
| `PAUSED` | Explicit operator suspension or engine auto-pause | ACCOUNTANT, OWNER, or ADMIN via resume action |
| `REVIEW_HOLD` | Gate failure due to blocking review issues | Resolution of all blocking issues + re-gate via `engine.advance_phase` |
| `AWAITING_APPROVAL` | Gate failure due to pending approval requirement | Approval granted + gate re-evaluated |

A run in REVIEW_HOLD or AWAITING_APPROVAL is not paused; it is held at a phase boundary by the gate logic. PAUSED is an operator-level suspension that can occur mid-phase, before any gate has been evaluated.

---

## Who can pause

Users with role ACCOUNTANT, OWNER, or ADMIN may pause a running workflow. REVIEWER and read-only roles cannot initiate a pause. The permission surface is `WORKFLOW_PAUSE`.

---

## Pause conditions

A run may be paused only when `run_status = RUNNING`. Attempts to pause a run in any other status return `PAUSE_FORBIDDEN`:

| Status | Pausable? |
| --- | --- |
| `CREATED` | No — not yet running |
| `RUNNING` | Yes |
| `PAUSED` | No — already paused |
| `REVIEW_HOLD` | No — use the review queue to resolve the hold |
| `AWAITING_APPROVAL` | No — approve or cancel the approval request |
| `FINALIZING` | No — in-progress finalization cannot be suspended |
| `FINALIZED` | No — terminal |
| `FAILED` | No — terminal |
| `CANCELLED` | No — terminal |
| `COMPENSATING` | No — compensation in progress; cannot be interrupted |

---

## What pause does

On a successful pause:

1. `run_status` transitions from `RUNNING` to `PAUSED`.
2. `paused_at` is set to `now()`.
3. `paused_by_user_id` is set to the actor's user ID (null for auto-pause; see below).
4. `paused_reason` is set to a caller-supplied note (free text, max 500 chars) or a system code for auto-pause.

The current phase is not rolled back. The run will resume from the last committed phase checkpoint — specifically, the phase index and all phase entry actions that already executed remain intact. In-flight tool invocations that were running at the moment of pause are allowed to complete their current atomic unit; the pause takes effect before the next tool call.

---

## Resume

Any user with role ACCOUNTANT, OWNER, or ADMIN may resume a PAUSED run. The permission surface is `WORKFLOW_RESUME`.

On resume:

1. `run_status` transitions from `PAUSED` to `RUNNING`.
2. `paused_at`, `paused_by_user_id`, and `paused_reason` are retained on the row for audit. They are not cleared.
3. The engine re-evaluates the gate for the current phase before executing the next tool call. If the gate now fails (conditions changed while paused), the run transitions to `REVIEW_HOLD` or `AWAITING_APPROVAL` rather than continuing.

The resume action does not require a new idempotency key. Phase idempotency keys from before the pause remain valid.

---

## Automatic pause

The engine may auto-pause a run when a non-fatal external dependency is unavailable and the failure does not warrant a `FAILED` transition. Examples:

- ECB exchange rate endpoint unavailable and the current phase requires a rate lookup.
- VIES endpoint down and the current phase is preparing EU VAT entries.

For auto-pause, `paused_by_user_id` is set to null and `paused_reason` is set to a system code (e.g., `ECB_RATE_UNAVAILABLE`, `VIES_ENDPOINT_DOWN`). An alert is raised per the `alert_rule_configuration_schema.md` configuration. The run will not self-resume; an operator must resume it after the dependency recovers.

Auto-pause is distinct from a retry. The engine retries transient failures per Block 03 Phase 08's retry policy before escalating to auto-pause. Auto-pause is used only when the retry budget is exhausted or the outage is expected to last beyond the retry window.

---

## Stale pause alert

There is no hard TTL on a paused run. However, if a run remains in `PAUSED` status for more than 7 consecutive days:

- The audit event `ENGINE_RUN_STALE_PAUSED` (LOW) is emitted once per calendar day until the run is resumed or cancelled.
- The event payload includes `run_id`, `business_id`, `paused_at`, `days_paused`, and `paused_reason`.

The stale alert is informational. It does not escalate the run's severity or trigger auto-cancellation.

---

## Cancellation from pause

A paused run may be cancelled by an OWNER or ADMIN. Cancellation from PAUSED follows:

- OUT workflow runs: `out_run_abort_policy.md`
- IN workflow runs: `in_run_abort_policy.md`

The cancellation path does not require a resume step; the run transitions from `PAUSED` directly to `COMPENSATING` (if ledger entries were posted) or `CANCELLED`.

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `ENGINE_RUN_PAUSED` | LOW | Run transitions to PAUSED (manual or auto) |
| `ENGINE_RUN_RESUMED` | MEDIUM | Run transitions from PAUSED to RUNNING (MEDIUM because resume re-activates a suspended financial pipeline) |
| `ENGINE_RUN_STALE_PAUSED` | LOW | Run has been PAUSED for more than 7 days; emitted daily |

---

## Multiple pause cycles

A run may be paused and resumed multiple times within a single run lifecycle. Each pause/resume cycle writes a new set of audit events. The `workflow_runs` columns `paused_at`, `paused_by_user_id`, and `paused_reason` are overwritten on each subsequent pause; they reflect the most recent pause only.

The full pause/resume history is recoverable from the audit log by querying `ENGINE_RUN_PAUSED` and `ENGINE_RUN_RESUMED` events for the `run_id`. The audit log is the authoritative source for the complete pause cycle count and timing.

---

## Interaction with phase idempotency

Phase idempotency keys recorded before a pause remain valid after resume. When the engine re-evaluates the current phase gate on resume, it does not re-issue idempotency keys or reset the phase record. The gate evaluation is a read-only check against existing state; it does not create a new phase entry.

If a new `engine.advance_phase` call is needed after resume (because the gate now requires a different action), the caller supplies a new `caller_idempotency_key` for that call. See `resumability_and_idempotency.md` for the full checkpoint model.

---

## Cross-references

- `workflow_run_schema.md` — `workflow_runs` columns `paused_at`, `paused_by_user_id`, `paused_reason`, `run_status_enum`
- `resumability_and_idempotency.md` — phase checkpoint semantics on resume and idempotency key lifecycle
- `out_run_abort_policy.md` — cancellation path for OUT workflow runs from PAUSED status
- `in_run_abort_policy.md` — cancellation path for IN workflow runs from PAUSED status
- `audit_log_policies.md` — audit event naming convention
- `alert_rule_configuration_schema.md` — configurable alert rules for auto-pause and stale-pause events
