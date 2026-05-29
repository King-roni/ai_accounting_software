# drive_folder_mapping_ui_spec

**Category:** UI specs · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 09 — Document Intake & Extraction · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

The UX for configuring the Google Drive folder mapping per business. Per Stage 1: "Drive folder mapping: User explicitly connects a single root invoice folder per business; the operator's convention is **2-week date subfolders**, which Block 09's Drive finder uses to scope searches by transaction date."

Lives in business settings. Owner / Admin per `permission_matrix` (`EXTERNAL_INTEGRATION` surface). Mobile rejected per `mobile_write_rejection_endpoints`.

---

## Entry point

Settings → Integrations → Google Drive.

Pre-condition: user has authenticated with Google via OAuth per `oauth_token_encryption_schema`. The Drive folder picker requires an active token with `drive.readonly` scope.

## States

### State 1 — Not connected

```
┌────────────────────────────────────────────────────────────────┐
│  Google Drive                                                  │
│                                                                │
│  Connect Google Drive to automatically discover                │
│  invoices and receipts during your workflows.                  │
│                                                                │
│  Cyprus Bookkeeping will read documents from a single          │
│  invoice folder you choose. We never modify your Drive.        │
│                                                                │
│  [Connect Google Drive]                                        │
└────────────────────────────────────────────────────────────────┘
```

Click triggers Google OAuth flow. Per Stage 1 EU residency: OAuth callback URL is EU-hosted. Per Stage 1 "Gmail/Drive token refresh authority: Any Owner or Admin": Owner / Admin can perform this; lower roles see disabled UI.

### State 2 — Connected, no folder selected

```
┌────────────────────────────────────────────────────────────────┐
│  Google Drive                                            ●     │
│                                                                │
│  ✓ Connected as andreas@example.com                            │
│                                                                │
│  Choose your invoice folder                                    │
│  We'll search for documents inside this folder during          │
│  your workflows.                                               │
│                                                                │
│  [Choose folder]                                               │
│                                                                │
│  [Disconnect]                                                  │
└────────────────────────────────────────────────────────────────┘
```

The green dot in the title row indicates "connected." Disconnect button below the primary action.

Click "Choose folder" opens a folder picker modal. Per Google Drive Picker API per `oauth_token_encryption_schema`.

### State 3 — Folder selected

```
┌────────────────────────────────────────────────────────────────┐
│  Google Drive                                            ●     │
│                                                                │
│  ✓ Connected as andreas@example.com                            │
│                                                                │
│  Invoice folder                                                │
│  📁 Cyprus Bookkeeping / Invoices                              │
│  Last verified: 5 minutes ago                                  │
│                                                                │
│  Folder convention                                             │
│  We expect 2-week date subfolders inside this folder:          │
│  📁 2026-01-01 to 2026-01-14                                   │
│  📁 2026-01-15 to 2026-01-28                                   │
│  📁 2026-01-29 to 2026-02-11                                   │
│  ...                                                           │
│                                                                │
│  ✓ Convention check passed (3 subfolders match expected format)│
│                                                                │
│  [Change folder]              [Disconnect]                     │
└────────────────────────────────────────────────────────────────┘
```

The folder convention is **2-week date subfolders** per Stage 1. The UI displays this convention so users know what subfolder structure to maintain. Block 09's Drive finder uses these subfolders to scope searches by transaction date.

The convention check runs at folder-selection time + periodically (per `analytics_refresh_runbook` shape):

- Lists subfolders in the selected folder
- Counts how many match the date-range naming pattern (`YYYY-MM-DD to YYYY-MM-DD`)
- If ≥ 1 match: "Convention check passed"
- If 0 matches: warning message "No date subfolders found. Block 09 won't scope searches; documents will be searched across the entire folder."

### State 4 — Convention check failed (degraded)

```
⚠ Convention check failed
  We didn't find any 2-week date subfolders in your folder.
  Documents will be searched across the entire folder, which
  may be slower for large folders. To improve performance,
  organize invoices into subfolders named like "2026-01-01 to
  2026-01-14".

  [Continue anyway]   [Choose a different folder]
```

Users can opt-in to the degraded behavior or choose a properly-organized folder. Per Stage 1 the convention is the operator's recommendation, not a hard requirement.

### State 5 — Token expired

```
⚠ Token expired
  Your Drive connection expired. Reconnect to continue using
  document discovery.

  [Reconnect Google Drive]
```

Per `oauth_token_encryption_schema` `status = REFRESH_FAILED`. The token-refresh integration attempted to refresh and failed. User reconnect re-authorizes.

## Folder picker modal

Uses Google's Drive Picker API embedded in an iframe. The picker is Google's own UI; we don't customize beyond:

- Locking to "Folders only" filter
- Showing only folders owned by the user (no shared-by-others folders — per Stage 1 single-folder convention)
- Modal size: 800 × 600 px; centered

Per accessibility: focus returns to the Settings page after the modal closes.

## Disconnect flow

Click "Disconnect" opens a confirmation:

```
Disconnect Google Drive?

If you disconnect:
• Active workflows continue with their pre-disconnect state
• Future workflows won't find Drive documents
• Past document references remain in your data

[Disconnect]   [Cancel]
```

Confirm triggers:

1. Revoke OAuth tokens at Google per `oauth_token_encryption_schema` revocation flow
2. Update `oauth_tokens.status = REVOKED`, `oauth_tokens.revoked_at = now()`
3. Clear the selected folder ID
4. Emit `INTEGRATION_DISCONNECTED` audit event

In-flight workflows complete; past document references in `documents.source_link` remain valid (the references don't fail when the integration is later disconnected).

## Per-business scoping

Each business has its own Drive integration. A user with roles on multiple businesses sees a separate "Google Drive" section per business in the settings of each.

Token storage per `oauth_token_encryption_schema` is per-business. Disconnecting one business does not affect others.

## Audit events

| Event | When |
| --- | --- |
| `OAUTH_AUTHORIZED` | OAuth grant succeeds |
| `INTEGRATION_FOLDER_MAPPED` | User selects/changes the Drive folder |
| `INTEGRATION_DISCONNECTED` | User disconnects |
| `OAUTH_TOKEN_REFRESHED` | Background token refresh |
| `INTEGRATION_REFRESH_FAILED` | Refresh failed |

## Token bindings

| Element | Tokens |
| --- | --- |
| Section card | `--color-bg-raised` + `--color-border-subtle` + `--radius-lg` + `--shadow-1` |
| Status dot | `--color-status-success` (green) when connected |
| Folder icon | Lucide `Folder` icon, not emoji (the diagram above shows 📁 as descriptive shorthand) |
| Primary button | `--color-action-primary` |
| Secondary button (Disconnect) | `--color-status-danger` for the destructive action variant |
| Warning banner | `--color-status-warning` |

## Mobile

Settings is desktop-only per `mobile_write_rejection_endpoints`. Mobile users see a banner:

> "Settings are desktop-only. Open Cyprus Bookkeeping on a laptop to manage integrations."

## Component bindings

| Component | Source |
| --- | --- |
| Section card | `Card` from `component_library_ui_spec` |
| Button (primary, secondary, danger) | `Button` |
| Modal (disconnect confirm) | `Modal` |
| Banner (warning, error) | `Banner` |
| Status dot | `Badge` variant |

## Cross-references

- `oauth_token_encryption_schema` — token storage
- `permission_matrix` — `EXTERNAL_INTEGRATION` surface
- `mobile_write_rejection_endpoints` — settings desktop-only
- `component_library_ui_spec` — base components
- `design_system_tokens` — tokens
- `audit_log_policies` — OAuth + INTEGRATION events
- Block 02 Phase 08 — OAuth integration foundation (architecture)
- Block 09 Phase 06 — Drive finder (consumer)
- Stage 1 decision — single-folder + 2-week subfolder convention
