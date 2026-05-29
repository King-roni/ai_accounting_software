# Infrastructure Cutover Runbook

**Scope:** Production infrastructure cutover — DNS, load balancer, database connection strings, Supabase project URL.
**Owning team:** Infrastructure / SRE
**Severity classification:** P0 — execution errors can cause prolonged downtime
**Cross-ref:** `dr_restore_runbook.md`, `secrets_management_policy.md`

---

## Overview

This runbook covers the end-to-end procedure for cutting over production infrastructure to a new environment — a new Supabase project, a new hosting region, or a replacement stack after a disaster recovery event. It includes pre-cutover preparation, the cutover execution sequence, post-cutover verification, and the rollback procedure.

Required approvals before starting: **Infrastructure Lead sign-off** and **CTO sign-off** for any production cutover.

Estimated planned downtime: 10–20 minutes. Maximum acceptable window before triggering rollback: 30 minutes.

---

## Pre-Cutover Checklist

Complete every item and mark it done before opening the maintenance window.

### Infrastructure Readiness

- [ ] New environment health check passes (all services respond 200 on `/health`)
- [ ] SSL certificate issued and valid for all target domains (check `openssl s_client` output)
- [ ] Load balancer target group populated with new instances; health checks green
- [ ] DNS TTL reduced to 60 seconds at least 48 hours before cutover window
- [ ] Current DNS TTL confirmed as 60 seconds (run `dig +short <domain>` and verify TTL field)

### Database Readiness

- [ ] New database connection strings tested from application layer (staging environment)
- [ ] Database migration scripts applied to new DB and verified with schema diff
- [ ] Row counts match between old and new DB for all critical tables (automated check script: `scripts/db_rowcount_compare.sh`)
- [ ] Read replica lag < 5 seconds on new DB cluster
- [ ] Database connection pool configured: max 80 connections, min 5, idle timeout 300s

### Supabase-Specific Readiness

- [ ] New Supabase project URL confirmed and tested
- [ ] Connection pooler (PgBouncer) configured on new project; test connection string works
- [ ] All Supabase Edge Functions deployed to new project (`supabase functions deploy --project-ref <new-ref>`)
- [ ] Storage bucket policies copied from old project and verified
- [ ] Supabase Vault secrets re-populated in new project (do not copy; re-enter from secrets manager)
- [ ] RLS policies verified: run `scripts/rls_smoke_test.sh` against new project
- [ ] Auth providers (Google OAuth) reconfigured with new project's callback URLs
- [ ] Supabase anon key and service role key updated in Vercel environment variables (staging first)

### Application Layer

- [ ] Environment variables updated in Vercel (or CI/CD) to point to new Supabase project URL
- [ ] Vercel deployment preview with new env vars tested and verified
- [ ] Feature flags in their expected state for production cutover
- [ ] Background job scheduler (cron) paused on old environment

### Communication

- [ ] Maintenance window announcement sent to all active users (email + in-app banner) at least 24 hours before
- [ ] Status page updated to "Scheduled Maintenance" with window start/end times
- [ ] On-call SRE confirmed available for the full window plus 2 hours post-cutover

---

## Cutover Procedure

Execute steps in order. Do not skip steps. Record timestamps for each step.

### Step 1 — Open Maintenance Window (T+0:00)

1. Post maintenance window open notification to status page.
2. Enable maintenance mode in the application (`MAINTENANCE_MODE=true` environment variable, redeploy).
3. Confirm that new requests return HTTP 503 with maintenance page.
4. Wait 60 seconds for in-flight requests to drain (check `active_connections` on old DB, wait until < 5).

### Step 2 — Stop Background Jobs (T+0:02)

1. Pause the workflow run scheduler: set `scheduler.enabled = false` in the admin config table.
2. Confirm no new `workflow_runs` rows are being inserted (query: `SELECT count(*) FROM workflow_runs WHERE created_at > now() - interval '30 seconds'`).
3. Allow any RUNNING runs to complete or time out (max wait: 5 minutes). Runs still RUNNING after 5 minutes are force-cancelled with `ENGINE_RUN_HELD` event emitted.

### Step 3 — Database Connection Swap (T+0:07)

1. Update `DATABASE_URL` in Vercel (or CI/CD secrets) to point to new database connection pooler string.
2. Update `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to new project values.
3. Trigger a Vercel deployment to pick up new environment variables.
4. Confirm deployment succeeds (Vercel dashboard build log shows green).

### Step 4 — Supabase Edge Function Re-Deploy (T+0:10)

1. Run `supabase functions deploy --project-ref <new-project-ref>` for all edge functions.
2. Verify each function returns 200 on its health endpoint.
3. Confirm Vault secrets are accessible: run `scripts/vault_smoke_test.sh <new-project-ref>`.

### Step 5 — DNS Cutover (T+0:13)

1. Update DNS A record(s) (and CNAME for CDN-fronted domains) to point to new load balancer / Vercel deployment.
2. TTL is already 60 seconds from pre-cutover preparation.
3. Verify new DNS propagation: `dig +short <domain>` should return new IP within 2 minutes.

### Step 6 — Health Check (T+0:15)

1. Run `scripts/post_cutover_health_check.sh` — covers: API `/health`, DB connectivity, Supabase auth, Vault access, Edge Function ping.
2. All checks must pass before proceeding.
3. If any check fails, immediately trigger the Rollback Procedure.

### Step 7 — Restore Traffic (T+0:17)

1. Disable maintenance mode (`MAINTENANCE_MODE=false`, redeploy).
2. Re-enable background job scheduler (`scheduler.enabled = true`).
3. Post "Maintenance complete" update to status page.
4. Monitor error rate on new environment for 15 minutes (< 0.1% error rate is acceptable threshold).

---

## Post-Cutover Verification Checklist

Complete within 30 minutes of traffic restore.

- [ ] API error rate < 0.1% over 15-minute window
- [ ] P99 API latency < 2000 ms
- [ ] No `ENGINE_RUN_CREATION_REJECTED_*` events in audit log (would indicate scheduler misconfiguration)
- [ ] At least one background run completes successfully (trigger a test run if needed)
- [ ] Supabase Edge Functions responding correctly (check logs in Supabase dashboard)
- [ ] Old environment traffic confirmed at zero (check load balancer access logs)
- [ ] SSL certificate on new environment shows correct expiry (at least 60 days remaining)
- [ ] Storage bucket: confirm existing objects are accessible via new project URL
- [ ] Notify CTO that cutover is complete and monitoring is in progress

---

## Rollback Procedure

Execute if any post-cutover check fails or error rate exceeds threshold within the 30-minute rollback window.

**Rollback window:** 30 minutes from Step 7 (traffic restore). After 30 minutes, a rollback requires a full re-cutover back to the old environment using this same runbook.

1. Enable maintenance mode on new environment immediately.
2. Revert DNS records to old load balancer / Vercel deployment.
3. Revert `DATABASE_URL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` in Vercel to old values.
4. Trigger Vercel deployment with old env vars.
5. Verify old environment health check passes (`scripts/post_cutover_health_check.sh` against old config).
6. Disable maintenance mode on old environment.
7. Re-enable background job scheduler on old environment.
8. Post incident update to status page.
9. File incident report within 24 hours documenting root cause and corrective action.

---

## Communication Templates

### Maintenance Window Announcement (send 24 hours before)

```
Subject: Scheduled Maintenance — [DATE] [START TIME] to [END TIME] CET

We will be performing infrastructure maintenance on [DATE] from [START TIME] to [END TIME] CET.

During this window, the platform will be unavailable. No data will be lost. All in-progress work will be preserved and available when the platform returns.

We expect the downtime to last approximately 20 minutes within the scheduled window. We will post updates on our status page at [STATUS_PAGE_URL].

If you have time-sensitive work, please complete it before [START TIME - 1 hour] CET.
```

### Maintenance Window Open (post to status page at T+0:00)

```
Maintenance window is now open. Platform is in maintenance mode. Expected completion: [END TIME] CET.
```

### Maintenance Complete (post to status page at T+0:17)

```
Maintenance complete. Platform is fully operational. All services restored. Thank you for your patience.
```

---

## SLA Impact

Planned maintenance windows are excluded from monthly uptime SLA calculations per the platform Terms of Service, provided:
- At least 24 hours advance notice is given.
- The window does not exceed 4 hours.
- No more than 2 planned windows occur per calendar month.

An unplanned cutover (e.g., triggered by DR_RESTORE) counts against the SLA. File an incident report and apply any applicable SLA credits per the customer agreement.

---

## Required Approvals

| Role | Approval required for |
|---|---|
| Infrastructure Lead | All production cutovers |
| CTO | Production cutovers; any cutover with estimated downtime > 15 minutes |
| On-call SRE | Confirms readiness to execute; no veto authority |

Approvals must be recorded in the incident/change management system (Linear ticket or equivalent) before the maintenance window opens. Verbal approvals are not sufficient.

---

## Related Documents

- `dr_restore_runbook.md` — disaster recovery restore procedure (references this runbook at lines 23, 142, 182)
- `secrets_management_policy.md` — secret re-population procedure for new environments
- `audit_event_taxonomy.md` — ENGINE events emitted during run hold/cancel
