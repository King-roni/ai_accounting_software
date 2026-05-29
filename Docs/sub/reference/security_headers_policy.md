# Security Headers Policy

**Block:** Platform Security
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This policy defines the HTTP security headers enforced on all responses from the platform's web application and API. Headers are set at the Vercel Edge and Supabase Edge Function layers, ensuring they are applied before any application code runs. Compliance is validated monthly via Mozilla Observatory and in automated CI checks on every deployment.

## Header Definitions

### Content-Security-Policy (CSP)

```
Content-Security-Policy:
  default-src 'self';
  script-src 'self' 'nonce-{nonce}';
  style-src 'self' 'nonce-{nonce}';
  img-src 'self' data: https:;
  font-src 'self';
  connect-src 'self' https://*.supabase.co wss://*.supabase.co;
  frame-ancestors 'none';
  form-action 'self';
  base-uri 'self';
  object-src 'none';
  upgrade-insecure-requests;
```

**Directive rationale:**

| Directive              | Value                                    | Rationale                                                            |
|------------------------|------------------------------------------|----------------------------------------------------------------------|
| `default-src`          | `'self'`                                 | Block all unlisted resource types by default                         |
| `script-src`           | `'self' 'nonce-{nonce}'`                 | Allows only same-origin scripts and nonce-tagged inline scripts      |
| `style-src`            | `'self' 'nonce-{nonce}'`                 | Allows only same-origin stylesheets and nonce-tagged inline styles   |
| `img-src`              | `'self' data: https:`                    | Allows same-origin, data URIs (icons), and HTTPS images              |
| `connect-src`          | `'self' https://*.supabase.co wss://*.supabase.co` | Allows API and Realtime connections to Supabase         |
| `frame-ancestors`      | `'none'`                                 | Prevents embedding in iframes (clickjacking protection)              |
| `form-action`          | `'self'`                                 | Prevents form submissions to external domains                        |
| `object-src`           | `'none'`                                 | Blocks plugins (Flash, etc.)                                         |
| `upgrade-insecure-requests` | (present)                          | Instructs browser to upgrade HTTP to HTTPS automatically             |

`'unsafe-inline'` and `'unsafe-eval'` are never used. Any inline script requirement must use nonce-based approval.

### CSP Nonce Generation

A unique nonce is generated per HTTP request. It is used to approve inline scripts that cannot be avoided (e.g., Next.js hydration markers):

```typescript
// In Next.js middleware (middleware.ts)
import crypto from 'crypto';

export function middleware(request: NextRequest) {
    const nonce = crypto.randomBytes(16).toString('base64');
    const csp = buildCSP(nonce);

    const response = NextResponse.next();
    response.headers.set('Content-Security-Policy', csp);
    response.headers.set('x-nonce', nonce);  // passed to pages via headers
    return response;
}
```

The `x-nonce` header is read by the root layout to inject the nonce into `<script>` and `<style>` tags. The nonce is not logged and is not predictable between requests.

### Strict-Transport-Security (HSTS)

```
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
```

- `max-age=31536000`: 1-year HSTS policy. After visiting the site once, browsers enforce HTTPS for all subsequent requests within the year.
- `includeSubDomains`: All subdomains (staging, api, etc.) are covered by the HSTS policy.
- `preload`: The domain is submitted to browser HSTS preload lists. This requires maintenance of HTTPS across all subdomains indefinitely — do not remove this flag without removing from preload lists first.

This header is only served over HTTPS. It is not set in local development environments.

### X-Frame-Options

```
X-Frame-Options: DENY
```

Prevents the application from being embedded in any `<iframe>`, `<frame>`, or `<object>` element, regardless of origin. This provides redundant clickjacking protection alongside `frame-ancestors 'none'` in CSP (for browsers that support CSP Level 3).

### X-Content-Type-Options

```
X-Content-Type-Options: nosniff
```

Prevents browsers from MIME-sniffing the content type of a response. Without this header, a browser might interpret a text/plain response as JavaScript if the content resembles a script. Combined with correct `Content-Type` headers on all API responses, this eliminates MIME confusion attacks.

### Referrer-Policy

```
Referrer-Policy: strict-origin-when-cross-origin
```

- Same-origin requests: full URL is included in the `Referer` header.
- Cross-origin requests (HTTPS → HTTPS): only the origin is sent (no path or query string).
- Cross-origin requests downgrading to HTTP: no `Referer` sent.

This policy prevents sensitive path components (e.g., `/invoices/{id}`) from leaking to third-party domains via referrer headers, while still supporting same-origin analytics.

### Permissions-Policy

```
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), bluetooth=()
```

All browser feature permissions are explicitly denied. The platform has no use for camera, microphone, geolocation, or hardware device access. Denying unused permissions reduces the attack surface if a dependency or injected script attempts to use them.

### Cache-Control for Sensitive Endpoints

Auth, API, and user-data endpoints set:

```
Cache-Control: no-store, no-cache, must-revalidate
Pragma: no-cache
```

Static assets (JS, CSS, fonts) use:

```
Cache-Control: public, max-age=31536000, immutable
```

Static assets are served with content-hashed filenames, making long-lived caching safe.

## CORS Policy

CORS is enforced at the Edge Function level.

**Allowed origins per environment:**

| Environment | Allowed Origins                                          |
|-------------|----------------------------------------------------------|
| Production  | `https://app.example.cy`                                 |
| Staging     | `https://staging.example.cy`                             |
| Local dev   | `http://localhost:3000`, `http://localhost:54321`         |

Wildcard `*` is never used in production or staging. The `Access-Control-Allow-Origin` header is set to the specific requesting origin if it is on the allowlist; otherwise the request is rejected with 403.

**Allowed headers:**
```
Access-Control-Allow-Headers: Content-Type, Authorization, X-Request-ID, X-Idempotency-Key
```

**Allowed methods:**
```
Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS
```

Preflight requests (OPTIONS) receive a 204 response with the above headers and `Access-Control-Max-Age: 86400`.

`Access-Control-Allow-Credentials: true` is set only when `Access-Control-Allow-Origin` is a specific non-wildcard origin (required for sending cookies with cross-origin requests).

## Cookie Security

All cookies set by the platform use the following attributes:

| Cookie               | Secure | HttpOnly | SameSite | Path       | Notes                        |
|----------------------|--------|----------|----------|------------|------------------------------|
| Refresh token        | Yes    | Yes      | Strict   | /api/auth  | Session token cookie         |
| CSRF token           | Yes    | No       | Strict   | /          | Must be readable by JS       |
| Preferences (UI)     | Yes    | No       | Lax      | /          | No sensitive data            |

The refresh token cookie never appears in JavaScript — `document.cookie` access is blocked by `HttpOnly`. The CSRF token cookie is readable by JavaScript so it can be included in request headers.

## Vercel Configuration

Headers are set in `vercel.json`:

```json
{
    "headers": [
        {
            "source": "/(.*)",
            "headers": [
                { "key": "X-Frame-Options",        "value": "DENY" },
                { "key": "X-Content-Type-Options",  "value": "nosniff" },
                { "key": "Referrer-Policy",         "value": "strict-origin-when-cross-origin" },
                { "key": "Permissions-Policy",      "value": "camera=(), microphone=(), geolocation=(), payment=(), usb=(), bluetooth=()" },
                { "key": "Strict-Transport-Security", "value": "max-age=31536000; includeSubDomains; preload" }
            ]
        }
    ]
}
```

CSP is not set via `vercel.json` because it requires per-request nonce generation. It is set in Next.js middleware where the nonce is generated.

## CI Header Validation

An automated step in the deployment pipeline validates that all required security headers are present and correctly valued on the deployed environment:

```bash
# In CI pipeline (post-deployment check)
npx security-headers-check \
    --url https://app.example.cy \
    --required-headers \
        "Strict-Transport-Security" \
        "X-Frame-Options:DENY" \
        "X-Content-Type-Options:nosniff" \
        "Content-Security-Policy" \
        "Referrer-Policy" \
        "Permissions-Policy"
```

A failed header check blocks the deployment from being promoted to production traffic. The check runs against the staging deployment before the production promotion step.

## Monthly Observatory Audit

Security headers are tested monthly via Mozilla Observatory (`https://observatory.mozilla.org`). Target score: A+ (100/100). Any regression below A triggers an incident review.

Results are logged in the security monitoring runbook. The last three Observatory scans are retained for trend analysis.

## Local Development

Security headers are not enforced in `localhost:3000` development mode because:
- HSTS causes browser-enforced HTTPS that breaks local HTTP development.
- CSP nonces add complexity to hot-reload environments.

A reduced header set is applied locally (X-Content-Type-Options, X-Frame-Options) but HSTS and strict CSP are skipped. Developers should test security headers against the staging environment before merging changes that affect middleware configuration.

## Related Documents

- `policies/oauth_policy.md` (cookie attributes for OAuth tokens)
- `policies/session_management_policy.md` (session cookie configuration)
- `reference/supabase_auth_integration_guide.md` (auth cookie handling)
- `policies/encryption_at_rest_policy.md`
- `reference/error_code_catalog.md`
