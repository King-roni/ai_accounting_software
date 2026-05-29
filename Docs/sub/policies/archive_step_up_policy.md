# Archive Step-Up Policy

**Category:** Policies · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Step-up authentication policy specific to the finalization approval flow at the Block 15 boundary. This policy supplements the general step-up framework in `step_up_auth_for_workflow_approval` by committing to the exact UX flow, approval-method matrix, token validity window, mobile rejection rule, and token consumption semantics that apply when a user initiates period finalization. Finalization is irreversible within a period (amendment requires a full adjustment run); accordingly, step-up is always required — there is no configuration toggle to disable it.

---

## 1. When step-up authentication applies

Step-up authentication is required for every invocation of `out_workflow.user_approval` or `in_workflow.user_approval` where the resulting approval is intended to satisfy `engine.gate_approval_recorded` (i.e., where `approval_method = STEP_UP` is needed). There is no run-size or transaction-count threshold for finalization step-up, unlike the mid-workflow HUMAN_REVIEW_HOLD thresholds in `step_up_auth_for_workflow_approval`. Every period finalization requires step-up, unconditionally.

---

## 2. The UX flow

The following sequence is canonical for the "Finalize Period" action:

1. **User clicks "Finalize Period"** on the review queue's `Ready to Finalize` card or the dedicated finalization panel.
2. **Pre-challenge gate check:** the UI queries the composite gate `engine.gate_finalization_preconditions_satisfied`. If any gate returns `HOLD`, the finalization panel displays the failure reasons and the "Finalize Period" button is disabled. The step-up challenge is not triggered until all gates pass.
3. **Step-up challenge presented:** once gates pass, the UI presents a step-up challenge. The factor matches the user's configured login MFA:
   - If the user has a **passkey registered**: a passkey prompt (WebAuthn `navigator.credentials.get()`).
   - If the user has **TOTP only** (no passkey registered): a TOTP entry field (6-digit code, 30-second window).
   - If the user has **both** passkey and TOTP: passkey prompt is offered first; a "Use authenticator app instead" fallback is available.
4. **Challenge outcome:**
   - **Passed:** Block 02 Phase 06's step-up framework issues a one-time step-up token with `consumed_for_action = 'FINALIZATION'` and `expires_at = now() + interval '5 minutes'`.
   - **Failed:** No token issued. The user may retry up to 5 consecutive times before Block 02 Phase 06's lockout policy activates. Each failed attempt emits `STEP_UP_FAILED`.
5. **Confirmation step:** the UI shows a summary of the period (date range, transaction count, total amounts) with a "Confirm & Lock" button. The step-up token must still be valid when the user clicks "Confirm & Lock".
6. **`out_workflow.user_approval` / `in_workflow.user_approval` called** with the step-up token. The tool validates the token, records the `workflow_run_approvals` row with `approval_method = STEP_UP`, and emits `WORKFLOW_APPROVAL_RECORDED`. `engine.gate_approval_recorded` then returns `ADVANCE`.
7. **Token consumed:** the step-up token's `consumed_at` is set. It cannot be reused for any subsequent action, including a second finalization in the same session.

---

## 3. Approval-method matrix

The approval method is determined by the combination of role and registered MFA factor:

| Role | Passkey registered | TOTP registered | Resulting `approval_method` |
|---|---|---|---|
| Owner | Yes | — | `STEP_UP_PASSKEY` |
| Owner | No | Yes | `STEP_UP_TOTP` |
| Admin | Yes | — | `STEP_UP_PASSKEY` |
| Admin | No | Yes | `STEP_UP_TOTP` |
| Bookkeeper | Any | Any | Not permitted — `STANDARD` only |
| Accountant | Any | Any | Not permitted — no finalization approval rights |
| Reviewer | Any | Any | Not permitted |
| Read-only | Any | Any | Not permitted |

Both `STEP_UP_PASSKEY` and `STEP_UP_TOTP` produce a `workflow_run_approvals` row with `approval_method = 'STEP_UP'`. The sub-field (`PASSKEY` vs `TOTP`) is captured in `approval_mfa_factor` on the approvals table for audit traceability but does not affect gate evaluation — `engine.gate_approval_recorded` checks `approval_method = 'STEP_UP'` regardless of factor.

### Bookkeeper role clarification

Bookkeepers may record `STANDARD` approvals that clear `HUMAN_REVIEW_HOLD` (per `step_up_auth_for_workflow_approval` policy). They cannot record `STEP_UP` approvals and therefore cannot satisfy `engine.gate_approval_recorded`. If a Bookkeeper is the only available user, an Owner or Admin must perform the finalization approval. This is an intentional access control: finalization is an irreversible write to the `archive` schema, and the permission matrix assigns the `FINALIZATION` surface exclusively to Owner and Admin.

---

## 4. `STANDARD` approval (non-finalization context)

`STANDARD` approval (no step-up) is reserved for HUMAN_REVIEW_HOLD gate clearing in Block 12 Phase 07 and Block 13 Phase 09. In those contexts, the mid-workflow approval may or may not require step-up depending on the run's scope thresholds (per `step_up_auth_for_workflow_approval`). The `STANDARD` method explicitly does not satisfy `engine.gate_approval_recorded`. This separation is by design.

---

## 5. Step-up validity window

The step-up token issued at challenge-pass is valid for exactly **5 minutes**. This window covers the gap between challenge completion and the user clicking "Confirm & Lock".

If the user completes the step-up challenge but does not click "Confirm & Lock" within 5 minutes:

- The token expires (`consumed_at IS NULL`, `expires_at < now()`).
- The `workflow_run_approvals` call is rejected with `STEP_UP_TOKEN_EXPIRED`.
- The UI surfaces a notice: "Your verification has expired. Please re-verify to finalize."
- The step-up challenge must be repeated from step 3 above.
- Emits `STEP_UP_TOKEN_EXPIRED` audit event.

The 5-minute window is shorter than the general `step_up_validity_window_policy` default (30 minutes used for HUMAN_REVIEW_HOLD approvals). The tighter window is intentional: finalization is a high-consequence, irreversible action that benefits from recency of authentication.

---

## 6. Token consumption — single use

A step-up token issued for the finalization flow is consumed exactly once. After `workflow_run_approvals` records the row, the token's `consumed_at` is set. Any subsequent call presenting the same token is rejected with `STEP_UP_TOKEN_ALREADY_CONSUMED`. This applies even if the user attempts to finalize a second period in the same browser session immediately after the first — a fresh step-up challenge is required per period.

There is no "batch finalization" path that would allow a single step-up token to authorize multiple period closings.

---

## 7. Mobile rejection

The finalization action is a **desktop-only write surface**. `archive.lock_period` (Block 15 Phase 04's tool) is listed in `mobile_write_rejection_endpoints`. Mobile clients attempting to initiate finalization receive HTTP 405 with `MOBILE_WRITE_REJECTED`. The step-up challenge UI is not presented to mobile clients.

Read access to finalized archive data — viewing locked ledger entries, downloading archive packages — is available on mobile (download starts on the user's device).

---

## 8. Retry and lockout

Up to 5 consecutive step-up failures are permitted before Block 02 Phase 06's lockout policy activates. The lockout is at the per-user, per-business scope. Locked-out users cannot attempt finalization until the lockout window expires or an Owner resets the lockout via Block 02 Phase 04's admin surface.

Each failure emits `STEP_UP_FAILED`. The 6th attempt emits `MFA_CHALLENGE_FAILED` with a lockout flag. Recovery emits `MFA_ENROLLED` (if the user re-enrolls) or times out per the lockout window.

---

## Cross-references
- `step_up_auth_for_workflow_approval` — general step-up threshold policy for mid-workflow approvals
- `step_up_validity_window_policy` — general token lifecycle; this policy overrides the window to 5 minutes for finalization
- `permission_matrix` — `FINALIZATION` surface (Owner/Admin only); `WORKFLOW_APPROVE` surface
- `mobile_write_rejection_endpoints` — `archive.lock_period` listed as a mobile-rejected endpoint
- `audit_log_policies` — `STEP_UP_*`, `WORKFLOW_APPROVAL_RECORDED`, `FINALIZATION_*` event naming
- `audit_event_taxonomy` — TENANCY (`STEP_UP_*`) and FINALIZATION domain events
- Block 02 Phase 03 — MFA factors (TOTP + WebAuthn / passkeys)
- Block 02 Phase 06 — step-up authentication framework; lockout policy
- Block 12 Phase 01 — `workflow_run_approvals` table; `approval_method` enum
- Block 15 Phase 02 — `engine.gate_approval_recorded` gate definition
- Block 15 Phase 03 — approval modality architecture

---

## 9. Staleness interaction

If a workflow run that has a recorded `STEP_UP` approval subsequently re-enters `REVIEW_HOLD` (e.g., a new BLOCKING issue is raised by a late-arriving document rescan), the existing approval row is marked stale by Block 12 Phase 07's staleness rule. `engine.gate_approval_recorded` then returns `HOLD` because the most recent non-revoked `STEP_UP` row's `data_state_hash` no longer matches the run's current state.

When this occurs:
- The UI informs the user: "A new issue was raised after your last verification. Please re-verify to finalize."
- The user must resolve the new issue(s) first (return to the Review Queue).
- Once all gates pass again, a fresh step-up challenge is issued and a new approval row is recorded.

The stale approval row remains in the audit log. The gate evaluates only the most recent non-revoked row with `approval_method = 'STEP_UP'` and a matching `data_state_hash`.

---

## 10. Audit events emitted

| Event | When |
|---|---|
| `STEP_UP_REQUIRED` | UI determines step-up is needed before challenge is presented |
| `STEP_UP_PASSED` | Challenge passed; token issued |
| `STEP_UP_FAILED` | Challenge failed (per attempt) |
| `STEP_UP_TOKEN_CONSUMED` | Token consumed on successful `workflow_run_approvals` write |
| `STEP_UP_TOKEN_EXPIRED` | Token expired before use |
| `STEP_UP_TOKEN_ALREADY_CONSUMED` | Duplicate token presentation rejected |
| `WORKFLOW_APPROVAL_RECORDED` | Approval row written with `approval_method = STEP_UP` |
| `FINALIZATION_APPROVAL_RECORDED` | Block 15's cross-check event confirming a qualifying approval exists |
| `FINALIZATION_APPROVAL_NOT_QUALIFIED` | Gate rejects a `STANDARD` approval presented for finalization |

All `STEP_UP_*` events are in the `TENANCY` / `MFA` domain. `WORKFLOW_APPROVAL_RECORDED` is in the `WORKFLOW` domain. `FINALIZATION_*` events are in the `FINALIZATION` domain. All already exist in `audit_event_taxonomy`.
