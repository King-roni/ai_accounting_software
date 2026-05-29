# Integration Credential Rotation Policy

**Namespace:** security  
**Block:** 02 — Tenancy & Access  
**Category:** Policies  
**Stage:** 4 sub-doc (Layer 2)

---

## Overview

This policy defines when integration credentials must be rotated, how rotation is performed, and what happens when rotation fails. It applies to all rows in `integration_credentials` across all `integration_type_enum` values. The central requirement is zero-downtime rotation: the old credential must remain functional until the new credential has been verified and the switchover is complete.

---

## 1. Rotation Triggers

### 1.1 Proactive Expiry-Based Rotation

The rotation scheduler runs every 6 hours and queries:

```sql
SELECT id, business_entity_id, integration_type, credential_ref, expires_at
FROM integration_credentials
WHERE revoked_at IS NULL
  AND expires_at IS NOT NULL
  AND expires_at < now() + interval '14 days';
```

Any credential returned by this query enters the rotation queue immediately. The 14-day window provides enough lead time to retry failed rotations before the credential actually expires. Credentials with `expires_at IS NULL` are not subject to expiry-based rotation but are still subject to periodic rotation per section 1.3.

### 1.2 Manual Rotation

An org member with the OWNER or ADMIN role may trigger immediate rotation for any credential belonging to their business. Manual rotation is initiated via the Integrations settings UI or by calling `security.rotate_credential`. Manual rotation follows the same procedure as expiry-based rotation. The trigger event is logged as `INTEGRATION_CREDENTIAL_ROTATED` in the audit log (see section 6).

### 1.3 Periodic Forced Rotation

Regardless of expiry, all integration credentials are subject to a maximum lifetime:

| Integration Type | Maximum Lifetime |
|---|---|
| BANK_FEED | 90 days |
| STRIPE_CONNECT | Per Stripe's platform requirements (currently 1 year) |
| SMTP_RELAY | 180 days |
| VIES_API | 365 days |
| ECB_RATE_FEED | 365 days |
| SUPABASE_VAULT | 30 days |

When a credential's age (`now() - created_at`) exceeds the maximum lifetime, the rotation scheduler treats it as expiry-based and enqueues rotation. This ensures that even credentials without an explicit `expires_at` are rotated regularly.

### 1.4 Compromise-Detected Rotation

If a credential is identified as compromised — via security alerting, user report, or external notification — the rotation process is triggered immediately with `COMPROMISE_DETECTED` as the trigger reason. Compromise-detected rotation does not wait for the proactive window; the old credential is revoked as soon as the new credential is verified functional. If verification fails, the incident escalation path in section 5.3 applies.

The security alerting subsystem emits `SECURITY_ACCOUNT_COMPROMISE_SUSPECTED` before triggering credential rotation. See `security_alert_routing_policy.md`.

---

## 2. Rotation Procedure

The following steps apply to all trigger types. The detailed per-integration-type runbook is in `runbooks/credential_rotation_runbook.md`.

### Step 1 — Generate New Credential in Vault

1. The rotation worker calls the integration provider's API to issue a new credential (API key, OAuth token refresh, or SMTP password reset depending on `integration_type`).
2. The new secret material is written to Vault at a new versioned path: `secret/data/be/{business_entity_id}/{integration_type_lower}/{new_version}`.
3. The new Vault path is not yet referenced by any row in `integration_credentials`.

### Step 2 — Insert New Row

```sql
INSERT INTO integration_credentials (
    id,
    business_entity_id,
    integration_type,
    credential_ref,
    scopes,
    expires_at,
    created_by
) VALUES (
    gen_uuid_v7(),
    :business_entity_id,
    :integration_type,
    :new_vault_path,
    :scopes,
    :new_expires_at,
    :rotation_actor_id  -- service member ID for automated rotation, user ID for manual
);
```

At this point both the old row (`revoked_at IS NULL`) and the new row (`revoked_at IS NULL`) exist. The unique constraint `uq_integration_credential_active` permits this overlap because only the `NULL` revoked_at uniqueness is enforced per pair. This is intentional.

### Step 3 — Test Connectivity

The rotation worker performs a connectivity test using the new credential before revoking the old one. The specific test per integration type is defined in `runbooks/credential_rotation_runbook.md`. The test must:

- Complete within 30 seconds.
- Return a success response from the integration provider (not merely a non-error from Vault).
- Be idempotent (safe to retry on timeout).

If the connectivity test fails, proceed to the rollback procedure in section 4.

### Step 4 — Switch Active Reference

The application's credential resolver always queries:

```sql
SELECT credential_ref FROM integration_credentials
WHERE business_entity_id = :business_entity_id
  AND integration_type = :integration_type
  AND revoked_at IS NULL
ORDER BY created_at DESC
LIMIT 1;
```

After the new row is inserted, `ORDER BY created_at DESC LIMIT 1` returns the new row's `credential_ref`. This switchover is instantaneous and requires no application restart or config change. The old credential remains valid at the provider side until step 5.

### Step 5 — Revoke Old Credential

After the connectivity test passes:

1. Update the old row: `UPDATE integration_credentials SET revoked_at = now() WHERE id = :old_row_id`.
2. Call the integration provider's API to revoke or expire the old credential.
3. Retire the old Vault secret: set its TTL to 1 hour to allow in-flight requests that may still be using it to complete, then let Vault expire it.

The maximum overlap window (both credentials live at the provider) is 10 minutes. If step 5 cannot be completed within 10 minutes, the rotation worker emits a `WARNING_RECORDED` log entry and schedules a retry of the revocation step only.

---

## 3. Zero-Downtime Requirement

Rotation must not cause any integration request to fail due to an authentication error. The following guarantees are required:

- The new credential is verified before the old credential is revoked at the provider.
- The credential resolver's `ORDER BY created_at DESC` query returns the new credential as soon as it is inserted, before the old credential is revoked.
- Vault reads are cached in memory for a maximum of 60 seconds. In-flight requests using a cached old credential reference will succeed because the old credential remains valid at the provider for the overlap window.

If a provider does not support overlapping credentials (i.e., issuing a new credential immediately revokes the old one), this must be documented in the per-integration runbook. Such integrations require a maintenance window for rotation and are classified as HIGH-risk integrations.

---

## 4. Rollback Procedure

If the connectivity test in Step 3 fails:

1. Delete the newly inserted `integration_credentials` row (this is the only permitted DELETE on this table, and only during the rotation window before the new row is considered active).
2. Delete the new Vault secret (it has never been used).
3. Log a `WARNING_RECORDED` event against the run (or a standalone `INTEGRATION_CREDENTIAL_ROTATION_FAILED` audit event — see section 6).
4. If the failure was expiry-based: notify the org ADMIN via the notification system. Re-queue the rotation attempt for 1 hour later. After 3 consecutive failures, escalate to HIGH severity.
5. If the failure was compromise-detected: escalate immediately to HIGH severity and notify the DPO. The old credential may be compromised; the incident response process in `data_breach_response_runbook.md` applies.

The old row remains active with `revoked_at IS NULL` throughout rollback. The old credential continues to function normally.

---

## 5. Notification

### 5.1 Successful Rotation

On successful rotation, the org ADMIN members of the business receive an in-app notification. Notification content: integration type, old credential expiry (if applicable), new credential expiry. No secret material is included in the notification.

### 5.2 Rotation Approaching

When a credential enters the 14-day proactive window (section 1.1), the org ADMIN receives an advance notification. This allows human review before the automated rotation fires.

### 5.3 Rotation Failure

On rotation failure, the org ADMIN receives a HIGH-severity in-app notification and email. The notification includes: integration type, failure reason (connectivity test failed, Vault write failed, provider API error), and next retry time. If retries are exhausted and the credential expires, the integration halts and the notification escalates to BLOCKING severity.

---

## 6. Audit Events

The following audit events are emitted during rotation. Neither `INTEGRATION_CREDENTIAL_ROTATED` nor `INTEGRATION_CREDENTIAL_ROTATION_FAILED` currently appears in `audit_event_taxonomy.md`; they must be added in the next taxonomy update before this policy goes to APPROVED status.

| Event | Severity | When |
|---|---|---|
| `INTEGRATION_CREDENTIAL_ROTATED` | LOW | Rotation completed successfully |
| `INTEGRATION_CREDENTIAL_ROTATION_FAILED` | HIGH | Connectivity test failed or Vault write failed |
| `INTEGRATION_CREDENTIAL_COMPROMISED` | HIGH | Compromise-detected rotation triggered |

Payload for `INTEGRATION_CREDENTIAL_ROTATED`: `business_entity_id`, `integration_type`, `old_credential_id`, `new_credential_id`, `trigger_reason` (`EXPIRY_APPROACHING` | `PERIODIC_FORCED` | `MANUAL` | `COMPROMISE_DETECTED`), `rotated_at`, `actor_id`.

---

## 7. Policy Exceptions

No exceptions are permitted for SUPABASE_VAULT and BANK_FEED credentials. SMTP_RELAY, VIES_API, and ECB_RATE_FEED periodic rotation may be deferred by at most 30 days with written OWNER approval logged as a `MANUAL_OVERRIDE` in the run log.

---

## Related Documents

- `schemas/integration_credential_schema.md` — table definition
- `runbooks/credential_rotation_runbook.md` — step-by-step operational procedure per integration type
- `policies/secrets_management_policy.md` — Vault architecture and path conventions
- `policies/no_plaintext_fallback_policy.md` — prohibition on raw secret storage
- `reference/audit_event_taxonomy.md` — audit event definitions (pending addition of rotation events)
- `runbooks/data_breach_response_runbook.md` — incident response for compromise-detected rotation
- `policies/security_alert_routing_policy.md` — how compromise signals are detected and routed
- `schemas/audit_log_schema.md` — audit log table
