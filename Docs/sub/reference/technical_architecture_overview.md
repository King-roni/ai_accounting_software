# Technical Architecture Overview

**Block:** reference
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This document provides a high-level technical architecture reference for the Cyprus bookkeeping SaaS platform. It describes the technology stack, system topology, data flow through the processing pipeline, key design decisions, scalability approach, security perimeter, monitoring stack, and disaster recovery posture. It is the entry point for engineers unfamiliar with the system and the authoritative source for cross-cutting architectural decisions.

For operational runbooks, see the individual runbooks referenced in the Related Documents section. For schema-level details, see the schema sub-docs. For security policy details, see the policies directory.

## Technology Stack

| Layer | Technology | Role |
|---|---|---|
| Frontend | Next.js (App Router) | Server-side rendered React application; deployed on Vercel |
| Hosting | Vercel | Edge network hosting for the Next.js frontend; handles CDN, SSL termination, and preview deployments |
| Backend — Database | Supabase (PostgreSQL) | Primary relational database; Row-Level Security for multi-tenant isolation |
| Backend — Auth | Supabase Auth | JWT-based authentication; email/password + OAuth; MFA via TOTP |
| Backend — Storage | Supabase Storage | Binary file storage for bank statements, OCR inputs, and generated PDFs |
| Backend — Compute | Supabase Edge Functions (Deno) | All server-side business logic; the only layer that executes outside the database |
| Payments | Stripe Connect | Payment intent creation, webhook delivery for payment confirmation |
| Email | Resend | Transactional email delivery (invoice dispatch, notifications, password reset) |
| Archive Storage | AWS S3 (Object Lock COMPLIANCE) | Long-term immutable archive of finalized accountant packs and signed PDF bundles |
| Error Tracking | Sentry | Runtime error capture and alerting for both frontend and Edge Functions |
| DDoS / WAF | Cloudflare | Network-level protection in front of Vercel and Supabase API endpoints |

### Dependency Notes

Supabase serves as the central integration hub: the database, auth system, and file storage are all operated within a single Supabase project. Edge Functions are also deployed via Supabase. This reduces the number of external service integrations and keeps all data-adjacent compute within the same trust boundary.

AWS S3 is used exclusively for the Archive zone. No operational data lives in S3. The separation keeps the compliance-grade immutable archive decoupled from the day-to-day Supabase operational layer.

## System Topology

```
                        +------------------+
                        |   Cloudflare     |
                        |  (WAF / DDoS)    |
                        +--------+---------+
                                 |
                    +------------+-------------+
                    |                          |
          +---------+--------+      +----------+---------+
          |  Vercel Edge     |      |  Supabase API      |
          |  (Next.js SSR)   |      |  (REST + Realtime) |
          +---------+--------+      +----------+---------+
                    |                          |
                    |            +-------------+-------------+
                    |            |             |             |
                    |    +-------+------+ +----+----+ +------+-----+
                    |    | Supabase     | | Supa-   | | Supabase   |
                    |    | Edge Funcs   | | base    | | Storage    |
                    |    | (Deno)       | | Auth    | |            |
                    |    +-------+------+ +----+----+ +------+-----+
                    |            |             |             |
                    |            +------+------+             |
                    |                   |                    |
                    |           +-------+--------+           |
                    |           |  PostgreSQL    |           |
                    |           |  (RLS + pgvec) |           |
                    |           +----------------+           |
                    |                                        |
          +---------+--------+                    +----------+---------+
          |  Stripe Connect  |                    |  AWS S3            |
          |  (Payments)      |                    |  (Archive zone)    |
          +------------------+                    +--------------------+
                    |
          +---------+--------+
          |  Resend          |
          |  (Email)         |
          +------------------+
```

**Request path for a typical API call:**

1. Client browser or mobile app sends request to the Next.js frontend on Vercel.
2. Vercel Edge routes API calls to Supabase Edge Functions via the Supabase project URL.
3. Edge Functions execute business logic, validate inputs, enforce authorization, and interact with Postgres via the Supabase service client.
4. Postgres enforces RLS for all queries. Service-role queries bypass RLS only for internal system operations (scheduled jobs, audit writes) and never for user-facing data access.
5. Results return through the same path.

**Stripe webhook path:**

Stripe sends webhook events to a dedicated Supabase Edge Function endpoint. The function validates the Stripe signature, processes the event (typically a payment confirmation), and updates the database. No Stripe events are handled in the Next.js layer.

**Archive write path:**

When a run is finalized, the Edge Function constructs the accountant pack, uploads it to Supabase Storage (for immediate access), and then promotes the bundle to AWS S3 with Object Lock COMPLIANCE mode enabled. The S3 write is the final step of finalization.

## Data Flow: Processing Pipeline

The core processing pipeline for a bookkeeping run follows eight stages. Each stage is implemented as one or more Edge Functions (tools).

```
1. INTAKE
   Bank statement uploaded → validated → stored in Supabase Storage (Processing zone)

2. PARSE
   Raw file → parsed rows → bank_statement_rows table (Processing zone)

3. CLASSIFY
   Each row → AI classification + rule-based classification → classification_output
   Confidence scoring → rows below threshold → review queue

4. MATCH
   Classified transactions → matched against invoices/payments
   Match proposals generated → confirmed or escalated to review queue

5. LEDGER
   Confirmed matches → double-entry ledger postings (ledger_entries table)
   VAT entries generated per Cyprus VAT rules

6. VAT
   Ledger entries aggregated → VAT return computed → vat_return table
   VIES submissions prepared for EU intra-community transactions

7. FINALIZE
   All phases complete → finalization gate check
   PDF bundle generated → hash chain updated → archive bundle constructed

8. ARCHIVE
   Archive bundle → Supabase Storage (immediate access)
              → AWS S3 Object Lock COMPLIANCE (permanent immutable copy)
```

Data in the Processing zone (stages 1–4) is deleted 7 days after run completion or cancellation. Data from stage 5 onward persists in the Operational zone for 7 years. The archive bundle (stage 8) is permanent. See `data_retention_policy.md` for full zone definitions.

## Key Design Decisions

### Multi-tenancy via business_id + RLS

All user-facing tables include a `business_id` column that references `business_entities(id)`. Supabase RLS policies on every table enforce that authenticated users can only access rows where `business_id` matches a business they are an active member of. There is no application-level tenant routing — the database enforces isolation.

This design was chosen over schema-per-tenant (too complex to manage) and database-per-tenant (not supported by Supabase at the pricing tier). The trade-off is that a misconfigured RLS policy could expose cross-tenant data. To mitigate this, all RLS policies are reviewed on every schema migration and tested with a dedicated RLS test suite.

### No PII in JWT Claims

JWT tokens issued by Supabase Auth contain only the user's UUID (`sub` claim) and standard JWT fields. No email address, business ID, role, or other PII is embedded in the token. All user-facing API calls that require business context supply the business ID in the request body or URL parameter; the Edge Function validates membership via a database lookup.

This design prevents stale JWT data from being acted upon (e.g., if a user's role changes, the next database query reflects the updated role rather than a cached claim) and reduces PII exposure in logs that capture JWT payloads.

### All Financial Data in EUR Pivot

All monetary amounts stored in the database are in EUR, regardless of the original transaction currency. Foreign currency transactions are converted at the time of ledger posting using ECB reference rates (see `ecb_fx_rate_cache_reference.md`). The original currency and original amount are stored alongside the EUR-converted amounts for audit purposes.

This design simplifies VAT reporting (all Cyprus VAT returns are in EUR) and eliminates multi-currency arithmetic at query time. The trade-off is that historical FX conversions are locked in at the rate used at posting time.

### Edge Functions as the Only Server-Side Compute Layer

All business logic runs in Supabase Edge Functions (Deno runtime). The Next.js layer is responsible only for rendering and routing. It does not connect directly to the database or execute business logic.

This design keeps the trust boundary clear: Edge Functions hold the service-role key; the Next.js layer holds only the anon key and user JWT. It also ensures that all data access goes through the same authorization and audit path, whether triggered by a user action or a scheduled job.

### Primary Key Generation

All tables use `gen_uuid_v7()` for primary keys, which generates time-ordered UUIDs. This improves B-tree index locality for append-heavy tables and allows approximate creation-order sorting without a separate `created_at` index scan.

Exceptions that use `gen_random_uuid()` (fully random UUID v4): session IDs, password-reset tokens, invitation tokens, step-up tokens, OAuth state parameters. These values are used as bearer tokens in URLs or cookies; time-ordered generation would leak the relative creation time of security tokens, which is an unnecessary information disclosure.

## Scalability Considerations

### Database Connection Pooling

Supabase Edge Functions connect to PostgreSQL via **pgBouncer** in transaction pooling mode. This allows many concurrent Edge Function invocations to share a smaller pool of database connections, which is critical given that Edge Functions are stateless and spin up per request.

The pool size is configured based on observed peak concurrency. Connection pool exhaustion is monitored and alerted. If pool exhaustion becomes a recurring issue, the mitigation is to increase the pool size or reduce query latency.

### Read Replicas for Reporting

Heavy reporting queries (period comparisons, audit log searches, dashboard aggregations) are routed to Supabase read replicas when available. Write operations always go to the primary. The Edge Function layer handles read/write routing. This prevents reporting workloads from contending with transactional write throughput.

### S3 for Binary Storage

Bank statement files, generated PDFs, and archive bundles are stored in object storage (Supabase Storage or AWS S3), not in the database. Storing binary data in the database would inflate relation sizes, slow down backups, and consume connection bandwidth. Object storage handles binary retrieval more efficiently and scales independently of the database.

### Stateless Edge Functions

Edge Functions are stateless by design. Each invocation is independent. Long-running operations (e.g., full run processing) are decomposed into phases, each with a separate Edge Function invocation. Run state is persisted to the database between phase transitions, enabling resumption after failures without re-processing completed phases.

## Security Perimeter

### Service Role Key

The Supabase `service_role` key bypasses RLS and has full database access. It is stored only in Edge Function environment secrets (Supabase Vault). It is never exposed to the Next.js frontend, never included in client-side code, and never logged. All client-side Supabase calls use the `anon` key plus user JWT, which is subject to RLS.

### Secrets Management

All secrets (Stripe keys, AWS credentials, Resend API key, Sentry DSN, internal signing keys) are stored in Supabase Vault and injected into Edge Function environments at runtime. No secrets are stored in environment variable files, version control, or deployment manifests. See `secrets_management_policy.md`.

### Cloudflare

Cloudflare sits in front of both Vercel and the Supabase API endpoint. It provides DDoS mitigation, bot detection, and WAF rules. Cloudflare is configured to pass the client IP in a verified header to the origin for rate limiting and IP allowlist enforcement. See `ip_allowlist_policy.md` and `rate_limiting_policy.md`.

### MFA and Step-Up Auth

All users are encouraged to enroll in TOTP-based MFA per `mfa_policy.md`. Certain high-risk operations (archive access, run finalization approval, data export) require step-up authentication even for users with active MFA sessions. Step-up tokens are short-lived and single-use. See `step_up_auth_for_workflow_approval_policy.md`.

### Audit Log

All security-relevant and financially-relevant operations are written to the append-only audit log. The audit log is never modified or deleted. It is replicated to S3 as part of the archive zone for long-term retention. See `audit_log_schema.md` and `audit_log_policies.md`.

## Monitoring Stack

| Component | Tool | Purpose |
|---|---|---|
| Application errors | Sentry | Runtime exception capture in Edge Functions and Next.js; alerting on error rate spikes |
| Frontend analytics | Vercel Analytics | Page load performance, Web Vitals, traffic patterns |
| Database metrics | Supabase Dashboard | Connection pool utilization, query latency, replication lag |
| Custom audit dashboards | Internal (Supabase + Retool) | Audit event trend monitoring, anomaly detection on financial operations |
| Uptime monitoring | Supabase built-in + external | API endpoint availability; alerting on downtime |
| S3 replication health | AWS CloudWatch | Object replication status, storage metrics, Object Lock compliance checks |

Sentry is configured to scrub PII from error payloads before capture. Error messages, stack traces, and request context are included; request bodies are excluded for endpoints that handle financial or personal data.

## Disaster Recovery

### Recovery Objectives

| Metric | Target | Basis |
|---|---|---|
| RTO (Recovery Time Objective) | < 4 hours | Time from confirmed outage to restored service |
| RPO (Recovery Point Objective) | < 1 hour | Maximum data loss window |

These targets apply to the Operational zone (database and Supabase Storage). The Archive zone (S3 Object Lock) has a separate RTO of < 24 hours given that archived data is not required for day-to-day operations.

### Backup Strategy

**Supabase database:** Daily point-in-time recovery (PITR) backups are enabled on the Supabase project. The backup window allows restoration to any point within the last 7 days. For PRO and higher Supabase tiers, PITR granularity is configurable down to the minute. Backup files are retained by Supabase in geographically separated storage.

**Supabase Storage (binary files):** Supabase Storage files are backed up as part of the Supabase project backup. For critical in-progress files (bank statements for running runs), the backup RPO of < 1 hour is met by the Supabase PITR schedule.

**AWS S3 Archive:** S3 archive buckets are configured with cross-region replication to a secondary AWS region. Object Lock COMPLIANCE mode prevents deletion or modification of archived objects. Archive data is effectively immutable and does not require recovery — it is always available from either the primary or replica region.

### Restore Procedure

The restore procedure is documented in `dr_restore_runbook.md`. The high-level steps are:

1. Confirm the nature and scope of the incident (data corruption, infrastructure failure, or security incident).
2. For infrastructure failure: trigger Supabase project restore from the most recent clean backup.
3. For data corruption: identify the corruption point using the audit log, restore to a point-in-time before corruption, and replay audit log events to reconstruct the delta.
4. Validate restored data integrity using the hash chain verification tool.
5. Resume service after validation sign-off from a senior engineer and the security team lead.

For security incidents involving potential data breach, the restore procedure is paused pending a forensic snapshot per the incident response runbook.

## Related Documents

- `policies/data_retention_policy.md` — Data zone definitions and retention periods
- `policies/secrets_management_policy.md` — Secret storage and rotation
- `policies/row_level_security_policies.md` — RLS implementation patterns
- `policies/encryption_at_rest_policy.md` — Encryption standards
- `policies/rate_limiting_policy.md` — Rate limit configuration
- `policies/ip_allowlist_policy.md` — IP allowlist enforcement
- `policies/mfa_policy.md` — MFA enrollment requirements
- `policies/step_up_auth_for_workflow_approval_policy.md` — Step-up auth policy
- `policies/audit_log_policies.md` — Audit log guarantees
- `reference/audit_log_query_guide.md` — How to query the audit log
- `reference/supabase_auth_integration_guide.md` — Auth integration details
- `reference/supabase_rls_policy_map.md` — Full RLS policy inventory
- `reference/error_code_catalog.md` — System-wide error codes
- `schemas/audit_log_schema.md` — Audit log table DDL
- `schemas/business_schema.md` — Business entities table DDL
