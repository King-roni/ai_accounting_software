# Audit Event Naming Convention Policy

**Category:** Policies · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

This document is the formal specification for how audit event names are constructed, validated, and changed. It supplements Section 1 of `audit_log_policies.md`, which states the naming pattern. Where the two documents conflict, this file is more specific and takes precedence for the details it covers.

---

## Purpose

Audit event names are permanent identifiers. Once an event name enters production, rows in the append-only audit log carry it forever. The naming convention exists to make event names self-describing, predictable, and lintable. A name that passes the lint rules should communicate the domain, the action, and the tense without needing to open a reference document.

---

## Format

```
<DOMAIN>_<PAST_VERB>
```

Both parts are in SCREAMING_SNAKE_CASE. Every event name has at minimum two parts separated by a single underscore. The domain may itself contain underscores (e.g., `BANK_UPLOAD`, `OUT_WORKFLOW`), but the final segment after all domain tokens is the verb.

Examples demonstrating multi-token domains:

| Event name | Domain | Verb |
| --- | --- | --- |
| `BANK_UPLOAD_RECEIVED` | `BANK_UPLOAD` | `RECEIVED` |
| `OUT_WORKFLOW_RUN_TRIGGERED` | `OUT_WORKFLOW` | `RUN_TRIGGERED` |
| `AI_TIER_ESCALATED` | `AI` | `TIER_ESCALATED` |
| `SECURITY_RLS_DENY_DETECTED` | `SECURITY` | `RLS_DENY_DETECTED` |
| `SESSION_EVICTED_MAX_CONCURRENCY` | `SESSION` | `EVICTED_MAX_CONCURRENCY` |

The domain is the leftmost registered token or token sequence from the domain allowlist. Everything after the domain prefix is the verb phrase.

---

## Lint regex

```
^[A-Z][A-Z0-9_]*_[A-Z][A-Z0-9_]*$
```

This regex enforces:

- Starts with an uppercase letter
- Contains only uppercase letters, digits, and underscores
- Has at least one underscore separating two non-empty segments
- Does not start or end with an underscore
- Does not contain double underscores (`__`)

The regex is a necessary condition, not sufficient. It must be combined with:

1. **Domain membership check** — the leading domain token(s) must match an entry in the allowlist below.
2. **Taxonomy membership check** — the full event name must exist in `audit_event_taxonomy.md`. Passing the regex but not appearing in the taxonomy fails the build.

---

## Domain allowlist

All registered domains. The owning block is the block that first introduced the domain. A domain may be co-owned if events in that domain are emitted by multiple blocks (noted in `audit_log_policies`).

```
UPLOAD           EVIDENCE         VIES
BANK_UPLOAD      VENDOR_MEMORY    MATCH
COUNTERPARTY     USER             BUSINESS
SESSION          MFA_DEVICE       WORKFLOW_PHASE
REPORT           LIVE_TEST        WORKFLOW
WORKFLOW_TOOL    WORKFLOW_GATE    KEY
SECURITY         AI               AI_GATEWAY
AI_PROMPT        AI_CACHE         AUTH
INTAKE           CLASSIFICATION   MATCHING
LEDGER           OUT_WORKFLOW     IN_WORKFLOW
REVIEW_QUEUE     ARCHIVE          INVOICE
ENGINE           DATA             FINALIZATION
TENANCY          LOGIN            MFA
PASSWORD         INVITATION       OAUTH
INTEGRATION      RETENTION        LEGAL_HOLD
OBJECT_LOCK      ANALYTICS        BACKUP
GDPR             AUDIT            FILE
STATEMENT        DOCUMENT         INCOME_MATCHING
SPLIT_PAYMENT_GROUP  OUT_FILTER   OUT_ADJUSTMENT
IN_FILTER        IN_ADJUSTMENT    CLIENT
RECURRING_INVOICE    REVIEW       EXPORT
DASHBOARD        ACCOUNTANT_PACK  VIES_SUBMISSION
```

Domains that do not appear in this list are not registered. Using an unregistered domain in an audit event name fails the CI domain-membership check.

---

## Forbidden patterns

The following patterns are rejected by the lint rules or by documented convention, regardless of whether they pass the regex:

### Forbidden: `CRITICAL` as severity

The severity enum is `LOW`, `MEDIUM`, `HIGH`, `BLOCKING`. `CRITICAL` is not a valid severity value. Any event payload or documentation that uses `CRITICAL` as a severity label is a lint violation. Use `BLOCKING` for events that halt a workflow or require immediate intervention.

### Forbidden: single-part names

`UPDATED`, `CREATED`, `FAILED` — these have no domain context and are rejected by both the regex (no `_` separator) and the domain check. Every event name must be at least `DOMAIN_VERB`.

### Forbidden: generic verb-only names

Event names where the domain resolves to a registered domain but the verb carries no distinguishing information:

- `USER_UPDATED` is too generic if there are multiple update operations on users with different security significance. The policy permits `USER_UPDATED` where the payload `changed_fields` discriminates the case, but each block must evaluate whether a more specific name (e.g., `USER_EMAIL_VERIFIED`) is warranted.
- `INVOICE_CHANGED` — the verb `CHANGED` is not past tense and carries no semantic content. Use `INVOICE_AMENDED`, `INVOICE_VOIDED`, `INVOICE_SENT`, etc.
- `UPDATED` as a standalone verb segment is discouraged and will be challenged in code review for new events.

### Forbidden: version suffixes

`MATCHING_AUTO_CONFIRMED_v2` is not a valid event name. When a payload shape changes in a breaking way, a new event name without a version suffix is introduced. See the Change Process section.

### Forbidden: present-tense verbs

`MATCHING_AUTO_CONFIRMS`, `SESSION_EXPIRING` — the audit log records facts that happened, not intentions or ongoing states. All verbs are past tense: `CONFIRMED`, `EXPIRED`, `TRIGGERED`, `DETECTED`, `COMPLETED`, `FAILED`.

---

## Adding a new domain

1. Open a PR that amends both `audit_log_policies.md` (Section 1 domain allowlist) and this file's domain allowlist above.
2. Include a `Docs/decisions_log.md` entry explaining the new domain's owning block and why it cannot be subsumed by an existing domain.
3. The PR must include at least one event in `audit_event_taxonomy.md` using the new domain — a domain with no events is not permitted.
4. CI runs the domain-membership check against both files after merge.

No code may emit an event with an unregistered domain. The lint check fails the build at PR time.

---

## Adding a new event

1. Verify the domain is in the allowlist. If not, follow the new-domain process above.
2. Add the event name and one-line semantics to `audit_event_taxonomy.md` under the appropriate domain section.
3. Add a full payload schema entry to `audit_event_payload_schemas.md`.
4. If the event is emitted by a registered tool, add the event name to the tool's `audit_events` array in `engine.registerTool`.
5. One PR may add the domain (if new), the taxonomy entry, the payload schema, and the tool registration amendment together. The lint runs after merge.

---

## Change process

### Minor changes (non-breaking)

Adding optional payload fields to an existing event is a minor change. Existing consumers that do not read the new field are unaffected. A minor change requires:

- Amendment to the payload schema in `audit_event_payload_schemas.md`.
- No new event name.
- No deprecation period.

### Breaking changes

Renaming a domain, renaming the verb segment, removing required payload fields, or changing the semantic meaning of an existing event name is a breaking change. The process:

1. Introduce the new event name in `audit_event_taxonomy.md`.
2. Mark the old event name as deprecated in the taxonomy with a `deprecated_at` date and a pointer to the replacement.
3. Emit **both** the old and new event names for a minimum of **2 sprints** (the overlap period). This allows dashboards, alert rules, and forensic queries that reference the old name to be migrated.
4. After the overlap period, stop emitting the old event. Update the taxonomy to mark the old event as removed.
5. Do not delete the old event from the taxonomy — the append-only audit log contains historical rows with the old event name, and removing the taxonomy entry would cause false positives in the drift lint check.

The overlap period is 2 sprints minimum. If external parties (auditors, integrations) depend on the event, the overlap period is extended at the discretion of the owning block.

### Immutability guarantee

Event names in production are immutable in the audit log. Rows cannot be updated. A "rename" from the database perspective is the introduction of a new event name plus a deprecation of the old one. The old rows always retain the old name.

---

## CI enforcement

The following checks run on every PR that touches audit-emitting code, policy files, or taxonomy files:

| Check | Failure condition |
| --- | --- |
| Regex lint | Event name does not match `^[A-Z][A-Z0-9_]*_[A-Z][A-Z0-9_]*$` |
| Domain membership | Domain prefix not in allowlist |
| Taxonomy membership | Full event name not in `audit_event_taxonomy.md` |
| Removed event reference | Code references an event name listed under "Removed" in the taxonomy |
| Severity enum | `CRITICAL` appears in a severity field |
| Tool registration | `audit_events` array contains an event not in the taxonomy |

All checks are blocking. Override requires an amendment ticket in the commit message referencing `Docs/decisions_log.md`.

---

## Cross-references

- `audit_log_policies.md` — Section 1 naming pattern, domain allowlist (primary binding source), Section 4 chain partitioning
- `audit_event_taxonomy.md` — the canonical event catalogue that this convention governs
- `emit_audit_api.md` — the emission function that accepts event names validated against this convention
- Block 05 Phase 02 — `emitAudit()` schema and the lint hook integration
