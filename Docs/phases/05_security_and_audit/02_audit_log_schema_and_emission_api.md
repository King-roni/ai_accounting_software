# Block 05 — Phase 02: Audit Log Schema & Emission API

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Audit Log Model section)
- Decisions log: `Docs/decisions_log.md` (live log only in MVP — no separate read replica yet)

## Phase Goal

Stand up the audit log: the table that holds every audited event, and the single `emitAudit()` chokepoint API that every other block must use to record one. After this phase, audit emission is a primitive that any phase can call, the event is committed atomically with the state change that produced it, and the table is queryable under tenancy scope.

## Dependencies

- Block 02 Phase 01 (tenancy schema; events carry actor + tenancy fields)

(Block 04 Phase 01's hashing helpers are consumed by Phase 03, not by this phase — listed as a Phase 03 dependency.)

## Deliverables

- **`audit_events` table** in a dedicated `audit` schema:
  - `id` (UUID v7), `event_id` (monotonic per chain — see Phase 03)
  - `timestamp` (UTC, with sub-millisecond precision)
  - `actor_kind` (`USER`, `SYSTEM`), `actor_user_id` (nullable for SYSTEM), `actor_role`, `actor_session_id`
  - `organization_id`, `business_id` (tenancy scope; both nullable for org-less events like login attempts pre-tenancy resolution)
  - `subject_type` (e.g., `WORKFLOW_RUN`, `TRANSACTION`, `DOCUMENT`, `USER`, `BUSINESS`), `subject_id`
  - `action` (categorical, e.g., `LOGIN`, `LOGIN_FAILED` (emitted by Block 02 auth), `FILE_UPLOAD`, `TRANSACTION_CREATED`, `WORKFLOW_RUN_STATE_CHANGED`)
  - `before_state` (JSONB, nullable; populated for mutating events)
  - `after_state` (JSONB, nullable)
  - `reason` (text or structured)
  - `request_context` (JSONB; IP region, user agent, request id — PII-minimised)
  - `prev_event_hash`, `event_hash` (placeholders here; Phase 03 wires the chain logic)
  - `created_at`
- **`emitAudit()` API** — the single chokepoint:
  - Signature: `emitAudit({ actor, action, subject, before, after, reason, request_context })`.
  - Always called inside the same database transaction as the state change being audited (transactional coupling — both commit or neither does).
  - Validates required fields (actor, action, subject) and enriches with timestamp and tenancy from the principal context.
  - Generates `event_id` monotonically. Phase 02 produces a globally monotonic id; Phase 03 introduces per-chain partitioning, after which `event_id` is monotonic within its chain.
  - In Phase 02, leaves `prev_event_hash` and `event_hash` empty; Phase 03 fills them in.
- **RLS on `audit_events`:**
  - **SELECT** scoped by `(organization_id, business_id)` per the standard tenancy template; `Owner` and `Admin` roles can read events for businesses they have access to; `Read-only` and `Reviewer` see a filtered subset.
  - **INSERT** permitted only via the `audit_writer` service role used by `emitAudit()`. Application user roles cannot insert directly.
  - **UPDATE** forbidden (immutability is a non-negotiable from Block 01 Principle 4).
  - **DELETE** forbidden via application code paths; a separate retention process (out of scope for MVP) handles long-term lifecycle.
- **Indexes:** `(organization_id, business_id, timestamp DESC)`, `(actor_user_id, timestamp DESC)`, `(subject_type, subject_id, timestamp DESC)`, `(action, timestamp DESC)`.
- **MVP query mode:** all reads (operational and forensic) hit the live log directly. A separate read replica is deferred per Stage 1.
- **Audit events emitted by this phase itself:** `AUDIT_LOG_INITIALIZED`, `AUDIT_LOG_QUERIED` (for forensic queries — meta-audit).

## Definition of Done

- The `audit_events` table exists with all columns; the `audit` schema and `audit_writer` service role are configured.
- `emitAudit()` writes a complete event in the same transaction as a typical state change (verified via test: a state change that fails after `emitAudit` rolls back the audit row too).
- An UPDATE attempt against an audit row fails with a privilege error.
- An attempt to bypass `emitAudit()` and INSERT directly via an application role fails.
- Cross-tenant SELECT returns zero rows.
- Indexes are confirmed in `EXPLAIN` for the four typical query shapes.

## Sub-doc Hooks (Stage 4)

- **Audit event taxonomy sub-doc** — the canonical, system-wide event catalogue. Phase 02 owns this sub-doc and is responsible for naming consistency across every event emitter. Each phase that emits events references this catalogue rather than defining its own.
- **Audit event naming convention sub-doc** — convention `<DOMAIN>_<PAST_VERB>` (e.g., `WORKFLOW_RUN_STATE_CHANGED`, `KEY_ACCESSED`, `BACKUP_COMPLETED`); enforced by linting against the catalogue.
- **`emitAudit` API sub-doc** — exact signature, error shapes, transaction-coupling pattern, async edge cases.
- **Audit RLS sub-doc** — per-role read filters, including the Reviewer-vs-Read-only difference and Accountant access scope.
- **Audit query sub-doc** — common forensic queries, performance characteristics, escalation if live-log latency degrades.
