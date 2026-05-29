# Tool: archive.sign

**Block:** 15 — Finalization & Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`archive.sign` applies an RFC 3161 timestamp and a digital signature to an archived document bundle. It requests a timestamp token from the configured Timestamp Authority (TSA), embeds the token in the bundle's manifest file, signs the manifest with either the business's certificate or the platform certificate, and stores all signing artefacts in the S3 Archive zone under the bundle's prefix.

This tool is called during the finalization pipeline after `archive.promote` has placed the bundle in the Archive zone and before `engine.gate_finalization` marks the run FINALIZED. It may also be called manually by a platform administrator to re-sign a bundle (for example, after a certificate rotation).

The tool is idempotent in the sense that re-signing a bundle that already carries a timestamp creates a new timestamp token alongside the existing one. It does not overwrite or invalidate prior signatures; both are retained in the manifest for audit purposes.

---

## Tool identifier

`archive.sign`

## Side effect class

`WRITES_AUDIT`

---

## Input schema

```json
{
  "archive_bundle_id": "uuid — the archive_manifests.id of the bundle to sign, required"
}
```

---

## Output schema

```json
{
  "timestamp_token":         "string — base64-encoded RFC 3161 TimeStampToken",
  "signing_certificate_id":  "uuid — references the certificate used to sign the manifest",
  "signed_at":               "timestamptz — ISO 8601, UTC, moment the TSA token was received",
  "manifest_hash_signed":    "text — SHA-256 hex of the manifest at the moment of signing",
  "prior_signature_count":   "integer — number of existing signatures on this bundle before this call"
}
```

---

## Behaviour

### Step 1 — Load the bundle manifest

Retrieve the `archive_manifests` row for `archive_bundle_id`. Confirm the bundle's `s3_prefix` is reachable and that the manifest file exists at `{s3_prefix}/manifest.json`.

Read `manifest.json` and compute `SHA-256(manifest.json content)` to produce `manifest_hash`. This hash is the message imprint submitted to the TSA.

### Step 2 — Request RFC 3161 timestamp

Submit a `TimeStampRequest` to the configured TSA endpoint:

```
TSA_ENDPOINT = vault.get_secret('tsa_endpoint_url')
TSA_API_KEY  = vault.get_secret('tsa_api_key')       -- nullable; some TSAs use mTLS only

TimeStampRequest:
  version:          1
  messageImprint:   SHA-256(manifest_hash)
  certReq:          true   -- request TSA certificate in response
  nonce:            random 64-bit integer (gen_random_uuid() entropy)
```

The TSA endpoint URL and credentials are stored in Supabase Vault under the keys `tsa_endpoint_url` and `tsa_api_key`. Platform-level defaults are used when the business has not configured its own TSA credentials.

### Step 3 — Validate the TSA response

Verify that:
1. `TimeStampResponse.status.status = GRANTED (0)`
2. The `messageImprint` in the response matches the submitted hash
3. The TSA certificate is within its validity period
4. The `serialNumber` in the token is unique (check against `signing_artefacts` for this bundle)

If any validation step fails, the tool does not write a partial result and proceeds to the failure handling path (see below).

### Step 4 — Resolve signing certificate

If the business has an active certificate in `business_certificates` with `cert_type = 'SIGNING'` and `is_active = true`, use that certificate to sign the manifest.

If no business certificate is available, use the platform certificate identified by `vault.get_secret('platform_signing_cert_id')`.

Record `signing_certificate_id` as the UUID of the resolved certificate row.

### Step 5 — Sign the manifest

Compute the manifest signature:

```
signature = RSA-PSS-SHA256(
  message    = manifest_hash_bytes,
  private_key = resolved_certificate.private_key   -- loaded from Vault, never written to disk
)
```

Append the signature as `signature_hex` to `manifest.json` under a `signatures` array. Each entry in the array includes:

```json
{
  "signed_at":               "ISO 8601 UTC timestamp",
  "signing_certificate_id":  "uuid",
  "timestamp_token":         "base64 RFC 3161 token",
  "manifest_hash_signed":    "SHA-256 hex",
  "signature_hex":           "RSA-PSS-SHA256 hex"
}
```

The manifest is re-uploaded to S3 at the same key (`{s3_prefix}/manifest.json`), overwriting the previous version. S3 Object Lock (COMPLIANCE mode) is applied to each upload version, so prior versions remain retrievable via S3 versioning.

### Step 6 — Update archive_manifests

```sql
UPDATE archive_manifests
SET    timestamp_token         = $timestamp_token,
       signing_certificate_id  = $signing_certificate_id,
       manifest_hash           = $manifest_hash_signed
WHERE  id = $archive_bundle_id;
```

This stores the most recent signature. Prior signatures are accessible only via the S3-versioned `manifest.json`.

### Step 7 — Store signing artefact record

```sql
INSERT INTO signing_artefacts (
  archive_bundle_id, timestamp_token, signing_certificate_id,
  manifest_hash_signed, signed_at, created_at
) VALUES (
  $archive_bundle_id, $timestamp_token, $signing_certificate_id,
  $manifest_hash_signed, $signed_at, now()
);
```

### Step 8 — Emit audit event

Emit `ARCHIVE_DOCUMENT_SIGNED` (severity LOW) with payload:

```json
{
  "archive_bundle_id":      "uuid",
  "signing_certificate_id": "uuid",
  "signed_at":              "ISO 8601",
  "manifest_hash_signed":   "SHA-256 hex",
  "prior_signature_count":  "integer"
}
```

---

## Failure handling

### TSA unavailable

If the TSA endpoint returns a non-2xx HTTP status or is unreachable:

1. Retry up to 3 times with exponential back-off (2 s, 4 s, 8 s).
2. If all 3 retries fail, create a BLOCKING review issue via `review_queue.create_issue` with `issue_type = ARCHIVE_SIGN_TSA_UNAVAILABLE`.
3. Halt finalization: the run stays in AWAITING_APPROVAL status. `engine.gate_finalization` will fail at check (6) until the issue is resolved.

### TSA response invalid

If the TSA response is structurally invalid or the message imprint does not match:

1. Do not write any signing artefact.
2. Create a BLOCKING review issue with `issue_type = ARCHIVE_SIGN_TSA_RESPONSE_INVALID`.
3. Emit `ARCHIVE_DOCUMENT_SIGNED` is NOT emitted in this case; instead emit a separate `ARCHIVE_SIGN_FAILED` event (severity HIGH).

### Certificate not found

If neither a business certificate nor the platform certificate can be resolved, return error `ARCHIVE_SIGN_NO_CERTIFICATE` and open a BLOCKING review issue.

---

## TSA configuration

TSA endpoint configuration is stored in Supabase Vault (never in environment variables or the database in plaintext):

| Vault key | Description |
|---|---|
| `tsa_endpoint_url` | RFC 3161 TSA HTTP endpoint |
| `tsa_api_key` | API key for TSA (nullable if mTLS is used) |
| `tsa_cert_fingerprint` | Expected SHA-256 fingerprint of the TSA's TLS certificate |
| `platform_signing_cert_id` | UUID of the fallback platform signing certificate |

Changes to TSA configuration require a platform-admin step-up (`archive_step_up_policy.md`).

---

## Idempotency

Calling `archive.sign` on a bundle that is already signed does not replace the existing signature. It creates a new entry in the `signatures` array in `manifest.json` and a new row in `signing_artefacts`. The `archive_manifests.timestamp_token` and `signing_certificate_id` columns are updated to reflect the most recent signature. `prior_signature_count` in the output indicates how many signatures existed before this call.

---

## Audit events

| Event | Severity | Condition |
|---|---|---|
| `ARCHIVE_DOCUMENT_SIGNED` | LOW | Signing completed successfully |
| `ARCHIVE_SIGN_FAILED` | HIGH | TSA response invalid or certificate not found |

---

## Called by

- Finalization pipeline — automatically after `archive.promote`
- Platform administrator — manually via admin console (requires step-up auth)

---

## Mobile

`archive.sign` is classified as `WRITES_AUDIT`. Mobile clients may not invoke this tool. Requests with `client_form_factor = MOBILE` are rejected before any S3 or TSA interaction with status `MOBILE_WRITE_REJECTED`. The archive bundle signing status is visible in mobile review screens as a read-only indicator sourced from `archive_manifests.timestamp_token IS NOT NULL`.

---

## Error codes

| Code | Meaning |
|---|---|
| `ARCHIVE_BUNDLE_NOT_FOUND` | `archive_bundle_id` does not exist |
| `ARCHIVE_SIGN_TSA_UNAVAILABLE` | TSA unreachable after 3 retries |
| `ARCHIVE_SIGN_TSA_RESPONSE_INVALID` | TSA response failed validation |
| `ARCHIVE_SIGN_NO_CERTIFICATE` | No signing certificate available |
| `ARCHIVE_SIGN_S3_WRITE_FAILED` | Could not write updated manifest to S3 |
| `ARCHIVE_SIGN_INTERNAL_ERROR` | Unexpected error during signing |

---

## Related Documents

- `tool_archive_promote.md` — prerequisite: promotes bundle to Archive zone before signing
- `tool_archive_verify.md` — post-signing verification tool
- `archive_manifest_schema.md` — DDL for archive_manifests table
- `rfc3161_timestamp_policy.md` — policy governing timestamp authority selection and validation
- `archive_step_up_policy.md` — step-up requirements for archive operations
- `archive_access_control_policy.md` — access control for archive zone
- `secrets_management_policy.md` — Vault key naming conventions
