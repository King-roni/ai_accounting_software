# Archive Verification Policy

**Category:** Policies · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Rules governing the post-finalization verification pass that runs after the Block 15 lock sequence completes and `ARCHIVE_PROMOTION_COMPLETED` is emitted. Verification confirms that the archive bundle is internally consistent, that each file's SHA-256 hash matches the manifest, that the RFC 3161 timestamp is valid, and that ledger and invoice counts in the bundle match the operational database. This policy does not govern the lock sequence itself — that is `lock_sequence_policies`.

---

## 1. Trigger condition

The post-finalization verification pass is triggered automatically after `ARCHIVE_PROMOTION_COMPLETED` is emitted. The verification pass is independent of the lock sequence steps; it runs as a separate, asynchronous workflow phase dispatched by the Block 15 event subscriber in Block 16's analytics rebuild path. Verification does not block the `FINALIZED` state transition — the run is already `FINALIZED` before verification begins.

Manual verification may also be triggered by an Owner or Admin at any time after a period has been finalized. Manual verification does not require step-up MFA and does not require the run to be in any particular state other than `FINALIZED`.

---

## 2. Verification checks (binding)

The tool `archive.verify_bundle` performs the following four checks in order. All four must pass for verification to succeed.

### Check 1 — File hash integrity

For every file listed in the bundle's `manifest.json`, the tool recomputes the SHA-256 hash of the file bytes from the stored bundle ZIP and compares it to the `hash` field recorded in `manifest.json`. The hash is encoded as hex (lowercase, 64 characters) per `data_layer_conventions_policy`.

If any file's recomputed hash does not match the manifest entry, Check 1 fails.

### Check 2 — RFC 3161 timestamp validity

The tool validates the TSA response token stored at `{bundle_key}.tsr` in the `archive-bundles` bucket. Validation comprises:

1. Parsing the DER-encoded TSA response token.
2. Verifying that the `messageImprint` in the token matches the SHA-256 hash of the bundle ZIP (the same hash stored on `archive_packages.bundle_hash`).
3. Verifying the TSA certificate chain against the EU Trusted Lists (per `rfc3161_timestamp_policy`).
4. Confirming that the timestamp's signing time falls within the expected window (after the run transitioned to `FINALIZING` and before the current wall-clock time plus a 5-minute tolerance for clock skew).

If the `.tsr` file is absent (because the TSA call failed during the lock sequence and was not retried successfully), Check 2 is marked as `SKIPPED_TSA_UNAVAILABLE` rather than `FAILED` — the absence of the token was already recorded in the manifest at bundle creation time. Check 2 failing due to a malformed or invalid token (not mere absence) is treated as a hard failure.

### Check 3 — Ledger entry count reconciliation

The tool queries `archive.locked_ledger_entries` for the row count of all rows with `archive_package_id` matching the current lock. It compares this count to the row count of `ledger_entries.csv` inside the bundle ZIP (line count minus the header row). A discrepancy of any size fails Check 3.

### Check 4 — Issued invoice PDF completeness

For the finalized period, the tool queries `invoices` where `status NOT IN ('DRAFT', 'VOID')` and `period_start/period_end` falls within the locked period. For each such invoice, it verifies that a PDF entry exists in the bundle at the expected path per `archive_bundle_file_manifest`. If any invoice (with a non-draft, non-void status) has no corresponding PDF in the bundle, Check 4 fails.

---

## 3. Failure handling

If any check fails (other than a `SKIPPED_TSA_UNAVAILABLE` outcome on Check 2), `ARCHIVE_VERIFICATION_FAILED` is raised:

1. A review issue of type `archive.verification_failed` with severity `BLOCKING` is created in the review queue.
2. A `SECURITY_ALERT_RAISED` event is emitted (per Block 05 Phase 10) alerting all Owners.
3. The `archive_packages` row's `verification_status` column is set to `FAILED`.

A verification failure does **not** un-finalize the period. The archive is immutable: the `FINALIZED` state on the run row is not changed, and the Object-Locked bundle is not deleted. The period remains finalized for operational purposes (e.g., subsequent runs may proceed). The failure means the operator must investigate whether the bundle was corrupted in storage or whether there is a gap in the evidence set.

The investigation path follows `archive_promotion_failure_runbook`. That runbook defines the operator steps, the escalation contacts, and the acceptable resolution paths (which may include re-running the bundle assembly for an adjustment run to produce a corrected archive).

---

## 4. Verification outcome storage

Verification outcomes are recorded on the `archive_packages` row:

| Column | Values |
|---|---|
| `verification_status` | `PENDING`, `PASSED`, `FAILED`, `PARTIAL` (`PARTIAL` when Check 2 is `SKIPPED_TSA_UNAVAILABLE` but all other checks pass) |
| `verified_at` | Timestamptz of the completed verification pass |
| `verification_check_detail_json` | JSONB — per-check outcome (`PASSED`, `FAILED`, `SKIPPED_TSA_UNAVAILABLE`) and failure detail if applicable |

These fields are set by `archive.verify_bundle` exclusively. No other tool or application code may update `verification_status`.

---

## 5. Frequency and idempotency

- **Automatic:** runs once, asynchronously, after each `ARCHIVE_PROMOTION_COMPLETED`. If the automatic pass fails partway through (infrastructure error), the Block 03 resumability framework retries it. The tool is idempotent: re-running against a bundle that already has `verification_status = PASSED` is a no-op.
- **Manual:** any Owner or Admin may trigger via the `archive.verify_bundle` tool. Manual runs overwrite the `verification_check_detail_json` with the latest result. Manual runs do not require step-up MFA.

---

## 6. Verification and the `PARTIAL` outcome

A `PARTIAL` outcome occurs when Check 2 returns `SKIPPED_TSA_UNAVAILABLE` and all other checks pass. This means the bundle's file contents are intact and the evidence set is complete, but the trusted timestamp is absent because the TSA call failed during finalization and was not recovered.

A `PARTIAL` outcome is not treated as a failure for operational purposes: the period remains finalized, no review issue is raised, and no security alert fires. However, the `verification_status = PARTIAL` is surfaced in the dashboard so the operator is aware the timestamp is absent. The operator may take one of two paths:

1. Accept the `PARTIAL` status. The archive is still integrity-verified via SHA-256 hashes. The absence of the RFC 3161 token means there is no external, cryptographically-bound timestamp; the `locked_at` timestamp on `period_lock_status` provides an internal timestamp as a fallback.
2. Trigger the compensation-and-retry path documented in `archive_promotion_failure_runbook` to attempt to obtain a retrospective timestamp (only possible if the TSA is willing to issue one for a pre-existing hash; this is TSA-policy-dependent).

The decision is operator-owned; no automated action is taken beyond surfacing the `PARTIAL` status.

---

## 8. Permission requirements for manual verification

Manual verification is available to Owners and Admins. Bookkeepers, Accountants, and Reviewers may view the verification status on the archive detail page but cannot trigger a manual re-run. The manual trigger endpoint is gated by the `ARCHIVE_MANAGE` permission surface per `permission_matrix`.

Step-up MFA is not required for manual verification. The rationale: verification is a read-heavy operation (re-reads the bundle, re-computes hashes) with no write impact on finalized data. The only write is updating `verification_check_detail_json` on `archive_packages`, which is a metadata update, not a data mutation. Requiring step-up for a diagnostic operation would create friction without meaningful security benefit.

---

## 9. Mobile rejection

`archive.verify_bundle` is a server-side tool. Its results are surfaced read-only in the dashboard. The trigger endpoint for manual verification is listed in `mobile_write_rejection_endpoints.md`; mobile clients cannot initiate a manual verification pass.

---

## 7. Scheduled re-verification (Stage 2+ deferral)

MVP runs verification once automatically after finalization plus on-demand manual triggers. A scheduled weekly re-verification pass (re-running all four checks against all finalized bundles within the retention window) is deferred to Stage 2. The purpose of a scheduled pass would be to detect storage-side corruption that occurs after the initial verification passed — for example, bitrot in the object storage layer. MVP relies on the S3-compatible storage provider's internal integrity guarantees (Content-MD5 / ETag checks on GET) as a substitute for scheduled re-verification.

If a storage provider triggers an integrity alert on a bundle object after MVP deployment, the incident response path is `archive_promotion_failure_runbook` — the same runbook used for initial verification failures.

---

## 9. Audit events

| Event | Severity | When |
|---|---|---|
| `ARCHIVE_VERIFIED` | LOW | All four checks pass (or Check 2 is `SKIPPED_TSA_UNAVAILABLE` with all others passing) |
| `ARCHIVE_VERIFICATION_FAILED` | BLOCKING | Any check fails; review issue and security alert are also raised |

Both events are emitted on the business-scoped hash chain per `audit_log_policies`. They are in the `ARCHIVE` domain.

---

## Cross-references

- `lock_sequence_policies` — the 5-step lock sequence whose completion triggers this verification pass; `ARCHIVE_PROMOTION_COMPLETED` as the trigger event
- `rfc3161_timestamp_policy` — Check 2 validation rules; `.tsr` storage location; EU Trusted List chain validation
- `archive_bundle_file_manifest` — file composition spec for Check 1 and Check 4; `manifest.json` hash field format; `ledger_entries.csv` file path
- `data_layer_conventions_policy` — SHA-256 hex encoding for file hash comparison; `numeric` types
- `audit_log_policies` — `ARCHIVE_VERIFIED` and `ARCHIVE_VERIFICATION_FAILED` event naming; `ARCHIVE` domain; business-scoped hash chain
- `audit_event_taxonomy` — `ARCHIVE` domain canonical events; `ARCHIVE_VERIFIED` and `ARCHIVE_VERIFICATION_FAILED` entries
- `archive_promotion_failure_runbook` — incident response steps when `ARCHIVE_VERIFICATION_FAILED` is raised
- `tool_naming_convention_policy` — `archive.verify_bundle` tool name; `WRITES_ARCHIVE | WRITES_AUDIT` side-effect class
- `mobile_write_rejection_endpoints` — manual verification trigger listed as mobile-rejected
- `review_issue_card_schema` — `archive.verification_failed` issue type; `BLOCKING` severity
- Block 15 Phase 04 — `archive.promote_manifest`; `ARCHIVE_PROMOTION_COMPLETED` emission
- Block 15 Phase 05 — archive bundle structure; per-file hash population
- Block 05 Phase 10 — security alerting subsystem; `SECURITY_ALERT_RAISED` emission
