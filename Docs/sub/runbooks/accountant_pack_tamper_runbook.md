# Accountant Pack Tamper Investigation Runbook

**Category:** Runbooks · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

---

## Trigger

This runbook is initiated under either of the following conditions:

1. `SECURITY_HASH_CHAIN_TAMPER_DETECTED` is emitted for a finalized period — indicating that the archive bundle's hash chain or bundle hash deviates from the stored reference.
2. An accountant reports that the contents of a downloaded pack do not match their records — for example, a document is missing, figures differ from the signed copy, or the PDF is corrupt.

Both triggers require immediate investigation. Do not dismiss the report before completing at least Steps 1 through 4 of this runbook.

---

## Prerequisites

Before beginning, retrieve the following from the `archive_bundles` table for the affected period:

```sql
SELECT
  ab.id            AS bundle_id,
  ab.bundle_hash,          -- SHA-256 of the full ZIP, hex-encoded
  ab.archive_path,         -- S3 Object Lock key (e.g. s3://archive-bundles/<business_id>/<period>/<run_id>.zip)
  ab.archived_at,
  ab.workflow_run_id,
  ab.manifest_version
FROM archive_bundles ab
WHERE ab.business_id  = '<business_id>'
  AND ab.period_start = '<period_start>'
  AND ab.period_end   = '<period_end>'
ORDER BY ab.archived_at DESC
LIMIT 1;
```

Also retrieve the `period_lock_status` row:

```sql
SELECT *
FROM period_lock_status
WHERE business_id  = '<business_id>'
  AND period_start = '<period_start>'
  AND period_end   = '<period_end>';
```

Confirm the period is in `LOCKED` status before proceeding. If the period is not locked, the bundle was not finalized and this runbook does not apply — investigate via `finalization_failure_per_mode_runbook.md` instead.

---

## Step 1 — Verify S3 Object Lock status

Confirm the archive bundle object exists in S3 and has WORM Object Lock active.

```bash
aws s3api get-object-retention \
  --bucket archive-bundles \
  --key "<archive_path_key>"
```

Expected output: `{ "Retention": { "Mode": "COMPLIANCE", "RetainUntilDate": "<date>" } }`

**If the object is MISSING:** escalate immediately to BLOCKING. The archive copy has been deleted or the path is wrong. Emit `SECURITY_HASH_CHAIN_TAMPER_DETECTED` (BLOCKING) if not already emitted, notify ADMIN and OWNER, and freeze the business account pending investigation.

**If Object Lock status is UNLOCKED or GOVERNANCE (not COMPLIANCE):** escalate to BLOCKING. Object Lock in GOVERNANCE mode can be bypassed by privileged users; a COMPLIANCE downgrade is a security event. Treat as confirmed tampering until disproven.

**If the object is present with COMPLIANCE mode:** proceed to Step 2.

---

## Step 2 — Recompute bundle hash

Download the archive bundle from S3 and recompute its SHA-256:

```bash
aws s3 cp "s3://archive-bundles/<archive_path_key>" /tmp/bundle_check.zip

sha256sum /tmp/bundle_check.zip
```

Compare the computed hash against `archive_bundles.bundle_hash`.

**If the hashes DIFFER:** the archive copy in S3 has been tampered with. This is a confirmed BLOCKING security event. Proceed to the escalation section. Do not attempt further steps on the tampered copy until a forensic snapshot has been made.

**If the hashes MATCH:** the archive copy in S3 is intact. The discrepancy reported by the accountant is in a locally-downloaded copy. Proceed to Step 3 to verify the audit chain, then offer the accountant a fresh signed download link (see the False Positive section at the end of this runbook).

---

## Step 3 — Hash chain verification

Query the `audit_log_hash_chain` for all events associated with the period's `workflow_run_id`:

```sql
SELECT
  alh.sequence_number,
  alh.event_name,
  alh.chain_hash,
  alh.prev_chain_hash,
  alh.emitted_at
FROM audit_log_hash_chain alh
WHERE alh.workflow_run_id = '<workflow_run_id>'
  AND alh.business_id     = '<business_id>'
ORDER BY alh.sequence_number ASC;
```

Verify the chain is unbroken using the hash chain verification procedure from `tool_hash_chain_append.md`:

For each row `n`, recompute:
```
expected_chain_hash[n] = SHA-256( chain_hash[n-1] || canonical_json(event_payload[n]) )
```

Compare `expected_chain_hash[n]` against `stored chain_hash[n]`.

**If ANY row's recomputed hash diverges from its stored hash:** the audit chain is broken. This is a HIGH security event indicating data corruption or deliberate chain manipulation. Emit `AUDIT_HASH_CHAIN_VERIFICATION_FAILED` if the weekly scan has not already done so. Proceed to the escalation section.

**If the chain is unbroken:** the audit record is intact. Proceed to Step 4.

---

## Step 4 — Individual file verification

Each file in the bundle has a SHA-256 hash recorded in the `accountant_pack_manifest_schema.md` manifest entries. Unzip the bundle (use the S3 copy validated in Step 2) and verify each file:

```bash
unzip /tmp/bundle_check.zip -d /tmp/bundle_extracted/

# For each file listed in the manifest:
sha256sum /tmp/bundle_extracted/<file_path>
```

Compare each computed hash against the corresponding `file_sha256_hex` field in the manifest.

**If ALL file hashes match:** the bundle contents are intact. The reported discrepancy is definitively in a locally-modified copy. Proceed to the False Positive section.

**If ANY file hash DIFFERS from the manifest:** identify which file(s) are affected. This confirms the ZIP was altered after the manifest was built. Record the affected file names and proceed to the escalation section.

---

## Step 5 — RFC 3161 timestamp verification

The archive bundle includes a `.tsr` (timestamp response) file at the root of the ZIP. Verify the timestamp token against the TSA public key per `rfc3161_timestamp_policy.md`:

```bash
openssl ts -verify \
  -in /tmp/bundle_extracted/bundle.tsr \
  -data /tmp/bundle_check.zip \
  -CAfile /etc/ssl/tsa_ca_chain.pem
```

Expected result: `Verification: OK`

**If verification FAILS:** the timestamp token does not cover the current ZIP bytes. Combined with a bundle hash mismatch, this confirms the ZIP was modified after timestamping. Combined with a matching bundle hash, this indicates a TSR file replacement — equally suspicious.

**If verification SUCCEEDS:** the TSA proves the bundle existed in its current form at the stamped time. A valid TST with a matching bundle hash proves the archive copy has not been modified since timestamping.

Record `gen_time` from the TSA token and confirm it falls within the expected finalization window (within 15 minutes of `archive_bundles.archived_at`).

---

## Escalation

If Steps 2 through 5 confirm tampering (bundle hash mismatch, broken audit chain, file hash deviation, or TSR verification failure), execute the following:

1. **Emit** `SECURITY_HASH_CHAIN_TAMPER_DETECTED` (BLOCKING) to the global audit chain if not already emitted by the weekly scan. Payload: `business_id`, `workflow_run_id`, `bundle_id`, `tamper_evidence_summary`.

2. **Notify** the ADMIN and OWNER of the affected business immediately. Use the out-of-band escalation channel defined in `security_alert_routing_policy.md`. Do not use the platform's own notification pipeline for the tamper alert, as the pipeline's integrity may also be in question.

3. **Freeze the business account** pending investigation: set `business_entities.is_active = false` for the affected business. This halts new workflow runs and prevents further writes.

4. **File an incident report** per the incident response procedure in `tamper_detection_forensic_runbook.md`. Include: bundle_id, workflow_run_id, affected period, which step revealed the tamper, and all hash values computed during this runbook.

5. **Preserve forensic evidence**: take a snapshot of the S3 object (even if tampered), the `audit_log_hash_chain` rows, and the `archive_bundles` row before any remediation is attempted.

---

## False positive: bundle hash matches the archive copy

If Step 2 confirms the S3 archive copy's bundle hash matches `archive_bundles.bundle_hash`, and Steps 3–5 confirm the chain and individual files are intact, the reported discrepancy is in a locally-downloaded copy of the pack.

This can occur when:
- The accountant modified their local copy of the ZIP or a file within it.
- The accountant's file system or email client corrupted the downloaded file.
- The accountant downloaded the pack during a partial upload (if they received the download link before the bundle promotion completed — this should not be possible given the step-up access control, but is worth confirming).

**Resolution:** Generate a fresh signed download link for the accountant via `archive.generate_download_url`. The link requires the accountant to complete a step-up MFA challenge. Confirm that the newly-downloaded pack matches the accountant's expected records. Emit no tamper events; record the investigation in the support ticket.

---

## Cross-references

- `archive_bundle_construction_schema.md` — ZIP construction, Pass 1 / Pass 2 manifest build
- `accountant_pack_manifest_schema.md` — per-file SHA-256 hashes in the manifest
- `tamper_detection_forensic_runbook.md` — full forensic incident response procedure
- `rfc3161_timestamp_policy.md` — TSA endpoint, token validation, `.tsr` file format
- `audit_event_taxonomy.md` — `SECURITY_HASH_CHAIN_TAMPER_DETECTED`, `AUDIT_HASH_CHAIN_VERIFICATION_FAILED`, `ARCHIVE_VERIFICATION_FAILED`
- `tool_hash_chain_append.md` — hash chain recomputation procedure
- `security_alert_routing_policy.md` — ADMIN/OWNER escalation channels
