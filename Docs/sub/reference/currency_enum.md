# Currency Enum

**Block:** 11 — FX & Currency  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines the supported currencies in the platform, the `currency_code_enum` type, the `MoneyAmount` composite type, the European Central Bank (ECB) as the reference rate source, cross-rate triangulation rules, rounding conventions, and handling of currencies not in the enum (including sanctions-risk currencies). Cyprus uses EUR as its primary and only legal tender; all other currencies are handled as foreign currencies requiring explicit conversion.

---

## 1. Primary Currency

The platform's primary currency is **EUR (Euro)**. All internal financial calculations, ledger postings, VAT entries, and reporting are denominated in EUR unless an explicit foreign currency is recorded on the source transaction. The Cyprus Republic adopted the Euro on 1 January 2008, replacing the Cyprus pound (CYP).

EUR is not subject to FX conversion or rate lookup. EUR amounts are stored as-is. All exchange rate calculations use EUR as the pivot currency.

---

## 2. Supported Currencies — Enum Definition

```sql
CREATE TYPE currency_code_enum AS ENUM (
    'EUR',   -- Euro (primary; Cyprus legal tender)
    'USD',   -- US Dollar
    'GBP',   -- British Pound Sterling
    'CHF',   -- Swiss Franc
    'AED',   -- UAE Dirham
    'SGD',   -- Singapore Dollar
    'AUD',   -- Australian Dollar
    'CAD'    -- Canadian Dollar
);
```

These eight currencies cover the majority of foreign-currency transactions encountered by Cyprus-based businesses, including transactions with UK counterparties (GBP), US dollar invoices (USD), Swiss-based structures (CHF), Gulf-region counterparties (AED), and Singapore/APAC exposure (SGD, AUD).

**RUB (Russian Ruble) is excluded from the enum.** See Section 6 for sanctions-risk currency handling.

---

## 3. Currency Code Allowlist Rationale

Currencies were selected based on:

1. Frequency in Cyprus business transactions (EUR, USD, GBP dominate).
2. Active ECB reference rate publication (all listed currencies have ECB daily rates).
3. Absence of active EU financial sanctions at time of definition (RUB excluded).
4. Business demand from the Cyprus offshore and holding company sector (AED, SGD).

Adding a new currency to the enum requires:
1. Confirmation that ECB publishes daily reference rates for the currency.
2. Sanctions screening clearance.
3. A database migration appending the value to the enum.
4. An amendment to this document and to `ecb_fx_rate_cache_reference.md`.

---

## 4. ECB as Reference Rate Source

The European Central Bank (ECB) publishes official reference exchange rates daily at approximately 16:00 CET on each TARGET business day. These rates represent the mid-market rate against EUR.

The ECB reference rate is the authoritative source for all FX conversions on this platform. No other rate source is used for financial record conversions. Use of the ECB rate satisfies Cyprus tax authority requirements for converting foreign currency transactions to EUR for reporting purposes.

Rate freshness policy is defined in `ecb_rate_freshness_policy.md`. Key constraints:
- Rates are considered fresh for up to 3 business days from publication date.
- If the most recent available rate is older than 3 business days (e.g., due to a long public holiday), the conversion is flagged with `rate_staleness = STALE` and routed to the review queue.
- Weekend and public holiday dates use the most recent prior business day's rate.

Rate storage: rates are cached in the `ecb_rates` table (defined in `ecb_rate_schema.md`). The cache is populated by the `fx_conversion_source_integration` scheduled job.

---

## 5. EUR Pivot Cross-Rate Calculation

The ECB publishes rates as units of foreign currency per 1 EUR (EUR/XXX format). All cross-rates between two non-EUR currencies are calculated via EUR as the triangulation pivot.

### 5.1 Direct Conversion (Foreign → EUR)

```
eur_amount = foreign_amount / ecb_rate(currency)
```

Where `ecb_rate(currency)` is the ECB published rate for `currency` against EUR on the transaction date (units of `currency` per 1 EUR).

Example: USD/EUR rate = 1.0850 (1 EUR = 1.0850 USD)
- $108.50 USD → 108.50 / 1.0850 = €100.00 EUR

### 5.2 Inverse Conversion (EUR → Foreign)

```
foreign_amount = eur_amount * ecb_rate(currency)
```

### 5.3 Cross-Rate Triangulation (Foreign A → Foreign B)

No direct A→B conversion is performed. All non-EUR pairs are converted through EUR:

```
amount_in_B = (amount_in_A / ecb_rate(A)) * ecb_rate(B)
```

This is the tri-triangulation rule: two ECB lookups are required for any non-EUR cross-rate. The intermediate EUR amount is computed to full DECIMAL(18,4) precision before the second conversion. Rounding is applied only at the final output step (see Section 7).

Example: 1000 AED to GBP, with ECB rates AED=3.9250, GBP=0.8602:
```
eur_intermediate = 1000 / 3.9250 = 254.7771... EUR
gbp_result = 254.7771... * 0.8602 = 219.08... GBP → rounded to 219.08 GBP
```

---

## 6. Sanctions-Risk Currencies — RUB Handling

The Russian Ruble (RUB) is not included in `currency_code_enum` due to active EU financial sanctions (EU Council Regulation 833/2014 and related regulations) which restrict financial transactions with Russian counterparties.

If a transaction is encountered with `currency = 'RUB'`:

1. The currency is stored as a `TEXT` value in the `raw_currency` column on the `transactions` table (not cast to `currency_code_enum`).
2. The transaction is automatically placed in `REVIEW_HOLD` with a `SANCTIONS_SCREENING_REQUIRED` review issue of severity BLOCKING.
3. No FX conversion is performed until the review issue is resolved by a qualified operator.
4. The sanctions screening result must be documented in the review issue resolution notes before the transaction may be processed further.

Other currencies not in the enum (e.g., JPY, CNY, INR) are treated as unknown foreign currencies: stored as TEXT, flagged in the review queue with a `UNKNOWN_CURRENCY` issue of severity MEDIUM. Unknown currencies without sanctions risk may be added to the enum via the process described in Section 3.

---

## 7. `MoneyAmount` Composite Type

Financial amounts throughout the platform use the `MoneyAmount` composite type:

```sql
CREATE TYPE money_amount AS (
    amount   DECIMAL(18,4),
    currency currency_code_enum
);
```

The `DECIMAL(18,4)` precision allows up to 14 digits before the decimal point and 4 digits after. This accommodates:
- Very large transaction values (up to 99,999,999,999,999.9999 in any currency).
- Sub-cent precision required for VAT calculations and FX conversions.

Where a foreign currency amount cannot be represented as `currency_code_enum` (RUB or other unknown currency), the composite type is not used. Instead, a separate `(raw_amount DECIMAL(18,4), raw_currency TEXT)` pair is stored on the transaction row alongside a null `money_amount` value.

---

## 8. Rounding Rules

The platform applies **HALF_UP rounding** (also known as round-half-away-from-zero) for all currency arithmetic. This is the rounding mode required by the Cyprus VAT Act and is mandated in `ledger_rounding_policy.md`.

Rounding precision:

| Context | Precision | Rounding Mode |
|---------|-----------|---------------|
| Storage (all amounts) | 4 decimal places | HALF_UP |
| VAT calculation output | 2 decimal places | HALF_UP |
| Invoice line item amounts | 2 decimal places | HALF_UP |
| Invoice totals | 2 decimal places | HALF_UP |
| FX conversion intermediate | 4 decimal places (not rounded mid-calculation) | — |
| FX conversion final output | 2 decimal places | HALF_UP |
| Ledger entry amounts | 4 decimal places | HALF_UP |

HALF_UP rounding rule: if the digit to be dropped is exactly 5 (with no following non-zero digits), always round up (away from zero). Example: 2.5 → 3, 3.5 → 4, 2.45 → 2.5, 2.55 → 2.6.

In PostgreSQL, HALF_UP rounding for `DECIMAL`/`NUMERIC` types requires explicit use of `ROUND(value::numeric, n)` with cast to numeric; verify no intermediate float casts are applied.

---

## 9. Currency Validation at Intake

During the INTAKE phase, the `intake.validate_file_format` tool checks the currency code on each parsed transaction:

| Scenario | Action |
|----------|--------|
| Currency matches `currency_code_enum` | Processed normally |
| Currency is `RUB` | `raw_currency = 'RUB'`, `REVIEW_HOLD`, BLOCKING issue |
| Currency is unknown (not in enum, not RUB) | `raw_currency = <value>`, MEDIUM review issue |
| Currency field is absent or null | Defaults to business `default_currency` from `business_settings` |
| Currency field is malformed (not 3 chars, not alphabetic) | INTAKE parse error for the specific row |

Transactions with an unknown currency do not block the rest of the run. The INTAKE phase gate (`engine.gate_intake_complete`) does not fail due to unknown currencies; it routes them to the review queue.

---

## 10. Integration with `tool_fx_convert`

The `tool_fx_convert` tool is the sole mechanism for performing FX conversions on the platform. It:

1. Looks up the ECB rate for the source currency on the transaction date from the `ecb_rates` cache.
2. Applies the EUR pivot calculation (Section 5).
3. Returns a `money_amount` in EUR.
4. Records the rate used (`ecb_rate_id`, `rate_date`, `rate_value`) on the calling transaction or ledger entry row for audit trail purposes.

`tool_fx_convert` rejects conversions where:
- The rate is absent from the cache (rate fetch from ECB failed and cache miss).
- The rate is STALE per `ecb_rate_freshness_policy.md` and the caller did not explicitly pass `allow_stale = true`.
- The source currency is `RUB` or any other sanctions-flagged currency.

---

## 11. Integration with `ecb_rate_freshness_policy`

See `ecb_rate_freshness_policy.md` for the full definition of rate freshness thresholds, cache warm-up schedules, stale rate escalation, and the handling of ECB publication delays.

Key interaction: if `tool_fx_convert` is called during the LEDGER_POST phase for a run and the rate is stale, the phase gate `engine.gate_ledger_balanced` will not pass for the affected transactions. They are routed to `REVIEW_HOLD` with a `STALE_FX_RATE` review issue.

---

## 12. Display and Formatting

Currency formatting for UI display and PDF output follows ISO 4217 symbol conventions:

| Currency | Symbol | Decimal Separator | Thousands Separator |
|----------|--------|------------------|-------------------|
| EUR | € | . | , |
| USD | $ | . | , |
| GBP | £ | . | , |
| CHF | CHF | . | ' |
| AED | AED | . | , |
| SGD | S$ | . | , |
| AUD | A$ | . | , |
| CAD | C$ | . | , |

All display formatting is applied by the frontend layer and PDF generation layer. The database stores numeric values only, without formatting characters.

---

## Related Documents

- `policies/ecb_rate_freshness_policy.md`
- `reference/ecb_fx_rate_cache_reference.md`
- `schemas/ecb_rate_schema.md`
- `schemas/fx_paired_legs_schema.md`
- `schemas/vat_entry_schema.md`
- `schemas/ledger_entry_schema.md`
- `schemas/business_settings_schema.md`
- `integrations/fx_conversion_source_integration.md`
