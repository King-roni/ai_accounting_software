# in_monthly_trigger_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Governing rules for when and how an `IN_MONTHLY` workflow run is created. This document is the parallel to `out_monthly_trigger_policy` for the incoming invoice side. Every code path that creates an `IN_MONTHLY` run must satisfy all rules here before calling `in_workflow.create_run`. Rules are binding; deviations require a `Docs/decisions_log.md` amendment.

---

## 1. Trigger surfaces

Two and only two trigger surfaces exist for `IN_MONTHLY` in MVP:

| Surface | Tool | Trigger kind |
| --- | --- | --- |
| Event-driven (paired with OUT, on statement upload) | `in_workflow.handle_statement_upload_event` | `EVENT` |
| Manual (standalone) | `in_workflow.start_run_manually` | `MANUAL` |

No scheduled (cron) trigger is permitted in MVP.

---

## 2. Event-driven trigger — primary path

### 2.1 Pair trigger sequencing

The primary way an `IN_MONTHLY` run is created is as part of the paired-run creation when a bank statement upload is processed. When `STATEMENT_UPLOAD_COMPLETED` arrives:

1. `out_workflow.handle_statement_upload_event` creates the `OUT_MONTHLY` run row.
2. In the same database transaction, `in_workflow.handle_statement_upload_event` creates the `IN_MONTHLY` run row.
3. Both rows are linked via `workflow_runs.paired_run_id` (self-referential FK, `DEFERRABLE INITIALLY DEFERRED`).
4. `IN_WORKFLOW_RUN_PAIR_LINKED` is emitted to record the pairing.

The pair symmetry invariant (`A.paired_run_id = B AND B.paired_run_id = A`) is enforced by the engine at pair-creation time, not by SQL constraint.

### 2.2 Per-business gate

If `in_workflow_business_config.auto_start_on_statement_upload = false` for the business, the handler emits `IN_WORKFLOW_AUTO_START_SUPPRESSED` and returns without creating an `IN_MONTHLY` run. The `OUT_MONTHLY` run proceeds independently. The user must then trigger the IN run manually.

### 2.3 `triggered_by_event_id`

For `EVENT`-kind runs, `workflow_runs.triggered_by_event_id` is populated with the `id` of the source `STATEMENT_UPLOAD_COMPLETED` event row in `trigger_events_processed`. This FK is null for `MANUAL` runs.

---

## 3. Manual trigger rules

### 3.1 When manual is appropriate

Manual triggering is permitted when:
- `auto_start_on_statement_upload = false` and the user is initiating the run explicitly.
- There is incoming invoice activity requiring processing but no new bank statement upload for the period (standalone IN run).
- The event-driven trigger was suppressed and the user is recovering manually.

A manually triggered `IN_MONTHLY` run does not require a paired `OUT_MONTHLY` run; `paired_run_id` remains null for standalone manual runs.

### 3.2 Permission

Manual triggers require the `WORKFLOW_TRIGGER` permission surface (Block 02 Phase 04):

| Role | Permitted |
| --- | --- |
| Owner | Yes |
| Admin | Yes |
| Bookkeeper | Yes |
| Accountant | No — 403 |
| Reviewer | No — 403 |
| Read-only | No — 403 |

A denied attempt emits `ACCESS_DENIED` and returns a structured 403. No run row is written.

### 3.3 `manual_trigger_note`

`manual_trigger_note` (text) is **mandatory** on all manual trigger calls. Blank strings are rejected. This field is stored on the `workflow_runs` row and included in the `IN_WORKFLOW_RUN_TRIGGERED` audit payload.

### 3.4 Step-up MFA

Step-up MFA is **not required** for triggering. It is required only for approval and cancellation.

### 3.5 Mobile client rejection

Any trigger request arriving from `client_form_factor = MOBILE` is rejected before the permission check. The rejection emits `MOBILE_WRITE_REJECTED` and returns a structured error. See `mobile_write_rejection_endpoints` for the full rejection surface list. Mobile clients may read run state but cannot initiate runs.

---

## 4. Period validation rules

All trigger paths must validate the period before creating a run:

1. **Calendar month boundary.** `period_start` must be the first day of a calendar month; `period_end` must be the last day of the same calendar month. Non-month-aligned periods are rejected.

2. **No future period.** `period_start` must be <= `current_date`.

3. **No re-trigger of a finalized period.** A period for which a `FINALIZED` `IN_MONTHLY` run already exists cannot be re-triggered via this surface. The correct path is `IN_ADJUSTMENT`. Rejection emits `IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`.

4. **Retention window.** The period must be within the statutory retention window. Periods outside it emit `IN_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED`.

---

## 5. Concurrency invariant

At most one active (non-terminal) `IN_MONTHLY` run may exist per `(business_id, period_start)`. The conflict check SQL predicate (equivalent to `out_run_concurrency_policy` Section 2, but scoped to `workflow_type = 'IN_MONTHLY'`) is:

```sql
WHERE business_id = $1
  AND workflow_type = 'IN_MONTHLY'
  AND period_start = $2
  AND status NOT IN ('FINALIZED', 'FAILED', 'CANCELLED')
```

Conflict results in the structured error `IN_WORKFLOW_RUN_ALREADY_ACTIVE`. No run row is written.

Concurrent `IN_MONTHLY` runs across **different** periods for the same business are permitted.

---

## 6. Run row write path

`in_workflow.create_run` is the sole permitted tool for creating `IN_MONTHLY` run rows. It calls `engine.create_run` internally, which:

1. Validates the concurrency invariant (Section 5).
2. Validates the period rules (Section 4).
3. Writes the `workflow_runs` row with `status = CREATED` and `trigger_kind` set appropriately.
4. Emits `IN_WORKFLOW_RUN_TRIGGERED` (LOW severity) via `emitAudit()`.
5. Returns the new `workflow_run_id`.

---

## 7. Audit

| Event | Severity | Trigger |
| --- | --- | --- |
| `IN_WORKFLOW_RUN_TRIGGERED` | LOW | Run row created successfully (both paths) |
| `IN_WORKFLOW_AUTO_START_SUPPRESSED` | LOW | Event handler suppressed due to config flag |
| `IN_WORKFLOW_RUN_PAIR_LINKED` | LOW | Pair linkage established with OUT run |
| `IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED` | LOW | Period already finalized |
| `IN_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED` | LOW | Period outside retention window |
| `ACCESS_DENIED` | MEDIUM | Permission check failed |
| `MOBILE_WRITE_REJECTED` | LOW | Request rejected due to mobile form factor |

---

## Cross-references

- `out_monthly_trigger_policy` — parallel OUT-side trigger rules; pair-trigger sequencing detail
- `out_run_concurrency_policy` — concurrency predicate structure; multi-period rules
- `in_monthly_type_definition` — `IN_MONTHLY` workflow type registration; trigger configuration; `auto_start_on_statement_upload` toggle
- `workflow_run_schema` — `trigger_kind`, `triggered_by_user_id`, `triggered_by_event_id`, `manual_trigger_note`, `paired_run_id` columns
- `workflow_state_enum` — canonical 10-value state set; terminal state definition
- `audit_event_taxonomy` — `IN_WORKFLOW_RUN_TRIGGERED`, `IN_WORKFLOW_AUTO_START_SUPPRESSED`, `IN_WORKFLOW_RUN_PAIR_LINKED`
- `audit_log_policies` — `IN_WORKFLOW` domain; past-tense naming convention
- `mobile_write_rejection_endpoints` — mobile rejection surface list
- Block 13 Phase 07 — IN_MONTHLY type registration; per-business IN config table
- Block 12 Phase 04 — pair-trigger ownership; OUT/IN parallel coordination
- Block 03 Phase 09 — trigger engine; `trigger_events_processed`; event-replay deduplication
- Block 02 Phase 04 — `WORKFLOW_TRIGGER` permission surface; role-to-surface mapping
