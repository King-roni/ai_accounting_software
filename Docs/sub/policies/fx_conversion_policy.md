# FX Conversion Policy

**Block:** Ledger / Engine
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This policy governs how the platform converts transaction amounts in non-EUR currencies to EUR for ledger posting, reporting, and tax filing. Cyprus financial statements are required by law to be denominated in EUR. All amounts stored in the ledger's `amount_eur` column, and all figures in VAT returns and financial reports, reflect EUR values derived from this policy.

The policy applies to every transaction where `transaction.currency != 'EUR'` and to every invoice-payment matching scenario where the payment and invoice denominate in different currencies. Deviations from this policy require explicit documentation in the run's adjustment log.

## When FX Conversion Is Required

FX conversion is applied in the following situations:

1. **Transaction intake:** a bank statement row carries a non-EUR amount. The `amount_eur` field on the transaction record is populated at intake time using the rate in effect on the transaction's `value_date`.
2. **Invoice creation in non-EUR currency:** invoice amounts are stored in the invoice currency. The EUR equivalent is computed at the time of invoice creation for VAT reporting purposes and recomputed at payment time to determine FX gain/loss.
3. **Invoice-payment matching across currencies:** a payment in one currency is matched to an invoice in a different currency. The matching engine uses EUR equivalents to assess whether amounts agree within tolerance (see matching tolerance below).
4. **Ledger posting:** every `ledger_entries` row requires an `amount_eur` value. If the underlying transaction is in a non-EUR currency, `fx_rate` and `fx_rate_date` are populated and `amount_eur` is computed at posting time.

No FX conversion is applied to EUR transactions. The `fx_rate` and `fx_rate_date` columns remain NULL, and `amount_eur = amount` for EUR transactions.

## Rate Source

All FX rates are sourced from the **European Central Bank (ECB) daily reference rates**. The integration is documented in `ecb_fx_rate_cache_reference.md`. Rates are cached in `ecb_rate_schema.md`.

The ECB publishes reference rates on business days at approximately 16:00 CET. The platform fetches these rates via the ECB data API and stores them in the local rate cache. Fallback behaviour when rates are unavailable is defined in `ecb_rate_unavailable_runbook.md`.

No other rate source is permitted for statutory accounting purposes. Rates from payment processors, bank confirmation documents, or third-party feeds may be stored for informational purposes but are not used for ledger posting or tax reporting.

## Rate Date Selection

The rate date determines which ECB rate is applied to a given transaction.

**Primary rule:** use the `value_date` of the transaction (i.e. the date the funds were credited or debited, not the booking date).

**Weekend and holiday fallback:** the ECB does not publish rates on weekends or ECB target closing days. If the `value_date` falls on a non-publishing day, use the most recent prior ECB publishing day. The platform's rate cache includes a `publishing_day` flag so this lookup is a single indexed query.

```sql
SELECT rate
FROM ecb_rates
WHERE currency_code = :currency
  AND rate_date <= :value_date
  AND is_ecb_publishing_day = true
ORDER BY rate_date DESC
LIMIT 1;
```

This approach is consistent with Cyprus VAT regulations and the approach recommended in IAS 21 (Effects of Changes in Foreign Exchange Rates) for practical application.

**Invoice rate:** when an invoice is created, the ECB rate on the invoice `issue_date` is stored in `invoices.fx_rate` and `invoices.fx_rate_date`. This rate is used only for the initial EUR equivalent display on the invoice. At payment time, the rate on the payment `value_date` is used for ledger posting.

## Rounding

All FX arithmetic uses **HALF_UP rounding** to minimize systematic bias from repeated rounding.

| Step | Decimal places |
|---|---|
| Stored `fx_rate` | 8 decimal places (`DECIMAL(18,8)`) |
| Intermediate computation | Full floating-point precision |
| Stored `amount_eur` | 2 decimal places (`DECIMAL(15,2)`) |
| Rate used in matching | 4 decimal places (for display and tolerance calculation) |

The `tool_fx_convert.md` tool encapsulates all rounding logic. No calling code should perform FX arithmetic directly — all conversions must go through `tool_fx_convert`.

## FX Difference Handling

When a payment is matched to an invoice denominated in the same non-EUR currency, the EUR equivalent of the payment may differ from the EUR equivalent of the invoice due to exchange rate movement between invoice issue date and payment date. This difference is an FX gain or loss and must be posted to the ledger.

**Trigger condition:** the absolute difference between `invoice.amount_eur` and `payment.amount_eur` (both computed from ECB rates on their respective dates) is greater than €0.01.

**Action:**

1. A separate `ledger_entries` row is created for the FX difference, tagged with `description = 'FX_DIFF'`.
2. The entry is posted to the FX_GAIN or FX_LOSS account as defined in the business's chart of accounts (see `chart_of_accounts_schema.md`, account type `FX_GAIN` / `FX_LOSS`).
3. If the payment EUR amount > invoice EUR amount: post a CREDIT to `FX_GAIN`.
4. If the payment EUR amount < invoice EUR amount: post a DEBIT to `FX_LOSS`.
5. The FX_DIFF entry carries `transaction_id` and `invoice_id` so it is fully traceable.

The double-entry constraint is maintained: the total DEBITs and CREDITs across the payment entry and the FX_DIFF entry are equal.

## Multi-Currency Invoice Matching Tolerance

When the matching engine evaluates a payment against an invoice in a different currency, it converts both to EUR using the rates on their respective dates and computes the proportional difference:

```
diff_pct = abs(payment_eur - invoice_eur) / invoice_eur
```

| diff_pct | match_level |
|---|---|
| ≤ 2% | `STRONG_PROBABLE` |
| 2%–5% | `WEAK_POSSIBLE` |
| > 5% | `NO_MATCH` (unless PARTIAL_PAYMENT flag is set) |

The 2% tolerance accommodates normal exchange rate movement between invoice date and payment date. It is not a rounding tolerance — it reflects expected rate drift over typical payment terms of 30–60 days.

If the payment is in EUR and the invoice is in a non-EUR currency (or vice versa), the same tolerance rules apply after conversion.

## FX Gain/Loss Accounts

The chart of accounts for each business must include mapped accounts of type `FX_GAIN` and `FX_LOSS`. These are created automatically when a business is onboarded and its chart of accounts is initialized. The account codes follow the Cyprus chart of accounts standard:

- FX Gain: account code `7600` (Other Income — Foreign Exchange Gains)
- FX Loss: account code `8600` (Other Expenses — Foreign Exchange Losses)

If a business's chart of accounts does not include these accounts, the `tool_fx_convert.md` tool will raise a `BLOCKING` error during ledger posting and halt the run.

## Integration with tool_fx_convert

All FX conversion operations in the platform are routed through `tool_fx_convert.md`. Direct use of ECB rate data from the cache outside of this tool is not permitted in application code. The tool:

- Looks up the correct ECB rate for the given currency and value_date.
- Applies HALF_UP rounding.
- Returns `amount_eur`, `fx_rate`, `fx_rate_date`.
- Emits `FX_RATE_APPLIED` audit event (LOW).

See `tool_fx_convert.md` for full input/output specification.

## Reporting Currency

All reports generated by the platform default to EUR unless the requesting user explicitly selects an alternative display currency.

- Selecting a non-EUR display currency applies current-day ECB rates to convert ledger EUR amounts for display only. These display-converted values are not stored.
- Exported financial statements (P&L, balance sheet, VAT return) are always denominated in EUR, regardless of display currency setting.
- The Cyprus annual financial statements requirement (Companies Law Cap. 113) mandates EUR denomination.

## Cyprus Legal Requirement

Cyprus adopted the euro on 1 January 2008. All statutory financial statements, VAT returns (VAT Form 4B), and VIES filings must be denominated in EUR. This policy implements that requirement at the data layer. Any transaction that cannot be converted to EUR (e.g. because the ECB does not publish a rate for the currency) must be escalated to the accountant for manual entry. Unsupported currencies are listed in `currency_enum.md`.

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `FX_RATE_APPLIED` | LOW | Emitted by `tool_fx_convert` for each conversion. Payload: `currency`, `amount`, `fx_rate`, `fx_rate_date`, `amount_eur`. |
| `FX_DIFF_POSTED` | LOW | Emitted when an FX_DIFF adjustment entry is created in the ledger. Payload: `invoice_id`, `transaction_id`, `diff_amount_eur`, `direction` (GAIN or LOSS). |
| `FX_RATE_UNAVAILABLE` | HIGH | Emitted when the ECB rate for a required currency/date pair is not in the cache. Triggers `ecb_rate_unavailable_runbook.md`. |

## Related Documents

- `tool_fx_convert.md` — tool specification for all FX conversion calls
- `ecb_fx_rate_cache_reference.md` — ECB rate integration and cache structure
- `ecb_rate_schema.md` — DDL for cached ECB rates
- `ecb_rate_unavailable_runbook.md` — handling missing rates
- `ecb_rate_freshness_policy.md` — staleness thresholds for cached rates
- `ledger_entry_schema.md` — `fx_rate`, `fx_rate_date`, `amount_eur` columns
- `chart_of_accounts_schema.md` — FX_GAIN and FX_LOSS account types
- `matching_policy.md` — multi-currency matching tolerances in context
- `currency_enum.md` — supported and unsupported currency codes
