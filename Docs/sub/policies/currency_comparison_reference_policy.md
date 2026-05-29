# currency_comparison_reference_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Co-owner:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

The matching engine, split-payment detection, dedup fingerprints, and ledger balance comparisons all need a single answer to one question: **in which currency space do we compare amounts?** This policy commits to **always-EUR comparison** as the canonical rule, defines where the EUR-normalised values come from, what reproducibility columns are persisted, and how the matching pipeline behaves when the EUR-normalisation is missing.

Cross-referenced from `match_signal_weights.md`, `fx_conversion_source_integration.md`, and others as `currency_comparison_reference_policy`. This is the canonical home; prior references that previously inlined the rule are now superseded.

---

## 1. The rule

**All amount comparisons are performed in EUR minor units.**

Both sides of any comparison — `transaction.amount` vs `document.total_amount`, `match_score.amount_signal` per `match_scoring_calibration_policy.md`, split-payment-group `total_member_amount` vs parent invoice amount, dedup fingerprint amount component — are normalised to EUR minor units (`bigint`, integer cents) **before** any equality, tolerance, or sum operation is evaluated. Raw foreign-currency values are never directly compared.

This applies regardless of:

- Whether the transaction is in EUR or a foreign currency.
- Whether the document is in EUR or a foreign currency.
- Whether the transaction and document share a non-EUR currency (e.g., both USD).
- Whether the transaction is a multi-leg FX pair (e.g., Revolut card payment with EUR-side and merchant-side legs).

EUR is always the comparison denominator. No alternative is exposed via configuration.

---

## 2. Rationale

Three reasons, in priority order:

1. **Accounting truth.** Cyprus statutory ledgers are EUR-denominated (per `data_layer_conventions_policy.md` and the Stage-1 decision that Cyprus VAT + accountant pack are EUR-native). Matching decisions feed the ledger; they must operate in the ledger's currency space.
2. **Determinism.** Comparing in transaction-currency means a USD invoice scored against a EUR transaction would need direction-aware conversion logic per comparison. Two conversions per pair (one to convert the foreign side, again on the inverse direction for reverse pairs) introduces rounding inconsistencies that defeat the bit-exactness guarantee in `tool_matching_score_pair.md` §8. Always-EUR uses one conversion per side, computed once at intake, never recomputed at comparison time.
3. **Reproducibility.** The per-leg FX rates are the explicit reproducibility artefact (stored on `transactions.fx_paired_legs` + match-record FX columns per §4). EUR-normalised values are the canonical form; the rate columns let us reconstruct foreign-side amounts post-hoc when needed (e.g., for accountant explanation in the review queue).

---

## 3. EUR-normalisation source

The matching engine reads pre-computed EUR-normalised values from the source rows; it does NOT compute conversions at match time.

| Side | Column | Type | Populated by |
|---|---|---|---|
| Transaction | `transactions.amount_eur_minor` | `bigint` (EUR minor units, signed: OUT negative / IN positive per `transactions_amount_direction_chk`) | Bank-statement parser at intake; uses `ecb_fx_rate_cache_reference.md` rates |
| Document | `documents.total_amount_eur_minor` | `bigint` (EUR minor units, unsigned magnitude) | Document-extraction pipeline (Block 09) at extract time; invoice generator (Block 13) at issue time |

Both columns are NOT NULL when their parent row reaches the matching phase. Rows where the value could not be computed at intake are gated upstream (per §10).

The `amount` field on the underlying source row (transaction or document) retains the original-currency value alongside `currency` (ISO-4217 code) for display, dispute resolution, and forensics — those columns are NOT consumed by the matching engine.

---

## 4. Reproducibility columns on `match_records`

Every `match_records` row stores the FX state used at the moment of scoring:

| Column | Type | Semantics |
|---|---|---|
| `fx_rate_transaction_side` | `numeric(18,8)` | ECB rate (units of foreign per 1 EUR) used to convert the transaction. `1.00000000` when the transaction is EUR-native. |
| `fx_rate_document_side` | `numeric(18,8)` | ECB rate used to convert the document. `1.00000000` when the document is EUR-native. |
| `ecb_rate_date_used` | `date` | The `ecb_fx_rates.rate_date` row from which the rates above were sourced. `NULL` when both sides are EUR-native (no rate was consulted). |
| `original_currency_transaction` | `char(3)` | The transaction's source ISO-4217 currency code. |
| `original_currency_document` | `char(3)` | The document's source ISO-4217 currency code. |

Persisting both raw rate values + the rate-date means any future audit can answer "what amount was matched against what amount, in which currency space, using which rate, on which date" without re-querying the ECB cache. The cache itself is immutable (per `ecb_fx_rate_cache_reference.md`), so the answer is stable.

When both sides are EUR-native, all four FX columns can be either filled with their identity values or left as defaults — implementation must NOT NULL-out and re-NULL in a single update; pick one shape at insert and stick to it. The recommended shape: leave `ecb_rate_date_used = NULL` and set both `fx_rate_*` to `1.0`.

---

## 5. Cross-currency pairs

A transaction in currency A and a document in currency B (where A ≠ B and at least one is not EUR) is compared by:

1. Reading `transactions.amount_eur_minor` (already EUR-normalised at intake using rate-A's EUR conversion).
2. Reading `documents.total_amount_eur_minor` (already EUR-normalised at extraction).
3. Comparing the two EUR values directly.

There is **no intermediate conversion to "the other side's currency"**. EUR is the shared denominator regardless of how exotic the pair (e.g., a JPY transaction matched against a GBP invoice still resolves through EUR).

The `ecb_rate_date_used` on `match_records` will reference the date used to source rate-A's conversion at the transaction's intake; the document side's rate-date may differ. The two are recorded independently per §4; only the more-recent of the two is stored in `ecb_rate_date_used` (chosen because that's the date relevant to the *match decision*, not to any single side's normalisation). Implementation must take `GREATEST(transaction_intake_date, document_intake_date)`.

---

## 6. fx_paired_legs reference

For multi-leg FX transactions (Revolut card payments, multi-currency Wise transfers, etc.), the `transactions.fx_paired_legs` jsonb column records the per-leg conversion. Schema lives in `fx_paired_legs_schema.md`.

The matching engine consumes **only** the EUR-side leg's value via `amount_eur_minor`. The foreign-side leg is informational (for display and dispute resolution) and is NOT used as a comparison input. This avoids ambiguity when the same transaction has multiple foreign-currency representations.

When a Revolut transaction is `payer-EUR / merchant-USD`, `amount_eur_minor` is the payer-side EUR value (what was debited from the user's EUR balance); the merchant-side USD value is on `fx_paired_legs` for transparency. The match runs against the payer-side EUR value.

---

## 7. Tolerance rules

Per `match_scoring_calibration_policy.md` (and reconciliation-pending per BOOK-170 / BOOK-174 drift), amount-similarity tolerance bands are evaluated in **EUR space**:

- "Amount within ±0.01" means `|txn_eur_minor - doc_eur_minor| ≤ 1` (one cent) **in EUR**.
- "Amount within ±2%" means `|txn_eur_minor - doc_eur_minor| ≤ 0.02 × doc_eur_minor` **in EUR**.
- Same for the ±5% / ±10% bands.

A 100.00-USD invoice (EUR-normalised at intake to, e.g., 92,000 minor units) compared to a 92.50-EUR transaction (9,250 minor units) is **not** a hit on the ±0.01 band — the comparison is `|9250 - 92000| = 82750`, far outside any tolerance. This is correct: the user paid 92.50 EUR, the invoice was for ~920 EUR equivalent — those are different amounts in any sensible model. The original-currency illusion (`92.50` vs `100.00` looks "close") is rejected by always-EUR comparison.

Edge: the example above also illustrates why decimal-place alignment between EUR and non-EUR is critical. The bank-statement parser must persist `amount_eur_minor` in EUR cents (×100 of the EUR value), not in foreign-currency minor units. The transaction's `currency` and `amount` columns hold the foreign-original form; `amount_eur_minor` is always in EUR cents.

---

## 8. Determinism guarantee

`transactions.amount_eur_minor` is **frozen at intake time** using the ECB rate available at intake. It is never recomputed against newer ECB rates. This ensures:

- A match scored today and re-scored next month produces the same `composite_score` (subject to the same scoring config).
- An archive bundle's contents (per Block 15) are stable indefinitely — the EUR-normalised values that feed ledger balances do not drift as rates update.
- Recalibration (per `match_scoring_calibration_policy.md` §"Recalibration") re-scores using the same EUR values; it does NOT re-normalise FX.

The only path that re-normalises FX is an explicit adjustment-run flow (Block 12 IN / Block 13 OUT adjustment paths) where the new EUR value is written as a *new* row (not an UPDATE of an existing row) and a `FX_NORMALISATION_ADJUSTED` audit fires. The original row's `amount_eur_minor` remains unchanged for the historical record.

---

## 9. Same-currency optimisation

When both sides are EUR-native (the common case for Cyprus-domestic accounts):

- No FX rate lookup.
- No `ecb_fx_rates` table query.
- `amount_eur_minor` is just `amount * 100` (the parser's standard cents conversion).
- Per-pair fuzzy-amount-match cost stays at <1 ms per `tool_matching_score_pair.md` §10.

The implementation should NOT call `ledger.fetch_ecb_rate` for EUR-native rows. A guard on `currency = 'EUR'` short-circuits the FX path. This is enforced by the bank-statement parser; the matching engine consumes `amount_eur_minor` regardless of how it was populated.

---

## 10. Edge case: EUR-normalisation missing at match time

If a `transaction` or `document` reaches the matching phase with `amount_eur_minor IS NULL`, the candidate pair is **excluded** from the scoring loop. A review issue is raised:

| Event | Severity | Trigger |
|---|---|---|
| `MATCHING_AMOUNT_EUR_MISSING` | MEDIUM | `transactions.amount_eur_minor IS NULL` OR `documents.total_amount_eur_minor IS NULL` for any pair entering the candidate set |

The review-queue issue payload: `{ transaction_id, document_id, side_missing: 'transaction' | 'document' | 'both', currency_observed, business_id }`.

This is **distinct** from `LEDGER_CURRENCY_UNSUPPORTED` (per `ecb_fx_rate_cache_reference.md` §"Currency coverage"). The relationship:

- `LEDGER_CURRENCY_UNSUPPORTED` fires at intake / ledger preparation when no ECB rate (and no MANUAL_OVERRIDE) exists. It **blocks ledger entry** and is the upstream cause of an unpopulated `amount_eur_minor`.
- `MATCHING_AMOUNT_EUR_MISSING` fires downstream at match time when the EUR value is still missing. It **blocks matching** for that pair only; the broader workflow continues.

The two events should never fire in parallel for the same row — the ledger-side block prevents the row from reaching the matching phase in healthy operation. If both fire, that indicates the upstream gate leaked; flag for ops investigation.

---

## 11. Audit semantics

No per-comparison audit event. The FX state is captured on the `match_records` row itself (§4 columns) — every match record carries its own complete FX provenance. The audit chain captures match records via `MATCHING_PAIR_SCORED` (per `tool_matching_score_pair.md` §7).

`MATCHING_AMOUNT_EUR_MISSING` (MEDIUM) emits only when §10's missing-value path fires.

`FX_NORMALISATION_ADJUSTED` (HIGH) emits during an adjustment-run flow per §8.

None of these audit payloads carry the foreign-currency amount or the rate value — those are recoverable via the persisted match_records row and the immutable `ecb_fx_rates` cache.

---

## 12. Mobile

Read-only on mobile. The match records (with FX state) are readable; no mobile surface can trigger re-normalisation (re-normalisation is a write operation gated by `mobile_write_rejection_endpoints.md`).

---

## 13. Cross-references

- `data_layer_conventions_policy.md §3` — integer minor units, no floats for currency
- `ecb_fx_rate_cache_reference.md` — rate source for intake-time EUR normalisation
- `fx_conversion_source_integration.md` — integration contract that consumed this rule inline; now points back to this canonical policy
- `fx_paired_legs_schema.md` — per-leg conversion artefact schema; matching engine consumes only the EUR-side leg
- `match_signal_weights.md` — amount-signal scoring; tolerance bands operate in EUR
- `match_scoring_calibration_policy.md` — composite scoring; threshold bands operate in EUR
- `match_scoring_weights_policy.md` — alternate weight doc (subject to BOOK-170 reconciliation); FX rule applies identically
- `transactions_schema.md` — `amount_eur_minor bigint NOT NULL` column
- `documents_schema.md` — `total_amount_eur_minor bigint NOT NULL` column
- `match_records_schema.md` — FX reproducibility columns (`fx_rate_transaction_side`, `fx_rate_document_side`, `ecb_rate_date_used`, `original_currency_transaction`, `original_currency_document`)
- `audit_event_taxonomy.md` — `MATCHING_PAIR_SCORED`, `MATCHING_AMOUNT_EUR_MISSING`, `FX_NORMALISATION_ADJUSTED`
- `mobile_write_rejection_endpoints.md` — re-normalisation write rejection
- Block 10 Phase 02 — matching engine consumer
- Block 11 Phase 07 — ledger preparation upstream
- Block 11 Phase 08 — ECB cache populator
- Block 12 — OUT adjustment-run flow (one of the two re-normalisation paths)
- Block 13 — IN adjustment-run flow (the other re-normalisation path)
- Stage 1 decision — EUR statutory currency for Cyprus VAT and accountant pack
