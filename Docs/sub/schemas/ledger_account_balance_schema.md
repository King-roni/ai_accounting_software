# Schema: ledger_account_balances

## Purpose

Materializes cached debit and credit totals per ledger account per VAT period per business entity. This table is the primary source for balance sheet and trial balance reporting. Rather than summing ledger entries at query time, report generation reads pre-computed rows from this table, which are kept current via trigger or scheduled recomputation.

---

## Table Definition

```sql
CREATE TABLE ledger_account_balances (
  id                  uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_entity_id  uuid          NOT NULL REFERENCES business_entities(id) ON DELETE CASCADE,
  account_code        text          NOT NULL,
  period_id           uuid          NOT NULL REFERENCES vat_periods(id) ON DELETE RESTRICT,
  debit_total         numeric(15,2) NOT NULL DEFAULT 0,
  credit_total        numeric(15,2) NOT NULL DEFAULT 0,
  net_balance         numeric(15,2) GENERATED ALWAYS AS (debit_total - credit_total) STORED,
  last_computed_at    timestamptz   NOT NULL DEFAULT now(),
  is_locked           boolean       NOT NULL DEFAULT false,

  CONSTRAINT ledger_account_balances_non_negative_totals
    CHECK (debit_total >= 0 AND credit_total >= 0)
);
```

---

## Column Reference

| Column               | Type            | Nullable | Default            | Description                                                                                                                                      |
|----------------------|-----------------|----------|--------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                 | uuid            | No       | gen_uuid_v7()      | Surrogate PK. UUIDv7 for time-ordered indexing.                                                                                                  |
| `business_entity_id` | uuid            | No       | —                  | FK → `business_entities(id)`. Enforces tenant isolation. Balances are always per-business.                                                       |
| `account_code`       | text            | No       | —                  | The account code from `chart_of_accounts` (e.g. `1100`, `4000`). Not a FK; chart customization means codes can vary by entity.                  |
| `period_id`          | uuid            | No       | —                  | FK → `vat_periods(id)`. Each row represents one account's balance within one VAT period.                                                         |
| `debit_total`        | numeric(15,2)   | No       | 0                  | Sum of all debit-side ledger entries for this account in this period.                                                                            |
| `credit_total`       | numeric(15,2)   | No       | 0                  | Sum of all credit-side ledger entries for this account in this period.                                                                           |
| `net_balance`        | numeric(15,2)   | No       | Computed           | `debit_total - credit_total`. GENERATED ALWAYS STORED. Read-only. Positive = net debit position; negative = net credit position.                |
| `last_computed_at`   | timestamptz     | No       | now()              | Timestamp of the most recent recomputation. Used to detect staleness and to order concurrent recompute jobs.                                     |
| `is_locked`          | boolean         | No       | false              | Set to `true` when the associated period is locked. Locked rows cannot be updated by recompute triggers; they are read-only until unlocked.      |

---

## Constraints and Indexes

### Primary Key

```sql
ALTER TABLE ledger_account_balances
  ADD CONSTRAINT ledger_account_balances_pkey PRIMARY KEY (id);
```

### Unique Index (business, account, period)

Each combination of business entity, account code, and period is unique. There is exactly one balance row per account per period per business.

```sql
CREATE UNIQUE INDEX uq_ledger_account_balances_entity_account_period
  ON ledger_account_balances (business_entity_id, account_code, period_id);
```

### Supporting Indexes

```sql
-- Range queries by period for trial balance
CREATE INDEX idx_ledger_account_balances_entity_period
  ON ledger_account_balances (business_entity_id, period_id);

-- Lookup by account code across periods
CREATE INDEX idx_ledger_account_balances_account_code
  ON ledger_account_balances (business_entity_id, account_code);
```

---

## UPDATE Trigger: maintain last_computed_at

Any update to `debit_total` or `credit_total` must refresh `last_computed_at` automatically.

```sql
CREATE OR REPLACE FUNCTION trg_ledger_account_balance_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.last_computed_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER ledger_account_balances_touch
  BEFORE UPDATE OF debit_total, credit_total
  ON ledger_account_balances
  FOR EACH ROW
  EXECUTE FUNCTION trg_ledger_account_balance_touch();
```

---

## Recomputation Strategy

Balances are recomputed using one of two mechanisms depending on configuration:

### A. Post-Insert Trigger on ledger_entries (real-time)

When a new row is inserted into `ledger_entries`, a trigger calls `upsert_account_balance`:

```sql
INSERT INTO ledger_account_balances (
  id, business_entity_id, account_code, period_id, debit_total, credit_total
)
SELECT
  gen_uuid_v7(),
  :business_entity_id,
  :account_code,
  :period_id,
  COALESCE(SUM(CASE WHEN side = 'DEBIT'  THEN amount ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN side = 'CREDIT' THEN amount ELSE 0 END), 0)
FROM ledger_entries
WHERE business_entity_id = :business_entity_id
  AND account_code = :account_code
  AND period_id = :period_id
ON CONFLICT (business_entity_id, account_code, period_id)
DO UPDATE SET
  debit_total  = EXCLUDED.debit_total,
  credit_total = EXCLUDED.credit_total;
-- last_computed_at updated by the BEFORE UPDATE trigger above
```

### B. Scheduled Recompute Job (batch fallback)

A scheduled job (default: every 5 minutes) recomputes all non-locked balance rows where `last_computed_at < now() - interval '10 minutes'`. This catches any rows missed by trigger failures.

The job skips rows where `is_locked = true`.

---

## Period Lock Interaction

When `tool_period_lock` transitions a VAT period to locked:

1. All `ledger_account_balances` rows for that `period_id` are updated to `is_locked = true`.
2. The recompute trigger is suppressed for locked rows via a guard in `trg_ledger_account_balance_touch` (checks `OLD.is_locked = false`).
3. Locked balance rows are the source of truth for finalized period reporting.

If a period is unlocked via `period_lock_override_runbook.md`, `is_locked` is reset to `false` and a full recompute is forced for the affected period.

---

## Row Level Security

RLS policies on this table mirror those on `ledger_entries`. A business entity member may read rows where `business_entity_id` matches their active context. Write access is restricted to service-role only; application code never writes balance rows directly.

---

## Relationship to ledger_entry_schema

`ledger_entries` is the authoritative source. `ledger_account_balances` is a derived materialization. If a discrepancy is detected (via `tool_ledger_reconcile`), the balance row is recomputed from raw entries, not the other way around.

---

## Related Documents

- `schemas/ledger_entry_schema.md` — Source-of-truth ledger entries that feed these balances.
- `schemas/vat_period_schema.md` — Period records referenced by `period_id`.
- `schemas/period_lock_schema.md` — Lock state that sets `is_locked` on balance rows.
- `tools/tool_ledger_post.md` — Inserts ledger entries and triggers balance updates.
- `tools/tool_ledger_reconcile.md` — Detects and repairs balance-to-entry discrepancies.
- `policies/period_lock_policy.md` — Rules for period locking and its effect on balance rows.
- `runbooks/ledger_imbalance_runbook.md` — Response procedure when balances diverge from entries.
