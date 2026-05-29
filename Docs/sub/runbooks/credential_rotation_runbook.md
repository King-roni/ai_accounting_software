# Credential Rotation Runbook

**Namespace:** security  
**Block:** 02 — Tenancy & Access  
**Category:** Runbooks  
**Stage:** 4 sub-doc (Layer 2)

---

## Overview

This runbook covers the step-by-step procedure for rotating an integration credential manually or when automated rotation has failed. Follow the appropriate integration-type section. Complete all verification steps before marking the rotation done.

Policy context: `policies/integration_credential_rotation_policy.md`. Schema reference: `schemas/integration_credential_schema.md`.

---

## Prerequisites

Before starting any rotation:

1. **Confirm the credential row exists and is active.**
   ```sql
   SELECT id, integration_type, credential_ref, expires_at, revoked_at, created_at
   FROM integration_credentials
   WHERE business_entity_id = '<business_entity_id>'
     AND integration_type = '<TYPE>'
     AND revoked_at IS NULL;
   ```
   Expected: exactly one row. If zero rows exist, there is nothing to rotate. If two or more rows exist, a prior rotation may have stalled — resolve the overlap before proceeding (see section 7).

2. **Confirm Vault access.** You must have a Vault token with write access to the `secret/data/be/<business_entity_id>/` path. Verify:
   ```bash
   vault kv get secret/data/be/<business_entity_id>/<integration_type_lower>/current
   ```
   Expected: current secret metadata. If Vault is unreachable, stop and resolve the infrastructure issue first.

3. **Record the old credential row ID.** Store it as `OLD_CRED_ID` for rollback.

4. **Confirm no active workflow runs are mid-phase for this business.** Check:
   ```sql
   SELECT workflow_run_id, status, current_phase_name FROM workflow_runs
   WHERE business_entity_id = '<business_entity_id>'
     AND status IN ('RUNNING', 'REVIEW_HOLD', 'AWAITING_APPROVAL', 'FINALIZING');
   ```
   If any runs are active in a phase that uses the integration being rotated, wait for the phase to complete or pause the run first. PAUSED status is safe.

---

## Section A — Bank Feed (BANK_FEED)

Bank feed credentials are issued by the bank aggregator (Salt Edge / Nordigen or direct bank API).

**Step 1 — Issue new API key from the aggregator dashboard or API.**
```bash
# Example for Nordigen: create a new access token
curl -X POST https://ob.nordigen.com/api/v2/token/new/ \
  -H "Content-Type: application/json" \
  -d '{"secret_id": "<nordigen_secret_id>", "secret_key": "<nordigen_secret_key>"}'
# Note the access token returned. This is the new credential.
```

**Step 2 — Write new credential to Vault.**
```bash
NEW_VERSION=$(date +%Y%m%d%H%M%S)
vault kv put secret/data/be/<business_entity_id>/bank_feed/${NEW_VERSION} \
  token="<new_access_token>" \
  provider="nordigen" \
  issued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NEW_VAULT_PATH="secret/data/be/<business_entity_id>/bank_feed/${NEW_VERSION}"
```

**Step 3 — Insert new integration_credentials row.**
```sql
INSERT INTO integration_credentials (
    id, business_entity_id, integration_type, credential_ref, scopes, expires_at, created_by
) VALUES (
    gen_uuid_v7(),
    '<business_entity_id>',
    'BANK_FEED',
    '<NEW_VAULT_PATH>',
    ARRAY[]::text[],
    now() + interval '90 days',
    '<rotation_actor_org_member_id>'
)
RETURNING id;
-- Save returned ID as NEW_CRED_ID
```

**Step 4 — Test connectivity.**
```bash
# Call the bank feed sync tool with the new credential
# The tool resolver will pick up the new row (ORDER BY created_at DESC)
curl -X POST https://<api_host>/tools/bank_feed.test_connection \
  -H "Authorization: Bearer <service_token>" \
  -d '{"business_entity_id": "<business_entity_id>"}'
# Expected: {"status": "ok", "provider": "nordigen", "account_count": N}
```
If the response is not `"status": "ok"`, go to section 6 (Rollback).

**Step 5 — Revoke old credential.**
```sql
UPDATE integration_credentials
SET revoked_at = now(), updated_at = now()
WHERE id = '<OLD_CRED_ID>';
```
Then revoke at the provider:
```bash
# Nordigen: delete the old token at the provider (consult provider docs for the specific endpoint)
vault kv metadata delete secret/data/be/<business_entity_id>/bank_feed/<OLD_VERSION>
# Set a 1-hour soft TTL on the old Vault path to allow in-flight requests to drain
```

**Step 6 — Verify.**
```sql
SELECT id, credential_ref, revoked_at FROM integration_credentials
WHERE business_entity_id = '<business_entity_id>' AND integration_type = 'BANK_FEED'
ORDER BY created_at DESC LIMIT 2;
-- Expected: new row has revoked_at IS NULL, old row has revoked_at SET
```

---

## Section B — Stripe Connect (STRIPE_CONNECT)

Stripe Connect credentials are OAuth tokens issued per connected account.

**Step 1 — Initiate OAuth re-authorization.**

Stripe Connect tokens are rotated by completing a new OAuth flow. Generate a new authorization URL via the Stripe platform dashboard or API:
```bash
# Generate state token and store it in oauth_states table first
# Then present the authorization URL to the business owner (requires user action)
```
Note: STRIPE_CONNECT rotation requires a user action (owner must approve the new OAuth grant). This runbook covers the system-side steps; user notification is handled by the rotation worker.

**Step 2 — After OAuth callback, write new token to Vault.**
```bash
NEW_VERSION=$(date +%Y%m%d%H%M%S)
vault kv put secret/data/be/<business_entity_id>/stripe_connect/${NEW_VERSION} \
  access_token="<new_access_token>" \
  refresh_token="<new_refresh_token>" \
  stripe_user_id="<acct_xxx>" \
  token_type="bearer"
```

**Step 3 — Insert new row, test, revoke old row.** Follow steps 3–6 from Section A, substituting `STRIPE_CONNECT` for `BANK_FEED` and the appropriate Stripe API endpoint for the connectivity test:
```bash
# Stripe connectivity test: retrieve the connected account
curl https://api.stripe.com/v1/account \
  -H "Authorization: Bearer <new_access_token_from_vault>"
# Expected HTTP 200 with account object
```

---

## Section C — SMTP Relay (SMTP_RELAY)

SMTP credentials are username/password pairs for the outbound email relay (SendGrid, Postmark, or self-hosted). SMTP credentials cannot be programmatically rotated via API on all providers; manual issuance in the relay dashboard is required.

**Step 1 — Generate new credentials.** SendGrid: API Keys → Create with "Mail Send" permission. Postmark: Server API Tokens → rotate.

**Step 2 — Write to Vault.** Follow the same `vault kv put` pattern as Section A, using path `secret/data/be/<business_entity_id>/smtp_relay/${NEW_VERSION}` with keys `username`, `password`, `host`, `port`.

**Step 3 — Insert new row.** Set `expires_at = now() + interval '180 days'`.

**Step 4 — Test connectivity.** Call `smtp.test_connection` tool. Expected: `{"status": "ok"}`. If not ok, go to section 6.

**Step 5 — Revoke old row.** Unlike BANK_FEED, revoke at the provider before setting `revoked_at`. SMTP providers typically invalidate the old key synchronously on revocation.

---

## 5. Verification Steps (All Integration Types)

After completing any rotation:

1. Confirm exactly one active (`revoked_at IS NULL`) row exists for the `(business_entity_id, integration_type)` pair.
2. Confirm the `credential_ref` on the active row points to the new Vault path.
3. Confirm the old row has `revoked_at` set.
4. Confirm the audit log contains an `INTEGRATION_CREDENTIAL_ROTATED` event for this business and integration type within the last 5 minutes.
5. Run a live integration smoke test (bank feed fetch, Stripe account check, or SMTP send) using the application's normal code path — not a direct Vault read.

---

## 6. Rollback

If Step 4 connectivity test fails, delete the new unverified row and destroy the new Vault secret:

```sql
DELETE FROM integration_credentials WHERE id = '<NEW_CRED_ID>';
```
```bash
vault kv destroy -versions=<new_version_number> secret/data/be/<business_entity_id>/<type>/<NEW_VERSION>
```

Confirm the old row is still active (`revoked_at IS NULL`). Log the failure. The rotation scheduler retries in 1 hour; after 3 consecutive failures, severity escalates to HIGH.

---

## 7. Resolving a Stalled Rotation (Two Active Rows)

If a prior rotation left two rows with `revoked_at IS NULL`, query both rows and test each credential against the provider. Revoke the invalid one (or the older one if both are valid). If neither is valid, treat as a credential loss incident and initiate a full re-issue from Step 1. Query to identify both rows:

```sql
SELECT id, credential_ref, created_at FROM integration_credentials
WHERE business_entity_id = '<business_entity_id>'
  AND integration_type = '<TYPE>' AND revoked_at IS NULL
ORDER BY created_at;
```

---

## Related Documents

- `policies/integration_credential_rotation_policy.md` — policy governing rotation triggers and procedures
- `schemas/integration_credential_schema.md` — table definition and column notes
- `policies/secrets_management_policy.md` — Vault architecture
- `runbooks/data_breach_response_runbook.md` — compromise-detected escalation path
- `reference/audit_event_taxonomy.md` — INTEGRATION_CREDENTIAL_ROTATED event definition (pending)
- `schemas/oauth_state_schema.md` — OAuth state table used in Stripe Connect rotation
