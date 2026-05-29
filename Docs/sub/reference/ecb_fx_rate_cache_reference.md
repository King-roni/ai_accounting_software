# ecb_fx_rate_cache_reference

**Category:** Reference data · **Owning block:** 11 — Ledger & Cyprus VAT · **Co-owner:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 10 (Matching Engine — FX-adjusted match scoring); Block 11 Phase 08 (VAT amount computation and ECB rate cache population).

**Purpose:** Complete reference for the ECB FX rate cache: source feed, cache table structure, TTL and staleness semantics, currency coverage, conversion arithmetic, fallback chain, and the alert events emitted when the cache is stale or a currency is unsupported. Consumed by `ledger.fetch_ecb_rate`, the matching engine's FX normalization step, and the Revolut CSV parser's multi-currency conversion path.

---

## Rate source

The European Central Bank publishes daily Euro foreign exchange reference rates as an XML feed:

```
https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml
```

Rate semantics: **1 EUR = X units of foreign currency**. This is the inverse of the more common `X/EUR` quoting convention. The ECB quotes EUR as the base currency; the feed states how many units of each foreign currency equal one euro.

Example from the ECB feed:
```xml
<Cube currency='USD' rate='1.0821'/>
```
This means 1 EUR = 1.0821 USD.

The ECB publishes rates on TARGET2 business days at approximately 16:00 CET. No rates are published on weekends or ECB holidays. This means transactions dated on non-business days are resolved against the most recent prior business day's rates — the fallback mechanism is by design, not a gap.

---

## Cache table

The cache table `ecb_fx_rates` is defined in `ecb_rate_schema`. The relevant columns for this reference:

| Column | Type | Description |
|---|---|---|
| `rate_id` | `uuid` (UUID v7) | PK per `data_layer_conventions_policy §2` |
| `rate_date` | `date` | Calendar date for which the ECB published this rate |
| `currency_code` | `char(3)` | ISO 4217 three-letter code for the foreign currency (e.g., `USD`, `GBP`, `CHF`) |
| `rate_eur` | `numeric(18,8)` | Units of foreign currency per 1 EUR, as published by the ECB. Extended precision retained to avoid rounding loss during conversion; truncated to 6 significant figures when sourced from the ECB XML feed |
| `fetched_at` | `timestamptz` | Timestamp of the HTTP call that retrieved this row from the ECB feed |
| `source` | text | `ECB_DAILY` for rates retrieved from the ECB feed; `MANUAL_OVERRIDE` for operator-entered corrections |

**Unique constraint:** `(currency_code, rate_date)` — one rate row per currency per day. Attempt to insert a duplicate raises a conflict; the existing row is not overwritten (rates are immutable once written).

**Note on schema file:** The authoritative DDL lives in `ecb_rate_schema`. The column names in `ecb_rate_schema` use `currency_pair` (e.g., `USD/EUR`) and `rate` (with precision `numeric(10,6)`). This reference doc normalises the semantics; treat `ecb_rate_schema` as canonical for column names and DDL.

---

## Cache TTL and freshness

A rate row is considered **fresh** for 24 hours after `fetched_at`. Background job cadence aligns with this TTL: the cache populator runs daily at **16:00 CET** (after the ECB publishes its daily rates) and fetches the latest rates for all currency codes observed in recent transactions.

Staleness detection logic:

```
is_stale = (now() - fetched_at) > interval '24 hours'
         AND rate_date = today()
         AND source = 'ECB_DAILY'
```

When a lookup for today's rate finds only a stale row (fetched more than 24 hours ago for today's date), the system emits a `LEDGER_ECB_RATE_STALE` alert and proceeds with the stale rate under the fallback semantics described below. Stale detection does not apply to `MANUAL_OVERRIDE` rows; manual overrides are considered valid until explicitly superseded.

The `LEDGER_ECB_RATE_STALE` alert payload includes: `currency_code`, `rate_date`, `fetched_at`, `staleness_seconds`, `business_id` (the business whose ledger run triggered the stale check).

---

## Currency coverage

The ECB daily feed publishes rates for 32 currencies as of the current publication. The covered set includes: USD, GBP, JPY, CHF, AUD, CAD, HKD, SEK, NOK, DKK, NZD, SGD, HUF, CZK, PLN, RON, BGN, TRY, BRL, CNY, HRK, IDR, ILS, INR, KRW, MXN, MYR, PHP, THB, ZAR, and others subject to ECB publication changes.

EUR itself is never in the feed (EUR/EUR = 1.0 by definition). EUR transactions bypass the FX lookup entirely.

Currencies **not covered** by the ECB feed fall back to `MANUAL_OVERRIDE`. An operator may insert a `MANUAL_OVERRIDE` row for any currency not in the ECB publication. If no manual override exists for an unsupported currency, the transaction is blocked with a `LEDGER_CURRENCY_UNSUPPORTED` review issue (severity MEDIUM).

The `LEDGER_CURRENCY_UNSUPPORTED` review issue payload: `transaction_id`, `business_id`, `currency_code`, `transaction_date`, `workflow_run_id`.

---

## Conversion arithmetic

All non-EUR amounts are converted to EUR using:

```
amount_eur = amount_foreign / rate_eur
```

Where `rate_eur` is the ECB rate as stored (units of foreign currency per 1 EUR).

Rounding: **HALF_UP** to 2 decimal places. Results are stored as `numeric(15,2)`. Intermediate calculations use `numeric(18,8)` precision. Floating-point types are never used — per `data_layer_conventions_policy §3`, currency amounts are never stored as floats.

Example:

```
Transaction: 1000.00 USD
ECB rate (USD): rate_eur = 1.08210000  (1 EUR = 1.0821 USD)
amount_eur = 1000.00 / 1.08210000 = 924.13 EUR  (HALF_UP)
```

The `rate_eur` value used and the `rate_date` from which it was sourced are stored on the resulting `vat_entries` and `ledger_entries` rows (`fx_rate_used`, `ecb_rate_date` columns) for full reproducibility.

---

## Fallback chain

When a rate is needed for `(currency_code, transaction_date)`, the lookup proceeds in this order:

| Step | Condition | Action |
|---|---|---|
| 1 | Fresh ECB_DAILY row exists for `(currency_code, transaction_date)` | Use it; no alert |
| 2 | Stale ECB_DAILY row exists for `(currency_code, transaction_date)` | Use it; emit `LEDGER_ECB_RATE_STALE` |
| 3 | No row for exact date; nearest prior date row exists (any source) | Use nearest prior; record fallback date on `ecb_rate_date` column |
| 4 | MANUAL_OVERRIDE row exists for `(currency_code, transaction_date)` | Use it; no staleness check |
| 5 | No row found by any path | Create `LEDGER_CURRENCY_UNSUPPORTED` review issue; block ledger entry |

Step 3 covers the standard weekend/holiday case: a transaction dated Saturday uses Friday's rate. The `ecb_rate_date` stored on the ledger entry will be Friday's date, not Saturday's. This is expected behavior and does not raise an alert.

Step 4 (MANUAL_OVERRIDE) can apply at any step if an operator has explicitly overridden the rate for a currency/date pair. The `source = 'MANUAL_OVERRIDE'` value is recorded in the audit trail.

---

## Background fetch job

Block 11 Phase 08 owns the scheduled cache population job. Job parameters:

- **Schedule:** daily at 16:00 CET (after ECB publication)
- **Scope:** all currency codes seen in `bank_statement_rows` or `transactions` within the trailing 30 days, plus any codes with active `MANUAL_OVERRIDE` rows
- **Behavior:** fetches the ECB XML feed, inserts new rows for today's rates (skipping on conflict), updates `fetched_at` on existing rows if a fresher fetch arrives within the same day
- **Audit event:** `ECB_RATE_FETCHED` (LOW) emitted per inserted row; see `audit_event_taxonomy` under the `LEDGER` domain

---

## Audit events

| Event | Domain | When | Severity |
|---|---|---|---|
| `ECB_RATE_FETCHED` | `LEDGER` | New rate row inserted from ECB feed | LOW |
| `LEDGER_ECB_RATE_STALE` | `LEDGER` | Lookup finds a stale rate (> 24h old) for today's date | MEDIUM |
| `LEDGER_CURRENCY_UNSUPPORTED` | `LEDGER` | No rate found after full fallback chain; review issue created | MEDIUM |

`LEDGER_ECB_RATE_STALE` and `LEDGER_CURRENCY_UNSUPPORTED` are new events added to the taxonomy under the existing `LEDGER` domain (Block 11). Both events are emitted by `ledger.fetch_ecb_rate` during ledger preparation. See `audit_event_taxonomy` under the `LEDGER` domain section.

---

## Mobile write rejection

`ledger.fetch_ecb_rate` is a server-side workflow tool. No client or mobile surface may write to `ecb_fx_rates`. Per `mobile_write_rejection_endpoints.md`, any write attempt from a mobile client (`client_form_factor = MOBILE`) is rejected before reaching this table.

---

## Cross-references

- `csv_parser_revolut_format_spec` — multi-currency Revolut rows trigger this lookup; conversion formula consumed there
- `bank_statement_rows_schema` — `parsed_amount_eur` column populated by FX conversion using rates from this cache
- `ecb_rate_schema` — authoritative DDL for `ecb_fx_rates`; column-level definitions and RLS
- `ledger_entry_schema` — `fx_rate` and `amount_eur` columns computed using this cache; `ecb_rate_date` reproducibility column
- `data_layer_conventions_policy §2` — UUID v7 for `rate_id`
- `data_layer_conventions_policy §3` — `numeric(15,2)` output; no float currency storage
- `audit_event_taxonomy` — `ECB_RATE_FETCHED`, `LEDGER_ECB_RATE_STALE`, `LEDGER_CURRENCY_UNSUPPORTED`
- `fx_conversion_source_integration` — Block 11 integration contract for the ECB XML feed; error handling for unavailable currencies
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
- Block 11 Phase 08 — scheduled cache populator; primary writer of `ecb_fx_rates` rows
- Block 11 Phase 07 — ledger preparation dispatcher; calls `ledger.fetch_ecb_rate` for non-EUR transactions
- Block 10 — Matching Engine; uses ECB-converted `amount_eur` for scoring non-EUR transactions against EUR invoices
