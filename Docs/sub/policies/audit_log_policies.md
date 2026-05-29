# Audit Log Policies

**Category:** Policies · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 convention)

Four sub-policies bound together because they describe one feature surface: how the audit log is named, secured, queried, and partitioned. Every audit-emitting tool, every reviewer of the audit log, and every operator running forensic queries binds to this doc.

Block 05 Phase 02 owns the schema and `emitAudit()` function. Phase 03 owns hash-chain tamper resistance.

---

## Section 1 — Audit event naming

**Pattern: `<DOMAIN>_<PAST_VERB>` — uppercase snake.**

Examples (canonical, drawn from existing phase docs):
- `MATCHING_AUTO_CONFIRMED`
- `LEDGER_VAT_TREATMENT_DECIDED`
- `ARCHIVE_PROMOTION_COMPLETED`
- `STATEMENT_UPLOAD_COMPLETED`
- `WORKFLOW_GATE_HOLD`
- `FINALIZATION_LOCK_COMMITTED`
- `KEY_ROTATED`

Anti-examples:
- `match_auto_confirm` — lowercase, present tense
- `MATCHING_AUTO_CONFIRMS` — present tense
- `MATCHING.AUTO.CONFIRMED` — dotted, not snake
- `MATCHING_AUTO_CONFIRMED_v2` — versioned suffix; if the shape changes, a new event name with no version suffix is the right move

### DOMAIN allowlist (binding)

| Domain | Source block(s) |
| --- | --- |
| `WORKFLOW`, `WORKFLOW_TOOL`, `WORKFLOW_GATE` | 03 — Workflow Engine |
| `TENANCY`, `LOGIN`, `MFA`, `PASSWORD`, `INVITATION`, `OAUTH`, `INTEGRATION` | 02 — Tenancy & Access |
| `USER`, `BUSINESS`, `SESSION`, `MFA_DEVICE` | 02 — Tenancy & Access (table-lifecycle events for `users`, `business_entities`, `user_sessions`, `mfa_devices`) |
| `AUTH` | 02 — Tenancy & Access (application-layer permission check events from `auth.can_perform`; OAuth lifecycle events `AUTH_OAUTH_CONNECTED`, `AUTH_OAUTH_TOKEN_REFRESHED`, `AUTH_OAUTH_TOKEN_REVOKED`, `AUTH_OAUTH_PERMISSION_DOWNGRADED` — see `gmail_oauth_integration.md`) |
| `WORKFLOW_PHASE` | 03 — Workflow Engine (phase-state lifecycle) |
| `ENGINE` | 03 — Workflow Engine (workflow type registry boot-time registration — `ENGINE_WORKFLOW_TYPE_REGISTERED`; see `workflow_type_registry_schema.md`) |
| `RETENTION`, `LEGAL_HOLD`, `OBJECT_LOCK`, `ANALYTICS` | 04 — Data Architecture (primary); `ANALYTICS` events are also emitted by Block 16 for snapshot rebuilds — see `analytics_snapshot_schema` |
| `KEY`, `BACKUP`, `GDPR`, `SECURITY`, `AUDIT`, `FILE` | 05 — Security & Audit |
| `AI`, `AI_GATEWAY`, `AI_PROMPT`, `AI_CACHE` | 06 — AI Layer |
| `UPLOAD` | 04, 07, 09 (upload content-sniff pipeline — `upload_content_sniff_policy`) |
| `BANK_UPLOAD` | 07 — Bank Statement Pipeline (bank upload file lifecycle — `bank_upload_schema`) |
| `STATEMENT`, `INTAKE` | 07, 09 (shared via the `intake` namespace) |
| `EVIDENCE` | 07 — Bank Statement Pipeline (evidence PDF lifecycle) |
| `CLASSIFICATION` | 08 — Transaction Classification |
| `VENDOR_MEMORY` | 08 — Transaction Classification (vendor memory record lifecycle — `vendor_memory_schema`) |
| `DOCUMENT` | 09 — Document Intake |
| `MATCH` | 10 — Matching Engine (match record lifecycle — `match_record_schema`, `income_matching_schema`) |
| `MATCHING`, `INCOME_MATCHING`, `SPLIT_PAYMENT_GROUP` | 10 — Matching Engine |
| `COUNTERPARTY` | 11 — Ledger & Cyprus VAT (counterparty record lifecycle — `counterparty_schema`) |
| `LEDGER`, `VIES` | 11 — Ledger & Cyprus VAT (primary owner); Block 16 co-owns `VIES` for submission lifecycle events — `VIES_SUBMISSION_CREATED`, `VIES_SUBMISSION_ACCEPTED`, `VIES_SUBMISSION_REJECTED` (see `vies_submission_tracking_schema`) |
| `OUT_WORKFLOW`, `OUT_FILTER`, `OUT_ADJUSTMENT` | 12 — OUT Workflow |
| `IN_WORKFLOW`, `IN_FILTER`, `IN_ADJUSTMENT`, `INVOICE`, `CLIENT`, `RECURRING_INVOICE` | 13 — IN Workflow + Invoice Generator |
| `REVIEW` | 14 — Review Queue |
| `FINALIZATION`, `ARCHIVE` | 15 — Finalization & Secure Archive |
| `EXPORT`, `DASHBOARD`, `ACCOUNTANT_PACK` | 16 — Dashboard & Reporting |
| `REPORT` | 16 — Dashboard & Reporting (async report job lifecycle — `report_job_schema`, `period_comparison_schema`) |
| `LIVE_TEST` | 05 — Security & Audit (live integration test infrastructure) |

Adding a new domain requires a `Docs/decisions_log.md` amendment. The taxonomy of specific events under each domain is `audit_event_taxonomy` (Reference data sub-doc, Block 05).

### Lint rule

Regex: `^[A-Z][A-Z0-9_]*_[A-Z][A-Z0-9_]*$`

Plus:
1. Domain (left of the first `_` after the prefix span) must be in the allowlist
2. Event name must exist in `audit_event_taxonomy` (catalogue check)
3. No event name appears twice with different ownership / payload shape

CI fails the build if any of these checks fail. The check runs on every audit-emitting source file before merge.

### Past-tense rule

The verb portion is past tense — the audit log records facts that have happened, not commands or intentions. This rules out `_REQUESTED` for events that succeeded; we use `_COMPLETED` instead. `_REQUESTED` is reserved for events that capture the request itself, separate from completion (e.g., `KEY_ROTATION_REQUESTED` followed by `KEY_ROTATED`).

---

## Section 2 — Per-role audit-log RLS

The audit log is private. It contains user actions, decisions, IPs, decrypted-field-access markers, and system-level events. RLS restricts which rows a role can `SELECT`.

### Default rule

Every audit row carries `business_id` (nullable for global events). RLS denies any read where the requester's session does not have an active role on that `business_id`. Cross-business read is impossible regardless of role.

### Per-role overlays

| Role | Visible events |
| --- | --- |
| **Owner** | All events for the business |
| **Admin** | All events for the business EXCEPT `KEY_ROTATED`, `KEY_ROTATION_REQUESTED`, `BACKUP_KEY_ROTATED` (Owner-only by default; configurable post-MVP) |
| **Bookkeeper** | All events EXCEPT those with domain in `{KEY, BACKUP, GDPR, SECURITY}` AND EXCEPT events whose actor role is Accountant (privacy boundary) |
| **Accountant** | Events with domain in `{LEDGER, REVIEW, FINALIZATION, ARCHIVE, EXPORT, INVOICE, CLIENT, RECURRING_INVOICE, IN_WORKFLOW, OUT_WORKFLOW, OUT_ADJUSTMENT, IN_ADJUSTMENT, OUT_FILTER, IN_FILTER, MATCH, MATCHING, INCOME_MATCHING, SPLIT_PAYMENT_GROUP, CLASSIFICATION, STATEMENT, INTAKE, UPLOAD, DOCUMENT, WORKFLOW, WORKFLOW_GATE, WORKFLOW_TOOL, AI, REPORT, DASHBOARD, ACCOUNTANT_PACK}` — the operational and reporting surface only |
| **Reviewer** | Events with domain in `{REVIEW, WORKFLOW, WORKFLOW_GATE, FINALIZATION}` AND with no actor PII (the actor email/IP are masked in the API response — see Block 05 Phase 06 access control) |
| **Read-only** | Events with domain in `{WORKFLOW, FINALIZATION}` only — high-level run lifecycle, no per-record actions |

### Implementation

Each role has its own RLS policy defined alongside the table. The policies use `auth.role_on_business(business_id)` from Block 02 Phase 04 to resolve the active role. Policies are declarative SQL; no application-side filtering.

The Owner row of `KEY_ROTATED` exception is written via the per-business `app.audit_owner_only` session variable that Block 02's role helpers set for Owner-active sessions.

### Mobile

`client_form_factor = MOBILE` does not affect audit-log read RLS. Mobile is read-only for writes per the Stage 1 decision; reads are unaffected.

### Cross-business

Cross-business audit access is impossible. There is no Owner-of-Organization role with cross-business read; an Owner viewing two businesses sees two separate audit logs. The Block 16 multi-business consolidated dashboard never queries audit directly — it queries pre-aggregated views that respect per-business RLS.

---

## Section 3 — Forensic query patterns and latency

The audit log is queryable but not free. These are the supported access patterns and their latency budgets.

### Indexed lookups (target: P95 < 100ms)

| Query | Index |
| --- | --- |
| `events_by_subject` — all events touching a specific transaction / document / match | `(business_id, subject_id, event_time)` |
| `events_by_actor_in_window` — actor activity in a time window | `(business_id, actor_user_id, event_time)` |
| `events_by_event_type_in_window` — incidence count of a specific event in a period | `(business_id, event_type, event_time)` |
| `events_by_business_in_window` — full-tape replay of a business's activity | `(business_id, event_time)` |
| `chain_walk_from_anchor` — verify hash-chain integrity from a known anchor | `(chain_id, sequence_number)` |

### Time-range scans (target: P95 < 2s)

Up to 30 days. Use cases: GDPR access export, accountant pack audit-history slice, drill-down record history. Backed by partial indexes on `event_time` per business.

### Cold-storage replica (Stage 2+)

Queries spanning more than 30 days route to a cold-storage replica with relaxed latency budgets (target: P95 < 30s). MVP defers this; long queries on the primary fail with a clear "use the export pipeline" error, not by exceeding `statement_timeout`.

### Escalation: queries exceeding 5s

Postgres `statement_timeout` is set to 5s for the audit-reading roles. Queries that exceed this are killed with a structured error. Ops alert fires (`SECURITY_AUDIT_QUERY_TIMEOUT`) so the team can either tune the query, add an index, or move the consumer to the cold-storage replica.

### Query construction rules

- Always include `business_id` in the WHERE clause — RLS will deny without it, and the indexes are tenant-prefixed
- Use `event_time` time-range filters; never scan unbounded time
- Hash-chain integrity walks bypass `event_type` filters by design — they verify the chain regardless of payload

---

## Section 4 — Hash-chain partitioning

Three chain levels run in parallel. Each chain is an independent append-only sequence of `(prev_hash, event_payload_canonical_json) → chain_hash`.

| Chain | Scope | Source |
| --- | --- | --- |
| **Global** | System-level events (cross-tenant alerts, backup events, replica events). Single chain head | One row in `chain_heads` |
| **Org** | Cross-business org events (member invitations, role grants spanning businesses, integration token shared by multiple businesses). One chain head per `organization_id` | One row per organization |
| **Business** | All business-scoped events. One chain head per `business_id` | One row per business |

### Chain-head storage

`chain_heads` table — one row per chain. Each row holds the latest `chain_hash`, `last_event_id`, and `last_sequence_number`. Updates occur inside `emitAudit()` via row-level lock (`SELECT … FOR UPDATE`) on the relevant chain row.

### Lock semantics

- One chain row at a time per emission
- Lock held for the duration of the emit transaction (a separate short transaction per the 2026-05-08 amendment — emit runs out-of-band of the operational transaction that triggered it)
- Concurrent emissions on different chains do not contend (per-business chains lock their own rows)

### Throughput target

- Steady state: <50 emissions per second per chain. Index design easily handles this
- Burst: 500/s per business chain handled with row-locking degradation; latency rises but no failures
- Cross-business burst (50 businesses × 500/s simultaneous) handled by the per-business chain isolation

### Anchoring (Phase 03)

Chain heads are periodically anchored externally via RFC 3161 timestamping (Block 05 Phase 03). The anchor records `(chain_id, sequence_number, chain_hash)` to the third-party TSA. Each chain anchors independently — the global chain does not gate the business chains.

### Failure modes

- **Chain divergence** — two writers produced two valid `chain_hash` values for the same `sequence_number`. Detected by `(chain_id, sequence_number)` unique constraint; later writer's transaction aborts. Audit emit retries with the new chain head.
- **Anchor failure** — RFC 3161 TSA unreachable. Anchoring is best-effort; chain still appends, and the next successful anchor covers the gap.
- **Audit-emit-failed during workflow** — handled by Block 03 Phase 07 resumability; a recovery emission `FINALIZATION_LOCK_AUDIT_RECOVERED` covers the recovery window.

### Trade-off rationale

Per-business isolation gives clean tenant separation in audit forensics ("walk only this business's chain") and limits blast radius of any chain-level corruption. The org chain captures cross-business administrative actions that don't fit cleanly in either business. The global chain is system-of-record for events with no tenant context.

A single global chain was rejected because high-volume tenants would dominate latency for low-volume tenants. Per-event chains were rejected because the lock contention cost flips negative below ~10 events per second per source.

---

## Cross-references

- `audit_event_taxonomy` (Reference data, Block 05) — the canonical event catalogue
- `data_layer_conventions_policy` — canonical JSON serialization, hashing
- Block 05 Phase 02 — audit log schema, `emitAudit()` function
- Block 05 Phase 03 — hash-chain tamper resistance, RFC 3161 timestamping
- Block 02 Phase 04 — `auth.role_on_business()` helper used by RLS
- Block 03 Phase 07 — resumability framework that handles audit-emit failure recovery

## Open items deferred to later sub-docs

- The catalogue of every approved event name + payload shape — `audit_event_taxonomy` (Reference data sub-doc, Block 05)
- Backup-encrypted audit-log replication — Block 05 Phase 08
- Cold-storage replica architecture — Stage 2+ deferral
- Per-event-type retention overrides (default = retention engine's standard 6-year window) — `retention_policies_schema` (Schemas, Block 04)
