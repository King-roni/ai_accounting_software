# Block 02 — Phase 02: Authentication Baseline

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Authentication section)
- Decisions log: `Docs/decisions_log.md` (Supabase Auth available; MFA factors arrive in Phase 03)

## Phase Goal

Users can sign up with email + password, verify their email, log in, log out, reset their password, and stay authenticated via session cookies. No MFA yet — that's Phase 03. No role-aware access yet — that's Phase 04.

## Dependencies

- Phase 01 (schema in place; `users` profile row created on signup)
- Email service for verification and reset emails (sub-doc choice — see hooks)

## Deliverables

- **Sign-up endpoint + UI** — email + password, captures display name, creates a `public.users` row linked to the Supabase `auth.users` row.
- **Email verification flow** — verification link sent on signup; login refused until email is verified.
- **Login endpoint + UI** — email + password challenge, returns session cookie.
- **Logout endpoint** — invalidates the session token.
- **Password reset flow** — request → email link → reset form.
- **Session lifecycle:**
  - HttpOnly + Secure + SameSite cookies.
  - Short access token lifetime; refresh token rotation on each refresh.
  - Re-authentication required for sensitive actions (full implementation in Phase 06).
- **Rate limiting** on `/login`, `/signup`, `/password-reset` endpoints (per IP and per email).
- **Audit events** (auth-flow only — profile and email-change events are owned by Phase 11)**:** `LOGIN`, `LOGIN_FAILED`, `LOGOUT`, `SIGNUP`, `EMAIL_VERIFIED`, `PASSWORD_RESET_REQUESTED`, `PASSWORD_RESET_COMPLETED`.
- **Account-locked-out flow** when failed login attempts exceed threshold.

## Definition of Done

- A new user can sign up, receive a verification email, click the link, log in, and land on the post-login screen.
- Logging in with the wrong password produces a `LOGIN_FAILED` audit event and increments the failed-attempt counter.
- After N failed attempts, the account is locked for a configured cooldown.
- Logging out invalidates the session — using the old cookie returns 401.
- Password reset flow round-trips end-to-end.
- All auth events appear in the audit log with correct actor + IP context.
- Rate limits trigger on rapid repeated requests.

## Sub-doc Hooks (Stage 4)

- **Email service sub-doc** — transactional email provider (Resend, Postmark, SES — EU region required), sender domain, DKIM/SPF setup, template management.
- **Password policy sub-doc** — minimum length, complexity rules, breach-list checking.
- **Session lifetime sub-doc** — access token TTL, refresh token TTL, idle timeout, absolute timeout values.
- **Rate-limit configuration sub-doc** — per-endpoint thresholds and cooldowns.
