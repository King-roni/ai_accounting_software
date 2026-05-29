# MFA Enrollment Policy

**Block ref:** 02 — Tenancy & Access · **Category:** Policies · **Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Defines which MFA methods are supported, which roles must enroll, how devices are tracked, and what events force re-enrollment. This policy is binding on `auth.verify_mfa`, the login flow, and any surface that issues or consumes step-up tokens. Implementation home: Block 02 Phase 03.

---

## Supported methods

| Method | Standard | Code format | Window |
|---|---|---|---|
| TOTP | RFC 6238 | 6-digit numeric | 30 seconds |
| Hardware security key | FIDO2/WebAuthn | Assertion-based | N/A |

SMS OTP is not supported and will not be added. SMS delivery is unreliable, subject to SIM-swap attacks, and not auditable at the byte level. Any code proposing SMS MFA support is rejected at review.

TOTP codes outside the 30-second window are rejected. A ±1 window tolerance (accepting the previous and next code) is permitted for clock-skew accommodation but must be implemented at the TOTP library level, not in application code.

---

## Enrollment requirement by role

| Role | MFA enrollment |
|---|---|
| OWNER | Required — enforced at every login |
| ADMIN | Required — enforced at every login |
| ACCOUNTANT | Optional — enforced only if business config `require_mfa_accountant = true` |
| VIEWER | Optional — not enforced by default |

Enforcement is checked at the login completion step. If a required-MFA user has no active `mfa_devices` row, the session is not issued. The user is redirected to the MFA enrollment flow instead.

A business owner can upgrade the requirement for ACCOUNTANT and VIEWER roles via the tenant settings page. This setting is stored in `business_entities.mfa_policy_overrides` (JSONB). The override cannot relax the OWNER/ADMIN requirement — that is a platform-level constraint, not a per-business setting.

---

## Recovery codes

- 8 recovery codes are generated at the point of first successful MFA enrollment (when `mfa_devices.is_active` transitions to `true` for the user's first device).
- Codes are stored as individual bcrypt hashes (cost factor 12) in `mfa_recovery_codes`. The plaintext codes are displayed once, in the enrollment confirmation screen, and are never retrievable again.
- Each code is single-use. On consumption, `consumed_at` is set and the code cannot be reused. The audit event `MFA_RECOVERY_CODE_USED` is emitted with `codes_remaining` in the payload.
- If the user loses all recovery codes, re-enrollment is required. Re-enrollment invalidates the existing device set and generates a new set of 8 codes.
- Recovery codes are not regenerated on addition of a second device. They are tied to the user account, not to a specific device.

---

## Device trust

A device that passes an MFA challenge can be designated as trusted for a configurable period. Defaults:

- Trust duration: 30 days
- Per-business override: configurable between 1 day and 90 days via `business_entities.mfa_device_trust_days`
- Trusted devices skip the TOTP/FIDO2 challenge on subsequent logins from the same device
- Trusted devices do NOT skip step-up MFA challenges. Step-up is always a fresh challenge regardless of device trust state. See `step_up_validity_window_policy.md`.

Device trust is tracked in the `mfa_device_trusts` table: `id` (UUID v7), `user_id`, `device_fingerprint` (hashed), `trusted_at`, `expires_at`, `last_seen_at`. Trust is revoked automatically at `expires_at` or on explicit revocation by the user or an ADMIN.

---

## MFA devices table

Table: `mfa_devices`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID v7, `gen_uuid_v7()` | Primary key |
| `user_id` | UUID v7, FK → `users.id` | |
| `device_type` | enum: `TOTP` \| `FIDO2` | Closed enum; no other values |
| `device_name` | text | User-supplied, max 80 chars |
| `enrolled_at` | timestamptz | Set when `is_active` transitions to `true` |
| `last_used_at` | timestamptz | Updated on every successful MFA challenge |
| `is_active` | boolean | `false` = soft-deleted device |

Maximum devices per user: 5. If a user attempts to enroll a sixth device, the request is rejected with error `MFA_DEVICE_LIMIT_REACHED`. The user must remove an existing device first.

RLS: users may read and delete their own devices. ADMIN may read and force-remove devices within their business. Cross-business device access is denied.

---

## Forced re-enrollment triggers

The following events require forced MFA re-enrollment on the affected user's next login:

| Trigger | Initiating event |
|---|---|
| Password reset completed | User completes a password-reset flow |
| Suspected account compromise | `SECURITY_ACCOUNT_COMPROMISE_SUSPECTED` alert raised for the user |
| Admin-initiated reset | OWNER or ADMIN calls `auth.force_mfa_reenrollment` for a user |

On forced re-enrollment:

1. All `mfa_devices` rows for the user are set to `is_active = false`.
2. All `mfa_device_trusts` rows for the user are deleted.
3. All active sessions for the user are revoked (see `session_lifetime_policy.md`).
4. The audit event `MFA_ENROLLMENT_FORCED` is emitted with `forced_by_user_id` (nullable — system-initiated for the compromise path) and `reason`.

The user must complete a fresh TOTP or FIDO2 enrollment on next login before any session is issued.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `MFA_DEVICE_ENROLLED` | MEDIUM | When a new `mfa_devices` row becomes `is_active = true` after first successful TOTP code confirmation or FIDO2 assertion |
| `MFA_DEVICE_REMOVED` | HIGH | When `is_active` is set to `false` on any device |
| `MFA_ENROLLMENT_FORCED` | HIGH | When all devices are invalidated and re-enrollment is required |
| `MFA_RECOVERY_CODE_USED` | HIGH | When a single-use recovery code passes challenge verification |

`MFA_DEVICE_REMOVED` is HIGH because device removal reduces the user's authentication strength and is a relevant signal for account-takeover detection.

`MFA_RECOVERY_CODE_USED` is HIGH because backup-code consumption may indicate a recovery scenario or an account-takeover attempt; it should be reviewed in the security alert queue.

---

## Failure paths

**User loses all devices and all recovery codes.** If a user has no active `mfa_devices` row and no unconsumed `mfa_recovery_codes` row, and MFA is required for their role, they cannot log in. Resolution: an OWNER or ADMIN must call `auth.force_mfa_reenrollment` to invalidate the device state and allow the user to enroll a fresh device. The admin action emits `MFA_ENROLLMENT_FORCED` with `reason = ADMIN_INITIATED`.

**Enrollment confirmation failure.** A user who starts TOTP enrollment (scans the QR code) but never submits a valid confirming code does not get an `mfa_devices` row with `is_active = true`. The partial enrollment is abandoned after 10 minutes (pending enrollment state is held in a separate ephemeral table, not in `mfa_devices`). No audit event is emitted for a partial enrollment that is never confirmed.

**Device limit reached.** If the user has 5 active devices, enrollment of a 6th is rejected at the application layer before any TOTP secret is generated. Error: `MFA_DEVICE_LIMIT_REACHED`. No audit event is emitted for the rejected attempt.

---

## Integration with step-up authentication

Step-up MFA (Block 02 Phase 06) is a separate challenge from login MFA. Device trust affects login MFA only. The following operations always require a fresh step-up challenge regardless of device trust status:

- Finalization approval (any workflow run)
- Key rotation
- Business deactivation
- Admin-forced MFA re-enrollment of another user
- GDPR erasure request

The step-up challenge type (TOTP or FIDO2) must match one of the user's enrolled and active `mfa_devices` rows. The step-up challenge is valid for the window defined in `step_up_validity_window_policy.md` (default: 15 minutes, non-configurable).

---

## Cross-references

- `mfa_device_schema.md` — full DDL for `mfa_devices` and `mfa_recovery_codes`
- `step_up_validity_window_policy.md` — step-up MFA rules; device trust does not bypass step-up
- `session_lifetime_policy.md` — session revocation on forced re-enrollment
- `audit_event_taxonomy.md` — `MFA_DEVICE_ENROLLED`, `MFA_DEVICE_REMOVED`, `MFA_ENROLLMENT_FORCED`, `MFA_RECOVERY_CODE_USED`
- Block 02 Phase 03 — MFA implementation, TOTP and FIDO2 integration
- Block 02 Phase 06 — step-up authentication
- `password_policy.md` — password reset triggers forced re-enrollment
