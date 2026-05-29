# OAuth Policy

**Block:** Authentication & Identity
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This policy defines all OAuth 2.0 and OpenID Connect (OIDC) flows supported by the platform, the providers configured through Supabase Auth, and the security requirements around token storage, PKCE, and account linking. All OAuth state parameters and session identifiers use `gen_random_uuid()` per the PK convention exceptions for ephemeral security tokens.

## Supported Flows

### Authorization Code with PKCE (Web Clients)

The primary flow for all browser-based authentication. PKCE (Proof Key for Code Exchange) is mandatory — no implicit flow is supported.

**Flow steps:**

1. Client generates a code verifier: a cryptographically random string of 43–128 characters using `crypto.randomBytes(96).toString('base64url')`.
2. Client computes `code_challenge = BASE64URL(SHA-256(code_verifier))` — S256 method only. Plain method is rejected.
3. Client generates an OAuth state parameter via `gen_random_uuid()` — single-use, 10-minute expiry, stored server-side (see `schemas/oauth_state_schema.md`).
4. Client redirects to the provider authorization endpoint with `response_type=code`, `code_challenge`, `code_challenge_method=S256`, and `state`.
5. Provider redirects back to the registered redirect URI with `code` and `state`.
6. Platform validates the returned `state` against the stored value — mismatch triggers AUTH_OAUTH_FAILED and aborts.
7. Platform exchanges `code` + `code_verifier` for tokens at the provider token endpoint.
8. Platform validates the ID token, extracts claims, and creates or matches a Supabase Auth user.

### Device Authorization Flow (CLI)

Used by the platform CLI tool when no browser is available.

1. CLI calls the device authorization endpoint to obtain a `device_code` and `user_code`.
2. CLI displays the `user_code` and the verification URI for the user to visit on any browser.
3. CLI polls the token endpoint using the `device_code` until the user completes authorization or the code expires (10-minute window, 5-second poll interval).
4. On success, the CLI receives a refresh token stored in the OS keychain (not in any file).

Implicit flow, Resource Owner Password Credentials, and Client Credentials are not supported for user-facing authentication.

## Supported Providers

All providers are configured through Supabase Auth. Configuration lives in the Supabase dashboard and environment-specific secrets in Vault.

| Provider  | Protocol  | Scopes Requested                        | Used For             |
|-----------|-----------|-----------------------------------------|----------------------|
| Google    | OIDC      | `openid email profile`                  | Web + CLI            |
| Microsoft | OIDC      | `openid email profile offline_access`   | Web + CLI            |
| GitHub    | OAuth 2.0 | `read:user user:email`                  | Web (developer tier) |

Provider-specific configuration (client ID, client secret) is stored in Supabase Auth provider settings, not in application code. Secrets are rotated annually or immediately on suspected compromise.

## OAuth State Parameter

- Generated with: `gen_random_uuid()`
- Purpose: CSRF protection — binds the authorization request to the callback
- Storage: `oauth_states` table (see `schemas/oauth_state_schema.md`), server-side only
- Expiry: 10 minutes from creation; expired states are rejected and cleaned up by a scheduled job
- Single-use: consumed and deleted on first use; replayed states trigger AUTH_OAUTH_FAILED (MEDIUM)
- State is never logged in full; only the first 8 characters are retained in audit events for correlation

## PKCE Code Verifier

- Method: S256 — SHA-256 hash of the code verifier, base64url-encoded
- Length: 43–128 characters (RFC 7636 requirement)
- Generation: `crypto.randomBytes(96).toString('base64url')` — produces a 128-character string
- The code verifier is held in memory on the client for the duration of the authorization flow only
- It is never sent to or stored by the platform server
- Plain method is explicitly blocked: if `code_challenge_method=plain` is received, the request is rejected with a 400 error

## Token Storage

Correct token storage is critical to preventing token theft.

| Token Type    | Storage Location         | Rationale                                                                    |
|---------------|--------------------------|------------------------------------------------------------------------------|
| Access token  | In-memory only (JS heap) | Short-lived (1 hour); never written to disk, localStorage, or sessionStorage |
| Refresh token | httpOnly cookie          | Inaccessible to JavaScript; immune to XSS token theft                        |
| ID token      | In-memory only           | Parsed and discarded after claim extraction                                  |

**Explicitly prohibited storage locations:**
- `localStorage` — accessible to JavaScript, XSS-vulnerable
- `sessionStorage` — accessible to JavaScript
- URL parameters — logged by proxies and browser history
- Non-httpOnly cookies — accessible to JavaScript

The refresh token cookie is set with the following attributes:
- `HttpOnly` — no JavaScript access
- `Secure` — HTTPS only
- `SameSite=Strict` — no cross-site requests
- `Path=/api/auth` — scoped to auth endpoints only
- `Max-Age` aligned to the refresh token lifetime (30 days for standard sessions; see `session_lifetime_policy.md`)

## Redirect URI Allowlist

Redirect URIs are registered per environment. The platform rejects any `redirect_uri` not on the allowlist — Supabase Auth enforces this at the provider configuration level.

| Environment | Allowed Redirect URIs                                                        |
|-------------|------------------------------------------------------------------------------|
| Production  | `https://app.example.cy/auth/callback`                                       |
| Staging     | `https://staging.example.cy/auth/callback`                                   |
| Local dev   | `http://localhost:3000/auth/callback`                                        |
| CLI         | `http://localhost:PORT/auth/callback` (ephemeral port range 49152–65535)     |

Wildcard redirect URIs are never permitted in production or staging. Any change to the production allowlist requires a reviewed deployment.

## OAuth Account Linking

A user may link an OAuth provider account (e.g., Google) to an existing email/password account.

**Requirements:**
1. The user must be authenticated with their existing session.
2. Linking requires step-up MFA verification (see `step_up_auth_for_workflow_approval_policy.md`).
3. The OAuth provider email must match the existing account's primary email — cross-email linking is blocked.
4. A user account may have at most one linked identity per provider.
5. Linking a second Google account to an account that already has a Google identity linked is blocked.

**Account linking flow:**
1. User navigates to Account Settings → Linked Accounts.
2. Platform triggers step-up MFA challenge.
3. On MFA success, platform initiates the OAuth flow for the target provider.
4. On OAuth callback, platform calls `supabase.auth.linkIdentity()` with the provider token.
5. Audit event AUTH_ACCOUNT_LINKED (LOW) is emitted with `actor_user_id`, `provider`, and `linked_provider_user_id`.

## Provider Account Deprovisioning

If a user's OAuth provider account is deleted or deactivated (e.g., a Google Workspace account is removed by an admin), the user will lose the ability to authenticate via that provider.

**Platform behaviour:**
- On the next OAuth callback for that provider, the token exchange will fail with an error from the provider.
- Platform emits AUTH_OAUTH_FAILED (MEDIUM) and presents an error page.
- The platform's email delivery system sends a notification to the account's primary email address instructing the user to set up an alternative login method (email/password or another linked OAuth provider).
- The account is not deleted — data is preserved.
- If the account has no other login method and no MFA recovery codes, the user must contact support for identity verification and account recovery.

## Audit Events

| Event                  | Severity | Trigger                                                          |
|------------------------|----------|------------------------------------------------------------------|
| AUTH_OAUTH_INITIATED   | LOW      | OAuth flow begins; state parameter created                       |
| AUTH_OAUTH_COMPLETED   | LOW      | Token exchange succeeds; user session created                    |
| AUTH_OAUTH_FAILED      | MEDIUM   | State mismatch, token exchange failure, or provider error        |
| AUTH_ACCOUNT_LINKED    | LOW      | OAuth identity successfully linked to existing account           |

All events are written via `tool_emit_audit` with the standard payload schema (`audit_log_schema.md`). AUTH_OAUTH_FAILED includes `failure_reason` in the metadata field.

## Supabase Auth Provider Configuration

Providers are configured in the Supabase dashboard under Authentication → Providers. The following settings apply:

- **Google:** Client ID and Client Secret from Google Cloud Console OAuth 2.0 credentials. Authorized redirect URIs must include all entries from the allowlist above.
- **Microsoft:** Client ID and Client Secret from Azure AD app registration. Supported account types: `Accounts in any organizational directory and personal Microsoft accounts`.
- **GitHub:** Client ID and Client Secret from GitHub OAuth App settings. Homepage URL and callback URL must match registered values.

Client secrets are stored in Vault, not hardcoded. Supabase reads them from the environment at startup.

Custom claims are injected into JWTs via a Supabase Auth hook that fires after each OAuth sign-in. The hook reads the user's `org_members` row to populate `business_id` and `role` claims. See `reference/supabase_auth_integration_guide.md` for hook implementation details.

## Security Considerations

- OAuth state reuse attempts are treated as potential CSRF attacks and logged at MEDIUM severity.
- Code verifiers must not be logged at any verbosity level.
- Access tokens must not appear in application logs. Log scrubbing rules in the logging pipeline reject patterns matching JWT format.
- Provider tokens (Google/Microsoft access tokens) are discarded after claim extraction and account creation; the platform does not store or use provider access tokens for API calls.
- OAuth errors from providers (e.g., `access_denied`, `temporarily_unavailable`) are mapped to internal error codes defined in `error_code_catalog.md` before being returned to the client.

## Related Documents

- `schemas/oauth_state_schema.md`
- `schemas/oauth_token_encryption_schema.md`
- `schemas/session_schema.md`
- `policies/mfa_policy.md`
- `policies/session_management_policy.md`
- `policies/step_up_auth_for_workflow_approval_policy.md`
- `reference/supabase_auth_integration_guide.md`
- `reference/error_code_catalog.md`
