# Incident Response Policy

**Namespace:** security  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

This document defines how incidents are classified, who responds, response SLAs, communication channels, and post-incident requirements. It applies to all production environments and any environment handling real business entity data.

---

## Incident Severity Levels

### SEV-1 — Critical

Conditions that qualify:

- Confirmed or strongly suspected data breach involving personal data or financial records
- Full production outage: API returns 5xx for more than 5% of requests over a 5-minute window
- Authentication system unavailable
- Encryption key compromise or suspected key exposure
- Database unreachable or data loss detected

### SEV-2 — High

Conditions that qualify:

- Partial outage: one or more core features unavailable (e.g., bank feed ingestion, OCR pipeline, report generation) while others remain functional
- Data integrity issue: records written with incorrect values, mismatched ledger entries, or incorrect tax calculations affecting more than one business entity
- Significant performance degradation exceeding 10x baseline latency for more than 15 minutes
- Failed finalization run affecting a locked period
- Credential rotation failure for an active integration

### SEV-3 — Medium

Conditions that qualify:

- Degraded performance below SEV-2 threshold (2x–10x baseline latency)
- Non-critical feature unavailable (e.g., PDF export, dashboard charts)
- Background job failure affecting a single business entity without broader data risk
- Elevated error rates in non-critical endpoints

### SEV-4 — Low

Conditions that qualify:

- Cosmetic UI defects
- Minor copy or formatting errors
- Non-blocking edge case bugs with known workarounds
- Documentation inaccuracies

---

## Response SLAs

| Severity | Acknowledgement | Mitigation Target | Resolution Target |
|---|---|---|---|
| SEV-1 | 15 minutes | 2 hours | 8 hours |
| SEV-2 | 1 hour | 8 hours | 48 hours |
| SEV-3 | 4 hours | 48 hours | 10 business days |
| SEV-4 | 1 business day | Next sprint | Best effort |

**Acknowledgement** means an on-call engineer has confirmed the alert and begun investigation.  
**Mitigation** means the impact is contained or a workaround is in place even if root cause is not resolved.  
**Resolution** means root cause is fixed and systems are verified stable.

---

## On-Call Rotation

- On-call rotation is maintained as a weekly schedule in the internal incident management system.
- Primary on-call receives PagerDuty alert within 2 minutes of automated alerting threshold breach.
- If primary does not acknowledge within 5 minutes, escalation to secondary on-call fires automatically.
- A dedicated incident commander role is activated for SEV-1 incidents. The incident commander coordinates response but does not necessarily perform technical remediation.

---

## Communication Channels

### Internal

- **#incidents** Slack channel: all severity levels. Incident commander pins status updates every 30 minutes during active SEV-1/SEV-2 incidents.
- **#incidents-sev1** Slack channel: SEV-1 only. All engineers who are not directly responding should mute notifications; bridge is kept clear.
- Video bridge: opened by incident commander for SEV-1 and SEV-2 incidents within 15 minutes of acknowledgement.

### External (Customer-Facing)

- **Status page** (status.{domain}): updated within 30 minutes of SEV-1 acknowledgement and within 2 hours of SEV-2 acknowledgement.
- **In-app banner**: activated for outages affecting authenticated users. Managed via feature flag in per-business-toggle configuration.
- **Direct email notification**: sent to affected business entity contacts for SEV-1 incidents and any SEV-2 incident where data integrity is affected.

### Regulatory

- See GDPR Breach Notification section below.

---

## Incident Lifecycle

1. **Detection** — automated alert or manual report received.
2. **Triage** — on-call engineer assesses and assigns severity level.
3. **Declaration** — incident is formally declared in incident management system; incident channel created; stakeholders notified.
4. **Investigation** — root cause analysis begins.
5. **Mitigation** — impact is contained; workaround communicated if applicable.
6. **Resolution** — fix deployed, systems verified stable.
7. **Closure** — incident closed in tracking system; post-mortem scheduled if required.

---

## Post-Incident Review Requirements

### SEV-1 and SEV-2

A written post-mortem is required within **5 business days** of incident closure.

Post-mortem must include:

- Timeline of events (detection through resolution)
- Root cause (or best hypothesis if inconclusive)
- Contributing factors
- Impact: affected business entities, data rows, duration
- What worked well in the response
- Action items with owners and due dates (minimum one preventive action item)

Post-mortems are stored in the internal wiki under `/incidents/{year}/{incident-id}` and are blameless in tone.

### SEV-3 and SEV-4

A brief incident report (bullet-point format acceptable) is filed in the issue tracker. No formal post-mortem required unless the incident reveals a systemic issue.

---

## GDPR Breach Notification

Cyprus jurisdiction applies. The relevant supervisory authority is the **Commissioner for Personal Data Protection (CPDP)**, which serves as the DPA for Cyprus.

### Notification Trigger

A notification is required when a security incident involves a personal data breach (as defined under GDPR Article 4(12)) affecting EU data subjects.

### Timeline

- **72 hours** from the point at which the breach becomes known (not from when it occurred), a report must be filed with the Cyprus DPA.
- If the full scope of the breach is not known within 72 hours, a preliminary notification is filed with available information, followed by supplementary notifications as more facts emerge.

### Notification Content

Required elements per GDPR Article 33(3):

- Nature of the breach including categories and approximate number of data subjects affected
- Contact details of the Data Protection Officer (DPO)
- Likely consequences of the breach
- Measures taken or proposed to address the breach

### Data Subject Notification

If the breach is likely to result in a high risk to the rights and freedoms of affected individuals, those individuals must also be notified directly without undue delay per GDPR Article 34.

### Audit Event

Breach notifications are recorded as `SECURITY.GDPR_BREACH_NOTIFIED` audit events with the DPA reference number once received. Severity classification: BLOCKING.

---

## Related Documents

- `policies/security_alert_routing_policy.md` — Alert routing and escalation channels
- `policies/gdpr_data_subject_rights_policy.md` — GDPR rights fulfilment
- `policies/backup_and_recovery_policy.md` — Recovery procedures referenced during SEV-1 data loss
- `policies/audit_log_policies.md` — Audit log immutability requirements during incident investigation
- `reference/security_alerting_internal.md` — Internal alerting thresholds and PagerDuty integration
