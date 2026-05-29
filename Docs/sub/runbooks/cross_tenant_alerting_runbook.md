# cross_tenant_alerting_runbook

**Category:** Runbooks · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block runbook)

The operator-facing procedure for cross-tenant security alerts — alerts whose scope spans multiple businesses or whose triggering condition is infrastructure-level. Per Stage 1: "Security alerting: Internal-only in MVP (ops/security channel). User-facing alerts deferred."

The runbook lives between the alert dispatch (per `alert_rule_configuration_schema`) and the operator investigation. It pins which alert classes trigger cross-tenant routing, escalation thresholds, and audit recording.

---

## Alert classes routing to this runbook

| Alert class | Trigger condition | Severity |
| --- | --- | --- |
| `cross_business_actor_anomaly` | Same actor (user_id) failing auth in N≥3 businesses within 1 hour | HIGH |
| `vault_kek_access_failure` | Vault returning errors on KEK retrieval across multiple businesses | BLOCKING |
| `audit_chain_divergence_storm` | More than 3 `AUDIT_CHAIN_DIVERGENCE_DETECTED` events in 15 minutes across the global chain | HIGH |
| `tsa_cascading_failure` | All RFC 3161 TSAs returning errors over a 30-minute window | HIGH |
| `mass_decryption_anomaly` | A single actor triggering > 100 `FIELD_DECRYPTED` events in 1 minute | HIGH |
| `cross_business_login_anomaly` | Same source IP attempting auth in N≥5 businesses (potential credential stuffing) | HIGH |
| `analytics_refresh_cascading_failure` | > 5 `ANALYTICS_REFRESH_FAILED` events in 1 hour across businesses | MEDIUM |
| `object_lock_violation_multi_business` | More than one `OBJECT_LOCK_VIOLATION_DETECTED` event in 1 hour | BLOCKING |

The thresholds (N, time windows) are configured in `alert_rules` per `alert_rule_configuration_schema` (Schemas, Block 05).

## Routing

All alerts route to the **ops security channel** (Slack / PagerDuty / equivalent — Stage 4 sub-doc selection). Per Stage 1: user-facing alerts are deferred to post-MVP.

Per-business operators (Owner / Admin) are NOT directly notified — these alerts indicate infrastructure or cross-tenant concerns that require operator-level investigation before any user-side disclosure.

The dispatch destination is configured via `secrets_management` per Block 05 Phase 07 — webhook URL stored encrypted, decrypted at dispatch time.

## Step 1 — Receive the alert

Alert payload shape (per `alert_rule_configuration_schema`):

```json
{
  "alert_id": "<uuid>",
  "alert_class": "cross_business_actor_anomaly",
  "severity": "HIGH",
  "rule_id": "<uuid>",
  "triggering_events": ["<event_id_1>", "<event_id_2>", "<event_id_3>"],
  "affected_business_ids": ["<bid_1>", "<bid_2>", "<bid_3>"],
  "summary": "Actor <user_id> failed auth in 3 businesses within 1 hour",
  "first_event_at": "2026-01-15T09:00:00Z",
  "last_event_at": "2026-01-15T09:42:00Z",
  "dedup_window_started_at": "2026-01-15T08:30:00Z",
  "rule_version": "1.4.0"
}
```

The `triggering_events` are full event IDs from `audit_log` — operator can re-fetch full event detail for investigation.

## Step 2 — Investigate per class

### `cross_business_actor_anomaly`

```sql
-- Identify the actor's recent activity
SELECT business_id, event_type, event_payload, appended_at
FROM audit_log
WHERE actor_user_id = $user_id
  AND appended_at >= $first_event_at - INTERVAL '1 hour'
  AND event_type IN ('LOGIN_FAILED', 'STEP_UP_FAILED', 'ACCESS_DENIED')
ORDER BY appended_at DESC
LIMIT 100;
```

Patterns to look for:
- **Credential stuffing:** distinct IPs per business, brief intervals — likely external attack
- **Legitimate cross-business operator:** same IP, gaps between attempts (typing password wrong on different accounts) — likely the Owner managing multiple businesses

If credential stuffing: temporarily disable the user's sessions across all businesses via `session_revoke_all_user_sessions(user_id)`; notify the user via `transactional_email_service_integration` (security-class email — not opt-out-able).

### `vault_kek_access_failure`

```sql
-- How widespread is the failure
SELECT business_id, count(*) AS failure_count
FROM audit_log
WHERE event_type IN ('KEY_ACCESS_DENIED', 'KEY_ACCESS_FAILED')
  AND appended_at >= now() - INTERVAL '15 minutes'
GROUP BY business_id;
```

If many businesses affected: likely Vault outage. Engage Vault provider runbook. The system enters degraded mode — decryption-requiring operations fail with `KEY_UNAVAILABLE` per `audit_log_policies`. Workflows that don't require decryption continue.

### `tsa_cascading_failure`

Per `rfc_3161_timestamp_integration`: TSA failures don't block chain advancement; anchoring is best-effort. The alert is informational. Operator action: verify TSA outage with vendor; fall through to backup TSA if primary; document remediation in `key_rotation_runbook` follow-up.

### `object_lock_violation_multi_business`

Per `archive_promotion_failure_runbook` Step 3: any single instance is BLOCKING for that business. Multi-business instances suggest systematic issue (Storage configuration drift, infrastructure compromise, or cascading code bug).

Procedure:
1. Halt the affected businesses (via `business_settings.global_halt = true`)
2. Engineering escalation immediate
3. Verify Object Lock attribute values across affected bundles
4. If real tampering: legal escalation per Cyprus regulator notification requirements

## Step 3 — Audit the investigation

Operators MUST record their investigation in the audit log via `audit_investigation_recorded`:

```ts
emitAudit("SECURITY_INVESTIGATION_RECORDED", {
  alert_id,
  investigated_by_operator: $operator_email,
  finding_classification: "FALSE_POSITIVE" | "CONFIRMED_THREAT" | "INFRASTRUCTURE_ISSUE" | "OPERATIONAL_ERROR",
  remediation_action: "...",
  affected_business_ids: [...],
  investigation_started_at,
  investigation_completed_at
});
```

The audit trail is part of the system's own integrity — investigations are themselves auditable.

## Step 4 — Dedup window management

Per `alert_deduplication_policy` (now part of `audit_log_policies` cross-references): within the dedup window, repeated triggering events extend the window but do NOT re-dispatch the alert. The operator sees one alert covering the full burst.

If the alert is investigated and resolved before the dedup window closes, the operator marks the alert resolved; subsequent triggering events within the window may emit a fresh alert if escalation thresholds are exceeded.

## Escalation thresholds

| Threshold | Trigger | Action |
| --- | --- | --- |
| Single alert | Per the rule | Ops investigates per this runbook |
| 3 alerts in 1 hour (same class) | Cumulative | Engineering paged |
| 1 BLOCKING alert | Immediate | Engineering + legal paged |
| 5 alerts across classes in 1 hour | Infrastructure-level concern | All-hands |

## Audit events emitted by the runbook

| Event | When |
| --- | --- |
| `SECURITY_ALERT_RAISED` | Initial alert dispatch (per `audit_event_taxonomy`) |
| `SECURITY_ALERT_DEDUPLICATED` | Triggering event within dedup window |
| `SECURITY_INVESTIGATION_RECORDED` | Operator records investigation outcome |

## Cross-references

- `alert_rule_configuration_schema` (Block 05) — alert rules
- `alert_deduplication_policy` — dedup window per rule
- `audit_log_policies` — `SECURITY_*` event family
- `archive_promotion_failure_runbook` — sibling runbook
- `analytics_refresh_runbook` — sibling runbook
- `transactional_email_service_integration` — security-class email
- `key_rotation_runbook` — TSA + key rotation procedures
- `step_up_validity_window_policy` — step-up auth post-investigation
- Block 02 Phase 09 — role-change propagation (consumer of session_revoke)
- Block 05 Phase 02 — audit log + alert dispatch
- Block 05 Phase 10 — security alerting (architecture)
- Stage 1 decision — security alerting internal-only in MVP
