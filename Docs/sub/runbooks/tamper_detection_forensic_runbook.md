# Tamper Detection — Forensic Trace Runbook

**Category:** Runbooks · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 15, Phases 04–06 (bundle construction, Object Lock, archive verification). Co-owned by Block 05 — Security & Audit (integrity check job, `ARCHIVE_TAMPER_DETECTED` emission).

**Purpose:** Defines the detection mechanism, the step-by-step forensic trace procedure, the quarterly drill protocol, and the false-positive clearing process for archive tamper events. An operator following this runbook should be able to distinguish confirmed tampering from storage provider integrity anomalies and produce a documented conclusion in every case.

---

## Detection mechanism

### Scheduled integrity check job

A daily background job (`archive.verify_all_bundles`) runs independently of any finalization activity. The job:

1. Queries `archive_bundles` for all rows where `lock_status = 'LOCKED'` and `integrity_last_verified_at < NOW() - INTERVAL '24 hours'`.
2. For each bundle, retrieves the stored object bytes from the `archive-bundles` bucket using the `storage_key`.
3. Computes SHA-256 of the retrieved bytes using the canonical algorithm from `data_layer_conventions_policy.md` (hex encoding, lowercase).
4. Compares the computed hash against `archive_bundles.bundle_hash` (stored at bundle-seal time).
5. Additionally, for all finalized runs, walks the hash chain for the business's `chain_id`, re-computing each `chain_hash` from `prev_chain_hash || event_payload_canonical_json` and comparing against the stored value.

The job updates `archive_bundles.integrity_last_verified_at` after each successful check.

### Detection signal

When any check fails, the job emits `ARCHIVE_TAMPER_DETECTED` (severity: BLOCKING) via `emitAudit()`. This event is in the `ARCHIVE` domain per `audit_log_policies.md`.

The BLOCKING severity triggers an immediate operator alert via the security alerting pipeline (`security.raise_alert`), which sends a notification to all OWNER and ADMIN users on the affected business and pages the on-call operator if the alerting integration is configured.

**No finalization or export can proceed for the affected `business_id` while `ARCHIVE_TAMPER_DETECTED` is in an unresolved state.** The `engine.gate_finalization_preconditions` gate checks for unresolved BLOCKING security alerts before allowing the lock sequence to begin.

---

## Forensic trace procedure

### Step 1 — Identify the affected run and bundle

From the `ARCHIVE_TAMPER_DETECTED` event payload, extract:

- `workflow_run_id` — the run whose bundle failed verification
- `archive_bundle_id` — the specific bundle row in `archive_bundles`
- `object_key` — the Object Storage key of the affected ZIP
- `expected_sha256_hex` — the hash stored on the `archive_bundles` row at seal time
- `computed_sha256_hex` — the hash computed during the integrity check
- `detected_at` — UTC timestamp of detection

Record these values before proceeding. All subsequent steps reference these identifiers.

### Step 2 — Pull the bundle manifest and compare per-file hashes

Query the manifest entries for the affected bundle:

```sql
SELECT
    abfm.file_path,
    abfm.sha256_hex AS manifest_expected_hash,
    abfm.file_size_bytes,
    abfm.object_key AS file_storage_key
FROM archive_bundle_file_manifest abfm
WHERE abfm.archive_bundle_id = '<archive_bundle_id>'
ORDER BY abfm.file_path;
```

For each file listed in the manifest, retrieve the corresponding object bytes from storage and compute SHA-256. Compare each computed hash against `manifest_expected_hash`. Differences narrow the scope from "something in the bundle changed" to the specific file(s) affected.

This step is compute-intensive for large bundles. Prioritise files that are security-critical: audit log exports, ledger CSVs, and the manifest JSON itself.

### Step 3 — Check Object Storage access logs for writes after the lock timestamp

The archive object was Object-Locked at seal time. No compliant storage provider should allow a write operation on a COMPLIANCE-mode locked object. However, the access log check verifies this independently.

In the Supabase Storage console (or via the storage provider's API), pull the access log for the affected `object_key`. Filter to events after `archive_bundles.locked_at` for the bundle.

Look for any `PUT`, `POST`, `DELETE`, `COPY`, or `RestoreObject` operation. A legitimate sealed archive should show only `GET` and `HEAD` operations after the lock timestamp.

If the storage provider does not surface per-object access logs directly, request them via the provider's support portal, referencing the bucket name, object key, and the time window from `locked_at` to `detected_at`.

### Step 4 — Verify the RFC 3161 timestamp against the current document

The RFC 3161 timestamp in the `.tsr` file stored alongside the bundle asserts that the bundle's SHA-256 hash existed at or before the timestamp's `genTime`.

Retrieve the `.tsr` file from the `archive-bundles` bucket (key pattern: `<storage_key>.tsr`).

Verify the timestamp response:

1. Parse the TSR and extract the `messageImprint` (algorithm OID + hash value).
2. Confirm the `messageImprint` hash matches `archive_bundles.bundle_hash`.
3. Confirm the `genTime` in the TSR is at or before `archive_bundles.locked_at` (within TSA clock tolerance).
4. Verify the TSR signature against the TSA's public certificate chain.

If the `messageImprint` hash in the TSR does not match `archive_bundles.bundle_hash`, the timestamp does not cover the current document state. This is strong evidence that the document was modified after timestamping. Note this finding; it is relevant to Step 5.

### Step 5 — Determine conclusion: confirmed tamper or provider integrity issue

**Confirmed tamper** — all of the following are true:
- The computed SHA-256 differs from the stored hash.
- The Object Storage access log shows one or more write operations after `locked_at`.
- The RFC 3161 timestamp's `messageImprint` matches the original bundle hash but not the current bytes.

**Escalation steps for confirmed tamper:**

1. Do not modify, delete, or re-upload any affected objects. Preserve the current state as evidence.
2. Export and preserve all access logs, the `ARCHIVE_TAMPER_DETECTED` event payload, and this runbook's findings as a written incident record.
3. Escalate to the security team and legal counsel immediately. This constitutes a potential breach of the regulatory archive.
4. Disable export and finalization for the affected `business_id` via the platform admin surface until the investigation is complete.
5. Notify the business OWNER as required by the applicable data-breach notification timeline under Cyprus law.

**Storage provider integrity issue** — all of the following are true:
- The computed SHA-256 differs from the stored hash.
- The Object Storage access log shows NO write operations after `locked_at`.
- The RFC 3161 timestamp's `messageImprint` matches the original bundle hash.

This pattern indicates silent bit corruption by the storage provider — the object's bytes have changed without a client-side write operation. Follow the false-positive clearing procedure below.

**Ambiguous result** — if the access log is unavailable or incomplete:

Do not resolve the alert until the log evidence is obtained. Treat as confirmed tamper pending investigation. Open a priority support ticket with the storage provider to obtain the access log.

---

## Quarterly drill — simulation protocol

The quarterly drill verifies that the detection pipeline is functioning end-to-end before a real tamper event occurs.

**Prerequisites:** The drill must be performed against a non-production environment (staging or development). Never run the drill against a production archive.

**Drill steps:**

1. Identify a finalized bundle in the non-production environment. Record its `archive_bundle_id` and `storage_key`.
2. Using a storage-admin credential that bypasses Object Lock (available only in non-production environments where COMPLIANCE mode is not enforced), write a single-byte modification to the bundle object. Record the modification timestamp.
3. Wait for the next scheduled run of `archive.verify_all_bundles`, or trigger it manually in the non-production environment.
4. Verify that `ARCHIVE_TAMPER_DETECTED` is emitted with the correct `archive_bundle_id`, `workflow_run_id`, and mismatching hash values.
5. Verify that the operator alert fires (check the alerting integration log for the non-production environment).
6. Restore the original object bytes from the backup or by re-uploading the original content.
7. Run `archive.verify_all_bundles` again and confirm `ARCHIVE_TAMPER_DETECTED` is NOT emitted for the restored bundle, and that `archive_bundles.integrity_last_verified_at` updates.
8. Document the drill outcome (pass/fail) in `decisions_log.md` with the date and the non-production `archive_bundle_id` used.

If the drill fails (no `ARCHIVE_TAMPER_DETECTED` emitted for a known-corrupt object), escalate to engineering before the next production deployment. The integrity check job may be misconfigured or skipping bundles.

---

## False-positive clearing procedure

A false positive is a confirmed storage provider checksum inconsistency where:
- No client-side write operation is present in the access logs.
- The RFC 3161 timestamp's `messageImprint` matches the original bundle hash.
- The provider has acknowledged the integrity anomaly in a support ticket response.

**Clearing steps:**

1. Obtain written confirmation from the storage provider acknowledging the integrity anomaly and confirming no unauthorized access occurred.
2. Document the provider's response, the `archive_bundle_id`, the `detected_at` timestamp, and the resolution in `decisions_log.md`. Reference the provider's support ticket ID.
3. Re-retrieve the original bundle bytes from the provider's data-recovery path (most providers retain a pre-corruption snapshot for Object-Locked objects; confirm this with the provider before proceeding).
4. Verify the recovered bytes hash to `archive_bundles.bundle_hash`. Do not proceed if they do not match.
5. Apply a new RFC 3161 timestamp to the recovered bytes:

   ```
   archive.apply_rfc3161_timestamp({ archive_bundle_id: '<id>', force_retimestamp: true })
   ```

   This emits `RFC3161_TIMESTAMP_APPLIED` and updates `archive_bundles.rfc3161_tsr_storage_key`.
6. Emit `ARCHIVE_TAMPER_FALSE_POSITIVE_CLEARED` by calling `security.resolve_alert` with `resolution_note` referencing the `decisions_log.md` entry.
7. Run a manual integrity check pass on the bundle to confirm `ARCHIVE_TAMPER_DETECTED` is not re-emitted.

---

## Interaction with finalization gating

The `engine.gate_finalization_preconditions` gate checks for unresolved `ARCHIVE_TAMPER_DETECTED` events before allowing the 5-step lock sequence to begin. Specifically, it queries:

```sql
SELECT COUNT(*) FROM security_alerts
WHERE business_id = '<biz_id>'
  AND alert_type = 'ARCHIVE_TAMPER_DETECTED'
  AND status != 'RESOLVED';
```

A count > 0 causes the gate to return HOLD with `blocking_reason = 'UNRESOLVED_TAMPER_ALERT'`. This gate cannot be bypassed without resolving or explicitly dismissing the alert with a platform-admin credential.

---

## Cross-references

- `archive_verification_policy.md` — post-finalization verification checks, accepted outcomes, and the `SKIPPED_TSA_UNAVAILABLE` condition
- `archive_bundle_construction_schema.md` — `archive_bundle_file_manifest` table structure, per-file hash fields
- `rfc3161_timestamp_policy.md` — TSA retry logic, `.tsr` file structure, `messageImprint` verification
- `hash_chain_schema.md` — hash chain structure, `chain_hash` computation, `chain_heads` table
- `audit_event_taxonomy.md` — `ARCHIVE_TAMPER_DETECTED`, `ARCHIVE_TAMPER_FALSE_POSITIVE_CLEARED`, `ARCHIVE_VERIFICATION_FAILED`
- `finalization_failure_per_mode_runbook.md` — `HASH_CHAIN_BROKEN` and `BUNDLE_PASS2_HASH_MISMATCH` failure modes
