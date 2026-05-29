# ledger_entry_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `ledger_entries` table, which stores the double-entry bookkeeping record for each classified and matched transaction. One row represents one complete journal entry: a debit account, a credit account, an amount, and the VAT treatment applied. Ledger entries are created by `ledger.prepare_entries` (Block 11 Phase 07) and are locked by `archive.lock_period` (Block 15 Phase 03) during finalization. Locked entries are governed by `locked_ledger_entries_schema`.

---

## Table definition

```sql
CREATE TABLE ledger_entries (
  entry_id              uuid              PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id           uuid              NOT NULL REFERENCES business_entities(id),
  workflow_run_id       uuid              NOT NULL REFERENCES workflow_runs(id),
  transaction_id        uuid              NOT NULL REFERENCES transactions(id),
  entry_date            date              NOT NULL,                               -- typically transaction_date; may differ for accrual adjustments
  debit_account_id      uuid              NOT NULL REFERENCES chart_of_accounts(id),
  credit_account_id     uuid              NOT NULL REFERENCES chart_of_accounts(id),
  amount_eur            numeric(15,2)     NOT NULL CHECK (amount_eur > 0),
  currency              char(3)           NOT NULL,                               -- ISO 4217; matches the transaction's currency
  amount_original       numeric(15,2),                                           -- original amount in transaction currency if non-EUR; null for EUR transactions
  fx_rate               numeric(10,6),                                           -- ECB exchange rate used for conversion; null for EUR transactions
  vat_treatment         vat_treatment_enum NOT NULL,
  vat_amount_eur        numeric(15,2)     NOT NULL DEFAULT 0.00 CHECK (vat_amount_eur >= 0),
  counterparty_id       uuid              REFERENCES counterparties(counterparty_id), -- nullable; null for transactions with no resolved counterparty
  description           text,                                                    -- human-readable summary; may include the transaction's normalised description
  is_locked             boolean           NOT NULL DEFAULT false,
  locked_at             timestamptz,                                             -- populated when is_locked transitions to true
  created_at            timestamptz       NOT NULL DEFAULT now(),

  -- Double-entry balance invariant: debit and credit accounts must differ
  CONSTRAINT chk_ledger_entry_double_entry
    CHECK (debit_account_id != credit_account_id)
);
```

### Column notes

- `entry_id` — UUID v7 per `data_layer_conventions_policy §2`.
- `business_id` — non-nullable. RLS enforces tenant isolation using this column.
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. Ledger entries are always produced within a workflow run. The LEDGER phase of the run creates all entries for the period.
- `transaction_id` — FK to `transactions.id`. One `ledger_entries` row corresponds to one transaction. In the standard case, there is a one-to-one relationship between transaction and ledger entry. Adjustment entries (Block 12 / Block 13 adjustment runs) may produce additional rows for the same `transaction_id` with a distinct `workflow_run_id`.
- `entry_date` — the accounting date for the journal entry. For standard entries, this equals `transactions.transaction_date`. For accrual-basis adjustments, it may differ. All date values are calendar dates in the `Europe/Nicosia` timezone.
- `debit_account_id` / `credit_account_id` — both required; non-nullable FKs to `chart_of_accounts.id`. The debit and credit accounts are resolved by `ledger.prepare_entries` using the mapping algorithm in `ledger_account_mapping_schema`. The CHECK constraint enforces the double-entry invariant: debit and credit accounts must differ.
- `amount_eur` — the transaction amount in EUR, expressed as a positive `numeric(15,2)`. Always positive; the direction of the entry is encoded by which account is debited and which is credited, not by the sign. Currency amounts are never stored as floats per `data_layer_conventions_policy §3`.
- `currency` — ISO 4217 three-letter code of the transaction's original currency. `EUR` for EUR transactions; other codes for non-EUR transactions where FX conversion was applied.
- `amount_original` — the transaction amount in the original currency, null for EUR transactions. Stored for audit traceability; the ledger is always maintained in EUR.
- `fx_rate` — the ECB exchange rate used to convert `amount_original` to `amount_eur`. Null for EUR transactions. Sourced from the ECB rate table (Block 11 Phase 08); the rate is pinned at the time of ledger preparation and does not change after creation. The `FX_RATE_FETCHED_ECB` audit event records the rate retrieval.
- `vat_treatment` — the VAT treatment applied to this entry. Drawn from the closed 8-value `vat_treatment_enum`. Resolved by the VAT treatment classifier (Block 11 Phase 05) per `vat_rate_table_reference`. The `UNKNOWN` value is permitted here during the draft window (it triggers an accountant review flag); it must not appear in locked entries.
- `vat_amount_eur` — the VAT amount in EUR, non-negative `numeric(15,2)`. Zero for `OUTSIDE_SCOPE`, `EXEMPT`, and `UNKNOWN` treatments. Computed by Block 11 Phase 08 from the resolved rate in `vat_rate_table_reference` and `amount_eur`.
- `counterparty_id` — nullable FK to `counterparties.counterparty_id`. Null when the counterparty resolver could not identify the vendor (a `LEDGER_COUNTERPARTY_UNRESOLVED` event is emitted in this case). When populated, the counterparty record links to VAT treatment defaults and ledger account suggestions.
- `description` — optional free-text summary. Not the raw bank narrative (which lives in `transactions.description`); this is a processed label suitable for accountant-facing exports. May include the normalised counterparty name and transaction type.
- `is_locked` — `false` until the period is finalised. Set to `true` by `archive.lock_period` during Block 15 finalization. Once locked, the entry is immutable; any attempt to update a locked row is blocked by a trigger. See `locked_ledger_entries_schema` for the finalized-entry governance.
- `locked_at` — timestamp when `is_locked` was set to `true`. Null until locking. Populated by the locking transaction.

---

## Immutability after locking

A trigger prevents updates to rows where `is_locked = true`:

```sql
CREATE OR REPLACE FUNCTION prevent_locked_ledger_entry_update()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.is_locked = true THEN
    RAISE EXCEPTION 'Cannot modify a locked ledger entry (entry_id: %)', OLD.entry_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_locked_ledger_entry_update
  BEFORE UPDATE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_locked_ledger_entry_update();
```

Locked entries are archived into the Finalized Archive zone (Block 15 Phase 04) and referenced by `locked_ledger_entries_schema`. The `UNKNOWN` VAT treatment is blocked during locking: `archive.lock_period` rejects entries with `vat_treatment = UNKNOWN` and surfaces them as a finalization precondition failure.

---

## RLS

```sql
CREATE POLICY ledger_entries_isolation ON ledger_entries
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

---

## Indexes

```sql
-- Primary lookup: all entries for a transaction
CREATE INDEX idx_ledger_entries_transaction
  ON ledger_entries (transaction_id, business_id);

-- Run-level batch queries
CREATE INDEX idx_ledger_entries_run
  ON ledger_entries (workflow_run_id, business_id);

-- Unlocked entries for pending finalization scan
CREATE INDEX idx_ledger_entries_unlocked
  ON ledger_entries (business_id, entry_date)
  WHERE is_locked = false;

-- VAT treatment filter (VAT return preparation, export)
CREATE INDEX idx_ledger_entries_vat_treatment
  ON ledger_entries (business_id, vat_treatment, entry_date);
```

---

## Mobile write rejection

`ledger.prepare_entries` is a server-side workflow tool. No client or mobile write path exists for `ledger_entries`. Any direct write attempt from a mobile client is rejected per `mobile_write_rejection_endpoints.md`. Mobile clients may view ledger summaries through read-only dashboard surfaces.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `LEDGER_ENTRY_CREATED` | `ledger_entries` row inserted by `ledger.prepare_entries` | LOW |
| `LEDGER_ENTRY_LOCKED` | `is_locked` transitions to `true` during finalization | LOW |

Both events are emitted via `emitAudit()` per `audit_log_policies`. The `LEDGER_ENTRY_CREATED` payload includes `entry_id`, `transaction_id`, `debit_account_id`, `credit_account_id`, `amount_eur`, `vat_treatment`, and `vat_amount_eur`. The `LEDGER_ENTRY_LOCKED` payload includes `entry_id`, `business_id`, and `locked_at`. The existing taxonomy event `FINALIZATION_LEDGER_BULK_LOCKED` (Block 15) covers the aggregate locking event across the entire period; `LEDGER_ENTRY_LOCKED` is the per-row event.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; `numeric(15,2)` for currency amounts; no floating-point currency
- `locked_ledger_entries_schema` — governance of entries after `is_locked = true`; finalized archive record shape
- `ledger_account_mapping_schema` — resolution algorithm that produces `debit_account_id` and `credit_account_id`
- `vat_treatment_enum` — closed 8-value enum; `vat_treatment` values
- `vat_rate_table_reference` — rate table consulted to compute `vat_amount_eur`
- `counterparty_schema` — `counterparties` table; `counterparty_id` FK
- `audit_log_policies` — `LEDGER_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `LEDGER_ENTRY_CREATED`, `LEDGER_ENTRY_LOCKED`, `LEDGER_ENTRIES_PREPARED`, `FINALIZATION_LEDGER_BULK_LOCKED`
- Block 11 Phase 01 — ledger schema foundation; `chart_of_accounts` and `draft_ledger_entries` table context
- Block 11 Phase 05 — VAT treatment classifier; determines `vat_treatment`
- Block 11 Phase 07 — type-aware ledger preparation dispatcher; primary writer via `ledger.prepare_entries`
- Block 11 Phase 08 — VAT amount computation; determines `vat_amount_eur` and FX columns
- Block 15 Phase 03 — period finalization and locking; transitions `is_locked` to `true`
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
