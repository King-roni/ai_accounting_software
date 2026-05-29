# Integration: Supabase Vault

**Block:** Security  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The system uses Supabase Vault as the primary secrets management layer for all sensitive credentials and key material that edge functions and server-side processes require at runtime. Vault provides AES-256 encryption at rest managed by Supabase's internal KMS, with access controlled by the Postgres `vault` schema. No plaintext secret value ever appears in a migration file, a Supabase configuration file, or an RLS policy expression.

## Stored Secret Categories

The following categories of secrets are stored in Vault:

| Secret Name Pattern | Category | Description |
|---|---|---|
| `stripe_secret_key_{env}` | Payment | Stripe secret API key for the live or test environment |
| `stripe_webhook_secret_{env}` | Payment | Stripe webhook signing secret for event verification |
| `ecb_api_key` | Data | API key for ECB exchange rate endpoint (if auth is added by ECB in future) |
| `pdf_signing_cert_pem` | Document | PEM-encoded certificate used to digitally sign generated PDFs |
| `pdf_signing_key_pem` | Document | PEM-encoded private key for PDF signing |
| `smtp_host` | Email | SMTP server hostname |
| `smtp_username` | Email | SMTP authentication username |
| `smtp_password` | Email | SMTP authentication password |
| `kms_arn` | Infrastructure | AWS KMS key ARN used for envelope encryption of counterparty data at rest |
| `rfc3161_tsq_endpoint` | Document | URL of the RFC 3161 timestamp authority |
| `rfc3161_tsq_credentials` | Document | Credentials for the timestamp authority |

## Vault Access API

Vault secrets are accessed using the Supabase `vault` schema functions within edge functions and Postgres functions. The two primary operations are:

**Create or update a secret:**

```sql
SELECT vault.create_secret(
  secret   => 'sk_live_xxxx',
  name     => 'stripe_secret_key_live',
  description => 'Stripe live secret key'
);
```

**Read a decrypted secret by name:**

```sql
SELECT decrypted_secret
FROM vault.decrypted_secrets
WHERE name = 'stripe_secret_key_live';
```

In edge functions, secrets are accessed via the Supabase client with service-role privileges:

```typescript
const { data, error } = await supabaseAdmin
  .from('vault.decrypted_secrets')
  .select('decrypted_secret')
  .eq('name', 'stripe_secret_key_live')
  .single();
```

## Cold Start Loading Pattern

Edge functions load secrets once at cold start, not on every request. This reduces Vault query overhead and prevents per-request latency from secret decryption. The pattern is:

```typescript
// Module-level (runs once per cold start)
let stripeSecretKey: string | null = null;

async function getStripeSecretKey(): Promise<string> {
  if (!stripeSecretKey) {
    const { data } = await supabaseAdmin
      .from('vault.decrypted_secrets')
      .select('decrypted_secret')
      .eq('name', 'stripe_secret_key_live')
      .single();
    stripeSecretKey = data?.decrypted_secret ?? null;
  }
  if (!stripeSecretKey) {
    throw new Error('stripe_secret_key_live not found in Vault');
  }
  return stripeSecretKey;
}
```

The cached value is held in the function's module scope for the lifetime of the warm container. If the container is evicted (Supabase edge function cold start), the next invocation re-fetches from Vault.

## RLS Policy Restriction

Vault values must never appear in RLS policy expressions. RLS policies run per-row and are evaluated in the context of the authenticated user. Embedding a Vault read inside an RLS expression would:

1. Expose the decrypted value to Postgres query planning logs.
2. Create a per-row Vault query, causing severe performance degradation.
3. Violate the principle that secrets are only accessible to service-role operations.

If an RLS policy appears to require a secret value (e.g., a shared signing key), the architecture must be revised so the check occurs at the application layer, not in SQL.

## Rotation Procedure

Secret rotation follows this sequence:

1. In the Supabase Dashboard, navigate to Vault and update the secret entry with the new value.
2. Redeploy all edge functions that consume the rotated secret. The redeployment forces a cold start and clears the cached value.
3. Verify the new secret is operational by running the appropriate smoke test (e.g., a Stripe API ping for payment secrets).
4. Revoke the old secret at the provider (Stripe, SMTP provider, etc.).
5. Emit a `SECURITY_SECRET_ACCESSED` audit event (see Audit Events below) with the rotation metadata in the notes field.

Do not update the secret and expect running containers to pick up the new value automatically — they will not until they cold-start. Time-sensitive rotations (e.g., after a suspected compromise) must include a forced redeployment.

## Audit Events

| Event | Severity | When emitted |
|---|---|---|
| `SECURITY_SECRET_ACCESSED` | LOW | Emitted by `security.emit_audit` when a Vault secret is read by a scheduled or on-demand process. Not emitted for per-request reads in hot paths. |

The audit payload includes: `secret_name` (name only, never the value), `accessor_function`, `access_reason` (e.g. `cold_start`, `rotation_verification`).

The audit emission is performed via `security.emit_audit` which writes to the `audit_log` table. This call is made from the edge function or Postgres function that reads the secret; it is not automatic.

## Local Development

In local development, secrets are provided via `.env.local` at the project root. The edge function loader reads from environment variables when `SUPABASE_URL` points to `localhost`:

```bash
# .env.local — never commit this file
STRIPE_SECRET_KEY_LIVE=sk_test_xxxx
PDF_SIGNING_CERT_PEM="-----BEGIN CERTIFICATE-----\n..."
SMTP_PASSWORD=dev_password
```

`.env.local` is listed in `.gitignore`. If it is accidentally committed, rotate all contained secrets immediately using the rotation procedure above.

The local development pattern does not use `vault.decrypted_secrets`. Edge functions must implement a `getSecret(name)` helper that checks the environment variable first (local) and falls back to Vault (production). This keeps local development functional without requiring a Supabase project.

## Supabase Dashboard Management

Secrets can be viewed and managed in the Supabase Dashboard under **Project Settings > Vault**. The dashboard shows secret names and descriptions but never displays decrypted values. To inspect a secret's current value for debugging, use the `vault.decrypted_secrets` view from the Supabase SQL editor with service-role credentials — never from a client-side context.

## Migration Considerations

Vault secrets are not managed by Supabase migration files (`supabase/migrations/`). Migration files are committed to version control; secrets must not appear in version control under any circumstances. The `vault.create_secret()` calls used during initial environment setup are executed as one-time SQL scripts run manually from the Supabase Dashboard SQL editor or via a secure CI/CD step that reads from a secrets manager (e.g., GitHub Actions secrets).

If a migration requires a secret to exist (e.g., creating a trigger that references a Vault secret), the migration should fail gracefully with an error if the secret is absent rather than proceeding with a null value.

## Integration with Other Policies

- `secrets_management_policy.md` — the governing policy for secret handling, rotation schedules, and access control
- `no_plaintext_fallback_policy.md` — prohibits plaintext fallback when Vault is unavailable
- `encryption_at_rest_policy.md` — envelope encryption using the `kms_arn` secret from Vault

## Related Documents

- `secrets_management_policy.md` — secret lifecycle and rotation policy
- `no_plaintext_fallback_policy.md` — plaintext fallback prohibition
- `encryption_at_rest_policy.md` — at-rest encryption using KMS ARN from Vault
- `totp_secret_storage_integration.md` — TOTP secrets stored separately in Vault
- `stripe_payment_integration.md` — consumes Stripe secrets from Vault
- `transactional_email_service_integration.md` — consumes SMTP secrets from Vault
- `rfc_3161_timestamp_integration.md` — consumes timestamp authority credentials from Vault
