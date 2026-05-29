# Backup and Recovery Policy

**Category:** Policies · **Owning block:** 05 — Security, Audit & Compliance · **Stage:** 4 sub-doc (Layer 2)

This policy defines the backup strategy, retention rules, restore procedures, and recovery
objectives for the platform's Supabase-hosted database. All infrastructure engineers and on-call
responders are bound by these rules.

---

## 1. Scope

This policy covers:

- The Supabase Postgres database (all schemas: `public`, `auth`, `storage`).
- Supabase Auth metadata (managed by Supabase; included in the database backup).

This policy does **not** cover:

- Object Storage buckets (`processing-zone`, `archive-zone`, `export-temp`). See Section 6.
- In-flight Processing zone data (see Section 7).
- Application-level caches or transient queue state.

---

## 2. Backup mechanism

Supabase Pro provides continuous Write-Ahead Log (WAL) archiving with Point-in-Time Recovery
(PITR) enabled. Backups are taken at the storage level and are managed entirely by Supabase.
No application-level dump jobs are run in addition to Supabase's native PITR.

PITR means that the database can be restored to any second within the retention window,
not just to daily snapshot boundaries.

---

## 3. Retention

| Backup type | Retention period | Managed by |
|---|---|---|
| PITR continuous WAL | 30 days | Supabase (Pro plan) |
| Daily logical snapshots | 30 days (included in PITR coverage) | Supabase (Pro plan) |

After 30 days, WAL segments are purged by Supabase automatically. There is no archival tier for
database backups beyond 30 days. Data retention for business records beyond 30 days is achieved
at the application layer via the `archive-zone` Object Storage bucket, not via database backups.

---

## 4. Recovery Time Objective and Recovery Point Objective

| Metric | Target |
|---|---|
| RPO (Recovery Point Objective) | 24 hours |
| RTO (Recovery Time Objective) | 4 hours |

RPO is set to 24 hours because PITR covers the full 30-day window; in practice, recovery can
target any point within the last 30 days with second-level precision. The 24-hour figure is the
worst-case commitment in the event that PITR metadata is unavailable and recovery must fall back
to the most recent daily snapshot.

RTO is 4 hours. This covers: Supabase restore initiation (estimated 30–90 minutes for large
databases), DNS propagation update, connection string update in environment variables, application
smoke tests, and on-call sign-off. The 4-hour clock starts from incident declaration, not from
the time of failure detection.

---

## 5. Restore procedure

### 5a. Point-in-time restore via Supabase dashboard

1. Log into the Supabase dashboard at `https://supabase.com/dashboard`.
2. Select the project.
3. Navigate to **Settings → Database → Backups**.
4. Select **Point in Time Recovery**.
5. Choose the target date and time (UTC). Confirm the target is within the 30-day window.
6. Enter the confirmation string and initiate the restore.
7. Monitor restore progress. The project will be offline during restore.
8. On completion, run the smoke-test suite (`pnpm test:smoke`) against the restored instance.

### 5b. Restore via Supabase CLI

For scripted or automated recovery:

```bash
supabase db restore --project-ref <PROJECT_REF> --target-time <ISO8601_TIMESTAMP>
```

The CLI restore requires the `SUPABASE_ACCESS_TOKEN` with `project:admin` scope.
Store this token in the secrets manager; do not hard-code it in scripts.

### 5c. Post-restore validation checklist

After any restore, the on-call engineer must verify:

- [ ] Row counts on `transactions`, `ledger_entries`, `invoices` match pre-incident expectation.
- [ ] Latest `audit_logs` entries are intact up to the recovery point.
- [ ] `period_locks` table reflects the correct locked state.
- [ ] RLS helper functions (`rls_get_business_id`, `rls_get_user_id`) return correct values.
- [ ] `SUPABASE_URL` environment variable in all Edge Functions points to the restored instance.
- [ ] At least one end-to-end smoke test passes for each workflow type (IN, OUT).

---

## 6. Object Storage: archive-zone and processing-zone

**archive-zone** objects (finalized archive bundles) are permanent. Supabase Object Storage does
not delete them unless explicitly instructed by an application call. Because archive bundles are
immutable and permanent by design, they are not separately backed up via database backup or PITR.
Archive bundle integrity is instead protected by the SHA-256 manifest hash stored in
`archive_bundles.manifest_hash` — restoring the database gives you the manifest; the object
remains in the bucket.

**processing-zone** and **export-temp** objects have TTL-based deletion rules configured on the
bucket (see `supabase_project_config`). They are not backed up. Loss of these objects due to a
database restore to an earlier point-in-time is expected behaviour; any in-flight workflow run
affected will be placed into `FAILED` status during post-restore reconciliation.

---

## 7. In-flight Processing zone data

Processing zone files have a maximum TTL of 7 days. They are not covered by the backup policy
and are explicitly excluded from RTO/RPO commitments. If a restore targets a point in time earlier
than the upload timestamp of an in-flight file, the workflow run record will reference a file that
no longer exists in the database. The `engine.gate_intake` validation step will fail that run
on next execution, triggering the standard `FAILED` state and notifying the business owner.

---

## 8. Backup test schedule

A restore drill is conducted monthly. The drill validates the end-to-end restore procedure on a
non-production clone of the Supabase project.

| Activity | Frequency | Owner | Record location |
|---|---|---|---|
| PITR restore to non-prod clone | Monthly | Infrastructure on-call | `runbooks/backup_restore_drill_log.md` |
| Post-restore validation checklist | Each drill | Infrastructure on-call | Same as above |
| RTO measurement | Each drill | Infrastructure on-call | Logged as `INFRA_BACKUP_DRILL_COMPLETED` audit event |

If a drill fails to complete within the 4-hour RTO, it is escalated to a HIGH severity issue and
the root cause must be resolved before the next monthly cycle.

---

## 9. Backup monitoring and alerting

Supabase sends backup failure alerts to the configured project notification email. This email must
resolve to the infrastructure team's alert channel. Backup failure alerts are treated as HIGH
severity and trigger the on-call rotation immediately.

No application-level monitoring of backup health is implemented at this time. Reliance is placed
on Supabase's own backup monitoring infrastructure. If Supabase backup failure notifications are
not received for more than 48 hours, the on-call engineer must manually verify backup status in
the Supabase dashboard.

---

## Related Documents

- `supabase_project_config` — project-level settings, bucket TTL rules, environment variable names
- `storage_bucket_configuration` — processing-zone, archive-zone, export-temp bucket definitions
- `archive_verification_policy` — archive bundle integrity verification and manifest hash checks
- `data_retention_policy` — 7-year application-layer retention obligations
- `zone_promotion_policy` — Processing zone to archive zone promotion rules
- `secrets_management_policy` — `SUPABASE_ACCESS_TOKEN` storage for CLI restore
- `runbooks/backup_restore_drill_log` — monthly drill records
