# fx_paired_legs_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The JSONB structure stored on `transactions.fx_paired_legs` for `transaction_type = 'FX_EXCHANGE'` rows. Per the Stage 1 decision: "FX exchange representation: one transaction with paired legs. Block 11 derives multiple ledger entries from a single FX transaction."

This sub-doc defines the JSONB shape, the multi-step FX case, the FX-rate source rules, and the ECB-fallback per Stage 1.

---

## Shape

```typescript
type FxPairedLegs = {
  rate_source: "bank" | "ecb_fallback",
  rate_recorded_at: timestamptz,
  legs: FxLeg[],                          // 2+ entries
};

type FxLeg = {
  leg_index: integer,                     // 0-based, sequential within the FX chain
  currency: string,                       // ISO 4217 — e.g., "EUR", "USD", "GBP"
  amount_signed: bigint,                  // currency-native minor units; sign convention: − = outflow leg, + = inflow leg
  exchange_rate_to_eur: numeric(15, 6),   // The rate at which this leg's amount converts to EUR
  fees_eur_cents: bigint,                 // FX fees attributable to this leg, in EUR cents
};
```

### Concrete example — Revolut USD → EUR

```json
{
  "rate_source": "bank",
  "rate_recorded_at": "2026-01-15T09:42:11Z",
  "legs": [
    {
      "leg_index": 0,
      "currency": "USD",
      "amount_signed": -10000,
      "exchange_rate_to_eur": 0.9217,
      "fees_eur_cents": 0
    },
    {
      "leg_index": 1,
      "currency": "EUR",
      "amount_signed": 9170,
      "exchange_rate_to_eur": 1.0,
      "fees_eur_cents": 47
    }
  ]
}
```

In this example: $100.00 was exchanged into €91.70 with €0.47 in fees attributable to the EUR-side leg. The bank-recorded rate (0.9217) is used per Stage 1 decision; the bank captured the rate at 09:42:11Z.

### Multi-step FX example — USD → EUR → GBP

```json
{
  "rate_source": "bank",
  "rate_recorded_at": "2026-01-15T09:42:11Z",
  "legs": [
    {
      "leg_index": 0,
      "currency": "USD",
      "amount_signed": -10000,
      "exchange_rate_to_eur": 0.9217,
      "fees_eur_cents": 0
    },
    {
      "leg_index": 1,
      "currency": "EUR",
      "amount_signed": -9170,                // outflow leg (transient)
      "exchange_rate_to_eur": 1.0,
      "fees_eur_cents": 25
    },
    {
      "leg_index": 2,
      "currency": "GBP",
      "amount_signed": 7820,
      "exchange_rate_to_eur": 1.1726,
      "fees_eur_cents": 22
    }
  ]
}
```

Each intermediate leg has both an outflow (negative `amount_signed`) and an inflow that follows it. The bank's FX product determines whether intermediate legs are visible (some banks consolidate; Revolut typically shows each step).

## Validation rules

### Rule 1: paired legs sum to zero in EUR terms (with rounding tolerance)

```
sum_over_legs(amount_signed * exchange_rate_to_eur_in_minor_units) + sum_over_legs(fees_eur_cents) ≈ 0
```

Tolerance: ± 2 cents (handles per-leg rounding). Outside tolerance: the parser flags the transaction with `intake.fx_legs_balance_drift` review issue (HIGH severity).

### Rule 2: `leg_index` is sequential and 0-based

Indices are 0, 1, 2, … No gaps. The order represents the temporal sequence of the FX chain.

### Rule 3: at least one leg in `EUR` for transactions involving EUR

The Cyprus business reports books in EUR; an FX chain that never touches EUR is unusual (and possibly an INTERNAL_TRANSFER misclassified as FX_EXCHANGE). Parser flags this case for review.

### Rule 4: `rate_source = ecb_fallback` only when the bank rate was unrecoverable

Per Stage 1: "Bank-recorded rate from the FX leg (Revolut's own rate). ECB daily rate as fallback when the bank rate is missing."

ECB fallback uses the daily ECB EUR reference rate for the leg's date. The integration is `fx_conversion_source_integration` (Integrations, Block 11).

### Rule 5: `exchange_rate_to_eur > 0`

Negative or zero rates are invalid. Parser rejects.

## Storage

Stored on `transactions.fx_paired_legs` (JSONB). The column is `NOT NULL` only when `transaction_type = 'FX_EXCHANGE'`:

```sql
CHECK (transaction_type != 'FX_EXCHANGE' OR fx_paired_legs IS NOT NULL)
```

per `transactions_schema`.

The JSONB serialization uses canonical JSON per `data_layer_conventions_policy` — keys sorted lexically, no insignificant whitespace, deterministic.

## Ledger derivation

Block 11 Phase 07's `prepareFxExchangeEntry` produces multiple ledger entries from one FX transaction:

- For each leg with `amount_signed != 0`: a paired DR/CR entry against the account currency and the EUR equivalent
- For total fees: a separate "FX fees" ledger entry (mapped to the Bank Fees account in `cyprus_default_chart_catalog`)
- For FX gain/loss: a derived entry per `vat_rate_table_cyprus` shape (zero VAT)

Per Block 11 Phase 07: FX_DELTA derived entries carry zero VAT amounts; the PRIMARY-side row carries any actual figures. The dispatcher reads `fx_paired_legs` to compute these.

## Currency comparison consumer

Per `currency_comparison_reference_policy` (Block 10): matching engine compares cross-currency amounts in always-EUR. The matching engine reads `transactions.amount_eur_cents` (the projection); FX-rate accuracy depends on this schema's `exchange_rate_to_eur` values.

When `amount_eur_cents` is recomputed (e.g., during adjustment re-runs), the canonical projection function reads `fx_paired_legs` and applies `exchange_rate_to_eur` per leg.

## Indexes

`fx_paired_legs` is JSONB; no traditional B-tree index. Block 11 Phase 07's queries traverse it row-at-a-time. The set of FX_EXCHANGE transactions is small (typically < 5% of total volume); no GIN index needed in MVP.

If FX volume grows, a partial GIN index on `fx_paired_legs` is the Stage 2+ option.

## Cross-references

- `transactions_schema` — host table; column constraint
- `transaction_type_enum` — `FX_EXCHANGE` definition
- `data_layer_conventions_policy` — canonical JSON for the JSONB
- `currency_comparison_reference_policy` — always-EUR comparison consumer
- `fx_conversion_source_integration` — ECB fallback integration
- `vat_rate_table_cyprus` — zero-VAT derived entries
- `cyprus_default_chart_catalog` — FX-fee account mapping
- Block 04 Phase 02 — bank statement & transaction schema (architecture)
- Block 07 Phase 04 — row normalization (parses FX legs from bank statements)
- Block 11 Phase 07 — type-aware ledger preparation paths (consumer)
- Stage 1 decision — "One transaction with paired legs"
