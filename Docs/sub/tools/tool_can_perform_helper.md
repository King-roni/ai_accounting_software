# tool: auth.can_perform

**Category:** Tools · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

`auth.can_perform` is the canonical application-layer permission check. Every tool that writes data, transitions state, or reads restricted surfaces calls `auth.can_perform` before proceeding. It is a READ_ONLY tool: it never writes run state and never alters any database row. When the check returns `allowed: false`, it emits `AUTH_PERMISSION_DENIED` to the audit log.

---

## Tool registration

```ts
engine.registerTool({
  name: "auth.can_perform",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_auth_can_perform#v1.input",
  output_schema_ref: "tool_auth_can_perform#v1.output",
  audit_events: ["AUTH_PERMISSION_DENIED"],
  description_ref: "Docs/sub/tools/tool_can_perform_helper.md",
});
```

---

## Signature

```ts
auth.can_perform({
  user_id:     string,   // UUID v7 — the user making the request
  business_id: string,   // UUID v7 — the tenant context
  surface:     PermissionSurface,
  operation:   "READ" | "WRITE" | "DELETE" | "APPROVE",
}) → {
  allowed:  boolean,
  reason?:  string,      // present only when allowed = false
}
```

The `reason` field is a machine-readable code, not a human-readable message. Callers must not display `reason` directly to end users. It is included in the `AUTH_PERMISSION_DENIED` audit payload and is available for programmatic branching in tool orchestration logic.

---

## Permission surface enum

Thirteen canonical surfaces. The string values are stored in the `permission_surfaces` enum type in Postgres.

| Surface | Description |
| --- | --- |
| `workflow_run` | Creating, pausing, resuming, or cancelling workflow runs |
| `transaction` | Reading and writing `transactions` rows, including tag application |
| `invoice` | Creating, amending, voiding, or reading `invoices` rows |
| `document` | Uploading, reading, or dismissing `documents` rows |
| `ledger_entry` | Reading `ledger_entries` and `vat_entries`; manual override is a separate check |
| `bank_upload` | Uploading bank statement files via the intake pipeline |
| `vendor_memory` | Reading and writing `vendor_memory` rows |
| `counterparty` | Reading and writing `counterparties` rows |
| `review_issue` | Viewing, resolving, dismissing, or snoozeing `review_issues` |
| `archive` | Reading from the finalized archive zone; write access is internal-only |
| `report` | Generating and downloading report exports |
| `admin_settings` | Modifying business-level configuration, AI config, and rate limits |
| `audit_log` | Reading audit log entries via the dashboard or API |

Any surface string not in this list causes `auth.can_perform` to throw `SURFACE_UNKNOWN`. Adding a surface requires an amendment to this file and to `permission_matrix.md`.

---

## Role-to-surface matrix (summary)

The full matrix lives in `permission_matrix.md`. This table records the common-case grant pattern only; exceptions and operation-level overrides are in the full matrix.

| Role | Granted surfaces (default READ + WRITE unless noted) |
| --- | --- |
| Owner | All 13 surfaces |
| Admin | All except `audit_log` (READ only) and `admin_settings` (READ only) |
| Bookkeeper | `transaction`, `invoice`, `document`, `bank_upload`, `vendor_memory`, `counterparty`, `review_issue`, `ledger_entry` (READ only) |
| Accountant | `transaction` (READ), `invoice` (READ), `ledger_entry` (READ), `report` (READ), `archive` (READ), `audit_log` (READ) |
| Reviewer | `review_issue` (WRITE), `transaction` (READ), `invoice` (READ) |
| Read-only | `transaction` (READ), `invoice` (READ), `document` (READ) |

---

## Error shapes

Three distinct error outcomes; each has different caller semantics:

### `PERMISSION_DENIED` — returns `allowed: false`

The check resolved a role for the `(user_id, business_id)` pair and the role does not grant the requested surface + operation. This is the normal denial path.

Return value:
```json
{ "allowed": false, "reason": "PERMISSION_DENIED" }
```

The caller receives `allowed: false` and must branch accordingly. No exception is raised. `AUTH_PERMISSION_DENIED` is emitted with `surface`, `operation`, `user_id`, `business_id`, and `reason` in the payload.

### `SURFACE_UNKNOWN` — throws

The `surface` value is not in the enum. This is a programming error, not a runtime access-control decision. `auth.can_perform` throws with code `SURFACE_UNKNOWN`. No audit event is emitted (the caller code must be corrected; an audit trail of programming errors adds noise).

Callers must validate the surface value at the call site. Lint tooling in `tool_naming_convention_policy` enforces that `auth_events` array references are checked against the canonical surface list at CI time.

### `USER_SUSPENDED` — throws

`users.is_active = false` for the given `user_id`. The session should have been invalidated at login time, but this guard catches cases where a session token was issued before deactivation. Throws with code `USER_SUSPENDED`. No `AUTH_PERMISSION_DENIED` is emitted; the suspension is already recorded via `USER_DEACTIVATED`. Callers must propagate this error up to the request boundary, which must return HTTP 403 with `error: "USER_SUSPENDED"`.

---

## Audit integration

When `allowed = false` via the `PERMISSION_DENIED` path, `auth.can_perform` emits `AUTH_PERMISSION_DENIED` before returning.

**Event:** `AUTH_PERMISSION_DENIED`
**Severity:** MEDIUM
**Chain:** business chain

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `user_id` | uuid | The requesting user |
| `business_id` | uuid | The tenant context |
| `surface` | text | The permission surface that was checked |
| `operation` | text | `READ`, `WRITE`, `DELETE`, or `APPROVE` |
| `role_at_check` | text | The role resolved for `(user_id, business_id)` at check time |
| `reason` | text | Always `PERMISSION_DENIED` on this path |

The `USER_SUSPENDED` and `SURFACE_UNKNOWN` error paths do not emit this event. The `USER_DEACTIVATED` event (Block 02) is the record of suspension; `SURFACE_UNKNOWN` is a code defect, not a runtime access event.

`auth.can_perform` emits the audit event inside a separate short transaction per `audit_log_policies` Section 4 lock semantics. Audit emission failure does not propagate to the caller — the permission check result is returned regardless.

---

## Side-effect contract

`auth.can_perform` is `READ_ONLY | WRITES_AUDIT`. It performs the following reads:

1. `user_sessions` — verifies the session is active and not expired
2. `tenancy_role_grants` — resolves the active role for `(user_id, business_id)`
3. `users` — checks `is_active`

It writes exclusively to the audit log via `emitAudit()`. It never writes to `workflow_runs`, `transactions`, or any other operational table.

Callers that run `auth.can_perform` inside a serializable transaction must be aware that the audit write happens in a separate transaction (the emit is out-of-band). The permission check result itself does not depend on the audit write succeeding.

---

## Usage pattern

```ts
const { allowed, reason } = await auth.can_perform({
  user_id:     ctx.user_id,
  business_id: ctx.business_id,
  surface:     "invoice",
  operation:   "WRITE",
});

if (!allowed) {
  // reason is safe to log internally; do not expose to client
  throw new PermissionError({ code: "PERMISSION_DENIED", surface: "invoice" });
}
```

Callers must not cache the result of `auth.can_perform` across requests. Role grants can change (e.g., `TENANCY_ROLE_REVOKED`) between calls; stale cached results would silently bypass the check.

---

## Mobile

`auth.can_perform` is an internal permission check invoked before every write operation; it is not directly callable by clients. Mobile write rejection is enforced upstream at the API gateway layer per `mobile_write_rejection_endpoints.md` before `auth.can_perform` is ever invoked for a mobile client attempting a write.

## Cross-references

- `rls_deny_audit_pattern_policy.md` — database-layer RLS denial capture; complements this application-layer check
- `permission_matrix.md` — full role × surface × operation grant table
- `audit_event_taxonomy.md` — canonical entry for `AUTH_PERMISSION_DENIED`
- `tenancy_schema_definition.md` — `tenancy_role_grants` table and role enum
- Block 02 Phase 04 — role resolution helpers and session GUC setup
- Block 05 Phase 02 — `emitAudit()` function
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy; enforced at API gateway layer before this tool is invoked
