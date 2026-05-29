# fx_conversion_source_integration

**Category:** Integrations · **Owning block:** 11 — Ledger & Cyprus VAT Engine · **Co-owner:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The FX rate source integration. Per Stage 1: "FX rate source: Bank-recorded rate from the FX leg (Revolut's own rate). ECB daily rate as fallback when the bank rate is missing."

Two-tier sourcing: primary is the bank-recorded rate parsed from `transactions.fx_paired_legs`; fallback is the ECB daily reference rate fetched from the European Central Bank's public API.

---

## Primary source — bank-recorded rate

Source: `transactions.fx_paired_legs.legs[].exchange_rate_to_eur` per `fx_paired_legs_schema`. The bank captures the rate at transaction time; the parser preserves it.

`fx_paired_legs.rate_source = "bank"` indicates this case.

No external API call — the rate is in the bank statement bytes the user uploaded.

## Fallback source — ECB daily reference rate

Source: ECB Statistical Data Warehouse public API.

```
GET https://data-api.ecb.europa.eu/service/data/EXR/D.{CCY}.EUR.SP00.A
  ?startPeriod={date}&endPeriod={date}
  &format=jsondata
```

Response (extract):

```json
{
  "dataSets": [{
    "series": {
      "0:0:0:0:0": {
        "observations": {
          "0": [1.0843]
        }
      }
    }
  }],
  "structure": {
    "dimensions": {
      "observation": [{"id": "TIME_PERIOD", "values": [{"id": "2026-01-15"}]}]
    }
  }
}
```

The rate (1.0843 in this example) is EUR per unit of the foreign currency (or its inverse depending on convention — pinned per `currency_comparison_reference_policy`).

`fx_paired_legs.rate_source = "ecb_fallback"` indicates this case.

## When fallback kicks in

Per Block 07 Phase 04's row normalization:

1. If the bank statement carries a per-leg rate → use that rate; mark `rate_source = "bank"`
2. If the bank statement is missing a per-leg rate AND the transaction is an FX_EXCHANGE → fetch ECB rate for the transaction date; mark `rate_source = "ecb_fallback"`
3. If both fail (bank rate missing AND ECB unreachable) → mark transaction as `Needs Confirmation` (per `issue_type_to_group_mapping`); user-supplied rate required

## Caching

Per-day ECB rates are cached in a local `fx_rates_cache` table:

```sql
CREATE TABLE fx_rates_cache (
  rate_date          date NOT NULL,
  source_currency    text NOT NULL,                       -- e.g., 'USD'
  target_currency    text NOT NULL DEFAULT 'EUR',
  rate               numeric(15, 6) NOT NULL,
  fetched_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (rate_date, source_currency, target_currency)
);
```

Refresh: a background job fetches today's rates once per day at 18:00 CET (ECB publishes around 16:00 CET). The cache survives application restarts.

Per Stage 1: "Hosting region: EU only" — ECB's API is EU-hosted by definition.

## Failure handling

| Failure | Behavior |
| --- | --- |
| ECB API unreachable | Use cache (last-known rate within ±3 days); if no cache → raise `intake.fx_rate_unresolvable` review issue |
| ECB returns no rate for the date (weekend / bank holiday) | Use ECB rate from the previous business day (per ECB convention) |
| ECB cert / TLS failure | Treated as unreachable; fall through to cache |

The integration is best-effort. Missing rates surface as review issues, not as workflow blockers.

## Audit events

| Event | When |
| --- | --- |
| `FX_RATE_FETCHED_BANK` | Bank-recorded rate parsed from statement (aggregated per workflow run) |
| `FX_RATE_FETCHED_ECB` | ECB fallback rate fetched |
| `FX_RATE_UNRESOLVABLE` | Both sources failed |

## Performance

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| ECB API fetch (single date) | 200 ms | 1 s | 3 s |
| Cache hit | < 5 ms | < 20 ms | < 50 ms |

ECB API has no published rate limit but the integration self-throttles to < 10 requests / second.

## Cost

ECB API is free. No metering, no auth, no subscription. The integration footprint is negligible.

## EU residency

ECB API is EU-domiciled (European Central Bank). Compliant with Stage 1 EU-only rule.

## Cross-references

- `fx_paired_legs_schema` — host column for `rate_source` and `exchange_rate_to_eur`
- `currency_comparison_reference_policy` — always-EUR comparison rule
- `transactions_schema` — host table
- `audit_log_policies` — event naming
- `transaction_type_enum` — `FX_EXCHANGE` consumer
- Block 07 Phase 04 — row normalization
- Block 11 Phase 07 — ledger preparation for FX
- Stage 1 decision — bank rate primary, ECB fallback

---

## Fallback chain documentation

The full priority order for FX rate resolution, from most preferred to least:

```
1. Bank-recorded rate
   Source: transactions.fx_paired_legs.legs[].exchange_rate_to_eur
   Marker: fx_paired_legs.rate_source = "bank"
   When: the bank statement (e.g., Revolut CSV) includes a per-leg exchange rate
   Preferred because: it reflects the actual rate the business transacted at

2. ECB cache (previously fetched rate, still within TTL)
   Source: fx_rates_cache table; cache hit for (rate_date, source_currency, target_currency)
   Marker: fx_paired_legs.rate_source = "ecb_fallback"; fx_rate_cache_hit = true
   When: bank rate is missing AND a cached ECB rate for the transaction date exists and is fresh

3. ECB live fetch
   Source: ECB Statistical Data Warehouse API (live call)
   Marker: fx_paired_legs.rate_source = "ecb_fallback"; fx_rate_cache_hit = false
   When: bank rate is missing AND no cached rate exists for the date (or cache is stale)

4. ECB previous-business-day rate (weekend/holiday fallback)
   Source: ECB API or cache, walking back to the most recent ECB business day
   Marker: fx_paired_legs.rate_source = "ecb_fallback"; fx_rate_date_adjusted = true
   When: the transaction date falls on a weekend or public holiday and ECB has no rate for that date

5. Manual override (user-supplied rate)
   Source: user provides a rate via the review queue
   Marker: fx_paired_legs.rate_source = "manual_override"
   When: all automated sources failed; user intervention required
   Trigger: a Needs Confirmation review issue is raised for the transaction
```

The fallback chain is deterministic and auditable: the `rate_source` marker on each `fx_paired_legs` record tells the auditor exactly which tier was used.

---

## ECB rate cache TTL

The ECB rate cache has a TTL of **48 hours** from the `fetched_at` timestamp. A cached rate older than 48 hours is considered stale and triggers a fresh ECB API fetch.

Rationale for 48 hours: ECB publishes rates once per business day (around 16:00 CET). A 48-hour TTL ensures:
- The cache is refreshed daily by the background job
- If the background job fails one day, the previous day's rate is still usable for a full business day
- Weekend transactions (when ECB doesn't publish) use the Friday rate, which will still be within TTL on Monday

The background job refreshes at 18:00 CET (2 hours after ECB's typical publication time). If the job fails to run (e.g., server maintenance), the 48-hour TTL provides a safety buffer before any degradation is visible to users.

**Stale cache behavior**: if the cached rate is older than 48 hours AND the ECB API is reachable, the cache is refreshed before use. If the API is not reachable AND the cache is older than 48 hours but not older than 72 hours, the stale cache is used with a `FX_RATE_STALE_CACHE_USED` audit event at LOW severity. Beyond 72 hours: the rate is considered unreliable; the system falls through to the manual-override path and raises a `Needs Confirmation` issue.

---

## Currency conversion error handling

| Error condition | Primary behavior | Fallback |
| --- | --- | --- |
| Bank rate missing (no `exchange_rate_to_eur` in legs) | Proceed to ECB cache/fetch | ECB → manual |
| ECB API unreachable | Use cache (≤ 48h: fresh; ≤ 72h: stale with LOW event) | If > 72h stale: manual override required |
| ECB returns `INVALID_CURRENCY` for a non-EU-traded currency | `FX_RATE_UNRESOLVABLE` event; Needs Confirmation issue raised | User must supply rate manually |
| Rate = 0 (data error from bank or ECB) | Treated as missing; proceed to next tier | Same chain |
| `fx_paired_legs` is missing entirely (FX_EXCHANGE transaction without leg data) | Block 07 Phase 04 raises a `Needs Confirmation` issue immediately; does not attempt ECB fetch | User must either re-upload the statement or manually enter the legs |
| Multiple legs with conflicting rates (rare — some banks report both buy and sell rate) | Use the `exchange_rate_to_eur` from the leg whose direction is OUT (the cost to the business) | If direction is ambiguous: `FX_RATE_UNRESOLVABLE` |

---

## Additional cross-references

- `ecb_rate_schema` — schema for the `fx_rates_cache` table including `fetched_at`, `rate_date`, TTL enforcement columns
