# Compensation Log Schema

**Category:** Schemas · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Defines the `compensation_log` table — the operational record written every time the Block 15 finalization lock sequence enters a compensating rollback (`COMPENSATING` workflow state). Each row captures the full sequence of rollback steps, their outcomes, and the partial-write state that existed when compensation was triggered. The table supports post-incident forensics, operator investigation, and the auto-retry-once decision gate.

---

## 1. Table definition

```sql
CREATE TABLE compensation_log (
  log_id                        uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Run linkage
  workflow_run_id               uuid NOT NULL
                                  REFERENCES workflow_runs(workflow_run_id),
  business_id                   uuid NOT NULL,

  -- Compensation timing
  compensation_started_at       timestamptz NOT NULL DEFAULT now(),
  compensation_completed_at     timestamptz,         -- NULL while in progress

  -- Overall outcome; set when compensation_completed_at is written
  compensation_outcome          compensation_outcome_enum,

  -- Per-step detail — JSONB array of step records (see Section 2)
  steps_json                    jsonb NOT NULL DEFAULT '[]'::jsonb,

  -- Human-readable description of the partial state when compensation started
  partial_write_description     text NOT NULL,

  -- True if Block 15 Phase 09 queued an auto-retry-once attempt
  -- (only possible when failure occurred before Object Lock was applied — Steps 1 or 2)
  auto_retry_queued             boolean NOT NULL DEFAULT false
);

CREATE TYPE compensation_outcome_enum AS ENUM ('SUCCEEDED', 'FAILED');

-- One compensation attempt per run per invocation;
-- a second attempt (e.g., auto-retry also failed) inserts a second row
CREATE INDEX idx_compensation_log_run
  ON compensation_log(workflow_run_id, compensation_started_at DESC);

CREATE INDEX idx_compensation_log_business
  ON compensation_log(business_id, compensation_started_at DESC);
```

---

## 2. Field reference

| Field | Type | Notes |
|---|---|---|
| `log_id` | UUID v7 PK | Monotonically increasing per `data_layer_conventions_policy` |
| `workflow_run_id` | UUID FK | References `workflow_runs.workflow_run_id`; the run that entered `COMPENSATING` |
| `business_id` | UUID | Tenant scope; no RLS restrictions beyond business isolation (Section 5) |
| `compensation_started_at` | timestamptz | Set when `COMPENSATING` state is entered and this row is inserted |
| `compensation_completed_at` | timestamptz | Set when the compensation sequence finishes; `NULL` while rollback is in progress |
| `compensation_outcome` | enum | `SUCCEEDED` — rollback completed, partial state cleaned up; `FAILED` — rollback itself failed, operator intervention required |
| `steps_json` | JSONB | Array of step records; see Section 3 |
| `partial_write_description` | text | Human-readable description of the partial-write state at the time compensation was triggered (e.g., "Ledger entries written; archive bundle build failed at Step 2 before Object Lock applied") |
| `auto_retry_queued` | boolean | `true` if Block 15 Phase 09 determined the failure was pre-Object-Lock and queued an auto-retry-once attempt before invoking this compensation record's rollback |

---

## 3. `steps_json` structure

Each element in the `steps_json` array corresponds to one rollback step, executed in reverse order of the lock sequence (Step 5 → Step 1). Steps that were never reached (because the original failure occurred earlier) are not included.

```typescript
interface CompensationStep {
  /** Name of the rollback step; mirrors lock sequence step names in reverse */
  step_name:
    | 'revert_manifest_promotion'
    | 'abandon_tsa_token'
    | 'mark_object_lock_orphan'
    | 'delete_staging_bundle'
    | 'delete_locked_ledger_entries';

  /** Current status of this rollback step */
  status: 'PENDING' | 'COMPLETED' | 'FAILED';

  /** Wall-clock time this step was attempted */
  attempted_at: string;       // ISO 8601 timestamptz

  /** Wall-clock time this step completed; null if PENDING or FAILED */
  completed_at: string | null;

  /** Error message if status = FAILED; null otherwise */
  error_message: string | null;
}
```

The `steps_json` array is updated in-place as the compensation sequence progresses. Each step update is a narrow JSONB path update (`jsonb_set`) rather than a full-row overwrite, to minimize lock contention on the row during active rollback.

---

## 4. Invariants

**One row per compensation attempt:** a run that enters `COMPENSATING` once produces one `compensation_log` row. If the auto-retry path is taken — the first compensation succeeded, the run returned to `AWAITING_APPROVAL`, the second finalization attempt also failed, and a second `COMPENSATING` state is entered — a second `compensation_log` row is inserted. There is no `UNIQUE` constraint on `workflow_run_id` because of this multi-attempt possibility.

**No UPDATE after completion:** once `compensation_completed_at` is set and `compensation_outcome` is populated, the row must not be modified. The only permitted mutations during an active compensation are: `steps_json` path updates (step status progresses) and the final write of `compensation_completed_at` and `compensation_outcome` together.

**Object Lock orphan:** if the original failure occurred after Object Lock was applied (Steps 3, 4, or 5), the compensation sequence records a `mark_object_lock_orphan` step with status `COMPLETED`. The bundle object cannot be deleted by design; the `archive_packages` row for that bundle is flagged `COMPENSATION_ORPHAN`. Operators are alerted. This step does not constitute a `FAILED` compensation outcome.

**`partial_write_description` is mandatory:** the description must be written at the time compensation begins. An empty string is not permitted. This field is the first human-readable record of what went wrong, visible to operators before the `steps_json` array is fully populated.

---

## 5. RLS

`compensation_log` is operational infrastructure data. No per-role row-level restriction beyond business isolation is applied. Any role with an active session on the `business_id` may SELECT. No application role may INSERT or UPDATE outside the Block 15 compensation tools; this is enforced via the `app.compensation_active` session variable gate:

```sql
CREATE POLICY compensation_log_insert_compensation
  ON compensation_log
  FOR INSERT
  WITH CHECK (
    current_setting('app.compensation_active', true) = 'true'
  );

CREATE POLICY compensation_log_update_compensation
  ON compensation_log
  FOR UPDATE
  USING (
    current_setting('app.compensation_active', true) = 'true'
  );

CREATE POLICY compensation_log_read_business_roles
  ON compensation_log
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

CREATE POLICY compensation_log_no_delete
  ON compensation_log
  FOR DELETE
  USING (false);
```

---

## 6. Mobile rejection

`compensation_log` writes are performed exclusively by Block 15 Phase 09 system tools. No write surface is exposed to any client, including mobile. Block 15 lock sequence tools are listed in `mobile_write_rejection_endpoints`. Operators may read compensation logs via the admin console; read access is not mobile-restricted but is available only to Owner and Admin roles.

---

## 7. Audit events

| Event | Severity | When |
|---|---|---|
| `COMPENSATION_LOG_APPENDED` | HIGH | Emitted when a new `compensation_log` row is inserted (i.e., when a run enters `COMPENSATING` and the log row is first created). Payload includes `log_id`, `workflow_run_id`, `business_id`, `partial_write_description`, `auto_retry_queued` |

`COMPENSATION_LOG_APPENDED` is HIGH severity because the `COMPENSATING` state represents a serious operational event — a partial-write failure during finalization. The event is emitted on the business-scoped hash chain. It is a domain `ARCHIVE` event per `audit_log_policies`.

Note: `WORKFLOW_RUN_COMPENSATING_STARTED` (HIGH, `WORKFLOW` domain) is also emitted when the run transitions to `COMPENSATING` — this is a distinct event owned by Block 03. The two events are complementary: `WORKFLOW_RUN_COMPENSATING_STARTED` records the state transition; `COMPENSATION_LOG_APPENDED` records the compensation infrastructure row.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; JSONB canonical encoding for `steps_json`; timestamptz conventions; no float currency in payloads
- `lock_sequence_policies` — the 5-step lock sequence that produces compensation events; Section 3 (compensation procedure); `app.compensation_active` session variable; `app.adjustment_lock_active` for adjustment path
- `period_lock_status_schema` — `archive_packages` `COMPENSATION_ORPHAN` flag referenced in step invariants; `is_current` update during compensation
- `workflow_state_enum` — `COMPENSATING` state definition; `FINALIZING → COMPENSATING` and `COMPENSATING → FAILED` / `COMPENSATING → AWAITING_APPROVAL` transitions; canonical 10-value state set
- `audit_log_policies` — `COMPENSATION_LOG_APPENDED` event naming; `ARCHIVE` domain; HIGH severity rationale; business-scoped hash chain
- `audit_event_taxonomy` — `ARCHIVE` domain events; `WORKFLOW_RUN_COMPENSATING_STARTED` and `WORKFLOW_RUN_COMPENSATING_COMPLETED` sibling events
- `mobile_write_rejection_endpoints` — Block 15 lock sequence tools listed as mobile-rejected
- `locked_ledger_entries_schema` — `delete_locked_ledger_entries` step target; `app.compensation_active` DELETE policy
- Block 15 Phase 09 — failure handling and rollback architecture; auto-retry-once logic; `auto_retry_queued` flag
- Block 03 Phase 07 — resumability framework; step checkpointing during compensation
- Block 03 Phase 04 — `transitionRun()` for `FINALIZING → COMPENSATING` and `COMPENSATING → FAILED` transitions
