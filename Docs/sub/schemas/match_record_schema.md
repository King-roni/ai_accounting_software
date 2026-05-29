# match_record_schema

**Category:** Schemas · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `match_records` table, which holds one row per confirmed or proposed transaction-to-invoice (or transaction-to-document) match. Each row is the output of the `matching.score_pair` tool after the score has been classified into a match level. The table is the authoritative record of how transactions are reconciled against invoices and other financial documents. Confirmed rows feed the ledger preparation phase; rejected rows are excluded from ledger entries and inform the rejection memory.

---

## Table definition

> **DDL authority has moved.** The canonical `CREATE TABLE match_records` DDL, including all enum types (`match_level_enum`, `match_type_enum`, `match_status_enum`), column definitions, and uniqueness constraints, is defined in `match_records_schema.md`. That file was established as the authoritative owner of the `match_records` DDL in Cycle 14 to resolve a duplicate-DDL finding (S7-024).
>
> Do not modify the `CREATE TABLE match_records` statement in this file. Any schema changes must be made in `match_records_schema.md` only. This document retains all column notes, constraint explanations, RLS policy, index definitions, and cross-reference sections as supplementary documentation.

---

## Schema summary (non-normative)

The following is a condensed reference of the `match_records` table structure for readers consulting this document. For normative DDL, always refer to `match_records_schema.md`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `match_id` / `id` | uuid PK | No | UUID v7 per `data_layer_conventions_policy §2` |
| `business_id` | uuid FK | No | Tenant scope; RLS-enforced |
| `workflow_run_id` / `run_id` | uuid FK | No | The workflow run that created this record |
| `transaction_id` | uuid FK | No | The transaction being matched |
| `invoice_id` | uuid FK | Yes | Null for unmatched transactions |
| `match_level` / `final_match_level` | match_level_enum | No | EXACT, STRONG_PROBABLE, WEAK_POSSIBLE, NO_MATCH |
| `match_type` | match_type_enum | No | SINGLE, SPLIT, PARTIAL |
| `status` / `final_status` | match_status_enum | No | PROPOSED, CONFIRMED, REJECTED |
| `confirmed_by_user_id` / `confirmed_by` | uuid FK | Yes | Null for auto-confirmed matches |
| `confirmed_at` | timestamptz | Yes | Null while PROPOSED |
| `rejection_reason` / `exception_note` | text | Yes | Populated on REJECTED rows |
| `created_at` | timestamptz | No | Row insert time |

**Enum values:**

- `match_level_enum`: `EXACT` (score ≥ 0.95) · `STRONG_PROBABLE` (score ≥ 0.80) · `WEAK_POSSIBLE` · `NO_MATCH`
- `match_type_enum`: `SINGLE` · `SPLIT` · `PARTIAL`
- `match_status_enum`: `PROPOSED` · `CONFIRMED` · `REJECTED`

**Key constraints:**

- A unique partial index on `(transaction_id, invoice_id) WHERE status != 'REJECTED'` prevents duplicate active match records for the same pair.
- `split_group_id` (UUID v7) is shared across all rows that constitute a split match group. Null for `SINGLE` and `PARTIAL` matches.
- `match_score` is a float in [0.0, 1.0] checked at INSERT time.

### Column notes

- `match_id` — UUID v7 per `data_layer_conventions_policy §2`.
- `business_id` — non-nullable. RLS enforces tenant isolation using this column.
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. Every match record is produced within a workflow run. The MATCHING phase of the run creates all `PROPOSED` rows; confirmation or rejection may occur in the same run or during a subsequent review.
- `transaction_id` — FK to `transactions.id`. Never null. A transaction may appear in multiple `match_records` rows if multiple candidates are surfaced, but only one row per pair may be non-`REJECTED`.
- `invoice_id` — nullable FK to `invoices.id`. Null when a transaction is evaluated for matching but no invoice candidate is found. Null rows represent evaluated-but-unmatched transactions and are used by the review queue to surface "unmatched transaction" issues.
- `match_level` — the threshold tier from `match_scoring_weights_policy §3`. `EXACT` (score ≥ 0.95) and `STRONG_PROBABLE` (score ≥ 0.80) are eligible for auto-confirmation. `WEAK_POSSIBLE` and `NO_MATCH` require human confirmation. No match level exists for scores below 0.40; pairs below that threshold produce no row.
- `match_type` — `SINGLE` for a standard one-transaction-to-one-invoice match. `SPLIT` for rows that are part of a split payment group (multiple transactions covering one invoice). `PARTIAL` for a transaction that partially covers an invoice but is not part of a detected split group.
- `split_group_id` — UUID v7 identifying the split payment group. Shared across all `match_records` rows that constitute a split match for the same invoice. Null for `SINGLE` and `PARTIAL` matches. The `split_payment_groups` table (Block 10 Phase 01 / `split_payment_detection_policy`) is the parent record; this column is the FK reference even though it is typed as a bare UUID here for flexibility during the group formation window.
- `match_score` — the final weighted score from `matching.score_pair` per `match_scoring_weights_policy`. Stored at proposal time; not updated after creation. Historical score snapshots are preserved even if the scoring configuration changes.
- `status` — lifecycle status. `PROPOSED` on creation. Transitions to `CONFIRMED` (auto or human) or `REJECTED` (human). Transitions are driven by `matching.confirm_match` and `matching.reject_match` tools.
- `confirmed_by_user_id` — null for auto-confirmed matches (`EXACT` / `STRONG_PROBABLE` level with auto-confirm enabled per business configuration). Populated with the user's ID for human-confirmed matches.
- `confirmed_at` — timestamp of confirmation. Null while `PROPOSED`. Populated on transition to `CONFIRMED`.
- `rejection_reason` — free text explaining why the match was rejected. Null while `PROPOSED` or `CONFIRMED`. Used by the rejection memory (Block 10 Phase 06) and surfaced in the review queue.

---

## Uniqueness constraint note

The declared `UNIQUE NULLS NOT DISTINCT` constraint on `(transaction_id, invoice_id)` is enforced by the application layer with a `WHERE status != 'REJECTED'` filter, because a standard UNIQUE constraint cannot easily be partial over a nullable column in PostgreSQL without a partial index. The enforcement pattern is:

```sql
CREATE UNIQUE INDEX idx_match_records_tx_invoice_non_rejected
  ON match_records (transaction_id, invoice_id)
  WHERE status != 'REJECTED' AND invoice_id IS NOT NULL;
```

This allows a previously rejected pair to be re-proposed in a later run while preventing duplicate active match records for the same pair.

---

## RLS

```sql
CREATE POLICY match_records_isolation ON match_records
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

---

## Indexes

```sql
-- Unique non-rejected pair enforcement (see above)
CREATE UNIQUE INDEX idx_match_records_tx_invoice_non_rejected
  ON match_records (transaction_id, invoice_id)
  WHERE status != 'REJECTED' AND invoice_id IS NOT NULL;

-- Run-level batch queries
CREATE INDEX idx_match_records_run
  ON match_records (workflow_run_id, status);

-- Business-scoped status filter (review queue, dashboard)
CREATE INDEX idx_match_records_business_status
  ON match_records (business_id, status, created_at DESC);

-- Split group membership
CREATE INDEX idx_match_records_split_group
  ON match_records (split_group_id)
  WHERE split_group_id IS NOT NULL;
```

---

## Mobile write rejection

Confirmation and rejection of match records are write operations executed through `matching.confirm_match` and `matching.reject_match` tools server-side. Mobile clients cannot write directly to `match_records`. Any such attempt is rejected per `mobile_write_rejection_endpoints.md`. Mobile clients may view proposed matches via read-only API surfaces.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `MATCH_PROPOSED` | `match_records` row created with `status = PROPOSED` | LOW |
| `MATCH_CONFIRMED` | `status` transitions to `CONFIRMED` (auto or human) | LOW |
| `MATCH_REJECTED` | `status` transitions to `REJECTED` | LOW |

All events are emitted via `emitAudit()` per `audit_log_policies`. The `MATCH_CONFIRMED` payload includes `match_id`, `match_score`, `match_level`, `match_type`, and `confirmed_by_user_id` (null for auto-confirm). The `MATCH_REJECTED` payload includes `rejection_reason`. Existing taxonomy events `MATCHING_AUTO_CONFIRMED`, `MATCHING_USER_CONFIRMED`, and `MATCHING_USER_REJECTED` in Block 10 cover the matching-domain semantics; `MATCH_PROPOSED`, `MATCH_CONFIRMED`, and `MATCH_REJECTED` are the table-lifecycle events defined for this schema.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; score snapshot stored at write time; no float currency
- `match_level_enum` — defined in this schema; `EXACT | STRONG_PROBABLE | WEAK_POSSIBLE | NO_MATCH`
- `match_scoring_weights_policy` — scoring formula and threshold definitions that produce `match_level` and `match_score`
- `split_payment_detection_policy` (Block 10 Phase 04) — governs `split_group_id` population and the `SPLIT` match type
- `audit_log_policies` — `MATCHING_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `MATCH_PROPOSED`, `MATCH_CONFIRMED`, `MATCH_REJECTED`, `MATCHING_AUTO_CONFIRMED`, `MATCHING_USER_CONFIRMED`, `MATCHING_USER_REJECTED`
- Block 10 Phase 01 — matching schema foundation; `match_rejection_memory` and `split_payment_groups` tables
- Block 10 Phase 02 — match scoring engine; creates `PROPOSED` rows
- Block 10 Phase 03 — strong/probable auto-confirm rule; drives auto-transitions to `CONFIRMED`
- Block 10 Phase 04 — split payment detection; populates `split_group_id` and `match_type = SPLIT`
- Block 10 Phase 06 — rejection memory; reads `rejection_reason` on `REJECTED` rows
- Block 11 Phase 07 — ledger preparation; reads `CONFIRMED` rows to determine which transactions have matched invoices
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
