# passkey_relying_party_integration

**Category:** Integrations · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

WebAuthn relying-party (RP) configuration for the platform's passkey factor. Per Stage 1: "MFA factors: TOTP + WebAuthn/passkeys." This sub-doc commits to the **relying-party axis**: RP identity, authenticator selection, attestation handling, cross-device strategy, and the integration surface with Supabase Auth's WebAuthn infrastructure. Enrollment-flow UX and credential storage are owned by Supabase Auth and are out of scope here.

Companion to `totp_secret_storage_integration.md` (TOTP-side) and `mfa_enrollment_policy.md` (factor-agnostic policy umbrella).

---

## 1. Relying-party identity

| Property | Value | Notes |
|---|---|---|
| `rp.id` (production) | `cypbk.eu` | eTLD+1 of the production apex domain. Single RP across all per-business subdomains. Passkeys are user-scoped, not business-scoped — the same passkey authenticates the same user regardless of which business workspace they're navigating. |
| `rp.id` (staging) | `staging.cypbk.eu` | Distinct RP from production by design — passkeys do NOT cross environment boundaries. A staging passkey cannot be presented at production and vice versa. |
| `rp.id` (dev) | `dev.cypbk.eu` (or `localhost` for local dev) | Same boundary rule. Local-dev `localhost` is special-cased per WebAuthn spec; never accepted in production. |
| `rp.name` | `"Cyprus Bookkeeping"` | Shown in the OS passkey UI ("Save a passkey for Cyprus Bookkeeping?"). Stable string; changes require a product-decision-log entry because users see it during enrollment. |

**Single-RP rationale:** A multi-RP design (one per business subdomain) would force users to enroll a passkey per business, which is hostile to multi-business accountants (the platform's largest power-user cohort). The user-scoped RP collapses to the simpler model: one identity → one set of passkeys.

---

## 2. User handle and binding

WebAuthn requires a stable per-user `user.id` (binary blob, max 64 bytes) that the relying party can use to look the user up at assertion time.

| Field | Value | Notes |
|---|---|---|
| `user.id` | `users.id` (UUID v7) serialised as 16 raw bytes | Binary form, not the hex string. UUID v7's time-ordering is acceptable here because the user-handle is opaque to the authenticator — no one observes it as a temporal signal. |
| `user.name` | `users.email` | Shown in the authenticator UI alongside the platform name during enrollment ("Save a passkey for user@example.com on Cyprus Bookkeeping"). |
| `user.displayName` | `users.display_name` (fallback to email if null) | Free-form human-readable label. |

**Stability rule:** `user.id` is **stable for the lifetime of the account**. On account deletion, the `users.id` value MUST NOT be reused for a new account on the same authenticator — would create credential collisions where an old passkey resolves to a new identity. Account deletion is a tombstone operation per `gdpr_data_subject_rights_policy.md`; the row is anonymised but the id is retained.

---

## 3. Authenticator selection criteria

The `PublicKeyCredentialCreationOptions.authenticatorSelection` block at enrollment time:

```json
{
  "userVerification": "required",
  "residentKey": "preferred",
  "requireResidentKey": false
}
```

| Knob | Value | Rationale |
|---|---|---|
| `userVerification` | `"required"` | The passkey is a security-relevant factor; the platform requires the authenticator to perform user verification (PIN, biometric, or OS unlock). Mere user presence (touch-only) is rejected at the assertion level. |
| `residentKey` | `"preferred"` | Let the authenticator decide. Modern platform authenticators (iCloud Keychain, Google Password Manager, Windows Hello, 1Password) all prefer resident keys; hardware security keys may not. `"preferred"` accepts either. |
| `requireResidentKey` | `false` | Strict alias of `residentKey: "discouraged"`; we want the preferred-vs-strict distinction to live in `residentKey`. Per WebAuthn L3, `requireResidentKey` is deprecated; `false` here is for compatibility with L2 implementations. |
| `authenticatorAttachment` | (omitted) | Allow both `"platform"` (built-into-device) and `"cross-platform"` (USB / NFC / BLE security keys). No platform preference. |

**At assertion time** (`PublicKeyCredentialRequestOptions`): `userVerification: "required"` mirrors the enrollment policy. An assertion arriving with `userVerification: false` is rejected even if the credential is valid.

---

## 4. Attestation handling

`attestation: "none"` at enrollment.

The platform does NOT collect AAGUIDs, does NOT maintain an attestation allow-list or block-list, and does NOT distinguish between authenticator vendors. Rationale:

- **Privacy:** Attestation can reveal authenticator make/model, which is a fingerprinting vector. `"none"` is the privacy-preserving default for consumer-grade RPs.
- **Operational cost:** Maintaining an attestation list (FIDO MDS subscription, regular updates, vendor onboarding flow) is a Stage-2+ enterprise feature.
- **Trust model:** MVP trusts any FIDO2-conformant authenticator the user can persuade their browser to use. The browser already enforces minimum-standards before exposing the WebAuthn API.

This decision is recorded in `Docs/decisions_log.md`. Upgrading to direct or enterprise attestation requires a decisions-log amendment and an MDS subscription.

---

## 5. Cross-device passkey strategy

The platform treats **all passkeys as first-class**, regardless of whether they are:

| Class | Examples | Platform treatment |
|---|---|---|
| OS-synced passkeys | iCloud Keychain, Google Password Manager, 1Password, Bitwarden | First-class. No platform-side discouragement. |
| Device-bound platform authenticators | Windows Hello (when configured non-syncable), Linux libfido2 | First-class. |
| Hardware security keys | YubiKey, SoloKey, NitroKey, Google Titan | First-class. |
| Hybrid transport (phone-authenticates-laptop QR flow) | Caboodle / CTAP 2.2 cross-device authentication | Enabled. |

The platform does NOT distinguish synced vs. device-bound in policy. There is no concept of "this passkey is too portable" — if Apple / Google / a third-party password manager has chosen to sync a credential, the platform accepts the resulting assertions.

**Hybrid transport** (the QR-code flow where a user signs in on their laptop by approving on their phone) is enabled because Supabase Auth's underlying WebAuthn implementation supports it. The platform requires no additional configuration; the browser drives the UX.

---

## 6. Origin and challenge handling

| Property | Value |
|---|---|
| `origin` allow-list (production) | `https://cypbk.eu`, `https://app.cypbk.eu` |
| `origin` allow-list (staging) | `https://staging.cypbk.eu`, `https://app.staging.cypbk.eu` |
| `origin` allow-list (dev) | `http://localhost:3000` and `https://dev.cypbk.eu` |
| Challenge generation | 32 cryptographically-random bytes per request, server-side |
| Challenge TTL | 5 minutes from issue; single-use; consumed-or-expired token |
| Challenge storage | Redis-backed; key is `webauthn_challenge:<challenge_b64>`; value is `{user_id, intent: "enroll" \| "assert", issued_at}` |

No wildcard origins. No `localhost` in production allow-list. Cross-origin WebAuthn calls (iframe scenarios) are not supported; the platform sets `Permissions-Policy: publickey-credentials-get=(self), publickey-credentials-create=(self)` to block embedded use.

---

## 7. Multiple passkeys per user

| Rule | Value |
|---|---|
| Maximum passkeys per user | `5` (mirrors the TOTP device cap in `mfa_device_schema.md`) |
| Minimum passkeys when factor is `passkey-only` | `1` (cannot delete the last passkey while passkey is the configured MFA factor) |
| Last-passkey deletion guard | Step-up required via password OR backup code (per `mfa_backup_codes_policy.md`) |
| Credential nickname | User-assigned at enrollment; max 64 chars; for display only ("MacBook Touch ID", "YubiKey 5C", "iPhone 16 Pro") |

The 5-credential cap balances multi-device usability (laptop platform key + phone synced key + hardware-key backup) against credential-list pollution. Exceeding 5 returns a structured `MFA_DEVICE_LIMIT_REACHED` per Block 02 Phase 03.

---

## 8. Recovery and fallback

Loss-of-access fallback ordering:

1. If user has any TOTP factor enrolled → user authenticates via TOTP.
2. Else if user has unused backup codes → user consumes one per `mfa_backup_codes_policy.md`.
3. Else → account-recovery flow owned by Block 02 Phase 04. No support-driven passkey reset.

**Explicit non-support:** the platform does NOT provide a support-team-driven passkey reset path. Recovery is strictly user-initiated. Rationale: a support-team override of a WebAuthn factor would compromise the security-property the factor exists to provide. Users who lock themselves out without backup codes must complete a full identity-re-verification through the account-recovery flow.

---

## 9. Audit events

All WebAuthn-related events arrive at the platform via Supabase Auth's webhook channel and are persisted into the platform's audit chain by the `mfa_event_ingest` worker (per Block 05 Phase 04).

| Event | Severity | Trigger | Kind dimension |
|---|---|---|---|
| `MFA_ENROLLED` | MEDIUM | New passkey credential registered | `kind: "passkey"` |
| `MFA_CHALLENGE_PASSED` | LOW | Successful assertion at login or step-up | `kind: "passkey"` |
| `MFA_CHALLENGE_FAILED` | MEDIUM | Failed assertion (invalid signature, expired challenge, missing user-verification, replay) | `kind: "passkey"` |
| `MFA_DEVICE_REVOKED` | MEDIUM | User removes a passkey credential | `kind: "passkey"` |
| `MFA_DEVICE_LIMIT_REACHED` | LOW | Enrollment attempt past the 5-credential cap | `kind: "passkey"` |
| `MFA_CHALLENGE_REPLAYED` | HIGH | Same challenge presented twice (server detects via Redis single-use) | `kind: "passkey"` |

`kind` is a dimension on the payload (not a distinct action), letting the audit chain stay consistent between TOTP-emitted and passkey-emitted events.

No credential public key, no client-data-JSON, no attestation object, no AAGUID is included in any audit payload. Credential ID is included in opaque-handle form for forensic correlation only.

---

## 10. Supabase Auth integration surface

| Concern | Lives in | Access path |
|---|---|---|
| Credential public key, sign-count, transports list | `auth.mfa_factors` (factor_type = `webauthn`) | Supabase Auth admin client only |
| User ↔ credential join | `auth.users.id` ↔ `public.users.id` (1:1) | Standard SELECT |
| Credential metadata (nickname, created_at, last_used_at) | `auth.mfa_factors.factor_data` (JSON) | Supabase Auth admin client |
| Enrollment / assertion verification logic | Supabase Auth Edge Functions | Black-box; platform consumes results only |
| Revocation | Supabase Auth admin API → `auth.mfa.deleteFactor(factor_id)` | Wrapped by platform RPC `mfa.passkey_revoke(factor_id)` |

**Platform-side does not store passkey credential material.** Anything currently in `public.mfa_devices` is TOTP-only. The platform's role is:

1. Compose and serve `PublicKeyCredentialCreationOptions` / `PublicKeyCredentialRequestOptions` JSON to the browser at enrollment and assertion time (the options use the platform's RP ID + challenge + user-handle as documented above).
2. Forward the browser-returned `AuthenticatorAttestationResponse` / `AuthenticatorAssertionResponse` to Supabase Auth for cryptographic verification.
3. On success, ingest the resulting event via the audit webhook.

This split lets the platform stay out of cryptographic verification code paths while keeping audit and policy decisions in-platform.

---

## 11. EU residency

Supabase Auth's WebAuthn verification logic runs in the same EU region as the project (`noxvmnxrqlzsdfngfiww`, eu-west-1). No passkey credential material — public key, sign-count, attestation object — transits non-EU infrastructure.

Per Stage 1: all auth-domain data stays in EU; this policy inherits that constraint by reference.

---

## 12. Browser support floor

Minimum browser cohort that supports `userVerification: "required"` + CTAP 2.2 hybrid transport:

| Browser | Minimum version |
|---|---|
| Chromium-based (Chrome, Edge, Brave, Arc) | 108 (Dec 2022) |
| Safari (macOS / iOS / iPadOS) | 16 (Sep 2022) |
| Firefox | 119 (Oct 2023) |

Below-floor browsers receive a soft warning at MFA-factor-selection time and fall back to TOTP. The browser-detection check uses `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` + a UA-version check (UA check is a backstop because the WebAuthn capability check alone can pass on older browsers that lack `userVerification: "required"` enforcement).

---

## 13. Cross-references

- `totp_secret_storage_integration.md` — sibling MFA factor (TOTP)
- `mfa_device_schema.md` — TOTP-side device storage (passkey credentials live in `auth.mfa_factors`, not here)
- `mfa_enrollment_policy.md` — factor-agnostic enrollment umbrella
- `mfa_backup_codes_policy.md` — recovery fallback path
- `step_up_validity_window_policy.md` — fresh-MFA window applies regardless of factor
- `mfa_required_role_rechallenge_policy.md` — when re-challenge is required
- `audit_event_taxonomy.md` — `MFA_*` event family + `kind` dimension
- `permission_matrix.md` — `BUSINESS_SETTINGS_EDIT` for self-enrollment
- `gdpr_data_subject_rights_policy.md` — `users.id` tombstone-on-delete rule
- Block 02 Phase 03 — multi-factor authentication (architecture)
- Block 02 Phase 04 — account-recovery flow (passkey-loss endpoint)
- Block 05 Phase 04 — audit webhook ingest worker
- Stage 1 decision — TOTP + WebAuthn/passkeys as MFA factors
- Stage 1 decision — EU-only hosting
