# in_run_abort_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2 policy)

Defines the conditions under which an IN workflow run is aborted, who may abort it, the effects on downstream records, and the compensation path when ledger state must be reversed.

---

## Scope

This policy applies to workflow runs with `workflow_type` in `{IN_MONTHLY, IN_ADJUSTMENT}`. Abort for OUT workflow runs is governed by `out_run_abort_policy.md`.

---

## Abort definition

Abort sets `run_status = CANCELLED` and halts all further phase execution for the run. Abort is irreversible. A CANCELLED run cannot be resumed, re-gated, or advanced.

If the run had already posted ledger entries at the time of abort, the engine transitions to `COMPENSATING` before `CANCELLED`. The run reaches `CANCELLED` only after all compensation actions complete successfully.

---

## Who can abort

OWNER or ADMIN role only. ACCOUNTANT cannot abort an IN workflow run.

The permission surface is `WORKFLOW_ABORT`. REVIEWER and read-only roles do not have this surface.

---

## Manual abort conditions

An OWNER or ADMIN may manually abort an IN run when `run_status` is in `{CREATED, RUNNING, PAUSED, REVIEW_HOLD}`.

Manual abort is not permitted when `run_status` is in `{AWAITING_APPROVAL, FINALIZING, FINALIZED, COMPENSATING}`:

- `AWAITING_APPROVAL`: the approval must be resolved or expired before abort is available.
- `FINALIZING`: finalization is in progress; the run cannot be interrupted.
- `FINALIZED`: terminal; the period is closed.
- `COMPENSATING`: compensation is already in progress; no further state transitions are accepted until compensation completes.

---

## Automatic abort conditions

The engine auto-aborts an IN run when any of the following occur:

1. Bank statement parsing fails with a BLOCKING-severity error during the INGESTION phase. A BLOCKING error indicates the statement file is structurally invalid and cannot be recovered by retry. The run_status transitions to `FAILED` first (per the retry policy); if the BLOCKING failure persists after exhausting retries, the engine aborts.

2. The deduplication phase determines that the run's period is already covered by a FINALIZED run. A FINALIZED run for the same `(business_id, workflow_type, period_year, period_month)` is a hard block; the engine cannot create two FINALIZED runs for the same period.

3. The engine's compensation trigger fires (per `compensation_trigger_schema.md`) and the compensation mechanism itself fails to complete within the allowed window. In this case the run remains in `COMPENSATING` and a HIGH alert is raised; the run is not transitioned to `CANCELLED` automatically — an operator must intervene.

---

## Effects of abort

When a run is aborted, the following state changes occur in order:

1. If ledger entries have been posted, `run_status` transitions to `COMPENSATING` (see Compensation section below). Otherwise, skip to step 2.
2. `run_status` transitions to `CANCELLED`.
3. All DRAFT invoices created within this run (`invoices.intake_run_id = run_id AND invoices.status = DRAFT`) are set to `VOID`.
4. In-flight AI classification jobs for this run (`ai_classification_jobs.run_id = run_id AND status IN ('QUEUED','RUNNING')`) are cancelled.
5. Any PENDING match proposals sourced from this run (`match_proposals.source_run_id = run_id AND status = PENDING`) are set to `REJECTED` with `rejection_reason = 'SOURCE_RUN_CANCELLED'`.

---

## Bank statement row retention

Aborting an IN run does not delete `bank_statement_rows` that were already ingested during the run. These rows are retained for audit with:

- `intake_run_id` pointing to the CANCELLED `workflow_runs` row
- `ingestion_status = 'ORPHANED'` (set during abort)

Retained rows are visible in the audit trail and may be referenced in investigations. They are excluded from all active processing queries via their `ingestion_status`.

---

## Compensation

If ledger entries were posted before abort, compensation proceeds as follows:

1. `run_status` transitions from `RUNNING` (or `PAUSED`/`REVIEW_HOLD`) to `COMPENSATING`.
2. The engine executes compensation actions in reverse phase order per `compensation_trigger_schema.md`.
3. Each reversed ledger entry is written as a compensating double-entry with `compensation_for_entry_id` pointing to the original.
4. When all compensation actions complete, `run_status` transitions from `COMPENSATING` to `CANCELLED`.

Compensation is idempotent; if the COMPENSATING state is interrupted, re-running compensation skips already-reversed entries.

If compensation itself fails, `run_status` remains `COMPENSATING` and a HIGH alert fires. An operator must resolve the compensation failure manually before the run can be marked CANCELLED.

---

## Re-run after abort

After a run reaches `CANCELLED`, a new IN run for the same period may be created. The deduplication check passes because only FINALIZED runs block re-creation; CANCELLED runs do not.

The new run starts fresh from CREATED status. Prior `bank_statement_rows` with `ingestion_status = 'ORPHANED'` are not automatically re-processed; the operator must decide whether to re-upload the statement or reference the existing rows.

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `IN_WORKFLOW_RUN_ABORTED` | MEDIUM | Run transitions to CANCELLED (with or without compensation) |
| `IN_WORKFLOW_COMPENSATION_STARTED` | HIGH | Run transitions to COMPENSATING before CANCELLED |

Both events include: `run_id`, `business_id`, `aborted_by_user_id` (null for system-initiated abort), `abort_reason`.

---

## Invoice VOID behavior on abort

Invoices set to `VOID` during abort follow the invoice lifecycle policy from `invoice_lifecycle_policy.md`. A VOID invoice:

- Is excluded from all active revenue recognition calculations.
- Is not deleted; the row is retained with `status = VOID` and `voided_at = now()` for audit and for reference by the client's invoice history.
- Cannot be reactivated. If the same invoice must be re-issued in a subsequent run, it is issued as a new invoice row with a new `id`.

The VOID transition for invoices is atomic with the `run_status → CANCELLED` transition. If the run had many DRAFT invoices, all are voided in a single batch UPDATE within the abort transaction.

---

## Interaction with the OUT run

An IN run and its paired OUT run share a `period_year` / `period_month` but are independent `workflow_runs` rows linked via `paired_run_id`. Aborting an IN run does not auto-abort the paired OUT run. The OUT run continues independently.

However, if the OUT run is in a phase that depends on IN-generated data (e.g., a reconciliation phase reading matched invoice totals), the phase gate may return `REVIEW_HOLD` or fail after the IN run's match proposals are rejected during abort. The accountant must resolve those issues in the OUT run's review queue.

---

## Cross-references

- `in_run_config_schema.md` — IN workflow run configuration
- `compensation_trigger_schema.md` — compensation trigger definitions and idempotency
- `workflow_pause_resume_policy.md` — pause/resume lifecycle (PAUSED runs may be aborted from PAUSED)
- `deduplication_policy.md` — dedup check that can trigger auto-abort
- `invoice_lifecycle_policy.md` — VOID transition behavior for DRAFT invoices
- `workflow_run_schema.md` — `run_status_enum`, `paired_run_id`, and state-machine constraints
- `audit_log_policies.md` — audit event naming convention
