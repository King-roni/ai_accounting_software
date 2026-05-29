# Review Issue History Schema

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

The `review_issue_history` table is the append-only log of every state transition and significant action taken on a review issue across its lifetime. It is the human-readable audit trail for review queue activity. It is distinct from the tamper-evident `audit_log` table: the `audit_log` is the cryptographic system-of-record for every event (secured by a hash chain, per `audit_log_policies`); `review_issue_history` is the per-issue activity log that queue operators, bookkeepers, and owners use to understand the full sequence of actions on a single issue without performing an audit-log query.

Every INSERT to this table is append-only. No UPDATE or DELETE is permitted on any row.

---

## 1. Table definition

```sql
CREATE TABLE review_issue_history (
  history_id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Issue linkage
  review_issue_id         uuid NOT NULL
                            REFERENCES review_issues(review_issue_id),

  -- Tenant context
  business_id             uuid NOT NULL,

  -- Run context — the run in which this action occurred
  workflow_run_id         uuid NOT NULL
                            REFERENCES workflow_runs(workflow_run_id),

  -- The type of action recorded by this row
  action_type             review_issue_action_type_enum NOT NULL,

  -- Status values for transitions — NULL when action is not a status change
  previous_status         text,
  new_status              text,

  -- Actor — NULL for system-initiated actions
  actor_user_id           uuid
                            REFERENCES users(id),

  -- Action-specific payload (resolution action, snooze reason,
  -- escalation trigger, comment text, assignment target, etc.)
  action_payload_json     jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Immutable timestamp
  created_at              timestamptz NOT NULL DEFAULT now(),

  -- Immutability enforcement
  CONSTRAINT review_issue_history_no_future_created_at
    CHECK (created_at <= now() + interval '5 seconds')
);

CREATE TYPE review_issue_action_type_enum AS ENUM (
  'CREATED',
  'STATUS_CHANGED',
  'ASSIGNED',
  'SNOOZED',
  'RESOLVED',
  'ESCALATED',
  'COMMENT_ADDED'
);

CREATE INDEX idx_review_issue_history_issue
  ON review_issue_history(review_issue_id, created_at DESC);

CREATE INDEX idx_review_issue_history_business_run
  ON review_issue_history(business_id, workflow_run_id);

CREATE INDEX idx_review_issue_history_actor
  ON review_issue_history(business_id, actor_user_id, created_at DESC)
  WHERE actor_user_id IS NOT NULL;
```

---

## 2. Field reference

| Field | Type | Notes |
|---|---|---|
| `history_id` | UUID v7 PK | Monotonically increasing per `data_layer_conventions_policy` |
| `review_issue_id` | UUID FK | References `review_issues.review_issue_id` |
| `business_id` | UUID | Tenant scope; RLS-enforced per Section 4 |
| `workflow_run_id` | UUID FK | The run in which the action occurred |
| `action_type` | enum | One of the 7 closed values; see Section 3 |
| `previous_status` | text nullable | The issue's status before this action; NULL if action is not a status transition (e.g., `COMMENT_ADDED`, `ASSIGNED`) |
| `new_status` | text nullable | The issue's status after this action; NULL when same rules apply |
| `actor_user_id` | UUID FK nullable | The user who performed the action; NULL for system-initiated actions (engine-driven escalations, automatic snooze clears) |
| `action_payload_json` | JSONB | Action-specific detail; shape varies by `action_type` (see Section 3) |
| `created_at` | timestamptz | Wall-clock time of the action; set on INSERT; never modified |

---

## 3. Action type reference and payload shapes

### `CREATED`

Recorded when a `review_issues` row is first inserted. The `actor_user_id` is NULL for system-generated issues; it carries the user ID for manually created issues where applicable.

```json
{
  "issue_type": "matching.no_match_found",
  "issue_group": "Missing Documents",
  "initial_severity": "HIGH"
}
```

`previous_status` and `new_status` are both NULL — there is no prior status transition; the issue is instantiated directly to its initial status (`OPEN`).

### `STATUS_CHANGED`

Recorded on every status transition on the `review_issues` row. Both `previous_status` and `new_status` are populated.

```json
{
  "transition_reason": "manual_resolution",
  "resolution_action": "confirm_match"
}
```

### `ASSIGNED`

Recorded when `review_issues.assigned_to_user_id` changes, either via `review_queue.assign_issue` or as part of bulk assignment. `previous_status` and `new_status` are NULL.

```json
{
  "previous_assignee_user_id": "uuid-or-null",
  "new_assignee_user_id": "uuid",
  "assignment_method": "ROUND_ROBIN"
}
```

### `SNOOZED`

Recorded when a snooze action is applied. `previous_status` is the status before snooze; `new_status` is `SNOOZED`.

```json
{
  "snooze_id": "uuid",
  "snooze_reason": "Awaiting supplier response",
  "snooze_until_run_id": "uuid-or-null",
  "carry_forward_count": 1
}
```

### `RESOLVED`

Recorded when a resolution action closes the issue. `new_status` reflects the terminal status assigned (`RESOLVED`, `DISMISSED`).

```json
{
  "resolution_action": "mark_resolved",
  "resolution_note": "Invoice confirmed on file"
}
```

### `ESCALATED`

Recorded by `review_queue.unsnooze_at_run_start` when an automatic severity escalation is applied. `actor_user_id` is NULL — escalation is system-initiated. `previous_status` and `new_status` are both NULL (severity, not status, changed; see `issue_escalation_policy`).

```json
{
  "previous_severity": "LOW",
  "new_severity": "MEDIUM",
  "carry_forward_count": 3,
  "escalation_threshold": 3
}
```

### `COMMENT_ADDED`

Recorded when a user adds a note to the issue via `review_queue.add_note`. `previous_status` and `new_status` are NULL.

```json
{
  "note_id": "uuid",
  "comment_preview": "First 140 characters of the note text..."
}
```

---

## 4. Immutability enforcement

No UPDATE or DELETE is permitted on any `review_issue_history` row. This is enforced by the RLS policies below and by application-layer convention. The table is append-only by design: the history must be a faithful record of what happened in the order it happened.

```sql
CREATE POLICY review_issue_history_no_update
  ON review_issue_history
  FOR UPDATE
  USING (false);

CREATE POLICY review_issue_history_no_delete
  ON review_issue_history
  FOR DELETE
  USING (false);
```

---

## 5. RLS — read access

| Role | Visible rows |
|---|---|
| Owner | All history rows for the business |
| Admin | All history rows for the business |
| Bookkeeper | History rows for issues currently or previously assigned to them (i.e., where `review_issue_id` is in the set of issues ever assigned to the Bookkeeper's `user_id`) |
| Accountant | All history rows for the business (read-only; Accountants have operational read access per `audit_log_policies`) |
| Reviewer | History rows for the business where `action_type != 'COMMENT_ADDED'` (comments may contain PII) |

```sql
-- Owner and Admin: full business-scoped read
CREATE POLICY review_issue_history_owner_admin_read
  ON review_issue_history
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.role_on_business(business_id) IN ('OWNER', 'ADMIN')
  );

-- Bookkeeper: restricted to their assigned issues
CREATE POLICY review_issue_history_bookkeeper_read
  ON review_issue_history
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.role_on_business(business_id) = 'BOOKKEEPER'
    AND review_issue_id IN (
      SELECT review_issue_id
      FROM review_issues
      WHERE assigned_to_user_id = auth.current_user_id()
    )
  );

-- Accountant: full business-scoped read
CREATE POLICY review_issue_history_accountant_read
  ON review_issue_history
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.role_on_business(business_id) = 'ACCOUNTANT'
  );
```

INSERT is gated by application logic — the write occurs inside the same transaction as the underlying review-issue mutation (status change, assignment, snooze). No client-facing INSERT policy is defined; application code calls a trusted internal function.

---

## 6. Relationship to `audit_log`

These two records serve different consumers and must not be conflated:

| Dimension | `review_issue_history` | `audit_log` |
|---|---|---|
| Purpose | Human-readable per-issue activity timeline | Tamper-evident cryptographic system record |
| Audience | Queue operators, bookkeepers, owners reading issue context | Security forensics, compliance audits, chain verification |
| Queryability | Direct query by `review_issue_id` | Query via indexed lookup patterns per `audit_log_policies` |
| Tamper resistance | Append-only by RLS; no hash chain | SHA-256 hash chain per `audit_log_policies` Section 4 |
| System events | Yes — system-initiated actions have `actor_user_id IS NULL` | Yes — all events including system |
| Payload shape | Action-specific JSONB per issue activity | Canonical JSON per event type (feeds hash chain) |

Both records are written on every significant review-queue action. The `audit_log` is the authoritative record; `review_issue_history` is the derived, query-friendly trail for the UI.

---

## 7. Mobile rejection

Writing to `review_issue_history` is an implicit side-effect of review-queue write actions (status changes, assignment, snooze, resolution). All those write actions are rejected on mobile clients per `mobile_write_rejection_endpoints.md`. Reading the history of an issue is available on mobile as a read-only operation.

---

## 8. Audit events

`review_issue_history` is itself a history table; the significant events associated with review issue mutations are emitted on the business-scoped `audit_log` hash chain under the `REVIEW` domain. This table does not emit its own audit events — the mutations that write rows here are logged by the tools that perform the underlying mutations (e.g., `review_queue.assign_issue` emits `REVIEW_ISSUE_REASSIGNED`; `review_queue.snooze_issue` emits `REVIEW_ISSUE_SNOOZED`).

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; JSONB canonical encoding for `action_payload_json`; immutability contract
- `review_issue_card_schema` — `review_issues.review_issue_id` FK target; issue status enum values; `assigned_to_user_id` column
- `resolution_action_payload_schema` — `action_payload_json` shape for `RESOLVED` action type
- `snooze_carry_forward_schema` — `action_payload_json` shape for `SNOOZED` action type; `carry_forward_count` semantics
- `issue_escalation_policy` — `action_payload_json` shape for `ESCALATED` action type; `previous_severity` / `new_severity` fields
- `audit_log_policies` — tamper-resistant system record; relationship between `review_issue_history` and `audit_log`; per-role RLS overlays
- `audit_event_taxonomy` — `REVIEW` domain canonical events; the audit events that accompany each history row
- `tool_naming_convention_policy` — `review_queue` namespace; `review_queue.assign_issue` write ownership
- `mobile_write_rejection_endpoints` — review-queue write surfaces rejected on mobile clients
- `workflow_state_enum` — `workflow_run_id` FK context; canonical 10-value run state set
- Block 14 Phase 01 — `review_issues` schema; status enum
- Block 14 Phase 04 — resolution actions architecture; resolution action enum
- Block 14 Phase 06 — assignment and notes architecture
- Block 14 Phase 07 — snooze and carry-forward architecture
