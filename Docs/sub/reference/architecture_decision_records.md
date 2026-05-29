# Architecture Decision Records

**Block:** Cross-cutting / Platform
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

Architecture Decision Records (ADRs) document significant design choices, the context
in which they were made, the alternatives considered, and the consequences of the
chosen approach. ADRs are immutable once accepted — if a decision is reversed, a new
ADR superseding the old one is created rather than editing this document.

Format: each ADR has a title, date, status, context, decision, and consequences.
Status values: `PROPOSED`, `ACCEPTED`, `DEPRECATED`, `SUPERSEDED`.

---

## ADR-001: Use Supabase as the Backend Platform

**Date:** 2025-09-01
**Status:** ACCEPTED

### Context

The platform required a PostgreSQL database, authentication service, file storage,
serverless function runtime, and real-time subscriptions. Options evaluated:

1. **Self-managed PostgreSQL** on a cloud VM with a separate auth library (e.g. Auth.js),
   separate object storage (S3), and a separate serverless compute platform.
2. **Supabase** — a managed backend-as-a-service built on PostgreSQL with integrated
   auth (GoTrue), object storage, Edge Functions (Deno), and a real-time engine.
3. **Firebase (Google)** — a NoSQL document database with integrated auth and storage.
   Rejected early because it does not support relational queries, ACID transactions, or
   Row Level Security, all of which are required for multi-tenant financial data.

The team had strong PostgreSQL expertise and needed RLS-based multi-tenancy, ACID
transactions for double-entry bookkeeping, and long-term WORM storage for compliance.

### Decision

Use Supabase as the primary backend platform. PostgreSQL provides the relational model
and RLS. GoTrue provides authentication with MFA. Supabase Storage provides the four
storage zones. Edge Functions provide the tool execution runtime.

### Consequences

- **Positive:** Significant reduction in infrastructure management overhead. RLS is
  enforced at the database layer, eliminating an entire class of application-level
  multi-tenancy bugs. Integrated auth reduces custom session management code.
- **Positive:** Supabase's managed PostgreSQL handles backups, point-in-time recovery,
  and failover automatically.
- **Negative:** Dependency on a single vendor. Supabase outages affect all platform
  services simultaneously. Mitigated by the DR restore runbook and the Supabase outage
  runbook.
- **Negative:** Edge Functions run on Deno, not Node.js. Some npm packages are not
  compatible. Developers must use Deno-compatible imports or ESM equivalents.
- **Watch:** Supabase Storage Object Lock (WORM) support must be confirmed per project
  region before finalising the archive-zone configuration. See ADR-006.

---

## ADR-002: gen_uuid_v7() for Business Primary Keys

**Date:** 2025-09-15
**Status:** ACCEPTED

### Context

The platform needs primary keys for all business entity tables. Three options were
evaluated:

1. **Sequential integer IDs (`BIGSERIAL`)** — simple, compact, naturally ordered. But
   they leak row count information to clients and create cross-table collision risk if
   IDs are ever exposed.
2. **gen_random_uuid() (UUIDv4)** — universally unique, no information leakage. But
   random UUIDs fragment B-tree indexes and produce poor insert performance at scale
   because new rows are inserted at random positions in the index, causing page splits.
3. **gen_uuid_v7() (UUIDv7)** — universally unique, encodes timestamp in the high bits,
   making it monotonically sortable. Avoids the index fragmentation of UUIDv4 while
   retaining the non-guessability of UUID. Requires a custom PostgreSQL function
   (available as an extension or pure SQL implementation).

All public-facing identifiers must be non-sequential to avoid enumeration attacks.

### Decision

Use `gen_uuid_v7()` as the default primary key generator for all tables that represent
business entities (runs, documents, invoices, ledger entries, audit events, etc.).
`gen_random_uuid()` is used only for non-PK identifiers (e.g. webhook delivery IDs,
one-time tokens) where time ordering provides no benefit.

### Consequences

- **Positive:** B-tree index inserts are sequential in time order, reducing page splits
  and improving write performance at scale.
- **Positive:** `ORDER BY id` is equivalent to `ORDER BY created_at` for most practical
  purposes, simplifying many list queries.
- **Positive:** IDs are non-guessable and non-sequential, preventing enumeration.
- **Negative:** UUIDv7 is not yet a PostgreSQL built-in. The platform requires a custom
  `gen_uuid_v7()` function. This function must be present in every environment
  (production, staging, local). The schema migration that creates it must run before any
  table creation migrations.

---

## ADR-003: Append-Only Audit Log with Hash Chain

**Date:** 2025-10-01
**Status:** ACCEPTED

### Context

The platform processes financial data subject to Cyprus tax law, which requires a
tamper-evident audit trail for at least 7 years. Options evaluated:

1. **Mutable audit records** — standard table rows that can be updated or deleted.
   Simple to implement, but any database administrator or compromised service role key
   can silently alter audit history.
2. **Append-only audit log with application-level protections** — no UPDATE/DELETE
   permitted on `audit_events`, enforced by RLS. Prevents accidental modification but
   does not detect a compromise of the service role key.
3. **Append-only audit log with hash chain** — as above, plus each event stores the
   SHA-256 hash of the previous event's hash concatenated with the current event's
   canonical JSON. Any post-insertion modification of any event will break the hash
   chain for all subsequent events. Chain breaks are detectable by the audit chain
   verification job.

### Decision

Implement an append-only audit log with a three-level hash chain (global, per-org,
per-business). The `audit_events` table has no UPDATE or DELETE RLS policy — not even
the service role. Chain verification runs as a scheduled job and emits `AUDIT_CHAIN_BREAK`
(BLOCKING severity) on any detected discrepancy.

### Consequences

- **Positive:** Any tampering with audit records is detectable, satisfying the
  tamper-evident requirement for financial compliance.
- **Positive:** Provides strong evidence of data integrity in any regulatory or legal
  inquiry.
- **Negative:** The audit log cannot be corrected retroactively. If an event is emitted
  with incorrect payload data, a compensating event must be appended. The incorrect
  event remains in the chain.
- **Negative:** Hash chain computation adds a small amount of latency to every audit
  write. Benchmarked at < 2 ms per event; acceptable for current throughput.
- **Watch:** The hash chain function must be called within the same transaction as the
  event insert. If the insert succeeds but the hash update fails, the chain breaks.
  The tool framework enforces this transactional coupling.

---

## ADR-004: Row-Level Security for Multi-Tenancy

**Date:** 2025-10-15
**Status:** ACCEPTED

### Context

The platform is multi-tenant: each organisation and business entity's data must be
strictly isolated. Options evaluated:

1. **Separate database per tenant** — complete isolation, but operationally complex
   and expensive. Each tenant requires their own Supabase project, connection pool,
   and migration management.
2. **Application-level tenancy filtering** — a shared database where every query
   includes a `WHERE business_entity_id = ?` clause enforced by the application. Simple
   to implement but relies entirely on the application code being correct. A single
   missing WHERE clause leaks cross-tenant data.
3. **Row Level Security (RLS) in PostgreSQL** — the database itself enforces row
   visibility based on the session's JWT claims. Application code cannot bypass RLS
   without using the service role key. Cross-tenant leakage requires a deliberate
   security bypass, not an accidental missing WHERE clause.

### Decision

Use PostgreSQL Row Level Security as the primary multi-tenancy enforcement layer. Every
table storing business data has RLS policies that restrict SELECT, INSERT, UPDATE, and
DELETE to rows matching the authenticated user's `business_entity_id` claims. The
`service_role` key bypasses RLS and is used only in Edge Functions for administrative
operations that legitimately need cross-tenant access.

### Consequences

- **Positive:** Cross-tenant data leakage requires an explicit security bypass, not an
  accidental application bug. This substantially reduces the blast radius of application
  code defects.
- **Positive:** RLS policies are auditable as database schema objects, not distributed
  across application code files.
- **Negative:** RLS policies are harder to test than application-layer filters. The
  RLS debugging runbook (`supabase_rls_debugging_runbook.md`) is required reading for
  all backend developers.
- **Negative:** Complex queries that join across business entities (e.g., platform-wide
  analytics) must use the service role key or a dedicated analytics schema with
  explicit access controls.

---

## ADR-005: Processing Zone 7-Day TTL

**Date:** 2025-11-01
**Status:** ACCEPTED

### Context

Raw uploaded documents (PDFs, images, CSVs) are stored in the processing zone during
OCR, parsing, and classification. Once processing is complete, the document data is
stored in the database and the processed representation is in the operational zone. The
raw object in the processing zone is redundant after processing and contributes to
storage quota consumption.

Options evaluated:

1. **Keep raw objects permanently** — no TTL. Simple, and raw objects are available for
   reprocessing if the parsing algorithm improves. But unbounded growth creates storage
   cost and compliance risk (raw documents may contain PII that should not be retained
   indefinitely without specific purpose).
2. **Delete immediately after processing** — raw objects are deleted once
   `processing_completed_at` is set. Minimal storage usage. But if a processing bug
   is discovered shortly after completion, the raw object is gone and cannot be
   reprocessed.
3. **7-day TTL** — raw objects are retained for 7 days after upload, then purged
   regardless of processing status. This gives a recovery window for reprocessing in
   the event of a near-term bug, while bounding the storage footprint.

### Decision

Implement a 7-day TTL on the processing zone. A nightly scheduled job (`processing_zone_ttl_purge`)
deletes objects older than 7 days. The TTL applies uniformly; there is no extension for
objects still in `PROCESSING` status at day 7 — such objects are treated as failed
intake and a review issue is created.

### Consequences

- **Positive:** Processing zone stays small in steady state, limiting storage quota
  consumption by this bucket.
- **Positive:** PII in raw documents is not retained beyond the processing window,
  reducing data minimisation risk.
- **Negative:** Reprocessing raw documents is only possible within the 7-day window.
  After that, the user must re-upload the original file.
- **Watch:** If the TTL purge job stalls, the processing zone will grow unboundedly
  until the issue is caught. The storage quota runbook includes a specific check for
  this. The job's last successful run timestamp is monitored.

---

## ADR-006: RFC 3161 Timestamping for Archive Bundles

**Date:** 2025-11-15
**Status:** ACCEPTED

### Context

Cyprus tax law requires that archived financial documents be stored in a tamper-evident
manner and that their creation time can be proven. Options evaluated:

1. **Internal timestamps only** — record `created_at` in the database. Simple, but
   the timestamp is under the control of the platform operator. An auditor cannot verify
   that the timestamp was not retroactively altered.
2. **Blockchain anchoring** — hash the archive bundle and record the hash in a public
   blockchain. Provides external proof but adds dependency on a third-party blockchain,
   introduces cost per transaction, and is not yet widely recognised by tax authorities.
3. **RFC 3161 trusted timestamp** — submit the archive bundle hash to an accredited
   Timestamp Authority (TSA). The TSA returns a signed timestamp token that cryptographically
   proves the document existed in its current form at the stated time. RFC 3161 is an
   IETF standard recognised by EU eIDAS regulation and accepted by most EU tax authorities.

### Decision

Apply an RFC 3161 timestamp token from an accredited TSA to each archive bundle at
finalization. The token is stored alongside the bundle in the archive zone and embedded
in the bundle manifest. Bundle promotion is atomic: if the RFC 3161 call fails, the
entire finalization is rolled back and retried.

### Consequences

- **Positive:** Provides externally verifiable, tamper-evident proof of the archive's
  existence and integrity at finalization time. This satisfies the Cyprus tax authority's
  requirements for long-term document authenticity.
- **Positive:** RFC 3161 tokens are issued by independent, accredited third parties,
  removing the need to trust the platform operator's internal clock.
- **Negative:** Adds a dependency on a TSA service. If the TSA is unavailable at
  finalization time, the finalization blocks. The archive promotion failure runbook
  covers TSA unavailability scenarios.
- **Negative:** RFC 3161 tokens add approximately 2–5 KB per archive bundle. Negligible
  relative to bundle sizes.

---

## Related Documents

- `/Docs/sub/reference/supabase_project_config.md`
- `/Docs/sub/reference/supabase_rls_policy_map.md`
- `/Docs/sub/reference/audit_event_taxonomy.md`
- `/Docs/sub/reference/archive_bundle_file_manifest.md`
- `/Docs/sub/runbooks/archive_promotion_failure_runbook.md`
- `/Docs/sub/runbooks/supabase_storage_quota_runbook.md`
- `/Docs/sub/runbooks/audit_chain_break_runbook.md`
