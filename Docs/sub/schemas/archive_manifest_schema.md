# archive_manifest_schema

**Block:** 15 — Finalization & Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `archive_manifests` table records the metadata for each finalized document bundle that has been promoted to the permanent Archive zone in S3. Each row describes one bundle: where it lives in S3, how many files it contains, its integrity hash, its RFC 3161 timestamp token, and the Object Lock retention parameters that enforce the 7-year mandatory retention period under Cyprus accounting regulations.

A bundle is created by `archive.promote` and signed by `archive.sign`. Once promoted, the bundle is immutable: its S3 objects are under Object Lock COMPLIANCE mode and cannot be deleted or modified until `object_lock_retain_until`. The manifest row itself is append-only after `promoted_at` is set; only the `timestamp_token` and `signing_certificate_id` columns may be updated (by `archive.sign`).

---

## Table definition

```sql
CREATE TABLE archive_manifests (
  id                        uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  run_id                    uuid          NOT NULL REFERENCES workflow_runs(id),
  business_id               uuid          NOT NULL REFERENCES business_entities(id),
  period_id                 uuid          NOT NULL REFERENCES vat_periods(id),
  manifest_version          integer       NOT NULL DEFAULT 1,
  file_count                integer       NOT NULL CHECK (file_count > 0),
  total_size_bytes          bigint        NOT NULL CHECK (total_size_bytes > 0),
  s3_prefix                 text          NOT NULL,           -- e.g. archive/{business_id}/{period_id}/{run_id}/
  manifest_hash             text          NOT NULL,           -- SHA-256 of all individual file hashes concatenated in deterministic order
  timestamp_token           text,                            -- base64-encoded RFC 3161 TimeStampToken; null until archive.sign completes
  signing_certificate_id    uuid,                            -- FK to signing_certificates; null until archive.sign completes
  object_lock_mode          text          NOT NULL DEFAULT 'COMPLIANCE'
                                          CHECK (object_lock_mode = 'COMPLIANCE'),
  object_lock_retain_until  date          NOT NULL,           -- created_at::date + 7 years
  promoted_at               timestamptz,                     -- null until archive.promote succeeds
  promoted_by               text          NOT NULL DEFAULT 'SYSTEM',
  created_at                timestamptz   NOT NULL DEFAULT now()
);
```

---

## Column notes

- `id` — UUID v7 per `data_layer_conventions_policy §2`.
- `run_id` — FK to `workflow_runs(id)`. Exactly one archive manifest is created per finalized run. A UNIQUE constraint on `run_id` is not applied because amendment runs for the same period may produce a second manifest; the combination `(run_id)` alone is not unique, but `(run_id, manifest_version)` is.
- `business_id` — FK to `business_entities(id)`. Non-nullable; used by RLS policies and for S3 prefix construction. `REFERENCES business_entities(id)` per standing rules.
- `period_id` — FK to `vat_periods(id)`. Identifies the accounting period this bundle covers. Used for period-level archive lookups.
- `manifest_version` — integer starting at 1. Incremented when a bundle is superseded by an amendment run. Amendment bundles for the same period under a new run get `manifest_version = 2` etc. This is an application-level counter; S3 versioning handles the file-level history.
- `file_count` — the number of files included in the bundle at promotion time. Checked at `CHECK (file_count > 0)`.
- `total_size_bytes` — total uncompressed size of all files in the bundle in bytes. Used for storage accounting and integrity checks.
- `s3_prefix` — the S3 object key prefix under which all bundle files are stored. Format: `archive/{business_id}/{period_id}/{run_id}/`. The manifest file itself is at `{s3_prefix}manifest.json`.
- `manifest_hash` — SHA-256 of all individual file hashes concatenated in deterministic (lexicographic by filename) order. Computed by `archive.promote` and verified by `archive.verify`. This hash is the message imprint submitted to the TSA during signing.
- `timestamp_token` — base64-encoded RFC 3161 `TimeStampToken` as returned by the TSA. Null until `archive.sign` completes. When `archive.sign` is called multiple times, this column stores the most recent token; all tokens are preserved in the `signatures` array within `manifest.json` in S3.
- `signing_certificate_id` — UUID referencing the certificate used in the most recent signing. Null until first signing. Populated by `archive.sign`.
- `object_lock_mode` — always `COMPLIANCE`. No other mode is permitted. CHECK constraint enforces this. COMPLIANCE mode prevents deletion or modification of S3 objects even by the root account until `object_lock_retain_until`.
- `object_lock_retain_until` — date after which the S3 Object Lock expires. Computed as `created_at::date + interval '7 years'`. Aligns with Cyprus accounting record retention requirements (7 years from the end of the accounting period, or from `created_at` as a conservative default). This value is written to each S3 object's Object Lock configuration at promotion time.
- `promoted_at` — timestamp when `archive.promote` successfully completed. Null while the bundle is being prepared. Once set, the bundle is considered promoted and the manifest row is effectively immutable (except for signing columns).
- `promoted_by` — always `'SYSTEM'`; the finalization pipeline does not accept user-initiated bundle promotion. Stored as text rather than a UUID because it represents a system actor.
- `created_at` — insertion timestamp; not updated after creation.

---

## Indexes

```sql
-- Gate check: find the manifest for a specific run
CREATE INDEX idx_archive_manifests_run_id
  ON archive_manifests (run_id);

-- Period-level archive lookup (accountant and admin views)
CREATE INDEX idx_archive_manifests_business_period
  ON archive_manifests (business_id, period_id);
```

---

## Row-level security

```sql
ALTER TABLE archive_manifests ENABLE ROW LEVEL SECURITY;

-- Org owners and admins may read their business's archive manifests
CREATE POLICY archive_manifests_org_read
  ON archive_manifests FOR SELECT
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE  user_id = auth.uid()
        AND  role IN ('OWNER', 'ADMIN')
    )
  );

-- Service role: full access (used by archive.promote, archive.sign, archive.verify)
CREATE POLICY archive_manifests_service_role
  ON archive_manifests FOR ALL
  USING (auth.role() = 'service_role');
```

Client code never writes to this table directly. All writes go through the service role via `archive.promote` and `archive.sign`.

---

## Data zone

Archive manifests and their S3 objects reside in the Archive data zone as defined in `storage_bucket_configuration.md`:

- S3 bucket: `{platform}-archive` (separate from Hot and Warm zones)
- Object Lock enabled at bucket level
- Mode: COMPLIANCE (cannot be downgraded to GOVERNANCE)
- Default retention: 7 years from object creation date
- Versioning: enabled (all versions retained until the COMPLIANCE hold expires)
- Replication: cross-region enabled for disaster recovery

The `object_lock_retain_until` value in this table is written to each S3 object's individual Object Lock configuration at promotion time. Bucket-level default retention acts as a fallback but individual object configuration takes precedence.

---

## Audit events

| Event | Severity | Trigger |
|---|---|---|
| `ARCHIVE_PROMOTED` | LOW | `promoted_at` is set; bundle successfully moved to Archive zone |
| `ARCHIVE_DOCUMENT_SIGNED` | LOW | `archive.sign` completes successfully |
| `ARCHIVE_VERIFICATION_STARTED` | LOW | `archive.verify` begins checking a bundle |
| `ARCHIVE_VERIFICATION_COMPLETED` | LOW | `archive.verify` confirms bundle integrity |
| `ARCHIVE_TAMPER_DETECTED` | BLOCKING | `archive.verify` detects a hash mismatch or Object Lock violation |

`ARCHIVE_TAMPER_DETECTED` at severity BLOCKING immediately opens a review issue and triggers the `tamper_detection_forensic_runbook.md` response procedure.

---

## Related Documents

- `tool_archive_promote.md` — creates the bundle and sets promoted_at
- `tool_archive_sign.md` — sets timestamp_token and signing_certificate_id
- `tool_archive_verify.md` — verifies manifest_hash and Object Lock status
- `archive_bundle_layout_schema.md` — structure of files within the bundle
- `archive_bundle_construction_schema.md` — how file_count and manifest_hash are computed
- `storage_bucket_configuration.md` — S3 bucket settings and Object Lock configuration
- `archive_access_control_policy.md` — who may read archive manifests
- `archive_verification_policy.md` — periodic re-verification schedule
- `data_retention_policy.md` — 7-year retention basis
- `tamper_detection_forensic_runbook.md` — response when ARCHIVE_TAMPER_DETECTED fires
