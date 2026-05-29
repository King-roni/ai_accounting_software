# Match Records Schema

**Category:** Schemas · Block 10 — Matching  
**Owner:** matching  
**Last updated:** 2026-05-17

---

## 1. Purpose

DDL and field reference for the `match_records` table. This table holds the **permanent Operational-zone record** of every confirmed match between a transaction and an invoice. It is distinct from `match_proposals`, which are ephemeral Processing-zone records created during matching candidate generation.

The lifecycle distinction is:
- `match_proposals` — transient, created during each workflow run's matching phase; discarded after the run finalizes.
- `match_records` — permanent; created when a match is confirmed (auto or human); retained for the full 7-year statutory retention period.

This schema is the authoritative reference for `reference/match_level_enum.md`, which defines the `match_level_enum` values used in this table.

---

## 2. DDL

```sql
CREATE TABLE match_records (
  id                   uuid          NOT NULL DEFAULT gen_uuid_v7(),
  run_id               uuid          NOT NULL REFERENCES workflow_runs(id) ON DELETE RESTRICT,
  business_id          uuid          NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  transaction_id       uuid          NOT NULL REFERENCES transactions(id) ON DELETE RESTRICT,
  invoice_id           uuid          NULL     REFERENCES invoices(id) ON DELETE RESTRICT,
  -- NULL when the match outcome is UNMATCHED_EXCEPTION (transaction has no invoice counterpart).
  match_proposal_id    uuid          NULL     REFERENCES match_proposals(id) ON DELETE SET NULL,
  -- FK to match_proposals(id). Set NULL when the proposal is purged after finalization.
  -- The match_record persists even after the proposal is purged.
  final_match_level    match_level_enum NOT NULL,
  final_status         match_status_enum NOT NULL,
  confirmed_at         timestamptz   NULL,
  confirmed_by         uuid          NULL,
  -- FK to auth.users(id). NULL for auto-confirmed matches (EXACT level or confidence >= threshold).
  exception_note       text          NULL,
  -- Populated when final_status = 'EXCEPTION_DOCUMENTED'. Free-text explanation by accountant.
  created_at           timestamptz   NOT NULL DEFAULT now(),

  CONSTRAINT match_records_pkey PRIMARY KEY (id)
);
```

---

## 3. Unique Constraint

```sql
-- One active confirmed match per transaction.
-- REJECTED and SUPERSEDED matches are excluded so a transaction can be re-matched
-- after a rejection or amendment.
CREATE UNIQUE INDEX uq_match_records_transaction_active
  ON match_records (transaction_id)
  WHERE final_status NOT IN ('REJECTED', 'SUPERSEDED');
```

This constraint enforces the invariant that each transaction has at most one active confirmed match at any time. A transaction may have multiple historical match record rows (e.g., one REJECTED and one CONFIRMED), but only one non-rejected, non-superseded row is permitted.

---

## 4. Indexes

```sql
-- Primary run-scoped lookup (match phase summary, finalization checks)
CREATE INDEX idx_match_records_run_id
  ON match_records (run_id);

-- Business-scoped lookup (review queue, accountant dashboard)
CREATE INDEX idx_match_records_business_id_status
  ON match_records (business_id, final_status);

-- Invoice lookup (check if an invoice is already matched)
CREATE INDEX idx_match_records_invoice_id
  ON match_records (invoice_id)
  WHERE invoice_id IS NOT NULL;

-- Transaction lookup (history of all matches for a transaction)
CREATE INDEX idx_match_records_transaction_id
  ON match_records (transaction_id);
```

---

## 5. Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | No | PK, generated with `gen_uuid_v7()`. Time-ordered for efficient range scans. |
| `run_id` | uuid | No | FK to `workflow_runs(id)`. The workflow run during which this match was confirmed. |
| `business_id` | uuid | No | FK to `business_entities(id)`. Denormalized for efficient RLS evaluation. |
| `transaction_id` | uuid | No | FK to `transactions(id)`. The bank transaction being matched. |
| `invoice_id` | uuid | Yes | FK to `invoices(id)`. The invoice matched to the transaction. NULL for `UNMATCHED_EXCEPTION`. |
| `match_proposal_id` | uuid | Yes | FK to `match_proposals(id)`. The proposal that led to this confirmed match. Set NULL after proposal purge. |
| `final_match_level` | match_level_enum | No | The match quality level at confirmation time. See `match_level_enum.md`. |
| `final_status` | match_status_enum | No | The match lifecycle status. See status values. |
| `confirmed_at` | timestamptz | Yes | When the match was confirmed. NULL for REJECTED/SUPERSEDED rows. |
| `confirmed_by` | uuid | Yes | The user who confirmed the match. NULL for auto-confirmed matches. |
| `exception_note` | text | Yes | Accountant-supplied explanation for `EXCEPTION_DOCUMENTED` status. |
| `created_at` | timestamptz | No | Row creation timestamp. |

---

## 6. Status Values (match_status_enum)

| Status | Description |
|---|---|
| `CONFIRMED` | Match confirmed (auto or human). Active match. |
| `AUTO_CONFIRMED` | Match auto-confirmed by the engine (EXACT level, or confidence ≥ threshold). |
| `REJECTED` | Match rejected by accountant. Transaction is available for re-matching. |
| `SUPERSEDED` | Match superseded by an amendment or correction run. Historical record only. |
| `EXCEPTION_DOCUMENTED` | Match outcome accepted as exception with accountant note. No invoice counterpart. |

---

## 7. Relationship to match_proposals

`match_proposals` are created by `matching.propose` during the matching phase of each workflow run. They are ephemeral:

- Created in the Processing zone during each run.
- Referenced by `match_records.match_proposal_id` when a proposal leads to confirmation.
- Purged 7 days after the run finalizes (Processing zone TTL).
- When purged, `match_records.match_proposal_id` is set to NULL (ON DELETE SET NULL).

The `match_record` is the permanent evidence of the match outcome. The `match_proposal` is the transient computation artifact. Do not use `match_proposals` for audit or regulatory queries; use `match_records`.

---

## 8. Data Zone and Retention

- **Zone:** Operational
- **Retention:** 7 years from the end of the financial year in which the matching run occurred, per Cyprus Tax Law 4/1978 and `data_retention_policy.md`.
- `match_records` are included in the archive bundle for the period in which they were confirmed.
- Locked (read-only) once the parent period is finalized.

---

## 9. RLS

```sql
ALTER TABLE match_records ENABLE ROW LEVEL SECURITY;

-- Business members can read match records for their business
CREATE POLICY match_records_business_read
  ON match_records FOR SELECT
  TO authenticated
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );

-- INSERT and UPDATE restricted to service_role
```

---

## 10. Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `MATCHING_MATCH_CONFIRMED` | LOW | `final_status` set to `CONFIRMED` (human confirmation) |
| `MATCHING_MATCH_AUTO_CONFIRMED` | LOW | `final_status` set to `AUTO_CONFIRMED` |
| `MATCHING_EXCEPTION_DOCUMENTED` | LOW | `final_status` set to `EXCEPTION_DOCUMENTED` |

All events carry `business_id`, `match_record_id`, `transaction_id`, `invoice_id` (nullable), `final_match_level`, `run_id`. `MATCHING_MATCH_CONFIRMED` also carries `confirmed_by`.

---

## 11. Integration with income_outcome_enum

The `transactions.income_outcome` field (typed `income_outcome_enum`) determines which invoice type the matching engine searches for:

- `INCOME` transactions → matched against sales invoices (`invoice_type IN ('TAX_INVOICE', 'PRO_FORMA')`).
- `EXPENSE` transactions → matched against vendor invoices (`invoice_type = 'VENDOR'`).
- `TRANSFER` and `INTERNAL` transactions → excluded from the matching engine; no `match_record` is created.
- `UNKNOWN` transactions → matching is deferred until classification resolves the income/outcome direction.

See `reference/income_outcome_enum.md` for enum definitions and `matching_engine_policy.md` for the full matching logic.

---

## 12. Cross-References

- `reference/match_level_enum.md` — `match_level_enum` values (`EXACT`, `STRONG_PROBABLE`, `WEAK_POSSIBLE`, `NO_MATCH`)
- `reference/income_outcome_enum.md` — `income_outcome_enum` values; determines matching direction
- `schemas/match_proposals_schema.md` — the ephemeral Processing-zone proposals that precede confirmation
- `matching_engine_policy.md` — full matching logic, scoring, and auto-confirm thresholds
- `match_scoring_config_schema.md` — per-business scoring weights
- `audit_event_taxonomy.md` — `MATCHING_MATCH_CONFIRMED`, `MATCHING_MATCH_AUTO_CONFIRMED`, `MATCHING_EXCEPTION_DOCUMENTED`
- `data_retention_policy.md` — 7-year retention rule; Operational zone
