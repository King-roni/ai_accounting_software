# Security Incident Response Policy

**Category:** Policies · **Owning block:** 11 — Security & Compliance · **Stage:** 4 sub-doc (Layer 2)

This policy defines how the platform detects, classifies, and responds to security incidents. It covers incident types, detection sources, severity classification, response procedures, GDPR notification requirements, and post-incident documentation obligations.

---

## 1. Incident Types

The following categories of security incidents are in scope for this policy:

| Type | Description |
|---|---|
| Data breach | Unauthorised access to, or exfiltration of, personal data or business-confidential data. |
| Unauthorised access | A party gains access to a resource or tenant without valid authorisation. |
| Key compromise | A signing key, encryption key, service account key, or API key is exposed or used by an unauthorised party. |
| DDoS | Distributed denial-of-service attack targeting the platform's API or web frontend. |
| Insider threat | A current or former employee, contractor, or service account misuses access privileges. |
| Supply chain compromise | A third-party dependency or integration is used as a vector to reach platform data. |

Incidents outside this list are escalated to the Security Lead for ad hoc classification.

---

## 2. Detection Sources

Security incidents may be detected via any of the following:

- **Audit log anomalies** — automated rules scanning `audit_logs` for unusual access patterns (e.g. bulk record reads by a single user, cross-tenant query attempts).
- **Rate limit breaches** — repeated violations of rate limits configured in `rate_limit_configuration_policy.md`, particularly on authentication endpoints.
- **Failed MFA spikes** — a sudden increase in `MFA_CHALLENGE_FAILED` audit events for one or more users, indicating a credential-stuffing or targeted attack.
- **Alert rule triggers** — `alert_rule_configuration_schema.md` conditions firing for security-relevant events.
- **External reports** — vulnerability disclosure reports, law enforcement contacts, or reports from affected users.
- **Vendor notifications** — security advisories from Supabase, cloud providers, or integrated third-party services.

All detection sources route to the incident tracking queue. False positives are documented and closed; confirmed incidents proceed to classification.

---

## 3. Severity Classification Matrix

| Severity | Label | Definition |
|---|---|---|
| SEV-1 | Confirmed breach | Personal data or business data has been accessed or exfiltrated by an unauthorised party. Active exploitation confirmed. |
| SEV-2 | Suspected breach | Strong indicators of unauthorised access but not yet confirmed. Exploitation may be ongoing. |
| SEV-3 | Attempted breach / anomaly | Detected attack attempt that was blocked or failed. No confirmed unauthorised access. Anomalous behaviour requiring investigation. |

Severity is assigned by the Security Lead at initial triage. Severity may be upgraded at any point during the investigation. Severity is never downgraded retroactively — if an incident was initially SEV-2 and later confirmed as SEV-1, the SEV-1 classification applies to the entire incident timeline.

---

## 4. Response Procedures

### 4.1 SEV-1: Confirmed Breach

1. **Immediate containment** — within 30 minutes of confirmation: revoke affected credentials, block affected user sessions, disable affected API keys.
2. **Notify** — Security Lead, CTO, DPO, and `org:owner` of any affected business entities within 1 hour.
3. **Preserve** — do not delete any log entries, database rows, or audit records. See Section 6.
4. **Isolate** — quarantine affected systems or tenant data if technically feasible without destroying evidence.
5. **GDPR notification** — if personal data is involved, initiate DPA notification procedure (Section 5) within 72 hours of discovery.
6. **Legal hold** — notify legal counsel. All affected data is placed under legal hold; no routine retention deletions may run during the hold period.
7. **Incident record** — create a formal incident record (Section 7) immediately.

### 4.2 SEV-2: Suspected Breach

1. **Immediate investigation** — Security Lead begins forensic review within 2 hours of classification.
2. **Provisional containment** — revoke suspect credentials, increase audit logging verbosity for affected resources.
3. **Notify** — Security Lead and CTO within 2 hours. DPO notified if personal data is plausibly in scope.
4. **Preserve** — no log deletions. Audit records frozen for affected scope.
5. **Status updates** — Security Lead provides hourly updates until resolved or upgraded to SEV-1.
6. **Resolution** — confirmed as SEV-1 (upgrade) or downgraded to SEV-3 with full justification.

### 4.3 SEV-3: Attempted Breach / Anomaly

1. **Investigation** — assigned engineer investigates within 24 hours.
2. **Monitoring enhancement** — alert rules tightened for the detected pattern.
3. **Notify** — Security Lead via incident ticket. No executive notification required unless pattern escalates.
4. **Close** — closed with documented findings within 5 business days.

---

## 5. GDPR Breach Notification

If a confirmed or suspected breach (SEV-1 or SEV-2) involves personal data of EU residents, the following GDPR obligations apply:

- **DPA notification** — the Cyprus Data Protection Authority (DPA) must be notified within **72 hours** of discovery of the breach. If notification cannot be made within 72 hours, a partial notification is submitted with a reason for delay. The notification must include: nature of the breach, categories and approximate number of data subjects affected, name and contact of the DPO, likely consequences, and measures taken or proposed.
- **Data subject notification** — if the breach is likely to result in a high risk to data subjects (identity theft, financial loss, discrimination), affected individuals must be notified without undue delay.
- **Documentation** — all breaches (including those not notified to the DPA) must be documented in the internal breach register maintained by the DPO.

The DPO owns the GDPR notification procedure. The Security Lead provides technical facts; the DPO drafts the formal notification.

---

## 6. Forensics Preservation

During any active security incident investigation, the following must not be deleted, modified, or truncated:

- `audit_logs` rows within the scope of the incident.
- `hash_chain_schema.md` entries for the affected scope.
- Application server logs, database query logs, and network access logs.
- Row-level history for any tables in scope (if point-in-time recovery is available, a recovery point must be captured immediately).

Automated data retention jobs that would delete in-scope data are suspended for the duration of the legal hold or investigation, whichever is longer. The DPO and Security Lead must jointly approve resumption of retention jobs after an incident is closed.

Evidence preservation is not optional and is not negotiable regardless of storage cost or operational impact.

---

## 7. Post-Incident Documentation

Every security incident, regardless of severity, must produce a closed incident record containing:

- Incident ID (UUID).
- Discovery timestamp and source.
- Initial severity classification and basis.
- Final severity classification (if changed).
- Timeline of events (detection, containment, notification, resolution).
- Root cause analysis.
- Data affected (categories, approximate count of records, approximate count of data subjects if applicable).
- Actions taken during response.
- Remediation measures implemented.
- Recommendations to prevent recurrence.
- Sign-off by Security Lead and DPO.

Incident records are retained for a minimum of 5 years. They are stored in the secure incident register, not in the platform's application database.

---

## 8. Related Documents

- `incident_response_policy.md` — operational incident response (non-security)
- `data_breach_response_runbook.md` — step-by-step breach response runbook
- `audit_log_schema.md` — audit log target for anomaly detection
- `hash_chain_schema.md` — tamper-evident audit chain
- `gdpr_data_subject_rights_policy.md` — data subject rights in breach context
- `gdpr_right_to_erasure_policy.md` — erasure restrictions during legal hold
- `data_retention_policy.md` — retention jobs suspended during incidents
- `security_alert_routing_policy.md` — how security alerts reach the incident queue
- `mfa_policy.md` — MFA enforcement relevant to access breach scenarios
- `encryption_at_rest_policy.md` — encryption state relevant to data breach severity assessment
