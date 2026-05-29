# session_device_fingerprint_capture_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The data contract for the user-facing sessions list surfaced in `settings_page_ui_spec.md` §Security → Active sessions. Defines: what the list reads from the `user_sessions` table, how the device-fingerprint string is captured and stored, what display transformations apply, and the refresh semantics for the "Last active" column.

Companion to `session_schema.md` (table DDL), `session_lifetime_policy.md` (idle / absolute timeouts), `tool_session_refresh.md` (the refresh tool that updates `last_active_at`), and `audit_event_taxonomy.md` (`AUTH_SESSION_*` events).

---

## 1. The session list read

The sessions list is a read-only surface populated by a single SECURITY DEFINER function:

```sql
CREATE OR REPLACE FUNCTION auth.list_my_sessions()
RETURNS TABLE (
  session_id          uuid,
  device_fingerprint  text,            -- raw captured fingerprint; display layer masks
  ip_address_masked   text,            -- pre-masked first-2-octets form; never raw
  ip_country_code     text,            -- ISO 3166-1 alpha-2, derived once at creation
  created_at          timestamptz,
  last_active_at      timestamptz,
  is_current          boolean,         -- TRUE for the session that issued the request
  client_form_factor  text             -- 'WEB' | 'MOBILE' | 'API'
)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT
    s.id                                                     AS session_id,
    s.device_fingerprint                                     AS device_fingerprint,
    auth.mask_ip(s.ip_address)                               AS ip_address_masked,
    s.ip_country_code                                        AS ip_country_code,
    s.created_at                                             AS created_at,
    s.last_active_at                                         AS last_active_at,
    (s.id = current_setting('app.principal_context_json',true)::jsonb->>'session_id'::uuid)
                                                             AS is_current,
    s.client_form_factor                                     AS client_form_factor
  FROM user_sessions s
  WHERE s.user_id = auth.current_user_id()
    AND s.is_revoked = false
    AND s.expires_at > now()
  ORDER BY s.last_active_at DESC;
$$;
```

Three guardrails enforced at function level:

1. **Scope** — `s.user_id = auth.current_user_id()`. A user only ever sees their own sessions, never another user's. There is no admin override surface in MVP.
2. **Active only** — revoked + expired sessions are excluded. The list shows live sessions only; history lives in the audit log (`AUTH_SESSION_REVOKED`, `AUTH_SESSION_EXPIRED`).
3. **Pre-masked IP** — the function returns `ip_address_masked`, never raw `s.ip_address`. The masking happens in the DB layer so a misconfigured client can't accidentally render raw IPs.

The function is gated by `EXTERNAL_INTEGRATION = ALLOW` for the user's own scope — there's no separate "sessions read" surface; reading your own sessions is part of the base authenticated surface.

---

## 2. Device fingerprint — what it is

A `device_fingerprint` is a stable, low-entropy descriptor of the client a session was created from. It is **NOT** a precise device identifier (no canvas fingerprinting, no WebGL probing, no font enumeration — those would be GDPR-significant tracking signals we deliberately don't collect).

What it IS: a server-side concatenation of two declared headers at session creation:

```
device_fingerprint = "<browser_family>/<browser_major_version> on <os_family>"
```

Examples:
- `"Chrome/138 on macOS"`
- `"Safari/17 on iOS"`
- `"Firefox/122 on Windows"`
- `"Mobile-App/iOS"` (when `client_form_factor = MOBILE`)
- `"API client"` (when `client_form_factor = API` and no UA is present)

Source: the `User-Agent` HTTP header parsed by the `ua-parser-js` library at session creation. Failure to parse falls back to `"Unknown browser on Unknown OS"`. The string is truncated to 60 chars and stored verbatim.

This is intentionally human-readable: the user sees it on the Sessions list and recognises their devices ("Chrome on macOS — that's my laptop") without privacy implications beyond what the User-Agent already broadcasts to every HTTP server.

---

## 3. Capture moments

Two distinct events capture / refresh fingerprint data:

### 3.1 Session creation (initial capture)

Triggered by successful login (password + MFA pass). The `auth.login` SECURITY DEFINER function:

1. Parses the `User-Agent` header → `device_fingerprint`.
2. Captures the source IP via `request.headers.x-forwarded-for` (first non-private IP from the chain) → stored as raw `ip_address` (network IP type).
3. Resolves `ip_address` → `ip_country_code` via the IP-geolocation service (`maxmind_geoip_integration.md`). Best-effort; if the lookup fails, `ip_country_code = NULL`.
4. Inserts `user_sessions` with these fields + the standard session timing columns.
5. Emits `AUTH_SESSION_CREATED` (LOW) audit event with payload `{session_id, device_fingerprint, ip_country_code, client_form_factor}`. **Raw IP is NOT in the audit payload** — only the country code, per `audit_log_policies.md` PII-minimisation rule.

The IP geolocation happens ONCE at session creation. Mid-session IP changes do not re-resolve the country code (see §3.2).

### 3.2 Session refresh (last_active_at update)

Per `tool_session_refresh.md`, every successful refresh updates `last_active_at`, `access_token_hash`, `refresh_count`. **The refresh tool does NOT update `device_fingerprint` or `ip_address` or `ip_country_code`.** Those are immutable post-creation.

Mid-session IP changes (laptop moved between Wi-Fi networks; mobile-cell handoff) are not displayed because the stored value reflects the creation-time location. This is intentional: the user already knows their device; what they want from the IP column is "where was this session opened from" (an anti-fraud signal), not "where is this session NOW" (operational noise).

The `tool_session_refresh.md` device-fingerprint-mismatch behaviour at §"Device fingerprint mismatch" applies when a refresh attempt presents a fingerprint that differs from the stored value (cross-device replay). The mismatch revokes the session and emits `AUTH_SESSION_DEVICE_MISMATCH` (MEDIUM) — that flow is the security trigger, not a re-capture path.

### 3.3 Why `last_active_at` updates only on refresh

`last_active_at` is NOT updated on every API call (that would mean every read-path query incurs a write to `user_sessions`, multiplying write load by N). Instead, it updates only on the refresh path (typically every 10-15 minutes per the Supabase access-token TTL). The displayed value lags real activity by up to one refresh interval; this is acceptable for the surface's purpose ("when was I last on this device") and avoids the write amplification.

---

## 4. Display transformations

The DB returns `device_fingerprint`, `ip_address_masked`, `ip_country_code`, `created_at`, `last_active_at`, `is_current`, `client_form_factor`. The UI applies four additional transformations:

| Column | Raw value | Display rendering |
|---|---|---|
| Device | `"Chrome/138 on macOS"` (60 chars max) | Rendered verbatim. If truncated by the 60-char cap during capture, no ellipsis (the cap is far above realistic values). |
| IP | `"185.107.x.x"` (first two octets, last two `x`'d) | Rendered as-is. Hover surfaces "Opened from <country flag emoji + country name>" if `ip_country_code` non-NULL. |
| Created | `2026-05-15T10:23:47Z` | Local-TZ formatted via `Intl.DateTimeFormat(user_locale)` per `settings_page_ui_spec.md` §Form behaviour. |
| Last active | `2026-05-28T08:14:00Z` | Relative ("3 minutes ago") if < 1 day; absolute ("May 28, 08:14") if older. |
| Is-current | boolean | A "This device" pill rendered as `--color-status-info` background, `--color-text-on-info` text, `--radius-pill`. Mutually exclusive with the Revoke button — the current session's Revoke button text becomes "Sign out". |
| Client form factor | `"WEB"` / `"MOBILE"` / `"API"` | Icon (Lucide `Monitor` / `Smartphone` / `Terminal`) leading the Device column. |

### 4.1 IP masking specifics

`auth.mask_ip(inet)` is the canonical function. IPv4: first two octets + `.x.x`. IPv6: first 32 bits hex + `:x:x:x:x:x:x`. Implementation:

```sql
CREATE OR REPLACE FUNCTION auth.mask_ip(p_ip inet) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN family(p_ip) = 4 THEN
      split_part(host(p_ip), '.', 1) || '.' || split_part(host(p_ip), '.', 2) || '.x.x'
    WHEN family(p_ip) = 6 THEN
      regexp_replace(host(p_ip), '^([0-9a-f]{1,4}:[0-9a-f]{1,4}):.*', '\1:x:x:x:x:x:x')
    ELSE
      'unknown'
  END
$$;
```

The function is IMMUTABLE so it can be used in indexed expressions if a future surface needs it.

---

## 5. Privacy + retention

| Concern | Behaviour |
|---|---|
| Raw IP storage | Stored at row creation in `user_sessions.ip_address`. Not exposed via any read API. Used internally only by anti-fraud signal queries (e.g., `AUTH_SESSION_DEVICE_MISMATCH` triggers comparing source IP to historical pattern). |
| Raw IP in audit payloads | Forbidden per `audit_log_policies.md` PII-minimisation rule. Audit events carry only `ip_country_code`, never raw IP. |
| Raw IP in logs | Forbidden — application logs MUST use the masked form via `auth.mask_ip`. Lint rule in `lint_pii_in_logs.sh` (B05·P03 deliverable) enforces this. |
| Retention | `user_sessions` rows are kept indefinitely after revoke/expire for audit-trail joinability, BUT the `ip_address` column is set to NULL after 90 days post-revoke via the `gc_session_ip_redaction` daily job (B02·P11 migration). The `device_fingerprint` and `ip_country_code` are retained — they're already low-PII. |
| GDPR erasure | A subject-erasure request per `gdpr_right_to_erasure_policy.md` anonymises the entire `user_sessions` row to a tombstone marker (user_id → anonymised UUID, ip_address → NULL, device_fingerprint → 'ERASED'). |

The 90-day raw-IP retention is a deliberate compromise: long enough for anti-fraud investigations triggered by alerts, short enough to limit the blast radius of a database leak.

---

## 6. Edge cases

| Case | Behaviour |
|---|---|
| User has 100+ active sessions (unusual; perhaps automated headless test runs) | List paginates at 50 sessions per page; "Load more" button reveals the next 50. No hard cap on session count. |
| Session created from a Tor exit node | `ip_country_code` resolves to the exit-node's country (typically not the user's actual country). Displayed as-is; no warning. Tor detection is out-of-scope for MVP. |
| Session created from a private/RFC-1918 IP (e.g., behind a corporate VPN that strips X-Forwarded-For) | `ip_address = NULL`, `ip_country_code = NULL`. Display shows "Unknown location" with no flag. |
| Session created from a mobile device that rotates its UA per app version | Each app update creates a new device_fingerprint string (e.g., `"Mobile-App/iOS-17.4"` vs `"Mobile-App/iOS-17.5"`). The user sees both rows if both sessions are still active. Cosmetic; not a security concern. |
| Multiple sessions from the same browser+OS+IP (e.g., user opens two tabs) | Each browser tab does NOT create a new session — sessions are user-account-bound, not tab-bound. Same JWT shared across tabs. List shows ONE row per (user, device, login event). |
| Session created during a network handoff (Wi-Fi → mobile data mid-login) | The IP captured is whichever network was active when the auth-callback completed. The other network's IP never makes it to the row. |

---

## 7. Cross-references

- `session_schema.md` — `user_sessions` table DDL; column definitions for `device_fingerprint`, `ip_address` (inet), `ip_country_code` (text), `last_active_at`, `is_revoked`
- `session_lifetime_policy.md` — idle / absolute timeouts; expires_at population
- `tool_session_refresh.md` — refresh path that updates `last_active_at`; device-fingerprint mismatch behaviour
- `settings_page_ui_spec.md` §Security → Active sessions — consumer of `auth.list_my_sessions`
- `audit_event_taxonomy.md` — `AUTH_SESSION_CREATED` (LOW), `AUTH_SESSION_REVOKED`, `AUTH_SESSION_DEVICE_MISMATCH` (MEDIUM), `AUTH_SESSION_EXPIRED`
- `audit_log_policies.md` — PII-minimisation rule (raw IP forbidden in audit payloads)
- `audit_event_payload_schemas.md` — payload shape for `AUTH_SESSION_CREATED` (consumes country_code, NOT raw IP)
- `principal_context_schema.md` §12 — `current_user_id` helper consumed by §1 query
- `maxmind_geoip_integration.md` — IP → country code resolution at §3.1
- `gdpr_right_to_erasure_policy.md` — anonymisation behaviour per §5
- `mobile_write_rejection_endpoints.md` — Revoke session is a write; mobile blocked
- `lint_pii_in_logs.sh` — application-log enforcement (B05·P03)
- Block 02 Phase 02 — auth + session creation (capture site)
- Block 02 Phase 11 — account settings (UI consumer)
- Block 05 Phase 02 — audit taxonomy (event consumer)
- Stage 1 decision — no precise device fingerprinting (canvas / WebGL / font enumeration explicitly excluded)
