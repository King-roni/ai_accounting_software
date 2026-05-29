# Block 02 — Phase 08: OAuth Integration Foundation

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (External Authorization section)
- Block doc: `Docs/blocks/05_security_and_audit.md` (Field-level encryption — Supabase Vault + pgcrypto)
- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Phase 9.1, 9.2 — consumes these tokens)
- Decisions log: `Docs/decisions_log.md` (Token refresh: any Owner or Admin; Drive root folder with 2-week date subfolders convention)

## Phase Goal

Each business can connect a single Gmail account and a single Google Drive folder. The OAuth tokens are encrypted at rest in Supabase Vault, refreshable by any Owner/Admin (not just the original connecting user), and disconnectable with full audit. Block 09's Email and Drive finders consume these tokens later.

## Dependencies

- Phase 02 (auth)
- Phase 04 (Owner/Admin permission)
- Phase 06 (disconnect is a step-up surface)
- Block 05 Vault integration available (or, if deferred, document the dependency)

## Deliverables

- **`business_integrations` table** — `id`, `business_id`, `provider` (`GMAIL` or `GOOGLE_DRIVE`), `status` (`ACTIVE`, `DISCONNECTED`, `ERROR`), `connected_user_id` (the user who initially connected), `oauth_token_encrypted`, `oauth_refresh_token_encrypted`, `scope`, `connected_at`, `last_refreshed_at`, `last_used_at`. One row per (business, provider).
- **`drive_folder_mappings` table** (for the Drive provider) — `business_id`, `root_folder_id`, `subfolder_naming_convention` (default: `2_week_date_ranges` per Stage 1 decision; **only `2_week_date_ranges` is supported in MVP** — the enum shape is open for post-MVP additions), `connected_at`.
- **Google OAuth client config** — single Google Cloud project, separate OAuth clients for Gmail and Drive scopes, EU-region storage, EU consent screen.
- **Connect flow:**
  - Owner or Admin initiates from business settings.
  - OAuth redirect with read-only scopes (Gmail `gmail.readonly`, Drive `drive.readonly` plus folder-restricted access).
  - Callback handler stores tokens encrypted via Vault + pgcrypto (per Block 05).
  - For Drive: user picks the root invoice folder; mapping saved with the convention flag.
- **Refresh flow:**
  - Triggered automatically before expiry by a background job and on-demand by the email/Drive finders.
  - **Any Owner or Admin** of the business can manually trigger refresh — not just the original connecting user.
  - Refresh failures mark `status = ERROR`, surface a review issue in Block 14, and emit `INTEGRATION_REFRESH_FAILED`.
- **Disconnect flow** — Owner/Admin only; step-up required (Phase 06); revokes the token at Google, marks row `DISCONNECTED`, retains audit history.
- **Scope assertion** at connect and at use — refuse to read scopes outside the granted set.
- **Audit events:** `INTEGRATION_CONNECTED`, `INTEGRATION_REFRESHED`, `INTEGRATION_DISCONNECTED`, `INTEGRATION_REFRESH_FAILED`.

## Definition of Done

- Owner can complete a Gmail connect flow end-to-end; tokens are encrypted at rest (verifiable via inspection of the table).
- Owner can complete a Drive connect flow including picking a root folder; the folder mapping is saved.
- A different Admin (not the original connecter) can refresh the token successfully; the audit log records who did it.
- Disconnect prompts step-up, revokes at Google, and marks the row.
- Failed refreshes produce a review issue in Block 14 (placeholder is fine if Block 14 isn't built yet — emit the audit event).
- All scopes are read-only; attempts to use a write scope are blocked.

## Sub-doc Hooks (Stage 4)

- **Google Cloud project setup sub-doc** — OAuth client IDs, redirect URIs, scope strings, EU consent screen details.
- **Token encryption sub-doc** — exact pgcrypto + Vault wrapping pattern, key rotation, decrypt-at-use.
- **Drive folder mapping sub-doc** — UI for the root-folder picker, parsing 2-week subfolder names, fallback when the convention isn't followed.
- **Refresh strategy sub-doc** — proactive vs reactive refresh, error backoff, circuit breaker.
- **Scope assertion sub-doc** — runtime check, what to do when Google returns extra scopes the user accidentally granted.
