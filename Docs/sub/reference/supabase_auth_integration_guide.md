# Supabase Auth Integration Guide

**Block:** Authentication & Identity
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This reference describes how the platform integrates with Supabase Auth for user authentication, session management, JWT customization, and RLS enforcement. It covers setup, custom claims, triggers, hooks, and local development workflow. Supabase Auth is the sole authentication system — no custom auth server is maintained.

## Project Configuration

Supabase Auth is configured per environment (production, staging, local). The following environment variables are required:

| Variable                    | Description                                   | Storage        |
|-----------------------------|-----------------------------------------------|----------------|
| `SUPABASE_URL`              | Project URL, e.g. `https://xyz.supabase.co`   | Vault          |
| `SUPABASE_ANON_KEY`         | Public anon key for client-side SDK           | Vault          |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key — bypasses RLS               | Vault          |

All three values are read from Vault at Edge Function startup. They must never appear in source code, `.env.example`, or CI logs. The anon key is safe to expose to the browser — it is restricted by RLS. The service role key must never be exposed client-side.

```typescript
// Correct: server-side only (Edge Function)
const supabase = createClient(
    process.env.SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!
);

// Correct: client-side (browser)
const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
);
```

## JWT Configuration

Supabase issues JWTs with a default payload. The platform extends this payload with custom claims added by an Auth Hook (see below).

**Standard claims:**
- `sub` — Supabase user UUID
- `email` — user email
- `role` — Supabase role (`anon` or `authenticated`)
- `exp` — expiry (default: 1 hour for access tokens)
- `iat` — issued at

**Custom claims added by platform hook:**

| Claim        | Type   | Description                                      |
|--------------|--------|--------------------------------------------------|
| `business_id`| string | UUID of the user's active business               |
| `app_role`   | string | Platform role: `owner`, `admin`, `member`, `accountant` |
| `mfa_level`  | string | `none`, `totp`, `step_up`                        |

RLS policies access these claims via `auth.jwt() ->> 'business_id'` and `auth.jwt() ->> 'app_role'`. Using `app_role` rather than Supabase's built-in `role` avoids conflicts with Supabase's internal role system.

**Token lifetimes:**
- Access token: 3600 seconds (1 hour)
- Refresh token: 2592000 seconds (30 days) for standard sessions; 86400 seconds (24 hours) for step-up sessions

## Custom Claims Sync — Auth Hook

Supabase Auth hooks allow custom logic to run after authentication events. The platform uses a `custom_access_token` hook to inject `business_id`, `app_role`, and `mfa_level` into every issued JWT.

```typescript
// supabase/functions/_auth_hooks/custom_access_token.ts
export async function customAccessTokenHook(payload: {
    user_id: string;
    claims: Record<string, unknown>;
}): Promise<{ claims: Record<string, unknown> }> {
    const { data: member } = await supabaseAdmin
        .from('org_members')
        .select('business_id, role')
        .eq('user_id', payload.user_id)
        .eq('is_active', true)
        .single();

    const mfaLevel = await getMfaLevel(payload.user_id);

    return {
        claims: {
            ...payload.claims,
            business_id: member?.business_id ?? null,
            app_role:    member?.role ?? null,
            mfa_level:   mfaLevel
        }
    };
}
```

The hook is registered in Supabase Dashboard under Authentication → Hooks → Custom Access Token. It runs synchronously on every token issue and refresh — it must complete within 2 seconds to avoid auth latency.

If `org_members` returns no row (user is not yet a member of any business), `business_id` and `app_role` are `null`. These users can authenticate but cannot access any business-scoped resources (all RLS policies require a non-null `business_id`).

## User Signup Flow

### Email + Password

1. Client calls `supabase.auth.signUp({ email, password })`.
2. Supabase creates an `auth.users` entry with `confirmed_at = null`.
3. Supabase sends a confirmation email to the user's address.
4. User clicks the confirmation link.
5. Supabase sets `confirmed_at = now()`.
6. Database trigger `after_user_confirmation` fires (see below) to create the initial org structure.

### OAuth Signup

1. Client initiates OAuth flow per `policies/oauth_policy.md`.
2. On successful OAuth callback, Supabase creates or updates an `auth.users` entry.
3. OAuth accounts are considered confirmed immediately — no email confirmation step.
4. The same `after_user_confirmation` trigger fires.

### Unconfirmed Users

Unconfirmed users (email sign-up, `confirmed_at = null`) are blocked from all write API endpoints. The Edge Function middleware checks the `email_confirmed_at` field in the JWT payload. Unconfirmed users receive a 403 with `EMAIL_NOT_CONFIRMED` error code on any write attempt.

## Database Trigger: after_user_confirmation

```sql
CREATE OR REPLACE FUNCTION handle_user_confirmation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- Create a new business entity for the user
    INSERT INTO business_entities (id, name, created_by)
    VALUES (gen_uuid_v7(), NEW.raw_user_meta_data->>'company_name', NEW.id);

    -- Add the user as owner of the new business
    INSERT INTO org_members (id, user_id, business_id, role, is_active)
    VALUES (
        gen_uuid_v7(),
        NEW.id,
        (SELECT id FROM business_entities WHERE created_by = NEW.id ORDER BY created_at DESC LIMIT 1),
        'owner',
        true
    );

    -- Initialize business settings with defaults
    INSERT INTO business_settings (id, business_id)
    VALUES (
        gen_uuid_v7(),
        (SELECT id FROM business_entities WHERE created_by = NEW.id ORDER BY created_at DESC LIMIT 1)
    );

    -- Initialize notification preferences
    INSERT INTO notification_preferences (user_id, business_id)
    VALUES (
        NEW.id,
        (SELECT id FROM business_entities WHERE created_by = NEW.id ORDER BY created_at DESC LIMIT 1)
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER after_user_confirmation
    AFTER UPDATE OF confirmed_at ON auth.users
    FOR EACH ROW
    WHEN (OLD.confirmed_at IS NULL AND NEW.confirmed_at IS NOT NULL)
    EXECUTE FUNCTION handle_user_confirmation();
```

For OAuth users (who skip email confirmation), the trigger fires on `INSERT` with a non-null `confirmed_at`.

## RLS Integration

### User Isolation

All tables with user-owned rows use `auth.uid()` to scope access:

```sql
USING (user_id = auth.uid())
```

### Business Isolation

Tables scoped to a business use the `business_id` claim from the JWT:

```sql
USING (business_id = (auth.jwt() ->> 'business_id')::uuid)
```

### Role-Based Access

Admin-only operations layer an `app_role` check:

```sql
USING (
    business_id = (auth.jwt() ->> 'business_id')::uuid
    AND (auth.jwt() ->> 'app_role') IN ('owner', 'admin')
)
```

### MFA Level Enforcement

Step-up operations require `mfa_level = 'step_up'` in the JWT:

```sql
USING (
    (auth.jwt() ->> 'mfa_level') = 'step_up'
    AND business_id = (auth.jwt() ->> 'business_id')::uuid
)
```

Full RLS policy map is in `reference/supabase_rls_policy_map.md`.

## Service Role Usage

The service role key bypasses all RLS policies. It must only be used in:
- Supabase Edge Functions (server-side, never exposed to client)
- Auth hooks
- Database migration scripts (dev/CI only)

It must never be:
- Bundled in client-side code
- Committed to version control
- Logged or included in error responses

All service role database clients are created fresh per request — not shared across requests.

## Session Management

Supabase Auth handles token refresh automatically via the client SDK. The platform's server middleware validates the JWT on each request:

```typescript
// Edge Function middleware
const { data: { user }, error } = await supabase.auth.getUser(token);
if (error || !user) return new Response('Unauthorized', { status: 401 });
```

The platform does not implement its own session store. Session state (active/revoked) is managed entirely by Supabase Auth. Logout calls `supabase.auth.signOut()`, which revokes the refresh token server-side.

## Admin API Usage

Administrative operations (creating users, resetting passwords, managing sessions) use the Supabase Admin API:

```typescript
const { data, error } = await supabaseAdmin.auth.admin.createUser({
    email: 'user@example.com',
    email_confirm: true
});
```

Admin API calls require the service role key and are only made from Edge Functions.

## Custom Claims — Role Change Propagation

When a user's role in `org_members` changes, the custom claims in their active JWT are stale until the next token refresh (up to 1 hour). To force immediate propagation:

1. The role-change operation updates `org_members.role`.
2. The Edge Function that performs the update also calls `supabaseAdmin.auth.admin.signOut(userId, 'others')` to invalidate all sessions for that user except the current admin's session.
3. On the user's next API call, their token refresh will invoke the `custom_access_token` hook and pick up the new role.

## Local Development Setup

```bash
# Install Supabase CLI
npm install -g supabase

# Start local Supabase stack (PostgreSQL, Auth, Realtime, Edge Functions)
supabase start

# Seed auth users for development
supabase db seed

# Access local dashboard
open http://127.0.0.1:54323
```

Local auth uses a test secret for JWT signing. The anon key and service role key are printed to the console on `supabase start`. Never commit these values — they are deterministic for the local stack and have no security value.

**Seeding auth users:**

```sql
-- In supabase/seed.sql
SELECT supabase_auth.create_user(
    '00000000-0000-0000-0000-000000000001'::uuid,
    'owner@test.cy',
    'TestPassword123!',
    'confirmed',
    '{"company_name": "Test Bookkeeping Ltd"}'::jsonb
);
```

## Supabase Auth Hooks Reference

| Hook                    | Trigger                  | Platform Use                                      |
|-------------------------|--------------------------|---------------------------------------------------|
| `custom_access_token`   | Every token issue/refresh | Inject `business_id`, `app_role`, `mfa_level`    |
| `send_email`            | Email send events        | Route through custom email delivery integration   |
| `mfa_verification_attempt` | MFA code checked      | Rate limiting and audit event emission            |

## Related Documents

- `policies/oauth_policy.md`
- `policies/mfa_policy.md`
- `policies/session_management_policy.md`
- `policies/row_level_security_policies.md`
- `reference/supabase_rls_policy_map.md`
- `reference/permission_matrix.md`
- `schemas/org_member_schema.md`
- `schemas/session_schema.md`
- `schemas/mfa_device_schema.md`
