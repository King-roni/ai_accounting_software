# TOTP Authenticator App Integration Guide

**Category:** Integrations · Block 02 — Tenancy & Access
**Status:** Authoritative
**Cross-ref:** mfa_enrollment_policy.md, totp_secret_storage_integration.md, step_up_token_schema.md, step_up_validity_window_policy.md, settings_page_ui_spec.md

---

## 1. Overview

This document covers the integration of TOTP-based multi-factor authentication using standard authenticator apps. Supported apps include Google Authenticator, Authy, 1Password, Microsoft Authenticator, and any RFC 6238-compliant TOTP client.

TOTP is the primary MFA method for step-up authentication and login MFA. SMS-based OTP is not implemented. Hardware tokens (FIDO2/WebAuthn) are out of scope for MVP.

---

## 2. TOTP Standard

- **Specification:** RFC 6238 (TOTP: Time-Based One-Time Password Algorithm).
- **Base algorithm:** RFC 4226 (HOTP), with time as the counter.
- **HMAC algorithm:** SHA-1. SHA-256 and SHA-512 are not used, as most authenticator apps default to SHA-1 and non-default algorithms are inconsistently supported.
- **Code length:** 6 digits.
- **Time step (period):** 30 seconds.
- **Clock skew tolerance:** ±1 period (see Section 7).
- **Secret size:** 160 bits (20 bytes).

---

## 3. Secret Generation

A new TOTP secret is generated for each enrollment attempt. Secrets are never reused across enrollment sessions.

### 3.1 Entropy Source

The 20-byte secret is derived from `gen_random_uuid()`-based entropy. `gen_random_uuid()` is used here (not `gen_uuid_v7()`) because secrets are tokens, not ordered identifiers — random UUID entropy is the appropriate source for key material. The raw bytes are extracted and used directly as the TOTP secret.

### 3.2 Base32 Encoding

The raw 20-byte secret is Base32-encoded (RFC 4648, no padding) for use in the `otpauth://` URI and for display to the user during enrollment. The Base32 string is the canonical representation passed to authenticator apps.

### 3.3 Storage

Secrets are stored encrypted. The storage mechanism, key management, and encryption details are defined in totp_secret_storage_integration.md. Plaintext secrets are never written to the database, logs, or error trackers.

### 3.4 Pending vs. Active Secrets

A secret generated during enrollment is in `PENDING` state until the user successfully verifies a TOTP code against it. Only then is it promoted to `ACTIVE`. Pending secrets older than 10 minutes are automatically invalidated by a cleanup job (they are not promoted to ACTIVE and cannot be used for authentication).

---

## 4. QR Code Format

The secret is encoded as an `otpauth://` URI and displayed as a QR code during the enrollment flow.

### 4.1 URI Format

```
otpauth://totp/{issuer}:{user_email}?secret={base32_secret}&issuer={issuer}&algorithm=SHA1&digits=6&period=30
```

| Parameter      | Value                                          |
|----------------|------------------------------------------------|
| `{issuer}`     | The application name as configured in env: `TOTP_ISSUER` (e.g., "BookkeepingAI") |
| `{user_email}` | The authenticated user's email address (URL-encoded) |
| `secret`       | The Base32-encoded secret (no padding)         |
| `algorithm`    | `SHA1` (always; not configurable)              |
| `digits`       | `6` (always)                                   |
| `period`       | `30` (always)                                  |

### 4.2 QR Code Rendering

- The `otpauth://` URI is rendered as a QR code server-side using a QR code library.
- The QR code is returned as a base64-encoded PNG data URL in the enrollment initiation API response.
- Dimensions: 256×256px at the default zoom level. Rendered in the UI at 200px × 200px with a white background (`--color-surface-default`) and 16px padding around the code.
- A "Can't scan the QR code?" toggle reveals the Base32 secret in plain text for manual entry. The revealed secret is displayed in a monospaced font in a bordered box.

---

## 5. Enrollment Flow

### 5.1 Entry Point

User navigates to Settings → MFA → Enable MFA. This route requires an active session; no step-up is required to initiate enrollment (the user is already authenticated at the login MFA level).

### 5.2 Step 1 — Initiate Enrollment

- Client calls `POST /mfa/totp/enroll`.
- Server generates the 20-byte secret, stores it in `PENDING` state (totp_secret_storage_integration.md), constructs the `otpauth://` URI, renders the QR code PNG, and returns:
  - `qr_code_data_url` (base64 PNG)
  - `manual_entry_key` (Base32 secret, formatted in groups of 4: "JBSW Y3DP EHPK 3PXP")
  - `enrollment_session_id` (a short-lived token identifying this enrollment attempt)

### 5.3 Step 2 — User Scans QR Code

- The UI displays the QR code and manual entry key.
- The user opens their authenticator app and scans the QR code, or enters the manual key.
- A 6-digit code appears in the app, rotating every 30 seconds.

### 5.4 Step 3 — Verify Enrollment

- The user enters the current 6-digit code into the "Verify code" field on the enrollment screen.
- Client calls `POST /mfa/totp/enroll/verify` with `{ enrollment_session_id, code }`.
- Server validates the code against the pending secret using the TOTP algorithm with the ±1 window.
- **On success:** The secret is promoted from `PENDING` to `ACTIVE`. Backup codes are generated (Section 6). The UI transitions to the backup codes display step. Audit event: `MFA_ENROLLED` (MEDIUM severity).
- **On failure:** An inline error is shown: "Incorrect code. Please check your authenticator app and try again." The enrollment session remains open. After 5 failed attempts in 60 minutes, the enrollment session is invalidated and the user must start over.

### 5.5 Step 4 — Backup Codes Display

- After successful verification, backup codes are displayed immediately (Section 6).
- This is the only time backup codes are shown in full. The user is instructed to download or screenshot them.
- A "Done — I've saved my backup codes" button completes enrollment.
- Enrollment is not considered complete until the user clicks this button (the `mfa_devices` record's `enrollment_confirmed_at` is set at this point).

---

## 6. Backup Codes

### 6.1 Generation

- 10 single-use backup codes are generated at the time of successful TOTP enrollment.
- Each code is 8 digits (numeric), generated using `gen_random_uuid()`-derived randomness.
- Display format: groups of 4 separated by a hyphen — e.g., "1234-5678".

### 6.2 Storage

- Each backup code is stored as a bcrypt hash (cost factor 10).
- Plaintext codes are never stored.
- The hash and a `used` flag are stored in the backup codes table (referenced in totp_secret_storage_integration.md).

### 6.3 Usage

- At login or step-up, a user who cannot produce a TOTP code may click "Use a backup code instead."
- The entered code is checked against all unused backup codes for the user.
- If a match is found: the code is marked as `used`, the authentication step is satisfied. Audit event: `MFA_BACKUP_CODE_USED` (HIGH severity).
- If no match is found: an error is shown. Failed backup code attempts are rate-limited identically to TOTP attempts.
- Used backup codes cannot be reused.

### 6.4 Regeneration

- The user may regenerate backup codes at any time via Settings → MFA → Regenerate backup codes.
- Before regeneration, the user must supply a valid TOTP code (step-up requirement).
- On regeneration: all existing backup codes for the user are invalidated (hard-deleted); 10 new codes are generated and displayed.
- Audit event: `MFA_BACKUP_CODES_REGENERATED` (MEDIUM severity).

---

## 7. Clock Skew Tolerance

TOTP codes are time-based. A user's device clock may drift relative to the server.

- **Accepted windows:** The server accepts codes from the current 30-second window, the immediately preceding window, and the immediately following window.
- This is ±1 period (30 seconds before and 30 seconds after the current window boundary).
- This tolerance accommodates typical clock drift and network latency.
- Codes more than 1 period outside the current window are rejected.

---

## 8. Brute Force Protection

### 8.1 Rate Limiting

- **Threshold:** 5 failed TOTP verification attempts within any 60-minute rolling window.
- **Scope:** Per user, per context (login MFA, step-up).
- **On threshold reached:**
  - The verification endpoint returns a 429 response.
  - The current session is invalidated if the failure occurred at the step-up layer.
  - Audit event emitted: `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` (HIGH severity).
  - The user must wait until the 60-minute window expires before attempting again. No manual unlock is available to users (ADMIN can unlock via the admin panel — out of scope for this document).

### 8.2 Counter Reset

The failed attempt counter resets on a successful TOTP verification.

### 8.3 Audit Events

| Event                              | Trigger                                        | Severity |
|------------------------------------|------------------------------------------------|----------|
| `MFA_ENROLLED`                     | Successful TOTP enrollment confirmed           | MEDIUM   |
| `MFA_UNENROLLED`                   | User removes TOTP device (future feature)      | HIGH     |
| `MFA_BACKUP_CODE_USED`             | Backup code used for authentication            | HIGH     |
| `MFA_BACKUP_CODES_REGENERATED`     | Backup codes regenerated by user               | MEDIUM   |
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | 5 failed verifications in 60 minutes           | HIGH     |

---

## 9. MFA Device Record

Each enrolled TOTP device corresponds to a record in `mfa_devices` (mfa_device_schema.md). Key fields relevant to this integration:

- `device_type = 'TOTP'`
- `enrollment_confirmed_at`: set when the user completes Step 5 of enrollment
- `last_used_at`: updated on each successful TOTP verification
- `is_active`: set to `false` if the device is disabled by an admin or when the user unenrolls

---

## 10. Unenrollment

Unenrollment is a future feature (post-MVP). The API endpoint will require step-up authentication before allowing removal of a TOTP device. Removing the only MFA device will be blocked if the business's MFA policy requires MFA for the user's role.
