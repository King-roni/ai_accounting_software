# Security Best Practices Guide

**Block:** Platform / Security
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This guide is for platform operators and developers. It covers credential management,
access control, MFA requirements, audit log monitoring, incident response, and
dependency management. Following these practices reduces the attack surface and ensures
the platform meets the compliance expectations of a financial data processor operating
under EU/Cyprus regulation.

This guide does not replace the security policy documents (`security_headers_policy.md`,
`security_alerting_internal.md`). It is a practical companion that translates policy
into day-to-day operational behaviour.

---

## Credential Management

### API Keys

- Rotate all API keys on a quarterly schedule. Rotation means issuing a new key,
  updating all consumers, then revoking the old key. Never delete the old key record —
  mark it `REVOKED` so the audit trail is preserved.
- Never log API keys in any form. Ensure logging libraries are configured to redact
  `Authorization`, `X-API-Key`, and `Bearer` token values. Verify this by searching
  production log streams for the `pk_live_` prefix quarterly.
- Do not store API keys in source control, environment files committed to Git, or
  plain-text configuration files. Use environment variables injected at deploy time
  (Vercel environment variables, or Supabase Vault for server-side secrets).

### Supabase Service Role Key

The Supabase `service_role` key bypasses all Row Level Security policies. It must be
treated as a root credential.

- Store it exclusively in Supabase Vault or the Vercel encrypted environment
  variable store. Never in application code, client-side bundles, or `.env` files
  committed to any repository.
- Scope its use to Edge Functions and server-side admin API routes only. Never
  expose it in any client-reachable code path.
- Rotate it immediately upon suspected exposure. There is no deferred rotation for
  this credential — exposure of the service role key is a SEV-1 incident.

### Database Passwords and JWT Secrets

- Rotate the Supabase project JWT secret only when a compromised session is suspected.
  Rotation invalidates all active sessions. Coordinate with on-call support.
- Never store database connection strings in application logs. Ensure ORM and query
  builder libraries are configured to omit query parameters from error output.

### Supabase Vault

All application secrets (third-party API keys for Stripe, Nordigen, SendGrid, ECB,
VIES) must be stored in Supabase Vault as named secrets. Access them via
`vault.decrypted_secrets` in Edge Functions; do not pass them as environment variables
at function invocation time.

```sql
-- Retrieve a secret (run inside Edge Function, not in client-reachable code)
SELECT decrypted_secret
FROM vault.decrypted_secrets
WHERE name = 'STRIPE_SECRET_KEY';
```

---

## Access Control

### Principle of Least Privilege

Every team member and integration should have the minimum permissions required for
their function.

- Use the role hierarchy: `viewer < accountant < admin < owner`. Assign `accountant`
  rather than `admin` unless admin capabilities are actively needed.
- Integration API keys should cover only the scopes listed in `api_integration_guide.md`
  that the integration actually uses. Do not issue `wildcards` or all-scope keys.
- Database access for developer debugging must use a read-only Supabase role. Never
  use the service role key for ad-hoc queries. Create a named `readonly_debug` role
  with `GRANT SELECT` on relevant tables.

### Quarterly Access Reviews

- Review all org members and their roles in the Supabase Auth dashboard at the start
  of each quarter.
- Cross-reference against the HR system (or equivalent) to identify leavers and
  role changes.
- Review API key issuance log. Revoke keys for integrations that have been retired.
- Document the review in the security tracking log, even if no changes are made.

### Offboarding Procedure

When a team member leaves, execute within 24 hours:

1. Revoke their Supabase Auth user (Admin → Users → Deactivate).
2. Revoke any personal API keys they held.
3. Rotate any shared credentials they had access to (e.g. admin Vercel team account).
4. Check the audit log for any anomalous activity in the 30 days prior to departure.
5. Emit `TENANCY_MEMBER_REMOVED` event (this should happen automatically via the
   offboarding tool; verify it is present in `audit_events`).

---

## MFA Requirements

### Enforcement Policy

- **Required:** MFA is enforced for all users with `org:admin` or `owner` roles.
  The platform enforces this at the RLS layer — admin-scoped operations require a
  session with MFA verified (`aal2` claim).
- **Recommended:** All users are encouraged to enrol MFA. User-facing onboarding
  includes an MFA prompt that cannot be dismissed for more than 14 days.
- MFA method: TOTP (authenticator app). SMS OTP is not offered due to SIM-swap risk.
  Hardware key support (WebAuthn) is on the roadmap.

### Recovery Codes

- Recovery codes are issued at MFA enrolment time. They are shown once and must be
  stored securely by the user.
- Recovery code use is logged as `MFA_BACKUP_CODE_USED` (HIGH severity). Monitor
  this event — multiple consecutive backup code uses for the same account may indicate
  the primary device has been lost or the account is compromised.

---

## Audit Log Monitoring

### Anomalies to Watch For

| Pattern                                                        | Severity | Action                                      |
|----------------------------------------------------------------|----------|---------------------------------------------|
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` for any user                | HIGH     | Investigate for brute force; may need account lock |
| `MFA_BACKUP_CODE_USED` more than once per account per month    | MEDIUM   | Confirm with user; may indicate lost device |
| `TENANCY_ROLE_GRANTED` to `owner` outside business hours       | HIGH     | Verify legitimacy with org owner            |
| `ACCESS_DENIED` spike for a single user                        | MEDIUM   | May indicate misconfiguration or probe      |
| Any `AUDIT_CHAIN_BREAK` event                                  | BLOCKING | Follow `audit_chain_break_runbook.md`       |
| `MOBILE_WRITE_REJECTED` spike from a single device             | MEDIUM   | Check for automated abuse or misconfigured app |
| `AI_CLASSIFICATION_OVERRIDDEN` rate above 20% over 4 hours    | HIGH     | Follow `high_classification_error_rate_runbook.md` |
| `STORAGE_PURGE_FAILED` two or more times in 24 hours           | HIGH     | Follow `supabase_storage_quota_runbook.md`  |

### Setting Up Alerts

Configure a Supabase webhook or a Postgres `pg_notify` listener to stream
`audit_events` rows to your alerting backend (e.g., a Slack bot or PagerDuty):

```sql
-- Trigger that fires pg_notify for HIGH and BLOCKING events
CREATE OR REPLACE FUNCTION notify_high_severity_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.severity IN ('HIGH', 'BLOCKING') THEN
    PERFORM pg_notify('audit_high_severity', row_to_json(NEW)::text);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER audit_high_severity_trigger
AFTER INSERT ON audit_events
FOR EACH ROW EXECUTE FUNCTION notify_high_severity_audit();
```

Listen to the `audit_high_severity` channel from a lightweight Edge Function that
forwards to Slack `#alerts-security`.

---

## Incident Response Quick Reference

### Severity Levels

| Level | Definition                                                          | Response Time |
|-------|---------------------------------------------------------------------|---------------|
| SEV-1 | Data breach, service_role key exposed, production data inaccessible | Immediate     |
| SEV-2 | Auth broken, MFA bypass, sustained > 20 min outage                 | 15 minutes    |
| SEV-3 | Elevated error rates, non-critical feature down                     | 1 hour        |
| SEV-4 | Cosmetic, documentation, minor degradation                          | Next sprint   |

### Who to Contact for SEV-1

1. **On-call engineer** — primary incident commander. Page via PagerDuty.
2. **CTO / Founding engineer** — escalate if on-call is unreachable after 5 minutes.
3. **Supabase support** — for suspected infrastructure compromise:
   support.supabase.com (Pro/Team plan: live chat available).
4. **Legal / DPO** — must be notified within 1 hour of confirmed personal data breach.
   EU GDPR Article 33 requires notification to supervisory authority within 72 hours.

### What NOT to Do in a SEV-1

- Do not publicly disclose details of the incident until legal has been notified.
- Do not attempt to delete audit log rows, even as a "cleanup" action. Every deletion
  is itself logged and creates forensic complications.
- Do not reuse the compromised credential after rotation. Revoke, do not reuse.
- Do not discuss the incident on personal or third-party communication channels.
  Use the designated incident channel only.

---

## Dependency Management

### Supabase SDK

- Pin the Supabase JS/TS SDK to a specific minor version. Unpin major version upgrades
  only after reviewing the migration guide and testing in staging for 48 hours.
- Check for updates weekly. Subscribe to the Supabase GitHub releases feed.
- When a security advisory is published for the SDK, upgrade within 24 hours for
  CRITICAL severity, 72 hours for HIGH severity. (Note: 'CRITICAL' here refers to external CVE/NVD severity classification. The internal platform severity_enum uses BLOCKING instead of CRITICAL — see reference/severity_enum.md.)

### Other Dependencies

- Subscribe to GitHub Dependabot alerts for the platform repository.
- Subscribe to npm security advisories for all production dependencies.
- Run `npm audit --production` as part of the CI pipeline. Block deployments on
  `critical` or `high` severity findings unless a documented exception exists.
- Review the full dependency tree quarterly. Remove unused packages — they are attack
  surface without benefit.

---

## Related Documents

- `/Docs/sub/runbooks/credential_rotation_runbook.md`
- `/Docs/sub/runbooks/data_breach_response_runbook.md`
- `/Docs/sub/runbooks/mfa_lockout_runbook.md`
- `/Docs/sub/reference/security_alerting_internal.md`
- `/Docs/sub/reference/security_headers_policy.md`
- `/Docs/sub/reference/supabase_rls_policy_map.md`
- `/Docs/sub/guides/api_integration_guide.md`
