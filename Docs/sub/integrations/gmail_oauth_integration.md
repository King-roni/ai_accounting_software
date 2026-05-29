# Gmail OAuth Integration

**Block:** 02 — Tenancy & Access
**Category:** Integrations
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Documents the Google OAuth 2.0 integration that grants the document intake pipeline
read access to a business's Gmail inbox and Google Drive. This file is the binding
reference for the authorization code flow, token lifecycle, scope enforcement, and
revocation path. It covers only the auth surface; the downstream intake behaviour
driven by these tokens is owned by Block 09.

---

## OAuth 2.0 Flow

The integration uses the authorization code flow with PKCE (RFC 7636). No implicit or
device flows are used.

### Step-by-step

1. The application generates a cryptographically random `code_verifier` (32 bytes,
   base64url-encoded). The `code_challenge` is `BASE64URL(SHA-256(code_verifier))`.
2. A new row is inserted into `oauth_states` with `id = gen_random_uuid()` (UUID v4
   per `data_layer_conventions_policy` — OAuth state IDs are security nonces where
   a time-ordered prefix would leak creation time). The row carries `user_id`,
   `business_id`, `provider = 'google'`, `code_verifier` (encrypted at rest),
   `expires_at = NOW() + INTERVAL '15 minutes'`, and `consumed_at = NULL`.
   Audit event: `OAUTH_STATE_CREATED`.
3. The user is redirected to Google's authorization endpoint. The `state` parameter
   in the redirect URL is the `oauth_states.id` (UUID). The `code_challenge` and
   `code_challenge_method=S256` are included. Scopes requested: `gmail.readonly` and
   `drive.readonly` (see "Scope enforcement" below).
4. On callback, the application receives `code` and `state`. It immediately loads the
   `oauth_states` row matching `state`, verifies `expires_at > NOW()` and
   `consumed_at IS NULL`, then sets `consumed_at = NOW()` in the same transaction
   (atomic consume-and-mark). If the row is missing, expired, or already consumed,
   the callback is rejected with HTTP 400. Audit event: `OAUTH_STATE_CONSUMED`.
5. The application exchanges the `code` + `code_verifier` for an access token and
   refresh token at Google's token endpoint. The access token and refresh token are
   encrypted (AES-256-GCM) and stored in `oauth_tokens`. Audit event:
   `AUTH_OAUTH_CONNECTED`.
6. The `oauth_states` row is deleted immediately after the token exchange completes
   successfully. If the exchange fails, the row is not deleted (the consume mark
   prevents replay).

Unused `oauth_states` rows (expired without callback) are purged by a background job
after a 24-hour post-expiry window. Audit event: `OAUTH_STATE_EXPIRED_UNUSED`.

---

## Scopes

Two scopes are requested:

| Scope | Purpose |
| --- | --- |
| `https://www.googleapis.com/auth/gmail.readonly` | Read inbox for document attachment discovery |
| `https://www.googleapis.com/auth/drive.readonly` | Read Drive for document file discovery |

No write scopes are requested at any point. The OAuth consent screen explicitly lists
both scopes. Google's incremental authorization is not used; both scopes are requested
in a single authorization request.

The user's explicit per-scope consent is recorded by Google and surfaced on the consent
screen. The platform does not re-request scopes that have already been granted unless a
`AUTH_OAUTH_PERMISSION_DOWNGRADED` event triggers a re-authorization flow.

---

## Token Storage

Access tokens and refresh tokens are stored in the `oauth_tokens` table:

```sql
-- Canonical DDL: see oauth_token_encryption_schema.md. This document covers the OAuth lifecycle and refresh strategy; table definition is owned by oauth_token_encryption_schema.md.
```

The plaintext of neither token is ever written to the database, application logs, or
any downstream storage. Per `no_plaintext_fallback_policy`, if the encryption helper
is unavailable at write time, the write fails with `ENCRYPTION_UNAVAILABLE`; there is
no silent fallback path.

DEK rotation follows `encryption_at_rest_policy`. On key rotation, `oauth_tokens` rows
are re-encrypted in a background migration that processes one row at a time to avoid
locking the table.

---

## Refresh Strategy

Google access tokens expire after 3,600 seconds (1 hour). The platform refreshes
proactively and reactively:

**Proactive:** The token refresh job runs every 50 minutes and refreshes any
`oauth_tokens` row where `expires_at < NOW() + INTERVAL '10 minutes'`. This prevents
expiry mid-request during intake runs.

**Reactive:** If an intake tool receives an HTTP 401 from the Gmail or Drive API, it
calls the token refresh path inline, updates `oauth_tokens.access_token_enc` and
`expires_at`, then retries the original request once. Audit event:
`AUTH_OAUTH_TOKEN_REFRESHED`.

**Refresh failure path:** If the refresh call returns an error (e.g. the refresh token
was revoked by the user via Google's account settings), the platform:

1. Sets `gmail_sources.status = 'INACTIVE'` for all Gmail sources associated with
   the `business_id`.
2. Emits audit event `AUTH_OAUTH_TOKEN_REVOKED` with `revocation_reason =
   'REFRESH_FAILED'`.
3. Creates a `REVIEW_ISSUE` of type `OAUTH_TOKEN_REVOKED` in the review queue so the
   business owner is notified to re-authorize.
4. Halts any in-progress intake run that was using the revoked token. The run
   transitions to `REVIEW_HOLD`.

Re-authorization requires the user to complete the OAuth flow from step 1 again. The
old `oauth_tokens` row is deleted before the new one is written.

---

## Scope Enforcement

The `scopes_granted` column on `oauth_tokens` is checked by intake tools before
attempting any API call. Two degraded modes apply:

| Scopes granted | Intake behaviour |
| --- | --- |
| Both `gmail.readonly` and `drive.readonly` | Full intake: email finder + Drive finder |
| `gmail.readonly` only | Attachment-only mode: email attachments are processed; Drive finder is disabled for this business |
| `drive.readonly` only | Drive finder runs; email finder is disabled |
| Neither scope granted | Intake is fully disabled for the business; the review queue shows an `OAUTH_SCOPE_INSUFFICIENT` issue |

If a user re-authorizes but grants fewer scopes than were previously granted (e.g.
removes `drive.readonly`), the platform emits `AUTH_OAUTH_PERMISSION_DOWNGRADED` and
updates `scopes_granted` to reflect the reduced grant. Intake degrades to the
appropriate mode without requiring a re-run.

---

## Token Revocation

Token revocation is initiated in two scenarios:

**User-initiated disconnect:** When a business owner disconnects the Google integration
via account settings, the platform immediately calls Google's token revocation endpoint
(`https://oauth2.googleapis.com/revoke`) with the refresh token. Whether or not
Google's endpoint responds successfully, the `oauth_tokens` row is deleted and
`gmail_sources.status` is set to `'INACTIVE'`. Audit event: `AUTH_OAUTH_TOKEN_REVOKED`
with `revocation_reason = 'USER_DISCONNECT'`.

**Business deactivation:** When a `business_entities` row is deactivated
(`TENANCY_BUSINESS_DEACTIVATED`), the deactivation handler revokes all active OAuth
tokens for the business using the same path above. Audit event:
`AUTH_OAUTH_TOKEN_REVOKED` with `revocation_reason = 'BUSINESS_DEACTIVATED'`.

In both cases the revocation call to Google is fire-and-forget (best-effort). Token
deletion from the local database is not conditional on Google's response.

---

## Audit Events

| Event | Severity | Trigger |
| --- | --- | --- |
| `AUTH_OAUTH_CONNECTED` | LOW | OAuth flow completed; access + refresh tokens stored |
| `AUTH_OAUTH_TOKEN_REFRESHED` | LOW | Access token refreshed successfully via refresh token |
| `AUTH_OAUTH_TOKEN_REVOKED` | MEDIUM | Token revoked (user disconnect, business deactivation, or refresh failure) |
| `AUTH_OAUTH_PERMISSION_DOWNGRADED` | MEDIUM | Re-authorization granted fewer scopes than the previous grant |
| `OAUTH_STATE_CREATED` | LOW | `oauth_states` row inserted (redirect initiated) |
| `OAUTH_STATE_CONSUMED` | LOW | Callback validated; state row marked consumed |
| `OAUTH_STATE_EXPIRED_UNUSED` | LOW | Purge job removed an unconsumed expired state row |

`AUTH_OAUTH_TOKEN_REVOKED` payload includes: `business_id`, `user_id`, `provider`,
`revocation_reason` (`USER_DISCONNECT` | `BUSINESS_DEACTIVATED` | `REFRESH_FAILED`),
`revoked_at`.

`AUTH_OAUTH_PERMISSION_DOWNGRADED` payload includes: `business_id`, `user_id`,
`previous_scopes`, `new_scopes`, `removed_scopes`.

`AUTH_OAUTH_CONNECTED` payload includes: `business_id`, `user_id`, `provider`,
`scopes_granted`, `connected_at`.

---

## Mobile

The OAuth authorization redirect is initiated from the web client. Write surfaces
(token storage, connect, disconnect) reject mobile clients per
`mobile_write_rejection_endpoints.md`. The OAuth callback endpoint is not a write
surface accessible from the mobile client — it is a server-side redirect handler.

---

## Cross-references

- `oauth_state_schema.md` — `oauth_states` table DDL and UUID v4 rationale
- `session_schema.md` — session context used when initiating the OAuth flow
- `document_gmail_query_schema.md` — how stored Gmail queries use the token
- `encryption_at_rest_policy.md` — AES-256-GCM encryption helper and DEK hierarchy
- `no_plaintext_fallback_policy.md` — prohibition on plaintext token storage
- `audit_event_taxonomy.md` — canonical event definitions
- Block 02 Phase 08 — OAuth integration foundation (phase doc)
- Block 09 Phase 05 — Email finder (Gmail consumer)
- Block 09 Phase 06 — Drive finder (Drive consumer)
