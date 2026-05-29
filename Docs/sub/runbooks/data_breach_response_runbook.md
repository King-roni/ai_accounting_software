# Data Breach Response Runbook

**Block:** security
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook defines the response procedure for a personal data breach affecting the
platform and its business entity clients. All procedures align with GDPR Article 33
(notification to supervisory authority) and Article 34 (communication to data subjects).

A personal data breach means a breach of security leading to the accidental or unlawful
destruction, loss, alteration, unauthorised disclosure of, or access to, personal data
transmitted, stored, or otherwise processed.

The platform processes the following categories of personal data:
- Financial records (invoices, transactions, bank statements) tied to natural persons.
- Contact data (name, email, VAT number) for clients and business entity members.
- Audit log entries containing actor identifiers and IP addresses.
- Authentication credentials (hashed passwords, MFA secrets, session tokens).

Regulatory context: the platform is registered in Cyprus. The competent supervisory
authority is the Office of the Commissioner for Personal Data Protection (OCPDP).

---

## Step 1 — Detect and Confirm

### Event Classification

Upon receiving an alert, report, or anomaly, classify the event within 30 minutes:

| Classification       | Definition                                                                 |
|----------------------|----------------------------------------------------------------------------|
| Confirmed Breach     | Unauthorised access is confirmed by evidence (logs, attacker confirmation). |
| Suspected Breach     | Anomaly detected but causal access not yet confirmed.                       |
| False Alarm          | Investigation concludes no unauthorised access occurred.                    |

### Detection Sources

- Sentry: unusual volume of 401/403 responses from a single IP or session.
- Supabase Auth logs: anomalous session creation volume, logins from unexpected geographies.
- Supabase Database logs: bulk SELECT queries against `audit_events`, `documents`, or
  `business_entities` tables not matching any known background job.
- External report: affected user, security researcher, or third-party notification.

### Immediate Escalation (within 1 hour of detection)

Regardless of classification level, escalate immediately to:

- **DPO** (Data Protection Officer): [dpo@company.com] — responsible for GDPR assessment.
- **CTO**: [cto@company.com] — responsible for technical containment.
- **CEO**: notify if Confirmed Breach or Suspected Breach with high scope.

Create a private incident channel in Slack: `#incident-breach-YYYY-MM-DD`. All
investigation communication must occur in this channel for audit trail purposes.

Do NOT discuss the breach in public channels, external email, or with any party not on the
incident team until legal has been consulted.

### Audit Event to Write

```sql
INSERT INTO audit_events (
  id, event_type, severity, actor_id, business_entity_id,
  metadata, created_at
) VALUES (
  gen_uuid_v7(),
  'SECURITY_BREACH_DETECTED',
  'HIGH',
  '<detecting_actor_id_or_system>',
  NULL, -- platform-level event, not tenant-specific unless known
  jsonb_build_object(
    'classification', 'SUSPECTED_BREACH',
    'detection_source', 'sentry_alert',
    'incident_channel', '#incident-breach-2026-05-17',
    'escalated_to', ARRAY['dpo', 'cto']
  ),
  now()
);
```

---

## Step 2 — Contain

Containment must begin immediately upon Confirmed or Suspected Breach classification.
Do not wait for full scope assessment before containing.

### Revoke Compromised Sessions

Use the `auth.revoke_session` tool to invalidate specific sessions, or revoke all sessions
for a compromised account:

```bash
# Revoke all sessions for a specific user (via admin API)
curl -X DELETE "$SUPABASE_URL/auth/v1/admin/users/<user_id>/sessions" \
  -H "apikey: $SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY"
```

```sql
-- Confirm sessions are revoked
SELECT id, user_id, created_at, not_after
FROM auth.sessions
WHERE user_id = '<user_id>'
  AND not_after > now();
-- Should return 0 rows after revocation
```

### Isolate Affected Business Accounts

If the breach is scoped to specific business entities, set them to read-only or suspend:

```sql
UPDATE business_entities
SET is_suspended = true,
    suspension_reason = 'Security incident — pending investigation',
    updated_at = now()
WHERE id IN ('<business_entity_id_1>', '<business_entity_id_2>');
```

### Rotate Exposed Secrets

If API keys, webhook secrets, or OAuth client secrets were exposed, follow
`secrets_management_policy.md` for rotation procedure. Steps in brief:

1. Generate new secret in Supabase Vault or Vercel environment settings.
2. Update all references (Edge Functions, Vercel environment variables).
3. Invalidate the old secret.
4. Verify integrations resume normal operation before closing rotation step.

Do not reuse or archive the exposed secret value.

### Disable Affected Integrations

If the breach vector was an integration (bank feed, Google Drive, email provider):

```sql
UPDATE integrations
SET is_active = false,
    deactivation_reason = 'Security incident — breach containment',
    updated_at = now()
WHERE id = '<integration_id>';
```

---

## Step 3 — Assess Scope

Scope assessment must be completed before the 72-hour notification deadline. Start
immediately — do not wait for containment to finish.

### Dimensions to Assess

| Dimension                     | Questions to Answer                                                     |
|-------------------------------|-------------------------------------------------------------------------|
| Categories of data affected   | Financial data? PII? Auth credentials? Audit log?                       |
| Number of records              | Rows accessed or exfiltrated across affected tables.                    |
| Number of individuals          | Natural persons whose data was accessed (not just record count).        |
| Exfiltration vs access         | Was data copied/downloaded, or only read in-place?                      |
| Time window                    | Earliest and latest timestamp of unauthorised activity.                 |
| Attack vector                  | Stolen session? SQL injection? Compromised API key? Insider?            |

### Scope Assessment Queries

```sql
-- Identify all audit events in the suspected window from a suspicious actor
SELECT
  ae.event_type,
  ae.created_at,
  ae.actor_id,
  ae.business_entity_id,
  ae.metadata->>'ip_address' AS ip,
  ae.metadata->>'user_agent' AS user_agent
FROM audit_events ae
WHERE ae.actor_id = '<suspect_actor_id>'
  AND ae.created_at BETWEEN '<window_start>' AND '<window_end>'
ORDER BY ae.created_at ASC;

-- Count affected business entities and individuals
SELECT
  count(DISTINCT ae.business_entity_id) AS affected_entities,
  count(DISTINCT ae.actor_id) AS affected_actors
FROM audit_events ae
WHERE ae.metadata->>'ip_address' = '<attacker_ip>'
  AND ae.created_at BETWEEN '<window_start>' AND '<window_end>';
```

---

## Step 4 — Notify

### GDPR Article 33 — Supervisory Authority Notification

**Threshold:** any breach likely to result in a risk to the rights and freedoms of natural
persons must be notified to the OCPDP within 72 hours of becoming aware.

**Cyprus DPA Contact:**

Office of the Commissioner for Personal Data Protection
1 Iasonos Street, 1082 Nicosia, Cyprus
Email: commissioner@dataprotection.gov.cy
Phone: +357 22 818 456
Online notification form: https://www.dataprotection.gov.cy

**Article 33 Notification Template:**

```
Subject: Personal Data Breach Notification — [Company Name] — [Date]

1. Nature of the breach:
   [Describe what happened — unauthorised access, accidental disclosure, etc.]

2. Categories and approximate number of individuals concerned:
   [e.g., "Approximately 150 business clients, constituting natural persons as
   sole traders."]

3. Categories and approximate number of personal data records concerned:
   [e.g., "Invoice records and contact data — approximately 3,400 records."]

4. Name and contact details of the DPO:
   [DPO name, email, phone]

5. Likely consequences of the breach:
   [e.g., "Risk of targeted phishing using financial data; identity fraud risk."]

6. Measures taken or proposed to address the breach:
   [Containment steps taken; technical remediation planned.]
```

### GDPR Article 34 — Data Subject Notification

**Threshold:** high risk to rights and freedoms. High risk indicators:
- Financial data of natural persons was exfiltrated.
- Authentication credentials (even hashed) were accessed.
- More than 100 individuals affected.

**Data Subject Notification Template:**

```
Subject: Important Security Notice — Your Account Data

Dear [Name],

We are writing to inform you of a security incident that may have affected your
personal data held in [Platform Name].

What happened:
[Plain-language description — date range, type of access.]

What data was involved:
[Specific categories — e.g., invoices, contact information, transaction records.]

What we have done:
[Containment steps taken — session revocation, key rotation, etc.]

What you should do:
[Change password, enable MFA, monitor for suspicious activity on financial accounts.]

Contact:
If you have questions, contact our Data Protection Officer at [dpo@company.com]
or call [phone number].

[Company Name]
```

---

## Step 5 — Document and Remediate

### Incident Log

Maintain a running incident log in the private Slack channel and formalize it in a
breach register document. Required fields:

| Field                     | Value |
|---------------------------|-------|
| Incident ID               | BREACH-YYYY-MM-DD-NNN |
| Detection timestamp       | |
| Classification            | Confirmed / Suspected / False Alarm |
| DPO notified at           | |
| CTO notified at           | |
| Containment completed at  | |
| Scope: categories of data | |
| Scope: individuals affected | |
| OCPDP notified at         | |
| Data subjects notified at | |
| Root cause                | |
| Technical fix deployed at | |
| Post-mortem completed at  | |

### Evidence Preservation Checklist

- [ ] Do NOT delete or modify `audit_events` rows from the incident window.
- [ ] Export relevant `auth.sessions` and `auth.audit_log` entries to secure storage.
- [ ] Preserve Supabase and Vercel access logs from the incident window.
- [ ] Capture Sentry error payloads associated with the breach period.
- [ ] Record the full text of any anomaly alerts that triggered detection.
- [ ] Document all queries run during investigation with timestamps and analyst names.

Evidence must be retained for a minimum of 3 years per GDPR accountability obligations.
Do not store evidence in systems that may be compromised — use an isolated secure location.

### Post-Mortem Requirements

A post-mortem must be completed within 7 days of incident closure. It must include:

1. Detailed attack timeline.
2. Root cause analysis (technical and process).
3. Impact assessment (confirmed scope vs suspected scope).
4. Controls that failed and why.
5. Remediation actions taken.
6. New or updated controls to prevent recurrence.
7. Lessons for future incidents.

Post-mortem document must be reviewed by DPO, CTO, and CEO before closure.

---

## Related Documents

- `/Docs/sub/reference/security_alerting_internal.md`
- `/Docs/sub/reference/security_headers_policy.md`
- `/Docs/sub/reference/audit_event_taxonomy.md`
- `/Docs/sub/reference/supabase_rls_policy_map.md`
- `/Docs/sub/runbooks/mfa_lockout_runbook.md`
- `/Docs/sub/runbooks/tamper_detection_forensic_runbook.md`
