# approval_record_schema

**Block:** 15 — Finalization & Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `approval_records` table stores every approval request and decision made within the platform. A record is created when a workflow run reaches `AWAITING_APPROVAL` status and an approval is required before finalization. The same table is used for period amendment approvals, step-up override approvals, and data erasure approvals. Each record has a lifecycle: PENDING → APPROVED or REJECTED; or PENDING → EXPIRED if the approver does not act before `expires_at`.

A run may have at most one active (PENDING or APPROVED) FINALIZATION approval record at any time. The partial unique index enforces this constraint at the database level.

---

## Table definition

```sql
CREATE TABLE approval_records (
  id                uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  run_id            uuid          REFERENCES workflow_runs(id),           -- nullable for non-run approvals
  request_id        uuid          NOT NULL,                               -- client-supplied idempotency key
  approver_id       uuid          NOT NULL REFERENCES auth.users(id),
  approval_type     text          NOT NULL
                                  CHECK (approval_type IN (
                                    'FINALIZATION',
                                    'PERIOD_AMENDMENT',
                                    'STEP_UP_OVERRIDE',
                                    'DATA_ERASURE'
                                  )),
  status            text          NOT NULL DEFAULT 'PENDING'
                                  CHECK (status IN (
                                    'PENDING',
                                    'APPROVED',
                                    'REJECTED',
                                    'EXPIRED',
                                    'SUPERSEDED'
                                  )),
  requested_by      uuid          NOT NULL REFERENCES auth.users(id),
  requested_at      timestamptz   NOT NULL DEFAULT now(),
  decided_at        timestamptz,
  decision_note     text,                                                 -- optional free-text from approver
  expires_at        timestamptz   NOT NULL,                               -- defaults to requested_at + interval from approval_expiry_policy
  step_up_token_id  uuid          REFERENCES step_up_tokens(id),         -- required for FINALIZATION; nullable for others
  created_at        timestamptz   NOT NULL DEFAULT now()
);
```

### Partial unique index — one active approval per run

```sql
CREATE UNIQUE INDEX uq_approval_records_run_active
  ON approval_records (run_id, approval_type)
  WHERE status IN ('APPROVED', 'PENDING');
```

This index prevents two simultaneously active (PENDING or APPROVED) records for the same run and approval_type. When a new approval is requested for a run that already has a PENDING record, the existing record must first be set to SUPERSEDED.

---

## Column notes

- `id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing within a second, enabling efficient range scans by creation time.
- `run_id` — FK to `workflow_runs(id)`. Nullable to support non-run approvals (e.g., `DATA_ERASURE` approvals that reference a subject ID rather than a run). For `FINALIZATION` and `PERIOD_AMENDMENT` types, `run_id` is always non-null.
- `request_id` — client-supplied UUID used for idempotency. If the same `request_id` is submitted twice, the second call returns the existing record without creating a duplicate. Clients should use `gen_random_uuid()` for this value.
- `approver_id` — the org member who is authorized to approve or reject. Determined by the approval routing logic in `issue_group_routing_policy.md`. For FINALIZATION, the approver is the org owner or a member with the `CAN_APPROVE_FINALIZATION` capability.
- `approval_type` — the type of action requiring approval. Governs expiry window, step-up requirements, and routing.
- `status` — lifecycle state. Transitions: PENDING → APPROVED, PENDING → REJECTED, PENDING → EXPIRED (by background job), PENDING → SUPERSEDED (when re-requested).
- `requested_by` — the user who triggered the approval request (e.g., the accountant who submitted the run for finalization).
- `decided_at` — set when status transitions to APPROVED or REJECTED. Null while PENDING.
- `decision_note` — optional free-text entered by the approver. Not required for APPROVED decisions; recommended for REJECTED decisions to explain why.
- `expires_at` — the deadline for the approver to act. After this timestamp the background expiry job sets `status = EXPIRED`. The default window is 24 hours, configurable per `approval_expiry_policy.md`.
- `step_up_token_id` — nullable FK to `step_up_tokens(id)`. Required for `FINALIZATION` approvals: the approver must complete a step-up MFA challenge before their approval is accepted. The token must be in VALID status and must not have expired. See `step_up_auth_for_workflow_approval_policy.md`.
- `created_at` — insertion timestamp. Always set to `now()` at creation; never updated.

---

## Indexes

```sql
-- For engine gate check: find the most recent APPROVED FINALIZATION record for a run
CREATE INDEX idx_approval_records_run_status
  ON approval_records (run_id, status)
  WHERE run_id IS NOT NULL;

-- For approver inbox: find all PENDING records assigned to a specific approver
CREATE INDEX idx_approval_records_approver_status
  ON approval_records (approver_id, status)
  WHERE status = 'PENDING';
```

---

## Row-level security

```sql
ALTER TABLE approval_records ENABLE ROW LEVEL SECURITY;

-- Approver: can read their own PENDING approvals; can update to APPROVED or REJECTED
CREATE POLICY approval_records_approver_read
  ON approval_records FOR SELECT
  USING (approver_id = auth.uid());

CREATE POLICY approval_records_approver_update
  ON approval_records FOR UPDATE
  USING (approver_id = auth.uid() AND status = 'PENDING')
  WITH CHECK (status IN ('APPROVED', 'REJECTED'));

-- Requester: can read their own requests (any status)
CREATE POLICY approval_records_requester_read
  ON approval_records FOR SELECT
  USING (requested_by = auth.uid());

-- Org owner: can read all approval records for their business
CREATE POLICY approval_records_owner_read
  ON approval_records FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM org_members om
      JOIN   workflow_runs wr ON wr.business_id = om.business_id
      WHERE  om.user_id = auth.uid()
        AND  om.role = 'OWNER'
        AND  wr.id = approval_records.run_id
    )
  );

-- Service role: unrestricted (used by engine and background jobs)
CREATE POLICY approval_records_service_role
  ON approval_records FOR ALL
  USING (auth.role() = 'service_role');
```

---

## Approval expiry

The default expiry window for all approval types is 24 hours from `requested_at`. This window is configurable per `approval_expiry_policy.md`. A Supabase scheduled function runs every 15 minutes and sets `status = 'EXPIRED'` for all rows where `expires_at < now() AND status = 'PENDING'`. The expiry job emits `APPROVAL_EXPIRED` (severity LOW) for each record it expires.

---

## Audit events

| Event | Severity | Trigger |
|---|---|---|
| `APPROVAL_REQUESTED` | LOW | New approval_records row inserted with status = PENDING |
| `APPROVAL_GRANTED` | LOW | status transitions to APPROVED |
| `APPROVAL_REJECTED` | MEDIUM | status transitions to REJECTED |
| `APPROVAL_EXPIRED` | LOW | status transitions to EXPIRED via background job |

Audit payloads include `approval_record_id`, `run_id`, `approval_type`, `approver_id`, `requested_by`, and (for GRANTED) `force_override: bool` to distinguish normal approvals from admin overrides described in `approval_timeout_runbook.md`.

---

## Cross-references

- `approval_expiry_policy.md` — defines the 24 h default window and per-type overrides
- `step_up_auth_for_workflow_approval_policy.md` — step-up requirements for FINALIZATION
- `step_up_token_schema.md` — step_up_tokens table DDL
- `workflow_run_approvals_schema.md` — earlier approval schema (legacy); this table supersedes it for new approval types
- `runbooks/approval_timeout_runbook.md` — handling EXPIRED records
- `tool_finalization_gate_check.md` — check 2 queries this table

---

## Related Documents

- `approval_expiry_policy.md`
- `step_up_token_schema.md`
- `tool_finalization_gate_check.md`
- `runbooks/approval_timeout_runbook.md`
- `workflow_run_schema.md`
