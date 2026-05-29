# Tool: in_workflow.start

**Category:** Tools · Block 13 — IN Workflow + Invoice Generator
**Namespace:** `in_workflow`
**Action:** `start`
**Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`

---

## Purpose

Starts a new IN workflow run for a given business and period. The IN workflow processes inbound revenue activity — generating invoices from recurring templates, tracking receivables, and reconciling incoming bank payments against issued invoices — for a single calendar month. This tool is the single entry point for all IN run creation.

---

## Mobile Rejection

Mobile clients cannot call `in_workflow.start`. Any call from a mobile session returns HTTP 403 with error body `{ "code": "MOBILE_WRITE_REJECTED", "tool": "in_workflow.start" }`. See `mobile_write_rejection_endpoints.md` for the full list of mobile-rejected write tools.

---

## Input Schema

```json
{
  "business_id":          "uuid",
  "period_year":          "integer",
  "period_month":         "integer (1–12)",
  "triggered_by":         "enum(SCHEDULED | MANUAL)",
  "triggered_by_user_id": "uuid | null",
  "run_config":           "object (in_run_config_schema.md)",
  "idempotency_key":      "string"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `business_id` | uuid | yes | Must reference `business_entities(id)` |
| `period_year` | integer | yes | Four-digit year |
| `period_month` | integer | yes | 1–12 |
| `triggered_by` | enum | yes | `SCHEDULED` for cron-initiated; `MANUAL` for user-initiated |
| `triggered_by_user_id` | uuid or null | yes | Null for `SCHEDULED`; required for `MANUAL` |
| `run_config` | object | yes | Configuration blob per `in_run_config_schema.md` |
| `idempotency_key` | string | yes | Duplicate keys within 24 h return the existing run |

---

## Preconditions

1. `business_id` must reference an active business entity (`business_entities.status = 'ACTIVE'`).
2. `period_year` and `period_month` must form a valid past or current calendar month.
3. For `MANUAL` runs: `triggered_by_user_id` must be a business member with role `OWNER` or `ADMIN`.

---

## Concurrency Check

Before creating a new run, the tool checks for existing active IN runs for the same business-period:

- Queries `workflow_runs` for rows where `business_id` matches, `workflow_type = 'IN'`, `period_year` matches, `period_month` matches, and `run_status IN ('RUNNING', 'PAUSED', 'REVIEW_HOLD', 'AWAITING_APPROVAL')`.
- If any such row exists, returns `ENGINE_RUN_ALREADY_ACTIVE` (409).
- Only one active IN run per business-period is permitted at any time.

---

## Process

### Step 1 — Idempotency Check

Queries `workflow_runs` for an existing row matching `idempotency_key`. If found, returns the existing run state without modification.

### Step 2 — Concurrency Check

As described above.

### Step 3 — Run Creation

Calls `engine.run_create` with:
- `workflow_type = 'IN'`
- `business_id`, `period_year`, `period_month`, `triggered_by`, `triggered_by_user_id`, `idempotency_key`

Stores `run_config` in `in_run_configs`:

```sql
INSERT INTO in_run_configs (
  id,          -- gen_uuid_v7()
  run_id,
  business_id,
  config_blob,
  created_at
);
```

### Step 4 — Phase Advance to INVOICE_GENERATION (Phase 1)

Calls `engine.advance_phase` to transition the run from `CREATED` to phase 1 (`INVOICE_GENERATION`). The IN workflow phase sequence is distinct from the OUT workflow — governed by `in_monthly_phase_sequence.md`.

Phase 1 processes recurring invoice templates:

1. Queries `recurring_invoice_templates` where `business_id` matches and `status = 'ACTIVE'` and `applies_to_month(period_year, period_month) = true`.
2. For each matching template, creates a DRAFT invoice in `invoices` using the template's line items, VAT rates, and client reference. Schema: `recurring_invoice_schema.md`.
3. The count of created DRAFT invoices is captured in `run_metrics.recurring_invoices_generated`.

If any template references a client that no longer exists (`client_not_found`), the tool emits `IN_WORKFLOW_CLIENT_NOT_FOUND` (422) and adds a `review_queue` issue rather than halting the run.

If the invoice sequence number pool for the business is exhausted (`invoice_sequences` table), returns `IN_WORKFLOW_INVOICE_SEQUENCE_EXHAUSTED` (503). The run does not advance past phase 1 until the sequence is extended.

### Step 5 — Bank Reconciliation Gate

After phase 1 completes, the tool checks the reconciliation dependency:

- Queries `workflow_runs` for a row where `business_id` matches, `workflow_type = 'OUT'`, `period_year` matches, `period_month` matches, and `run_status = 'FINALIZED'`.
- **OUT run is FINALIZED** — the reconciliation phase is immediately queued as phase 3 of this IN run. Bank debits from the finalized OUT run are matched against the period's invoices.
- **OUT run is not FINALIZED** — the reconciliation phase is deferred. The IN run advances through phases 1 and 2 normally. A deferred reconciliation trigger is stored in `deferred_reconciliation_triggers`. When the OUT run finalizes, it fires `in_workflow.trigger_reconciliation` for the matching IN run.

### Step 6 — Audit Emission

Emits `ENGINE_RUN_CREATED` (LOW) and `IN_WORKFLOW_RECURRING_INVOICE_GENERATED` (LOW) to the audit log.

---

## Trigger Modes

### SCHEDULED

Triggered by `in_monthly_trigger_policy.md`. The scheduler runs on the same schedule as the OUT trigger. `triggered_by = 'SCHEDULED'`, `triggered_by_user_id = null`. Idempotency key: `in:{business_id}:{period_year}:{period_month}`.

### MANUAL

Triggered by an OWNER or ADMIN user via the UI. The user may manually start an IN run at any time.

---

## Output Schema

```json
{
  "run_id":                    "uuid",
  "run_status":                "RUNNING",
  "current_phase":             1,
  "recurring_invoices_queued": "integer"
}
```

`recurring_invoices_queued` is the count of DRAFT invoices created in phase 1 from recurring templates.

---

## Error Codes

| Code | HTTP Equivalent | Condition |
|---|---|---|
| `ENGINE_RUN_ALREADY_ACTIVE` | 409 | Active IN run exists for this business-period |
| `ENGINE_IDEMPOTENCY_HIT` | 200 | Idempotency key matched; cached result returned |
| `IN_WORKFLOW_INVOICE_SEQUENCE_EXHAUSTED` | 503 | Invoice sequence number pool is exhausted |
| `IN_WORKFLOW_CLIENT_NOT_FOUND` | 422 | Template references a deleted client; review issue created |

---

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `ENGINE_RUN_CREATED` | LOW | New IN workflow run row inserted |
| `IN_WORKFLOW_RECURRING_INVOICE_GENERATED` | LOW | DRAFT invoices created from recurring templates |

---

## Cross-references

- `in_run_config_schema.md` — structure of the `run_config` object
- `in_monthly_phase_sequence.md` — ordered phase definitions for the IN workflow
- `recurring_invoice_schema.md` — recurring template and generated invoice structure
- `in_monthly_trigger_policy.md` — scheduled trigger rules and timing
- `mobile_write_rejection_endpoints.md` — mobile write rejection rules
