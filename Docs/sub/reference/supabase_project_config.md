# Supabase Project Configuration Reference

**Category:** Reference · **Owning block:** 02 — Tenancy & Access · **Co-owners:** 05 · **Stage:** 4 sub-doc (Layer 1)

This document is the authoritative reference for the Supabase project configuration for the
platform. It covers auth settings, database parameters, storage buckets, Edge Function deployment,
and environment variable names. It does not contain secret values — only names and settings.

---

## 1. Auth settings

| Setting | Value | Notes |
|---|---|---|
| JWT expiry | 3600 seconds (1 hour) | Access tokens expire after 1 hour. Clients must use the refresh token flow to obtain a new access token. |
| Refresh token rotation | Enabled | Each refresh token use issues a new refresh token and invalidates the previous one. |
| Refresh token reuse interval | 10 seconds | Allows a small window for network retry without treating it as token theft. |
| Auth flow | PKCE required | Implicit flow is disabled. All clients must use PKCE. This applies to web and mobile clients. |
| Email confirmation | Required | New accounts cannot sign in until the email address is confirmed. |
| Magic link enabled | Yes | Used as an alternative to password for first-time sign-in from invitation links. |
| OTP expiry | 600 seconds (10 minutes) | Applies to magic link and email OTP flows. |
| Password minimum length | 12 characters | Per `password_policy`. |
| MFA enforcement | Per-business configurable | Platform-level MFA is optional; per `mfa_policy`, businesses can enforce TOTP for their members. |
| Step-up MFA | Enabled | Used for `FINALIZATION` and optionally for `BUSINESS_SETTINGS_EDIT`, `USER_INVITE`, `EXTERNAL_INTEGRATION` surfaces. |
| Session lifetime (inactive) | 7 days | Inactive sessions are invalidated after 7 days per `session_lifetime_policy`. |

---

## 2. Database settings

| Setting | Value | Notes |
|---|---|---|
| Postgres version | 15 | Minimum required for `gen_uuid_v7()` extension support via `pgcrypto` + custom function. |
| Connection pooling | PgBouncer (transaction mode) | Transaction-mode pooling is required because session-level `set_config` calls are used for RLS context. Each transaction sets its own context. |
| Max connections (pool) | 60 (configurable per Supabase plan) | Direct connections reserved for migrations and admin operations. |
| Statement timeout | 30 seconds | Queries exceeding 30 seconds are terminated. Long-running analytical queries must use Edge Functions with streaming. |
| Idle in transaction timeout | 10 seconds | Transactions left idle for 10 seconds are rolled back and connections returned to the pool. |
| `search_path` | `public, extensions` | `extensions` schema is included for access to `pgcrypto` and `uuid-ossp`. |
| `log_min_duration_statement` | 5000 ms | Queries over 5 seconds are logged to the Supabase log drain for performance review. |

---

## 3. Storage buckets

Three storage buckets are configured. All buckets have RLS enabled at the application layer;
bucket-level policies enforce that only service role can write directly.

### 3a. processing-zone

| Property | Value |
|---|---|
| Purpose | Temporary storage for uploaded bank statements and documents awaiting intake |
| Access | Private (no public URL) |
| TTL | 7 days from upload; objects are deleted by the `storage.cleanup_processing_zone` Edge Function |
| Max file size | 50 MB per object (per `intake_size_limits_policy`) |
| Allowed MIME types | application/pdf, text/csv, application/vnd.ms-excel, application/vnd.openxmlformats-officedocument.spreadsheetml.sheet |
| Backup | Not backed up (see `backup_and_recovery_policy` Section 7) |

### 3b. archive-zone

| Property | Value |
|---|---|
| Purpose | Permanent storage for finalized archive bundles |
| Access | Private (no public URL); step-up auth required for download per `archive_step_up_policy` |
| TTL | None — objects are permanent |
| Versioning | Immutable; objects cannot be overwritten once written |
| Backup | Objects are permanent by design; not separately backed up |

### 3c. export-temp

| Property | Value |
|---|---|
| Purpose | Short-lived export files (report downloads, accountant packs) |
| Access | Private; pre-signed URL issued per download request |
| TTL | 24 hours from object creation; deleted by `storage.cleanup_export_temp` Edge Function |
| Max file size | 200 MB per object |
| Backup | Not backed up |

---

## 4. Edge Function deployment notes

Edge Functions are deployed via the Supabase CLI:

```bash
supabase functions deploy <function-name> --project-ref <PROJECT_REF>
```

Key deployment constraints:

- Every Edge Function that performs database writes must call `auth.set_rls_context()` at the
  start of the handler if it operates on behalf of a user session.
- Functions that use the service role (system jobs) must not expose the service role key to
  any response payload.
- Cold start timeout: 2 seconds. Functions with initialisation overhead must warm via scheduled
  pings if cold-start latency is unacceptable.
- Maximum execution time: 150 seconds. Long-running jobs must checkpoint progress and support
  resumability per `resumability_policy`.
- Deno runtime: `supabase-edge-runtime` (Deno 1.x). Node.js modules are not available natively;
  use the CDN import pattern from `deno.land/x` or npm specifiers.

---

## 5. Environment variable names

The following environment variable names are used across the platform. Values are never stored
in this document or in any committed file. Values are stored in the secrets manager per
`secrets_management_policy`.

| Variable name | Used by | Purpose |
|---|---|---|
| `SUPABASE_URL` | All services, Edge Functions | Project API URL |
| `SUPABASE_ANON_KEY` | Client SDK (browser/mobile) | Public anon key for unauthenticated requests |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-side system jobs only | Bypasses RLS; never exposed to client |
| `VAULT_KMS_KEY_ID` | Encryption-at-rest jobs | KMS key identifier for envelope encryption |
| `SMTP_HOST` | Email delivery Edge Function | Transactional email provider host |
| `SMTP_PORT` | Email delivery Edge Function | Transactional email provider port |
| `SMTP_USER` | Email delivery Edge Function | SMTP authentication username |
| `SMTP_PASSWORD` | Email delivery Edge Function | SMTP authentication password (secret) |
| `ENCRYPTION_KEY_ID` | `counterparty_encryption`, field-level encryption | Active encryption key reference |
| `SENTRY_DSN` | Error monitoring (server-side) | Error reporting endpoint |
| `VIES_API_BASE_URL` | VIES validation Edge Function | EU VIES service base URL |
| `ECB_RATES_API_URL` | ECB rate fetch Edge Function | European Central Bank FX rates endpoint |
| `ARCHIVE_SIGNING_KEY` | Archive bundle finalizer | Private key for RFC 3161 timestamp signing |
| `WEBHOOK_SECRET` | Inbound webhook handler | HMAC verification secret for webhook payloads |

---

## 6. RLS and service role safety

The `SUPABASE_ANON_KEY` enforces RLS for all requests. The `SUPABASE_SERVICE_ROLE_KEY`
bypasses RLS entirely. This is the only RLS bypass mechanism in the system.

Rules for service role usage:

1. `SUPABASE_SERVICE_ROLE_KEY` is only used in server-side Edge Functions and scheduled jobs.
   It is never included in client bundles, API responses, or log output.
2. Every Edge Function that uses the service role client must document why RLS bypass is required
   in the function's header comment.
3. Service role operations must emit an audit event where the operation touches tenant data.
   See `multi_tenancy_isolation_policy` Section 7 for the permitted use cases and required events.
4. Rotation of `SUPABASE_SERVICE_ROLE_KEY` requires coordinated redeployment of all Edge Functions
   that reference it. Rotation procedure is in `integration_credential_rotation_policy`.

---

## Related Documents

- `multi_tenancy_isolation_policy` — service role bypass conditions and audit requirements
- `secrets_management_policy` — storage and rotation of all secret values
- `backup_and_recovery_policy` — database backup strategy and bucket backup coverage
- `storage_bucket_configuration` — detailed bucket policy definitions
- `archive_step_up_policy` — step-up auth requirement for archive-zone downloads
- `intake_size_limits_policy` — processing-zone file size and MIME type limits
- `integration_credential_rotation_policy` — service role key rotation procedure
- `session_lifetime_policy` — session TTL and inactive session invalidation
- `mfa_policy` — MFA enforcement settings and per-business toggle
- `rls_helper_functions` — `rls_get_business_id()` and session context setup
