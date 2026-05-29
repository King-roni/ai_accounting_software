# account_email_change_flow_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The verification timeline + rollback contract for the account-email-change flow surfaced in `settings_page_ui_spec.md` §Profile. This doc is the canonical source of truth for: how long each step has, what the account state is at each step, how to recover when the user loses access to the OLD or NEW mailbox mid-flow, and what audit trail every transition emits.

Companion to `transactional_email_service_integration.md` (email delivery mechanics) and `session_schema.md` (what gets invalidated on email change).

---

## 1. The flow at a glance

```
Step 1  Request    user enters new email + current password   T0
Step 2  Confirm    user clicks link in NEW mailbox            T0 + Δ_confirm
Step 3  Notify     OLD mailbox receives "your email changed"  same tx as Step 2
Step 4  Settle     stored email = new email                   same tx as Step 2
```

Each step's authority + audit footprint + failure handling is operationalised below.

---

## 2. Step 1 — Request

### Inputs

| Field | Source | Notes |
|---|---|---|
| `new_email` | Settings form | Validated for RFC 5322 shape + DNS MX presence (best-effort, non-blocking on transient DNS failure). |
| `current_password` | Settings form | Re-auth credential. Plaintext over TLS; verified against Supabase Auth password hash before any state change. |
| Active session | Implicit (JWT) | Must be a valid step-up-fresh session per `step_up_validity_window_policy.md`. |

### Required step-up

Email-change is a HIGH-sensitivity surface per `permission_matrix.md`. The platform requires step-up freshness OR an in-flow re-auth. The current-password field IS the re-auth: a successful password match within the same request counts as step-up satisfaction for this surface only (does not refresh `step_up_qualified_until`).

If the password is wrong, the request is rejected with `AUTH_EMAIL_CHANGE_PASSWORD_REJECTED` (MEDIUM); no state change occurs. Rate limit: 5 attempts per session per hour to deter brute force.

### State change

1. `email_change_requests` row inserted with:
   - `id = gen_random_uuid()` (UUID v4 — security nonce; time-ordered would leak request time)
   - `user_id` = current `app_user_id`
   - `old_email` = current `users.email`
   - `new_email` = the requested address
   - `requested_at = now()`
   - `expires_at = now() + INTERVAL '24 hours'`
   - `confirmation_token_hash = sha256(token)` — token itself returned only via email; never stored plain
   - `status = 'PENDING'`
2. `users.email` is **NOT yet changed**. The user remains authenticated under `old_email`. Sessions are NOT invalidated.
3. Confirmation email dispatched to `new_email` via `transactional_email_service_integration` (fire-and-forget; email-dispatch failure does not roll back the row — it appears as PENDING and the user can re-request).
4. Notice email dispatched to `old_email` ("A change to <truncated_new_email> was requested. If this wasn't you, contact support."). Same fire-and-forget semantics.
5. Audit: `EMAIL_CHANGE_REQUESTED` (MEDIUM) per `audit_event_taxonomy.md`. Payload: `{user_id, old_email_hash, new_email_hash, request_id, requested_at}`. **Both addresses hashed**: per `audit_log_policies.md` PII-minimisation rule, audit rows never carry raw email addresses post-Stage-3; only SHA-256 hex of the addresses for forensic correlation.

### Hard cap on outstanding requests

A user can have at most **one** PENDING row per `user_id` at any moment. A second request supersedes the first: the prior row's `status` transitions to `SUPERSEDED`, audit `EMAIL_CHANGE_REQUEST_SUPERSEDED` (LOW) is emitted, the prior confirmation email's token is no longer valid (lookup by `confirmation_token_hash` fails because the new request's hash overrides). The old notice email already sent to OLD is not rescinded.

---

## 3. Step 2 — Confirm

### The confirmation link

Format: `https://app.cypbk.example/auth/email-change-confirm?token=<base64url-encoded 32-byte secret>`.

### Verification

On callback:

1. Compute `sha256(token)`; look up `email_change_requests` WHERE `confirmation_token_hash = <hash>` AND `status = 'PENDING'`.
2. If not found → reject with HTTP 400 + emit `EMAIL_CHANGE_CONFIRM_INVALID` (MEDIUM). No state change.
3. If found, verify `expires_at > now()`. If expired → reject + emit `EMAIL_CHANGE_CONFIRM_EXPIRED` (LOW); `status` transitions to `EXPIRED`.
4. Verify the caller is **NOT signed in as a different user**: the callback handler accepts both authenticated and anonymous callers (the confirmation link may be clicked from the new email's device where the user isn't signed in). If the caller IS signed in as a user whose `id != email_change_requests.user_id`, reject + emit `EMAIL_CHANGE_CONFIRM_USER_MISMATCH` (HIGH) — possible phishing redirection attempt.
5. If all checks pass, atomically (single transaction):
   - `UPDATE users SET email = <new_email> WHERE id = <user_id>`
   - `UPDATE email_change_requests SET status = 'CONFIRMED', confirmed_at = now() WHERE id = <request_id>`
   - Revoke ALL active sessions for the user EXCEPT the one that initiated Step 1 (if it's still valid; identified by `user_sessions.id = email_change_requests.initiating_session_id` from §2 row, stored at request time). See §4 for the rationale.
   - Dispatch the "your email changed" notification to `old_email` (Step 3).
   - Emit `EMAIL_CHANGED` (HIGH) per `audit_event_taxonomy.md`. Payload: `{user_id, old_email_hash, new_email_hash, request_id, confirmed_at}`.

### Confirmation UX

After successful confirmation, the user is redirected to `/auth/email-change-confirmed` (a static success page). If the user was anonymous at click time, they are redirected to `/login` with the message "Email change confirmed. Please sign in with your new email." The new email pre-fills the login form.

### Δ_confirm — the verification timeline

| Element | Value | Source |
|---|---|---|
| Token TTL | **24 hours** from `requested_at` | §2 `expires_at` default |
| Rate of confirmation reminders | 0 | We do not nag; one email at request time is the sole confirmation surface. |
| Re-request policy | Always allowed; supersedes prior PENDING row per §2 hard-cap rule | — |
| Token reuse after confirmation | NEVER. `confirmation_token_hash` is single-use; subsequent presentations of the same token return `EMAIL_CHANGE_CONFIRM_INVALID`. | — |

The 24-hour window is a deliberate trade-off: long enough for a user to find an email in spam, short enough that an attacker who briefly compromised the user's old email session can't reuse a stale `email_change_requests` row indefinitely.

---

## 4. Session revocation on confirmation

When email changes, all sessions EXCEPT the initiating session are revoked. Rationale:

- Sessions that pre-date the change were bound to the OLD email (in the JWT's contextual claims and in any cached client state). Allowing them to continue would let an old-mailbox-compromised attacker maintain access after the legitimate owner changed the address.
- The initiating session is preserved so the user isn't immediately logged out of the tab where they were doing the change. If that tab's session was the only active one, no other sessions exist and the rule is a no-op.

Mechanism: a SECURITY DEFINER function `auth.revoke_other_sessions(user_id uuid, except_session_id uuid)` is called inside the Step-2 atomic transaction. It sets `user_sessions.is_revoked = true` and `user_sessions.revoked_reason = 'EMAIL_CHANGED'` on all matching rows.

The user is informed via the post-confirm redirect page: "Your email has been changed. Other devices have been signed out for security."

---

## 5. Rollback — losing access mid-flow

### Case A — User loses access to OLD email after Step 1 but before Step 2

The user submitted the request. The notice email went to the OLD mailbox (irrelevant — they don't have access). The confirmation email went to the NEW mailbox. If the user has access to the NEW mailbox, they confirm normally. Step 2 proceeds; OLD mailbox notice is silently ignored. Nothing to roll back.

### Case B — User loses access to NEW email after Step 1 but before Step 2

The user submitted the request but didn't read the confirmation email and the new address is now inaccessible (mistyped, mailbox went away, ISP outage). The PENDING row sits at `status = 'PENDING'` and expires at T0 + 24h.

**Recovery options:**

1. **Wait for expiry** (24h), then submit a new Step 1 with a corrected `new_email`. The expired row transitions to `EXPIRED` via the periodic GC job (`gc_email_change_requests` runs hourly) or on next Step-1 submission.
2. **Active cancel** — `settings_page_ui_spec.md` exposes "Cancel pending email change" while a PENDING row exists. Cancel calls `auth.email_change_cancel(request_id)`, sets `status = 'CANCELLED'`, emits `EMAIL_CHANGE_CANCELLED` (LOW). The user can then submit a new Step 1 immediately.

### Case C — User loses access to BOTH old AND new email mid-flow

This is the "lost the laptop with both mailboxes" case. The user cannot self-recover via the in-product flow because both email-based surfaces are inaccessible.

**Recovery procedure** — out-of-band, owned by Support:

1. User contacts Support via the in-product "Contact support" form (which does NOT require email access — the user is still signed in via the session that initiated Step 1, or via the password-only login). The form captures `user_id`, current claimed identity, and a request to "abandon email change and update to <third email>".
2. Support verifies identity via `account_recovery_runbook.md` (governmental ID match against `users.legal_identity_document_hash` per GDPR identity-proofing requirements).
3. Support invokes `auth.support_force_email_change(user_id, new_email, support_ticket_id)` — SECURITY DEFINER, audit-logged `EMAIL_CHANGED` with `via_support: true` payload field + `support_ticket_id` reference.
4. The flow is identical to a normal Step 2 confirmation thereafter: sessions revoked, OLD mailbox notice attempted (best-effort; may bounce — acceptable).

### Case D — User confirms (Step 2) but then realises the new email was wrong

The PENDING → CONFIRMED transition is irreversible from the user's side. The user can submit a NEW email-change request immediately to correct the mistake; the new flow goes through Step 1 again under the now-confirmed email. There is no "undo" button. Audit trail shows the back-and-forth.

---

## 6. Audit events introduced or consumed

| Event | Severity | Trigger | Payload |
|---|---|---|---|
| `EMAIL_CHANGE_REQUESTED` | MEDIUM | Step 1 success | `{user_id, old_email_hash, new_email_hash, request_id, requested_at}` |
| `EMAIL_CHANGE_PASSWORD_REJECTED` | MEDIUM | Step 1 re-auth failed | `{user_id, attempts_remaining}` |
| `EMAIL_CHANGE_REQUEST_SUPERSEDED` | LOW | New Step 1 supersedes prior PENDING | `{prior_request_id, new_request_id}` |
| `EMAIL_CHANGE_CONFIRM_INVALID` | MEDIUM | Step 2 token not found | `{token_hash_prefix}` (first 8 hex chars only, for correlation) |
| `EMAIL_CHANGE_CONFIRM_EXPIRED` | LOW | Step 2 token past `expires_at` | `{request_id}` |
| `EMAIL_CHANGE_CONFIRM_USER_MISMATCH` | HIGH | Step 2 caller signed in as different user | `{request_id, caller_user_id, expected_user_id}` |
| `EMAIL_CHANGED` | HIGH | Step 2 atomic success | `{user_id, old_email_hash, new_email_hash, request_id, confirmed_at, via_support: bool, support_ticket_id?}` |
| `EMAIL_CHANGE_CANCELLED` | LOW | User active-cancels a PENDING row | `{request_id}` |

`EMAIL_CHANGE_CONFIRM_USER_MISMATCH` at HIGH severity feeds the security alerting layer per `security_alert_routing_policy.md` §1 (HIGH events go to active-Owner email + dashboard).

**Cross-block coordination flagged for B05·P02 implementation:** confirm taxonomy registers all 8 events above; confirm `EMAIL_CHANGED` payload supports the `via_support: bool` + optional `support_ticket_id` fields.

---

## 7. The `email_change_requests` table

```sql
CREATE TABLE email_change_requests (
  id                          uuid PRIMARY KEY,
  user_id                     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  old_email                   text NOT NULL,
  new_email                   text NOT NULL,
  confirmation_token_hash     bytea NOT NULL,                            -- SHA-256 of the 32-byte secret
  initiating_session_id       uuid REFERENCES user_sessions(id),         -- preserved across Step-2 revoke per §4
  status                      email_change_status_enum NOT NULL DEFAULT 'PENDING',
  requested_at                timestamptz NOT NULL DEFAULT now(),
  expires_at                  timestamptz NOT NULL,
  confirmed_at                timestamptz,
  cancelled_at                timestamptz,
  CONSTRAINT ecr_expiry_chk      CHECK (expires_at > requested_at),
  CONSTRAINT ecr_terminal_at_chk CHECK (
    (status = 'CONFIRMED' AND confirmed_at IS NOT NULL) OR
    (status = 'CANCELLED' AND cancelled_at IS NOT NULL) OR
    (status IN ('PENDING', 'EXPIRED', 'SUPERSEDED'))
  )
);

CREATE TYPE email_change_status_enum AS ENUM ('PENDING', 'CONFIRMED', 'EXPIRED', 'CANCELLED', 'SUPERSEDED');

-- One PENDING row per user (hard cap from §2)
CREATE UNIQUE INDEX ecr_one_pending_per_user
  ON email_change_requests(user_id)
  WHERE status = 'PENDING';

-- Lookup index for Step-2 confirm
CREATE INDEX ecr_by_token_hash
  ON email_change_requests(confirmation_token_hash)
  WHERE status = 'PENDING';

-- GC index for expiry sweep
CREATE INDEX ecr_pending_expiry
  ON email_change_requests(expires_at)
  WHERE status = 'PENDING';
```

RLS: only the row's `user_id` (via `current_user_id()`) can SELECT its own rows. INSERT/UPDATE go through SECURITY DEFINER RPCs (`auth.email_change_request`, `auth.email_change_confirm`, `auth.email_change_cancel`, `auth.support_force_email_change`).

**Cross-block coordination flagged for B02·P11 migration:** add this table + enum + 3 indexes; wire the GC job per `email_change_requests` periodic-expiry sweep.

---

## 8. Cross-references

- `settings_page_ui_spec.md` §Profile — Step 1 entry point UI
- `transactional_email_service_integration.md` — confirmation + notice email dispatch
- `audit_event_taxonomy.md` — 8 events introduced (§6, cross-block flagged for B05·P02)
- `audit_log_policies.md` — PII-minimisation rule requiring email hashing in audit payloads
- `session_schema.md` — `user_sessions` table; `revoked_reason = 'EMAIL_CHANGED'` consumed at §4
- `session_lifetime_policy.md` — session-validity precondition for Step 1
- `step_up_validity_window_policy.md` — re-auth-as-step-up rule for Step 1
- `permission_matrix.md` — HIGH-sensitivity surface classification
- `password_policy.md` — current-password validation rules
- `account_recovery_runbook.md` — Case C support-driven recovery (governmental ID verification)
- `gdpr_data_subject_rights_policy.md` — `legal_identity_document_hash` source for Case C
- `mobile_write_rejection_endpoints.md` — Step 1 is a write surface; mobile blocked (consistent with phase-doc desktop-only-in-MVP rule)
- Block 02 Phase 02 — auth + email (consumer of the new email value post-confirmation)
- Block 02 Phase 06 — step-up rules (informs §2 re-auth semantics)
- Block 02 Phase 11 — account settings (owning phase)
- Block 05 Phase 02 — audit taxonomy (consumer of 8 new events)
- Stage 1 decision — email change is verification-required (binding to this doc's two-step + supersede rules)
