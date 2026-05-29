# Security Alerting Internal Reference

**Category:** Reference · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

Internal reference for security alert routing, escalation paths, and on-call obligations. This
document is used by the on-call engineer, the alert routing configuration, and any tooling that
dispatches alerts based on audit event severity.

---

## Section 1 — Alert channels

Security alerts route to two channels depending on severity.

| Severity | Slack channel | PagerDuty |
| --- | --- | --- |
| HIGH | `#security-alerts` | P2 — acknowledged within 1 hour |
| BLOCKING | `#security-alerts` | P1 — acknowledged within 15 minutes |

BLOCKING-severity events additionally page the on-call engineer directly as a P1 incident.
The P1 page is sent regardless of time of day or existing active incidents.

LOW and MEDIUM severity audit events do not trigger real-time alerts. They are queryable via the
audit log and feed into the scheduled anomaly detection job (Stage 2+). If an automated rule
detects a pattern of MEDIUM events that exceeds a threshold, the rule may escalate to HIGH and
trigger the HIGH alert path.

---

## Section 2 — Alert event sources

The `security_alert_routing_policy` subscribes to the audit log's event stream for any event with
`severity IN ('HIGH', 'BLOCKING')`. The routing policy is not configured per-event; it fires on
any event in that severity range unless the event is suppressed per Section 5.

The event stream is the Supabase Realtime channel on `audit_log` filtered to HIGH and BLOCKING
rows. The routing consumer processes each event within 30 seconds of the INSERT commit under
normal conditions.

---

## Section 3 — Alert payload structure

Every alert dispatch carries the following payload. The payload is delivered as a structured JSON
body to both Slack and PagerDuty.

```json
{
  "event_name": "<DOMAIN_PAST_VERB>",
  "severity": "HIGH | BLOCKING",
  "business_id": "<uuid>",
  "user_id": "<uuid | null>",
  "occurred_at": "<timestamptz ISO 8601>",
  "run_id": "<uuid | null>",
  "alert_id": "<uuid>",
  "payload_excerpt": { }
}
```

`payload_excerpt` contains at most 512 bytes of the raw audit event payload. If the full payload
exceeds 512 bytes, it is truncated at a field boundary. The full payload is always retrievable
from the audit log via `event_id`.

`user_id` is included when the triggering event has an identifiable actor. System-generated events
(background jobs, engine operations) may have `user_id = null`.

`business_id` is always present for business-scoped events. Global and org-scoped events carry
`business_id = null` with `organization_id` in the payload excerpt.

---

## Section 4 — Rate limiting and deduplication

Duplicate alerts for the same `event_name + business_id` combination are deduplicated within a
5-minute rolling window. The deduplication window prevents alert storms during high-frequency
anomaly conditions.

Within the window, only the first alert is dispatched to Slack and PagerDuty. Subsequent matching
events are counted and appended to the first alert's thread as a suppression summary: "N additional
events suppressed in the last 5 minutes."

The deduplication window does not apply to BLOCKING-severity events. Every BLOCKING event
dispatches a separate P1 page regardless of prior alerts in the window. The Slack message for
subsequent BLOCKING events within the window is de-noised (threaded under the original message),
but the PagerDuty page fires each time.

---

## Section 5 — Alert suppression

Test and staging environments route all alerts to `#security-alerts-staging`. PagerDuty is never
paged from a non-production environment.

Environment detection uses the `DEPLOYMENT_ENV` variable set in the Supabase project configuration.
If `DEPLOYMENT_ENV` is absent or has an unrecognised value, alerts route as if production. This
fail-open approach ensures that misconfigured deployments do not silently drop security alerts.

Suppression rules in production are not permitted. Any proposal to suppress a specific HIGH or
BLOCKING event in production requires an amendment to this document and a sign-off in
`decisions_log.md`.

---

## Section 6 — Events that always alert

The following HIGH events trigger an alert on every occurrence, regardless of deduplication window
state. They are individually enumerated because they represent conditions that should never be
routine:

| Event | Severity | Alert reason |
| --- | --- | --- |
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | HIGH | Max step-up failures indicate a brute-force attempt on a privileged action |
| `AUTH_RLS_BYPASS_DETECTED` | HIGH | RLS bypass in a client path is a class-A misconfiguration |
| `SECURITY_HASH_CHAIN_TAMPER_DETECTED` | HIGH | Audit chain integrity is a core trust guarantee |
| `SECURITY_GATEWAY_BYPASS_DETECTED` | HIGH | Tool invocations outside the gateway violate the execution contract |

These events are excluded from the 5-minute deduplication window. Each occurrence generates a
new Slack message and a new PagerDuty incident.

---

## Section 7 — Incident response obligations

### P1 (BLOCKING severity)

- On-call engineer acknowledges the PagerDuty incident within 15 minutes.
- Within 30 minutes: initial triage posted to the `#security-alerts` Slack thread.
- Within 2 hours: a written incident summary is created in the incident tracking system.
- Escalation: if no acknowledgement within 15 minutes, PagerDuty automatically escalates to the
  secondary on-call.

### P2 (HIGH severity)

- On-call engineer acknowledges within 1 hour during business hours (09:00–18:00 EET).
- Outside business hours: acknowledgement within 2 hours.
- Within 4 hours of acknowledgement: initial triage posted to the Slack thread.

---

## Section 8 — No auto-remediation

The alerting system is informational. No automated action — account suspension, run cancellation,
data deletion — is triggered by an alert. Remediation is performed by the on-call engineer after
triage.

This constraint is deliberate: automated remediation based on security events can itself be
weaponised as a denial-of-service vector. Any future auto-remediation proposal requires a threat
model review and an amendment to this document.

---

## Cross-references

- `security_alert_routing_policy.md` — routing configuration and consumer implementation
- `audit_event_taxonomy.md` — full catalogue of HIGH and BLOCKING events
- `audit_log_policies.md` — severity definitions and audit chain structure
