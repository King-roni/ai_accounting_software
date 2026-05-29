# Runbook: Monitoring and Alerting

**Block:** Infrastructure / Operations
**Layer:** 2 — Sub-Doc
**Status:** Draft · **Last updated:** 2026-05-17

## Overview

This runbook describes what is monitored, how alerts are configured, the alert channels
by severity, and the on-call rotation structure. The goal is to ensure that degradation in
any critical system component is detected and escalated before it impacts user-facing
operations or data integrity.

---

## What Is Monitored

### Supabase Database Metrics

| Metric                   | Collection interval | Notes                                       |
|--------------------------|--------------------|--------------------------------------------|
| Active DB connections    | 30s                | Via `pg_stat_activity` count               |
| Max connection pool size | 30s                | PgBouncer pool max_client_conn             |
| Connection utilisation % | 30s                | Derived: active / max * 100                |
| Query latency P50        | 1m                 | Via `pg_stat_statements`                   |
| Query latency P99        | 1m                 | Via `pg_stat_statements`                   |
| Slow query count (>1s)   | 5m                 | Queries with `mean_exec_time > 1000ms`     |
| Storage used (GB)        | 5m                 | Supabase storage metrics API               |
| Storage limit (GB)       | 5m                 | From project plan limits                   |
| Storage utilisation %    | 5m                 | Derived: used / limit * 100                |
| Replication lag          | 1m                 | Read replica lag in milliseconds           |

### Edge Function Error Rates

Each deployed Edge Function is monitored independently.

| Metric                        | Collection interval | Notes                               |
|-------------------------------|--------------------|------------------------------------|
| Invocation count              | 1m                 | Total calls per function            |
| Error count                   | 1m                 | HTTP 5xx and unhandled exceptions   |
| Error rate %                  | 1m                 | Derived: errors / invocations * 100 |
| P99 invocation duration (ms)  | 1m                 |                                     |
| Cold start count              | 5m                 |                                     |

Monitored functions: `classify_document`, `bank_sync_webhook`, `vat_recalculate`,
`archive_bundle`, `report_generate`, `gdpr_erase`.

### Bank Sync Job Health

The bank sync integration runs on a scheduled interval. The following are monitored:

| Metric                        | Notes                                                    |
|-------------------------------|----------------------------------------------------------|
| Last successful sync timestamp | Alert if > expected interval + 10 minute grace period   |
| Sync job status               | RUNNING, COMPLETED, FAILED per bank connection           |
| Transaction ingestion count   | Alert if count drops to 0 for > 24 hours                 |
| Consecutive failure count     | Alert at 3 consecutive failures                          |

### Archive Integrity Job Results

The archive integrity job runs nightly. Results are written to `archive_integrity_results`.

| Metric                        | Notes                                                    |
|-------------------------------|----------------------------------------------------------|
| Job completion status         | COMPLETED or FAILED                                      |
| Bundles checked count         | Alert if < expected bundle count (indicates skipped run) |
| Hash mismatches found         | Alert immediately if count > 0                           |
| Missing bundles count         | Alert if count > 0                                       |

---

## Alert Thresholds

| Metric                              | Threshold                    | Severity | Action           |
|-------------------------------------|------------------------------|----------|------------------|
| DB connection utilisation           | > 80%                        | SEV-1    | Page on-call     |
| DB connection utilisation           | > 60%                        | SEV-3    | Slack alert      |
| Query latency P99                   | > 5,000 ms                   | SEV-2    | Slack alert      |
| Query latency P99                   | > 10,000 ms                  | SEV-1    | Page on-call     |
| Slow query count (>1s)              | > 10 per 5m window           | SEV-3    | Slack alert      |
| Storage utilisation                 | > 80%                        | SEV-2    | Slack alert      |
| Storage utilisation                 | > 95%                        | SEV-1    | Page on-call     |
| Edge Function error rate            | > 5% over 5m window          | SEV-2    | Slack alert      |
| Edge Function error rate            | > 20% over 5m window         | SEV-1    | Page on-call     |
| Bank sync last success              | > interval + 10m             | SEV-2    | Slack alert      |
| Bank sync consecutive failures      | >= 3                         | SEV-1    | Page on-call     |
| Archive integrity failure           | Any FAILED result            | SEV-1    | Page on-call     |
| Archive hash mismatch               | count > 0                    | SEV-1    | Page on-call     |
| Replication lag                     | > 30,000 ms                  | SEV-2    | Slack alert      |
| Replication lag                     | > 120,000 ms                 | SEV-1    | Page on-call     |

---

## Alert Channels

### SEV-1 and SEV-2 — PagerDuty

SEV-1 and SEV-2 alerts route to PagerDuty. PagerDuty enforces the on-call rotation (see
On-Call Rotation section below).

- SEV-1 alerts: immediate phone call + push notification + SMS. Escalates to secondary
  on-call after 5 minutes without acknowledgement.
- SEV-2 alerts: push notification + SMS. Escalates to secondary on-call after 15 minutes
  without acknowledgement.

PagerDuty service: [Link placeholder — configure in PagerDuty dashboard]
PagerDuty integration key: stored in Supabase Vault as `pagerduty_integration_key`.

### SEV-3 and SEV-4 — Slack

SEV-3 and SEV-4 alerts route to the `#alerts-infra` Slack channel. No paging. These alerts
require acknowledgement within 4 hours during business hours (09:00–18:00 CET).

- SEV-3: requires a response in the thread with initial assessment within 4 hours.
- SEV-4: informational; no response required but should be reviewed at next standup.

Slack webhook URL: stored in environment variable `SLACK_ALERTS_WEBHOOK_URL`.

### Severity Definitions

| Severity | Definition                                                                      |
|----------|---------------------------------------------------------------------------------|
| SEV-1    | Production data integrity risk, or complete service outage                      |
| SEV-2    | Significant degradation affecting > 20% of requests or a critical background job |
| SEV-3    | Degradation affecting < 20% of requests, or a non-critical job failure          |
| SEV-4    | Informational threshold breach; no user impact expected                         |

---

## Dashboard Links

| Dashboard                      | URL                                                    |
|-------------------------------|--------------------------------------------------------|
| Supabase project metrics      | [Placeholder — Supabase dashboard > Metrics]           |
| Edge Function logs            | [Placeholder — Supabase dashboard > Edge Functions]    |
| PgBouncer pool stats          | [Placeholder — configure in monitoring stack]          |
| Archive integrity results     | [Placeholder — internal admin panel > Archive]         |
| Bank sync job status          | [Placeholder — internal admin panel > Bank Sync]       |
| PagerDuty incident timeline   | [Placeholder — PagerDuty > Incidents]                  |

Replace placeholders with live URLs once monitoring infrastructure is provisioned.

---

## On-Call Rotation

The on-call rotation covers 24/7 response for SEV-1 and SEV-2 alerts.

**Rotation structure:**
- One primary on-call engineer per week.
- One secondary on-call engineer per week (different person from primary).
- Rotation changes every Monday at 09:00 CET.
- Minimum 72-hour rest period before re-entering on-call rotation.

**Responsibilities during on-call week:**
- Acknowledge PagerDuty alerts within 5 minutes (SEV-1) or 15 minutes (SEV-2).
- Open an incident in the `#incidents` Slack channel within 10 minutes of acknowledgement.
- Follow the relevant runbook for the alerted condition.
- Escalate to the secondary if the primary cannot respond within escalation window.
- Write a brief post-incident note in the `#incidents` thread on resolution.

**Handoff:** Primary hands off to the incoming primary each Monday. The outgoing primary
provides a summary of any open or recently resolved incidents.

On-call roster is managed in PagerDuty under the `boekhouding-oncall` schedule.
[Placeholder — link to PagerDuty schedule]

---

## Related Documents

- `runbooks/supabase_outage_runbook.md` — full Supabase outage response
- `runbooks/archive_promotion_failure_runbook.md` — archive integrity failures
- `runbooks/bank_statement_live_integration_runbook.md` — bank sync integration
- `runbooks/cross_tenant_alerting_runbook.md` — cross-tenant alert scenarios
- `runbooks/dr_restore_runbook.md` — disaster recovery and restore procedures
