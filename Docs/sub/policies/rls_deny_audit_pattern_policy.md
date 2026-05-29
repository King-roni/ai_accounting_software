# RLS Deny Audit Pattern Policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

When a Postgres row-level security policy denies an access attempt on a multi-tenant table, the denial must be captured in the audit log. Silent RLS denials are invisible to operators and create a blind spot in the security event stream. This policy defines the trigger function, covered tables, required audit event, and suppression rules.

---

## Purpose

RLS is the primary tenant isolation enforcement mechanism in the platform. A denial event indicates either a misconfigured client, a bug in the application layer that is presenting the wrong `business_id` context, or an active attempt to access rows outside the caller's tenancy boundary. All three cases require an audit trail.

The pattern supplements — it does not replace — the `auth.can_perform` permission check. `auth.can_perform` emits `AUTH_PERMISSION_DENIED` at the application layer. This policy covers the database layer: denials that reach Postgres RLS directly, including cases where the application-layer check was bypassed or absent.

---

## Trigger function

A PL/pgSQL trigger function named `fn_emit_rls_deny_audit` is attached to each covered table. The function signature:

```sql
CREATE OR REPLACE FUNCTION fn_emit_rls_deny_audit()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_table_name  text  := TG_TABLE_NAME;
  v_operation   text  := TG_OP;         -- SELECT | INSERT | UPDATE | DELETE
  v_user_id     uuid  := current_setting('app.current_user_id',   true)::uuid;
  v_business_id uuid  := current_setting('app.current_business_id', true)::uuid;
  v_row_id      uuid;
BEGIN
  -- row_id is only available for UPDATE and DELETE (OLD row); for SELECT/INSERT it is NULL
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    v_row_id := OLD.id;
  END IF;

  -- Suppress system-role and migration contexts (see Suppression section)
  IF current_setting('app.system_role', true) = 'true' THEN
    RETURN NULL;
  END IF;
  IF current_setting('app.migration_transaction', true) = 'true' THEN
    RETURN NULL;
  END IF;

  PERFORM emit_audit_api(
    p_event_name  => 'SECURITY_RLS_DENY_DETECTED',
    p_severity    => 'HIGH',
    p_business_id => v_business_id,
    p_payload     => jsonb_build_object(
      'table_name',   v_table_name,
      'operation',    v_operation,
      'user_id',      v_user_id,
      'business_id',  v_business_id,
      'row_id',       v_row_id
    )
  );

  RETURN NULL;
END;
$$;
```

The function is declared `SECURITY DEFINER` so it can write to the audit log regardless of the role that triggered the denial. It reads `app.current_user_id` and `app.current_business_id` from the session-local GUC settings that Block 02 Phase 04's role helpers set on every authenticated connection.

`emit_audit_api` is the low-level Postgres-callable wrapper around `emitAudit()`. It runs in a separate short transaction per the 2026-05-08 amendment in `audit_log_policies` Section 4, so a denied operation that aborts the caller's transaction does not suppress the audit event.

---

## Covered tables

All multi-tenant tables carry this trigger. The trigger fires on a best-effort AFTER STATEMENT basis for SELECT-policy denials and AFTER ROW basis for INSERT/UPDATE/DELETE-policy denials.

| Table | RLS policy name | Operations covered |
| --- | --- | --- |
| `workflow_runs` | `rls_workflow_runs_tenant_isolation` | SELECT, INSERT, UPDATE, DELETE |
| `transactions` | `rls_transactions_tenant_isolation` | SELECT, INSERT, UPDATE, DELETE |
| `invoices` | `rls_invoices_tenant_isolation` | SELECT, INSERT, UPDATE, DELETE |
| `business_entities` | `rls_business_entities_tenant_isolation` | SELECT, UPDATE |
| `users` | `rls_users_tenant_isolation` | SELECT, UPDATE |
| `documents` | `rls_documents_tenant_isolation` | SELECT, INSERT, UPDATE, DELETE |

Tables that are global (no `business_id` column) do not carry this trigger. Examples: `organizations`, `audit_log`, `chain_heads`. Access control on these tables is handled by role-level grants, not RLS.

---

## Audit event: `SECURITY_RLS_DENY_DETECTED`

**Severity:** HIGH

HIGH because an RLS denial at the database layer indicates either a programming error or an access boundary violation. Both cases require operator visibility.

**Payload fields:**

| Field | Type | Description |
| --- | --- | --- |
| `table_name` | text | Postgres table name where the denial occurred |
| `operation` | text | One of `SELECT`, `INSERT`, `UPDATE`, `DELETE` |
| `user_id` | uuid (nullable) | The authenticated user from the session GUC; null if the connection has no user context |
| `business_id` | uuid (nullable) | The business context from the session GUC; null if no business context is active |
| `row_id` | uuid (nullable) | The `id` of the denied row for UPDATE and DELETE operations; null for SELECT and INSERT |

The `row_id` field is null for SELECT denials because Postgres evaluates SELECT RLS policies before row retrieval — the denied rows are never returned to the trigger. For INSERT denials, the row was not yet committed and carries no stable `id`.

**Chain assignment:** business chain when `business_id` is non-null; global chain when `business_id` is null.

---

## Suppression rules

The trigger must not fire in the following contexts:

**1. System-role operations.** Internal background jobs, cron tasks, and migration support functions set `app.system_role = 'true'` via `SET LOCAL` before executing. These operations intentionally bypass tenant isolation at the application layer and do not represent security denials.

**2. Migration transactions.** Schema migrations set `app.migration_transaction = 'true'`. Migrations operate as superuser or a role with bypass-RLS privilege; an RLS denial during migration indicates a migration authoring error, which is tracked by the migration toolchain separately.

Suppression is enforced inside the trigger function itself rather than by detaching the trigger, so the trigger remains active and can be re-enabled without DDL changes if a context is incorrectly flagged for suppression.

---

## Operational notes

If `app.current_user_id` or `app.current_business_id` are not set — for example, when a query arrives via a direct Postgres connection without the application layer's session setup — the payload fields are null. A non-null `business_id` is the trigger for routing to the business chain; null routes to the global chain. Operators querying the global chain for `SECURITY_RLS_DENY_DETECTED` events with null business context should treat these as elevated-priority investigation items.

Alert rule `rls_deny_threshold` in `security_alert_routing_policy` fires a `SECURITY_ALERT_CREATED` when more than 10 `SECURITY_RLS_DENY_DETECTED` events occur within a 5-minute window for the same `(business_id, table_name)` pair. Bursts above this threshold indicate systematic access-pattern problems rather than isolated incidents.

A single isolated `SECURITY_RLS_DENY_DETECTED` event does not automatically trigger an alert. The event is always present in the audit log for forensic queries using the `events_by_event_type_in_window` index pattern described in `audit_log_policies` Section 3. Operators responding to suspected intrusion attempts should use this query pattern first before escalating.

---

## Cross-references

- `emit_audit_api.md` — the Postgres-callable audit emission wrapper
- `audit_log_policies.md` — chain partitioning, event naming convention, per-role RLS on the audit log itself
- `tenancy_schema_definition.md` — `business_id` column contract on all multi-tenant tables
- `tool_can_perform_helper.md` — application-layer permission check that emits `AUTH_PERMISSION_DENIED`
- `audit_event_taxonomy.md` — canonical event catalogue entry for `SECURITY_RLS_DENY_DETECTED`
- Block 02 Phase 04 — `auth.role_on_business()` helper and session GUC setup
- Block 05 Phase 02 — `emitAudit()` function and audit log schema
