# Runbook: Bank Feed Reconnect

**Block:** Bank Feed Integration
**Layer:** 2 — Sub-Doc
**Type:** Runbook
**Severity:** MEDIUM (degraded; no data loss unless gap exceeds retention window)
**Status:** Draft

## Overview

This runbook covers the procedure for reconnecting a bank feed that has become disconnected. A disconnected bank feed stops syncing new bank statement lines, causing data gaps. The platform detects disconnections via the `last_sync_status` field on `bank_feed_schema.md` rows and surfaces them as alerts and in-app notifications.

This runbook applies to all supported bank feed providers: Nordigen (GoCardless Open Banking), Salt Edge, and Manual Upload. The reconnection steps differ per provider.

---

## 1. Common Disconnection Causes

| Cause | Affected Providers | Description |
|---|---|---|
| OAuth token expiry | Nordigen, Salt Edge | The OAuth access token issued by the bank has expired. Most bank OAuth tokens are valid for 90 days (some banks: 180 days). |
| Bank API changes | Nordigen, Salt Edge | The bank updated its Open Banking API, invalidating the existing integration. Nordigen/Salt Edge push a provider update; a re-consent may be required. |
| Rate limiting | Nordigen, Salt Edge | The platform exceeded the bank's permitted API call quota. Sync is paused until the quota resets (typically 24 hours). |
| Credential revocation | Nordigen, Salt Edge | The user revoked the bank's authorisation consent via their online banking portal. Full re-consent required. |
| Bank maintenance | Nordigen, Salt Edge | Planned or unplanned bank maintenance window. No action needed; sync resumes automatically when maintenance ends. |
| Manual Upload | N/A | Manual upload feeds do not disconnect; the user simply needs to upload the next statement file. |

To identify the cause, check the `disconnect_reason` field on the `bank_feed_schema.md` row and the most recent error in the integration credential logs (`integration_credential_schema.md`).

---

## 2. Reconnection Steps: Nordigen (GoCardless Open Banking)

Nordigen uses a requisition-based OAuth flow. Reconnection requires creating a new requisition and re-authorising.

**Step 1: Confirm the disconnection cause.**

Navigate to Settings → Bank Feeds → [affected bank account]. The status should show `DISCONNECTED` or `AUTH_EXPIRED`. Check the `disconnect_reason` field.

**Step 2: Initiate re-authorisation.**

Click "Reconnect" on the bank feed settings page. The platform calls the Nordigen API to create a new requisition. The user is redirected to the bank's authorisation screen.

**Step 3: Complete bank authorisation.**

The user logs into their bank's online portal and approves the data sharing consent. The bank redirects back to the platform with an authorisation code.

**Step 4: Platform exchanges the code.**

The platform's Nordigen integration handler exchanges the authorisation code for access and refresh tokens. These are stored encrypted in `integration_credential_schema.md` via Vault.

**Step 5: Verify connection.**

The platform triggers a test sync. Check that `last_sync_status = 'SUCCESS'` on the `bank_feed` row. If the test sync fails, check the integration credential logs for error detail.

**Step 6: Backfill (if data gap exists).**

If the disconnection caused a sync gap, trigger a backfill. See Section 5.

---

## 3. Reconnection Steps: Salt Edge

Salt Edge uses a connection-based consent flow with explicit re-consent requirements for certain banks.

**Step 1: Confirm the disconnection cause.**

Navigate to Settings → Bank Feeds → [affected bank account]. Review `disconnect_reason` and the Salt Edge connection status.

**Step 2: Attempt token refresh.**

For expired tokens (not revoked consent), the platform can attempt a silent token refresh via the Salt Edge API. This requires no user interaction. Trigger via: Settings → Bank Feeds → "Refresh Token".

If the refresh succeeds, verify with a test sync. If the refresh fails (consent revoked, refresh token also expired), proceed to Step 3.

**Step 3: Re-consent flow.**

Click "Reconnect" to initiate the Salt Edge re-consent flow. The user is redirected to the Salt Edge widget, which proxies the bank authorisation. The user re-enters their bank credentials in the Salt Edge widget (credentials are handled by Salt Edge, never seen by the platform).

**Step 4: Complete re-consent.**

After the user completes the widget, Salt Edge returns a new connection object. The platform stores the updated credentials in `integration_credential_schema.md`.

**Step 5: Verify connection.**

Trigger a test sync. Confirm `last_sync_status = 'SUCCESS'`. If the test sync returns an error, retrieve the Salt Edge connection status from the Salt Edge API directly to identify any provider-side issue.

**Step 6: Backfill (if data gap exists).**

See Section 5.

---

## 4. Manual Upload: No Reconnection Needed

Manual Upload bank feeds do not use OAuth and cannot "disconnect" in the technical sense. If a business has a manual upload feed and the latest statement is missing, the user simply needs to upload the next OFX, CSV, or MT940 file.

Navigate to: Bank Feeds → [account] → Upload Statement. Follow the intake format rules in `intake_format_policy.md`.

If the business wants to transition from manual upload to a live integration (Nordigen or Salt Edge), this is a feed migration, not a reconnection. Follow the bank feed setup procedure in `bank_statement_live_integration_runbook.md`.

---

## 5. Handling Data Gaps After Reconnection

If the disconnection caused a missed sync window (bank statements that should have been imported were not), trigger a backfill:

**Step 1: Identify the gap.**

Check the `last_successful_sync_at` field on the `bank_feed` row. Compare against the current date. The gap period is `last_successful_sync_at` to now.

**Step 2: Trigger backfill.**

Via the platform admin interface or the backfill API endpoint:

```
POST /api/bank-feeds/{bank_feed_id}/backfill
{
  "from_date": "<last_successful_sync_at date>",
  "to_date": "<today>"
}
```

The backfill request triggers a historical transaction fetch from the provider for the specified date range. Nordigen supports up to 90 days of history; Salt Edge supports up to 365 days (bank-dependent).

**Step 3: Monitor backfill progress.**

The backfill runs asynchronously. Monitor the `bank_feed_schema.md` `sync_status` field. A successful backfill sets `last_sync_status = 'SUCCESS'` and updates `last_successful_sync_at`.

**Step 4: Review imported lines.**

After backfill, review the newly imported lines in the bank statement review interface. Look for duplicates (the deduplication pipeline runs automatically, but manual review is recommended after a gap). Any `DUPLICATE_PROBABLE` flags should be resolved before the next workflow run.

**Step 5: Check open workflow runs.**

If a workflow run was started during the gap period, check whether the backfilled transactions affect the run's scope. A reviewer may need to re-trigger the IN or OUT filter to include the newly available lines.

---

## 6. Escalation: If Reconnection Fails

If all reconnection steps have been followed and the bank feed remains disconnected:

**Option A: Contact the provider.**
- Nordigen: submit a support ticket via the Nordigen dashboard. Include the requisition ID from `integration_credential_schema.md`.
- Salt Edge: submit a support ticket via the Salt Edge dashboard. Include the connection ID.

**Option B: Fallback to manual upload.**

While the live integration is being resolved, the business can continue operations using manual OFX/CSV/MT940 uploads. This is always available regardless of live integration status.

To switch to manual upload temporarily:
1. Navigate to Bank Feeds → [account] → Settings.
2. Set `fallback_to_manual = true`.
3. Upload statements manually per `intake_format_policy.md`.

The live integration reconnection can proceed in parallel without affecting manual uploads.

**Option C: Escalate to platform support.**

If the provider is unresponsive or the integration is broken at the platform level (not the bank level), escalate to the platform engineering team with the `bank_feed_id`, `integration_credential_id`, and the full error log.

---

## 7. Verification Checklist

After completing reconnection, confirm all of the following:

- `bank_feed.last_sync_status = 'SUCCESS'`
- `bank_feed.last_successful_sync_at` is within the last 24 hours (or within the expected sync interval)
- `bank_feed.disconnect_reason` is NULL (cleared on successful reconnect)
- A test sync has been triggered and completed without error
- The bank account balance shown in the platform matches the balance from the bank's own portal
- Any data gap has been backfilled and reviewed

---

## Related Documents

- `bank_feed_schema.md` — DDL and status fields for bank feed connections
- `bank_statement_live_integration_runbook.md` — initial setup of live bank integrations
- `integration_credential_schema.md` — stored OAuth tokens and connection credentials
- `integration_credential_rotation_policy.md` — token rotation policy
- `intake_format_policy.md` — accepted file formats for manual upload fallback
- `bank_statement_import_failure_runbook.md` — troubleshooting import failures after reconnection
- `oauth_policy.md` — OAuth token lifecycle policy
- `oauth_token_encryption_schema.md` — encryption of stored tokens
