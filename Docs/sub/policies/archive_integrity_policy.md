# Policy: Archive Integrity

**Namespace:** `archive`
**Owning block:** 15 — Finalization & Secure Archive
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

This policy defines how the platform maintains the integrity of the permanent document archive. It covers the SHA-256 hash chain mechanism, RFC 3161 timestamping, Object Storage WORM configuration, the automated verification schedule, the response procedure when tampering is detected, and the prohibition on chain repair.

---

## 1. Hash Chain Mechanism

Every document promoted to the archive zone is assigned a `chain_position` value in `document_archives` and participates in a per-business hash chain. The chain provides tamper evidence: modifying any archived document or its metadata causes all subsequent chain entries to fail verification.

### 1.1 Chain entry computation

When a document is promoted via `tool_archive_promote.md`, the finalization pipeline calls `tool_hash_chain_append.md`, which computes the chain entry as follows:

```
chain_entry_hash = SHA-256(
  prev_chain_entry_hash
  || document_id (uuid, formatted as lowercase hex without hyphens)
  || content_hash (SHA-256 of raw document bytes, lowercase hex)
  || storage_path (UTF-8)
  || locked_at::text (ISO 8601, UTC)
  || business_entity_id (uuid, lowercase hex without hyphens)
)
```

`prev_chain_entry_hash` is the `chain_entry_hash` of the row at `chain_position - 1` for the same `business_entity_id`. For the first document in the chain (`chain_position = 1`), `prev_chain_entry_hash` is the null sentinel: 64 ASCII zeros.

The `chain_entry_hash` is stored in the `hash_chain` table (defined in `hash_chain_schema.md`) alongside the `chain_position` and `document_archive_id`. The `document_archives` table stores `chain_position` but not the hash itself, keeping the chain state in the dedicated `hash_chain` table.

### 1.2 Chain scope

The chain is scoped per `business_entity_id`. Each business has an independent monotonic chain. Cross-business chain comparisons are not meaningful and are not performed.

### 1.3 Chain position assignment

`chain_position` is assigned within a serializable transaction using:

```sql
SELECT COALESCE(MAX(chain_position), 0) + 1
FROM document_archives
WHERE business_entity_id = $business_entity_id
FOR UPDATE;
```

The `UNIQUE (business_entity_id, chain_position)` constraint in `document_archive_schema.md` prevents gaps or duplicates at the database level.

---

## 2. RFC 3161 Timestamping

### 2.1 Purpose

RFC 3161 timestamps provide cryptographic proof that a document existed in its current form at or before a specific point in time. They are issued by a trusted Timestamp Authority (TSA) and are legally admissible as evidence in EU jurisdictions, including Cyprus, under eIDAS Article 41.

### 2.2 When timestamps are obtained

After `tool_archive_promote.md` completes, `tool_archive_sign.md` is called. It submits the `content_hash` of each document (or the `manifest_hash` of the bundle) to the configured TSA and stores the returned `TimeStampToken` in `document_archives.rfc3161_timestamp_token` (DER-encoded, bytea). The TSA used is configured in `rfc3161_timestamp_policy.md`.

### 2.3 Verification

`tool_archive_verify.md` verifies the timestamp token against the document's current `content_hash`. A mismatch between the hash embedded in the token and the stored `content_hash` indicates that either the document or its metadata was modified after signing. This is treated as tampering (see section 4).

### 2.4 Token storage

Tokens are stored in `document_archives.rfc3161_timestamp_token` (bytea, DER format). A human-readable copy is also included in the bundle's `manifest.json` in Object Storage (base64-encoded). The database row is the authoritative copy for verification queries; the manifest copy is for portability and audit export.

---

## 3. Object Storage WORM Configuration

The archive zone bucket is configured with S3-compatible Object Lock in COMPLIANCE mode. COMPLIANCE mode prevents any principal, including the root account and platform administrators, from deleting or overwriting objects until the retention period expires.

Settings:

- **Mode:** COMPLIANCE
- **Minimum retention:** 7 years from the date of object upload, aligned with Cyprus accounting record-keeping requirements (Income Tax Law Cap. 297, as amended).
- **Default retention rule:** 7 years applied to all new objects at upload time. Individual objects may carry a longer retention period if required.
- **Bucket versioning:** enabled. Every write creates a new version; existing versions cannot be deleted before retention expiry.

The `object_lock_retain_until` column in `archive_manifests` records the expiry date applied to each bundle. The finalization pipeline writes this date to the S3 object's Object Lock configuration at promotion time via the bucket's default lock and per-object `x-amz-object-lock-retain-until-date` header.

Platform administrators may not shorten the retention period on any object in COMPLIANCE mode. Requests to do so are rejected by the Object Storage API.

---

## 4. Integrity Verification Schedule

`tool_archive_verify.md` runs on an automated schedule to detect tampering before it would otherwise be noticed.

**Daily spot-check:** each calendar day, the scheduler invokes `tool_archive_verify.md` with `{ "mode": "spot_check", "sample_size": 100 }`. The tool selects 100 `document_archives` rows uniformly at random across all businesses and verifies:

1. The `content_hash` in the database matches the SHA-256 of the object bytes in Object Storage.
2. The RFC 3161 token in `rfc3161_timestamp_token` verifies against the stored `content_hash`.
3. The `chain_entry_hash` in `hash_chain` for this document's `chain_position` recomputes correctly given the previous chain entry.

**Monthly full verification:** on the first day of each calendar month, the scheduler invokes `tool_archive_verify.md` with `{ "mode": "full", "business_entity_id": null }` for each business that has at least one finalized period. Full verification walks the entire chain for each business.

Results are emitted as `ARCHIVE_INTEGRITY_VERIFIED` (LOW) on success or `ARCHIVE_INTEGRITY_FAILURE` (BLOCKING) on failure. The BLOCKING severity halts the verification run and immediately triggers the tamper response in section 5.

---

## 5. Tamper Response

If `tool_archive_verify.md` detects a hash mismatch, timestamp token failure, or broken chain link, the following steps are executed automatically and then escalated to human operators.

**5.1 Automatic steps**

1. Emit `ARCHIVE_TAMPER_DETECTED` (HIGH) to the audit log. Payload includes `manifest_id`, `document_key` (the `storage_path` of the affected document), and `business_entity_id`.
2. Set `document_archives.tamper_suspected = true` for all rows at or after the first broken chain position for the affected business.
3. Add the affected `manifest_id` (if known) to a `quarantine_set` maintained in the `archive_manifests` table via `quarantine_flag = true`.
4. Block any new finalization run for the affected business from completing until the quarantine is reviewed. The `engine.gate_finalization` check reads `quarantine_flag` from `archive_manifests`.

**5.2 Escalation**

An in-app notification is sent immediately to all org members with role `org:owner` for the affected business. The notification includes the `document_key`, the first broken chain position, and a link to the tamper investigation runbook (`tamper_detection_forensic_runbook.md`).

**5.3 No deletion of affected records**

Affected `document_archives` rows and the corresponding Object Storage objects must not be deleted, even if they have been confirmed as tampered. A broken or modified chain is preserved as forensic evidence. The only permitted action is flagging (`tamper_suspected = true`, `quarantine_flag = true`). Deletion of tamper-suspected records is a prohibited action regardless of role.

---

## 6. Chain Repair Prohibition

If a hash chain break is detected, the chain must not be repaired by rewriting hashes or reinserting rows. A repaired chain would be indistinguishable from the original, destroying the forensic value of the evidence.

The correct procedure is:

1. Preserve the broken chain exactly as found.
2. Escalate per section 5.2.
3. Document the break in a `note` record against the affected period with `note_type = 'TAMPER_INVESTIGATION'`.
4. If the affected documents are recoverable from an independent source (e.g., email copies of invoices), they may be archived again under a new `chain_position` with a note linking the new and old records. The original broken entries are retained, not replaced.

Any code path that writes to `hash_chain` rows after they are set is a prohibited operation and is blocked by the `document_archives_update` RLS policy (`locked_at IS NULL` requirement).

---

## Related Documents

- `document_archive_schema.md` — `document_archives` table definition
- `archive_manifest_schema.md` — bundle-level metadata including `quarantine_flag`
- `hash_chain_schema.md` — `hash_chain` table structure and chaining algorithm
- `tool_archive_promote.md` — promotes documents to archive zone
- `tool_archive_sign.md` — obtains RFC 3161 timestamp tokens
- `tool_archive_verify.md` — performs hash chain and timestamp verification
- `rfc3161_timestamp_policy.md` — TSA configuration and legal admissibility notes
- `storage_bucket_configuration.md` — Object Lock mode and retention settings
- `tamper_detection_forensic_runbook.md` — operator steps after tamper detection
- `audit_event_taxonomy.md` — `ARCHIVE_TAMPER_DETECTED`, `ARCHIVE_INTEGRITY_VERIFIED`, `ARCHIVE_INTEGRITY_FAILURE`
