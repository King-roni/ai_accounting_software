# Schema: bank_statement_lines

**Namespace:** data  
**Owning Block:** 07 — Bank Statement Pipeline  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

---

## Overview

`bank_statement_lines` stores individual parsed lines extracted from a bank statement. Each row represents one transaction line as reported by the bank: a date, amount, direction, and narrative. Rows are inserted by `intake.import_bank_statement` after the statement header is validated. This table is the canonical source of line-level bank data that the matching engine operates against.

A line remains unmatched (`transaction_id = NULL`) until `matching.propose` and `matching.confirm_match` link it to a `transactions` row. The `dedup_hash` column prevents the same line from being inserted twice for the same statement.

This table sits in the Persistent zone. It is tenant-scoped by `business_entity_id` and protected by Row Level Security.

---

## Enum types

```sql
CREATE TYPE line_direction_enum AS ENUM (
  'DEBIT',
  'CREDIT'
);
```

`line_direction_enum` is defined in the Block 07 migration that creates this table. If it already exists from a prior migration, the migration guard uses `DO $$ BEGIN ... EXCEPTION WHEN duplicate_object THEN NULL; END $$` per `supabase_migration_tooling_policy`.

---

## DDL

```sql
CREATE TABLE bank_statement_lines (
  id                    uuid              NOT NULL DEFAULT gen_uuid_v7(),
  bank_statement_id     uuid              NOT NULL
                          REFERENCES bank_statements(id) ON DELETE RESTRICT,
  business_entity_id    uuid              NOT NULL
                          REFERENCES business_entities(id) ON DELETE RESTRICT,
  line_date             date              NOT NULL,
  value_date            date,
  description           text              NOT NULL,
  amount                numeric(15,2)     NOT NULL,
  currency              char(3)           NOT NULL DEFAULT 'EUR',
  direction             line_direction_enum NOT NULL,
  running_balance       numeric(15,2),
  raw_reference         text,
  parsed_counterparty   text,
  transaction_id        uuid
                          REFERENCES transactions(id) ON DELETE SET NULL,
  dedup_hash            text              NOT NULL,
  dedup_status          dedup_status_enum NOT NULL DEFAULT 'NEW',
  created_at            timestamptz       NOT NULL DEFAULT now(),

  CONSTRAINT bank_statement_lines_pkey
    PRIMARY KEY (id),
  CONSTRAINT bank_statement_lines_amount_nonzero
    CHECK (amount <> 0),
  CONSTRAINT bank_statement_lines_currency_length
    CHECK (char_length(currency) = 3)
);
```

---

## Unique index

```sql
CREATE UNIQUE INDEX bank_statement_lines_dedup_hash_uidx
  ON bank_statement_lines (bank_statement_id, dedup_hash);
```

This index enforces line-level deduplication within a single statement. Two lines sharing the same `(bank_statement_id, dedup_hash)` cannot coexist. The hash is the SHA-256 hex digest of the concatenation `line_date::text || description || amount::text || direction::text` using the canonical form in `dedup_key_generator_policy`.

---

## Foreign key indexes

```sql
CREATE INDEX bank_statement_lines_bank_statement_id_idx
  ON bank_statement_lines (bank_statement_id);

CREATE INDEX bank_statement_lines_business_entity_id_idx
  ON bank_statement_lines (business_entity_id);

CREATE INDEX bank_statement_lines_transaction_id_idx
  ON bank_statement_lines (transaction_id)
  WHERE transaction_id IS NOT NULL;

CREATE INDEX bank_statement_lines_dedup_status_idx
  ON bank_statement_lines (dedup_status)
  WHERE dedup_status IN ('DUPLICATE_PROBABLE', 'NEEDS_REVIEW');
```

---

## Column notes

- `id` — UUID v7 PK per `data_layer_conventions_policy §2`. Monotonically increasing within a run.
- `bank_statement_id` — FK to `bank_statements(id)`. All lines for the same statement share this FK. ON DELETE RESTRICT prevents statement deletion while lines exist.
- `business_entity_id` — tenant scope. Denormalized from the parent `bank_statements` row at insert time for efficient RLS evaluation without a join.
- `line_date` — the transaction booking date as reported by the bank. Primary date for matching and ledger posting.
- `value_date` — settlement date if the bank reports it. Nullable. MT940 and CAMT.053 formats distinguish booking date from value date; CSV formats typically do not.
- `description` — the transaction narrative. Primary field used by the matching engine and for counterparty extraction. The import tool rejects blank descriptions.
- `amount` — always positive regardless of direction. Direction is expressed by the `direction` column. Stored as `numeric(15,2)` per `data_layer_conventions_policy §3`. Float types are not used.
- `currency` — ISO 4217 three-letter code. Defaults to `EUR` for Cyprus-entity accounts. Non-EUR amounts are not converted here; FX conversion occurs during ledger posting.
- `direction` — `DEBIT` (money leaving the account) or `CREDIT` (money entering the account). Determined by the parser from the source format's sign convention (signed amount, D/C column, or debit/credit split columns).
- `running_balance` — account balance after this line as reported by the bank. Nullable; not all formats include per-line balances. Used by the import tool for balance-mismatch validation against the statement header.
- `raw_reference` — the unmodified reference or remittance field from the source. Used for structured-reference matching (IBAN fragments, invoice numbers). Preserved verbatim for audit.
- `parsed_counterparty` — counterparty name extracted from `description` or the source format's dedicated counterparty field. Set by the import tool. Null if extraction produces no result.
- `transaction_id` — FK to `transactions(id)`. Null until matching confirms a link. Set by `matching.confirm_match` or by auto-confirm inside `matching.propose` when `match_level = EXACT` and `proposed_by = 'system'`. ON DELETE SET NULL preserves line history if a transaction is deleted.
- `dedup_hash` — SHA-256 hex digest of `line_date::text || description || amount::text || direction::text`. Computed at insert time per `dedup_key_generator_policy`. Enforced unique per statement via the dedup index.
- `dedup_status` — `NEW` until dedup runs, then `DUPLICATE_EXACT`, `DUPLICATE_PROBABLE`, or `NEEDS_REVIEW`. See `deduplication_policy` for promotion rules.
- `created_at` — wall-clock insert timestamp. Not updated after insert.

---

## Row Level Security

```sql
ALTER TABLE bank_statement_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY bank_statement_lines_tenant_read
  ON bank_statement_lines
  FOR SELECT
  USING (
    business_entity_id =
      current_setting('app.current_business_id')::uuid
  );

CREATE POLICY bank_statement_lines_service_write
  ON bank_statement_lines
  FOR ALL
  USING (current_setting('app.role', true) = 'service_role');
```

Client-facing reads are scoped to the authenticated business entity via the `app.current_business_id` session variable set by the API gateway per `rls_policy_template`. All writes are service-role only.

---

## Audit events

No DDL-level audit triggers on this table. The owning tool `intake.import_bank_statement` emits `BANK_STATEMENT_IMPORTED` when lines are inserted. `matching.propose` emits `MATCHING_AUTO_CONFIRMED` when `transaction_id` is set by the auto-confirm path.

Audit event notes:
- `BANK_STATEMENT_IMPORTED` — not yet in the taxonomy. Must be added to `audit_event_taxonomy.md` before `tool_bank_statement_import.md` goes to production.

---

## Related Documents

- `bank_statement_schema.md` — parent statement record; `bank_statement_id` FK target
- `transactions_schema.md` — `transaction_id` FK target
- `match_proposal_schema.md` — proposals that reference lines by ID
- `deduplication_policy.md` — dedup_status lifecycle rules
- `dedup_key_generator_policy.md` — canonical hash input construction
- `tool_bank_statement_import.md` — tool that inserts rows into this table
- `tool_matching_propose.md` — tool that sets `transaction_id` via confirm path
- `data_layer_conventions_policy.md` — UUID v7 and numeric precision rules
- `rls_policy_template.md` — RLS session variable pattern
