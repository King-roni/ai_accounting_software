# Tool: archive.restore_document

**Namespace:** archive
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** Yes
**Idempotent:** Yes
**Mobile:** No

## Overview

`archive.restore_document` retrieves a document from the archive zone for legitimate legal, tax audit, or compliance purposes. The tool does not move, copy, or delete the document — it generates a signed temporary download URL with a 30-minute TTL and records the retrieval in both the audit log and the `archive_access_log` table.

Documents in the archive zone are immutable. This tool is a read-only access mechanism; it has no write path to the document data. The archive zone is a permanent, append-only storage area per `policies/archive_integrity_policy.md`.

---

## Tool Name

`archive.restore_document`

---

## Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| document_id | UUID | Yes | The ID of the archived document to retrieve. |
| requested_by | UUID | Yes | The `org_member_id` of the person requesting access. |
| purpose | TEXT | Yes | Documented reason for retrieval. Minimum 20 characters. |

### Parameter Notes

- `document_id` — references `document_archives.id`. The document must exist and belong to the caller's business.
- `requested_by` — the org member performing the retrieval. Must match the authenticated caller's `org_member_id`. Used for the audit trail and access log.
- `purpose` — a mandatory documented reason for the retrieval, required for compliance. Examples: `"Tax Authority audit request — Cyprus VAT inspection 2025"`, `"Client dispute — invoice copy requested by legal counsel"`. The minimum 20-character requirement is enforced by the server. This reason appears in the `archive_access_log` and in the `ARCHIVE_DOCUMENT_RESTORED` audit event.

---

## Outputs

```json
{
  "document_id": "<uuid>",
  "filename": "<original filename>",
  "content_type": "<MIME type>",
  "download_url": "<signed URL>",
  "url_expires_at": "<timestamptz — 30 minutes from now>",
  "access_log_id": "<uuid of archive_access_log row>",
  "chain_integrity": "VERIFIED | UNVERIFIED",
  "chain_position": "<bigint>"
}
```

- `chain_integrity` — `VERIFIED` if the hash chain entry for this document was successfully verified at call time. `UNVERIFIED` if the chain check was skipped due to a transient error; the access is still permitted but the caller is notified. A chain integrity failure (`BROKEN`) blocks the retrieval and returns an error.
- `download_url` — a signed Supabase Storage URL valid for 30 minutes. The URL is single-use in production environments. After 30 minutes the URL expires and a new retrieval call is required.

---

## Preconditions

All preconditions are evaluated before any write. Failure in any precondition returns an error and makes no state change.

**PC-1: Document exists.** The `document_id` must match an existing `document_archives` row visible to the caller's business.

**PC-2: Caller has `archive:read` permission.** The `requested_by` org member must hold the `archive:read` permission. This permission is granted to ADMIN and OWNER roles by default and is not available to standard ACCOUNTANT or VIEWER roles without an explicit grant.

**PC-3: Step-up authentication.** The caller must have a valid step-up token (per `tools/tool_step_up_request.md`). Archive access is classified as a high-privilege action per `policies/archive_step_up_policy.md`. The step-up token must have been issued within the last 15 minutes.

**PC-4: Chain integrity not broken.** The hash chain entry for the document's associated archive event must be intact. A broken chain returns `CHAIN_INTEGRITY_FAILURE` and blocks the retrieval. The caller must contact the platform team before proceeding.

**PC-5: Purpose meets minimum length.** The `purpose` must be non-null, non-whitespace, and at least 20 characters.

---

## Steps

1. Validate `document_id` exists and is visible to caller (RLS enforced).
2. Check `requested_by` holds `archive:read` permission (PC-2).
3. Verify step-up token is valid and within the 15-minute window (PC-3).
4. Verify chain integrity for the document's associated hash chain entry (PC-4). If chain is `VERIFIED`, set `chain_integrity = 'VERIFIED'`. If check is inconclusive due to a transient error, set `chain_integrity = 'UNVERIFIED'` and continue. If chain is `BROKEN`, return `CHAIN_INTEGRITY_FAILURE` error and halt.
5. Validate `purpose` length (PC-5).
6. Generate a signed Supabase Storage URL for the document with a 30-minute TTL.
7. Insert a row into `archive_access_log`: `document_id`, `accessed_by = $requested_by`, `purpose`, `access_type = 'RESTORE'`, `url_expires_at`, `accessed_at = now()`.
8. Emit `ARCHIVE_DOCUMENT_RESTORED` audit event (see Audit Events section). Note: the current taxonomy uses `ARCHIVE_DOCUMENT_ACCESSED` for document retrievals. A distinct `ARCHIVE_DOCUMENT_RESTORED` event should be added to the taxonomy to differentiate formal restore operations from general access. Until that addition is made, emit `ARCHIVE_DOCUMENT_ACCESSED` with `access_type = 'RESTORE'` in the payload.
9. Return the signed URL and access log ID to the caller.

---

## Idempotency

This tool is idempotent in the following sense: calling it multiple times with the same `document_id`, `requested_by`, and `purpose` will generate a new signed URL each time. Each call creates a new `archive_access_log` row and emits a new audit event — this is intentional, as each access is a separate retrievable event for compliance purposes. No deduplication is applied.

---

## Audit Events

| Event | Severity | Payload |
|---|---|---|
| `ARCHIVE_DOCUMENT_ACCESSED` (pending rename to `ARCHIVE_DOCUMENT_RESTORED`) | LOW | `document_id`, `accessed_by`, `purpose` (truncated to 500 chars), `access_type: 'RESTORE'`, `chain_integrity`, `chain_position`, `business_entity_id`, `accessed_at` |

Note for taxonomy maintainers: add `ARCHIVE_DOCUMENT_RESTORED` to the ARCHIVE domain in `reference/audit_event_taxonomy.md`. This event should be LOW severity. Until added, use `ARCHIVE_DOCUMENT_ACCESSED` with `access_type = 'RESTORE'` as noted above.

---

## Error Codes

| Code | HTTP Status | Condition |
|---|---|---|
| `NOT_FOUND` | 404 | `document_id` does not exist or is not visible to caller |
| `INSUFFICIENT_PERMISSION` | 403 | `requested_by` does not hold `archive:read` |
| `STEP_UP_REQUIRED` | 403 | No valid step-up token; caller must authenticate via step-up flow |
| `STEP_UP_EXPIRED` | 403 | Step-up token is older than 15 minutes |
| `CHAIN_INTEGRITY_FAILURE` | 409 | Hash chain verification returned BROKEN for this document |
| `PURPOSE_TOO_SHORT` | 422 | `purpose` is fewer than 20 characters |
| `PURPOSE_EMPTY` | 422 | `purpose` is null or whitespace-only |
| `UNAUTHORIZED` | 401 | Caller is not authenticated |
| `FORBIDDEN` | 403 | Caller is not an active member of the business |
| `URL_GENERATION_FAILED` | 500 | Supabase Storage signed URL generation failed |

---

## Database Operations

All writes execute in a single transaction:

1. Read and lock `document_archives` row (read-only lock; no modification).
2. Evaluate preconditions.
3. Call Supabase Storage `createSignedUrl` (outside transaction, before commit).
4. Insert `archive_access_log` row.
5. Insert `ARCHIVE_DOCUMENT_ACCESSED` audit log row via `emit_audit_api.md`.
6. Commit.

If the Storage URL generation fails (step 3), the transaction is not committed and no access log entry is written.

---

## Mobile

This tool requires `archive:read` permission and step-up authentication, both of which impose constraints on mobile use.

**Online requirement:** Archive retrieval must occur with an active network connection. Signed URLs cannot be cached or pre-fetched.

**Step-up authentication on mobile:** The mobile client must initiate the step-up flow via `tool_step_up_request.md` before calling this tool. The step-up token is valid for 15 minutes. If the mobile session is locked or backgrounded during this window, the caller may need to re-authenticate.

**Download behaviour:** The signed URL returned by this tool should be opened via the mobile client's secure document viewer. The URL must not be stored in an unencrypted local cache. The 30-minute TTL is enforced server-side; the client should display a countdown and prompt the user to request a new URL if the TTL expires before download completes.

**No offline access:** Archive documents may not be downloaded for offline viewing. The client must not persist the signed URL beyond the active session.

---

## Related Documents

- `policies/archive_integrity_policy.md` — Archive immutability and integrity model
- `policies/archive_access_control_policy.md` — Who may access archive documents
- `policies/archive_step_up_policy.md` — Step-up authentication requirements for archive access
- `schemas/archive_schema.md` — Document archives table DDL
- `schemas/hash_chain_entry_schema.md` — Hash chain entries (chain verification in step 4)
- `tools/tool_archive_verify.md` — Full chain integrity verification tool
- `tools/tool_archive_promote.md` — Document promotion to archive zone
- `tools/tool_step_up_request.md` — Step-up authentication request tool
- `tools/emit_audit_api.md` — Audit emission API
- `reference/audit_event_taxonomy.md` — ARCHIVE domain events
