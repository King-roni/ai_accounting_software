# income_matching_schema

**Category:** Schemas · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `income_match_records` table. This table holds matches between incoming bank credit transactions and expected income sources — invoices and, where applicable, pro-forma invoices under the conditions set by Block 10 Phase 08. It is distinct from `match_records` (the expense-side matching table defined in `match_record_schema`) because the candidate set, scoring signals, outcome types, and lifecycle integrations differ substantially on the IN side.

One row is written per candidate pair evaluated above the minimum score threshold. The row tracks the match from proposal through human confirmation or rejection, and provides the link back to the invoice lifecycle calls executed in Block 13.

---

## Table definition

```sql
CREATE TABLE income_match_records (
  income_match_id        uuid                  PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id            uuid                  NOT NULL REFERENCES business_entities(id),
  workflow_run_id        uuid                  NOT NULL REFERENCES workflow_runs(id),
  transaction_id         uuid                  NOT NULL REFERENCES transactions(id),
  invoice_id             uuid                  REFERENCES invoices(id),
  match_level            text                  NOT NULL,
  match_score            float                 NOT NULL CHECK (match_score >= 0.0 AND match_score <= 1.0),
  match_type             text                  NOT NULL,
  split_group_id         uuid,
  status                 text                  NOT NULL DEFAULT 'PROPOSED',
  confirmed_by_user_id   uuid                  REFERENCES users(id),
  confirmed_at           timestamptz,
  unmatched_reason       text,
  created_at             timestamptz           NOT NULL DEFAULT now(),
  updated_at             timestamptz           NOT NULL DEFAULT now()
);
```

---

## Column notes

- `income_match_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing; identifies this income match record uniquely across all businesses and runs.
- `business_id` — non-nullable. All income match records are tenant-scoped. RLS enforces tenant isolation using this column.
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. All `income_match_records` rows are produced within a workflow run. The `IN_MONTHLY` INCOME_MATCHING phase creates `PROPOSED` rows; confirmation or rejection may occur in the same run or during a subsequent review queue session.
- `transaction_id` — non-nullable FK to `transactions.id`. The incoming bank credit transaction. Must be a credit transaction (positive `amount_signed`); the application layer enforces this at write time. A single transaction may appear in multiple `income_match_records` rows during the scoring pass if multiple invoice candidates scored above the threshold — but only one row per transaction may be non-`REJECTED` at any given time.
- `invoice_id` — nullable FK to `invoices.id`. Null for `UNMATCHED` rows (transactions where no invoice candidate was found or where all candidates scored below the minimum threshold). Non-null for all other match types.
- `match_level` — the score threshold tier resolved from `match_level_enum` (`EXACT | STRONG_PROBABLE | WEAK_POSSIBLE | NO_MATCH`). Defined in `match_record_schema`. `EXACT` (score ≥ 0.95) and `STRONG_PROBABLE` (score ≥ 0.80) are eligible for auto-confirmation when the match type and auto-confirm rules permit. `WEAK_POSSIBLE` and `NO_MATCH` require human confirmation. Stored as text; validated against the closed enum at write time.
- `match_score` — the final weighted score produced by the IN-side signal computation in Block 10 Phase 08. The IN-side scoring reuses the Phase 02 engine with income-specific signal weights (invoice number / payment reference dominant; client name + amount + currency secondary; date proximity against `invoice_issue_date` and `due_date`). Score is in `[0.0, 1.0]`. Stored at proposal time and not updated after creation.
- `match_type` — the IN-side match outcome type. Closed enum: `SINGLE | SPLIT | PARTIAL | UNMATCHED`.
  - `SINGLE` — one transaction matched to one invoice.
  - `SPLIT` — this row is one of multiple transactions that together cover a single invoice (`ONE_INVOICE_MULTIPLE_PAYMENTS` outcome); `split_group_id` is populated.
  - `PARTIAL` — the transaction amount is less than the invoice total and is not part of a detected split group (`PARTIAL_PAYMENT` outcome).
  - `UNMATCHED` — no invoice candidate found above the minimum threshold (`NO_MATCH` outcome); `invoice_id` is null.
  - Stored as text; validated at write time.
- `split_group_id` — UUID v7 identifying the split payment group when `match_type = SPLIT`. Shared across all `income_match_records` rows that constitute a `ONE_INVOICE_MULTIPLE_PAYMENTS` group for the same invoice. Null for `SINGLE`, `PARTIAL`, and `UNMATCHED` rows. The `split_payment_groups` table (Block 10 Phase 01 / `split_payment_detection_policy`) is the parent record.
- `status` — lifecycle status. Closed enum: `PROPOSED | CONFIRMED | REJECTED`. `PROPOSED` on creation. Transitions to `CONFIRMED` (auto or human) or `REJECTED` (human, via the review queue). Stored as text; validated against the closed enum at write time.
- `confirmed_by_user_id` — null for auto-confirmed matches (`EXACT` / `STRONG_PROBABLE` level with invoice-number exact match, per Block 10 Phase 08 auto-confirm rules). Populated with the confirming user's UUID for human-confirmed matches.
- `confirmed_at` — timestamp of confirmation. Null while `PROPOSED`. Populated when the row transitions to `CONFIRMED`.
- `unmatched_reason` — free-text field populated for `UNMATCHED` rows describing why no match was found (e.g., `"No invoice found for this client above threshold"`, `"Amount did not match any open invoice within tolerance"`). Null for matched rows. Maximum 500 characters. Used in the review queue card to help the user understand why the transaction did not auto-match.

---

## `UNMATCHED` rows and review queue integration

Rows with `match_type = UNMATCHED` and `status = PROPOSED` are surfaced in the review queue as "unmatched income" issues. The `unmatched_reason` field provides the plain-language explanation. The user may:

1. **Manually link** the transaction to an invoice — triggers `classification.apply_tags` to update the transaction and `matching.confirm_income_match` to update this row to `CONFIRMED`.
2. **Mark as no-invoice income** — the transaction is treated as income without an associated invoice; the row remains `CONFIRMED` with `invoice_id = null`.
3. **Reclassify the transaction type** — if the income is actually an internal transfer or refund, the transaction type is amended via the classification policy.

---

## Auto-confirm rules

Auto-confirmation is permitted only when both conditions hold:
1. `match_level` is `EXACT` or `STRONG_PROBABLE`.
2. The `invoice_number` or `payment_reference` signal produced an exact match during scoring (i.e., the dominant IN-side signal fired at full weight).

When auto-confirmed, `confirmed_by_user_id` remains null and `confirmed_at` is set to the confirmation timestamp. All other `match_type` values and `match_level` values below `STRONG_PROBABLE` require human confirmation.

`MULTIPLE_INVOICES_ONE_PAYMENT` outcomes (where the combinatorial detection found a combination of invoices summing to the transaction amount) always route to the review queue and are never auto-confirmed, per the Stage 1 decision in Block 10 Phase 08.

---

## RLS

```sql
CREATE POLICY income_match_records_isolation ON income_match_records
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Tenant isolation by `business_id`. No cross-business read path exists.

---

## Indexes

```sql
-- Run-level batch queries and status filter
CREATE INDEX idx_income_match_records_run
  ON income_match_records (workflow_run_id, status);

-- Transaction lookup (one transaction may have multiple candidate rows)
CREATE INDEX idx_income_match_records_tx
  ON income_match_records (transaction_id, status);

-- Invoice-level lookup (how many payments matched this invoice)
CREATE INDEX idx_income_match_records_invoice
  ON income_match_records (invoice_id, status)
  WHERE invoice_id IS NOT NULL;

-- Business-scoped status filter (review queue, dashboard)
CREATE INDEX idx_income_match_records_business_status
  ON income_match_records (business_id, status, created_at DESC);

-- Split group membership
CREATE INDEX idx_income_match_records_split_group
  ON income_match_records (split_group_id)
  WHERE split_group_id IS NOT NULL;
```

---

## Mobile write rejection

Confirmation and rejection of income match records are executed through `matching.confirm_income_match` and `matching.reject_income_match` tools server-side. Mobile clients cannot write directly to `income_match_records`. Any such attempt is rejected per `mobile_write_rejection_endpoints.md`. Mobile clients may view proposed matches via read-only API surfaces.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `INCOME_MATCH_PROPOSED` | `income_match_records` row created with `status = PROPOSED` | LOW |
| `INCOME_MATCH_CONFIRMED` | `status` transitions to `CONFIRMED` (auto or human) | LOW |
| `INCOME_MATCH_REJECTED` | `status` transitions to `REJECTED` | LOW |

All events are emitted via `emitAudit()` per `audit_log_policies`. The `INCOME_MATCH_PROPOSED` payload includes `income_match_id`, `transaction_id`, `invoice_id`, `match_level`, `match_score`, and `match_type`. The `INCOME_MATCH_CONFIRMED` payload includes `confirmed_by_user_id` (null for auto-confirm) and `confirmed_at`. The `INCOME_MATCH_REJECTED` payload includes `unmatched_reason`. The existing taxonomy events `INCOME_MATCHING_PAIR_SCORED` and `INCOME_MATCHING_OUTCOME_RECORDED` (Block 10) cover the matching-domain operational events; `INCOME_MATCH_PROPOSED`, `INCOME_MATCH_CONFIRMED`, and `INCOME_MATCH_REJECTED` are the table-lifecycle events for this schema.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; score stored as float (not currency); canonical JSON for audit payloads
- `match_record_schema` — expense-side sibling table; `match_level_enum` defined there and reused here; `match_type_enum` partially reused (SINGLE, SPLIT, PARTIAL)
- `match_level_enum` — `EXACT | STRONG_PROBABLE | WEAK_POSSIBLE | NO_MATCH`; defined in `match_record_schema`; imported by this schema
- `invoice_schema` (Block 13) — `invoice_id` FK; invoice lifecycle states; `invoice.markPaid`, `invoice.markPartiallyPaid`, `invoice.markOverpaid` cross-block contracts
- `split_payment_detection_policy` (Block 10 Phase 04) — `split_group_id` population; `SPLIT` match type detection
- `audit_log_policies` — `MATCH` domain; `INCOME_MATCH_PROPOSED`, `INCOME_MATCH_CONFIRMED`, `INCOME_MATCH_REJECTED` events; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `INCOME_MATCH_PROPOSED`, `INCOME_MATCH_CONFIRMED`, `INCOME_MATCH_REJECTED`, `INCOME_MATCHING_PAIR_SCORED`, `INCOME_MATCHING_OUTCOME_RECORDED`
- Block 10 Phase 02 — match scoring engine; reused for IN-side scoring with income-specific signal weights
- Block 10 Phase 04 — split payment detection; populates `split_group_id` for `ONE_INVOICE_MULTIPLE_PAYMENTS` candidates
- Block 10 Phase 08 — income matching variant; primary owner of this table; auto-confirm rules; outcome-to-lifecycle mapping
- Block 13 — Invoice Generator; invoice lifecycle integration; candidate invoice status filter
- Block 14 — review queue; `UNMATCHED` row surfacing; human confirmation surface
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
