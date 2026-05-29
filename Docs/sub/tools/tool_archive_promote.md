# tool_archive_promote

**Category:** Tools — Block 15: Finalization & Secure Archive
**Tool name:** `archive.promote`
**Side effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
**Mobile rejection:** YES — mobile clients cannot call `archive.promote`. See `mobile_write_rejection_endpoints.md`.

---

## Purpose

Promotes a finalized archive bundle from the Processing storage zone to the Archive
storage zone with S3 Object Lock (COMPLIANCE mode, 7-year retention). This tool is
called internally by `engine.finalize` as step iii of the finalization sequence. It
may also be called directly during failure recovery per the archive promotion failure
runbook.

---

## Input Schema

```json
{
  "run_id":          "uuid",
  "bundle_id":       "uuid",
  "idempotency_key": "string"
}
```

All fields are required.

---

## Output Schema

```json
{
  "bundle_id":    "uuid",
  "archive_path": "text",
  "bundle_hash":  "text",
  "promoted_at":  "timestamptz"
}
```

`archive_path` is the full S3 object key in the Archive bucket.
`bundle_hash` is the SHA-256 hex digest of the bundle zip file.

---

## Execution Steps

Steps execute in the order below. Each step must succeed before proceeding to the next.

| # | Step | Detail |
|---|---|---|
| i | Compute SHA-256 of the bundle zip file in the Processing zone. | Read the file from Processing zone; compute digest in-memory. |
| ii | Upload the bundle to the Archive S3 bucket. | Set `x-amz-object-lock-mode: COMPLIANCE` and `x-amz-object-lock-retain-until-date` = upload date + 7 years. Retention period is governed by `data_retention_policy.md`. |
| iii | Verify ETag. | Read the ETag returned by S3 on the completed upload. Compare to the SHA-256 computed in step i. If they do not match, abort with `ARCHIVE_PROMOTION_HASH_MISMATCH`. |
| iv | Update `archive_bundles` row. | Set `archive_path` = the Archive S3 object key, `object_lock_status = 'LOCKED'`, `bundle_hash` = SHA-256 from step i, `promoted_at = now()`. |

---

## Retry Policy

Step ii (upload) is retried up to 3 times on transient S3 errors (5xx, network timeout)
with exponential back-off:

| Attempt | Delay before retry |
|---|---|
| 1 (initial) | — |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4 | 8 seconds |

After 3 retries (4 total attempts) without success, the tool writes
`ARCHIVE_PROMOTION_FAILED` (HIGH) and returns a `500` error. The bundle remains in
the Processing zone and the `archive_bundles` row is not updated.

---

## Hash Mismatch Handling

An ETag mismatch after a successful S3 upload indicates data corruption in transit.
This is treated as `BLOCKING`:

- `ARCHIVE_PROMOTION_HASH_MISMATCH` audit event is written at severity `BLOCKING`.
- The partially-uploaded object in Archive zone is tagged for quarantine; it is NOT
  deleted by this tool (deletion requires manual remediation per
  `archive_promotion_failure_runbook.md`).
- The `archive_bundles` row is NOT updated.
- The tool returns `500 HASH_MISMATCH`.

No retries are attempted on a hash mismatch — the mismatch is deterministic and
indicates the source bundle may be corrupt.

---

## Idempotency

If `bundle_id` already has `archive_path` set (promotion previously completed):

1. Verify the existing `archive_path` is reachable (HEAD request to Archive S3).
2. If reachable: return success with the existing `archive_path`, `bundle_hash`, and
   `promoted_at`. No steps are re-executed.
3. If not reachable: re-execute from step ii (the previous promotion was partial).

Idempotency keys expire after 24 hours.

---

## Processing Zone Cleanup

This tool does NOT delete the Processing zone copy. After successful promotion, the
Processing zone object is eligible for TTL expiry (7 days post-run). The background
TTL job governed by `data_retention_policy.md` handles deletion. The tool only sets
`promoted_at`; the TTL job reads this field to determine eligibility.

---

## Object Lock Configuration

| Parameter | Value |
|---|---|
| Mode | COMPLIANCE |
| Retention period | 7 years from upload date |
| Bucket versioning | Required (enabled before Object Lock can be activated) |
| Legal hold | Not set by this tool |

Once an object is locked with COMPLIANCE mode, it cannot be deleted or overwritten,
including by the bucket owner, until the retention period expires. See
`object_lock_integration.md` for IAM policy requirements and compliance implications.

---

## Primary Key References

`bundle_id` must reference an existing row in `archive_bundles`. `run_id` is used for
correlated audit log entries. Both must be associated with the same `business_id`.

---

## Audit Events

| Event                                  | Severity | Trigger                                      |
|---|---|---|
| `ARCHIVE_BUNDLE_PROMOTED`              | MEDIUM   | Steps i–iv completed successfully            |
| `ARCHIVE_PROMOTION_FAILED`             | HIGH     | Upload failed after 3 retries                |
| `ARCHIVE_PROMOTION_HASH_MISMATCH`      | BLOCKING | ETag does not match computed SHA-256         |

All events include `run_id`, `bundle_id`, and `business_id` in the audit payload.

---

## Error Codes

| Code                          | HTTP | Meaning                                            |
|---|---|---|
| `BUNDLE_NOT_FOUND`            | 404  | bundle_id does not exist in archive_bundles        |
| `RUN_NOT_FOUND`               | 404  | run_id does not exist                              |
| `PROCESSING_ZONE_UNAVAILABLE` | 503  | bundle file not readable from Processing zone      |
| `ARCHIVE_PROMOTION_FAILED`    | 500  | upload failed after 3 retries                      |
| `HASH_MISMATCH`               | 500  | ETag does not match computed SHA-256               |

---

## Cross-References

- `archive_bundle_construction_schema.md` — bundle structure, DDL, and hash chain spec
- `data_retention_policy.md` — 7-year retention rule, TTL expiry for Processing zone
- `object_lock_integration.md` — S3 Object Lock setup, IAM requirements, compliance notes
- `archive_promotion_failure_runbook.md` — remediation steps for failed promotions
- `mobile_write_rejection_endpoints.md` — mobile rejection policy and error format

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.