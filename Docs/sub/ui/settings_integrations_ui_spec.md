# Settings — Integrations UI Spec

**Category:** UI · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

UI specification for the Settings → Integrations page. This page allows OWNER and ADMIN roles
to view, connect, and manage third-party integrations: bank feeds, Stripe Connect, SMTP relay,
and the VIES VAT validation API.

---

## Access control

| Role | View | Add | Reconnect | Disconnect |
| --- | --- | --- | --- | --- |
| OWNER | Yes | Yes | Yes | Yes |
| ADMIN | Yes | Yes | Yes | Yes |
| ACCOUNTANT | Yes (read) | No | No | No |
| BOOKKEEPER | No | No | No | No |
| READ_ONLY | No | No | No | No |

ACCOUNTANT can view integration statuses but cannot add or modify integrations. All write
operations require OWNER or ADMIN. The page is not rendered for BOOKKEEPER and READ_ONLY;
navigating to `/settings/integrations` redirects to `/settings`.

---

## Page structure

Accessible at `/settings/integrations`. Consists of:

1. Page header — title "Integrations", "Add Integration" button (top-right, OWNER/ADMIN only).
2. Connected integrations list — cards grouped by category.
3. Empty state (when no integrations are connected).

Integration categories and their display order:

1. Bank Feeds
2. Payment Processors
3. Email & Notifications
4. Tax & Compliance

---

## Integration card layout

Each connected integration renders as a card. Card dimensions: full-width within its category
section, min-height 120px.

| Element | Detail |
| --- | --- |
| Provider logo | 40×40px, left-aligned |
| Provider name | Bold, `--text-base` |
| Integration subtype | Smaller text, e.g., "Revolut Business" or "Bank of Cyprus SEPA" |
| Status badge | See status badge spec below |
| Last sync | "Last synced {relative time}" — e.g., "Last synced 12 minutes ago" |
| Credential expiry | Shown when expiry is known; warning at ≤14 days (see expiry warning) |
| Reconnect button | Shown when status is EXPIRED or ERROR; OWNER/ADMIN only |
| Disconnect button | Shown on all connected integrations; OWNER/ADMIN only; confirmation required |
| Settings caret | Expands card to show advanced settings (scope, sync frequency) |

---

## Status badges

| Status | Label | Background | Text | Notes |
| --- | --- | --- | --- | --- |
| ACTIVE | Active | `--color-success-200` | `--color-success-800` | Syncing normally |
| SYNCING | Syncing | `--color-info-200` | `--color-info-800` | Sync in progress |
| PAUSED | Paused | `--color-neutral-200` | `--color-neutral-700` | Manually paused |
| EXPIRED | Expired | `--color-warning-200` | `--color-warning-800` | Credentials expired |
| ERROR | Error | `--color-danger-200` | `--color-danger-800` | Last sync failed |
| DISCONNECTED | Disconnected | `--color-neutral-100` | `--color-neutral-500` | Manually disconnected |

---

## Credential health indicators

Each card shows a credential health row below the status badge when credential expiry data
is available.

### Normal state (>14 days remaining)
  "Credentials valid until {expiry_date}"

Displayed in `--color-neutral-600`, `--text-sm`.

### Warning state (≤14 days remaining)
  A yellow warning icon precedes the text: "Credentials expire in {N} days — rotate now"

Background: `--color-warning-50` strip across the bottom of the card.
Text: `--color-warning-800`.
A "Rotate credentials" link opens the credential rotation modal (see credential rotation modal).

### Expired state (0 days / past expiry)
  A red error icon: "Credentials expired on {expiry_date}"

Background: `--color-danger-50` strip.
Text: `--color-danger-800`.
The Reconnect button is elevated to a primary button style.

The 14-day threshold is enforced at the backend. A `CREDENTIAL_ROTATION_DUE` notification is
also dispatched to OWNER and ADMIN users 14 days before expiry per `notification_center_ui_spec`.

---

## Integration categories and providers

### Bank Feeds

Supported providers:

| Provider | Auth method | Sync frequency |
| --- | --- | --- |
| Revolut Business | OAuth 2.0 | Real-time webhook + 6h poll fallback |
| Bank of Cyprus | Manual SEPA CSV upload | On upload trigger |
| Hellenic Bank | Manual SEPA CSV upload | On upload trigger |
| Open Banking (generic) | OAuth 2.0 (PSD2) | 6h poll |

### Payment Processors

| Provider | Auth method | Notes |
| --- | --- | --- |
| Stripe Connect | OAuth 2.0 | Connects via Stripe OAuth flow; receives charge and payout webhooks |

### Email & Notifications

| Provider | Auth method | Notes |
| --- | --- | --- |
| SMTP Relay | Manual credentials | Used for outbound system emails (invoices, notifications) |
| Gmail (OAuth) | OAuth 2.0 | Used for document intake via Gmail attachment monitoring |

### Tax & Compliance

| Provider | Auth method | Notes |
| --- | --- | --- |
| VIES API | API key | EU VIES VAT number validation; no OAuth flow |
| Cyprus Tax Department | Manual credential | For VAT return submission via TAXISnet |

---

## Add integration flow

The "Add Integration" button opens a modal with two steps.

### Step 1 — Select provider

A grid of available (not yet connected) integration provider cards. Each card shows the
provider logo, name, and category. Clicking a card advances to Step 2.

### Step 2 — Connect

The connect form varies by auth method:

**OAuth flow (Revolut, Stripe, Gmail, Open Banking):**
- A "Connect with {Provider}" button.
- Clicking opens the provider's OAuth authorization page in a new tab.
- On successful redirect, the callback handler stores the token and closes the modal.
- The new integration card appears in the list with status ACTIVE (or SYNCING on first sync).
- Emits `AUTH_OAUTH_CONNECTED` (LOW).

**Manual credentials (SMTP, VIES, TAXISnet):**
- A form with the required credential fields (host, port, username, password; or API key).
- All credential fields are masked (`type=password`).
- A "Test connection" button (optional step) sends a test probe before saving.
- Saving encrypts credentials via Vault before storage.
- Emits `INTEGRATION_CONNECTED` (LOW) on success.

On failure, an inline error message describes the problem. The modal remains open for
correction.

---

## Credential rotation modal

Opened from the "Rotate credentials" link on cards in warning or expired state.

Content:
- Current credential status summary (expiry date, provider).
- For OAuth integrations: a "Re-authorize" button that restarts the OAuth flow.
- For manual credential integrations: a credentials form (same as add flow) with existing
  values masked.
- A "Save & verify" button that tests the new credentials before committing.

On success: the card's credential expiry updates; status badge returns to ACTIVE.
Emits `AUTH_OAUTH_TOKEN_REFRESHED` (LOW) for OAuth re-authorization, or
`INTEGRATION_CONNECTED` (LOW) for manual credential update.

---

## Disconnect action

Clicking "Disconnect" on any card opens a confirmation dialog:
  "Disconnect {provider}? This will stop syncing. Existing data will not be deleted."

Confirming calls `auth.integrations_disconnect` with the integration ID. The card status updates
to DISCONNECTED. The Reconnect button replaces the Disconnect button.

For OAuth integrations: calls the provider's token revocation endpoint.
Emits `INTEGRATION_DISCONNECTED` (LOW) on success.
Emits `AUTH_OAUTH_TOKEN_REVOKED` (MEDIUM) if token revocation also occurred.

---

## Mobile layout

On viewports below 768px:
- Integration cards stack vertically in full width.
- The Settings caret is available on mobile; expands inline below the card.
- The "Add Integration" button is visible on mobile.
- OAuth flows open in the default mobile browser and redirect back via deep link.
- Manual credential forms are available on mobile.
- Credential rotation is available on mobile.

---

## Empty state

No integrations connected:
  "No integrations connected yet. Connect a bank feed or payment processor to start importing
  transactions automatically."

---

## Related Documents

- `credential_rotation_runbook.md` — credential rotation operating procedure
- `bank_feed_ui_spec.md` — bank feed configuration and sync status
- `settings_page_ui_spec.md` — Settings page parent structure and navigation
- `supabase_auth_integration_guide.md` — OAuth token storage and refresh
- `notification_center_ui_spec.md` — credential expiry notification delivery
- `audit_event_taxonomy.md` — `AUTH_OAUTH_CONNECTED`, `AUTH_OAUTH_TOKEN_REFRESHED`,
  `AUTH_OAUTH_TOKEN_REVOKED`, `INTEGRATION_DISCONNECTED`, `INTEGRATION_REFRESH_FAILED`
- `design_system_tokens.md` — colour, spacing, typography tokens
