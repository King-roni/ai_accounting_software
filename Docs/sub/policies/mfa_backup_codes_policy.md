# mfa_backup_codes_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

Canonical policy for MFA backup codes — the one-time recovery codes a user can present in place of a TOTP code or passkey assertion when their primary MFA factor is unavailable. This policy commits to count, format, generation source, hashing scheme, single-use enforcement, replay protection, regeneration triggers, exhaustion behaviour, display rules, audit semantics, mobile rules, GDPR treatment, and EU residency.

Sibling to `mfa_enrollment_policy.md` (factor-agnostic enrollment umbrella); companion to `mfa_device_schema.md` (DDL host); peer factor docs are `totp_secret_storage_integration.md` and `passkey_relying_party_integration.md`.

---

## 1. Count

**Exactly 10 codes per generation.** Not user-configurable.

Rationale: 10 is the industry norm (Google, GitHub, AWS, 1Password). Large enough to cover realistic loss scenarios (lost phone + lost laptop + a few failed challenges); small enough that users will actually write them down. Going higher creates abandonment (users skip the "save these somewhere safe" step); going lower under-covers multi-device-loss scenarios.

---

## 2. Format

Each code is **`XXXX-XXXX-XXXX`** — 12 characters of base-32 with hyphens at positions 4 and 8 for readability (14 chars displayed).

| Property | Value | Rationale |
|---|---|---|
| Character alphabet | Crockford base-32 (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`) | Excludes `O` / `0`, `I` / `1`, `L` / `1`, `U` / `V` confusables; lowers transcription errors for users hand-copying codes. |
| Length (characters, excluding hyphens) | 12 | Round number that fits on one line at all reasonable display sizes. |
| Entropy | 12 × log₂(32) = **60 bits** | Well above the 56-bit informal floor for "good enough against offline brute force on a bcrypt-hashed value at cost-12". |
| Case | Uppercase displayed; case-insensitive on submission | Crockford spec is case-insensitive; uppercase displays better in monospace UI. |
| Hyphens | Displayed at positions 4 and 8 (`XXXX-XXXX-XXXX`) | Display only; server strips hyphens before lookup. Codes typed as `XXXXXXXXXXXX` are equivalent. |
| Whitespace | Stripped on submission | Defensive parsing for users who paste with surrounding spaces. |

Reference implementation:

```
function generateBackupCode(): string {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const bytes = crypto.randomBytes(12);
  let out = '';
  for (let i = 0; i < 12; i++) {
    out += alphabet[bytes[i] % 32];
  }
  // Display form: insert hyphens at positions 4 and 8
  return out.slice(0, 4) + '-' + out.slice(4, 8) + '-' + out.slice(8, 12);
}
```

The `% 32` modulo here is acceptable because `256 % 32 == 0` — no bias. (A non-power-of-2 alphabet would require rejection sampling.)

---

## 3. Generation

Generated server-side via the platform's CSPRNG wrapper (Node's `crypto.randomBytes` or Postgres `gen_random_bytes` from `pgcrypto`). Never derived from user id, timestamp, or any predictable seed. Each code is **independent** — no shared seed, no chain.

Generated atomically with the bcrypt-hashing step inside the enrollment (or regeneration) transaction. Plaintext codes exist only:

1. In server memory between generation and bcrypt-hashing
2. In the one-time UI response to the user
3. Wherever the user chose to save them

They are never logged, never written to storage as plaintext, never returned by any API endpoint after the initial generation response.

---

## 4. Hashing scheme

**Bcrypt cost-12** — matches the `password_policy.md` storage choice for consistency. One bcrypt hash per code:

| Property | Value |
|---|---|
| Algorithm | bcrypt, `$2b$` (OpenBSD-compatible) |
| Cost factor | 12 |
| Salt | Auto-generated per-hash by the bcrypt library |
| Key derivation chain | None — each code is hashed independently |
| Storage location | `mfa_devices.backup_codes_hash text[]` (per `mfa_device_schema.md` §"Table: mfa_devices") |

Each array element is a self-contained bcrypt hash; the array order is the generation order and is stable for the life of the batch.

**Why bcrypt and not SHA-256?** Backup codes are user-supplied secrets — though they're machine-generated, they live on paper / in password managers / in screenshots and are subject to all the same offline-brute-force concerns as passwords. The 60-bit entropy combined with bcrypt cost-12 puts the offline-attack cost at ~`2^60 × 2^12` ≈ `2^72` bcrypt operations, which is computationally infeasible at current hardware costs.

---

## 5. Storage and used-index tracking

The existing schema (`mfa_device_schema.md`) carries:

| Column | Purpose |
|---|---|
| `backup_codes_hash text[]` | Array of bcrypt hashes; index is stable for the life of the batch |
| `backup_codes_used_count integer` | Counter, increments on each successful consumption |

This policy **adds** a column at B02·P03 migration time:

| Column | Purpose |
|---|---|
| `backup_codes_used_indexes smallint[]` | Array of indices into `backup_codes_hash` that have been consumed |

Why both `used_count` and `used_indexes`? `used_count` alone doesn't tell us *which* codes have been used, which makes same-code replay detection (§7) impossible. `used_indexes` is the authoritative used-set; `used_count` is `array_length(used_indexes, 1)` and is retained as a convenience column for fast "how many left" reads.

`used_indexes` is initialised to `'{}'` on insert and only grows; never reset except by regeneration (which also resets the hashes).

---

## 6. Single-use enforcement

At challenge time, the server iterates `backup_codes_hash` and bcrypt-verifies the submitted code (after stripping hyphens, uppercasing) against each hash whose index is NOT in `backup_codes_used_indexes`:

```
for i in 0 .. (array_length(backup_codes_hash) - 1):
    if i in backup_codes_used_indexes:
        continue
    if bcrypt_verify(submitted, backup_codes_hash[i]):
        # Atomic inside the same transaction:
        backup_codes_used_indexes := backup_codes_used_indexes || i
        backup_codes_used_count   := backup_codes_used_count + 1
        emit MFA_BACKUP_CODE_USED (HIGH) with payload { user_id, device_id, code_index: i, used_count_after }
        return CHALLENGE_PASSED
return CHALLENGE_FAILED
```

**Constant-time iteration:** the loop always checks all 10 hashes regardless of where the match occurs (or whether it occurs at all). This avoids a timing oracle revealing which code (if any) was a near-match. Implementation MUST NOT short-circuit on match before completing the iteration; the match-found flag is captured in a local variable, the loop runs to completion, and the success/fail decision is materialised after the loop exits.

---

## 7. Replay protection

If a code matches a hash whose index IS already in `backup_codes_used_indexes`, the challenge fails with a distinct event `MFA_BACKUP_CODE_ALREADY_USED` (HIGH) — separate from `MFA_CHALLENGE_FAILED`.

Why a distinct event? Replay of a known-valid code is a stronger account-takeover signal than a random failed guess. It implies the attacker has obtained a code that *was* valid (paper steal, password-manager breach, screenshot exfiltration) and is attempting reuse. Security alert evaluation (Block 05 Phase 10) treats this event as a HIGH-priority signal.

The hash row is **not deleted** on consumption. We need the bcrypt comparison to succeed against used codes so we can distinguish "value-as-used" (emit replay event) from "value-as-invalid" (emit generic failure). Deleting consumed hashes would collapse those two cases into "challenge failed", losing the forensic signal.

---

## 8. Regeneration policy

Three regeneration triggers:

### 8.1 User-initiated

User navigates to **Settings → Security → Regenerate backup codes**. Step-up authentication required (per `step_up_validity_window_policy.md`) via password OR active TOTP factor. Passkey-only users may step up via passkey.

On confirmation:

1. New batch of 10 codes generated (§3).
2. Atomic UPDATE of `mfa_devices`: `backup_codes_hash := new_hashes`, `backup_codes_used_indexes := '{}'`, `backup_codes_used_count := 0`.
3. Emit `MFA_BACKUP_CODES_REGENERATED` (HIGH) with payload `{ user_id, device_id, previous_used_count, regeneration_reason: 'user_initiated' }`.
4. Display new codes once (per §10); old codes are now invalid even if previously unused.

### 8.2 Auto-prompt at low-remaining-count

When `backup_codes_used_count >= 8` (only 2 codes left), the UI surfaces a "regenerate" nudge in the Security dashboard banner. The auto-prompt **does NOT** auto-regenerate — regeneration is always a user action. The banner persists until the user either regenerates or dismisses it.

### 8.3 Forced regeneration on compromise

On `SECURITY_ACCOUNT_COMPROMISE_SUSPECTED` (per `password_policy.md` rotation section):

1. `backup_codes_hash := '{}'`, `used_indexes := '{}'`, `used_count := 0`.
2. Emit `MFA_BACKUP_CODES_REGENERATED` with `regeneration_reason: 'forced_compromise'` and `previous_used_count: <prior value>`.
3. User receives forced re-enrollment per the rotation section of `password_policy.md`; new codes must be generated before any MFA-required action proceeds.

**Not a trigger:** routine factor changes (adding/removing a TOTP device, adding/removing a passkey, changing password without compromise flag) do NOT force regeneration. The Security dashboard surfaces a recommendation banner suggesting regeneration after such changes, but it is user-action-driven.

---

## 9. Exhaustion handling

When `backup_codes_used_count >= 10`:

- Backup-code challenge UI is hidden (no input field shown); user is told "All backup codes have been used. Regenerate from Settings → Security."
- Live MFA factors (TOTP, passkey) continue to work normally.
- If user is also locked out of live factors AND all backup codes used: fall through to `mfa_lockout_runbook.md` recovery flow.

There is no path that auto-regenerates exhausted codes. Regeneration always requires a step-up-authenticated user action OR an admin-driven `mfa_lockout_runbook.md` execution.

---

## 10. Display rules

| Rule | Detail |
|---|---|
| Display frequency | Exactly **once** — immediately after generation, in the response to the regeneration RPC. |
| Display surfaces | (a) On-screen list, (b) "Download as .txt" button, (c) "Copy all to clipboard" button, (d) "Print" view (browser print dialog with print-optimised layout). |
| Confirmation gate | User must explicitly check a "I've saved my backup codes" acknowledgement checkbox before the page allows navigation away or before the modal closes. |
| Re-display | No "show codes again" path exists. Codes are bcrypt-hashed immediately on storage — they cannot be retrieved server-side after the initial display. |
| Lost-codes recovery | Regenerate. The user accepts that any previously-unused codes from the prior batch are now invalid. |

The confirmation checkbox does NOT verify the user actually saved anything — it acknowledges the responsibility-of-storage. The platform's stance: if a user clicked through without saving, that's a user-error which the lockout runbook handles via account recovery; we don't engineer around it because storing the codes server-side defeats their purpose.

---

## 11. Audit events

Canonical event names committed by this policy:

| Event | Severity | Trigger | Payload |
|---|---|---|---|
| `MFA_BACKUP_CODE_USED` | HIGH | Successful consumption of an unused code | `{ user_id, device_id, code_index, used_count_after, source_ip, source_user_agent }` |
| `MFA_BACKUP_CODE_ALREADY_USED` | HIGH | Submitted code matches a hash whose index is in `used_indexes` (replay attempt) | `{ user_id, device_id, code_index, attempted_at }` |
| `MFA_BACKUP_CODES_REGENERATED` | HIGH | Atomic batch replacement (user-initiated OR forced-compromise) | `{ user_id, device_id, previous_used_count, regeneration_reason: 'user_initiated' \| 'forced_compromise' }` |

None of these payloads contain a plaintext code, a bcrypt hash, or any derivative of either.

All three are HIGH severity because they all carry security signal: a used code is a successful authentication-via-recovery (legitimate or attack); a replay attempt is a strong attack indicator; a regeneration is a credential-rotation event Owners should see.

**Drift resolution:** the previous documentation set used two conflicting names — `MFA_BACKUP_CODE_USED` in `mfa_device_schema.md` and `MFA_RECOVERY_CODE_USED` in `mfa_enrollment_policy.md`. **This policy commits to `MFA_BACKUP_CODE_USED`.** Stage-6 reconciliation should remove the `MFA_RECOVERY_CODE_USED` alias from `mfa_enrollment_policy.md` line 116.

---

## 12. Mobile

| Surface | Mobile allowed? | Notes |
|---|---|---|
| Backup-code consumption (challenge-time) | **Yes** | The challenge is a read-against-hash, not a write to credential state. Mobile users locked out of their primary factor must be able to use backup codes. |
| Backup-code regeneration | **No** | Write surface; rejected per `mobile_write_rejection_endpoints.md`. User must regenerate from a non-mobile client. The Settings UI hides the regenerate button on mobile and surfaces the message "Regenerate from a desktop browser." |
| Viewing remaining-count | **Yes** | Read-only; included in the Security dashboard mobile view. |

---

## 13. GDPR / erasure

Backup-code hashes are deleted on account deletion via `mfa_devices.user_id` FK `ON DELETE CASCADE` (per `mfa_device_schema.md` table definition). No separate retention; no archival; the codes vanish with the user.

Audit events referencing backup-code consumption are subject to the standard 6-year audit retention (per Block 04 Data Architecture / `audit_log_policies.md`). The `code_index` field in the payload is a small integer with no PII surface; no pseudonymisation step on erasure.

---

## 14. EU residency

bcrypt hashes are stored in the same EU Postgres instance as everything else (`noxvmnxrqlzsdfngfiww`, eu-west-1). No third-party hashing service, no transit to non-EU. CSPRNG uses the platform's local OS entropy source — no remote randomness API.

---

## 15. Cross-references

- `mfa_device_schema.md` — `backup_codes_hash text[]`, `backup_codes_used_count`, table-level FK + RLS (host schema for this policy's data); needs B02·P03 migration to add `backup_codes_used_indexes smallint[]` column per §5
- `mfa_enrollment_policy.md` — factor-agnostic enrollment umbrella; remove `MFA_RECOVERY_CODE_USED` alias per §11 drift-resolution
- `password_policy.md` — bcrypt cost-12 baseline; compromise-driven forced rotation
- `totp_secret_storage_integration.md` — sibling MFA factor
- `passkey_relying_party_integration.md` — sibling MFA factor; passkey-only users step up via passkey for regeneration
- `step_up_validity_window_policy.md` — step-up requirement for user-initiated regeneration
- `mfa_lockout_runbook.md` — account-recovery fallback when codes exhausted + factors lost
- `mobile_write_rejection_endpoints.md` — mobile-write rejection for the regenerate surface
- `audit_event_taxonomy.md` — `MFA_BACKUP_CODE_USED`, `MFA_BACKUP_CODE_ALREADY_USED`, `MFA_BACKUP_CODES_REGENERATED` canonical entries
- `data_layer_conventions_policy.md` — bcrypt cost-12 platform baseline
- Block 02 Phase 03 — multi-factor authentication (architecture); migration that adds `backup_codes_used_indexes`
- Block 05 Phase 04 — Vault setup (not used by backup-codes themselves — bcrypt is self-contained — but referenced for the broader MFA infrastructure)
- Block 05 Phase 10 — security alert evaluation (consumes the HIGH events from §11)
- Stage 1 decision — backup codes as the recovery path for MFA loss-of-access
