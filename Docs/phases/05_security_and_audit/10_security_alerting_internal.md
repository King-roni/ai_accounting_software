# Block 05 — Phase 10: Security Alerting (Internal)

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Security Alerting section)
- Decisions log: `Docs/decisions_log.md` (security alerting is internal-only in MVP; user-facing alerts deferred)

## Phase Goal

Stand up the alerting layer that watches the audit log, the chain-verification job, and the access-control runtime for anomalies; routes alerts to the ops/security channel; and stays internal-only per the Stage 1 decision. After this phase, the platform's security operations have a near-real-time signal pipeline grounded in the audit log Phase 02 produced.

## Dependencies

- Phase 02 (audit log — primary data source)
- Phase 03 (chain verification — failures escalate to alerts here)
- Phase 06 (access control runtime — emits the cross-tenant and decision-throws events)
- Phase 07 (secrets management — emits secret-access events)
- Block 02 Phase 02 (`LOGIN_FAILED` events that the failed-login-spike rule consumes)
- Block 04 Phase 07 (`OBJECT_LOCK_VIOLATION_DETECTED` events from the archive bucket that the Object-Lock-violation rule consumes)
- Block 04 Phase 08 (`BACKUP_REPLICATION_LAG_EXCEEDED` and restore-failure events)

## Deliverables

- **Alert rules engine:**
  - Reads audit events on a 1–5 minute schedule via direct query, or near-real-time via Postgres logical replication if available.
  - Rules are configuration-driven — adding a new rule does not require a code deploy.
- **Built-in MVP rule set:**
  - **Cross-tenant access attempts** — any audit event with `cross_tenant: true` triggers; severity `HIGH`. Repeated within 1 hour from the same actor escalates to `CRITICAL`.
  - **Repeated denials from the same actor** — N `ACCESS_DENIED` events from one actor within M minutes (sub-doc tunes N and M); severity `MEDIUM`.
  - **Decision-throws** — any `ACCESS_DECISION_THREW` event from Phase 06; severity `CRITICAL`. Implies a runtime bug in `canPerform`.
  - **Chain verification failures** — any `CHAIN_VERIFICATION_FAILED` from Phase 03; severity `CRITICAL`.
  - **Failed login spikes** — N `LOGIN_FAILED` events targeting one or many user accounts within M minutes; severity `HIGH` (potential password-spray attack).
  - **Storage Object Lock violations** — `OBJECT_LOCK_VIOLATION_DETECTED` events from Block 04 Phase 07 (Object Lock-protected archive bucket); severity `CRITICAL`.
  - **Restore verification failures** — `RESTORE_VERIFICATION_FAILED` from Phase 08; severity `CRITICAL`.
  - **Secret access anomalies** — high-frequency `SECRET_ACCESSED` for sensitive secrets, off-hours patterns; severity `MEDIUM`.
  - **Backup replication lag exceeded** — `BACKUP_REPLICATION_LAG_EXCEEDED` from Phase 08; severity `HIGH`.
- **Severity tiers and routing:**
  - `CRITICAL`: page on-call + emit to security channel + open an incident.
  - `HIGH`: emit to security channel, no page.
  - `MEDIUM`: roll up into a daily digest.
  - All routing is **internal-only** in MVP (Stage 1) — no Owner/Admin notifications to user-facing accounts.
- **Alert deduplication:**
  - Same rule + same subject within a configured window collapses into a single notification with a count. The dedup key is `(rule_id, subject_kind, subject_id)`, where `subject_kind` is `actor` or `business` depending on the rule.
  - Prevents notification flooding when an attack triggers a flurry of identical events.
- **Alert lifecycle:**
  - `alerts` table stores every alert: `id`, `rule_id`, `severity`, `subject` (actor/business/system), `payload` (JSONB summary), `fired_at`, `acknowledged_at`, `acknowledged_by`, `resolved_at`, `resolved_by`, `resolution_notes`.
  - Acknowledgement and resolution emit audit events.
- **Rule configuration:**
  - `alert_rules` table — rule id, name, query/template, severity, dedup window, enabled flag.
  - Rules can be added, updated, or disabled by operators with the `SECURITY_ALERTING_MANAGE` permission (a new internal surface, not exposed to user roles).
- **Audit events:** `SECURITY_ALERT_FIRED`, `SECURITY_ALERT_DEDUPLICATED`, `SECURITY_ALERT_ACKNOWLEDGED`, `SECURITY_ALERT_RESOLVED`, `ALERT_RULE_ADDED`, `ALERT_RULE_UPDATED`, `ALERT_RULE_DISABLED`.

## Definition of Done

- Each rule in the built-in set fires correctly when its trigger condition is simulated.
- Cross-tenant attempts produce `HIGH` alerts; repeated cross-tenant attempts within an hour escalate to `CRITICAL`.
- Decision-throws and chain-verification failures both reach `CRITICAL` and page on-call.
- Failed-login spikes detect at the configured threshold.
- Deduplication collapses repeated identical events within the window into one notification.
- Acknowledgement and resolution flows audit-log correctly.
- All routing is internal — no user-facing emissions in MVP.
- Adding a new rule via the rule configuration table works without a code deploy.

## Sub-doc Hooks (Stage 4)

- **Alert rule catalogue sub-doc** — the canonical list with thresholds, severity, dedup windows, rationale.
- **Alert routing sub-doc** — channel choice (Slack, PagerDuty, email), page rules, on-call rotation integration.
- **Deduplication policy sub-doc** — exact dedup window per rule, count-rendering format.
- **Rule configuration sub-doc** — schema, validation, the `SECURITY_ALERTING_MANAGE` internal surface.
- **User-facing alerts post-MVP sub-doc** — design space for surfacing org-relevant alerts to Owners (deferred per Stage 1).
