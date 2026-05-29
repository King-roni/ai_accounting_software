# Schema: match_proposals

**Block:** Matching  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`match_proposals` records every proposed match between a transaction and an invoice within a workflow run. It is the authoritative state store for the matching phase: proposals are created by `matching.propose`, confirmed by `matching.confirm`, rejected by `matching.reject_match`, and auto-confirmed by the matching engine when confidence exceeds the auto-confirm threshold.

Each row represents one candidate pairing at a point in time. A transaction may have multiple proposal rows across different statuses within a run (e.g. one REJECTED and one subsequently CONFIRMED), but only one active proposal per transaction at any time is enforced by a partial unique index.

---

## DDL

```sql
CREATE TYPE match_level_enum AS ENUM (
  'EXACT',
  'STRONG_PROBABLE',
  'WEAK_POSSIBLE',
  'NO_MATCH'
);

CREATE TYPE match_status_enum AS ENUM (
  'PROPOSED',
  'CONFIRMED',
  'REJECTED',
  'AUTO_CONFIRMED',
  'SUPERSEDED',
  'EXCEPTION_DOCUMENTED'
);

CREATE TABLE match_proposals (
  id                UUID          NOT NULL DEFAULT gen_uuid_v7(),
  run_id            UUID          NOT NULL
                      REFERENCES workflow_runs(id)
                      ON DELETE RESTRICT,
  transaction_id    UUID          NOT NULL
                      REFERENCES transactions(id)
                      ON DELETE RESTRICT,
  invoice_id        UUID          NULL
                      REFERENCES invoices(id)
                      ON DELETE RESTRICT,
  match_level       match_level_enum NOT NULL,
  composite_score   DECIMAL(5,4)  NOT NULL
                      CHECK (composite_score >= 0 AND composite_score <= 1),
  score_breakdown   JSONB         NOT NULL DEFAULT '{}',
  status            match_status_enum NOT NULL DEFAULT 'PROPOSED',
  proposed_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
  confirmed_at      TIMESTAMPTZ   NULL,
  confirmed_by      UUID          NULL
                      REFERENCES auth.users(id)
                      ON DELETE SET NULL,
  rejection_reason  TEXT          NULL,
  rejected_at       TIMESTAMPTZ   NULL,
  rejected_by       UUID          NULL
                      REFERENCES auth.users(id)
                      ON DELETE SET NULL,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT match_proposals_pkey PRIMARY KEY (id),

  -- Rejection reason must be present when status is REJECTED
  CONSTRAINT chk_rejection_reason
    CHECK (
      (status != 'REJECTED') OR
      (status  = 'REJECTED' AND rejection_reason IS NOT NULL AND length(trim(rejection_reason)) >= 10)
    ),

  -- confirmed_at and confirmed_by must be co-present
  CONSTRAINT chk_confirmation_fields
    CHECK (
      (confirmed_at IS NULL AND confirmed_by IS NULL) OR
      (confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL)
    )
);
```

---

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | Primary key. `gen_uuid_v7()`. |
| `run_id` | UUID | No | FK to `workflow_runs(id)`. The run in which this proposal was created. |
| `transaction_id` | UUID | No | FK to `transactions(id)`. The transaction being matched. |
| `invoice_id` | UUID | Yes | FK to `invoices(id)`. `NULL` when no invoice candidate was found (match_level = 'NO_MATCH'). |
| `match_level` | match_level_enum | No | Qualitative match tier. See Match Level Definitions below. |
| `composite_score` | DECIMAL(5,4) | No | Weighted composite score 0.0–1.0. Computed from `score_breakdown` dimensions. |
| `score_breakdown` | JSONB | No | Per-dimension scores. See Score Breakdown below. |
| `status` | match_status_enum | No | Current lifecycle status. See Status Definitions below. |
| `proposed_at` | TIMESTAMPTZ | No | When the proposal was created. |
| `confirmed_at` | TIMESTAMPTZ | Yes | When a human or auto-confirm confirmed the match. |
| `confirmed_by` | UUID | Yes | User who confirmed. `NULL` for `AUTO_CONFIRMED`. |
| `rejection_reason` | TEXT | Yes | Human-supplied reason for rejection. Required when status = `REJECTED`. |
| `rejected_at` | TIMESTAMPTZ | Yes | When the rejection was recorded. |
| `rejected_by` | UUID | Yes | User who rejected. |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |

---

## Match Level Definitions

| Level | Meaning | Typical composite_score range |
|---|---|---|
| `EXACT` | All scoring dimensions match exactly or within negligible tolerance | 0.95–1.0 |
| `STRONG_PROBABLE` | Strong multi-dimension match; minor discrepancy in one dimension | 0.80–0.94 |
| `WEAK_POSSIBLE` | Partial match; one or more dimensions are uncertain | 0.50–0.79 |
| `NO_MATCH` | No credible invoice candidate found | 0.0–0.49 or null invoice |

---

## Status Definitions

| Status | Meaning | Terminal |
|---|---|---|
| `PROPOSED` | Created by the engine; awaiting human review or auto-confirm | No |
| `AUTO_CONFIRMED` | Confirmed by the engine based on threshold score; no human action | Yes (within run) |
| `CONFIRMED` | Confirmed by a human reviewer | Yes (within run) |
| `REJECTED` | Rejected by a human reviewer via `matching.reject_match` | Reversible pre-finalization |
| `SUPERSEDED` | Replaced by a newer proposal for the same transaction | Yes |
| `EXCEPTION_DOCUMENTED` | Rejection confirmed as a documented exception | Yes |

---

## Score Breakdown JSONB

```jsonc
{
  "amount_score":    0.98,
  "date_score":      0.90,
  "reference_score": 1.00,
  "vendor_score":    0.87,
  "currency_score":  1.00
}
```

All dimension scores are 0.0–1.0. The `composite_score` is a weighted sum as defined in `match_scoring_weights_policy.md`.

---

## Indexes

```sql
-- One active proposal per transaction per run
-- Prevents two concurrent PROPOSED rows for the same transaction in the same run
CREATE UNIQUE INDEX idx_match_proposals_active
  ON match_proposals (run_id, transaction_id)
  WHERE status NOT IN ('REJECTED', 'SUPERSEDED');

-- Fast status-based queries within a run (review queue, phase completion check)
CREATE INDEX idx_match_proposals_run_status
  ON match_proposals (run_id, status);

-- Lookup by transaction across runs (matching history view)
CREATE INDEX idx_match_proposals_transaction
  ON match_proposals (transaction_id);
```

---

## Row-Level Security

```sql
ALTER TABLE match_proposals ENABLE ROW LEVEL SECURITY;

CREATE POLICY match_proposals_service_write
  ON match_proposals
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY match_proposals_business_read
  ON match_proposals
  FOR SELECT
  TO authenticated
  USING (
    run_id IN (
      SELECT wr.id
      FROM   workflow_runs wr
      JOIN   business_entities be ON be.id = wr.business_id
      JOIN   org_members om        ON om.business_id = be.id
      WHERE  om.user_id = auth.uid()
    )
  );
```

---

## Audit Events

| Event | Severity | When emitted |
|---|---|---|
| `MATCHING_MATCH_PROPOSED` | LOW | New proposal row created |
| `MATCHING_MATCH_CONFIRMED` | LOW | Status set to `CONFIRMED` by human |
| `MATCHING_MATCH_AUTO_CONFIRMED` | LOW | Status set to `AUTO_CONFIRMED` by engine |
| `MATCHING_MATCH_REJECTED` | LOW / MEDIUM | Status set to `REJECTED` (MEDIUM if exception documented) |

All events include `run_id`, `match_proposal_id`, `transaction_id`, `invoice_id`, `match_level`, and `composite_score`.

---

## Integration Points

| Tool or system | Relationship |
|---|---|
| `tool_match_propose.md` | Creates `PROPOSED` rows |
| `tool_match_confirm.md` | Transitions `PROPOSED` to `CONFIRMED` or `AUTO_CONFIRMED` |
| `matching.reject_match` | Transitions to `REJECTED`; may also set `SUPERSEDED` on prior row |
| Review queue | Reads proposals in `PROPOSED` status to surface for human review |
| Phase gate | Counts non-terminal proposals to determine if MATCHING phase is complete |
| Finalization gate | Asserts no `PROPOSED` rows remain for the run |

---

## Related Documents

- `tool_match_propose.md` — creates proposals
- `tool_match_confirm.md` — confirms proposals
- `tool_match_reject.md` — rejects proposals
- `matching_exception_schema.md` — exception records linked to rejected proposals
- `match_scoring_weights_policy.md` — composite score weighting rules
- `match_scoring_calibration_policy.md` — score threshold calibration
- `matching_policy.md` — matching lifecycle policy
- `out_exception_documented_policy.md` — exception documentation rules
- `match_signal_evidence_schema.md` — signal evidence supporting score breakdown
