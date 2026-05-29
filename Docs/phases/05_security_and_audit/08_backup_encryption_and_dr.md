# Block 05 — Phase 08: Backup Encryption & DR

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Backup & Recovery section)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 07 archive — high-priority backup target)
- Decisions log: `Docs/decisions_log.md` (EU only; backup encryption keys overlap transition per Phase 07)

## Phase Goal

Stand up the backup and disaster-recovery layer: encrypted backups with keys distinct from production, EU cross-region backup storage, scheduled restore tests, and integrity-verified restoration that re-checks both the audit-log hash chain and archive-bundle hashes before treating restored data as authoritative.

## Dependencies

- Phase 03 (chain verification — invoked on restore)
- Phase 04 (Vault — backup keys live in their own hierarchy, distinct from production DEKs)
- Phase 07 (secrets management — backup encryption keys with overlap-style rotation)
- Block 04 Phase 07 (archive schema and `archive-bundles` bucket — backup targets)
- Block 04 Phase 08 (`archiveBundleHash` for integrity verification on restore)

## Deliverables

- **Backup pipeline:**
  - Postgres: scheduled `pg_dump`-based full backups daily + WAL-based incrementals hourly. Backups cover the operational schema, the `archive` schema, and the `audit` schema.
  - Storage: `archive-bundles` and `raw-uploads` bucket contents replicated cross-region within the EU.
  - Backup metadata table `backup_records` — `id`, `source` (`postgres`, `storage_bucket_name`), `period_start`, `period_end`, `bytes`, `backup_hash`, `encryption_key_id`, `created_at`.
- **Backup encryption:**
  - Distinct key hierarchy from production DEKs (the backup key category in Phase 07).
  - Backups encrypted before write; the encryption key id is recorded on the `backup_records` row so restoration can fetch the right key.
  - Overlap-style transition during rotation (per Phase 07): backups taken during the transition window are readable with either the old or the new key.
- **Cross-region EU storage:**
  - Backups stored in a different EU region from production for resilience.
  - Replication is asynchronous; lag is monitored and alerts fire (Phase 10) when lag exceeds threshold.
- **Restore procedure (multi-party authorisation):**
  - Production restore requires Owner + a second authorised user, both with step-up.
  - Pre-restore: backup integrity verified (`backup_hash` matches re-computed hash; encryption key resolves; decryption succeeds on a sample).
  - During restore: data is written to a quarantine namespace; the production schemas are not overwritten until verification passes.
  - Post-restore: re-verify the audit log hash chain (Phase 03's `chain integrity verification`); re-verify archive bundle hashes (`archiveBundleHash` against the restored bundles' content).
  - On verification pass: promote quarantine to production (one-shot atomic switch).
  - On verification fail: restore is rejected and the audit chain remains intact; the original production data is unaffected.
- **Scheduled restore tests:**
  - Weekly: automated restore of the latest backup into a test environment + integrity check.
  - Monthly: full DR drill — production-equivalent restore with chain re-verification.
  - Outcomes audit-logged regardless of pass/fail.
- **Audit events:** `BACKUP_STARTED`, `BACKUP_COMPLETED`, `BACKUP_FAILED`, `BACKUP_REPLICATION_LAG_EXCEEDED`, `RESTORE_INITIATED`, `RESTORE_QUARANTINE_LOADED`, `RESTORE_VERIFICATION_PASSED`, `RESTORE_VERIFICATION_FAILED`, `RESTORE_PROMOTED_TO_PRODUCTION`, `RESTORE_REJECTED`, `RESTORE_TEST_PASSED`, `RESTORE_TEST_FAILED`, `DR_DRILL_COMPLETED`.

## Definition of Done

- Daily Postgres backups + hourly WAL replays succeed.
- Cross-region replication of `archive-bundles` and `raw-uploads` is active and observable.
- A test restore into a test environment completes successfully and passes both the chain-verification and archive-hash-verification checks.
- A simulated tampered backup (deliberately corrupted) is rejected with the right audit events; production data is not modified.
- The weekly restore test runs and emits its outcome to the audit log.
- An overlap-window backup taken during a key rotation is readable with both the old and new keys.

## Sub-doc Hooks (Stage 4)

- **Backup cadence sub-doc** — exact schedules per source, retention of older backups, cleanup policy.
- **Cross-region setup sub-doc** — Supabase region choices, replication mechanism, lag thresholds.
- **Restore runbook sub-doc** — step-by-step production-restore procedure, multi-party-auth flow, rollback if verification fails.
- **DR drill procedure sub-doc** — monthly drill scope, success criteria, post-drill review.
- **Backup-key overlap sub-doc** — exact key-resolution logic during overlap windows, readability test.
