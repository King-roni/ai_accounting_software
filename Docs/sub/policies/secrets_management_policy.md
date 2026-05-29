# Secrets Management Policy

**Scope:** All secrets used by the Cyprus bookkeeping SaaS platform — API keys, database passwords, JWT signing keys, KMS ARNs, OAuth client secrets, and service account credentials.
**Owning team:** Platform / Security
**Last reviewed:** 2026-05-17
**Cross-ref:** `dr_restore_runbook.md`, `audit_event_taxonomy.md`, `infrastructure_cutover_runbook.md`

---

## Overview

This policy defines how secrets are stored, accessed, rotated, and audited across the platform. All personnel with access to any production secret are subject to this policy. Violations may result in mandatory emergency rotation and, depending on severity, disciplinary action.

The platform uses Supabase Vault as the primary secrets store for runtime secrets and Vercel / GitHub Actions environment variable injection for CI/CD pipeline secrets.

---

## Secrets Classification

| Secret type | Classification | Storage location |
|---|---|---|
| JWT signing keys | Critical | Supabase Vault |
| Database passwords (connection strings) | Critical | Supabase Vault + CI/CD env vars |
| Service role keys (Supabase) | Critical | Supabase Vault + CI/CD env vars |
| OAuth client secrets (Google) | Critical | Supabase Vault |
| Third-party API keys (ECB, HaveIBeenPwned) | Sensitive | Supabase Vault |
| KMS ARNs | Sensitive | Supabase Vault |
| Anon keys (Supabase) | Internal | CI/CD env vars (lower privilege) |
| Webhook signing secrets | Sensitive | Supabase Vault |

No secret of any classification may be stored in:
- Source code files (any language)
- Git repositories (including private repositories)
- Log files or audit trail payloads
- Slack, email, or any communication platform
- Documentation files (including this file — examples must use placeholder values only)

---

## Secrets Storage

### Supabase Vault

Runtime secrets are stored in Supabase Vault and accessed via `vault.decryptedSecret(secret_name)` in database functions and edge functions. Direct access to the underlying `vault.secrets` table is prohibited except for platform admin tooling.

Key rules for Supabase Vault usage:
- Secrets are never exposed in RLS (Row Level Security) policies. RLS policies may reference secret names but must not call `vault.decryptedSecret()` inline — decryption must occur in a security definer function.
- Edge functions access secrets via environment variables injected at function deploy time, not by calling Vault at runtime. This avoids Vault round-trip latency on hot paths.
- Vault secret names follow the convention: `{service}_{environment}_{key_type}` (e.g., `google_oauth_production_client_secret`).

### CI/CD Environment Variables

Secrets injected into Vercel or GitHub Actions follow these rules:
- Secrets are entered as encrypted environment variables in the Vercel dashboard or GitHub repository secrets; they are never included in `vercel.json`, `.github/workflows/*.yml`, or any committed configuration file.
- Environment variables are scoped to the minimum required environment (production secrets are not available in preview deployments).
- No secret value is ever echoed, logged, or printed in build or deployment logs. CI/CD pipeline steps must not `echo $SECRET_VALUE` or print environment variables to stdout.

---

## Access Control

- Secrets in Supabase Vault are accessible only to service accounts with the `vault_reader` database role. Application code does not connect to the database as a superuser.
- CI/CD secrets in Vercel are accessible only to team members with the `Owner` role in the Vercel team.
- GitHub Actions secrets are accessible only to repository Admins.
- Individual developer access to production secrets requires explicit approval from the Infrastructure Lead and is reviewed monthly. Developer access is revoked immediately on personnel offboarding.
- All secret access follows the principle of least privilege: services receive only the specific secrets they require, not a blanket credential set.

---

## Rotation Schedule

| Secret type | Rotation frequency | Rotation trigger |
|---|---|---|
| JWT signing keys | Every 90 days | Scheduled + personnel offboarding |
| Database passwords | Every 180 days | Scheduled + personnel offboarding + suspected compromise |
| Service role keys | Every 180 days | Scheduled + personnel offboarding |
| OAuth client secrets | On personnel offboarding or suspected compromise | Event-driven |
| Third-party API keys | On personnel offboarding or key compromise | Event-driven |
| Webhook signing secrets | Every 180 days | Scheduled |

Rotation is performed by the Infrastructure Lead using the platform secret rotation runbook. Each rotation:
1. Generates a new secret value.
2. Updates the secret in Supabase Vault and/or CI/CD environment variables.
3. Triggers a Vercel redeployment (for CI/CD env var secrets) or a Vault secret version increment.
4. Verifies that the rotated secret is functional via the platform health check.
5. Emits `SECURITY_SECRET_ROTATED` (LOW) with `secret_name` and `rotated_by_user_id` in the payload.

Old secret versions are retained in Vault for 7 days after rotation to allow in-flight operations to complete, then permanently deleted.

---

## Audit Logging

All secret operations emit audit events:

| Event | Severity | Trigger |
|---|---|---|
| `SECURITY_SECRET_ACCESSED` | LOW | Any call to `vault.decryptedSecret()` or retrieval of a CI/CD secret in a running process |
| `SECURITY_SECRET_ROTATED` | LOW | Successful completion of any secret rotation |
| `SECURITY_SECRET_ROTATION_FAILED` | HIGH | Any failure during the rotation procedure before new secret is live |
| `SECURITY_SECRET_EMERGENCY_ROTATION_INITIATED` | HIGH | Break-glass emergency rotation started |

`SECURITY_SECRET_ACCESSED` events include `secret_name` (not the value), `accessed_by_service`, and `access_context`. They do not include the secret value, partial secret value, or any derivative thereof.

---

## Emergency Rotation Procedure

On suspected compromise of any secret (unauthorized access, accidental exposure in logs, personnel security incident):

**Target: all affected secrets rotated within 4 hours of confirmed or suspected compromise.**

1. **T+0:00** — Infrastructure Lead declares a security incident. CTO is notified immediately.
2. **T+0:15** — Scope assessment: identify which secrets may be compromised based on the incident details.
3. **T+0:30** — Emit `SECURITY_SECRET_EMERGENCY_ROTATION_INITIATED` (HIGH) for each affected secret type.
4. **T+0:30 to T+3:00** — Rotate all identified secrets using the standard rotation procedure, prioritising JWT signing keys and database passwords first.
5. **T+3:00** — Verify all rotated secrets are functional via full platform health check.
6. **T+4:00** — Incident report filed. Root cause documented. Corrective actions identified.

If a rotation fails mid-procedure (e.g., the new secret is invalid), the Infrastructure Lead has authority to put the platform into maintenance mode to prevent access with potentially compromised credentials while the issue is resolved.

---

## Personnel Offboarding

When a team member with access to production secrets leaves the team:

1. Within **2 hours** of access revocation: rotate all secrets the individual had access to.
2. Within **24 hours**: revoke Vercel team membership and GitHub repository access.
3. Within **24 hours**: audit `SECURITY_SECRET_ACCESSED` events for the 30 days prior to departure for any anomalous access patterns.
4. File an offboarding ticket in the change management system confirming completion of all rotation steps.

---

## Supabase-Specific Rules

- `vault.decryptedSecret()` is only called from security definer functions. It must never appear in:
  - RLS policies
  - Views
  - Client-accessible SQL functions (functions callable by the `anon` or `authenticated` role)
- The Supabase service role key is never used in client-side code (browser or mobile). It is only used in server-side edge functions and CI/CD automation.
- The Supabase `anon` key may be used in client-side code but must be treated as a published credential — it provides only the access granted by RLS policies to unauthenticated users.

---

## Compliance

This policy addresses GDPR Article 32 requirements for "appropriate technical measures" to ensure security of processing, specifically:

- Encryption of secrets at rest (Supabase Vault uses AES-256 encryption).
- Access control limiting secret access to authorised personnel and service accounts.
- Regular rotation reducing the window of exposure from credential compromise.
- Audit logging providing an evidence trail for compliance reviews and incident response.

Annual compliance review of this policy is required. The Infrastructure Lead is responsible for producing a rotation compliance report showing that all scheduled rotations were completed on time.

---

## Related Documents

- `dr_restore_runbook.md` line 22 — secret re-population during disaster recovery
- `infrastructure_cutover_runbook.md` — secret migration during environment cutover
- `audit_event_taxonomy.md` — SECURITY_SECRET_* event definitions
- `password_policy.md` — user password policy (separate from service secret policy)
