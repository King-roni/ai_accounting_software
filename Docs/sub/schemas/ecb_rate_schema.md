# ecb_rate_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `ecb_fx_rates` table. The table caches daily foreign exchange rates published by the European Central Bank (ECB), used to convert non-EUR transaction amounts to EUR for ledger entry preparation and VAT computation. The ECB's Euro foreign exchange reference rates are the authoritative source for EUR conversion in the Cyprus bookkeeping context.

One row per `(currency_pair, rate_date)` is stored. Lookups during ledger preparation are served from this cache; when a required rate is absent, the `ledger.fetch_ecb_rate` tool retrieves it from the ECB XML feed and writes it here before returning the value to the caller.

---

## Table definition

```sql
CREATE TABLE ecb_fx_rates (
  rate_id           uuid            PRIMARY KEY DEFAULT gen_uuid_v7(),
  currency_pair     text            NOT NULL,
  rate_date         date            NOT NULL,
  rate              numeric(10,6)   NOT NULL CHECK (rate > 0),
  source            text            NOT NULL DEFAULT 'ECB',
  fetched_at        timestamptz     NOT NULL,
  created_at        timestamptz     NOT NULL DEFAULT now(),

  -- Unique rate per currency pair per date
  CONSTRAINT uq_ecb_fx_rates_pair_date
    UNIQUE (currency_pair, rate_date)
);
```

---

## Column notes

- `rate_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing; identifies this rate record uniquely.
- `currency_pair` — the currency pair string in the format `{foreign_currency}/EUR`. Examples: `USD/EUR`, `GBP/EUR`, `CHF/EUR`. All rates are expressed as units of EUR per 1 unit of the foreign currency (e.g., `USD/EUR = 0.920000` means 1 USD = 0.920000 EUR). The format is `<ISO 4217 code>/EUR` — the EUR leg is always the quote currency because the ledger is maintained in EUR. The `ECB/EUR` pair does not exist (EUR is not exchanged against itself); EUR transactions require no FX conversion and do not query this table.
- `rate_date` — the calendar date for which this rate was published by the ECB. Corresponds to the ECB's Euro foreign exchange reference rate publication date. Note that the ECB does not publish rates on weekends or ECB holidays; rate dates are always TARGET2 business days.
- `rate` — the ECB reference rate as `numeric(10,6)`. Units: EUR per 1 unit of the foreign currency. Positive (enforced by CHECK constraint). Six decimal places are stored to match the precision published in the ECB XML feed. Currency amounts derived from this rate are computed as `amount_original × rate` and rounded to `numeric(15,2)` at the point of entry into `vat_entries` and `ledger_entries`.
- `source` — the data source for this rate. Always `ECB` in MVP. Stored explicitly to allow future extension (e.g., `ECB_FALLBACK` for rates interpolated from adjacent days, or `MANUAL` for operator-entered corrections). The `source` value is recorded in the `ECB_RATE_FETCHED` audit event payload for traceability.
- `fetched_at` — wall-clock timestamp when the rate was retrieved from the ECB XML feed and written to this table. Distinct from `created_at` in that `fetched_at` records the time of the ECB API call, which may differ from the DB insert time by the duration of the network call.
- `created_at` — wall-clock timestamp of row insertion. Set by the database default.

---

## Rate lookup semantics

### Exact date lookup

When `ledger.fetch_ecb_rate` is called with `(currency_pair, date)`, it first queries the cache:

```sql
SELECT rate
FROM ecb_fx_rates
WHERE currency_pair = $1
  AND rate_date = $2;
```

If a row exists, the cached rate is returned immediately without an ECB API call.

### Nearest prior business day fallback

If no row exists for the exact `rate_date`, the tool falls back to the nearest prior date with a rate on record for the same `currency_pair`:

```sql
SELECT rate, rate_date
FROM ecb_fx_rates
WHERE currency_pair = $1
  AND rate_date < $2
ORDER BY rate_date DESC
LIMIT 1;
```

This fallback is necessary because the ECB does not publish rates on weekends or holidays. A transaction dated on a Saturday resolves to Friday's rate; a transaction dated on a public holiday resolves to the preceding business day's rate. The `ecb_rate_date` column on `vat_entries` records the fallback date (not the original transaction date) so the rate lookup is reproducible.

### Missing rate escalation

If neither the exact date nor any prior date is found in the cache (which should only occur for historical transactions predating the cache's coverage or for very recently introduced currency pairs), the tool:

1. Attempts to fetch from the ECB XML feed for the requested date range.
2. If the ECB feed also has no data (e.g., the currency is not in the ECB reference rate publication — not all currencies are published), the tool raises a `MISSING_FX_RATE` review issue with severity `MEDIUM` and returns an error to the caller.
3. The `vat_entries` and `ledger_entries` rows are not created until the review issue is resolved. The `FX_RATE_UNRESOLVABLE` audit event is emitted.

### Scheduled cache population

A scheduled job (Block 11 Phase 08) runs daily to pre-populate rates for the current and trailing 30 days for all currency pairs observed in recent transactions. This minimizes on-demand ECB API calls during ledger preparation runs.

---

## Data retention

Rates older than 2 years are purged by a scheduled job. The 2-year window covers the look-back horizon for historical corrections: the business may need to recompute ledger entries for the prior period (Block 12/13 adjustment runs cover the current and prior period only). Rates beyond 2 years cannot be required by any in-scope correction workflow. Finalized periods whose ledger entries reference purged rates retain the rate snapshot on the `vat_entries.fx_rate_used` and `vat_entries.ecb_rate_date` columns; the `ecb_fx_rates` row need not be present for a finalized entry to remain valid.

The purge is implemented by the retention engine per `data_retention_policy` using a scheduled delete on `ecb_fx_rates WHERE rate_date < now() - interval '2 years'`.

---

## RLS

```sql
-- No tenant-specific data in ecb_fx_rates; rates are global reference data.
-- Read access: all authenticated business roles (SELECT only).
-- Insert access: service-role only (enforced by application layer; ledger.fetch_ecb_rate is the only writer).
-- Update and delete: not permitted at application layer (append-only; purge via retention job only).
```

All business roles — Owner, Admin, Bookkeeper, Accountant, Reviewer, Read-only — may SELECT from this table. Rate data is non-sensitive; there is no PII and no tenant-specific information. The unique constraint prevents double-insertion of the same pair/date combination.

---

## Indexes

```sql
-- Primary cache lookup: exact date
CREATE UNIQUE INDEX idx_ecb_fx_rates_pair_date
  ON ecb_fx_rates (currency_pair, rate_date);

-- Fallback lookup: nearest prior date
CREATE INDEX idx_ecb_fx_rates_pair_date_desc
  ON ecb_fx_rates (currency_pair, rate_date DESC);

-- Retention purge: date range scan
CREATE INDEX idx_ecb_fx_rates_date
  ON ecb_fx_rates (rate_date);
```

---

## Mobile write rejection

`ledger.fetch_ecb_rate` is a server-side workflow tool. No client or mobile write path exists for `ecb_fx_rates`. Any direct write attempt from a mobile client is rejected per `mobile_write_rejection_endpoints.md`. Rate data is readable by all authenticated roles via the standard API layer.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `ECB_RATE_FETCHED` | A new row is inserted into `ecb_fx_rates` after retrieval from the ECB XML feed | LOW |

The `ECB_RATE_FETCHED` event is emitted via `emitAudit()` per `audit_log_policies`. The payload includes `rate_id`, `currency_pair`, `rate_date`, `rate` (decimal string), `source`, and `fetched_at`. The event exists in `audit_event_taxonomy` under the `LEDGER` domain. Cache hits (lookups that find an existing row) do not emit an audit event; the event is emitted only on new row insertion.

The existing taxonomy event `FX_RATE_FETCHED_ECB` (Block 11 LEDGER domain) covers the same semantic but is the operational event emitted by the ledger preparation pipeline. `ECB_RATE_FETCHED` is the table-lifecycle event for this schema specifically. Both events may be emitted in the same workflow step; they are complementary.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; `numeric(10,6)` for rate precision; `numeric(15,2)` for derived EUR amounts; no floating-point currency in derived amounts
- `vat_entry_schema` — `fx_rate_used` and `ecb_rate_date` columns sourced from this table; rate snapshot on VAT entries for reproducibility
- `ledger_entry_schema` — `fx_rate` and `amount_eur` columns computed using rates from this table; EUR conversion for non-EUR transactions
- `fx_conversion_source_integration` — Block 11 integration contract for the ECB XML feed; scheduled cache population; error handling for unavailable currencies
- `audit_log_policies` — `LEDGER` domain; `ECB_RATE_FETCHED` event; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `ECB_RATE_FETCHED`, `FX_RATE_FETCHED_ECB`, `FX_RATE_UNRESOLVABLE`
- `data_retention_policy` — 2-year retention window; scheduled purge of old rates
- Block 11 Phase 08 — VAT amount computation; primary consumer and scheduled cache populator; calls `ledger.fetch_ecb_rate`
- Block 11 Phase 07 — ledger preparation dispatcher; reads FX-converted amounts for non-EUR transactions
- `tool_naming_convention_policy` — `ledger.fetch_ecb_rate` tool name; `ledger.*` namespace
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
