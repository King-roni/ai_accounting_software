# vat_entry_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `vat_entries` table. The table holds one row per VAT-bearing ledger entry, storing the computed VAT breakdown alongside the net, VAT, and gross amounts. Each row is in a one-to-one relationship with a `ledger_entries` row; not every ledger entry produces a `vat_entries` row (entries with `vat_treatment = OUTSIDE_SCOPE` or `vat_treatment = EXEMPT` produce no VAT entry). The `vat_entries` table is the primary input for Cyprus VAT return preparation (Block 16) and the VIES export pipeline.

---

## Table definition

```sql
CREATE TABLE vat_entries (
  vat_entry_id          uuid            PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id           uuid            NOT NULL REFERENCES business_entities(id),
  ledger_entry_id       uuid            NOT NULL REFERENCES ledger_entries(entry_id),
  workflow_run_id       uuid            NOT NULL REFERENCES workflow_runs(id),
  vat_treatment         text            NOT NULL,
  vat_rate              numeric(5,4)    NOT NULL CHECK (vat_rate >= 0.0000 AND vat_rate <= 1.0000),
  net_amount_eur        numeric(15,2)   NOT NULL,
  vat_amount_eur        numeric(15,2)   NOT NULL CHECK (vat_amount_eur >= 0),
  gross_amount_eur      numeric(15,2)   NOT NULL,
  fx_rate_used          numeric(10,6),
  original_currency     char(3)         NOT NULL,
  ecb_rate_date         date,
  is_locked             boolean         NOT NULL DEFAULT false,
  created_at            timestamptz     NOT NULL DEFAULT now(),

  -- One VAT entry per ledger entry
  CONSTRAINT uq_vat_entries_ledger_entry
    UNIQUE (ledger_entry_id),

  -- Gross = net + VAT
  CONSTRAINT chk_vat_entry_gross_balance
    CHECK (gross_amount_eur = net_amount_eur + vat_amount_eur)
);
```

---

## Column notes

- `vat_entry_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing; identifies this VAT entry uniquely across all businesses and periods.
- `business_id` — non-nullable. All VAT entries are tenant-scoped. RLS enforces tenant isolation using this column.
- `ledger_entry_id` — non-nullable FK to `ledger_entries.entry_id`. The parent ledger entry. Unique constraint ensures one-to-one relationship. When a `ledger_entries` row is locked during finalization, the corresponding `vat_entries` row is locked via the `is_locked` column on this table (not via the ledger entries trigger).
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. The run that produced this VAT entry. Used for run-level aggregation (VAT summary per run) and for the VAT return preparation pipeline.
- `vat_treatment` — the VAT treatment applied to the parent ledger entry. Must be a valid value from `vat_treatment_enum` (8 values). `OUTSIDE_SCOPE` and `EXEMPT` are the only values that do not produce a `vat_entries` row; all other treatments produce one row. Stored as text; validated against the enum at write time. See `vat_rate_table_reference` for the treatment-to-rate mapping.
- `vat_rate` — the applicable Cyprus VAT rate as a decimal fraction. Stored as `numeric(5,4)` — four decimal places of precision. Examples: `0.1900` for 19%; `0.0900` for 9%; `0.0500` for 5%; `0.0000` for zero-rated. The rate is resolved from `vat_rates` via the rate-resolution query in `vat_rate_table_reference §Rate resolution query`, using the parent `ledger_entries.entry_date` as the effective date. The rate is pinned at entry creation time and does not change after the entry is written.
- `net_amount_eur` — the taxable base amount in EUR, as `numeric(15,2)`. For standard domestic supplies, this is the transaction amount before VAT. For EU reverse-charge transactions, this is the base on which the self-assessed reverse-charge VAT is computed. Currency amounts are never stored as floats per `data_layer_conventions_policy §3`.
- `vat_amount_eur` — the computed VAT amount in EUR, as `numeric(15,2)`. Non-negative. Computed as `net_amount_eur × vat_rate`. For zero-rated entries, this is `0.00` (not null). The CHECK constraint `vat_amount_eur >= 0` prevents negative VAT amounts. Negative VAT corrections (credit notes, refunds) are handled by creating a separate VAT entry with a positive `net_amount_eur` and a note in the parent ledger entry, not by using a negative amount here.
- `gross_amount_eur` — the total amount including VAT, as `numeric(15,2)`. The CHECK constraint `gross_amount_eur = net_amount_eur + vat_amount_eur` enforces the balance invariant at the database level. Any mismatch is rejected at INSERT and UPDATE time.
- `fx_rate_used` — the ECB exchange rate applied to convert the original transaction currency to EUR, as `numeric(10,6)`. Units: EUR per 1 unit of the original currency (e.g., `0.920000` means 1 USD = 0.92 EUR). Null for EUR transactions where no conversion was needed. When populated, this value is sourced from `ecb_fx_rates` (defined in `ecb_rate_schema`) via `ledger.fetch_ecb_rate`. The rate is pinned at entry creation time; it does not change even if the ECB rate is subsequently updated.
- `original_currency` — the ISO 4217 three-letter currency code of the transaction before EUR conversion. `EUR` for EUR transactions (in which case `fx_rate_used` and `ecb_rate_date` are null). Other codes (e.g., `USD`, `GBP`, `CHF`) for non-EUR transactions.
- `ecb_rate_date` — the calendar date of the ECB rate used for FX conversion. Null for EUR transactions. This is the date of the rate record in `ecb_fx_rates` that was used — not necessarily the `ledger_entries.entry_date` (the rate engine falls back to the nearest prior business day if no rate exists for the exact entry date, per `ecb_rate_schema`). Storing this date makes the rate lookup fully reproducible without querying the ECB rate table.
- `is_locked` — `false` until the period is finalized. Set to `true` by the finalization locking step (Block 15 Phase 03) concurrently with locking the parent `ledger_entries` row. Once `true`, the VAT entry is immutable; any attempt to update a locked row is blocked by an application-layer guard (and by the immutability trigger pattern inherited from `ledger_entries`). A locked `vat_entries` row is included in the Finalized Archive zone per Block 15 Phase 04.

---

## VAT treatment and row creation policy

| `vat_treatment` value | VAT entry created | `vat_rate` | `vat_amount_eur` |
|---|---|---|---|
| `DOMESTIC_STANDARD` | Yes | `0.1900` | `net × 0.19` |
| `DOMESTIC_REDUCED` | Yes | `0.0900` or `0.0500` | `net × rate` |
| `DOMESTIC_ZERO` | Yes | `0.0000` | `0.00` |
| `EU_REVERSE_CHARGE` | Yes | `0.0000` (invoice); self-assessed separately | `0.00` on this entry |
| `IMPORT_OR_ACQUISITION` | Yes | Applicable Cyprus rate | `net × rate` |
| `NON_EU_SERVICE` | Yes | `0.0000` | `0.00` |
| `OUTSIDE_SCOPE` | No — no row created | — | — |
| `UNKNOWN` | No — deferred; accountant review required | — | — |

`OUTSIDE_SCOPE` transactions generate a ledger entry but no VAT entry. `UNKNOWN` transactions generate a ledger entry in draft state; the VAT entry is created once the accountant resolves the treatment (which cannot be `UNKNOWN` in a locked entry).

For `EU_REVERSE_CHARGE`, Block 11 Phase 06 computes the reverse-charge self-assessment amount separately and creates an additional ledger entry for the self-assessed VAT. The `vat_entries` row for the original entry records `vat_rate = 0.0000` and `vat_amount_eur = 0.00`; the reverse-charge self-assessment creates its own `vat_entries` row with the applicable Cyprus rate.

---

## RLS

```sql
CREATE POLICY vat_entries_isolation ON vat_entries
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Tenant isolation by `business_id`. No cross-business read path exists.

---

## Indexes

```sql
-- Primary lookup: VAT entry for a ledger entry (one-to-one)
CREATE UNIQUE INDEX idx_vat_entries_ledger_entry
  ON vat_entries (ledger_entry_id);

-- Run-level VAT aggregation (VAT return preparation)
CREATE INDEX idx_vat_entries_run
  ON vat_entries (workflow_run_id, vat_treatment);

-- Business-scoped VAT summary by treatment and period
CREATE INDEX idx_vat_entries_business_treatment
  ON vat_entries (business_id, vat_treatment, created_at);

-- Unlocked entries for pending finalization scan
CREATE INDEX idx_vat_entries_unlocked
  ON vat_entries (business_id, is_locked)
  WHERE is_locked = false;
```

---

## Mobile write rejection

`ledger.prepare_entries` and `ledger.compute_vat_amounts` are server-side workflow tools. No client or mobile write path exists for `vat_entries`. Any direct write attempt from a mobile client is rejected per `mobile_write_rejection_endpoints.md`. Mobile clients may view VAT summaries through read-only dashboard surfaces.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `VAT_ENTRY_CREATED` | `vat_entries` row inserted by `ledger.compute_vat_amounts` | LOW |

The event is emitted via `emitAudit()` per `audit_log_policies`. The `VAT_ENTRY_CREATED` payload includes `vat_entry_id`, `ledger_entry_id`, `business_id`, `vat_treatment`, `vat_rate`, `net_amount_eur`, `vat_amount_eur`, and `gross_amount_eur`. The existing taxonomy events `LEDGER_VAT_TREATMENT_DECIDED` and `LEDGER_ENTRIES_PREPARED` (Block 11) cover the broader VAT and ledger domain events; `VAT_ENTRY_CREATED` is the table-lifecycle event for this schema. No audit event is emitted for locking; `FINALIZATION_LEDGER_BULK_LOCKED` (Block 15) covers the aggregate period-lock event.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; `numeric(15,2)` for all EUR amounts; `numeric(5,4)` for VAT rate; `numeric(10,6)` for FX rate; no floating-point currency
- `ledger_entry_schema` — `ledger_entry_id` FK; one-to-one relationship; parent entry's `vat_treatment` and `entry_date` inform the VAT entry; immutability trigger pattern
- `vat_treatment_enum` — closed 8-value enum; `vat_treatment` must be a valid non-null value
- `vat_rate_table_reference` — rate-resolution query; valid rate values for MVP Cyprus rates; `DOMESTIC_REDUCED` 9% vs 5% resolution
- `ecb_rate_schema` — `ecb_fx_rates` table; `fx_rate_used` and `ecb_rate_date` sourced from this table; fallback to nearest prior business day when exact date unavailable
- `audit_log_policies` — `LEDGER` domain; `VAT_ENTRY_CREATED` event; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `VAT_ENTRY_CREATED`, `LEDGER_VAT_TREATMENT_DECIDED`, `LEDGER_ENTRIES_PREPARED`
- Block 11 Phase 05 — VAT treatment classifier; determines `vat_treatment` on the parent ledger entry
- Block 11 Phase 06 — reverse-charge and VIES relevance; creates the self-assessment VAT entry for `EU_REVERSE_CHARGE` transactions
- Block 11 Phase 08 — VAT amount computation; primary writer via `ledger.compute_vat_amounts`; resolves the applicable rate and computes amounts
- Block 15 Phase 03 — period finalization and locking; sets `is_locked = true`; rejects entries with `vat_treatment = UNKNOWN`
- Block 16 Phase 11 — VAT return and VIES export; reads this table for VAT return summary computation
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
