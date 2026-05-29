# Review Queue Schema

**Block:** 08 — Review Queue  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

Defines the `review_queue_issues` table, which is the persistent store for all issues raised during bookkeeping run processing. Issues are created by the engine (automated detection), by classification rules, or manually by accountants. The table supports the full issue lifecycle: OPEN through resolution or auto-close. It is the backing store for the Review Queue UI and the finalization gate that blocks FINALIZING when BLOCKING issues remain.

For issue status transitions, see `reference/issue_status_enum.md`. For issue group values, see `reference/issue_group_enum.md`. For RLS policy details, see `reference/supabase_rls_policy_map.md`.

---

## DDL

```sql
-- Enum types (defined once, shared across schemas)

CREATE TYPE issue_severity_enum AS ENUM (
    'INFO',
    'WARNING',
    'BLOCKING'
);

-- Reference issue_status_enum.md for the full issue_status_enum DDL.
-- It is created in that migration and referenced here.

-- Reference issue_group_enum.md for the full issue_group_enum DDL.

CREATE TABLE review_queue_issues (
    -- Primary key
    id                      uuid            PRIMARY KEY DEFAULT gen_uuid_v7(),

    -- Tenant context
    business_id             uuid            NOT NULL
                                              REFERENCES business_entities(id)
                                              ON DELETE CASCADE,

    -- Run context
    run_id                  uuid            NOT NULL
                                              REFERENCES workflow_runs(id)
                                              ON DELETE CASCADE,

    -- Affected entity
    entity_type             text            NOT NULL
                                              CHECK (entity_type IN (
                                                'TRANSACTION',
                                                'INVOICE',
                                                'MATCH',
                                                'LEDGER_ENTRY',
                                                'VAT_PERIOD',
                                                'RUN'
                                              )),
    entity_id               uuid            NOT NULL,

    -- Classification
    issue_group             issue_group_enum    NOT NULL,
    severity                issue_severity_enum NOT NULL,

    -- Content
    description             text            NOT NULL
                                              CHECK (char_length(description) >= 10),
    resolution_note         text,

    -- Status
    status                  issue_status_enum   NOT NULL DEFAULT 'OPEN',

    -- Snooze
    snooze_until            timestamptz,
    snoozed_by              uuid            REFERENCES auth.users(id),

    -- Assignment
    assigned_to             uuid            REFERENCES auth.users(id),

    -- Resolution
    resolved_by             uuid            REFERENCES auth.users(id),
    resolved_at             timestamptz,

    -- Timestamps
    created_at              timestamptz     NOT NULL DEFAULT now(),
    updated_at              timestamptz     NOT NULL DEFAULT now(),

    -- Constraints
    CONSTRAINT snooze_requires_until
        CHECK (
            (status = 'SNOOZED' AND snooze_until IS NOT NULL)
            OR (status != 'SNOOZED')
        ),
    CONSTRAINT resolution_requires_actor
        CHECK (
            (status = 'RESOLVED' AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)
            OR (status != 'RESOLVED')
        ),
    CONSTRAINT snooze_until_future
        CHECK (
            snooze_until IS NULL OR snooze_until > created_at
        )
);
```

---

## Indexes

```sql
-- Primary query paths for the Review Queue page

CREATE INDEX idx_review_queue_issues_run_status
    ON review_queue_issues (run_id, status);

CREATE INDEX idx_review_queue_issues_business_status_severity
    ON review_queue_issues (business_id, status, severity);

-- For finalization gate queries (block on BLOCKING issues)
CREATE INDEX idx_review_queue_issues_run_severity_status
    ON review_queue_issues (run_id, severity, status)
    WHERE severity = 'BLOCKING' AND status IN ('OPEN', 'IN_PROGRESS');

-- For snooze wake-up job
CREATE INDEX idx_review_queue_issues_snooze_until
    ON review_queue_issues (snooze_until)
    WHERE status = 'SNOOZED' AND snooze_until IS NOT NULL;

-- For assignee workload queries
CREATE INDEX idx_review_queue_issues_assigned_to
    ON review_queue_issues (assigned_to, status)
    WHERE assigned_to IS NOT NULL;
```

---

## Trigger: updated_at

```sql
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER review_queue_issues_updated_at
    BEFORE UPDATE ON review_queue_issues
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

## Row-Level Security

RLS is enabled on `review_queue_issues`. The following policies apply:

```sql
ALTER TABLE review_queue_issues ENABLE ROW LEVEL SECURITY;

-- Business members can read issues for their business
CREATE POLICY "business_members_read_issues"
    ON review_queue_issues
    FOR SELECT
    USING (
        business_id IN (
            SELECT business_id
            FROM business_memberships
            WHERE user_id = auth.uid()
            AND status = 'ACTIVE'
        )
    );

-- Accountants and owners can insert issues
CREATE POLICY "accountants_insert_issues"
    ON review_queue_issues
    FOR INSERT
    WITH CHECK (
        business_id IN (
            SELECT business_id
            FROM business_memberships
            WHERE user_id = auth.uid()
            AND role IN ('accountant', 'owner')
            AND status = 'ACTIVE'
        )
    );

-- Accountants and owners can update issues
CREATE POLICY "accountants_update_issues"
    ON review_queue_issues
    FOR UPDATE
    USING (
        business_id IN (
            SELECT business_id
            FROM business_memberships
            WHERE user_id = auth.uid()
            AND role IN ('accountant', 'owner')
            AND status = 'ACTIVE'
        )
    );

-- Service role bypasses RLS for engine-created issues
-- (enforced by Supabase service_role key, no explicit policy needed)
```

---

## Data Zone Classification

| Column group | Zone | Notes |
|---|---|---|
| id, business_id, run_id, entity_type, entity_id | Operational | Standard retention, 7-year minimum |
| issue_group, severity, description, status | Operational | Core issue data |
| resolution_note | Operational | Accountant-authored text, retained for audit |
| snooze_until, snoozed_by, assigned_to | Operational | Workflow state |
| resolved_by, resolved_at | Operational | Non-repudiation record |

No PII is stored directly in this table. `description` may contain entity references (e.g. transaction amounts) but not personal data. The `entity_id` FK resolves to the entity table where PII controls apply independently.

---

## Audit Events

All audit events are emitted to `audit_log` via `emit_audit.record`. See `reference/audit_event_taxonomy.md`.

| Event | Severity | Trigger |
|---|---|---|
| `REVIEW_ISSUE_CREATED` | LOW | A new row is inserted into `review_queue_issues` |
| `REVIEW_ISSUE_RESOLVED` | LOW | `status` transitions to RESOLVED |
| `REVIEW_ISSUE_SNOOZED` | LOW | `status` transitions to SNOOZED |
| `REVIEW_ISSUE_ESCALATED` | MEDIUM | `status` transitions to ESCALATED |
| `REVIEW_ISSUE_AUTO_CLOSED` | LOW | `status` transitions to AUTO_CLOSED (engine-driven) |

Audit records include: `event_type`, `actor_id` (user_id or 'engine'), `business_id`, `run_id`, `entity_id`, `occurred_at`, `metadata` (JSON with old_status, new_status, resolution_note if applicable).

---

## Snooze Wake-Up Job

A scheduled background job runs every 15 minutes and transitions all snoozed issues whose `snooze_until` is in the past back to `OPEN`. The job emits a `REVIEW_ISSUE_CREATED` event for the wake-up (not a new issue creation — the event payload includes `reactivation: true`). This job uses the service role and bypasses RLS.

---

## Finalization Gate Integration

The finalization gate queries `review_queue_issues` using the partial index `idx_review_queue_issues_run_severity_status` to check for any BLOCKING issues in OPEN or IN_PROGRESS status for the run. If any rows are returned, the gate fails and `engine.request_finalization_approval` returns `ENGINE_FINALIZATION_GATE_FAILED`.

This integration is documented in `schemas/finalization_gate_sql_schema.md`.

---

## Integration Points

- `reference/review_queue_policy.md` — policy rules governing issue creation, escalation, and auto-close
- `reference/issue_status_enum.md` — full status enum DDL and transition rules
- `reference/issue_group_enum.md` — issue_group_enum values and routing logic
- `schemas/finalization_gate_sql_schema.md` — finalization gate query using this table
- `ui/review_queue_ui_spec.md` — UI built on top of this schema
- `tools/tool_review_queue_create_issue.md` — tool that inserts into this table

---

## Related Documents

- `reference/issue_status_enum.md`
- `reference/issue_group_enum.md`
- `reference/severity_enum.md`
- `reference/supabase_rls_policy_map.md`
- `reference/audit_event_taxonomy.md`
- `schemas/workflow_run_schema.md`
- `schemas/review_issue_history_schema.md`
