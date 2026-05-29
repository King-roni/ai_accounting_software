# Runbook: MFA Lockout Recovery
**Category:** Runbooks · Block 02 — Tenancy & Access
**Last updated:** 2026-05-17

---

## Lockout Trigger Conditions

A user becomes locked out of MFA-protected actions through one of two paths:

1. **Max-attempts lockout:** The user fails step-up authentication 5 consecutive times within a
   1-hour window. The `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` (HIGH) audit event is emitted (taxonomy
   canonical name; replaces the former `AUTH_STEP_UP_FAILED` single-attempt event). The current
   session is invalidated immediately.

2. **Device loss:** The user's TOTP device is lost, stolen, or reset, and the user has no
   remaining backup codes. The user can log in (email + password) but cannot pass any step-up
   challenge.

Identify which condition applies before following the steps below.

---

## Scenario 1 — Step-Up Max Attempts Reached

**Symptoms:** `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` (HIGH) emitted in the audit log for the
user's `session_id` (taxonomy canonical name). The user reports being logged out mid-session.

**Steps:**

1. Confirm the lockout in the audit log:
   ```sql
   SELECT event_type, severity, session_id, created_at, payload
   FROM audit_events
   WHERE actor_user_id = '<user_id>'
     AND event_type    = 'AUTH_STEP_UP_FAILED_MAX_ATTEMPTS'
   ORDER BY created_at DESC
   LIMIT 1;
   ```

2. Confirm the session is invalidated:
   ```sql
   SELECT id, status, invalidated_at, invalidation_reason
   FROM sessions
   WHERE id = '<session_id>';
   ```
   Expected: `status = INVALIDATED`, `invalidation_reason = STEP_UP_MAX_ATTEMPTS`.

3. Instruct the user to re-authenticate with email and password. A new session is created.
   The step-up attempt counter resets on new session creation — the user is not permanently
   blocked from step-up.

4. The user requests a new step-up via:
   ```
   auth.request_step_up(
     user_id    = '<user_id>',
     context    = '<protected_action_context>',
     session_id = '<new_session_id>'
   )
   ```

5. If the user succeeds: resolved. If the user cannot pass the TOTP challenge (device lost),
   proceed to Scenario 2.

**Note:** Investigate why step-up was failing. If the TOTP clock is drifted, the authenticator
app may need re-sync. A 30-second clock skew tolerance is applied server-side; beyond that,
challenges will consistently fail.

---

## Scenario 2 — TOTP Device Lost, No Backup Codes

**Symptoms:** The user cannot provide a valid TOTP code; they confirm the device is lost and
no backup codes are available.

**Steps:**

1. Escalate to an `OWNER` or `ADMIN` on the same business entity.

2. The ADMIN navigates to: **Dashboard → Settings → Members → [User] → Disable MFA**.
   - This action is documented in `settings_page_ui_spec.md` under "Member settings → Disable
     MFA for this user".
   - The ADMIN must complete their own step-up challenge before the action is permitted. The
     locked-out user's step-up is not required.

3. Call (or confirm the UI calls):
   ```
   auth.disable_mfa(
     target_user_id    = '<locked_out_user_id>',
     acting_admin_id   = '<admin_user_id>',
     step_up_token_id  = '<admin_step_up_token_id>',
     reason            = 'device_lost_no_backup_codes'
   )
   ```

4. The `AUTH_MFA_UNENROLLED` (MEDIUM) audit event is emitted (admin-initiated). The target
   user's MFA enrollment record is set to `status = DISABLED`.

5. The user logs in with email + password. On next login, they are prompted to re-enroll MFA
   before accessing any MFA-protected feature. Enrollment flow is defined in
   `mfa_enrollment_policy.md`.

6. Encourage the user to download and store backup codes during re-enrollment.

---

## Scenario 3 — OWNER Is Locked Out (No ADMIN Available)

**Symptoms:** The `OWNER` user is locked out (Scenario 2 conditions) and no `ADMIN` exists
on the business entity, or all ADMINs are unavailable.

**Constraint:** No in-product mechanism exists for a non-OWNER user to disable the OWNER's MFA
without the OWNER's own step-up auth. This is by design to prevent privilege escalation.

**Recovery path:**

1. **Backup codes:** Confirm the OWNER has no backup codes. Backup codes are generated during
   enrollment (`mfa_enrollment_policy.md`). If any code remains unused, use it now via the
   standard step-up challenge UI.

2. **Backup codes exhausted or unavailable:** Escalate to platform support. The OWNER must
   provide identity verification (government-issued ID matching the account registration).

3. Platform support disables MFA via a privileged admin-only API endpoint that is not exposed
   in the product UI and requires a separate internal approval workflow.

4. Once MFA is disabled by platform support, `AUTH_MFA_UNENROLLED` (MEDIUM) is emitted
   (platform support override). The OWNER re-authenticates and re-enrolls MFA immediately.

5. After recovery, conduct a post-mortem: why were no backup codes available? Update the
   business entity's MFA policy to require a secondary `ADMIN` account as a standing recovery
   path.

---

## Prevention

- During MFA enrollment, the system presents backup codes once. Users must download and store
  them securely. This is required, not optional (`mfa_enrollment_policy.md`).
- Every business entity with an OWNER should have at least one active ADMIN as a recovery
  path. The onboarding checklist surfaces this requirement.
- Prompt users to verify their TOTP app clock sync if step-up failures increase suddenly.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | HIGH | 5th consecutive failure within 1 hour; also see `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` in taxonomy |
| `AUTH_MFA_UNENROLLED` | MEDIUM | Admin disables another user's MFA (admin-initiated) or platform support override |
| `AUTH_MFA_ENROLLED` | MEDIUM | User completes MFA re-enrollment after recovery |

---

## Cross-References

- `mfa_enrollment_policy.md`
- `step_up_token_schema.md`
- `step_up_validity_window_policy.md`
- `session_schema.md`
- `settings_page_ui_spec.md`
- `audit_event_taxonomy.md`
