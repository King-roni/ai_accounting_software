# transactions_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The canonical `transactions` table. Every parsed bank-statement row materialises as one row here. The heaviest single table in the operational schema — five status enums, multiple FKs, encryption boundaries, dedup machinery, and a JSONB for FX legs.

Per the 2026-05-08 Block 12 fix: `effective_match_status` lives on this table (the EXCEPTION_DOCUMENTED value is denormalised here rather than on `match_records`).

---

## Canonical DDL

The `transactions` table and `dedup_status_enum` type are defined in `transaction_schema.md`. This file previously contained a conflicting definition; it has been removed. See `transaction_schema.md` for all column definitions, indexes, and RLS policies.

`dedup_status_enum` canonical values: NEW · DUPLICATE_EXACT · DUPLICATE_PROBABLE · NEEDS_REVIEW

## ENUMs

### `transaction_type` — closed 12-value enum

Defined in `transaction_type_enum` (Reference data sub-doc). The 12 values: OUT_EXPENSE, IN_INCOME, INTERNAL_TRANSFER, FX_EXCHANGE, BANK_FEE, REFUND_IN, REFUND_OUT, CHARGEBACK, LOAN_OR_SHAREHOLDER_MOVEMENT, PAYROLL_OR_TEAM_PAYMENT, TAX_PAYMENT, UNKNOWN.

### `classification_method` — 5 values

Per Block 08 Phase 09 declaration. Marks which layer of the 3-layer classifier produced the result (or `MANUAL` for user-driven, `NO_AI_AVAILABLE` for the edge case where Tier 2 and Tier 3 are both disabled per business config).

### `dedup_status` — 4 values

Per Block 07 Phase 05's dedup engine. Canonical values are defined in `transaction_schema.md`: NEW, DUPLICATE_EXACT, DUPLICATE_PROBABLE, NEEDS_REVIEW.

### `effective_match_status` — 6 values

Per Block 12 Phase 06 fix. The single denormalised column reflecting the transaction's match state, including `EXCEPTION_DOCUMENTED` (the "no invoice available" exception path). NOT on `match_records` — match_records carries per-pair status; this is the transaction-level aggregate.

### `classification_status` — 4 values

Standard four-stage lifecycle: PENDING → NEEDS_CONFIRMATION (when low confidence) → CONFIRMED (final) — or FAILED.

### `ledger_status` — 4 values

`NOT_APPLICABLE` for types like UNKNOWN that don't reach ledger preparation; otherwise standard PENDING → PREPARED → FINALIZED lifecycle.

## Encryption

Two encrypted columns per `counterparty_encryption_schema`:

- `counterparty_identifier_encrypted` — full counterparty name + account (when extractable)
- `raw_description_encrypted` — raw bank-statement description

Both use the Block 05 pgcrypto wrapping via the Vault-managed per-business DEK. Decryption is logged via `FIELD_DECRYPTED` (per `audit_log_policies`).

`normalized_description` (post-redaction, after PII stripping) is NOT encrypted — it's the search-friendly form.

## Indexes

```sql
-- Tenant-prefixed lookups
CREATE INDEX idx_transactions_business_date ON transactions(business_id, transaction_date);

-- Classification queue (NEEDS_CONFIRMATION work for review queue)
CREATE INDEX idx_transactions_classification_queue
  ON transactions(business_id, classification_status, transaction_date)
  WHERE classification_status = 'NEEDS_CONFIRMATION';

-- Match queue
CREATE INDEX idx_transactions_match_queue
  ON transactions(business_id, effective_match_status, transaction_date)
  WHERE effective_match_status IN ('UNMATCHED', 'MATCHED_PROPOSED');

-- Dedup
CREATE UNIQUE INDEX idx_transactions_fingerprint_new
  ON transactions(business_id, fingerprint)
  WHERE dedup_status = 'NEW';

-- Statement upload lookup
CREATE INDEX idx_transactions_statement ON transactions(business_id, statement_upload_id);

-- Vendor lookup
CREATE INDEX idx_transactions_vendor
  ON transactions(business_id, recurring_vendor_id, transaction_date)
  WHERE recurring_vendor_id IS NOT NULL;

-- Filter status queries
CREATE INDEX idx_transactions_out_filter
  ON transactions(business_id, out_filter_decided_at)
  WHERE out_filter_decided_at IS NOT NULL;

CREATE INDEX idx_transactions_in_filter
  ON transactions(business_id, in_filter_decided_at)
  WHERE in_filter_decided_at IS NOT NULL;
```

## RLS

Standard tenant isolation per `permission_matrix`. Decryption of encrypted columns is gated by Block 05's `withAccessControl` wrapper — RLS allows the SELECT, but the encrypted bytes are only decrypted when the role + surface combination permits.

```sql
CREATE POLICY transactions_business_isolation ON transactions
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

## Migrations

Block 12 Phase 06 introduced `effective_match_status = EXCEPTION_DOCUMENTED` via the `exception_documented_match_status_migration` schema sub-doc (a sibling to this one).

## Audit Events

| Event | When |
| --- | --- |
| `STATEMENT_TRANSACTION_INGESTED` | New row inserted during zone promotion |
| `STATEMENT_TRANSACTION_DEDUP_FLAGGED` | `dedup_status` transitions to `DUPLICATE_EXACT` or `DUPLICATE_PROBABLE` |
| `STATEMENT_TRANSACTION_EXCEPTION_DOCUMENTED` | `effective_match_status` set to `EXCEPTION_DOCUMENTED` |
| `CLASSIFICATION_COMPLETED` | `classification_status` transitions to `CONFIRMED` |
| `MATCHING_COMPLETED` | `is_reconciled` set to `true` |

All emissions are per `audit_log_policies` in the `STATEMENT_*`, `CLASSIFICATION_*`, and `MATCHING_*` event families.

## RLS Policies

Row-level security is inherited from `business_entities`; see `row_level_security_policies.md`. Tenant isolation on `business_id` is enforced for all SELECT, INSERT, UPDATE operations. DELETE is not permitted at any role level (regulatory retention requires rows remain for the full 7-year Operational zone period).

## Related Documents

- `transaction_schema.md` — canonical DDL owner for the `transactions` table and `dedup_status_enum`; this file is a cross-reference stub
- `ledger_entry_schema.md` — `ledger_entries` table; FK from `ledger_entries.transaction_id` to `transactions.id`
- `match_record_schema.md` — `match_records` table; per-pair match status; FK to `transactions.id`
- `counterparty_encryption_schema.md` — encryption boundaries for `counterparty_identifier_encrypted` and `raw_description_encrypted`

## Cross-references

- `transaction_type_enum` — closed 12-value enum
- `fx_paired_legs_schema` — JSONB structure for FX_EXCHANGE
- `transaction_tag_columns_schema` — primary + secondary tag columns
- `counterparty_encryption_schema` — encryption boundaries
- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON
- `audit_log_policies` — `STATEMENT_*` / `CLASSIFICATION_*` / `MATCHING_*` event chains
- `filter_rule_type_direction_table` — filter routing
- `mobile_write_rejection_endpoints` — every WRITE via `intake.upload_pipeline_api` rejects MOBILE
- Block 04 Phase 02 — bank statement & transaction schema (architecture)
- Block 07 Phase 05 — deduplication engine
- Block 08 — classification + tagging consumers
- Block 12 Phase 06 — `effective_match_status = EXCEPTION_DOCUMENTED` migration
