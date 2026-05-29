# review_issues_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The canonical `review_issues` table — every issue raised by any producing block lives here. Per the 2026-05-08 amendment, Block 04 Phase 04 added 8 new columns and extended the status enum with `AUTO_RESOLVED_BY_RESCAN` to absorb the Block 14 requirements. The `issue_group` ENUM is the 5 actionable values (with `Ready to Finalize` as a queue-state projection per `issue_group_enum`).

---

## Table definition

```sql
CREATE TYPE review_issue_status_enum AS ENUM (
  'OPEN',
  'RESOLVED',
  'SNOOZED',
  'AUTO_RESOLVED_BY_RESCAN',
  'DISMISSED'
);

CREATE TYPE subject_kind_enum AS ENUM (
  'transactions',
  'documents',
  'match_records',
  'invoices',
  'ledger_entries',
  'workflow_runs'
);

CREATE TABLE review_issues (
  review_issue_id                       uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                           uuid NOT NULL REFERENCES business_entities(id),
  workflow_run_id                       uuid NOT NULL REFERENCES workflow_runs(workflow_run_id),

  -- Identity / classification
  issue_type                            text NOT NULL,                     -- per issue_type_to_group_mapping namespacing
  issue_group                           issue_group_enum NOT NULL,         -- 5 actionable values
  severity                              severity_enum NOT NULL,            -- 4-value closed enum
  status                                review_issue_status_enum NOT NULL DEFAULT 'OPEN',

  -- Subject (polymorphic FK)
  subject_id                            uuid NOT NULL,
  subject_kind                          subject_kind_enum NOT NULL,

  -- Frozen card content (post 2026-05-08 amendment columns)
  card_payload_json                     jsonb,                              -- frozen plain-language user-facing text
  card_content_generated_at             timestamptz,
  card_content_tier_used                tool_ai_tier_enum,                  -- NONE / LOCAL / EXTERNAL
  card_content_fallback_applied         boolean NOT NULL DEFAULT false,

  -- Display
  title                                 text NOT NULL,
  description                           text,

  -- Assignment (post 2026-05-08 amendment columns)
  assigned_to_user_id                   uuid REFERENCES users(id),
  assigned_by_user_id                   uuid REFERENCES users(id),
  assigned_at                           timestamptz,
  assignment_notification_sent_at       timestamptz,

  -- Resolution
  resolution_note                       text,                               -- per Stage 1 "single free-text notes field"
  resolution_action_type                text,                               -- one of resolution_action_enum values
  resolution_action_payload             jsonb,
  resolved_by_user_id                   uuid REFERENCES users(id),
  resolved_at                           timestamptz,

  -- Snooze (post 2026-05-08 amendment columns)
  snoozed_at                            timestamptz,
  snoozed_by                            uuid REFERENCES users(id),
  snooze_until                          timestamptz,
  snooze_reason                         text,

  -- Auto-resolution by rescan
  auto_resolution_trigger_issue_id      uuid REFERENCES review_issues(review_issue_id),  -- the issue whose resolution triggered the rescan

  -- Metadata
  created_at                            timestamptz NOT NULL DEFAULT now(),
  updated_at                            timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CHECK (
    -- RESOLVED requires resolution_action_type
    status != 'RESOLVED' OR resolution_action_type IS NOT NULL
  ),
  CHECK (
    -- SNOOZED requires snooze_until
    status != 'SNOOZED' OR snooze_until IS NOT NULL
  ),
  CHECK (
    -- DISMISSED requires resolution_note per resolution_action_enum
    status != 'DISMISSED' OR (resolution_note IS NOT NULL AND length(resolution_note) > 0)
  ),
  CHECK (
    -- BLOCKING severity cannot be DISMISSED
    NOT (severity = 'BLOCKING' AND status = 'DISMISSED')
  ),
  CHECK (
    -- AUTO_RESOLVED_BY_RESCAN requires the trigger pointer
    status != 'AUTO_RESOLVED_BY_RESCAN' OR auto_resolution_trigger_issue_id IS NOT NULL
  )
);
```

## ENUMs

### `status` — 5 values (post 2026-05-08 amendment)

| Value | Meaning |
| --- | --- |
| `OPEN` | Initial state; awaiting resolution |
| `RESOLVED` | User-driven resolution via one of the 13 actions in `resolution_action_enum` |
| `SNOOZED` | Carry-forward across runs; auto-clear on severity escalation per `rescan_policies` |
| `AUTO_RESOLVED_BY_RESCAN` | Block 14 Phase 08's re-scan determined the issue no longer applies after another issue was resolved |
| `DISMISSED` | Dismissed with reason — severity-restricted per `severity_enum` |

### `issue_group` — 5 values (per `issue_group_enum`)

```sql
CREATE TYPE issue_group_enum AS ENUM (
  'Missing Documents',
  'Needs Confirmation',
  'Possible Wrong Match',
  'Possible Tax-VAT Issue',
  'Unusual Transaction'
);
```

`Ready to Finalize` is a queue-state projection, NOT a row value here. Per the 2026-05-08 amendment.

### `subject_kind` — 6 values

The kinds of records issues can reference. `subject_id` is a UUID; the kind discriminates. Polymorphic FK; integrity via the `review_issues_subject_validator` trigger.

## `card_payload_json` shape

Frozen plain-language content for UI rendering. Per the 2026-05-08 Block 14 amendment, this column captures the AI-generated card content at issue-creation time so it doesn't drift if the underlying record changes.

```json
{
  "headline": "...",                       // ≤ 80 chars
  "explanation": "...",                    // ≤ 400 chars
  "recommended_action": "...",             // ≤ 120 chars per Block 14 scan fix
  "expand_pointer": {
    "kind": "transaction",
    "id": "...",
    "fields": ["counterparty_signature", "amount_signed", "transaction_date"]
  }
}
```

The `expand_pointer` is a live FK pointer per the Block 14 scan fix — the frozen card text doesn't update, but the expand-detail data resolves to live data when the user expands the card.

## Indexes (per `review_issues_index_schema`)

```sql
-- Queue view (the primary user surface)
CREATE INDEX idx_review_issues_queue
  ON review_issues(business_id, status, issue_group, severity DESC, created_at)
  WHERE status IN ('OPEN', 'SNOOZED');

-- Subject lookup (drill-down from a transaction / document)
CREATE INDEX idx_review_issues_subject
  ON review_issues(business_id, subject_kind, subject_id);

-- Assignment lookup (the "issues assigned to me" view)
CREATE INDEX idx_review_issues_assigned
  ON review_issues(business_id, assigned_to_user_id, status)
  WHERE assigned_to_user_id IS NOT NULL;

-- Snooze auto-clear lookup (Block 14 Phase 07 unsnooze pass)
CREATE INDEX idx_review_issues_snoozed
  ON review_issues(business_id, snooze_until)
  WHERE status = 'SNOOZED';
```

## RLS

Tenant isolation per `permission_matrix`. Per the `REVIEW_QUEUE_VIEW` surface, every role except no-business can SELECT.

```sql
CREATE POLICY review_issues_business_isolation ON review_issues
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

UPDATE / INSERT restricted by application code per `REVIEW_QUEUE_RESOLVE` / `REVIEW_ASSIGN` / `REVIEW_REGENERATE` surfaces.

## Audit events

Every state transition emits per `audit_event_taxonomy`:

| Event | Trigger |
| --- | --- |
| `REVIEW_ISSUE_CREATED` | INSERT |
| `REVIEW_ISSUE_RESOLVED` | status → RESOLVED |
| `REVIEW_ISSUE_DISMISSED` | status → DISMISSED |
| `REVIEW_ISSUE_SNOOZED` | status → SNOOZED |
| `REVIEW_ISSUE_SNOOZE_AUTO_CLEARED` | snooze invalidated by severity escalation |
| `REVIEW_AUTO_RESOLVED_BY_RESCAN` | status → AUTO_RESOLVED_BY_RESCAN |
| `REVIEW_ISSUE_REASSIGNED` | assigned_to_user_id update |
| `REVIEW_ISSUE_SELF_LINKED` | send_to_my_inbox action |
| `REVIEW_NOTE_ADDED` | resolution_note updated mid-flight |
| `REVIEW_CARD_REGENERATED` | card_payload_json regenerated |

## Cross-references

- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON for `card_payload_json` and `resolution_action_payload`
- `issue_group_enum` — closed 5-value enum
- `severity_enum` — closed 4-value enum
- `resolution_action_enum` — 13-value action vocabulary
- `issue_type_to_group_mapping` — runtime issue-type → group mapping
- `tool_ai_tier_metadata` — `card_content_tier_used` enum
- `review_issues_index_schema` — indexed query plans (Block 14)
- `review_issues_status_enum_migration` — migration adding AUTO_RESOLVED_BY_RESCAN
- `audit_log_policies` — `REVIEW_*` events
- `permission_matrix` — REVIEW_* surfaces
- Block 04 Phase 04 — canonical owner of this table (architecture)
- Block 14 Phase 01 — Block 14-side schema extensions
- 2026-05-08 decisions-log amendment — 8 added columns + status enum extension
