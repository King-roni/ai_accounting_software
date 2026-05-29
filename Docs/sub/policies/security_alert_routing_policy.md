# Security Alert Routing Policy

**Category:** Policies · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

Binding rules governing how security alerts are routed, notified, and escalated after creation. The `security.raise_alert` tool owns alert creation and deduplication. All routing logic is applied inside that tool before the alert row is committed. No external code may create `security_alerts` rows directly — all inserts go through `security.raise_alert`.

---

## Section 1 — Severity routing tiers

Severity determines the notification path. The closed severity set is `{MEDIUM, HIGH, BLOCKING}` — LOW conditions do not generate alert rows.

### MEDIUM

- A `security_alerts` row is created with `severity = MEDIUM`.
- The alert is surfaced in the Owner/Admin security dashboard for the affected business on their next login.
- **No immediate notification is dispatched.** MEDIUM alerts aggregate in the dashboard view; they do not trigger email or webhook.
- Applicable to repeated-denial patterns, off-hours secret access anomalies, and low-frequency `WORKFLOW_RUN_STALLED` occurrences.

### HIGH

- A `security_alerts` row is created with `severity = HIGH`.
- An **email notification** is sent immediately to all active Owners of the affected business via `transactional_email_service_integration`.
  - "Active Owners" means `business_user_roles` rows with `role = 'OWNER'` and `status = 'ACTIVE'`.
  - The email is dispatched within the same logical operation as the row creation; failure to dispatch does not block alert creation (email dispatch is fire-and-forget with audit trail).
- The alert is also surfaced in the Owner/Admin dashboard.
- Applicable to: `CROSS_TENANT_ACCESS_ATTEMPT`, `WORKFLOW_RUN_STALLED`, `GATEWAY_BYPASS_DETECTED`, `FAILED_LOGIN_SPIKE`, `OBJECT_LOCK_VIOLATION_DETECTED`.

### BLOCKING

- A `security_alerts` row is created with `severity = BLOCKING`.
- An **email notification** is sent to all active Owners of the affected business (same as HIGH path).
- A **platform admin webhook** is additionally triggered. The webhook payload includes the `alert_id`, `alert_type`, `business_id`, `description`, and `created_at`. Platform admin must acknowledge BLOCKING alerts within the incident SLA.
- BLOCKING alerts additionally **halt any pending finalization run** for the affected business until the alert is acknowledged by an Owner or Admin. This prevents finalizing a period whose data integrity is under investigation.
- Applicable to: `AUDIT_HASH_CHAIN_MISMATCH`, `CHAIN_VERIFICATION_FAILED`, `DECISION_THROWS`.

---

## Section 2 — Cross-tenant alert routing

Platform-level alerts (`business_id IS NULL`) are routed to **platform admin only**, regardless of severity. No business-level Owner or Admin is notified.

A cross-tenant alert is any alert with `alert_type` in `{CROSS_TENANT_ACCESS_ATTEMPT}` or any alert created by the access-control runtime where the actor's session is not scoped to a single business. Such alerts always carry `business_id = NULL` and go directly to the platform admin webhook (for HIGH and BLOCKING) or the platform admin dashboard (for MEDIUM).

The email path for cross-tenant alerts targets the platform ops email address, not a business Owner.

---

## Section 3 — Deduplication

### Rule

Identical alert tuples within a rolling 1-hour window are deduplicated. Two alerts are considered identical if they share the same `(business_id, alert_type, workflow_run_id)` tuple.

### Deduplication behaviour

When `security.raise_alert` is called and an existing `OPEN` or `ACKNOWLEDGED` `security_alerts` row matches the dedup tuple and `created_at > now() - interval '1 hour'`:

1. No new row is created.
2. The existing row's `duplicate_count` is incremented by 1.
3. No additional notification is dispatched for the deduplicated occurrence.
4. `SECURITY_ALERT_DEDUPLICATED` is emitted per `audit_event_taxonomy`.

When `workflow_run_id` is NULL (alert not tied to a specific run), deduplication matches on `(business_id, alert_type)` within the 1-hour window.

### Acknowledged alerts

An alert in `ACKNOWLEDGED` status **does not suppress new occurrences of the same type**. Once the dedup window expires (1 hour from the original alert's `created_at`), a new alert row is created for a subsequent occurrence. Acknowledgement is not treated as resolution; the same condition can recur and create a new alert.

A `RESOLVED` alert row never participates in deduplication — resolution closes the record permanently. A new occurrence after resolution creates a fresh alert row.

---

## Section 4 — Alert creation tool

`security.raise_alert` is the **sole authorised path** for creating `security_alerts` rows. This tool:

1. Validates that `alert_type`, `severity`, and `description` are non-empty.
2. Runs the deduplication check (Section 3).
3. Inserts the alert row if not deduplicated, or increments `duplicate_count` if deduplicated.
4. Routes notifications per Section 1–2.
5. Emits `SECURITY_ALERT_CREATED` (HIGH) or `SECURITY_ALERT_DEDUPLICATED` (LOW) per the outcome.

Tool registration:
```
Side-effect class: WRITES_RUN_STATE | WRITES_AUDIT | EXTERNAL_CALL
AI tier: NONE
Block namespace: security
```

`EXTERNAL_CALL` is declared because the HIGH and BLOCKING notification paths invoke `transactional_email_service_integration` and the platform admin webhook.

---

## Section 5 — Acknowledgement

Acknowledgement transitions `status` from `OPEN` to `ACKNOWLEDGED`. Permitted roles: Owner and Admin for business-scoped alerts; platform admin for cross-tenant alerts.

Acknowledgement:
1. Sets `acknowledged_by_user_id` and `acknowledged_at` on the row.
2. Emits `SECURITY_ALERT_ACKNOWLEDGED` per `audit_event_taxonomy`.
3. Does not suppress future occurrences (Section 3).
4. For BLOCKING alerts: acknowledgement by Owner or Admin lifts the finalization hold (if the alert condition has been investigated and deemed safe to proceed).

### Mobile

Acknowledgement is a write operation. Mobile clients are rejected at the acknowledgement endpoint per `mobile_write_rejection_endpoints.md`. An Owner or Admin on mobile may read alerts (SELECT is permitted) but must use a non-mobile client to acknowledge.

---

## Section 6 — Resolution

Resolution transitions `status` to `RESOLVED`. Permitted roles: same as acknowledgement.

Resolution requirements:
1. A non-empty `resolution_note` is required — the CHECK constraint on `security_alerts` enforces this at the database level.
2. `resolved_at` is set.
3. Emits `SECURITY_ALERT_RESOLVED` (MEDIUM) per `audit_event_taxonomy`. Payload includes `alert_id`, `alert_type`, `business_id`, `resolved_by_user_id`, `resolution_note`, `resolved_at`.

A `RESOLVED` alert is permanently closed. The row is retained for audit trail purposes and is never hard-deleted. Resolution does not suppress new occurrences; new occurrences generate fresh alert rows.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `SECURITY_ALERT_CREATED` | New alert row inserted by `security.raise_alert` | HIGH |
| `SECURITY_ALERT_DEDUPLICATED` | Existing alert's `duplicate_count` incremented | LOW |
| `SECURITY_ALERT_ACKNOWLEDGED` | Status transitions to `ACKNOWLEDGED` | MEDIUM |
| `SECURITY_ALERT_RESOLVED` | Status transitions to `RESOLVED` | MEDIUM |

---

## Cross-references

- `alert_schema` — `security_alerts` table definition; severity enum; status enum; dedup fields
- `audit_log_policies` — `SECURITY` domain naming convention; severity enum `{LOW, MEDIUM, HIGH, BLOCKING}`
- `audit_event_taxonomy` — `SECURITY_ALERT_CREATED` (HIGH), `SECURITY_ALERT_RESOLVED` (MEDIUM) catalogue entries
- `transactional_email_service_integration` — email dispatch for HIGH and BLOCKING alerts
- `cross_tenant_alerting_runbook` — investigation procedure for cross-tenant alerts
- `tool_naming_convention_policy` — `security.raise_alert` registration shape and side-effect class
- `mobile_write_rejection_endpoints.md` — write-surface rejection for acknowledgement and resolution on mobile
- `Docs/phases/05_security_and_audit/10_security_alerting_internal.md` — owning phase (alert rules engine, routing channels, on-call integration)
