# MFA Policy

**Block:** Auth  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines how multi-factor authentication (MFA) is enforced, enrolled, verified, and managed across the platform. MFA requirements vary by user role. Step-up MFA — a distinct second challenge triggered per high-risk operation — is covered separately from login MFA but governed by the same factor types and recovery mechanisms.

---

## MFA Enforcement Tiers

MFA enforcement is applied per user role at login time:

| Role | Login MFA | Step-Up MFA |
|---|---|---|
| VIEWER | Optional | Not required |
| ACCOUNTANT | Mandatory | Required for WRITES_RUN_STATE operations |
| ADMIN | Mandatory | Required for WRITES_RUN_STATE operations |
| OWNER | Mandatory | Required for WRITES_RUN_STATE and billing operations |

"Mandatory" means the user cannot complete login without passing an MFA challenge after password verification. If a mandatory-MFA user has not enrolled a factor, they are redirected to the MFA setup flow immediately after first login and cannot access the application until enrolment is complete.

Enforcement is checked by the `auth.can_perform_helper` tool and enforced at the Supabase Auth level via the `mfa` claim in the issued JWT.

---

## Supported Factors

### TOTP (Primary Factor)

Time-based One-Time Password (TOTP) per RFC 6238. Supported authenticator apps include Google Authenticator, Authy, 1Password, and any standards-compliant TOTP app.

- Algorithm: HMAC-SHA1
- Digits: 6
- Period: 30 seconds
- Issuer label: displayed in the authenticator app as `BoekhoudingenAI (<user email>)`
- Clock skew tolerance: ±1 step (30 seconds either side)

TOTP is the recommended and preferred factor for all users.

### SMS OTP (Fallback Factor)

SMS OTP is supported as a fallback mechanism only. It is explicitly discouraged due to SIM-swap vulnerabilities and carrier reliability issues.

- OTP length: 6 digits
- OTP validity: 5 minutes from dispatch
- Rate limit: 3 SMS OTPs per 10 minutes per user
- SMS OTPs may only be enrolled if no TOTP factor exists for the account

Phone numbers used for SMS OTP are classified as PII. They must be handled in accordance with `policies/gdpr_data_subject_rights_policy.md`. Phone numbers are stored encrypted at rest. On data subject deletion requests, phone numbers are purged from `mfa_devices` as part of the deletion workflow.

---

## TOTP Setup Flow

1. **Initiate enrolment** — User navigates to Security Settings and clicks "Add authenticator app." The platform calls the Supabase Auth MFA API (`supabase.auth.mfa.enroll({ factorType: 'totp' })`).
2. **Display QR code** — The API returns a `totp_uri` which is rendered as a QR code in the browser. The raw secret is also displayed for manual entry. The QR code is rendered client-side only and never stored server-side.
3. **Verify with two consecutive codes** — The user must enter two valid, sequential TOTP codes. This confirms the user's app is correctly synced. The platform calls `supabase.auth.mfa.verify({ factorId, challengeId, code })` twice with consecutive codes.
4. **Enrolment confirmed** — On successful double-verification, the factor is marked `VERIFIED` in `mfa_devices`. The platform emits `AUTH_MFA_ENROLLED` (severity: LOW).
5. **Recovery codes generated** — Immediately after enrolment, 8 single-use recovery codes are generated and displayed once. The user must acknowledge they have stored the codes offline. Recovery codes are stored as bcrypt hashes in `mfa_recovery_codes`.

---

## Recovery Codes

- **Count:** 8 per enrolment
- **Format:** Groups of 5 alphanumeric characters separated by hyphens (e.g., `A3K9X-P7MQR`)
- **Display:** Shown exactly once at enrolment time. Not retrievable after dismissal.
- **Storage:** Stored as bcrypt hashes (`$2b$12$...`). Plaintext is never persisted.
- **Usage:** Single-use. Each code is consumed on use and cannot be reused.
- **Regeneration:** Users may regenerate recovery codes from Security Settings. Regeneration invalidates all existing codes and generates a fresh set of 8. This action requires a valid TOTP code (or admin override) before the new codes are shown.
- **Backup requirement:** Users are required to store recovery codes offline (printed or in a password manager). The platform displays a warning if no recovery code has been used within 12 months and the user has not regenerated codes.

---

## MFA Bypass

MFA may only be bypassed via:

1. **Recovery code** — The user enters one of their 8 single-use recovery codes at the MFA challenge screen. On success: the code is consumed, a `AUTH_MFA_VERIFIED` event is emitted with `payload.method = "recovery_code"`, and the user is immediately prompted to regenerate recovery codes if fewer than 3 remain.

2. **Admin override** — A platform administrator with OWNER-level access to the admin panel may bypass MFA for a specific user account. This action:
   - Requires the admin's own step-up MFA verification.
   - Generates a time-limited (15-minute) bypass token.
   - Emits `AUTH_MFA_UNENROLLED` (severity: MEDIUM) with `payload.bypass_reason` and `payload.admin_id`.
   - Is visible in the user's audit log.

No other bypass mechanism exists. Support requests for MFA bypass are directed to the mfa_lockout_runbook.md workflow.

---

## Step-Up MFA

Step-up MFA is a distinct challenge triggered mid-session for specific high-risk operations. It is separate from login MFA.

Step-up is triggered for any operation tagged `WRITES_RUN_STATE` in the tool registry. The trigger flow:

1. The tool checks `step_up_token` validity via `auth.step_up_request`.
2. If no valid step-up token exists for the current session, the API returns HTTP 403 with `code: STEP_UP_REQUIRED`.
3. The client presents a TOTP challenge.
4. On success, a step-up token is issued with a validity window defined in `policies/step_up_validity_window_policy.md`.
5. Subsequent WRITES_RUN_STATE operations within the validity window skip the challenge.

Step-up failures are tracked: after 3 consecutive failures within 5 minutes, the step-up attempt is locked for 10 minutes and `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` (severity: HIGH) is emitted.

---

## MFA-Exempt Operations

The following operation types do not require login MFA or step-up MFA:

- Read-only API calls (GET requests, report downloads, audit log reads)
- Notification dismissal
- Dashboard preference updates
- Profile display name changes

Any operation that reads data without modifying financial records, run state, or access control is considered read-only and MFA-exempt.

---

## Supabase Auth MFA API Usage

The platform uses the Supabase Auth JavaScript client for all MFA operations:

| Operation | Supabase API Call |
|---|---|
| Enrol TOTP | `supabase.auth.mfa.enroll({ factorType: 'totp' })` |
| Create challenge | `supabase.auth.mfa.challenge({ factorId })` |
| Verify challenge | `supabase.auth.mfa.verify({ factorId, challengeId, code })` |
| List factors | `supabase.auth.mfa.listFactors()` |
| Unenrol factor | `supabase.auth.mfa.unenroll({ factorId })` |

The Authenticator Assurance Level (AAL) is embedded in the JWT: `aal1` for password-only sessions, `aal2` for sessions with a verified MFA factor. RLS policies that restrict sensitive tables require `auth.jwt() ->> 'aal' = 'aal2'` for write access.

---

## mfa_lockout_runbook.md Cross-Reference

Users locked out of their account due to lost MFA device and exhausted recovery codes must follow the identity verification process documented in `mfa_lockout_runbook.md`. That runbook defines the required identity evidence, SLA for resolution, and the audit trail requirements for the lockout recovery action.

---

## GDPR Note

Phone numbers collected for SMS OTP enrolment are personal data under GDPR. They are subject to:

- Encryption at rest (per `policies/encryption_at_rest_policy.md`)
- Inclusion in data subject access requests
- Purge on verified deletion request (per `policies/gdpr_data_subject_rights_policy.md`)
- Retention only for as long as the SMS OTP factor is active

TOTP secrets are not directly linked to identity and are not classified as PII, but they are encrypted at rest as a precaution.

---

## Audit Events

| Event Name | Severity | Trigger |
|---|---|---|
| AUTH_MFA_ENROLLED | LOW | User successfully enrolls a TOTP or SMS factor |
| AUTH_MFA_UNENROLLED | MEDIUM | User or admin removes an MFA factor |
| AUTH_MFA_VERIFIED | LOW | MFA challenge passed at login or step-up |
| AUTH_MFA_FAILED | MEDIUM | MFA challenge failed (incorrect code) |
| AUTH_STEP_UP_VERIFIED | LOW | Step-up MFA challenge passed mid-session |
| AUTH_STEP_UP_FAILED_MAX_ATTEMPTS | HIGH | 3 consecutive step-up failures within 5 minutes |

All events are emitted via `auth.emit_audit` with `actor_type = 'USER'`. Admin override events additionally include `payload.admin_id`.

---

## Related Documents

- `policies/session_management_policy.md`
- `policies/mfa_enrollment_policy.md`
- `policies/step_up_auth_for_workflow_approval_policy.md`
- `policies/step_up_validity_window_policy.md`
- `policies/gdpr_data_subject_rights_policy.md`
- `policies/encryption_at_rest_policy.md`
- `policies/password_policy.md`
- `schemas/mfa_device_schema.md`
- `schemas/step_up_token_schema.md`
- `tools/tool_step_up_request.md`
- `reference/mfa_lockout_runbook.md`
