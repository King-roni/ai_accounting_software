# recurring_invoice_run_schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Two tables support the recurring invoice subsystem: `recurring_invoice_templates` holds the per-client composition and cadence configuration, and `recurring_invoice_runs` is the deduplication ledger that prevents the daily scheduler from generating duplicate invoices. Together they implement the idempotency guarantee described in Block 13 Phase 05: calling the scheduler twice on the same day for the same template produces exactly one invoice. The scheduler runs at 06:00 UTC daily; catch-up logic covers missed runs within a 7-day window.

---

## `recurring_invoice_templates` — canonical DDL reference

The `recurring_invoice_templates` table DDL is canonical in `recurring_invoice_schema.md`. This file defines `recurring_invoice_runs` — the execution records for each template run.

---

## Recurring Invoice Runs Table

> **Superseded DDL removed.** This section previously contained a `CREATE TABLE recurring_invoice_runs` definition using a plain-text `status` column with values `QUEUED`, `RUNNING`, `COMPLETED`, `FAILED`, and `SKIPPED`. That definition was removed in a duplicate-DDL remediation (finding S7-027) because the same table was defined a second time in the "Table — recurring_invoice_runs (deduplication ledger)" section below, using the proper `recurring_run_status_enum` with values `GENERATED`, `SKIPPED`, and `FAILED`. The second definition is the canonical one.

The canonical `CREATE TABLE recurring_invoice_runs` DDL is in the **"Table — `recurring_invoice_runs` (deduplication ledger)"** section below, which uses `recurring_run_status_enum` and the `(template_id, generation_date)` unique constraint as the idempotency guarantee.

---

## Table — `recurring_invoice_runs` (deduplication ledger)

```sql
CREATE TYPE recurring_run_status_enum AS ENUM (
  'GENERATED',
  'SKIPPED',
  'FAILED'
);

CREATE TABLE recurring_invoice_runs (
  run_id                uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  template_id           uuid NOT NULL REFERENCES recurring_invoice_templates(template_id),
  generation_date       date NOT NULL,       -- the calendar date the scheduler ran for this template
  generated_invoice_id  uuid REFERENCES invoices(invoice_id),  -- nullable; null when SKIPPED or FAILED
  status                recurring_run_status_enum NOT NULL,
  failure_message       text,                -- populated when status = FAILED
  created_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_template_generation_date
    UNIQUE (template_id, generation_date)    -- idempotency guarantee
);
```

### Idempotency guarantee

The `UNIQUE (template_id, generation_date)` constraint is the core idempotency mechanism. Before generating an invoice, the scheduler attempts to insert a `recurring_invoice_runs` row. If a row already exists (unique violation), the scheduler skips generation and returns the existing `generated_invoice_id` from the prior run row. This means the scheduler is safe to retry on transient failure without producing duplicates.

`generation_date` is the calendar date the due date was scheduled for, not the wall-clock timestamp of the scheduler execution. This matters for catch-up runs: if the service was down from 2026-04-01 through 2026-04-04 and a monthly template had `next_due_date = 2026-04-01`, the catch-up scheduler on 2026-04-05 generates an invoice with `generation_date = 2026-04-01`, not `2026-04-05`.

### Catch-up window

The daily scheduler, on startup and on each daily tick, checks for `recurring_invoice_templates` where `next_due_date <= today` and no `recurring_invoice_runs` row exists for that `(template_id, next_due_date)` pair. Catch-up is bounded to a 7-day window: if `next_due_date < today - 7 days`, the scheduler inserts a `SKIPPED` run row (with a `failure_message` noting the catch-up window was exceeded) and advances `next_due_date` forward. This prevents unbounded back-fill for long-dormant templates.

### Status semantics

| Status | Meaning |
| --- | --- |
| `GENERATED` | Invoice was created successfully; `generated_invoice_id` is populated |
| `SKIPPED` | Due date was beyond the catch-up window, or template was in `PAUSED`/`ENDED` state when the run executed |
| `FAILED` | `invoice.create` or `invoice.markSent` threw an error; `failure_message` carries the detail; the template is retried on the next day's run |

A template that fails for 3 consecutive scheduled dates raises a `HIGH` severity review issue (Block 14) to surface the persistent failure to the user.

### Indexes (runs)

```sql
CREATE INDEX idx_recurring_runs_template
  ON recurring_invoice_runs(template_id, generation_date DESC);

CREATE INDEX idx_recurring_runs_invoice
  ON recurring_invoice_runs(generated_invoice_id)
  WHERE generated_invoice_id IS NOT NULL;
```

## RLS

```sql
CREATE POLICY recurring_templates_isolation ON recurring_invoice_templates
  FOR ALL
  USING (business_id = ANY(auth.business_ids_for_session()));

CREATE POLICY recurring_runs_isolation ON recurring_invoice_runs
  FOR ALL
  USING (
    template_id IN (
      SELECT template_id FROM recurring_invoice_templates
      WHERE business_id = ANY(auth.business_ids_for_session())
    )
  );
```

## Permission gate

Creating, updating, pausing, resuming, and ending templates requires the `INVOICE_MANAGE` surface (Block 02 Phase 04) — Owner, Admin, Bookkeeper. The `recurring_invoice_runs` table is written only by the scheduler (system actor); no user-facing mutation API exists for run rows.

Mobile write rejection: all template mutations are rejected from `client_form_factor = MOBILE` before the permission check.

## Business Rules

- A run row is inserted in `QUEUED` status by the scheduler before any invoice generation begins. If a `QUEUED` or `RUNNING` row already exists for the same `(template_id, period_start, period_end)` tuple, the scheduler must not insert a second row; it returns the existing row's `invoice_id` if available.
- `period_start` and `period_end` are derived from the template's `cadence` and `next_due_date` at the time the run is created. They are immutable after insert.
- `business_id` is denormalised from the template for efficient tenant-isolation queries without a join. It must always match `recurring_invoice_templates.business_id` for the referenced `template_id`.
- A `FAILED` run does not advance the template's `next_due_date`. The scheduler retries on the next daily tick. After 3 consecutive `FAILED` runs for the same template, a `HIGH` severity review issue is raised (Block 14).
- A `SKIPPED` run does advance the template's `next_due_date` to prevent indefinite back-fill.
- `invoice_id` must be null while status is `QUEUED`, `RUNNING`, `FAILED`, or `SKIPPED`. It must be non-null when status is `GENERATED`.
- Deletion of run rows is not permitted. Correction of a bad run requires inserting a new run row with the corrected data and voiding the generated invoice through the standard invoice void flow.

## Audit events

| Event | Trigger |
| --- | --- |
| `RECURRING_INVOICE_GENERATED` | Scheduler produces a new invoice for a template; `generated_invoice_id` populated |
| `RECURRING_INVOICE_GENERATION_SKIPPED` | Scheduler inserts a SKIPPED run row (catch-up window exceeded or template paused/ended) |
| `RECURRING_INVOICE_GENERATION_FAILED` | Scheduler inserts a FAILED run row after a generation error |

Additional template lifecycle events (`RECURRING_INVOICE_TEMPLATE_CREATED`, `RECURRING_INVOICE_TEMPLATE_UPDATED`, `RECURRING_INVOICE_TEMPLATE_PAUSED`, `RECURRING_INVOICE_TEMPLATE_RESUMED`, `RECURRING_INVOICE_TEMPLATE_ENDED`) are in `audit_event_taxonomy` under the `RECURRING_INVOICE` domain.

## Schema Design Notes

The `recurring_invoice_runs` table serves as the deduplication ledger for the recurring invoice subsystem. The design encodes two complementary guarantees:

**Idempotency via unique constraint.** The `UNIQUE (template_id, generation_date)` constraint ensures that no template can have more than one run row for the same generation date. Before generating an invoice, the scheduler does an INSERT; if the row already exists (unique violation), the scheduler returns the existing `generated_invoice_id` without re-generating. This makes the scheduler safe to retry on transient failure.

**Status semantics via typed enum.** The `recurring_run_status_enum` (`GENERATED`, `SKIPPED`, `FAILED`) maps directly to the three terminal outcomes of a scheduled run:
- `GENERATED` — an invoice was produced; `generated_invoice_id` is populated.
- `SKIPPED` — the template was in `PAUSED`/`ENDED` state, or the catch-up window was exceeded; no invoice created.
- `FAILED` — `invoice.create` or `invoice.markSent` raised an error; `failure_message` is populated; the run is retried on the next scheduler tick.

**Catch-up bounded at 7 days.** If `next_due_date` is more than 7 days in the past, the scheduler inserts a `SKIPPED` run row and advances `next_due_date`. This prevents unbounded back-fill on re-activation of dormant templates.

**Persistent failure escalation.** Three consecutive `FAILED` rows for the same template trigger a `HIGH`-severity review issue (Block 14), surfacing the persistent failure to the accountant.

---

## Related Documents

- `data_layer_conventions_policy` — UUID v7 for both PKs; canonical JSON for `lines_payload`; decimal-string currency amounts
- `audit_log_policies` — `RECURRING_INVOICE` domain; past-tense event naming
- `audit_event_taxonomy` — `RECURRING_INVOICE_GENERATED`, `RECURRING_INVOICE_GENERATION_SKIPPED`, `RECURRING_INVOICE_GENERATION_FAILED` under RECURRING_INVOICE domain
- `invoice_schema` — generated invoices FK to `invoices.invoice_id`; `lines_payload` structure is identical
- Block 13 Phase 05 — recurring templates and daily scheduler phase doc (source of truth for scheduler logic, catch-up semantics, cadence recompute)
- Block 03 Phase 09 — trigger engine that fires the daily scheduler
- Block 02 Phase 04 — `INVOICE_MANAGE` permission surface
