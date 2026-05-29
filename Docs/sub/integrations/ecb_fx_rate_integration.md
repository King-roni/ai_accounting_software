# Integration: ECB FX Rate

**Block:** FX Conversion  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The system fetches daily exchange rates from the European Central Bank (ECB) Statistical Data Warehouse API and stores them in the `fx_rates` table. Rates are used by `tool_fx_convert.md` to convert non-EUR transaction amounts to EUR for ledger posting and reporting. The fetch runs on a scheduled Supabase edge function triggered at 16:30 CET on each TARGET2 business day. On days when ECB does not publish (weekends, TARGET2 holidays), the previous business day's rates are reused.

## ECB API Endpoint

```
https://data-api.ecb.europa.eu/service/data/EXR/
```

The ECB Statistical Data Warehouse exposes a REST API conforming to the SDMX 2.1 standard. The system queries the `EXR` (Exchange Rate) data flow. A typical request for EUR/USD daily rates:

```
GET https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?lastNObservations=1
Accept: application/json
```

Key query parameters:

| Parameter | Value | Description |
|---|---|---|
| `D` | frequency | Daily |
| `{currency}` | e.g. `USD`, `GBP`, `CHF` | Quote currency |
| `EUR` | base currency | Always EUR |
| `SP00` | series variation | Spot rate |
| `A` | series suffix | Average |
| `lastNObservations=1` | | Return only the latest observation |

The system fetches rates for all currencies present in the business's `fx_paired_legs` for the current period, plus a baseline set of common currencies: USD, GBP, CHF, SEK, NOK, DKK, PLN, CZK, HUF.

## Rate Storage Schema

Rates are stored in the `fx_rates` table (see `ecb_rate_schema.md` for full DDL). The relevant columns are:

| Column | Type | Description |
|---|---|---|
| `id` | UUID | PK gen_uuid_v7() |
| `base_currency` | CHAR(3) | Always `'EUR'` |
| `quote_currency` | CHAR(3) | The non-EUR currency |
| `rate` | DECIMAL(18,8) | Units of quote_currency per 1 EUR |
| `rate_date` | DATE | The date the ECB published this rate |
| `source` | TEXT | Always `'ECB'` |
| `fetched_at` | TIMESTAMPTZ | When the system retrieved the rate |

## Fetch Schedule

The fetch is triggered by a Supabase scheduled edge function configured at `16:30 CET` (15:30 UTC in CET, 14:30 UTC in CEST). This is 30 minutes after the ECB publishes its daily reference rates at 16:00 CET, providing a buffer for ECB publication latency.

The cron expression in the Supabase scheduler:

```
30 15 * * 1-5
```

(Monday–Friday at 15:30 UTC; note this uses UTC and does not auto-adjust for CET/CEST transitions — see the Bank Holiday Handling section for how this is managed.)

## Cache Invalidation

If a rate for `(base_currency, quote_currency, rate_date)` already exists in `fx_rates`, the fetch function performs an upsert using `ON CONFLICT (base_currency, quote_currency, rate_date) DO UPDATE SET rate = EXCLUDED.rate, fetched_at = EXCLUDED.fetched_at`. This means re-running the fetch on the same day overwrites the existing record with the freshest value, which handles ECB intra-day corrections (rare but possible).

## Staleness Policy

Rate freshness rules are defined in `ecb_rate_freshness_policy.md`. The key operational rule is:

- A rate is considered fresh if `rate_date >= CURRENT_DATE - INTERVAL '1 business day'`.
- When `tool_fx_convert.md` requests a rate and the most recent available rate is older than the freshness threshold, the tool checks whether the gap is explained by a non-publishing day (weekend or TARGET2 holiday). If yes, the rate is used with a `stale_rate_used = true` flag recorded in the conversion result. If no explainable gap, the conversion is blocked and an alert is raised.

## Bank Holiday Handling

The ECB publishes rates only on TARGET2 business days. TARGET2 holidays include:

- New Year's Day (1 January)
- Good Friday
- Easter Monday
- Labour Day (1 May)
- Christmas Day (25 December)
- Boxing Day (26 December)

On these days, the ECB API either returns no new observation or returns the previous business day's rate. The fetch function handles this by:

1. Attempting the fetch as scheduled.
2. If the returned `rate_date` equals the previous business day's date (not today), recording the rate with the `rate_date` as returned by ECB and setting a `non_publishing_day = true` flag on the row.
3. `tool_fx_convert.md` is aware of this flag and accepts non-publishing-day rates as valid without triggering a staleness alert.

The list of TARGET2 holidays is maintained in a configuration table `target2_holidays` and is updated annually.

## Error Handling

| Condition | Response |
|---|---|
| HTTP timeout (> 10 seconds) | Retry with 5-second backoff, up to 3 attempts |
| HTTP 429 (rate limited) | Retry after the `Retry-After` header value, up to 3 attempts |
| HTTP 5xx | Retry × 3 with 10-second backoff |
| Parsing failure (unexpected SDMX schema) | Log error, emit `ECB_RATE_FETCH_FAILED`, create alert |
| All retries exhausted | Emit `ECB_RATE_FETCH_FAILED` (HIGH), create `alert_schema` record, notify on-call |

After all retries are exhausted, the system continues to use the previous business day's rate with `stale_rate_used = true` for any conversions that occur before the next successful fetch. This ensures the system remains operational during short ECB API outages.

## Audit Events

| Event | Severity | When emitted |
|---|---|---|
| `ECB_RATE_FETCHED` | LOW | After a successful fetch writes new rates to `fx_rates` |
| `ECB_RATE_STALE` | MEDIUM | When `tool_fx_convert.md` uses a rate older than the freshness threshold without a non-publishing-day explanation |
| `ECB_RATE_FETCH_FAILED` | HIGH | When the scheduled fetch fails after all retries |

The `ECB_RATE_FETCHED` payload includes: `rate_date`, `currencies_fetched`, `currencies_updated`, `fetch_duration_ms`.  
The `ECB_RATE_FETCH_FAILED` payload includes: `attempted_at`, `retry_count`, `last_error`, `last_successful_rate_date`.

## Integration with tool_fx_convert

`tool_fx_convert.md` is the sole consumer of the `fx_rates` table at runtime. It queries:

```sql
SELECT rate, rate_date, fetched_at
FROM fx_rates
WHERE base_currency = 'EUR'
  AND quote_currency = $1
ORDER BY rate_date DESC
LIMIT 1;
```

If the returned `rate_date` is not today and not explained by a non-publishing day, `tool_fx_convert.md` emits `ECB_RATE_STALE` before proceeding with the conversion.

## Local Development

In local development environments, the ECB API is not called on a schedule. Instead, a seed script populates `fx_rates` with a static snapshot of rates for the development period. This prevents tests from depending on live ECB API availability. The seed file is at `supabase/seed/fx_rates_dev.sql` and is regenerated quarterly.

## Monitoring

A Supabase alert rule monitors for the absence of a new `ECB_RATE_FETCHED` event within the 24 hours following 16:30 CET on a business day. If no event is detected, the alert fires with severity `MEDIUM` and notifies the infrastructure on-call rotation. This catches silent failures where the scheduler does not trigger the edge function.

## Related Documents

- `ecb_rate_schema.md` — full DDL for the `fx_rates` table
- `ecb_rate_freshness_policy.md` — staleness thresholds and business-day calculation rules
- `tool_fx_convert.md` — the tool that consumes rates from this table
- `fx_conversion_source_integration.md` — broader FX conversion architecture
- `fx_paired_legs_schema.md` — multi-currency transaction pairing that drives which currencies are fetched
- `data_retention_policy.md` — `fx_rates` retention rules (Operational zone, retained indefinitely as reference data)
