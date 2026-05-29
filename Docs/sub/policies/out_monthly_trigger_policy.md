# out_monthly_trigger_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

Governing rules for when and how an `OUT_MONTHLY` workflow run is created. Every code path that creates an `OUT_MONTHLY` run must satisfy all rules in this document before calling `out_workflow.create_run`. Rules are binding; deviations require a `Docs/decisions_log.md` amendment.

---

## 1. Trigger surfaces

Two and only two trigger surfaces exist for `OUT_MONTHLY` in MVP:

| Surface | Tool | Trigger kind |
| --- | --- | --- |
| Manual | `out_workflow.start_run_manually` | `MANUAL` |
| Event-driven (statement upload) | `out_workflow.handle_statement_upload_event` | `EVENT` |

No scheduled (cron) trigger is permitted in MVP per the Stage 1 decisions log ("Run triggers: Manual + event-based; no scheduled triggers in MVP").

---

## 2. Manual trigger rules

### 2.1 Permission

Manual triggers require the `WORKFLOW_TRIGGER` permission surface. The role-to-surface mapping is canonical in the `permission_matrix` (Block 02 Phase 04):

| Role | Permitted |
| --- | --- |
| Owner | Yes |
| Admin | Yes |
| Bookkeeper | Yes |
| Accountant | No — 403 |
| Reviewer | No — 403 |
| Read-only | No — 403 |

A denied manual trigger attempt emits `ACCESS_DENIED` and returns a structured 403 error. No run row is written.

### 2.2 `manual_trigger_note`

`manual_trigger_note` (text) is **mandatory** on all manual trigger calls. Blank strings are rejected. This field is stored on the `workflow_runs` row and included in the `OUT_WORKFLOW_RUN_TRIGGERED` audit payload. It is the operator's record of why the run was started manually rather than through the automatic event path.

### 2.3 Step-up MFA

Step-up MFA is **not required** for triggering. It is required only for approval (`WORKFLOW_APPROVE` surface) and cancellation. This is a Stage 1 binding decision.

### 2.4 Mobile client rejection

Any manual trigger request arriving from `client_form_factor = MOBILE` is rejected before the permission check. The rejection emits `MOBILE_WRITE_REJECTED` and returns a structured error. See `mobile_write_rejection_endpoints` for the full rejection surface list. Mobile clients may read run state but cannot initiate runs.

---

## 3. Event-driven trigger rules

### 3.1 Triggering event

The event trigger fires when a `STATEMENT_UPLOAD_COMPLETED` event is received from Block 07 Phase 09. The event carries `business_id`, `statement_upload_id`, `period_start`, and `period_end`.

### 3.2 `triggered_by_event_id`

For `EVENT`-kind runs, the `workflow_runs.triggered_by_event_id` column must be populated with the `id` of the source event row in `trigger_events_processed`. This column is null for `MANUAL` runs. The FK ensures every event-driven run is traceable to its originating upload event.

### 3.3 Per-business gate

If `out_workflow_configs.auto_trigger_on_statement_upload = false` for the business, the event handler emits `OUT_WORKFLOW_AUTO_START_SUPPRESSED` and returns without creating a run. The user must then trigger manually.

### 3.4 Event-replay deduplication

Block 03 Phase 09's `trigger_events_processed` table deduplicates events by `event_id`. If the same `STATEMENT_UPLOAD_COMPLETED` event arrives twice (network retry), the second arrival is a no-op — no second run is created.

### 3.5 Pair trigger

When the event fires, the handler atomically creates both the `OUT_MONTHLY` run and the `IN_MONTHLY` run in the same database transaction. The two runs are linked via `workflow_runs.paired_run_id`. If `IN_MONTHLY`'s auto-start is suppressed for the business, the OUT run still proceeds independently.

---

## 4. Period validation rules

All trigger paths must validate the period before creating a run:

1. **Calendar month boundary.** `period_start` must be the first day of a calendar month and `period_end` must be the last day of the same calendar month. Non-month-aligned periods are rejected with a structured error.

2. **No future period.** `period_start` must be <= `current_date`. Triggering for a future period is rejected.

3. **No overlap with a finalized period.** A period for which a `FINALIZED` `OUT_MONTHLY` run already exists cannot be re-triggered via this surface. The correct path for modifications to a finalized period is `OUT_ADJUSTMENT` (Block 12 Phase 09). Rejection audit event: `IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED` (IN-side equivalent: per-domain naming applies).

4. **Within retention window.** The period must not be older than `out_workflow_configs.out_adjustment_max_lookback_years` years from today. Periods outside the retention window are permanently unavailable for monthly processing.

---

## 5. Concurrency invariant

At most one active (non-terminal) `OUT_MONTHLY` run may exist per `(business_id, period_start)`. An active run is one whose `status` is not in `{FINALIZED, FAILED, CANCELLED}`. This invariant is checked by `engine.create_run` before writing the run row. Conflict results in a structured `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` error — no silent failure, no second run row.

The full SQL predicate used for the conflict check is documented in `out_run_concurrency_policy`. This policy commits to the invariant; the predicate detail belongs to the concurrency policy.

Concurrent `OUT_MONTHLY` runs across **different** periods for the same business are permitted (e.g., running January and February simultaneously is allowed).

---

## 6. Run row write path

`out_workflow.create_run` is the sole permitted tool for creating `OUT_MONTHLY` run rows. Direct `INSERT` into `workflow_runs` is forbidden. `out_workflow.create_run` calls `engine.create_run` internally, which:

1. Validates the concurrency invariant (Section 5).
2. Validates the period rules (Section 4).
3. Writes the `workflow_runs` row with `status = CREATED` and `trigger_kind` set appropriately.
4. Emits `OUT_WORKFLOW_RUN_TRIGGERED` (LOW severity) via `emitAudit()`.
5. Returns the new `workflow_run_id`.

---

## 7. Audit

| Event | Severity | Trigger |
| --- | --- | --- |
| `OUT_WORKFLOW_RUN_TRIGGERED` | LOW | Run row created successfully (both manual and event paths) |
| `OUT_WORKFLOW_AUTO_START_SUPPRESSED` | LOW | Event handler suppressed due to `auto_trigger_on_statement_upload = false` |
| `ACCESS_DENIED` | MEDIUM | Permission check failed on manual trigger |
| `MOBILE_WRITE_REJECTED` | LOW | Request rejected due to mobile form factor |

`OUT_WORKFLOW_RUN_TRIGGERED` payload includes: `workflow_run_id`, `business_id`, `period_start`, `period_end`, `trigger_kind`, `triggered_by_user_id` (MANUAL only), `triggered_by_event_id` (EVENT only), `manual_trigger_note` (MANUAL only).

---

## 8. Non-trigger write surfaces

The following actions on a run are governed by separate policies and tools, not this policy:

- **Cancellation** — requires step-up MFA; Owner/Admin only. See `workflow_state_enum`.
- **Approval** — `WORKFLOW_APPROVE` surface; step-up MFA required. See `workflow_state_enum`.
- **Pause / resume** — `WORKFLOW_TRIGGER` surface; no step-up MFA required for pause; step-up MFA for force-resume from `AWAITING_APPROVAL`.

---

## Cross-references

- `out_run_concurrency_policy` — SQL concurrency predicate; multi-period concurrency rules
- `workflow_run_schema` — `trigger_kind`, `triggered_by_user_id`, `triggered_by_event_id`, `manual_trigger_note` columns
- `workflow_state_enum` — canonical 10-value state set; terminal state definition
- `out_config_schema` — `auto_trigger_on_statement_upload` toggle; `out_adjustment_max_lookback_years`
- `in_monthly_trigger_policy` — parallel IN-side trigger rules; pair-trigger sequencing
- `audit_event_taxonomy` — `OUT_WORKFLOW_RUN_TRIGGERED`, `OUT_WORKFLOW_AUTO_START_SUPPRESSED`
- `audit_log_policies` — `OUT_WORKFLOW` domain; past-tense naming convention
- `mobile_write_rejection_endpoints` — mobile rejection surface list
- Block 12 Phase 08 — source phase doc for trigger implementation detail
- Block 03 Phase 09 — trigger engine; `trigger_events_processed`; event-replay deduplication
- Block 02 Phase 04 — `WORKFLOW_TRIGGER` permission surface; role-to-surface mapping
- `decisions_log.md` — Stage 1 binding: manual + event triggers only; no scheduled triggers in MVP
