# Bank Feed UI Spec

**Block:** data  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Bank Feed settings page allows users to connect, manage, and monitor automated bank data feeds for a business entity. It is accessible via **Settings → Bank Feeds** or directly at `/settings/bank-feeds`. The page is scoped to a single `business_entity`. Feeds are read-only data sources; write-back to any bank is not supported.

---

## Page Layout

The page is divided into three sections stacked vertically:

1. **Page header** — title, description, and Add Feed CTA.
2. **Connected feeds list** — one card per connected feed.
3. **Manual upload panel** — always visible below the feed list as a secondary input path.

### Page Header

| Element | Content |
|---|---|
| Title | "Bank Feeds" |
| Subtitle | "Connected feeds sync transactions automatically. You can also upload statements manually." |
| Primary CTA | "+ Add Feed" button, `--color-blue-600` fill |

The Add Feed button is disabled and shows a tooltip "Upgrade your plan to add more feeds" when the business entity has reached its feed limit for the current subscription tier.

---

## Connected Feeds List

Each connected feed renders as a card. Cards are stacked vertically with `16px` gap. If no feeds are connected, the empty state is shown instead (see Empty State section).

### Feed Card Layout

```
┌─────────────────────────────────────────────────────────────┐
│  [Bank logo]  Alpha Bank Cyprus                 [Status pill]│
│               IBAN: •••• •••• •••• 4872                      │
│               Provider: Nordigen                             │
│               Last sync: 2026-05-16 at 14:32 UTC            │
│                                                              │
│  [Sync Now]   [Settings]                    [Disconnect]    │
└─────────────────────────────────────────────────────────────┘
```

| Field | Source | Notes |
|---|---|---|
| Bank name | `bank_feeds.bank_name` | Display name, not IBAN BIC |
| Bank logo | `bank_feeds.bank_logo_url` | 32×32px, fallback to generic bank icon |
| IBAN last 4 | `bank_feeds.iban_last4` | Masked: `•••• •••• •••• {last4}` |
| Provider | `bank_feeds.provider` | `Nordigen`, `Salt Edge`, or `Manual` |
| Last sync time | `bank_feeds.last_synced_at` | Formatted as locale datetime; `—` if never synced |
| Status pill | `bank_feeds.sync_status` | See Feed Health Indicators |
| Sync Now button | — | Triggers immediate sync; disabled during RUNNING state |
| Settings link | — | Opens per-feed settings drawer |
| Disconnect | — | Opens disconnect confirmation modal |

The card border is `1px solid --color-neutral-200`. On hover, border becomes `--color-neutral-300`.

---

## Feed Health Indicators

The status pill is displayed in the top-right corner of the feed card.

| sync_status | Pill colour | Label | Additional UI |
|---|---|---|---|
| SUCCESS | `--color-green-100` / `--color-green-700` | "Synced" | Last sync timestamp shown |
| RUNNING | `--color-blue-100` / `--color-blue-700` | "Syncing..." | Spinner icon; Sync Now button disabled |
| FAILED | `--color-red-100` / `--color-red-700` | "Failed" | Error detail shown below IBAN line (see below) |
| RATE_LIMITED | `--color-amber-100` / `--color-amber-700` | "Rate Limited" | Retry-after time shown if available |
| PENDING_CONSENT | `--color-neutral-100` / `--color-neutral-600` | "Awaiting consent" | Re-authorise link shown |

### FAILED State Detail

When `sync_status = FAILED`, a collapsible error detail row is rendered below the IBAN line:

```
  Error: "Consent expired — re-authorisation required."
  [Re-authorise]
```

Error text comes from `bank_feeds.last_error_message`. Max display: 120 characters; truncated with "..." and a "Show more" toggle for longer messages.

### RATE_LIMITED State Detail

```
  Rate limited. Next retry: 2026-05-17 at 09:00 UTC
```

`next_retry_at` is sourced from `bank_feeds.rate_limit_reset_at`. If null, text reads "Retry time unknown. Sync will resume automatically."

---

## Add Feed Flow

Triggered by clicking "+ Add Feed". Rendered as a full-screen modal (max-width 560px, centered).

### Step 1 — Provider Selection

Grid of provider tiles (2 columns on desktop, 1 on mobile):

| Provider | Logo | Notes |
|---|---|---|
| Nordigen (GoCardless) | Nordigen logo | Supports 2,000+ European banks |
| Salt Edge | Salt Edge logo | Supports 5,000+ institutions |
| Manual Upload | Upload icon | No OAuth; skip to manual upload flow |

User selects one tile; it gets a `--color-blue-500` border highlight. "Next" button activates.

### Step 2 — Bank Search (Nordigen / Salt Edge)

- Free-text search field: "Search for your bank..."
- Results list rendered as rows: bank logo, bank name, country flag.
- Debounced search: 300ms, min 2 characters.
- Max 10 results shown; "Refine your search" prompt if more match.

### Step 3 — OAuth Handoff

A full-width info panel is shown:

```
You will be redirected to {bank_name} to authorise read-only access.
This connection is powered by {provider}.
Your login credentials are never stored by this system.
```

"Authorise" button opens the provider OAuth URL in a new tab (for Nordigen: `requisition_link`; for Salt Edge: `connect_url`). The modal displays a waiting state: "Waiting for authorisation..." with a spinner. Polling interval: 3s. Timeout: 10 minutes — if not completed, modal shows error state with "Try again" option.

On successful OAuth return, the modal advances automatically to Step 4.

### Step 4 — Account Selection

If the provider returns multiple accounts for the institution, a list is shown:

```
Select the account(s) to sync:
[ ] Alpha Bank Current Account (•••• 4872)
[ ] Alpha Bank Savings (•••• 1193)
```

At least one account must be selected. "Save" button is disabled until a selection is made.

### Step 5 — Test Connection

The system performs an initial sync probe (GET last 7 days of transactions). A progress indicator is shown. On success: green checkmark and "Connection successful. First sync is running in the background." On failure: red icon, error message, and "Try again" / "Go back" options.

### Step 6 — Save and Confirm

"Done" button closes the modal. The new feed card appears at the top of the Connected Feeds list with status `RUNNING`.

---

## Manual Upload Alternative

Rendered as a bordered panel below the feeds list, always visible.

```
┌──────────────────────────────────────────────────────────┐
│  Upload bank statement                                    │
│                                                          │
│  [Drag a CSV or OFX file here, or click to browse]      │
│                                                          │
│  Supported formats: CSV (comma-separated), OFX, MT940   │
│  Max file size: 25 MB                                    │
└──────────────────────────────────────────────────────────┘
```

- Drag-over state: border becomes `--color-blue-400` dashed, background `--color-blue-50`.
- After file drop or selection, file is validated client-side: format check, size check.
- Invalid file shows inline error: "Unsupported format. Use CSV, OFX, or MT940."
- Valid file triggers upload to `intake.intake_files`. The file name, size, and a progress bar are shown.
- On completion, a success banner: "Statement uploaded. It will be processed with the next run."
- See `/sub/ui/manual_upload_ui_spec.md` for the full manual upload flow.

---

## Disconnect Flow

Clicking "Disconnect" on a feed card opens a confirmation modal.

```
Disconnect Alpha Bank Cyprus?

Syncing will stop immediately. Transactions already imported will
not be deleted. You can reconnect this account at any time.

[Cancel]  [Disconnect]
```

"Disconnect" is a destructive button (`--color-red-600`). On confirm, the feed card is removed from the list. If the disconnect API call fails, a toast error is shown: "Could not disconnect feed. Please try again."

---

## Empty State

Shown when no feeds are connected and no statements have been uploaded.

```
[Bank icon, 48px]
No bank feeds connected

Connect a bank feed to automatically import transactions,
or upload a statement manually below.

[+ Add Feed]
```

---

## Interaction States

| Action | Loading indicator | Success feedback | Error feedback |
|---|---|---|---|
| Sync Now | Button shows spinner, text "Syncing..." | Status pill → SUCCESS; last sync time updated | Status pill → FAILED; error detail shown |
| Add Feed (save) | Modal progress bar | Feed card appears, banner "Feed connected" | Modal error state with message |
| Disconnect | Button spinner | Card removed, toast "Feed disconnected" | Toast error |
| Manual upload | Progress bar below file name | Banner above panel | Inline error below file name |

---

## Error States

- **Network error on page load**: Full-page error banner "Could not load bank feeds. Refresh the page." with Retry button.
- **Partial load failure** (feed list loads but status check fails): Individual cards show "Status unavailable" pill in `--color-neutral-100`.
- **OAuth timeout**: Modal shows "Authorisation timed out. Please try again." with "Start over" link.

---

## Mobile Layout

- Feed cards stack to full width; bank logo hidden on viewports < 400px.
- Add Feed modal is full-screen (no max-width cap) on mobile.
- Manual upload area shows tap-to-browse only; drag-drop is suppressed on touch devices.
- Status pills collapse to icon-only on viewports < 480px; full label on hover/tap.

---

## Related Documents

- `/sub/schemas/bank_feed_schema.md` — `bank_feeds` table definition
- `/sub/ui/manual_upload_ui_spec.md` — Full manual upload flow
- `/sub/ui/settings_page_ui_spec.md` — Settings page shell and navigation
- `/sub/integrations/nordigen_integration.md` — Nordigen OAuth flow and requisition lifecycle
- `/sub/runbooks/bank_feed_reconnect_runbook.md` — Ops runbook for expired consents
