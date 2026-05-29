# Snooze Carry-Forward Schema

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

Defines the `snooze_records` table that persists every snooze action applied to a review issue, and the carry-forward invariants governing how snoozed issues resurface across workflow runs. The snooze mechanism is a non-closing action: it transitions the issue to `SNOOZED` status without resolving it, and the engine carries it forward automatically via `review_queue.unsnooze_at_run_start`.

---

## 1. Table definition

```sql
CREATE TABLE snooze_records (
  snooze_id               uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Issue linkage
  review_issue_id         uuid NOT NULL
                            REFERENCES review_issues(review_issue_id),

  -- Tenant context
  business_id             uuid NOT NULL,

  -- Run context — the run in which the snooze was set
  workflow_run_id         uuid NOT NULL
                            REFERENCES workflow_runs(workflow_run_id),

  -- Actor
  snoozed_by_user_id      uuid NOT NULL
                            REFERENCES users(id),

  -- Timestamps
  snoozed_at              timestamptz NOT NULL DEFAULT now(),

  -- Target run for resurfacing; NULL = indefinite snooze
  -- Only permitted for severity LOW (see invariants below)
  snooze_until_run_id     uuid
                            REFERENCES workflow_runs(workflow_run_id),

  -- Mandatory reason, minimum 5 characters
  snooze_reason           text NOT NULL
                            CHECK (char_length(snooze_reason) >= 5),

  -- How many consecutive runs this issue has been carried forward
  carry_forward_count     integer NOT NULL DEFAULT 0
                            CHECK (carry_forward_count >= 0),

  -- Platform limit; Owner/Admin may raise to 5 via business settings
  max_carry_forward       integer NOT NULL DEFAULT 3
                            CHECK (max_carry_forward BETWEEN 1 AND 5),

  -- Set to true when carry_forward_count reaches max_carry_forward
  auto_escalated          boolean NOT NULL DEFAULT false,

  -- Constraints
  CHECK (
    -- max_carry_forward cannot exceed 5 (platform ceiling)
    max_carry_forward <= 5
  ),
  CHECK (
    -- carry_forward_count never exceeds max_carry_forward
    carry_forward_count <= max_carry_forward
  )
);

CREATE INDEX idx_snooze_records_issue
  ON snooze_records(review_issue_id, snoozed_at DESC);

CREATE INDEX idx_snooze_records_business_run
  ON snooze_records(business_id, workflow_run_id);

CREATE INDEX idx_snooze_records_until_run
  ON snooze_records(snooze_until_run_id)
  WHERE snooze_until_run_id IS NOT NULL;
```

---

## 2. Field reference

| Field | Type | Notes |
|---|---|---|
| `snooze_id` | UUID v7 PK | Monotonically increasing per `data_layer_conventions_policy` |
| `review_issue_id` | UUID FK | References `review_issues.review_issue_id` |
| `business_id` | UUID | Tenant scope; RLS-enforced (see Section 4) |
| `workflow_run_id` | UUID FK | The run in which the snooze was set |
| `snoozed_by_user_id` | UUID FK | Actor who applied the snooze |
| `snoozed_at` | timestamptz | Wall-clock time of the snooze action |
| `snooze_until_run_id` | UUID FK nullable | Next run in which the issue will resurface; `NULL` = indefinite |
| `snooze_reason` | text | Mandatory, min 5 chars |
| `carry_forward_count` | integer | Incremented by `review_queue.unsnooze_at_run_start` on each pass where the issue is re-snoozed |
| `max_carry_forward` | integer | Default 3; Owner/Admin may raise to 5 |
| `auto_escalated` | boolean | Set to `true` when `carry_forward_count` reaches `max_carry_forward` |

---

## 3. Invariants

### 3.1 Severity-based snooze eligibility

| Severity | Snooze permitted | Notes |
|---|---|---|
| `LOW` | Yes — including indefinite (`snooze_until_run_id IS NULL`) | Indefinite snooze is restricted to `LOW` only |
| `MEDIUM` | Yes — but `snooze_until_run_id` must be set (cannot be indefinite) | Maximum one period of snooze unless re-applied |
| `HIGH` | Maximum once per issue lifetime | A second snooze on the same issue is rejected if `carry_forward_count >= 1` |
| `BLOCKING` | Never | Attempting to snooze a `BLOCKING` issue returns HTTP 422 with `REVIEW_SNOOZE_REJECTED_SEVERITY`; no row is written |

These constraints are enforced at the application layer before INSERT. No CHECK constraint encodes them because severity is a column on `review_issues`, not on `snooze_records`.

### 3.2 Indefinite snooze restriction

`snooze_until_run_id IS NULL` is only accepted when the issue's severity at the time of snooze is `LOW`. Attempting to create an indefinite snooze for `MEDIUM` is rejected with `REVIEW_SNOOZE_REJECTED_INDEFINITE_NOT_PERMITTED`.

### 3.3 Carry-forward counter logic

On each call to `review_queue.unsnooze_at_run_start` (the engine that resurfaces snoozed issues at the start of every run):

1. For each issue with `status = SNOOZED` and `snooze_until_run_id` matching the current `workflow_run_id` (or `snooze_until_run_id IS NULL` for indefinite snoozes that are being manually unsnoozed), the tool resets the issue to `OPEN`.
2. If the issue is re-snoozed by the user within the same run (i.e., a new `snooze_records` row is inserted for the same `review_issue_id`), `carry_forward_count` is incremented by 1 on the new row.
3. When `carry_forward_count` equals `max_carry_forward` on the new snooze row, `auto_escalated` is set to `true` and the `REVIEW_ISSUE_CARRY_FORWARD_ESCALATED` audit event is emitted. The issue is still snoozed; the escalation flag is advisory to the Owner/Admin.

### 3.4 Severity escalation auto-clear

If a re-scan (Block 14 Phase 08) elevates an issue from `MEDIUM` to `HIGH` while the issue is `SNOOZED`, the snooze is automatically cleared by the re-scan tool. The snooze record retains its row (it is append-only); the issue's `status` transitions to `OPEN` and `REVIEW_ISSUE_SNOOZE_AUTO_CLEARED` is emitted. The escalated `HIGH` severity issue is now subject to the one-snooze-lifetime limit.

### 3.5 Finalization snapshot

When a run reaches finalization (Block 15), the `review_issues` snapshot captured in `archive.locked_ledger_entries` includes the `SNOOZED` status and snooze metadata as it stood at finalization time. The `snooze_records` row persists in the operational database. The next run's `review_queue.unsnooze_at_run_start` pass resurfaces the issue for the new run.

---

## 4. RLS

```sql
-- Tenant isolation: users may only read snooze records for their business
CREATE POLICY snooze_records_tenant_isolation
  ON snooze_records
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

-- Insert is gated by application logic, not RLS; application enforces
-- REVIEW_QUEUE_RESOLVE permission surface before writing
CREATE POLICY snooze_records_no_update
  ON snooze_records
  FOR UPDATE
  USING (false);

CREATE POLICY snooze_records_no_delete
  ON snooze_records
  FOR DELETE
  USING (false);
```

Snooze records are append-only. The `auto_escalated` flag is set by the INSERT path of the carry-forward record, not via UPDATE.

---

## 5. The `review_queue.unsnooze_at_run_start` tool

`review_queue.unsnooze_at_run_start` is the engine that resurfaces snoozed issues. It is registered via Block 03 Phase 03's `engine.registerTool` with the following declaration:

```typescript
engine.registerTool({
  name: "review_queue.unsnooze_at_run_start",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  audit_events: ["REVIEW_ISSUE_SNOOZE_AUTO_CLEARED"],
  description_ref: "Docs/sub/tools/tool_review_queue_unsnooze_at_run_start.md",
});
```

**Execution placement:** the tool runs as the first tool of the first phase (`INGESTION` for `OUT_MONTHLY` / `IN_MONTHLY`; `ADJUSTMENT_INTAKE` for `OUT_ADJUSTMENT` / `IN_ADJUSTMENT`) of every run. This guarantees execution before any phase-specific gate or work runs.

**Idempotency:** re-invocation for a run with no snoozed issues is a no-op. Re-invocation for a run that already unsnoozed all eligible issues is also a no-op.

**Algorithm:**

1. Query `review_issues` for all rows where `business_id = $run.business_id` AND `status = SNOOZED` AND (`snooze_until_run_id = $current_run_id` OR `snooze_until_run_id IS NULL`).
2. For each qualifying row, set `status = OPEN`, clear `snoozed_at`, `snoozed_by`, `snoozed_until` columns on `review_issues`.
3. Emit `REVIEW_ISSUE_SNOOZE_AUTO_CLEARED` per row (aggregate emit for large volumes per `audit_event_taxonomy`'s volume guidance).

---

## 6. Mobile rejection

Applying or modifying a snooze is a write action. Mobile clients attempting to invoke the snooze surface receive HTTP 405 `MOBILE_WRITE_REJECTED`. The snooze action endpoint is listed in `mobile_write_rejection_endpoints`. Read access to snoozed issues (the "Snoozed" sub-tab in the review queue) is available on mobile.

---

## 7. Audit events

| Event | Severity | When |
|---|---|---|
| `REVIEW_ISSUE_SNOOZED` | LOW | A snooze record is successfully written; issue transitions to `SNOOZED` |
| `REVIEW_ISSUE_CARRY_FORWARD_ESCALATED` | MEDIUM | `carry_forward_count` reaches `max_carry_forward` on a new snooze row |

Both events are emitted via `emitAudit()` on the business-scoped hash chain per `audit_log_policies`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; canonical JSON for audit event payloads; `numeric` types
- `review_issue_card_schema` — `review_issues.review_issue_id` FK target; `status` enum (`SNOOZED`, `OPEN`)
- `resolution_action_payload_schema` — `snooze` action payload (action #8); severity-eligibility table
- `severity_enum` — closed 4-value set `{LOW, MEDIUM, HIGH, BLOCKING}`; snooze eligibility per severity
- `audit_log_policies` — `REVIEW_ISSUE_SNOOZED`, `REVIEW_ISSUE_CARRY_FORWARD_ESCALATED` event naming
- `audit_event_taxonomy` — `REVIEW` domain canonical events
- `mobile_write_rejection_endpoints` — snooze endpoint listed as a mobile-rejected write surface
- `tool_naming_convention_policy` — `review_queue.unsnooze_at_run_start` tool name; `review_queue` namespace
- Block 14 Phase 07 — snooze + cross-run carry-forward architecture
- Block 03 Phase 03 — `engine.registerTool` boot framework; first-tool placement rule
- Block 03 Phase 07 — resumability; idempotent tool invocation
- Block 15 Phase 04 — finalization snapshot that captures `SNOOZED` issue state
