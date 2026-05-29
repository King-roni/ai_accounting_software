# Session Management Policy

**Block:** Auth  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines how user sessions are created, maintained, refreshed, and invalidated across the platform. Session management is implemented on top of Supabase Auth. All session tokens are short-lived JWTs backed by rotating refresh tokens. The policy applies uniformly to web and mobile clients; mobile clients are subject to a shorter inactivity timeout as noted in the Mobile section.

---

## Session Lifecycle

### 1. Login

A session begins when a user successfully authenticates via email/password or an OAuth provider. Supabase Auth issues:

- **Access token** — a signed JWT valid for **60 minutes**.
- **Refresh token** — a single-use opaque token valid for **7 days**, stored in `auth.refresh_tokens` (Supabase managed).
- **Session ID** — generated with `gen_random_uuid()` (not `gen_uuid_v7()`). Session IDs are ephemeral identifiers; collision resistance matters more than temporal ordering.

The access token carries standard JWT claims (`sub`, `aud`, `exp`, `iat`, `role`) plus application-level claims (`business_id`, `org_role`). The JWT is signed with the project's HS256 secret managed by Supabase Auth.

On session creation the platform emits `AUTH_SESSION_CREATED` (severity: LOW) to `audit_log`.

### 2. Active Session

Clients attach the access token as a `Bearer` header on every API request. The Supabase PostgREST layer and Edge Functions validate the JWT on each call. No server-side session store is consulted per request — validation is stateless via JWT signature.

If the access token has expired, the client must perform a refresh before issuing further requests.

### 3. Refresh

When the access token expires or is within 5 minutes of expiry, the client sends the refresh token to `POST /auth/v1/token?grant_type=refresh_token`. Supabase Auth:

1. Validates the refresh token (checks it has not been used, not expired, belongs to the session).
2. Issues a **new** access token (1-hour expiry) and a **new** refresh token (7-day expiry).
3. Marks the old refresh token as consumed (single-use rotation).

The platform emits `AUTH_SESSION_REFRESHED` (severity: LOW) to `audit_log` on each successful refresh.

Refresh token reuse attempts (replaying a consumed token) result in immediate session revocation and emit `AUTH_SESSION_REVOKED` (severity: MEDIUM).

### 4. Logout

On explicit logout, the client calls `POST /auth/v1/logout`. Supabase Auth revokes all refresh tokens for the session. The platform emits `AUTH_SESSION_REVOKED` (severity: MEDIUM).

Clients must discard the access token from memory immediately. Access tokens are JWTs and remain technically valid until expiry even after logout — the 1-hour window is the accepted gap; no token blocklist is maintained.

### 5. Session Expiry

A session expires when:

- The 7-day refresh token window passes without a successful refresh.
- The user changes their password (see Invalidation Triggers).
- An admin triggers a force-logout.

On natural expiry the platform emits `AUTH_SESSION_EXPIRED` (severity: LOW).

---

## Concurrent Session Limit

Each user may hold a maximum of **5 concurrent active sessions** across all devices and browsers. This limit is enforced at login:

1. Before creating a new session, count active sessions for the user in `auth.sessions`.
2. If the count equals 5, revoke the oldest session (by `created_at`) before issuing the new one.
3. Emit `AUTH_SESSION_REVOKED` for the evicted session.

This policy prevents credential-sharing abuse and limits blast radius if a refresh token is leaked.

---

## Session Invalidation Triggers

The following events immediately invalidate **all** active sessions for the affected user:

| Trigger | Action | Audit Event |
|---|---|---|
| Password change | Revoke all sessions | AUTH_SESSION_REVOKED (MEDIUM) per session |
| MFA enrolment | Revoke all sessions | AUTH_SESSION_REVOKED (MEDIUM) per session |
| MFA unenrolment | Revoke all sessions | AUTH_SESSION_REVOKED (MEDIUM) per session |
| Admin force-logout | Revoke target session(s) | AUTH_SESSION_REVOKED (MEDIUM) |
| Device mismatch (see below) | Flag session; prompt step-up | AUTH_SESSION_DEVICE_MISMATCH (MEDIUM) |
| Account suspension | Revoke all sessions | AUTH_SESSION_REVOKED (MEDIUM) per session |

On password change, the platform calls `auth.admin.signOut(userId, 'global')` via the Supabase Admin API from a privileged Edge Function. The caller's current session is re-established after the password change flow completes.

---

## Device Fingerprint Tracking

Each session stores a lightweight device fingerprint at creation and refresh time. The fingerprint comprises:

- **User-Agent string** — extracted from the HTTP `User-Agent` header.
- **IP address** — client IP resolved from the request, stored as `TEXT` after hashing with SHA-256 (PII minimisation).
- **Timestamp** — `occurred_at` of the fingerprint record.

Fingerprint data is stored in the application's `session_device_fingerprints` table (separate from `auth.sessions`, which is Supabase managed). The table references `session_id` and `business_id`.

On each token refresh, the current fingerprint is compared against the fingerprint recorded at session creation. If the IP geolocation resolves to a location more than **500 km** from the creation-time location within a **1-hour** window, the platform:

1. Sets a `device_mismatch` flag on the session record.
2. Emits `AUTH_SESSION_DEVICE_MISMATCH` (severity: MEDIUM) to `audit_log`.
3. Places the session in a `STEP_UP_REQUIRED` state — the next write operation requires step-up MFA before it proceeds.

IP geolocation is performed via a cached lookup table (MaxMind GeoLite2 or equivalent). Lookups are performed at the Edge Function layer. Failed lookups are logged and treated as non-blocking (the session continues without the distance check).

---

## Session Table Overview

Session state is managed by Supabase Auth in the `auth.sessions` and `auth.refresh_tokens` tables. These are Supabase-managed and not directly accessible via application DDL. Application code accesses session data via:

- `auth.uid()` — current user ID, callable from RLS policies.
- `auth.jwt()` — full decoded JWT, callable from RLS policies.
- Supabase Admin API — callable only from privileged Edge Functions.

The application maintains a supplementary `session_device_fingerprints` table for device tracking and a `session_flags` table for mismatch/step-up state. Both tables carry `business_id FK REFERENCES business_entities(id)`.

---

## Refresh Token Rotation

Refresh tokens are **single-use**. On every successful refresh:

- The old refresh token is marked consumed.
- A new refresh token is issued with a fresh 7-day window.
- The session's `updated_at` timestamp advances.

If a consumed refresh token is replayed:

1. The entire session is immediately revoked.
2. All other sessions for the same user are revoked (session-theft response).
3. The event is logged as `AUTH_SESSION_REVOKED` (severity: MEDIUM) with `payload.reason = "refresh_token_reuse"`.
4. The user is notified via email that their session was invalidated due to a suspected token replay.

---

## Suspicious Session Detection

Beyond device mismatch, the following patterns are treated as suspicious and trigger the same step-up flow:

- Refresh from a Tor exit node or known VPN IP (checked against a blocklist updated weekly).
- More than 10 refresh attempts within 60 seconds from a single session.
- Access from an IP in a country not previously seen for the account within the last 90 days.

Suspicious session events are routed to the security alert system per `security_alert_routing_policy.md`.

---

## Audit Events

| Event Name | Severity | Trigger |
|---|---|---|
| AUTH_SESSION_CREATED | LOW | New session established after successful login |
| AUTH_SESSION_REFRESHED | LOW | Refresh token exchanged successfully |
| AUTH_SESSION_EXPIRED | LOW | Session expired without explicit logout |
| AUTH_SESSION_REVOKED | MEDIUM | Explicit logout, force-logout, or invalidation trigger |
| AUTH_SESSION_DEVICE_MISMATCH | MEDIUM | IP geolocation shift > 500 km within 1 hour |

All events are written via `auth.emit_audit` and stored in `audit_log` with `actor_type = 'USER'` or `'SYSTEM'` as appropriate.

---

## Mobile

Mobile clients follow the same session lifecycle with the following differences:

- **Inactivity timeout:** 30 minutes of app backgrounding triggers an automatic session expiry. The app layer monitors `applicationDidEnterBackground` (iOS) / `onPause` (Android) and schedules a local timer to revoke the session if the app remains in the background past 30 minutes.
- **Refresh on foreground:** When the app returns to the foreground, it checks access token expiry and performs a silent refresh before resuming API calls.
- **Biometric gate:** On mobile, step-up authentication triggered by `AUTH_SESSION_DEVICE_MISMATCH` presents the device biometric prompt rather than an OTP form. The biometric result is used to confirm intent; the underlying step-up token is still issued via `auth.step_up_request`.
- **Token storage:** Access and refresh tokens must be stored in the platform keychain (iOS Keychain / Android Keystore). Storing tokens in shared preferences, `AsyncStorage`, or local storage is prohibited.
- **Device fingerprint:** Mobile clients include the device model identifier in the fingerprint in addition to User-Agent and IP.

---

## Related Documents

- `policies/mfa_policy.md`
- `policies/step_up_auth_for_workflow_approval_policy.md`
- `policies/step_up_validity_window_policy.md`
- `policies/password_policy.md`
- `policies/security_alert_routing_policy.md`
- `policies/session_lifetime_policy.md`
- `schemas/session_schema.md`
- `schemas/step_up_token_schema.md`
- `tools/tool_session_refresh.md`
- `tools/tool_step_up_request.md`
