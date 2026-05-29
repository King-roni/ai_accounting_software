# Tool: ledger.fx_convert

**Category:** Tools · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Converts a monetary amount from one currency to another using the ECB rate cache. This tool is READ_ONLY: it reads from `ecb_fx_rate_cache` and returns a conversion result. It does not write ledger entries, does not emit audit events, and does not modify any row. The caller is responsible for recording the rate in the ledger entry.

---

## Tool identifier

`ledger.fx_convert`

## Side effect class

`READ_ONLY`

No writes. No audit events. No mobile rejection applies (mobile rejection governs WRITES_* tools only — see `mobile_write_rejection_endpoints.md`).

---

## Input schema

```json
{
  "amount":           "numeric — positive, required",
  "from_currency":    "char(3) — ISO 4217 currency code, required",
  "to_currency":      "char(3) — ISO 4217 currency code, required",
  "conversion_date":  "date — the date for which the rate is sought, required",
  "business_id":      "uuid — required for audit context and rate-cache scoping"
}
```

`amount` must be positive and non-zero. Passing a negative amount returns `LEDGER_FX_INVALID_AMOUNT`. Passing an unrecognised currency code returns `LEDGER_CURRENCY_UNSUPPORTED`.

---

## Rate lookup behaviour

1. Query `ecb_fx_rate_cache` for the row matching `(from_currency, to_currency, conversion_date)`.
2. If the row exists and is not stale, return it as `rate_source = 'ECB_CACHE'`.
3. If no row exists for `conversion_date`, scan backwards up to 5 business days (calendar days excluding Saturday/Sunday) for the most recent prior rate. If found, return it as `rate_source = 'ECB_FALLBACK'`.
4. If no rate is found within 5 business days, return error `LEDGER_ECB_RATE_STALE` and do not return a converted amount. The caller must surface this as a review issue.

The 5-business-day fallback covers weekends and Cyprus public holidays where the ECB does not publish rates. Extending the fallback beyond 5 business days requires a manual override flow documented in `ecb_fx_rate_cache_reference.md`.

---

## EUR pivot for cross-currency pairs

ECB rates are EUR-based (all rates quoted as units of foreign currency per 1 EUR). When both `from_currency` and `to_currency` are non-EUR, the conversion uses EUR as a pivot:

```
from_amount → EUR intermediate → to_amount
rate_used = (1 / from_EUR_rate) * to_EUR_rate
```

When `from_currency = 'EUR'`, only the `to_currency` rate is needed. When `to_currency = 'EUR'`, only the `from_currency` rate is needed.

Cyprus base currency is EUR. The dominant use case is `to_currency = 'EUR'` (converting a foreign receipt or invoice to EUR for ledger posting).

---

## Output schema

```json
{
  "converted_amount":      "numeric(15,2) — rounded to 2 decimal places",
  "rate_used":             "numeric(12,6) — the effective exchange rate applied",
  "rate_date":             "date — the date of the rate actually used",
  "rate_source":           "'ECB_CACHE' | 'ECB_FALLBACK'",
  "ecb_cache_record_id":   "uuid — the ecb_fx_rate_cache row id used"
}
```

`rate_date` may differ from the requested `conversion_date` when a fallback rate is used. Callers must store `rate_date` alongside `rate_used` in the ledger entry — posting the rate without the date it was sourced from is a data quality violation.

---

## Rounding

`converted_amount` is rounded to 2 decimal places using ROUND_HALF_UP (standard arithmetic rounding). Intermediate calculations use full numeric precision; rounding is applied only to the final output value. This matches Cyprus VAT calculation requirements.

---

## Error codes

| Code | Condition |
|---|---|
| `LEDGER_ECB_RATE_STALE` | No rate found within 5 business days of conversion_date |
| `LEDGER_CURRENCY_UNSUPPORTED` | from_currency or to_currency not in the ECB rate set |
| `LEDGER_FX_INVALID_AMOUNT` | amount is zero or negative |

When `LEDGER_ECB_RATE_STALE` is returned, the audit event `LEDGER_ECB_RATE_STALE` (MEDIUM) is emitted by the rate-lookup layer, not by this tool. The tool propagates the error to the caller.

---

## Caller responsibilities

- Record `rate_used`, `rate_date`, and `ecb_cache_record_id` on the `ledger_entries` row via `ledger.post`.
- Do not call `ledger.fx_convert` for amounts already in EUR — pass them directly to `ledger.post` with `fx_rate = null`.
- If the tool returns `LEDGER_ECB_RATE_STALE`, the caller must create a `LEDGER_CURRENCY_UNSUPPORTED` review issue and hold ledger posting until the rate is resolved.

---

## Audit events

None. This tool is READ_ONLY. All audit events related to FX rates are emitted by the rate-fetch background job (`ECB_RATE_FETCHED`) or by the stale-rate detection layer (`LEDGER_ECB_RATE_STALE`).

---

## Cross-references

- `ecb_fx_rate_cache_reference.md` — cache schema, TTL, and manual override flow
- `ledger_entry_schema.md` — where rate_used and rate_date are stored on ledger rows
- `vat_rate_table_reference.md` — Cyprus VAT rates (separate from FX rates)
- `tool_ledger_post.md` — the WRITES tool that records the converted amount and rate
- `audit_event_taxonomy` — LEDGER_ECB_RATE_STALE and ECB_RATE_FETCHED event definitions

---

## Usage pattern within a workflow run

A typical ledger phase that processes a non-EUR transaction calls `ledger.fx_convert` before calling `ledger.post`:

1. Read the transaction's `currency` and `amount_signed` from the transactions table.
2. Call `ledger.fx_convert` with `from_currency = transaction.currency`, `to_currency = 'EUR'`, `conversion_date = transaction.date`, `business_id = transaction.business_id`.
3. On success: pass `converted_amount` as the `amount` parameter to `ledger.post`, and pass `rate_used`, `rate_date` as `fx_rate`, `fx_rate_date`.
4. On `LEDGER_ECB_RATE_STALE`: do not call `ledger.post`. Create a review issue, set the run to REVIEW_HOLD for the affected transaction, and continue processing remaining transactions.

This two-step pattern ensures that the rate provenance (which specific cache row supplied the rate) is always traceable from the ledger entry back to the `ecb_fx_rate_cache` row via `ecb_cache_record_id`.

---

## Concurrency note

`ledger.fx_convert` holds no locks. Multiple concurrent workflow runs for the same business can call it simultaneously. The underlying `ecb_fx_rate_cache` table is append-only for the background fetch job and read-only for callers, so there is no write contention on the happy path.

---

## Open items deferred to later sub-docs

- Manual override flow for currencies absent from ECB for more than 5 days — `ecb_fx_rate_cache_reference.md`
- Bank-sourced rate fallback (FX_RATE_FETCHED_BANK) — Block 11 Phase 04
