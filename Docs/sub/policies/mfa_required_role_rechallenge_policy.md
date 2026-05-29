# mfa_required_role_rechallenge_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

When a user's live role changes mid-session and the **new** role carries an MFA-recency requirement, the user must complete a fresh MFA challenge before any privileged action under that role proceeds. This policy commits to the narrow re-challenge interaction: trigger condition, UI signal, factor choice, failure behaviour, freshness scope, edge cases, audit semantics, mobile rules.

**Out of scope:** the role-change mechanism itself — how roles are granted, how the change propagates, how it audits as a role event — lives in **Block 02 Phase 09**. This policy is the MFA-side companion that activates *after* the role change is committed.

Cross-referenced from `totp_secret_storage_integration.md`, `passkey_relying_party_integration.md`, `step_up_ui_spec.md`, and (indirectly via `mfa_device_trusts` invalidation on password reset) `password_policy.md`.

---

## 1. Trigger condition

The re-challenge trigger fires when **all** of the following hold:

1. The user has an active (`is_revoked = false`, not expired) session.
2. Block 02 Phase 09 commits a role mutation (insert / update on `business_user_roles`) that assigns the user a role whose `permission_matrix` row carries `requires_mfa_recent = true` for any reachable surface — *and* the user did not already have a role with that same requirement on this business.
3. The session's `step_up_qualified_until` is in the past (or NULL) at the moment of commit.

If a user already had a fresh-MFA marker, no immediate re-challenge fires — the existing marker remains valid for the standard window per `step_up_validity_window_policy.md`. Re-challenge ensures *one* fresh-MFA event occurs **after** the role change, not before every privileged action.

If a user is downgraded (loses an MFA-requiring role and gains none), no re-challenge fires. Loss of a role does not change the freshness marker.

---

## 2. What the re-challenge IS NOT

| Confusion | Clarification |
|---|---|
| Session re-authentication | The session token stays valid. No logout. |
| Forced TOTP-only path | User may complete with any enrolled MFA factor (TOTP, passkey, backup code). |
| Password challenge | Password is the *first* factor; re-challenge requires the *second*. Password alone does not satisfy. |
| Bulk per-action prompting | Once completed, satisfies all `REQUIRE_STEP_UP` surfaces for the session-wide validity window. |
| Lockout on cancel | User can dismiss the step-up prompt; only the privileged write fails. Reads still proceed. |
| A separate RPC | Reuses the standard step-up pathway documented in `step_up_validity_window_policy.md`. |

---

## 3. Pre-emptive UI signal

The moment Phase 09 commits the role mutation (and this policy's trigger condition holds), the platform emits a realtime push event on the user's session-scoped Supabase Realtime channel:

```
event: MFA_REFRESH_REQUIRED
payload: {
  business_id: <uuid>,
  previous_role: <user_role | null>,
  new_role: <user_role>,
  reason_text: "Your role has changed and now requires multi-factor verification."
}
```

All active sessions for the user receive the push. The UI shows a **non-blocking banner** at the top of the application chrome:

> Your role has changed and now requires multi-factor verification — your next privileged action will prompt for a code.

The banner is informational and **does not block reads**. It persists in the chrome until either:

- The user completes step-up (any path), at which point the banner is dismissed automatically on the next render.
- The user explicitly dismisses the banner (×). Dismissal is local-to-this-tab; the underlying re-challenge requirement remains until step-up completes.

If realtime delivery fails (network outage, websocket closed), the requirement is still enforced at the next privileged request — the realtime push is a UX enhancement, not the policy mechanism.

---

## 4. The re-challenge interaction itself

When the user invokes any tool whose `permission_matrix` decision is `REQUIRE_STEP_UP` for the new role, the standard step-up modal fires per `step_up_ui_spec.md`. Factor choices:

| Factor | Path | Success condition |
|---|---|---|
| TOTP | Enter 6-digit code from any active `mfa_devices` row | Code matches with `±30s` clock-skew window |
| Passkey | WebAuthn assertion via any registered credential in `auth.mfa_factors` | Signature verifies + `userVerification: required` |
| Backup code | Consume one unused code per `mfa_backup_codes_policy.md` | Constant-time iteration finds an unused match |

Password is **NOT** a step-up factor. Users with passkey-only configuration (no TOTP enrolled) complete via passkey; users with TOTP-only complete via TOTP; users with both choose. Backup codes are always available as universal fallback.

On success, the session's `step_up_qualified_until` is set to `now() + step_up_validity_window` per `step_up_validity_window_policy.md`. The role-change trigger is satisfied; the originally-attempted privileged request is retried automatically.

---

## 5. Failure and abandonment behaviour

If the user cancels the step-up prompt or fails the challenge:

- The originating privileged request fails with HTTP 403 + `STEP_UP_REQUIRED` (existing shape per `permission_matrix.md`).
- **Reads continue to work.** The user can navigate, view dashboards, view archive data — anything whose decision is `ALLOW` for the new role.
- **Writes to `REQUIRE_STEP_UP` surfaces continue to fail** until step-up succeeds. Each new write attempt re-prompts.
- There is **no lockout** at the policy level. Retry is unlimited subject to:
  - TOTP rate-limit (`mfa_lockout_runbook.md` step-up-lockouts table — 5 failures over 15 min triggers lockout per Block 15 P03).
  - Backup-code replay protection per `mfa_backup_codes_policy.md` §7 (replay attempts emit `MFA_BACKUP_CODE_ALREADY_USED`).

Cancelled / failed re-challenge **does NOT** revoke the role. The role is granted; only the privileged action is gated. The user can return to step-up at any time.

---

## 6. Freshness scope

The freshness marker (`step_up_qualified_until`) is **per-session**. A successful re-challenge satisfies:

- All `REQUIRE_STEP_UP` surfaces for **the satisfying session** for the window defined in `step_up_validity_window_policy.md` (currently 15 min for `STANDARD_PRIVILEGED`, 5 min for `HIGH_PRIVILEGED`, per that doc).
- **Not** the user's other sessions (multi-device scenario, see §7.3 below).

The role change does NOT shorten or extend the window. It guarantees only that one fresh-MFA event occurs in the satisfying session after the role mutation. If the existing window had 10 min remaining at role-change time, that 10-min residue is **discarded** (the trigger condition requires `step_up_qualified_until` in the past, but immediately after the trigger fires, even an unexpired marker is invalidated for the role-change path — implementation must set `step_up_qualified_until := NULL` on trigger emission).

---

## 7. Edge cases

### 7.1 User has no MFA factor enrolled at role-change time

**Blocked upstream by Phase 09.** Phase 09's role-assignment validator MUST refuse to assign a role with `requires_mfa_recent = true` to a user who has zero active enrolled factors (`mfa_devices.is_active = true` empty AND no passkey credentials in `auth.mfa_factors`). The refusal returns `ROLE_ASSIGNMENT_REQUIRES_MFA_ENROLLMENT` and emits an audit event (Phase 09's concern).

This policy assumes the user has at least one enrolled factor whenever its trigger fires. If somehow invoked otherwise (race condition between factor deletion and role assignment), the step-up modal shows "No MFA factor available — contact account recovery" and fails the privileged request indefinitely until either a factor is re-enrolled or the role is revoked.

### 7.2 User on the same business has multiple roles, the new role is the one with MFA requirement

The trigger evaluates `requires_mfa_recent` across the **effective role set** for the business. If the previous effective set already required MFA (because of a different role), the trigger does NOT fire on adding the new role. Only the *first* MFA-requiring role on a business triggers re-challenge.

### 7.3 Multi-session: user has active sessions on 3 devices

Each session evaluates the trigger independently:

- Realtime banner is pushed to all 3.
- Each session's `step_up_qualified_until` is independently set to NULL.
- Each device must complete step-up before its privileged actions proceed.
- A step-up on Device A does NOT satisfy Devices B and C — the freshness marker is per-session.

### 7.4 Role change happens while user is mid-step-up for an unrelated action

The in-progress step-up flow is allowed to complete normally. If it succeeds, the `step_up_qualified_until` is set per the standard validity window. The role-change trigger, evaluated at commit time, may then re-mark the marker as NULL if its trigger fires *after* the step-up succeeds. Net effect: user completes one step-up, sees the role-change banner, completes a second step-up at next privileged action. Acceptable; the user inconvenience is small and the alternative (deferring the role-change-trigger evaluation) opens a race window.

### 7.5 Role change at the moment a session expires

The session expiry takes precedence. If the session is expired (idle or absolute timeout per `session_lifetime_policy.md`), the user re-authenticates from scratch (password + MFA), which satisfies the role-change trigger as a side effect. No separate re-challenge fires.

---

## 8. Audit events

| Event | Severity | When | Payload |
|---|---|---|---|
| `MFA_REQUIRED_BY_ROLE_CHANGE` | MEDIUM | At trigger moment (after Phase 09 commit, when this policy nulls `step_up_qualified_until`) | `{ user_id, business_id, previous_role, new_role, sessions_notified: uuid[], triggered_at }` |

Step-up completion itself emits `MFA_CHALLENGE_PASSED` (LOW) per the existing `MFA_*` taxonomy. This policy adds an **optional** `triggered_by` field to that event's payload — value `"role_change"` when the completion satisfies a `MFA_REQUIRED_BY_ROLE_CHANGE` trigger. Absent for other step-up completions. Provenance is recoverable by joining `MFA_REQUIRED_BY_ROLE_CHANGE.user_id` with subsequent `MFA_CHALLENGE_PASSED.triggered_by = 'role_change'` rows.

Cancellation / failure of a re-challenge does NOT emit a distinct event — the underlying step-up flow's own events (`MFA_CHALLENGE_FAILED` or no event on user-dismiss) suffice.

---

## 9. Mobile

| Surface | Mobile allowed? | Notes |
|---|---|---|
| Receiving `MFA_REFRESH_REQUIRED` realtime push + banner display | **Yes** | Read-only UI state; mobile clients render the banner identically. |
| Completing step-up via any factor | **Yes** | Step-up is read-against-credential. TOTP / passkey / backup-code paths all available on mobile. |
| The downstream privileged write being attempted | Subject to `mobile_write_rejection_endpoints.md` independently | A successful re-challenge does NOT bypass mobile-write rejection — those are orthogonal gates. |

---

## 10. Passkey-only users

Users whose only enrolled factor is passkey complete re-challenge with a passkey assertion. The step-up modal omits the TOTP code-entry field and presents the WebAuthn prompt directly. Backup codes remain available as the universal fallback.

There is no path that forces a TOTP enrollment when the new role is granted — the platform accepts passkey-only as a valid MFA configuration per `passkey_relying_party_integration.md`.

---

## 11. Implementation contract

The Phase-09-emitted role-change event MUST carry enough payload for this policy's evaluator to determine `requires_mfa_recent` transition. Minimum required fields:

```
ROLE_ASSIGNMENT_COMMITTED
  user_id: uuid
  business_id: uuid
  previous_effective_role_set: user_role[]
  new_effective_role_set: user_role[]
```

The evaluator (a SECURITY DEFINER function `mfa.evaluate_role_change_rechallenge_trigger`) computes:

```sql
old_required := EXISTS (
  SELECT 1 FROM permission_matrix pm
  WHERE pm.role = ANY(previous_effective_role_set)
    AND pm.requires_mfa_recent = true
);
new_required := EXISTS (
  SELECT 1 FROM permission_matrix pm
  WHERE pm.role = ANY(new_effective_role_set)
    AND pm.requires_mfa_recent = true
);

IF NEW.new_required AND NOT NEW.old_required THEN
  trigger_rechallenge();
END IF;
```

`trigger_rechallenge()` nulls `step_up_qualified_until` on all the user's active sessions, emits `MFA_REQUIRED_BY_ROLE_CHANGE`, and pushes the realtime `MFA_REFRESH_REQUIRED` event.

---

## 12. Cross-references

- `permission_matrix.md` — `requires_mfa_recent` column on permission rows; `REQUIRE_STEP_UP` decision
- `step_up_validity_window_policy.md` — `step_up_qualified_until` marker; per-window duration (15 min STANDARD / 5 min HIGH)
- `step_up_ui_spec.md` — the step-up modal UX (factor-picker, code entry, passkey prompt)
- `mfa_enrollment_policy.md` — factor availability check (at least one active factor required)
- `mfa_device_schema.md` — TOTP devices (`is_active = true` lookup)
- `passkey_relying_party_integration.md` — passkey factor completion
- `mfa_backup_codes_policy.md` — backup-code factor completion; replay protection
- `session_lifetime_policy.md` — session validity precedence over re-challenge (§7.5)
- `mfa_lockout_runbook.md` — TOTP / step-up failure lockout (Block 15 P03 5-failure / 15-min)
- `mobile_write_rejection_endpoints.md` — orthogonal write-surface gate
- `audit_event_taxonomy.md` — `MFA_REQUIRED_BY_ROLE_CHANGE` (new), `MFA_CHALLENGE_PASSED` with `triggered_by` field extension
- Block 02 Phase 03 — MFA architecture
- **Block 02 Phase 09 — role-change propagation (owning context for the trigger source)**
- Block 05 Phase 04 — audit chain ingest
- Stage 1 decision — role-driven MFA recency requirement
