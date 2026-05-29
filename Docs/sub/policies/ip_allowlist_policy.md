# IP Allowlist Policy

**Block:** Authentication & Identity
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The IP allowlist is an optional security feature available to Enterprise tier businesses. When enabled, all API requests originating from IP addresses not on the allowlist are rejected at the Edge Function middleware layer before any application logic or RLS evaluation occurs. This policy defines how the allowlist is configured, enforced, bypassed, and audited.

## Availability

IP allowlisting is an Enterprise tier feature only. It is not available on Starter or Professional plans. Attempting to enable it on a lower-tier business account returns error `IP_ALLOWLIST_NOT_AVAILABLE` (403) and emits no audit event.

## Data Model

The allowlist is stored on the `business_settings` table:

```sql
-- Column on business_settings (existing table)
ip_allowlist TEXT[]  -- CIDR notation entries, e.g. {'203.0.113.0/24', '198.51.100.45/32'}
```

- An empty array (`{}`) or NULL means the feature is disabled (all IPs are allowed).
- A non-empty array means the feature is active; only matching IPs are permitted.
- IPv4 and IPv6 CIDR ranges are both supported.
- Maximum 100 entries per business to prevent configuration sprawl.
- Individual host addresses must be expressed as `/32` (IPv4) or `/128` (IPv6).

## Enforcement Architecture

IP allowlist enforcement runs in the Supabase Edge Function middleware, applied before any route handler or RLS policy is evaluated.

**Enforcement sequence:**

1. Incoming request arrives at the Edge Function.
2. Middleware reads the `X-Forwarded-For` header (set by Vercel's edge network). The platform trusts only the first IP in the chain (the client IP as seen by the edge).
3. Middleware calls `business.get_ip_allowlist(business_id)` — a lightweight cached read from `business_settings`.
4. If the allowlist is empty or NULL, enforcement is skipped (pass-through).
5. If the allowlist is non-empty, each CIDR range is evaluated against the client IP.
6. If no range matches, the request is rejected with HTTP 403 and body:
   ```json
   { "error": "IP_ACCESS_DENIED", "code": 403 }
   ```
7. Audit event IP_ACCESS_DENIED (MEDIUM) is emitted with `actor_ip`, `business_id`, and `endpoint`.

**Caching:** The allowlist is cached in Edge Function memory with a 60-second TTL to reduce database reads. After an allowlist update, enforcement reflects the change within 60 seconds. This window is acceptable; it is not a security bypass.

## Admin UI — Managing the Allowlist

Business owners and admin role members can manage the allowlist at Settings → Security → IP Allowlist.

**Actions available:**

| Action        | Description                                                  | Required Role |
|---------------|--------------------------------------------------------------|---------------|
| Add entry     | Add a CIDR range or single IP                                | owner, admin  |
| Remove entry  | Remove an existing entry                                     | owner, admin  |
| View entries  | List all current entries                                     | owner, admin  |
| Enable/disable | Toggle the feature on or off (clearing the list disables) | owner only    |

**Validation on entry add:**
- Input must be valid CIDR notation. Invalid input is rejected client-side and server-side.
- Adding an entry that would lock out the current admin's IP shows a warning: "This change may lock you out. Confirm to proceed."
- The platform does not prevent self-lockout — it only warns.

## Bypass: Step-Up MFA

When a user is blocked by the IP allowlist, they may request a temporary bypass valid for 4 hours by completing a step-up MFA challenge.

**Bypass flow:**
1. User receives a 403 response from a blocked IP.
2. User authenticates through the standard login flow from a non-blocked IP (e.g., on a VPN, or a device on a listed IP).
3. From a listed IP, the user navigates to Settings → Security → IP Bypass and completes step-up MFA.
4. Platform generates a bypass grant tied to (`user_id`, `ip_address`, `business_id`), valid for 4 hours.
5. Subsequent requests from the non-listed IP within the 4-hour window are permitted.
6. Audit event IP_ALLOWLIST_BYPASS_GRANTED (MEDIUM) is emitted with `actor_user_id`, `bypassed_ip`, and `expires_at`.

**Bypass grants are not renewable.** After 4 hours, the user must repeat the step-up MFA flow. Bypass grants are stored in a short-lived `ip_bypass_grants` table (not part of the main schema — managed by the auth Edge Function).

## Interaction with Mobile Clients

Mobile clients (iOS and Android) operate on dynamic IP addresses assigned by carriers and Wi-Fi networks. These IPs change frequently and cannot be reliably pre-registered in an allowlist.

**Recommendation:** Do not enable IP allowlisting for any business where users access the platform via mobile apps.

If IP allowlisting is enabled and mobile clients are in use:
- Mobile clients will be blocked whenever their IP falls outside the allowlist.
- The bypass flow requires completing step-up MFA from a listed IP, which is impractical on mobile.
- Support tickets for IP-blocked mobile users are not treated as platform defects — the configuration decision is the business's responsibility.

See `reference/mobile_write_rejection_endpoints.md` for documentation of mobile-specific API behaviour.

## Interaction with CI/CD Pipelines

If the platform API is called from a CI/CD pipeline (e.g., to upload bank statements or trigger report generation), the pipeline's fixed egress IP must be added to the allowlist.

**Steps:**
1. Determine the fixed egress IP of the CI/CD runner (GitHub Actions, GitLab CI, etc.). Most enterprise CI providers expose fixed egress IPs.
2. Add the IP as a `/32` entry in the allowlist.
3. Document the entry with the `name` label (e.g., `github-actions-runner-prod`).

If the CI/CD provider rotates IPs, use a CIDR range covering the known range — or disable IP allowlisting for that business.

Using API keys for CI/CD authentication does not exempt requests from IP allowlist enforcement. Both session tokens and API keys are subject to IP checking.

## Audit Events

| Event                       | Severity | Trigger                                                          |
|-----------------------------|----------|------------------------------------------------------------------|
| IP_ACCESS_DENIED            | MEDIUM   | Request blocked because client IP is not on the allowlist        |
| IP_ALLOWLIST_UPDATED        | LOW      | Entry added, removed, or feature toggled                         |
| IP_ALLOWLIST_BYPASS_GRANTED | MEDIUM   | Step-up MFA bypass issued for a non-listed IP                    |

IP_ALLOWLIST_UPDATED includes `changed_by`, `change_type` (ADD / REMOVE / ENABLE / DISABLE), and `entry_affected` in the metadata field.

## Edge Cases

**VPN and proxy traffic:** If users access the platform through a corporate VPN, add the VPN's egress IP(s) to the allowlist, not individual user IPs.

**IPv6 dual-stack:** If the platform is accessed over IPv6, ensure IPv6 ranges are added. The middleware handles IPv4 and IPv6 independently — an IPv4 allowlist does not cover IPv6 traffic from the same host.

**Localhost bypass:** `127.0.0.1` and `::1` are never blocked by the allowlist, as requests from localhost indicate server-to-server calls that do not traverse the Edge Function middleware.

**Feature flag interaction:** The IP allowlist feature flag is checked in `business_settings.feature_flags`. If the Enterprise tier is downgraded, the allowlist configuration is preserved but enforcement is suspended. Re-upgrading to Enterprise re-enables enforcement using the previously saved configuration.

## Testing the Allowlist

Before enabling the IP allowlist in production, test the configuration:

1. Add the allowlist entries in a staging environment.
2. Verify that requests from an allowed IP return the expected responses.
3. Verify that requests from a non-listed IP receive HTTP 403 with body `{ "error": "IP_ACCESS_DENIED" }`.
4. Verify that the step-up MFA bypass grants temporary access from a non-listed IP.
5. Check that audit events IP_ACCESS_DENIED and IP_ALLOWLIST_BYPASS_GRANTED appear in the audit log.

Do not enable in production without completing this checklist. A misconfigured allowlist can lock out all users including admins.

## Disabling the Feature

To disable IP allowlisting without losing the configuration:

1. Navigate to Settings → Security → IP Allowlist.
2. Toggle "Enable IP Allowlist" to off.
3. The allowlist entries are preserved in `business_settings.ip_allowlist` but enforcement stops.
4. Audit event IP_ALLOWLIST_UPDATED (LOW) is emitted with `change_type = 'DISABLE'`.

To completely clear the allowlist, remove all entries after disabling. Clearing the array is equivalent to disabling the feature — an empty `ip_allowlist` array results in no enforcement regardless of the feature toggle state.

## Related Documents

- `schemas/business_settings_schema.md`
- `policies/rate_limiting_policy.md`
- `policies/session_management_policy.md`
- `policies/step_up_auth_for_workflow_approval_policy.md`
- `reference/supabase_auth_integration_guide.md`
- `reference/mobile_write_rejection_endpoints.md`
- `tools/tool_step_up_request.md`
