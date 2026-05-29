# Supabase Storage Quota Runbook

**Block:** Infrastructure
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook covers detection, triage, and resolution when Supabase Storage is
approaching or has reached its plan quota. Supabase Storage is the object store used
by all four storage zones. Exceeding the quota causes upload failures across document
intake, archive promotion, and export generation. This runbook does not cover bucket
permission errors or object-level failures — see `archive_promotion_failure_runbook.md`
for those.

Storage zones and their growth profiles:

- **processing-zone** — raw uploaded documents awaiting OCR and classification. Small by
  design: a scheduled TTL job purges objects older than 7 days. Average steady-state
  size for a mid-sized tenant cluster: 200–500 MB.
- **archive-zone** — finalized archive bundles (RFC 3161-stamped ZIP files). Grows
  permanently. No TTL. This zone will consume the most quota long-term.
- **operational-zone** — thumbnails, processed previews, and working copies. Moderate
  size; objects are deleted when their parent document is deleted.
- **export-temp** — exports generated for download. Auto-purges after 24 hours via
  scheduled job. Should remain near zero outside of peak export periods.

---

## Step 1 — Detect

### Alert Sources

1. **Supabase Dashboard — Storage Usage Gauge**
   Navigate to: Project → Storage → Usage. Quota consumption is displayed as a
   percentage bar. Investigate when usage exceeds 70%.

2. **Scheduled Monitoring Job Alert**
   The platform runs a `storage_quota_alert` scheduled job every 6 hours. It calls the
   Supabase Management API and emits a `STORAGE_QUOTA_WARNING` audit event when usage
   exceeds the configured threshold (default: 80%). The event appears in the
   `audit_events` table and triggers a Slack notification to `#alerts-infra`.

3. **Upload Failures in Sentry**
   Errors of class `StorageApiError` with message `Bucket storage limit exceeded` or
   `Upload quota reached` in the intake or archive-promotion tools indicate that the
   quota has been hit. These are BLOCKING failures for the affected tenants.

### Confirm the Alert Is Real

```bash
# Query Supabase Management API for storage stats
curl -s "https://api.supabase.com/v1/projects/$PROJECT_REF/storage" \
  -H "Authorization: Bearer $SUPABASE_MGMT_TOKEN" \
  | jq '{total_bytes: .total_bytes, quota_bytes: .quota_bytes, pct_used: (.total_bytes / .quota_bytes * 100)}'
```

If `pct_used` is above 80, proceed with triage. If below 80, the alert may be a false
positive from the monitoring job; verify the threshold configuration.

---

## Step 2 — Bucket-by-Bucket Breakdown

Identify which zone is consuming the most storage before taking action.

```bash
# List all buckets with approximate sizes via Supabase Management API
curl -s "https://api.supabase.com/v1/projects/$PROJECT_REF/storage/buckets" \
  -H "Authorization: Bearer $SUPABASE_MGMT_TOKEN" \
  | jq '.[] | {name: .name, size_bytes: .size}'
```

Expected breakdown for a healthy deployment:

| Bucket          | Expected Size  | Growth Profile     | TTL Policy       |
|-----------------|----------------|--------------------|------------------|
| processing-zone | < 1 GB         | Near-zero (TTL)    | 7 days           |
| archive-zone    | Grows annually | ~50 MB/business/yr | None (permanent) |
| operational     | Low–moderate   | Slow               | On doc delete    |
| export-temp     | Near-zero      | Spikes briefly     | 24 hours         |

If `processing-zone` is unexpectedly large (> 2 GB), the TTL purge job has likely
stalled. If `export-temp` is large (> 1 GB), the export cleanup job has stalled.
If `archive-zone` is the primary driver, the system is growing as expected — see
Step 4 for capacity planning.

### Check for Orphaned Objects

Objects without a corresponding database row can accumulate from failed transactions.

```sql
-- Find processing-zone objects older than 7 days (should have been purged)
SELECT
  name,
  created_at,
  metadata->>'size' AS size_bytes
FROM storage.objects
WHERE bucket_id = 'processing-zone'
  AND created_at < now() - INTERVAL '7 days'
ORDER BY created_at ASC
LIMIT 50;
```

```sql
-- Estimate per-business archive-zone usage
SELECT
  d.business_entity_id,
  COUNT(*) AS bundle_count,
  SUM((so.metadata->>'size')::bigint) AS total_bytes
FROM archive_bundles ab
JOIN storage.objects so ON so.name = ab.storage_path
WHERE so.bucket_id = 'archive-zone'
GROUP BY d.business_entity_id
ORDER BY total_bytes DESC
LIMIT 20;
```

---

## Step 3 — Emergency Actions

Take these steps when usage is above 90% or uploads are actively failing.

### Force-Run Export Cleanup Job

The export cleanup job purges `export-temp` objects older than 24 hours. Run it
manually if it has stalled.

```bash
curl -X POST "$SUPABASE_URL/functions/v1/scheduled-job-runner" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"job_name": "export_temp_cleanup", "triggered_by": "manual_quota_emergency"}'
```

Verify the result: `export-temp` bucket size should drop to near zero within 2 minutes.

### Force-Run Processing Zone TTL Purge

The processing-zone TTL purge runs nightly. Force it manually:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/scheduled-job-runner" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"job_name": "processing_zone_ttl_purge", "triggered_by": "manual_quota_emergency"}'
```

The job deletes all `processing-zone` objects whose corresponding `documents` row has
`processing_completed_at` set, or whose `created_at` is older than 7 days regardless
of status.

### Audit Events Emitted by Emergency Purge

Both jobs emit `STORAGE_PURGE_COMPLETED` on success and `STORAGE_PURGE_FAILED` on
failure. Confirm presence in `audit_events` before declaring the action complete.

### Temporary Upload Block for Largest Tenants

If quota is above 95% and you cannot free space quickly, consider temporarily blocking
new uploads from the largest `archive-zone` consumers by revoking their storage RLS
policy. Document the restriction and notify affected business owners immediately.
Restore access as soon as quota headroom is available.

---

## Step 4 — Long-Term Capacity Planning

### archive-zone Growth Projection

The archive-zone is the only zone with unbounded permanent growth.

Projection formula:

```
projected_annual_growth_bytes = active_business_count × 52_428_800  (50 MB per business per year)
```

This 50 MB/business/year figure assumes:
- Average 200 documents per business per year.
- Average 250 KB per finalized archive bundle (compressed ZIP).

Actual figures vary by business size. Run the per-business query in Step 2 monthly and
compare against this baseline.

### Multi-Tenant Capacity Model

```sql
-- Current quota consumption trajectory (monthly snapshots)
SELECT
  date_trunc('month', created_at) AS month,
  COUNT(DISTINCT ab.business_entity_id) AS active_businesses,
  SUM((so.metadata->>'size')::bigint) AS bytes_added
FROM archive_bundles ab
JOIN storage.objects so ON so.name = ab.storage_path
WHERE so.bucket_id = 'archive-zone'
GROUP BY 1
ORDER BY 1 ASC;
```

Use this output to project when the current quota will be exhausted. If the trend shows
quota exhaustion within 90 days, initiate a quota increase request (Step 5) immediately.

### Quota Upgrade Thresholds

| Usage Level | Action                                           |
|-------------|--------------------------------------------------|
| > 70%       | Log, monitor monthly                             |
| > 80%       | Open Supabase support ticket for upgrade quote   |
| > 90%       | Execute emergency actions, escalate to support   |
| > 95%       | Consider temporary upload restrictions           |

---

## Step 5 — Escalation to Supabase Support

If emergency purge actions do not free sufficient space, or if the archive-zone is
the primary driver and cannot be reduced, request a storage quota increase.

### Steps

1. Log in to Supabase Dashboard → Support → Create Ticket.
2. Category: **Storage** / **Quota Increase**.
3. Include in the ticket body:
   - Project reference ID.
   - Current usage (bytes used, quota limit, percentage).
   - Per-bucket breakdown.
   - Projected growth over 12 months (use the trajectory query output).
   - Requested new quota (recommend requesting 2× current to avoid repeat escalation).
4. For Pro and Team plan projects, quota increases are typically processed within 1
   business day. For Free plan projects, upgrade to Pro is required before a quota
   increase is available.

### While Waiting for Quota Increase

- Monitor storage every 30 minutes using the Management API check from Step 1.
- If uploads are failing, prioritise archive-zone for future quota — operational and
  export-temp uploads are lower priority.
- Consider enabling object compression at the application layer for new archive bundles
  if average bundle size exceeds 500 KB (consult `archive_bundle_file_manifest.md`).

---

## Post-Incident

After the immediate crisis is resolved:

1. Verify both TTL jobs are running on schedule.
2. Lower the monitoring threshold from 80% to 70% if this incident was first detected
   above 80%.
3. Update the capacity projection spreadsheet with current per-business averages.
4. File an ADR amendment if storage quotas are changed — record the new baseline in
   `reference/architecture_decision_records.md` under ADR-005.

---

## Related Documents

- `/Docs/sub/runbooks/supabase_outage_runbook.md`
- `/Docs/sub/runbooks/archive_promotion_failure_runbook.md`
- `/Docs/sub/runbooks/archive_restore_runbook.md`
- `/Docs/sub/reference/archive_bundle_file_manifest.md`
- `/Docs/sub/reference/supabase_project_config.md`
- `/Docs/sub/reference/architecture_decision_records.md`
