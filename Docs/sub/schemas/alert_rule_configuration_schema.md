# alert_rule_configuration_schema

**Category:** Schemas · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The `alert_rules` configuration table for the internal-only security alerting system (Block 05 Phase 10). One row per rule. The alerting engine reads this table on a 1–5 minute cadence (or near-real-time via logical replication, Stage 2+), evaluates the configured threshold against the audit log, and emits to the ops security channel per `cross_tenant_alerting_runbook`. Per Stage 1: security alerting is **internal-only** in MVP; user-facing alerts are deferred. The runtime access surface (`SECURITY_ALERTING_MANAGE`) is **NOT** one of the 15 canonical permission surfaces in `permission_matrix` — it is a system/ops surface gated by a session variable, never granted to a user role.

---

## Table definition

```sql
CREATE TYPE alert_rule_subject_kind_enum AS ENUM (
  'actor',     -- rule subject is a user (cross-business, repeated-denial)
  'business',  -- rule subject is a business (single-tenant pattern)
  'system'     -- rule subject is the platform (TSA outage, replication lag)
);

CREATE TYPE alert_rule_status_enum AS ENUM (
  'ENABLED',
  'DISABLED',
  'ARCHIVED'    -- preserved for audit; no longer evaluated
);

CREATE TABLE alert_rules (
  alert_rule_id          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Identification
  rule_name              text NOT NULL,                                 -- short snake_case, e.g., 'cross_business_actor_anomaly'
  alert_class            text NOT NULL,                                 -- matches an entry in cross_tenant_alerting_runbook
  rule_version           text NOT NULL DEFAULT '1.0.0',                 -- semver per rule body

  -- Trigger configuration
  event_type_predicate   text[] NOT NULL,                               -- list of audit event_type names this rule watches
  subject_kind           alert_rule_subject_kind_enum NOT NULL,
  threshold_count        integer NOT NULL,                              -- N events
  threshold_window       interval NOT NULL,                             -- within M time
  evaluation_cadence     interval NOT NULL DEFAULT INTERVAL '5 minutes',

  -- Output configuration
  severity               severity_enum NOT NULL,                        -- LOW | MEDIUM | HIGH | BLOCKING
  dedup_window           interval NOT NULL DEFAULT INTERVAL '1 hour',
  routing_channel        text NOT NULL DEFAULT 'ops_security_channel',  -- resolved against secrets_management

  -- Lifecycle
  status                 alert_rule_status_enum NOT NULL DEFAULT 'ENABLED',
  created_at             timestamptz NOT NULL DEFAULT now(),
  created_by_operator    text NOT NULL,                                 -- operator email (audit attribution)
  updated_at             timestamptz NOT NULL DEFAULT now(),
  updated_by_operator    text NOT NULL,
  disabled_at            timestamptz,
  disabled_reason        text,

  -- Free-form per-rule parameters (e.g., per-rule IP-distinct-count threshold)
  rule_parameters        jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Constraints
  CHECK (threshold_count >= 1),
  CHECK (threshold_window > INTERVAL '0'),
  CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'BLOCKING')),    -- defensive; type enforces it
  CHECK (
    (status = 'DISABLED' AND disabled_at IS NOT NULL AND disabled_reason IS NOT NULL)
    OR (status <> 'DISABLED')
  ),
  CHECK (
    -- event_type_predicate is non-empty
    array_length(event_type_predicate, 1) >= 1
  ),
  UNIQUE (rule_name)
);
```

`severity_enum` is defined once in `review_issues_schema` per `severity_enum` (the 4-value closed enum `LOW`, `MEDIUM`, `HIGH`, `BLOCKING`). This table reuses it directly; no `CRITICAL` value exists per the 2026-05-08 drift correction.

## Companion `alerts` table

The dispatched-alert rows (per Phase 10 — outside the scope of this sub-doc but cross-referenced for completeness) point back to `alert_rule_id`:

```sql
CREATE TABLE alerts (
  alert_id               uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  alert_rule_id          uuid NOT NULL REFERENCES alert_rules(alert_rule_id),
  severity               severity_enum NOT NULL,
  subject_kind           alert_rule_subject_kind_enum NOT NULL,
  subject_id             text NOT NULL,                                 -- actor_user_id, business_id, or 'SYSTEM'
  affected_business_ids  uuid[],                                        -- NULL for system alerts
  triggering_event_ids   uuid[] NOT NULL,
  payload                jsonb NOT NULL,
  fired_at               timestamptz NOT NULL DEFAULT now(),
  dedup_window_started_at timestamptz NOT NULL,
  acknowledged_at        timestamptz,
  acknowledged_by_operator text,
  resolved_at            timestamptz,
  resolved_by_operator   text,
  resolution_notes       text
);
```

Per `cross_tenant_alerting_runbook`: the runbook consumes this row's `payload` shape directly.

## Validation rules

1. `rule_name` matches `^[a-z][a-z0-9_]*$` (snake_case)
2. `alert_class` matches an entry in `cross_tenant_alerting_runbook`'s alert-class table (lint-enforced at write time via a fixture check)
3. Every entry in `event_type_predicate` is a member of `audit_event_taxonomy` (lint-enforced)
4. `severity` is one of the 4 values from `severity_enum`; the drift lint check in `severity_critical_drift_lint_check` rejects any reference to `CRITICAL`
5. `threshold_count >= 1` and `threshold_window > 0`
6. `dedup_window > 0` and `dedup_window >= threshold_window` (the dedup window must cover the trigger window to be meaningful)
7. `routing_channel` is resolved at dispatch against `secrets_management` (Block 05 Phase 07); the column stores a logical channel name, not the secret value

## RLS — operator-only access

The table is **NOT** user-visible. Per Stage 1: security alerting is internal-only; the `SECURITY_ALERTING_MANAGE` capability is a system surface, NOT a row in `permission_matrix`. RLS enforces this via the `app.ops_security_active` session variable:

```sql
ALTER TABLE alert_rules ENABLE ROW LEVEL SECURITY;

CREATE POLICY alert_rules_read ON alert_rules
  FOR SELECT
  USING (current_setting('app.ops_security_active', true) = 'true');

CREATE POLICY alert_rules_insert ON alert_rules
  FOR INSERT
  WITH CHECK (current_setting('app.ops_security_active', true) = 'true');

CREATE POLICY alert_rules_update ON alert_rules
  FOR UPDATE
  USING (current_setting('app.ops_security_active', true) = 'true');

CREATE POLICY alert_rules_no_delete ON alert_rules
  FOR DELETE
  USING (false);
```

The `app.ops_security_active` variable is set only by the ops-tooling service account at connection time. No user-role session ever has it set — no user-facing API path can read or modify rules. The DELETE policy is `false` permanently: rules are archived (`status = 'ARCHIVED'`), never deleted, so the audit history of past rule configurations survives.

## Audit events

Every change to `alert_rules` emits an audit event under the `SECURITY` / `AUDIT` domain (per `audit_log_policies` Block 05 domain allowlist). Emit-as-separate-transaction per `audit_log_policies` Section 4.

| Event | When | Payload sketch |
| --- | --- | --- |
| `ALERT_RULE_ADDED` | INSERT | `{ alert_rule_id, rule_name, alert_class, severity, threshold_count, threshold_window, created_by_operator }` |
| `ALERT_RULE_UPDATED` | UPDATE (excluding status-change-to-DISABLED) | `{ alert_rule_id, rule_version, fields_changed, updated_by_operator }` |
| `ALERT_RULE_DISABLED` | UPDATE setting `status = 'DISABLED'` | `{ alert_rule_id, disabled_reason, disabled_by_operator }` |
| `SECURITY_ALERT_RAISED` | Alert dispatch from rule evaluation | Per `cross_tenant_alerting_runbook` Step 1 payload |
| `SECURITY_ALERT_DEDUPLICATED` | Triggering event within dedup window | `{ alert_rule_id, original_alert_id, suppressed_event_count }` |
| `SECURITY_ALERT_ACKNOWLEDGED` | Operator acknowledges an alert | `{ alert_id, acknowledged_by_operator, acknowledged_at }` |
| `SECURITY_ALERT_RESOLVED` | Operator resolves an alert | `{ alert_id, resolved_by_operator, resolution_notes }` |
| `SECURITY_INVESTIGATION_RECORDED` | Operator records investigation outcome | Per `cross_tenant_alerting_runbook` Step 3 |

All events flow to the **global** audit chain partition per `audit_log_policies` Section 4 — they're cross-tenant / system-level by nature, with no single `business_id` scope. The `affected_business_ids` field in the `alerts` row preserves the per-business correlation without binding the chain partitioning to it.

## Indexes

```sql
CREATE INDEX idx_alert_rules_status
  ON alert_rules(status)
  WHERE status = 'ENABLED';

CREATE INDEX idx_alert_rules_event_type
  ON alert_rules USING GIN (event_type_predicate)
  WHERE status = 'ENABLED';

CREATE INDEX idx_alert_rules_alert_class
  ON alert_rules(alert_class)
  WHERE status = 'ENABLED';
```

- `status` (partial) speeds the evaluation-loop scan; only ENABLED rules are evaluated each tick
- `event_type` GIN supports the reverse lookup: "given an audit event of type X, which rules subscribe to it?" — used when the engine moves to push-based evaluation
- `alert_class` supports the runbook-driven query: "show me all rules of class `vault_kek_access_failure`"

## Mobile

`alert_rules` carries no user-facing write surface — there is no API endpoint a user (mobile or desktop) can call to read or modify a rule. The internal ops-tooling that writes here is a server-side process with no client form factor. The `SECURITY_ALERTING_MANAGE` capability is system-only.

For consistency with the `mobile_write_rejection_endpoints` enforcement contract: any future internal API surfacing rule management to a human operator declares `@MobilePolicy("REJECT")` regardless of role, since rule changes are operator-grade actions per Stage 1.

## Cross-references

- `cross_tenant_alerting_runbook` — operator procedure consuming the dispatched `alerts` rows; pins the 8 alert classes and their thresholds
- `audit_log_policies` — `ALERT_RULE_*` and `SECURITY_ALERT_*` event family; chain partitioning (global chain for these events)
- `audit_event_taxonomy` — `ALERT_RULE_ADDED`, `ALERT_RULE_UPDATED`, `ALERT_RULE_DISABLED`, `SECURITY_ALERT_*` catalogue entries
- `data_layer_conventions_policy` — UUID v7 IDs; canonical JSON for `payload` and `rule_parameters`
- `severity_enum` — the 4-value closed enum; no `CRITICAL`
- `permission_matrix` — explicit non-membership: `SECURITY_ALERTING_MANAGE` is NOT one of the 15 surfaces; this is a system surface gated by `app.ops_security_active`
- `mobile_write_rejection_endpoints` — internal ops surface; future operator UI declares REJECT
- Block 05 Phase 02 — audit log foundation
- Block 05 Phase 07 — `secrets_management` for `routing_channel` resolution
- Block 05 Phase 10 — security alerting (architecture)
- Stage 1 decision — security alerting internal-only in MVP
