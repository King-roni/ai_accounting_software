# Password Policy

**Block ref:** 02 — Tenancy & Access · **Category:** Policies · **Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Defines password complexity requirements, storage rules, reset flow, breach detection, and forced rotation triggers. This policy is binding on the signup flow, password-change endpoint, and password-reset flow. Implementation home: Block 02 Phase 02.

---

## Complexity requirements

All passwords must satisfy all of the following at the point of set (signup, change, or reset):

| Requirement | Rule |
|---|---|
| Minimum length | 12 characters |
| Uppercase | At least 1 character in the range A–Z |
| Lowercase | At least 1 character in the range a–z |
| Digit | At least 1 character in the range 0–9 |
| Special character | At least 1 character not in `[A-Za-z0-9]` |
| Breach check | Must not appear in the HaveIBeenPwned dataset (k-anonymity check; see below) |

Maximum length: 128 characters. Passwords longer than 128 characters are rejected at the API layer before hashing — this prevents bcrypt-timing attacks on very long inputs.

Passwords that fail any rule are rejected with a structured error identifying which rule failed. The breach check result is surfaced as a distinct error code `PASSWORD_BREACHED` (see Breach detection section).

---

## Storage

Passwords are stored as bcrypt hashes. bcrypt parameters:

- Cost factor: 12
- Salt: auto-generated per-hash by the bcrypt library
- Version: `$2b$` (OpenBSD-compatible, the standard node/Python/Go library format)

The plaintext password is never written to any log, database column, cache, audit event payload, or error message. Application code that logs a password — even in a truncated or masked form — is a code-review-blocking violation.

The hash is stored in `users.password_hash` (text, not nullable for password-authenticated users; null for SSO-only users).

---

## Password reset

Password reset uses a dedicated table `password_reset_tokens`:

| Column | Type | Notes |
|---|---|---|
| `id` | UUID v4, `gen_random_uuid()` | UUID v4 per `data_layer_conventions_policy.md` — short-lived security credential |
| `user_id` | UUID v7, FK → `users.id` | |
| `token_hash` | char(64) | SHA-256 hex digest of the raw token; raw token never stored |
| `created_at` | timestamptz | |
| `expires_at` | timestamptz | `created_at + INTERVAL '1 hour'` |
| `consumed_at` | timestamptz, nullable | Set on use |

Token validity window: 1 hour from `created_at`.

Single-use: once consumed, `consumed_at` is set and the token cannot be reused. Concurrent consumption attempts are serialized via `SELECT ... FOR UPDATE`.

On successful password reset:

1. The new password is validated against all complexity rules and the breach check.
2. `users.password_hash` is updated to the new bcrypt hash.
3. The reset token row has `consumed_at` set.
4. All active sessions for the user are invalidated — `user_sessions` rows are set to `is_revoked = true` and `SESSION_REVOKED` is emitted for each. This prevents session-hijacking after a password reset.
5. All `mfa_device_trusts` rows for the user are deleted, requiring MFA re-challenge on next login.
6. MFA devices are NOT removed; only the device trusts are invalidated. The user must still pass a fresh MFA challenge (not re-enroll) on next login unless forced re-enrollment has been triggered separately.
7. `AUTH_PASSWORD_RESET_COMPLETED` is emitted.

The password reset request (step before the email is sent) emits `AUTH_PASSWORD_RESET_REQUESTED`. The token is generated server-side, hashed immediately, and the raw token is transmitted in the email link only. The raw token is never stored.

---

## Breach detection

Integration with the HaveIBeenPwned (HIBP) k-anonymity API. The full SHA-1 of the password is never sent to HIBP. The k-anonymity protocol:

1. Compute `SHA-1(plaintext_password)` in-process.
2. Take the first 5 hex characters of the SHA-1 hash as the prefix.
3. Send `GET https://api.pwnedpasswords.com/range/{prefix}` to the HIBP API.
4. Receive the list of SHA-1 suffix + count pairs for all hashes matching the prefix.
5. Check whether the full SHA-1 hash suffix (characters 6–40) appears in the response.
6. If found: reject the password with error `PASSWORD_BREACHED`. Emit `AUTH_PASSWORD_BREACHED_DETECTED`.
7. If not found: proceed with complexity checks and storage.

The full SHA-1 is never transmitted outside the process. Only the 5-character prefix is sent. This is the standard HIBP k-anonymity design.

If the HIBP API is unreachable (network error, timeout after 2 seconds): the breach check is skipped and the password is accepted. This avoids blocking password changes when the external service is unavailable. The skip is logged at WARN level (application log, not audit log) — it is not an audit event because no security state changed.

`AUTH_PASSWORD_BREACHED_DETECTED` (MEDIUM severity) is emitted when a password fails the breach check at set-time. It does not include the password or its hash. Payload: `user_id`, `detected_at`, `check_context` (`SIGNUP` | `PASSWORD_CHANGE` | `PASSWORD_RESET`).

---

## Rotation triggers

Forced rotation invalidates the current password and requires the user to set a new one on next login.

| Trigger | Policy |
|---|---|
| Suspected account compromise | Forced rotation on `SECURITY_ACCOUNT_COMPROMISE_SUSPECTED` alert for the user. The session is invalidated immediately; the user cannot log in without resetting. |
| Periodic rotation | Optional; configurable per business via `business_entities.password_rotation_days` (default: disabled; when enabled, range 90–365 days). The platform does not enforce rotation by default. |

When forced rotation is triggered by a compromise event:

1. `users.password_hash` is set to a sentinel value that blocks login (a hash that no password can match).
2. All sessions are revoked.
3. All MFA device trusts are invalidated.
4. MFA re-enrollment is forced per `mfa_enrollment_policy.md`.
5. The user receives a forced-reset email with a new password-reset token.

Periodic rotation (when configured): the user is shown a rotation reminder on login 14 days before expiry and a blocking prompt at expiry. The current password continues to work until the deadline; no sentinel is set.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `AUTH_PASSWORD_CHANGED` | MEDIUM | On any successful password change (includes post-reset) |
| `AUTH_PASSWORD_RESET_REQUESTED` | LOW | When the reset email is dispatched (token created and sent) |
| `AUTH_PASSWORD_RESET_COMPLETED` | MEDIUM | When the reset token is consumed and the new password is stored |
| `AUTH_PASSWORD_BREACHED_DETECTED` | MEDIUM | When HIBP k-anonymity check returns a match |

`AUTH_PASSWORD_CHANGED` and `AUTH_PASSWORD_RESET_COMPLETED` are MEDIUM because a password change is a relevant security event that should be visible to the Owner in the audit log.

`AUTH_PASSWORD_RESET_REQUESTED` is LOW because requesting a reset is an expected, routine user action and the token has not yet been consumed.

None of these event payloads contain a password, password hash, SHA-1 hash, SHA-1 prefix, or any derivative of the password.

---

## Cross-references

- `password_reset_token_schema.md` — DDL for `password_reset_tokens`, token lifecycle
- `session_lifetime_policy.md` — session revocation on password reset and forced rotation
- `mfa_enrollment_policy.md` — MFA device trust invalidation and forced re-enrollment triggers
- `data_layer_conventions_policy.md` — UUID v4 for `password_reset_tokens.id`; bcrypt storage context
- `audit_event_taxonomy.md` — `AUTH_PASSWORD_CHANGED`, `AUTH_PASSWORD_RESET_REQUESTED`, `AUTH_PASSWORD_RESET_COMPLETED`, `AUTH_PASSWORD_BREACHED_DETECTED`, `SECURITY_ACCOUNT_COMPROMISE_SUSPECTED`
- Block 02 Phase 02 — authentication baseline implementation
