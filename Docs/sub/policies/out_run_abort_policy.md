# out_run_abort_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2 policy)

Defines the conditions under which an OUT workflow run is aborted, who may abort it, the effects on downstream records, and the compensation path when ledger state must be reversed.

---

## Scope

This policy applies to workflow runs with `workflow_type` in `{OUT_MONTHLY, OUT_ADJUSTMENT}`. Abort for IN workflow runs is governed by `in_run_abort_policy.md`.

---

## Abort definition

Abort sets `run_status = CANCELLED` and halts all further phase execution. Abort is irreversible. A CANCELLED run cannot be resumed, re-gated, or advanced.

If the run had already posted ledger entries at the time of abort, the engine transitions to `COMPENSATING` before `CANCELLED`. The run reaches `CANCELLED` only after all compensation actions complete.

---

## Who can abort

OWNER or ADMIN role only. ACCOUNTANT cannot abort an OUT workflow run.

The permission surface is `WORKFLOW_ABORT`. REVIEWER and read-only roles do not have this surface.

---

## Manual abort conditions

An OWNER or ADMIN may manually abort an OUT run when `run_status` is in `{CREATED, RUNNING, PAUSED, REVIEW_HOLD, AWAITING_APPROVAL}`.

Manual abort is not permitted when `run_status` is in `{FINALIZING, FINALIZED, COMPENSATING}`:

- `FINALIZING`: finalization sequence is in progress; it cannot be interrupted.
- `FINALIZED`: terminal; the period is closed.
- `COMPENSATING`: compensation already in progress; no further transitions accepted until compensation completes.

---

## Automatic abort conditions

The engine auto-aborts an OUT run when any of the following occur:

1. A phase gate fails with a BLOCKING-severity issue that cannot be cleared. BLOCKING issues represent conditions where the run cannot safely proceed and no resolution path exists within the current run cycle. The engine transitions the run from `REVIEW_HOLD` to `CANCELLED` (via COMPENSATING if applicable) after the BLOCKING classification is confirmed.

2. The manual hold TTL expires without resolution. Per `out_manual_hold_policy.md`, manual holds carry a maximum 30-day open window. If the hold remains unresolved after 30 days, the engine auto-aborts the run.

3. The compensation trigger fires and compensation cannot complete. In this case `run_status` remains `COMPENSATING` and a HIGH alert is raised; the run is not auto-transitioned to `CANCELLED` — an operator must intervene.

---

## Effects of abort

When an OUT run is aborted, the following state changes occur in order:

1. If ledger entries have been posted, `run_status` transitions to `COMPENSATING` (see Compensation section below). Otherwise, skip to step 2.
2. `run_status` transitions to `CANCELLED`.
3. All PENDING `workflow_run_approvals` rows for this run (`run_id = this run, status = PENDING`) are set to `EXPIRED`. This prevents a late approver from acting on a defunct approval request.
4. All outstanding manual hold records for this run are closed with `resolution = ABORTED`.
5. Review issues that are still OPEN for this run are carried forward to the next run per `snooze_carry_forward_policy.md`. Carry-forward happens even on abort, because the issues may remain valid for the next period's OUT run.

---

## Exception document retention

If the run had documented exceptions (`out_exception_documented_policy.md`), the `out_exception_documented` records are retained after abort. They are not voided or deleted. Retention serves the audit trail: the fact that an exception was documented during an aborted run is itself material for the next run's review.

The retained records are marked with `source_run_id` pointing to the CANCELLED run. They are excluded from active processing views but visible in the audit trail.

---

## Review issue carry-forward on abort

Open review issues from an aborted OUT run are carried forward to the next OUT run for the same period and business. This is the same carry-forward mechanism that operates at normal period close. The `carry_forward_log` records the transfer with `source_run_id = aborted run id`. The carry-forward process is triggered by `review_queue.carry_forward_issues` as part of the abort sequence.

---

## Compensation

If ledger entries were posted before abort, compensation proceeds as follows:

1. `run_status` transitions to `COMPENSATING`.
2. The engine executes compensation actions in reverse phase order per `out_phase_compensation_policy.md`.
3. When all compensation actions complete, `run_status` transitions from `COMPENSATING` to `CANCELLED`.

If compensation fails, `run_status` remains `COMPENSATING` and a HIGH alert fires. An operator must resolve the failure before the run can be marked CANCELLED.

---

## Re-run after abort

After a run reaches `CANCELLED`, a new OUT run for the same period may be created. Carried-forward review issues from the aborted run will be visible in the new run's review queue from the start.

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `OUT_WORKFLOW_RUN_ABORTED` | MEDIUM | Run transitions to CANCELLED |
| `OUT_WORKFLOW_COMPENSATION_STARTED` | HIGH | Run transitions to COMPENSATING before CANCELLED |

Both events include: `run_id`, `business_id`, `aborted_by_user_id` (null for system-initiated abort), `abort_reason`.

---

## Interaction with the paired IN run

An OUT run and its paired IN run share the same `period_year` / `period_month` and are linked via `paired_run_id` on `workflow_runs`. Aborting an OUT run does not auto-abort the paired IN run. The IN run continues independently and may reach FINALIZED even if the OUT run was aborted.

A new OUT run for the same period may be created after the prior one is CANCELLED, and it can be paired with the already-active (or already-FINALIZED) IN run. The `paired_run_id` on the new OUT run points to the IN run; the prior CANCELLED OUT run's `paired_run_id` is not cleared.

---

## Abort sequencing within the engine

When an OWNER or ADMIN calls the abort endpoint for an OUT run, the engine executes the following sequence atomically:

1. Lock the `workflow_runs` row (`SELECT ... FOR UPDATE`) to prevent concurrent phase advance or resume.
2. Validate the current `run_status` is in the permitted set for abort.
3. If ledger entries exist, transition `run_status` to `COMPENSATING` and dispatch the compensation job.
4. Otherwise, transition `run_status` directly to `CANCELLED`.
5. Expire PENDING approvals, close manual holds, and trigger carry-forward for open review issues.
6. Emit `OUT_WORKFLOW_RUN_ABORTED` and, if compensation was triggered, `OUT_WORKFLOW_COMPENSATION_STARTED`.

Steps 1–6 run in a single database transaction. If the transaction fails, the run remains in its prior status and the abort is rejected with `ABORT_TRANSACTION_FAILED`. The caller may retry.

---

## Interaction with the AWAITING_APPROVAL abort restriction

Manual abort is permitted from `AWAITING_APPROVAL` for OUT runs (unlike IN runs, where AWAITING_APPROVAL is not listed as an abortable state). This is intentional: OUT runs may reach AWAITING_APPROVAL for finalization-level approval, and an OWNER who decides to restart the period close should be able to abort without waiting for the approval window to expire. The PENDING approval rows are expired atomically with the abort transition per `out_run_abort_policy.md` abort effects.

---

## Cross-references

- `out_run_config_schema.md` — OUT workflow run configuration
- `out_manual_hold_policy.md` — manual hold TTL and resolution rules
- `snooze_carry_forward_policy.md` — carry-forward of open review issues on abort
- `compensation_trigger_schema.md` — compensation trigger conditions
- `out_phase_compensation_policy.md` — compensation action sequence for OUT runs
- `workflow_pause_resume_policy.md` — pause/resume lifecycle (PAUSED runs may be aborted)
- `workflow_run_schema.md` — `run_status_enum`, `paired_run_id`, and state-machine constraints
- `approval_expiry_policy.md` — PENDING approval handling during abort
- `audit_log_policies.md` — audit event naming convention
