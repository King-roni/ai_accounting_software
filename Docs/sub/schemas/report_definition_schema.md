# Schema: report_definitions

**Category:** Schemas · Block 16 — Dashboard & Reporting
**Table:** `report_definitions`
**Type:** System table — global, not per-business
**Last updated:** 2026-05-17

---

## Purpose

`report_definitions` stores the configuration for every report type the system can generate. It is the authoritative registry of supported reports — their output formats, required parameters, generating tool, and access constraints. This table is seeded at deployment and is read-only at runtime for all roles including ADMIN.

---

## DDL

```sql
CREATE TABLE report_definitions (
  id                          uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Identity
  report_type                 text        NOT NULL,
  report_name                 text        NOT NULL,

  -- Supported output formats for this report type
  -- Values: 'PDF' | 'XLSX' | 'CSV' | 'JSON'
  output_formats              text[]      NOT NULL,

  -- JSON Schema (draft-07) describing the parameters required to generate this report.
  -- Common parameters: period_year (integer), period_month (integer), business_id (uuid).
  -- Report-specific parameters may include: date_from, date_to, account_code,
  -- include_unrealised_fx, vat_box_override, etc.
  parameter_schema            jsonb       NOT NULL,

  -- The tool called to generate this report type.
  -- Examples: 'report.generate_period_summary', 'report.generate_vat_return',
  --           'report.generate_audit_log_export', 'report.generate_aged_receivables'
  generator_tool              text        NOT NULL,

  -- Estimated generation time in seconds. Used by the UI to set polling intervals
  -- and display progress indicators. Default covers most summary reports.
  estimated_generation_seconds integer    NOT NULL DEFAULT 30,

  -- Maximum number of data rows the report will include. NULL = unlimited.
  -- Used for reports that could grow unbounded (e.g. full transaction history).
  -- If the actual row count exceeds this limit, the report job returns REPORT_TOO_LARGE.
  max_row_limit               integer     NULL,

  -- If true, the report cannot be generated for a period that has not been
  -- finalized (workflow_runs.run_status != 'FINALIZED'). Enforced by the
  -- report job executor before calling the generator_tool.
  requires_finalized_period   boolean     NOT NULL DEFAULT true,

  -- If true, the user must complete a step-up authentication challenge before the
  -- report job is created. Applies to sensitive reports such as audit log exports
  -- and full data exports. See archive_step_up_policy.md.
  requires_step_up            boolean     NOT NULL DEFAULT false,

  -- Soft-delete / feature flag. Inactive definitions are not shown in the UI
  -- and cannot be used to create report jobs.
  is_active                   boolean     NOT NULL DEFAULT true,

  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now()
);
```

---

## Indexes

```sql
-- Primary lookup: by report_type (unique — one definition per type)
CREATE UNIQUE INDEX report_definitions_report_type_key
  ON report_definitions (report_type);

-- UI filtering: only show active definitions
CREATE INDEX report_definitions_is_active_idx
  ON report_definitions (is_active)
  WHERE is_active = true;
```

---

## No Business FK

`report_definitions` has no `business_id` foreign key. Report definitions are global system configuration — they define what kinds of reports exist, not which business requested one. The per-business scope lives in `report_jobs`, which carries `business_id REFERENCES business_entities(id)` and references this table via `report_type`.

---

## Seeded Report Types

The following rows are seeded at deployment. Additional types require a schema migration.

| `report_type` | `report_name` | `output_formats` | `requires_finalized_period` | `requires_step_up` |
|---|---|---|---|---|
| `PERIOD_SUMMARY` | Period Summary | `['PDF','XLSX']` | true | false |
| `VAT_RETURN` | VAT Return (TD4) | `['PDF','XLSX']` | true | false |
| `PROFIT_LOSS` | Profit & Loss | `['PDF','XLSX','CSV']` | true | false |
| `BALANCE_SHEET` | Balance Sheet | `['PDF','XLSX']` | true | false |
| `AGED_RECEIVABLES` | Aged Receivables | `['PDF','XLSX','CSV']` | false | false |
| `AGED_PAYABLES` | Aged Payables | `['PDF','XLSX','CSV']` | false | false |
| `AUDIT_LOG_EXPORT` | Audit Log Export | `['CSV','JSON']` | false | true |
| `FULL_DATA_EXPORT` | Full Data Export | `['JSON']` | false | true |
| `TRANSACTION_HISTORY` | Transaction History | `['XLSX','CSV']` | false | false |
| `LEDGER_TRIAL_BALANCE` | Trial Balance | `['PDF','XLSX']` | true | false |

---

## Governance Rules

1. **No runtime inserts or updates by any role.** Report definitions are changed exclusively via database migrations in the `migrations/` directory. The application user does not have `INSERT`, `UPDATE`, or `DELETE` privileges on this table.
2. **ADMIN users** can view report definitions in the admin panel but cannot modify them.
3. **Soft deletes only.** Setting `is_active = false` hides a definition from the UI and prevents new report jobs of that type. Existing report jobs with a now-inactive type are unaffected.
4. **`generator_tool` values** must match a registered tool in `tool_naming_convention_policy.md`. An unrecognised value causes `REPORT_GENERATION_FAILED` at job execution time.

---

## Relationship to report_jobs

```
report_definitions.report_type (unique)
        ↑
report_jobs.report_type (foreign key — text)
```

`report_jobs` carries the per-business, per-invocation parameters. The `parameter_schema` in `report_definitions` is validated against the `parameters` jsonb in `report_jobs` at job creation time. An invalid parameter object returns `REPORT_GENERATION_FAILED` before execution begins.

---

## Update Trigger

```sql
CREATE TRIGGER report_definitions_updated_at
  BEFORE UPDATE ON report_definitions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

## Parameter Schema — Example

The `parameter_schema` column holds a JSON Schema draft-07 object describing the parameters a caller must supply when creating a `report_job` for this type. Example for `VAT_RETURN`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["business_id", "period_year", "period_month"],
  "additionalProperties": false,
  "properties": {
    "business_id":   { "type": "string", "format": "uuid" },
    "period_year":   { "type": "integer", "minimum": 2020, "maximum": 2099 },
    "period_month":  { "type": "integer", "minimum": 1, "maximum": 12 },
    "include_unrealised_fx": { "type": "boolean", "default": false }
  }
}
```

The report job executor validates the caller's `parameters` jsonb against this schema at job creation time. Validation failure returns `REPORT_GENERATION_FAILED` before any computation begins.

---

## Access Control

| Role | Can view definitions | Can create report jobs | Can delete definitions |
|---|---|---|---|
| `OWNER` | Yes | Yes | No |
| `ADMIN` | Yes | Yes | No |
| `MEMBER` | Yes (active only) | Yes | No |
| System / Migrations | Yes | Yes | Yes (via migration only) |

No application-layer role may insert, update, or delete rows in `report_definitions` directly. The database user used by the application is granted `SELECT` only on this table.

---

## Cross-references

- `report_job_schema.md` — per-business, per-invocation report job table
- `report_output_schema.md` — generated output file metadata
- `report_template_policy.md` — PDF/XLSX template versioning and selection
- `export_definitions_catalog.md` — catalog of all export types including non-report exports
