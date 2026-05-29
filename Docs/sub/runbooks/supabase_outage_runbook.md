# Supabase Outage Runbook

**Block:** engine
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook covers detection, immediate response, impact assessment, recovery, and
post-outage procedures for a Supabase service degradation or complete outage. Supabase
provides the platform's primary database (PostgreSQL), authentication (GoTrue), object
storage, and Edge Functions runtime. Full or partial unavailability of these services
causes cascading failures across all product features.

This runbook distinguishes four failure domains:
- **Database** — Postgres read/write unavailable or timing out.
- **Auth** — Login, session refresh, and user management unavailable.
- **Storage** — File upload, download, and listing unavailable.
- **Edge Functions** — Serverless function execution failing or timing out.

---

## Step 1 — Detect

### Primary Detection Sources

1. **Supabase Status Page**: https://status.supabase.com
   - Check for active incidents affecting your project's region.
   - Subscribe to status notifications (email or webhook) if not already configured.

2. **Sentry Error Rate Dashboard**
   - Filter by error class `ConnectionError`, `TimeoutError`, `PostgrestError`.
   - A spike in these errors originating from Supabase client calls confirms the failure.

3. **Vercel Function Error Rates**
   - In Vercel dashboard: Deployments → Functions → Error Rate.
   - Errors from `/api/*` routes exceeding 5% within a 5-minute window should trigger
     manual investigation.

4. **Synthetic Health Check**
   - The platform runs a synthetic health check every 60 seconds via a cron-triggered
     Edge Function that executes `SELECT 1` and records latency.
   - If this check fails 3 consecutive times, a Slack alert is sent to `#alerts-infra`.

### Distinguish Failure Domain

```bash
# Database health check
curl -X POST "$SUPABASE_URL/rest/v1/rpc/health_check" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ANON_KEY"
# Expected: {"result": "ok"}

# Auth health check
curl "$SUPABASE_URL/auth/v1/health" \
  -H "apikey: $ANON_KEY"
# Expected: {"status": "ok"}

# Storage health check
curl "$SUPABASE_URL/storage/v1/health" \
  -H "apikey: $ANON_KEY"
# Expected: {"status": "healthy", ...}

# Edge Function health check (call a lightweight ping function)
curl "$SUPABASE_URL/functions/v1/ping" \
  -H "Authorization: Bearer $ANON_KEY"
# Expected: {"pong": true}
```

### Distinguish Partial vs Full Outage

| Response Pattern                          | Likely Failure Domain   |
|-------------------------------------------|-------------------------|
| Database timeout, Auth OK, Storage OK     | Database only           |
| Auth 500/503, DB OK                       | Auth (GoTrue) only      |
| Storage 500/503, DB and Auth OK           | Storage only            |
| All Edge Function calls time out or 503   | Edge Functions runtime  |
| All health checks fail                    | Full platform outage    |

---

## Step 2 — Immediate Response

### Set Maintenance Mode

The platform uses a Vercel environment variable to enable maintenance mode. When set,
all incoming requests receive a 503 response with a maintenance page rather than
attempting database calls that will fail.

1. Open Vercel dashboard → Project Settings → Environment Variables.
2. Set `MAINTENANCE_MODE=true` for the Production environment.
3. Trigger a redeployment (or use Vercel's instant rollout for env var changes).
4. Verify maintenance page is served:

```bash
curl -I https://your-production-domain.com/api/runs
# Expected: HTTP/2 503
# X-Maintenance-Mode: true
```

Alternatively, use Vercel CLI:

```bash
vercel env add MAINTENANCE_MODE true production
vercel --prod
```

### Notify Active Users

Post to the platform status page (status.yourplatform.com) within 10 minutes of
confirming an outage. Template:

```
[Investigating] We are aware of an issue affecting [database / login / file upload /
processing]. Our team is investigating. No data has been lost. Updates every 15 minutes.
Last updated: HH:MM UTC.
```

Send email notification to business entity admin contacts if downtime exceeds 30 minutes.
Do not send push notifications for outages under 10 minutes.

### Pause Scheduled Tasks

All CRON jobs that trigger run processing, VAT calculation, analytics refresh, and
webhook delivery must be paused to prevent them accumulating failed attempts.

```bash
# Pause all scheduled tasks via the platform admin API
curl -X POST "$PLATFORM_ADMIN_URL/api/scheduled-tasks/pause-all" \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"reason": "Supabase outage — automatic pause", "paused_by": "on-call-engineer"}'
```

Log the pause timestamp. You will need it for Step 5 (post-outage missed-job replay).

---

## Step 3 — Impact Assessment

### Feature Impact Matrix

| Feature                        | DB | Auth | Storage | Edge Fn | Degraded When |
|--------------------------------|----|------|---------|---------|---------------|
| Login / Session refresh        | -  | X    | -       | -       | Auth down     |
| Document upload / intake       | X  | X    | X       | X       | Any           |
| Run processing (all phases)    | X  | -    | X       | X       | DB or EF      |
| Invoice creation / editing     | X  | X    | -       | X       | DB or Auth    |
| VAT filing submission          | X  | X    | X       | X       | Any           |
| Audit log viewer               | X  | X    | -       | -       | DB or Auth    |
| File download (docs/archive)   | -  | X    | X       | -       | Auth or Stor  |
| Dashboard / analytics          | X  | X    | -       | X       | DB or EF      |
| API key management             | X  | X    | -       | -       | DB or Auth    |

### SLA Impact Calculation

Track outage duration from first confirmed unavailability to service restoration. Record:

- `outage_start`: first confirmed error timestamp (from Sentry or Supabase status page).
- `maintenance_mode_start`: when 503 responses began serving to users.
- `recovery_start`: when Supabase reports service restored.
- `maintenance_mode_end`: when `MAINTENANCE_MODE=false` is deployed.

```
Effective user-facing downtime = maintenance_mode_end - maintenance_mode_start
```

Monthly SLA calculation:

```
SLA% = ((total_minutes_in_month - effective_downtime_minutes) / total_minutes_in_month) × 100
```

If SLA falls below committed threshold (e.g., 99.9% = 43.8 minutes/month), trigger
SLA breach notification to affected enterprise accounts.

### Monitoring Query — Runs Affected During Outage

```sql
-- Find runs that were mid-phase during the outage window
SELECT
  r.id,
  r.status,
  r.current_phase,
  r.updated_at,
  r.business_entity_id
FROM runs r
WHERE r.status IN ('RUNNING', 'FINALIZING', 'COMPENSATING')
  AND r.updated_at BETWEEN '<outage_start>' AND '<recovery_time>'
ORDER BY r.updated_at ASC;
```

These runs may be stuck. After recovery, process them using `run_stuck_in_status_runbook.md`.

---

## Step 4 — Recovery

### Verify Supabase Service Restoration

Do not disable maintenance mode before verifying each affected service is healthy.

```bash
# Full health verification sequence
echo "=== Database ==="
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/health_check" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ANON_KEY"

echo "=== Auth ==="
curl -s "$SUPABASE_URL/auth/v1/health" -H "apikey: $ANON_KEY"

echo "=== Storage ==="
curl -s "$SUPABASE_URL/storage/v1/health" -H "apikey: $ANON_KEY"

echo "=== Edge Functions ==="
curl -s "$SUPABASE_URL/functions/v1/ping" -H "Authorization: Bearer $ANON_KEY"
```

All four must return healthy responses before proceeding.

### Re-enable Service

1. Set `MAINTENANCE_MODE=false` in Vercel and redeploy.
2. Verify the platform returns 200 responses on critical routes.
3. Confirm login flow works end-to-end (test account).
4. Confirm document upload works (upload test file).
5. Trigger a test run for an internal business entity to verify full processing pipeline.

### Run Missed Scheduled Jobs

Resume the scheduled task queue:

```bash
curl -X POST "$PLATFORM_ADMIN_URL/api/scheduled-tasks/resume-all" \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"resumed_by": "on-call-engineer", "outage_reference": "INCIDENT-2026-05-17"}'
```

For jobs that were due during the outage window and were not run, check the missed-job
log and trigger them manually if they are time-sensitive (VAT submission windows, period
end analytics refresh).

### Verify Audit Log Integrity

```sql
-- Check for audit log gaps during outage window (no events for extended period)
SELECT
  date_trunc('minute', created_at) AS minute_bucket,
  count(*) AS event_count
FROM audit_events
WHERE created_at BETWEEN '<outage_start>' AND '<recovery_time>'
GROUP BY 1
ORDER BY 1 ASC;
```

A gap in audit log events during the outage is expected and acceptable — the system was
not processing. Verify that events resume normally after `recovery_time`.

---

## Step 5 — Post-Outage

### Check for Data Inconsistency

Runs that were mid-phase during the outage may be in inconsistent states. Use the
detection query from Step 3 to enumerate them, then follow
`run_stuck_in_status_runbook.md` for each.

Priority order for unstuck recovery:
1. FINALIZING runs — closest to completion, highest user impact if stuck.
2. COMPENSATING runs — rollback in progress, must complete to restore consistency.
3. RUNNING runs — can typically be retried from current phase.

### Review Queued Webhooks

Webhook delivery attempts that failed during the outage are queued for retry. Verify
the webhook retry queue is draining:

```sql
SELECT
  status,
  count(*) AS count,
  min(created_at) AS oldest
FROM webhook_deliveries
WHERE status IN ('PENDING', 'FAILED')
  AND created_at > '<outage_start>'
GROUP BY status;
```

If more than 200 webhooks are pending, consider notifying integration partners that
delayed webhook delivery occurred during the incident window.

### Communication Templates

**Status page resolution update:**
```
[Resolved] The issue affecting [database / login / file upload / processing] has been
resolved. Service has been fully restored as of HH:MM UTC. All queued tasks are
processing normally. We are conducting a post-incident review and will publish a
summary within 24 hours. We apologise for the inconvenience.
```

**Enterprise account email:**
```
Subject: Service Disruption Summary — [Date]

Between [HH:MM UTC] and [HH:MM UTC] on [date], [Platform Name] experienced a service
disruption due to a degradation in our infrastructure provider (Supabase). During this
window, [describe affected features]. Total user-facing downtime was approximately
[N] minutes.

All data is intact. No data was lost or corrupted during the incident.

[Detail any SLA credit applicable per customer contract.]

Contact [support email] with any questions.
```

### Update SLA Metrics

Record the outage in the SLA tracking sheet with:
- Incident ID, start time, end time, affected services, root cause (Supabase / infra).
- User-facing downtime in minutes.
- Whether SLA threshold was breached.
- Actions taken to prevent recurrence.

### Supabase Support Ticket

If the outage lasted more than 30 minutes, file a support ticket with Supabase:
- Include project reference ID (from Supabase dashboard).
- Include the time window.
- Include a description of impact.
- Reference the Supabase status page incident if one was raised.

This ticket provides documentation for SLA credit claims against Supabase's own SLA
commitments to the platform.

---

## Related Documents

- `/Docs/sub/runbooks/run_stuck_in_status_runbook.md`
- `/Docs/sub/reference/supabase_auth_integration_guide.md`
- `/Docs/sub/reference/supabase_rls_policy_map.md`
- `/Docs/sub/runbooks/archive_promotion_failure_runbook.md`
- `/Docs/sub/runbooks/dr_restore_runbook.md`
