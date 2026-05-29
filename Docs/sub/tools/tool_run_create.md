# tool_run_create

**Category:** Tools · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2 tool)

Creates a new workflow run record and returns the `run_id`. This is the only permitted entry point for inserting a row into `workflow_runs`; direct INSERTs are forbidden per `workflow_run_schema.md`.

---

## Tool name

`engine.run_create`

## Side-effect class

`WRITES_RUN_STATE | WRITES_AUDIT`

## AI tier

`NONE`

## Mobile rejection

Mobile clients (`client_form_factor = MOBILE`) cannot call `engine.run_create`. Any call from a mobile client returns HTTP 403 with `error_code: MOBILE_WRITE_REJECTED` per `mobile_write_rejection_endpoints.md`. The audit event `MOBILE_WRITE_REJECTED` is emitted before the request is rejected.

---

## Input schema

```ts
{
  workflow_type:        text,        // must exist in workflow_type_registry
  business_id:          uuid,        // REFERENCES business_entities(id)
  period_year:          integer,     // e.g. 2026; null allowed for non-period-bound types
  period_month:         integer,     // 1–12; null allowed for non-period-bound types
  triggered_by:         enum,        // SCHEDULED | MANUAL | API
  triggered_by_user_id: uuid | null, // null for SCHEDULED; required for MANUAL and API
  run_config:           jsonb,       // type-specific config; validated against the workflow
                                     // type's config_schema in workflow_type_registry
}
```

### Field constraints

- `workflow_type` must be registered in `workflow_type_registry`. If the type is not found, the tool returns `WORKFLOW_TYPE_UNKNOWN`.
- `business_id` must reference an active row in `business_entities`. Inactive businesses return `BUSINESS_INACTIVE`.
- `period_year` + `period_month` are required when `workflow_type` is period-bound (OUT_MONTHLY, IN_MONTHLY, OUT_ADJUSTMENT, IN_ADJUSTMENT). For non-period-bound types (INGESTION, CLASSIFICATION, etc.), both must be null.
- `triggered_by_user_id` must be null when `triggered_by = SCHEDULED`. For `MANUAL` and `API`, a valid user UUID is required.
- `run_config` is validated against the JSON schema stored in `workflow_type_registry.config_schema`. Validation failure returns `RUN_CONFIG_INVALID` with a list of JSON Schema violations.

---

## Uniqueness constraint

Only one run with `run_status` in `{RUNNING, PAUSED, REVIEW_HOLD, AWAITING_APPROVAL}` is permitted per `(business_id, workflow_type, period_year, period_month)`.

An attempt to create a duplicate returns `ENGINE_RUN_ALREADY_ACTIVE` with the `run_id` of the existing active run. The caller may inspect the existing run via `engine.get_run` before deciding whether to abort it or wait.

Note: CREATED-status runs do not count toward the uniqueness check — a CREATED run that was never advanced may exist alongside a new CREATED run only until the first `engine.advance_phase` call.

---

## Run config storage

The `run_config` jsonb is stored in a type-specific config table:

- Workflow types with prefix `OUT_` → `out_run_configs` (schema: `out_run_config_schema.md`)
- Workflow types with prefix `IN_` → `in_run_configs` (schema: `in_run_config_schema.md`)
- Other types → type-specific config table as specified in `workflow_type_registry`

The `workflow_runs` row references the config row via a type-specific FK column. The run_config payload is not stored inline on `workflow_runs`.

---

## Initial state and phase behavior

On successful creation:

- `run_status` is set to `CREATED`
- `current_phase_index` is set to `0`
- `effective_phase_sequence_json` is set to the phase sequence from `workflow_type_registry` at the moment of creation (snapshot, not a live reference)
- No phase rows are created; the engine advances to the first phase via a subsequent call to `engine.advance_phase`

CREATED is a holding state. A run may remain CREATED indefinitely until the caller advances it or cancels it. The CREATED status is not subject to the stale-run alert policy; only PAUSED runs emit stale alerts.

---

## Output schema

```ts
{
  run_id:     uuid,        // gen_uuid_v7() PK
  run_status: 'CREATED',
  created_at: timestamptz,
}
```

---

## Error codes

| Code | Meaning |
| --- | --- |
| `MOBILE_WRITE_REJECTED` | Caller is a mobile client |
| `WORKFLOW_TYPE_UNKNOWN` | `workflow_type` not in registry |
| `BUSINESS_INACTIVE` | `business_id` references a deactivated business |
| `RUN_CONFIG_INVALID` | `run_config` fails JSON schema validation |
| `ENGINE_RUN_ALREADY_ACTIVE` | Active run already exists for this period and workflow type |
| `PERIOD_FIELDS_REQUIRED` | Period-bound type supplied with null period fields |
| `PERIOD_FIELDS_FORBIDDEN` | Non-period-bound type supplied with non-null period fields |
| `TRIGGERED_BY_USER_REQUIRED` | `triggered_by` is MANUAL or API but `triggered_by_user_id` is null |

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `ENGINE_RUN_CREATED` | LOW | Successful run creation |
| `MOBILE_WRITE_REJECTED` | LOW | Mobile client rejected before creation |

`ENGINE_RUN_CREATED` payload includes: `run_id`, `workflow_type`, `business_id`, `period_year`, `period_month`, `triggered_by`, `triggered_by_user_id`.

---

## Registration

```ts
engine.registerTool({
  name: "engine.run_create",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_run_create#v1.input",
  output_schema_ref: "tool_run_create#v1.output",
  audit_events: ["ENGINE_RUN_CREATED", "MOBILE_WRITE_REJECTED"],
  description_ref: "Docs/sub/tools/tool_run_create.md",
});
```

---

## Cross-references

- `workflow_run_schema.md` — `workflow_runs` table definition and `run_status_enum`
- `workflow_run_creation_policy.md` — policy governing when runs may be created
- `workflow_type_registry_schema.md` — registry of valid workflow types and their config schemas
- `out_run_config_schema.md` — config table for OUT workflow types
- `in_run_config_schema.md` — config table for IN workflow types
- `mobile_write_rejection_endpoints.md` — mobile rejection contract
- `tool_naming_convention_policy.md` — naming and registration rules
- `audit_log_policies.md` — audit event naming convention
