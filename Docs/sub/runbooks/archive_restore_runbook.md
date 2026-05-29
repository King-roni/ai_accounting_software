# Archive Restore Runbook

**Block:** archive / security  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This runbook covers the procedure for restoring an archived document from S3 Object Lock storage. Restoration is required when a document is needed for a tax audit, legal request, regulatory inspection, or internal dispute resolution. All restoration activity generates a full audit trail. No document may be accessed without authorisation, and the process includes integrity verification before any download links are issued.

This runbook applies to: archived finalization bundles, individual transaction documents, invoice PDFs, VAT return records, and any document stored under the platform's S3 Object Lock-protected archive prefixes.

---

## Prerequisites

- Requester has ADMIN or ACCOUNTANT role on the business entity.
- Step-up MFA is available and enrolled (see `step_up_ui_spec.md`).
- The document's retention period has not expired (Object Lock `retain_until` date is in the future, or a Legal Hold is active).
- The `archive_manifests` table has a record for the target period or run.

---

## Step 1: Authorise the Restore

### Who can authorise

| Role | Authorised for |
|---|---|
| ADMIN | Any document for their business |
| ACCOUNTANT | Documents they are assigned to via `accountant_assignments` |
| PLATFORM_SUPPORT | Cross-tenant restore (requires internal approval ticket; out of scope for this runbook) |

### Step-up MFA requirement

Before any archive restore can proceed, the requesting user must complete a step-up MFA challenge. This is enforced server-side by the `archive.restore_authorise` tool, which rejects requests without a valid step-up session token.

Step-up flow: user clicks "Request Archive Access" button → step-up challenge modal appears → user enters TOTP code → step-up session token issued (10-minute expiry, single-use) → token included in all subsequent restore API calls.

### Audit logging

Immediately upon authorisation (step-up completed, before any document is located), the system emits:
- `ARCHIVE_RESTORE_REQUESTED` audit event with fields: `requester_user_id`, `requester_role`, `business_id`, `request_reason` (free text entered by requester), `request_timestamp`.

The `request_reason` field is required. Acceptable reasons: `TAX_AUDIT`, `LEGAL_REQUEST`, `INTERNAL_REVIEW`, `REGULATORY_INSPECTION`, `DISPUTE_RESOLUTION`. Free-text supplementary detail can be added.

If the requester cannot complete step-up MFA (e.g., authenticator app lost), they must follow `mfa_lockout_runbook.md` to regain access before proceeding.

---

## Step 2: Locate the Archive

### Query archive_manifests

```sql
SELECT
  am.id,
  am.run_id,
  am.period_id,
  am.s3_prefix,
  am.manifest_hash,
  am.created_at,
  am.object_lock_retain_until,
  am.legal_hold_active
FROM archive_manifests am
WHERE am.business_id = '{business_id}'
  AND (am.run_id = '{run_id}' OR am.period_id = '{period_id}')
ORDER BY am.created_at DESC;
```

If no manifest is found:
- The run or period may not have been archived yet (only FINALIZED runs are archived).
- Check `runs.archive_status` field. If `archive_status = PENDING`, the archive job has not run yet.
- Escalate to `archive_promotion_failure_runbook.md` if the run is FINALIZED but `archive_status` is not COMPLETE.

### Verify Object Lock status

For each manifest retrieved, confirm:

1. `object_lock_retain_until` is in the future **OR** `legal_hold_active = true`. If both are false and `retain_until` is in the past, the object may have been deleted per the retention policy. Check S3 directly.
2. If `legal_hold_active = true`: document is under a legal hold and **cannot be deleted**. Restoration is always permitted regardless of `retain_until`.
3. Log the Object Lock status in the audit trail as part of the restore record.

### S3 Glacier note

If the S3 storage class has transitioned to Glacier or Glacier Deep Archive (visible via the S3 Object metadata or the `archive_manifests.storage_class` field):

- An S3 Glacier restore initiation is required before pre-signed URLs can be generated.
- Call `archive.initiate_glacier_restore({ s3_prefix, restore_days: 3 })`.
- Glacier restore for Standard tier takes 3–5 hours. Deep Archive takes 12–48 hours.
- The system will notify the requester via email when the restore is complete and Step 3 can proceed.
- Do not proceed to Step 3 until `archive_manifests.glacier_restore_status = AVAILABLE`.

---

## Step 3: Initiate Restore

### Integrity check (mandatory before any download)

Before generating any download links, call:

```
archive.verify({ manifest_id })
```

This tool:
1. Retrieves each file listed in the archive manifest.
2. Computes a SHA-256 hash of each file's current content.
3. Compares against `manifest.file_hashes` stored at the time of archival.
4. Compares the manifest itself against `archive_manifests.manifest_hash` (a hash of the manifest file content stored in S3).
5. If all hashes match: returns `{ integrity_status: "VERIFIED" }`.
6. If any hash mismatch: returns `{ integrity_status: "TAMPERED", mismatched_files: [...] }` and emits a `ARCHIVE_INTEGRITY_FAILURE` audit event (HIGH). **Stop. Do not proceed. Escalate to `tamper_detection_forensic_runbook.md`.**

### RFC 3161 timestamp verification (for legal contexts)

If the restore is for a legal or regulatory purpose, also call:

```
archive.verify_timestamp({ manifest_id })
```

This verifies the RFC 3161 timestamp token stored with the archive bundle against the TSA public key. A successful verification provides cryptographic proof of when the document existed, suitable for legal proceedings. See `rfc_3161_timestamp_integration.md` for details.

### Generate pre-signed URLs

After `VERIFIED` integrity status confirmed, generate signed S3 URLs for each document in the manifest:

```
archive.generate_download_urls({
  manifest_id,
  step_up_token,
  expiry_seconds: 3600,
  requester_user_id
})
```

This returns an array of `{ document_name, download_url, expires_at }` objects. Each URL:
- Is a pre-signed S3 GET URL valid for 1 hour (3600 seconds).
- Is scoped to the specific object; no prefix-level access is granted.
- Carries the requester's identity in the S3 request metadata for CloudTrail logging.

URLs are returned to the requester only; they are not stored in the database. Each URL generation is logged.

---

## Step 4: Deliver and Log

### Delivery to requester

Download links are presented in the platform UI under the restore request record (accessible at `/archive/restores/{restore_request_id}`). The page lists each document with its name, size, and the download link.

Optionally, links can be sent via email to the requesting user (system alert email category). This is opt-in; a checkbox on the restore request page enables it.

### Per-download audit logging

Each time a download link is clicked and the file is retrieved from S3, Resend (or the CloudFront CDN if configured) triggers a callback that logs:

```
ARCHIVE_DOCUMENT_ACCESSED audit event:
  severity: LOW
  fields: {
    manifest_id,
    document_name,
    requester_user_id,
    download_timestamp,
    restore_request_id,
    ip_address (if available via CloudFront)
  }
```

If a URL is generated but never accessed within its expiry window, a `ARCHIVE_URL_EXPIRED_UNUSED` event (LOW) is emitted when the expiry passes.

### Multiple documents in one manifest

If a manifest contains many files (e.g., a full finalization bundle with 50+ documents), the restore UI groups files by type: Invoices, Bank Statements, VAT Records, Ledger Exports, Accountant Pack. Each group can be downloaded individually or as a ZIP.

ZIP generation is handled by the `archive.package_restore` edge function and is streamed directly to the browser; the ZIP is not persisted to S3.

---

## Step 5: Post-Restore Procedures

### Confirm receipt

After the requester has downloaded all required documents, they mark the restore request as complete in the platform: Restore Request → "Mark as Completed." This sets `restore_requests.status = COMPLETED` and emits `ARCHIVE_RESTORE_COMPLETED` (LOW).

If the requester does not mark complete within 7 days, the system auto-marks as COMPLETED and emits the same event.

### Regulatory audit delivery

If the restore was initiated for a regulatory or tax audit (`request_reason = TAX_AUDIT` or `REGULATORY_INSPECTION`), proceed to prepare an Accountant Pack for inspector delivery:

1. Follow the `accountant_pack_tamper_runbook.md` procedure to prepare a tamper-evident package.
2. The Accountant Pack includes: all archived documents, the RFC 3161 timestamp verification report, the integrity verification report, and the audit event log for the relevant period.
3. Deliver to the inspector via the method they specified (secure email, CD-ROM, or physical print depending on Cyprus tax authority requirements).

### Legal hold flag

If the restore was initiated for a legal request, and the associated document does not already have a legal hold, the accountant or ADMIN should enable one to prevent deletion until the legal matter is resolved:

```
archive.set_legal_hold({
  manifest_id,
  legal_hold_active: true,
  reason: "Legal request ref: {reference}",
  set_by_user_id
})
```

This calls the S3 Object Lock API to enable the legal hold on all objects in the manifest's S3 prefix. The `archive_manifests.legal_hold_active` flag is updated accordingly.

To remove a legal hold once the matter is resolved, the same function is called with `legal_hold_active: false`. Legal hold removal requires ADMIN role and step-up MFA.

### Audit trail requirements

The complete audit trail for a restore event must be preserved for a minimum of 7 years (Cyprus tax record retention requirements). The following events must be present in sequence:

1. `ARCHIVE_RESTORE_REQUESTED`
2. `ARCHIVE_INTEGRITY_VERIFIED` (or `ARCHIVE_INTEGRITY_FAILURE` if tampered)
3. `ARCHIVE_DOCUMENT_ACCESSED` (one per document downloaded)
4. `ARCHIVE_RESTORE_COMPLETED`

If this sequence is incomplete (e.g., system failure during restore), a manual audit note must be added to the restore request record documenting what was accessed and when.

---

## Expected Audit Events Summary

| Event | Severity | Step |
|---|---|---|
| `ARCHIVE_RESTORE_REQUESTED` | MEDIUM | Step 1 |
| `ARCHIVE_INTEGRITY_VERIFIED` | LOW | Step 3 |
| `ARCHIVE_INTEGRITY_FAILURE` | HIGH | Step 3 — tamper detected |
| `ARCHIVE_DOCUMENT_ACCESSED` | LOW | Step 4 — per document |
| `ARCHIVE_URL_EXPIRED_UNUSED` | LOW | Step 4 — URL expiry |
| `ARCHIVE_RESTORE_COMPLETED` | LOW | Step 5 |
| `ARCHIVE_LEGAL_HOLD_SET` | MEDIUM | Step 5 — if legal hold enabled |
| `ARCHIVE_LEGAL_HOLD_REMOVED` | MEDIUM | Step 5 — if legal hold removed |

---

## Related Documents

- `archive_promotion_failure_runbook.md`
- `accountant_pack_tamper_runbook.md`
- `tamper_detection_forensic_runbook.md`
- `rfc_3161_timestamp_integration.md`
- `object_lock_integration.md`
- `archive_bundle_file_manifest.md`
- `mfa_lockout_runbook.md`
- `step_up_ui_spec.md`
- `audit_event_taxonomy.md`
