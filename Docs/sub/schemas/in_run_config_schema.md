# IN Run Config Schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

**Purpose.** Define the `in_run_configs` table, which is the IN_MONTHLY-specific extension of `workflow_runs`. Every `IN_MONTHLY` run has exactly one `in_run_configs` row. The base `workflow_runs` row carries shared state (status, phase pointer, timing) and the config row carries IN_MONTHLY-specific parameters: per-client invoice generation overrides, the recurring invoice flag, and trigger metadata. The config row is written once at run creation time and is thereafter immutable; a re-run creates a new `workflow_run_id` and a new config row.

---

## Table DDL

```sql
CREATE TABLE in_run_configs (
    id                          UUID        NOT NULL DEFAULT gen_uuid_v7()  PRIMARY KEY,
    workflow_run_id             UUID        NOT NULL                        REFERENCES workflow_runs(id),
    business_id                 UUID        NOT NULL                        REFERENCES business_entities(id),
    period_year                 INTEGER     NOT NULL,
    period_month                INTEGER     NOT NULL  CHECK (period_month BETWEEN 1 AND 12),
    invoice_generation_config   JSONB,
    recurring_invoice_enabled   BOOLEAN     NOT NULL  DEFAULT TRUE,
    manual_trigger              BOOLEAN     NOT NULL  DEFAULT FALSE,
    triggered_by_user_id        UUID,
    created_at                  TIMESTAMPTZ NOT NULL  DEFAULT now(),

    CONSTRAINT in_run_configs_workflow_run_uniq UNIQUE (workflow_run_id)
);

CREATE INDEX idx_in_run_configs_business_period
    ON in_run_configs (business_id, period_year, period_month);
```

All UUIDs are generated via `gen_uuid_v7()` per `data_layer_conventions_policy`. The `triggered_by_user_id` column is nullable: it is populated for manually triggered runs and null for scheduler-driven or event-driven runs.

---

## Column reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID v7 | No | Primary key |
| `workflow_run_id` | UUID v7 | No | FK → `workflow_runs.id`; UNIQUE (one config per run) |
| `business_id` | UUID v7 | No | FK → `business_entities.id`; tenant scope |
| `period_year` | integer | No | Calendar year of the accounting period (e.g. 2026) |
| `period_month` | integer | No | Calendar month 1–12 |
| `invoice_generation_config` | JSONB | Yes | Per-client invoice parameter overrides; null = use global business defaults |
| `recurring_invoice_enabled` | boolean | No | If `false`, the recurring invoice generation phase is skipped for this run |
| `manual_trigger` | boolean | No | `true` if triggered by an operator action, `false` for scheduler or event-driven |
| `triggered_by_user_id` | UUID v7 | Yes | User who triggered a manual run; null for scheduler/event-driven |
| `created_at` | timestamptz | No | Row creation timestamp |

---

## Period uniqueness

The UNIQUE constraint on `(workflow_run_id)` ensures a single workflow run has at most one config row. Period uniqueness (only one ACTIVE run per `(business_id, period_year, period_month)` for the `IN_MONTHLY` workflow type) is enforced at the `workflow_runs` level by a partial unique index owned by `workflow_run_creation_policy`. The config row is subordinate to that constraint.

The partial index on `workflow_runs`:

```sql
CREATE UNIQUE INDEX idx_workflow_runs_active_period_uniq
    ON workflow_runs (business_id, workflow_type, period_year, period_month)
    WHERE status NOT IN ('FINALIZED', 'FAILED', 'CANCELLED');
```

Attempts to create a second active IN_MONTHLY run for the same `(business_id, period_year, period_month)` fail at the `workflow_runs` insert before `in_run_configs` is written. See `workflow_run_creation_policy` for the full rejection handling.

---

## `invoice_generation_config` JSONB shape

This field provides per-client overrides for invoice generation within this specific run. Overrides apply only to invoices generated during this run; they do not alter the client's persisted defaults in the `clients` table.

```json
{
  "<client_id_uuid>": {
    "default_vat_rate": 0.19,
    "payment_terms_days": 14,
    "currency": "EUR"
  },
  "<another_client_id_uuid>": {
    "default_vat_rate": 0.09,
    "payment_terms_days": 30,
    "currency": "EUR"
  }
}
```

| Field | Type | Description |
|---|---|---|
| Key (client_id) | UUID string | References `clients.id` for the business |
| `default_vat_rate` | number | Override VAT rate for this client's invoices in this run (e.g. `0.19` for 19%) |
| `payment_terms_days` | integer | Override payment terms in days for this client's invoices in this run |
| `currency` | char(3) | ISO 4217 currency code; must be `EUR` for MVP |

If a client ID appears in `invoice_generation_config` but has no corresponding row in `clients`, the run fails at invoice generation with `INVALID_CLIENT_CONFIG_OVERRIDE`. The validation runs at Phase 1 (CLIENT_VALIDATION), not at config creation time.

If `invoice_generation_config` is null, all invoices use the global business defaults from `business_invoice_settings`.

Partial overrides are allowed: if `default_vat_rate` is provided but `payment_terms_days` is omitted, only `default_vat_rate` is overridden and the client's persisted `payment_terms_days` applies.

---

## Recurring invoice flag

`recurring_invoice_enabled` controls whether the IN_MONTHLY run executes the recurring invoice generation phase.

- `true` (default): the run processes all active `recurring_invoice_templates` for the business whose `billing_day` falls within the period and whose `status = ACTIVE`. Each qualifying template generates a DRAFT invoice; the drafts are then auto-issued per the template's `auto_issue` flag.
- `false`: the recurring invoice generation phase is skipped entirely. No `recurring_invoice_templates` are evaluated. `RECURRING_INVOICE_GENERATION_SKIPPED` is emitted for each active template that would have been processed. This flag is used for periods where recurring billing is paused (e.g., a business temporarily halting monthly subscriptions for a specific period).

Setting `recurring_invoice_enabled = false` does not deactivate or modify the underlying templates; it only affects this run. The next run with `recurring_invoice_enabled = true` processes the templates as normal.

---

## Audit event

`IN_WORKFLOW_RUN_CONFIGURED` (LOW) — emitted by `in_workflow.configure_run` when the `in_run_configs` row is successfully inserted. Payload:

```json
{
  "config_id": "<in_run_configs.id>",
  "workflow_run_id": "<workflow_run_id>",
  "business_id": "<business_id>",
  "period_year": 2026,
  "period_month": 5,
  "recurring_invoice_enabled": true,
  "invoice_generation_config_client_count": 2,
  "manual_trigger": false,
  "triggered_by_user_id": null
}
```

`invoice_generation_config` client IDs are not included in the payload (privacy boundary on client IDs); only the count of overridden clients is recorded.

---

## Relationship to OUT run config

`in_run_configs` and `out_run_configs` share the same structural pattern (one config row per workflow run, subordinate period uniqueness, same created_at + trigger columns) but carry different operational parameters:
- `out_run_configs` carries `bank_upload_ids` and `phase_override_config`
- `in_run_configs` carries `invoice_generation_config` and `recurring_invoice_enabled`

There is no FK between the two tables. The pairing of an `OUT_MONTHLY` run and an `IN_MONTHLY` run for the same period is tracked on `workflow_runs` via the `paired_run_id` column, not via the config tables.

---

## Cross-references

- `out_run_config_schema.md` — parallel schema for OUT_MONTHLY runs; structural comparison reference
- `workflow_run_creation_policy.md` — period uniqueness enforcement, duplicate rejection, trigger source rules
- `in_monthly_phase_sequence.md` — how phases consume `invoice_generation_config` and `recurring_invoice_enabled` at runtime
- `recurring_invoice_policy.md` — template evaluation logic invoked when `recurring_invoice_enabled = true`
