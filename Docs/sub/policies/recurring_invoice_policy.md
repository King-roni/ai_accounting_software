# recurring_invoice_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Rules governing recurring invoice generation. Recurring invoice schedules allow businesses to automatically produce invoices on a repeating cadence (monthly, quarterly, or annually). This policy is the normative source for schedule governance, generation sequencing, and the sequence number timing rule. The `recurring_invoice_run_schema` defines the table structures; this policy defines the behavioral rules that bind code and gate logic.

---

## 1. Schedule storage and structure

Recurring invoice schedules are stored in `recurring_invoice_templates` (see `recurring_invoice_run_schema`). One template row per client per cadence configuration. The deduplication ledger for scheduler runs is `recurring_invoice_runs`.

Each template specifies:
- `recurrence_cadence` — `MONTHLY`, `QUARTERLY`, or `ANNUALLY` (closed MVP enum).
- `next_due_date` — the calendar date the scheduler will next generate an invoice.
- `auto_send` — whether the generated invoice is automatically promoted from `DRAFT` to `SENT`.
- `status` — `ACTIVE`, `PAUSED`, or `ENDED`.

---

## 2. Generation output

Each generation cycle produces one `DRAFT` pro-forma invoice for the configured client. The generated invoice:
- Has `invoice_type = PRO_FORMA`.
- Carries the template's `lines_payload`, `currency`, and `vat_treatment`.
- Has `pro_forma_expires_at` set to `issue_date + 30 days` (or the per-template override if configured).

---

## 3. Auto-send promotion

If `auto_send = true` on the template, `in_workflow.generate_recurring_invoice` calls `in_workflow.send_invoice` immediately after creating the `DRAFT` row. This allocates a `PRO-YYYY-NNNN` sequence number and transitions the invoice to `SENT`. If `auto_send = false`, the invoice remains in `DRAFT` pending Owner/Admin review.

Note: the invoice lifecycle status is `SENT` (not `ISSUED`). `ISSUED` is not a valid status in the pro-forma invoice lifecycle.

Enabling `auto_send` on a template requires the `INVOICE_MANAGE` permission surface. Mobile clients cannot toggle this field (see Section 8).

---

## 4. Generation tool and ownership

`in_workflow.generate_recurring_invoice` is the sole tool that creates invoices from recurring templates. It:

1. Reads the template's `lines_payload` and configuration.
2. Calls `in_workflow.create_invoice` to insert a new `invoices` row in `DRAFT`.
3. Inserts a `recurring_invoice_runs` row with `status = GENERATED` (idempotency record).
4. If `auto_send = true`, calls `in_workflow.send_invoice` to allocate a sequence number and transition to `SENT` (canonical lifecycle status).
5. Emits `RECURRING_INVOICE_GENERATED` (LOW severity).

---

## 5. Generation trigger paths

Two trigger paths exist:

**Path A — IN_MONTHLY workflow integration:**
When an `IN_MONTHLY` run's period matches a template's `next_due_date`, the INCOME_MATCHING or LEDGER_PREPARATION phase invokes `in_workflow.generate_recurring_invoice` for in-scope templates. This is the primary path for businesses with active recurring templates and regular bank statement uploads.

**Path B — Standalone background job:**
The daily scheduler (Block 03 Phase 09, runs at 06:00 UTC) queries `recurring_invoice_templates WHERE status = 'ACTIVE' AND next_due_date <= today` and generates invoices for any due template not already covered by a workflow run. This path handles non-workflow-triggered schedules and businesses where `auto_start_on_statement_upload = false`.

Both paths share the same idempotency guarantee: the `UNIQUE (template_id, generation_date)` constraint on `recurring_invoice_runs` ensures exactly one invoice per template per due date regardless of how many times the generation path executes.

---

## 6. Schedule lifecycle — pause, modify, cancel

Owner, Admin, and Bookkeeper may manage templates via the `INVOICE_MANAGE` permission surface:

| Action | Tool | Effect |
| --- | --- | --- |
| Pause | `in_workflow.pause_recurring_schedule` | Sets `status = PAUSED`; scheduler skips the template until resumed |
| Resume | `in_workflow.resume_recurring_schedule` | Sets `status = ACTIVE`; `next_due_date` is recalculated from today if the prior due date has passed |
| Modify | `in_workflow.update_recurring_schedule` | Updates template fields; takes effect from the **next** generation cycle |
| Cancel | `in_workflow.cancel_recurring_schedule` | Sets `status = ENDED`; terminal; no further invoices generated |

**Retroactive effect prohibition:** changes to a recurring schedule do not retroactively alter already-generated invoices. An update to `lines_payload` or `vat_treatment` affects only invoices generated after the update. This rule is enforced by the tool — it writes the new field values to the template row, not to existing invoice rows.

---

## 7. Sequence number timing

The gap-free sequence number is consumed at `SENT` time, not `DRAFT` time. A `DRAFT` recurring invoice has no `invoice_number` until it is sent:

- `DRAFT` invoices: `invoice_number = NULL`.
- Transition to `SENT` (via `auto_send = true` or manual promotion): `in_workflow.next_invoice_number` allocates `PRO-YYYY-NNNN`. The status is `SENT`, not `ISSUED`.
- Skipped periods do not reserve sequence numbers.
- A template that is paused for February and resumes in March produces no `PRO-YYYY-NNNN` gap for February.

This is a binding rule from `invoice_sequence_schema`: the gap-free invariant applies to numbers actually allocated, not to calendar periods covered by a template.

---

## 8. Mobile client rejection

All template write operations (create, pause, resume, modify, cancel) and all `auto_send` toggle operations are rejected from `client_form_factor = MOBILE` before the permission check. The rejection emits `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints`. Mobile clients may read template state and generated invoice records.

---

## 9. Catch-up and skip behavior

If the scheduler was offline and `next_due_date < today - 7 days`, the scheduler inserts a `SKIPPED` run row and advances `next_due_date` without generating an invoice. This prevents unbounded back-fill for long-dormant templates. The 7-day window is the binding catch-up limit.

Invoices are not generated retroactively for skipped periods. If the business needs to issue an invoice for a skipped period, it must be created manually via `in_workflow.create_invoice`.

---

## 10. Persistent failure handling

A template that produces `FAILED` status in `recurring_invoice_runs` for 3 consecutive scheduled dates raises a `HIGH` severity review issue in Block 14. The template is retried on each subsequent day; the review issue is visible to Owner/Admin to prompt investigation.

---

## 11. Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `RECURRING_INVOICE_GENERATED` | LOW | `in_workflow.generate_recurring_invoice` produces a new invoice |
| `RECURRING_SCHEDULE_UPDATED` | LOW | Template fields modified via `in_workflow.update_recurring_schedule` |
| `RECURRING_SCHEDULE_CANCELLED` | MEDIUM | Template set to `ENDED` via `in_workflow.cancel_recurring_schedule` |
| `RECURRING_INVOICE_GENERATION_SKIPPED` | LOW | Scheduler inserts a `SKIPPED` run (catch-up window exceeded or template paused) |
| `RECURRING_INVOICE_GENERATION_FAILED` | MEDIUM | Scheduler inserts a `FAILED` run |

`RECURRING_SCHEDULE_CANCELLED` is MEDIUM severity because cancellation is irreversible; it permanently ends the template's generation cycle.

---

## Cross-references

- `recurring_invoice_run_schema` — `recurring_invoice_templates` and `recurring_invoice_runs` table definitions; idempotency guarantee; catch-up window semantics; `auto_send` column
- `invoice_schema` — generated invoice rows; `invoice_type = PRO_FORMA`; `pro_forma_expires_at`
- `invoice_lifecycle_policy` — `in_workflow.send_invoice` promotion; `DRAFT → SENT` transition; sequence number allocation timing
- `invoice_sequence_schema` — `PRO_FORMA` series; `in_workflow.next_invoice_number`; gap-free invariant
- `pro_forma_expiry_policy` — expiry timing on generated pro-forma invoices; `EXPIRED_UNCONVERTED` terminal state
- `audit_log_policies` — `RECURRING_INVOICE` domain; past-tense naming convention
- `audit_event_taxonomy` — `RECURRING_INVOICE_GENERATED`, `RECURRING_SCHEDULE_UPDATED`, `RECURRING_SCHEDULE_CANCELLED`
- `mobile_write_rejection_endpoints` — mobile rejection surface list
- Block 13 Phase 05 — recurring templates and daily scheduler; catch-up semantics; cadence recompute
- Block 03 Phase 09 — trigger engine that fires the daily scheduler at 06:00 UTC
- Block 02 Phase 04 — `INVOICE_MANAGE` permission surface
- `decisions_log.md` — MVP cadence enum locked at MONTHLY/QUARTERLY/ANNUALLY; wider cadences deferred Stage 2
- `invoice_sequence_schema` — gap-free sequence invariant; `PRO-YYYY-NNNN` series; sequence number allocated at `SENT` transition, not at `DRAFT`; cancelling a recurring schedule (audit event `RECURRING_SCHEDULE_CANCELLED`) does not reserve or release sequence numbers for future periods
