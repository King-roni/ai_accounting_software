# Data Retention Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 1 convention)

Binding retention windows for every data zone in the platform. Every engineer writing a deletion job, configuring a storage lifecycle rule, or designing a new table binds to the windows defined here. Windows may not be shortened by application code, user action, or operator request except as explicitly noted. Where a legal minimum exists, the platform enforces it as a hard floor.

---

## Zone summary

| Zone | Retention window | Enforcement mechanism |
| --- | --- | --- |
| Processing zone | 7 days after run completion or cancellation | Scheduled purge job |
| Operational zone | Life of business + 7 years post-deactivation | Nightly soft-delete + 30-day grace hard-delete job |
| Archive zone | 6 years default; per-business override via `retention_policies_schema` | Supabase Storage Object Lock COMPLIANCE mode; deletion by `retention_engine` role after expiry AND no active legal hold |
| Export temp | 24 hours TTL | Supabase Storage lifecycle rule (auto-expire) |
| Audit log | Permanent; append-only | No deletion path under any circumstance |
| Session tokens | 30 days after session expiry | Scheduled purge job |
| Step-up MFA tokens | 1 hour after use or expiry (whichever first) | Scheduled purge job |

---

## Processing zone

**Bucket:** `processing-zone` · **DB tables:** processing-zone scratch tables (classifier outputs, OCR extraction results, pre-finalization working state).

Retention: **7 days** after the workflow run that produced the data reaches a terminal state (`FINALIZED`, `FAILED`, or `CANCELLED`).

Rules:
- Purged by a scheduled job that runs every 4 hours.
- The job identifies runs that reached a terminal state more than 7 days ago and deletes the associated processing-zone rows and Storage objects.
- User-initiated deletion is not permitted. A user may cancel a run (which starts the 7-day clock), but they may not bypass the window.
- If the run is stuck in a non-terminal state (e.g., `RUNNING` with no progress for >30 days — an abnormal condition), the processing zone data is retained until the run is manually resolved by an operator.

---

## Operational zone

**Tables:** `transactions`, `documents`, `match_records`, `review_issues`, `ledger_entries`, `invoices`, `clients`, and all other business-data tables in the main operational DB.

Retention: **lifetime of the business plus 7 years after business deactivation**.

The 7-year post-deactivation floor is the Cyprus Tax Department's minimum records-retention requirement for tax and accounting records (Income Tax Law Cap. 297, VAT Law N.95(I)/2000 as in force). The platform enforces it as a hard floor; no API path allows reduction below 7 years post-deactivation.

Rules:
- While a business is active (`is_active = true`), no operational data is deleted.
- When a business is deactivated (`is_active = false` on the `business_entities` row), the 7-year retention clock starts.
- A nightly background job (`data.run_retention_sweep`) identifies businesses deactivated more than 7 years ago and marks their operational rows for soft-deletion.
- Soft-deleted rows enter a **30-day grace period** before hard-deletion. During the grace period, an Owner or platform admin may reactivate the business to cancel the deletion.
- After the 30-day grace period, rows are hard-deleted by a separate hard-delete job.
- Legal-hold check: before any hard-deletion, the retention engine calls the legal-hold hook (`legalHoldHook(business_id)`). If a hold is active, deletion is deferred and `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` is emitted. See Block 04 Phase 11 for the legal-hold mechanism.

---

## Archive zone

**Bucket:** `archive-bundles`.

Retention: **6 years default** (Cyprus VAT/books baseline) with **per-business override** via `retention_policies_schema`. The override is monotonically non-decreasing through the application API — see `retention_policies_schema.md` §4 for the update RPC and `admin_retention_override_runbook.md` for the narrow shortening path under compliance approval.

Archive bundles are sealed, Object-Locked Supabase Storage objects per `object_lock_integration.md`. Object Lock COMPLIANCE mode sets the retention-until-date at promotion time from the business's `retention_policies.retention_years` value; the platform enforces the floor — even platform admin cannot shorten an existing bundle's retention. After the bundle's Object Lock retention has expired AND no active legal hold blocks deletion, the `retention_engine` role is authorized to delete the bundle. Application user roles never have direct deletion access.

Attempting to delete an object in `archive-bundles` outside the sanctioned retention-engine path returns an error from Supabase Storage. The platform does not expose a deletion UI or API for this bucket to application roles. Any detection of a missing expected archive object before its retention has expired triggers `ARCHIVE_TAMPER_DETECTED` (BLOCKING) per Block 05 Phase 03.

---

## Export temp

**Bucket:** `export-temp`.

Retention: **24 hours TTL**.

Temporary signed-URL downloads for exported reports, CSV files, and accountant packs are staged in this bucket. Supabase Storage lifecycle rules auto-expire objects after 24 hours without any application code involvement. Users who need a file after 24 hours must re-generate the export.

The 24-hour window is intentionally short to limit the time window for signed-URL abuse. Signed URLs for `export-temp` objects are single-use where the export pipeline supports it; see `export_pipeline_policy` for the signed-URL generation details.

---

## Audit log

Retention: **permanent; append-only**.

The audit log rows in the `audit_log` table and the `audit_log_hash_chain` table are never deleted under any circumstance. No DELETE policy exists on either table for any role including platform admin. No scheduled purge job targets these tables.

This is unconditional. GDPR erasure requests do not delete audit log rows; they pseudonymize personal data fields in audit payloads per Block 05 Phase 09 (`GDPR_PSEUDONYMIZED`). The hash chain's integrity depends on the completeness of every row in sequence; deletion would break the chain.

The physical storage growth of the audit log is managed by Supabase's table partitioning strategy (Block 05 Phase 02) — partitions are archived to cold storage but remain queryable. The cold-storage replica is a Stage 2+ concern; for MVP, all audit rows remain on the primary.

---

## Session tokens

Retention: **30 days after session expiry**.

`user_sessions` rows where `expires_at < now() - interval '30 days'` are hard-deleted by the session-purge job (runs nightly). The 30-day window provides a forensic lookback for recent-session security investigations without accumulating unbounded session history.

Revoked sessions are also subject to the same 30-day post-expiry purge. The `revoked_at` timestamp does not start a separate clock; the `expires_at` timestamp governs the purge boundary.

---

## Step-up MFA tokens

Retention: **1 hour after use or expiry, whichever occurs first**.

Step-up MFA tokens (`step_up_tokens` table, Block 02 Phase 06) are purged within 1 hour of the earlier of: the token's `expires_at` timestamp or the `consumed_at` timestamp. A dedicated purge job runs every 15 minutes and hard-deletes eligible rows. The short window limits the attack surface for replayed step-up tokens while retaining enough history for the audit log to record consumption. The `STEP_UP_TOKEN_CONSUMED` audit event is emitted before the row is purged; the audit record persists permanently.

---

## Enforcement mechanisms summary

| Data | Mechanism | Operator |
| --- | --- | --- |
| Processing zone | Scheduled job (every 4 hours) | `data.purge_processing_zone` |
| Operational zone (soft-delete) | Nightly job + 30-day grace | `data.run_retention_sweep` |
| Operational zone (hard-delete) | Nightly job post-grace | `data.run_hard_delete` |
| Export temp | Storage lifecycle rule (auto) | Supabase Storage; no application code |
| Audit log | No mechanism (permanent) | — |
| Session tokens | Nightly job | `auth.purge_expired_sessions` |
| Step-up MFA tokens | 15-minute job | `auth.purge_expired_step_up_tokens` |

Scheduled jobs use Postgres advisory locks to prevent concurrent execution. All deletion events are audit-logged with the number of rows/objects affected.

---

## Legal hold interaction

A legal hold (`LEGAL_HOLD_SET` on a business) suspends all scheduled deletions for that business across all zones except export-temp (which is never audit-critical). The hold is checked before every deletion sweep. See Block 04 Phase 11 for the full legal-hold mechanism.

---

## Cross-references

- `storage_bucket_configuration` — bucket names, Object Lock settings, lifecycle rule configuration
- `data_layer_conventions_policy` — canonical JSON, identifier conventions used in deletion sweep queries
- `soft_delete_vs_status_policy` — `is_active` semantics and the relationship between soft-delete and hard-delete
- `audit_log_policies` — audit log permanent-retention rule; GDPR pseudonymization as the alternative to deletion
- `Docs/phases/04_data_architecture/10_retention_engine.md` — nightly retention engine implementation
- `Docs/phases/04_data_architecture/11_legal_hold.md` — legal hold mechanism that suspends scheduled deletions
- `Docs/phases/05_security_and_audit/09_gdpr_data_subject_rights.md` — GDPR pseudonymization path for audit log personal data

Right-to-erasure requests under GDPR Article 17 are handled via pseudonymization in the Operational zone; Audit log entries are exempt from erasure per Article 17(3)(b) (legitimate interest override / legal obligation) and the hash-chain integrity requirement — see `audit_log_policies` for the pseudonymization path.
