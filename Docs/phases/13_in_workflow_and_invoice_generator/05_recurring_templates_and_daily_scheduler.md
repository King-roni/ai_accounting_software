# Block 13 — Phase 05: Recurring Invoice Templates & Daily Scheduler

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Recurring Invoices — daily background scheduler; auto-send vs review)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 09 — trigger engine; scheduled jobs)
- Decisions log: `Docs/decisions_log.md` (recurring cadence: daily background scheduler)

## Phase Goal

Implement the recurring-invoice template system: templates carry composition + cadence; a daily background scheduler evaluates templates and produces a fresh invoice when the next-due date arrives. Templates are decoupled from the `IN_MONTHLY` close — mid-month cadences (weekly retainers, biweekly) work without depending on closeout timing. After this phase, recurring revenue (monthly retainers, quarterly subscriptions) is automated end-to-end.

## Dependencies

- Phase 01 (`invoices`, `invoice_lines`)
- Phase 02 (`clients`)
- Phase 03 (`invoice.create`, `invoice.addLine`, `invoice.markSent` — the composition + lifecycle helpers)
- Block 03 Phase 09 (trigger engine — provides the daily cron-style scheduler)
- Block 02 Phase 04 (permission matrix — Owner / Admin / Bookkeeper can create / edit templates; same surface as `INVOICE_MANAGE`)

## Deliverables

- **`recurring_invoice_templates` table:**
  - `id` (UUID v7), `organization_id`, `business_id`
  - `client_id` (FK to `clients`)
  - `template_name` (text; user-facing label, e.g., `"Monthly retainer — Acme Co."`)
  - **Composition snapshot** (the structure used to populate each generated invoice):
    - `currency` (text; ISO-4217)
    - `vat_treatment_per_line` (boolean)
    - `default_vat_treatment` (enum; nullable)
    - `payment_terms_days` (integer)
    - `lines_payload` (JSONB) — the array of `{ description, quantity, unit_price, vat_treatment?, vat_rate_pct? }` objects to copy into each generated invoice's `invoice_lines`. Sub-doc owns the exact JSONB schema.
  - **Cadence:**
    - `cadence_kind` (enum: `WEEKLY`, `BIWEEKLY`, `MONTHLY`, `QUARTERLY`, `SEMI_ANNUAL`, `ANNUAL`)
    - `cadence_anchor_day_of_period` (integer; e.g., `1` for "first of the month"; for weekly cadences, `1` = Monday, `7` = Sunday)
    - `next_due_date` (date; the next issuance date — recomputed on every generation)
    - `start_date` (date; first-issuance date — Stage 1 default; sub-doc owns "skip first" pattern)
    - `end_date` (date; nullable — the template stops generating after this date; null = open-ended)
  - **Auto-send vs review:**
    - `auto_send` (boolean; default `false`) — when `true`, the generated invoice transitions immediately to `SENT` (consumes an `INV-YYYY-NNNN` number); when `false`, the invoice lands as `DRAFT` for user review.
    - `auto_send_target_email` (text; nullable; populated only when `auto_send = true` AND email integration is enabled — out of MVP scope per Phase 04's note; sub-doc tracks).
  - **Lifecycle:**
    - `status` (enum: `ACTIVE`, `PAUSED`, `ENDED`)
    - `paused_at`, `paused_by` (nullable)
  - `created_at`, `created_by`, `updated_at`, `updated_by`
  - **Indexes:** `(business_id, status, next_due_date)` — the scheduler's hot-path query.
- **CRUD surface** (Block 02 Phase 11 settings + invoice-creation UI):
  - `recurring.create({ ... }) → template`
  - `recurring.update({ ... }) → template` — non-cadence fields editable freely; changing `cadence_kind` or `cadence_anchor_day_of_period` triggers a recompute of `next_due_date`.
  - `recurring.pause({ template_id, paused_by })` / `recurring.resume(...)` — `ACTIVE ↔ PAUSED`.
  - `recurring.end({ template_id, ended_by, ended_at })` — moves to `ENDED`; cannot resume.
  - **Permission gate:** `INVOICE_MANAGE` surface (Block 02 Phase 04) — Owner / Admin / Bookkeeper.
- **Daily scheduler** — `recurring.run_daily_scheduler({ scheduled_at })`:
  - Registered with Block 03 Phase 09's trigger engine; fires once per day at a configured hour (sub-doc owns the timing default — Stage 1 default: business-local 03:00).
  - Tool registration: side-effect `WRITES_RUN_STATE` (creates `invoices` rows + optionally transitions to `SENT`); AI tier `NONE`.
  - **Logic:**
    1. Query active templates with `next_due_date <= scheduled_at`.
    2. For each, call Phase 03's `invoice.create` with the template's composition snapshot.
    3. Copy `lines_payload` into `invoice_lines` rows via `invoice.addLine` calls (one per line entry).
    4. If `auto_send = true`, call `invoice.markSent` (allocates the `INV` number; sets lifecycle to `SENT`); else leave as `DRAFT`.
    5. Recompute `next_due_date` per the cadence rule:
       - `WEEKLY` → `next_due_date + 7 days`
       - `BIWEEKLY` → `next_due_date + 14 days`
       - `MONTHLY` → next month's `cadence_anchor_day_of_period` (handling month-end edge cases — e.g., anchor day 31 in February falls back to the last day of February; sub-doc owns the rule)
       - `QUARTERLY` → next quarter's anchor day
       - `SEMI_ANNUAL` → next half-year's anchor day
       - `ANNUAL` → next year's anchor day
    6. If the new `next_due_date > end_date` (when `end_date IS NOT NULL`), transition the template to `ENDED`.
  - **Idempotency:** the scheduler is idempotent over a `(business_id, template_id, due_date)` triple. If the scheduler retries (transient failure), it does not produce duplicate invoices. The dedup key is `recurring_invoice_runs(template_id, due_date)` — sub-doc owns the table; Stage 1 default: a row is inserted on every successful generation.
  - **Failure handling:** if `invoice.create` or `invoice.markSent` fails for one template, the scheduler logs the failure and continues with the next template — one template's failure does not stop the day's run. The failed template is retried on the next day's run; persistent failure raises a HIGH review issue.
- **Mid-month cadence support:**
  - The scheduler is decoupled from `IN_MONTHLY`. A weekly retainer due every Monday produces an invoice every Monday regardless of period boundaries; the invoice's `issue_date` falls in whichever month the Monday is in, and `IN_MONTHLY` for that month picks it up at finalization time.
- **Pro-forma recurring templates:**
  - Templates with `invoice_type = PRO_FORMA` are valid (e.g., a recurring proposal sent monthly). The generated invoice is a pro-forma, follows Phase 03's restricted lifecycle, and converts to a tax invoice via Phase 06 if accepted by the customer.
  - **Pro-forma expiry policy** (closes the "ghost pro-forma" accumulation problem): every generated pro-forma carries a `pro_forma_expires_at` timestamp (sub-doc tracks the column on `invoices`; default `issue_date + 30 days`). A daily integrity job transitions expired pro-formas to a new terminal state `EXPIRED_UNCONVERTED` (extends Phase 01's lifecycle enum to 12 values; flagged for Phase 01's sub-doc-stage migration). The recurring template can be configured with a longer or shorter expiry via `recurring_invoice_templates.pro_forma_expiry_days` (sub-doc tracks; default 30). Expired pro-formas remain in audit but are excluded from any further processing.
  - **Audit event for expiry:** `INVOICE_PRO_FORMA_EXPIRED` (declared here; Phase 03 picks up the lifecycle transition in its audit roster on the sub-doc migration).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `RECURRING_INVOICE`):
  - `RECURRING_INVOICE_TEMPLATE_CREATED`
  - `RECURRING_INVOICE_TEMPLATE_UPDATED` (with field-level diff)
  - `RECURRING_INVOICE_TEMPLATE_PAUSED` / `RECURRING_INVOICE_TEMPLATE_RESUMED` / `RECURRING_INVOICE_TEMPLATE_ENDED`
  - `RECURRING_INVOICE_SCHEDULER_RAN` (with template count processed and invoice count generated)
  - `RECURRING_INVOICE_GENERATED` (per invoice produced)
  - `RECURRING_INVOICE_GENERATION_FAILED` (per template that failed; with error)

## Definition of Done

- A user creates a `MONTHLY` template with anchor day `1`, `auto_send = false`, `start_date = 2026-06-01`; the daily scheduler running on `2026-06-01` produces a `DRAFT` invoice for that template; `next_due_date` advances to `2026-07-01`.
- An `auto_send = true` template generates and immediately transitions to `SENT`, allocating an `INV-YYYY-NNNN` number atomically.
- The scheduler is idempotent — if it runs twice on the same day, only one invoice per template is generated.
- A template with `end_date = 2027-01-01` correctly transitions to `ENDED` once `next_due_date` advances past that date.
- A weekly template anchored to Monday produces invoices every Monday regardless of `IN_MONTHLY` boundaries.
- A failed generation for one template doesn't stop the day's run; a HIGH review issue is raised after persistent failure.
- A pro-forma recurring template generates pro-forma invoices that follow Phase 03's restricted lifecycle.
- Tests cover: every cadence_kind, month-end edge cases, the auto-send vs review path, idempotency, end-date transition, failure isolation.

## Sub-doc Hooks (Stage 4)

- **`lines_payload` JSONB schema sub-doc** — exact shape, validation, evolution.
- **Cadence-recompute SQL sub-doc** — month-end edge cases, leap-year handling, holiday skipping (Stage 2+).
- **Scheduler timing sub-doc** — the per-business-local-time default; multi-tenant scheduling fairness; back-pressure under load.
- **`recurring_invoice_runs` dedup table sub-doc** — schema, retention, edge cases.
- **Email-send integration sub-doc (deferred)** — `auto_send` over email; bounce handling; `auto_send_target_email` lifecycle.
- **Pro-forma recurring sub-doc** — typical use cases; conversion-to-tax-invoice trigger from a recurring pro-forma.
