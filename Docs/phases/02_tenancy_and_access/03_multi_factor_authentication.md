# Block 02 — Phase 03: Multi-Factor Authentication

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Authentication section)
- Decisions log: `Docs/decisions_log.md` (MFA factors: TOTP + WebAuthn/passkeys)

## Phase Goal

Users can enrol a TOTP authenticator and/or a passkey, and any login by a user holding an MFA-required role (Owner, Admin, Accountant) is challenged with their enrolled factor. Backup codes exist as a recovery path. MFA is now the gate it needs to be for sensitive workflow actions in later phases.

## Dependencies

- Phase 02 (login flow exists to challenge inside)
- Block 05's Vault integration for TOTP secret storage. If Vault is not yet available, TOTP secrets are stored via a Vault-shaped wrapper interface; the wrapper is swapped to real Vault when Block 05 lands. **No plaintext at-rest path is permitted under any circumstance.**

## Deliverables

- **TOTP enrolment flow:**
  - Generate a per-user secret stored in Supabase Vault.
  - Render a QR code containing the OTPAUTH URI.
  - Verify the user's first 6-digit code before persisting the enrolment.
- **Passkey enrolment flow (WebAuthn):**
  - Relying-party configuration scoped to the platform domain.
  - Browser registration ceremony with attestation.
  - Multiple passkeys per user supported (different devices).
- **MFA challenge at login:**
  - Triggered when the logging-in user holds at least one MFA-required role on any business.
  - Challenge picks the user's preferred factor; user can switch to another enrolled factor.
- **Backup codes** — one-time-use, generated at TOTP enrolment, hashed at rest, surfaced once for the user to save.
- **MFA management UI** — add/remove TOTP, add/remove passkey, regenerate backup codes (with re-auth).
- **State on `users` profile row:** `mfa_enabled`, `mfa_factors_count`, last-used factor.
- **Audit events:** `MFA_ENROLLED`, `MFA_REMOVED`, `MFA_CHALLENGE_PASSED`, `MFA_CHALLENGE_FAILED`, `BACKUP_CODE_USED`, `BACKUP_CODES_REGENERATED`.
- **Audit sequence:** a successful MFA-protected login emits `LOGIN` (Phase 02) followed by `MFA_CHALLENGE_PASSED` (this phase). That pair is the canonical authenticated-login signature in the audit log.

## Definition of Done

- A user can enrol TOTP using any standard authenticator app (Google Authenticator, 1Password, etc.) and successfully pass an MFA challenge with it.
- A user can enrol a passkey on a supported device/browser and successfully pass a challenge.
- A user with both factors enrolled can switch between them at challenge time.
- Owner / Admin / Accountant accounts cannot reach the post-login screen without passing MFA.
- Each backup code works exactly once.
- MFA management UI requires re-auth before allowing factor removal.
- Audit events captured for every enrolment, challenge attempt, and backup-code use.

## Sub-doc Hooks (Stage 4)

- **TOTP secret storage sub-doc** — Vault integration pattern, key rotation, recovery on Vault outage.
- **Passkey relying-party sub-doc** — RP ID, authenticator selection, attestation handling, cross-device passkey strategy.
- **Backup code sub-doc** — count, format, hashing scheme, regeneration policy.
- **MFA-required-role re-challenge sub-doc** — what challenge is triggered when a user's live role gains an MFA requirement. Scoped specifically to the MFA re-challenge interaction; general role-change propagation lives in Phase 09.
