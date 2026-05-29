# partial_payment_minimum_threshold_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Co-owner:** 13 — IN Workflow · **Stage:** 4 sub-doc (Layer 2)

The threshold rule that distinguishes a **legitimate partial payment** of an invoice from **payment noise** that should NOT be matched. Per Block 10 Phase 08 Deliverables → `PARTIAL_PAYMENT` outcome: the engine treats an incoming amount as a partial payment of an invoice if `amount ≥ 5% of invoice total`. Amounts below this floor are NOT routed to `PARTIAL_PAYMENT`.

This doc operationalises the 5% rule with edge-case behaviour and the configurability contract.

---

## 1. The 5% rule

```
PARTIAL_PAYMENT eligibility:
  amount_eur >= 0.05 * invoice_total_eur
  AND amount_eur < invoice_total_eur  (otherwise it would be FULL_MATCH or OVERPAYMENT)
```

The threshold is **5% of the invoice's total in EUR** (per `currency_comparison_reference_policy.md` always-EUR rule — both sides converted at frozen-at-intake FX). The default is `0.05` (5 percent) as a hard floor configurable per-business per §6.

A transaction whose `amount_eur < 0.05 * invoice_total_eur` against the invoice is treated as **not a partial payment of this invoice**. It may still score as `POSSIBLE_REFUND_OR_TRANSFER` against a prior outgoing, or fall to `NO_MATCH` if no other candidate exists.

---

## 2. Why 5%

Three rationales (in priority order):

1. **Noise filter.** Tiny incoming amounts (a few euros against a multi-hundred-euro invoice) are usually NOT partial payments. They're typically:
   - Refunds of overpaid fees
   - Bank transfer reconciliation correction entries
   - Test transactions from a customer verifying the receiving account
   - Unrelated micro-payments from a customer with the same name

2. **User-experience floor.** A reviewer who sees "Partial payment of €2 against invoice €100" is overwhelmingly likely to reject the match. Suggesting it consumes attention without yielding correct allocations.

3. **Allocation hygiene.** If an invoice's `PARTIAL_PAYMENT` running total accumulates many ≤ 5%-of-total chunks, the bookkeeping log becomes noisy with sub-resolution payment events. The 5% floor keeps the running-total trail meaningful.

The 5% value itself is calibrated against the Cyprus SME book of typical invoice sizes (median €450) and typical bank-noise patterns. A 5% floor of a €450 invoice is €22.50 — a non-trivial amount that's unlikely to be noise.

---

## 3. Edge cases

### 3.1 Very small invoices

For an invoice with `total = €10`, the 5% floor is €0.50. A €0.45 incoming transaction is **below threshold** even though absolutely it's nearly the full invoice value.

**Behaviour:** the absolute amount is irrelevant; the rule is purely fractional. A €0.45 transaction against a €10 invoice scores `NO_MATCH` against this invoice (or `POSSIBLE_REFUND_OR_TRANSFER` if it matches a prior outgoing).

**Why this is correct:** very small invoices are uncommon (median Cyprus SME invoice is ~€450). For the cases that exist, an under-5% payment is unlikely to be a legitimate partial — bank fees, small refunds, etc. are far more common origins. The 5% rule is preserved.

### 3.2 Very large invoices

For an invoice with `total = €50,000`, the 5% floor is €2,500. A €2,000 incoming transaction is **below threshold**.

**Behaviour:** scores `NO_MATCH` against this invoice. If the customer is paying in tranches (€2k incoming each month against a €50k invoice), the smaller-tranche pattern needs **per-business override** per §6 — typical default is to lower the threshold for the businesses doing milestone billing.

The per-business override is configured against the **per-invoice** floor, not a global one — so a business with mixed small + large invoices can lower the floor without affecting the small-invoice noise filter.

### 3.3 Currency mismatch (cross-currency)

The 5% check uses **EUR-converted amounts** on both sides:

```
amount_eur = transaction.amount_eur_minor
invoice_total_eur = invoice.total_eur_minor  (frozen at issue per currency_comparison_reference_policy)
```

A USD transaction of $100 against a €5,000 EUR invoice is converted to EUR at the transaction's `fx_rate_transaction_side` per `match_records` reproducibility FX columns. If the EUR-equivalent is ≥ €250, eligible; if not, ineligible.

This means a USD transaction's eligibility can shift if the FX rate moves significantly between transaction-date and invoice-date. The FX rate used is the **transaction-side** frozen rate, not the invoice-side rate. This is consistent with the "amount at the moment of payment" semantic.

### 3.4 Rounding effects

The threshold check is on integer minor units (cents). `0.05 * invoice_total_eur_minor` is computed in PostgreSQL `numeric` arithmetic and rounded HALF_UP at the last cent. Examples:

| Invoice total | 5% floor (cents) | 5% floor (EUR display) |
|---|---|---|
| €100.00 (10000 minor) | 500 cents | €5.00 |
| €100.50 (10050 minor) | 503 cents (half-up from 502.5) | €5.03 |
| €99.99 (9999 minor) | 500 cents (half-up from 499.95) | €5.00 |

The HALF_UP rounding direction is consistent with Cyprus VAT computation per `cyprus_vat_rules.md` (which uses the same rule).

### 3.5 Zero-amount invoice

An invoice with `total_eur_minor = 0` is degenerate. The threshold becomes 0, so any positive amount technically qualifies. But:

**Behaviour:** invoice records with `total = 0` should never be created via the normal path. If one exists (testing artefact, data import bug), it's filtered out of the IN-side candidate set at the candidate-narrowing step, BEFORE any scoring runs. No `PARTIAL_PAYMENT` outcome is produced.

**Cross-block coordination flagged for B13 invoice generator:** confirm `invoices.total_eur_minor > 0` CHECK constraint at table level. If absent, add it per Stage-6 schema-hardening pass.

### 3.6 Negative amount transaction

An incoming transaction with `amount_eur_minor < 0` is technically a refund / reversal. The candidate-narrowing step at the IN-matching engine excludes negative-amount transactions from IN_INCOME matching entirely — they're routed to `POSSIBLE_REFUND_OR_TRANSFER` per Block 10 Phase 08 §POSSIBLE_REFUND_OR_TRANSFER (and BOOK-225 refund detection rule).

So the 5% check never sees a negative amount on the IN-side.

---

## 4. Below-threshold behaviour

A transaction that fails the 5% check against invoice X is not silently dropped. Three downstream paths:

| Condition | Outcome |
|---|---|
| Transaction has no other candidate invoice above any threshold | `NO_MATCH` |
| Transaction matches a prior OUT-side outgoing transaction (refund signal) | `POSSIBLE_REFUND_OR_TRANSFER` per BOOK-225 |
| Transaction matches another invoice above 5% threshold | Falls through to that invoice's outcome (`FULL_MATCH` / `PARTIAL_PAYMENT` / `OVERPAYMENT`) |

In all three paths, the failed-against-invoice-X check is NOT separately audited (the engine doesn't emit a "below threshold against invoice X" event for every below-threshold candidate it considers). Only the final outcome is audited per `audit_event_taxonomy.md` IN_INCOME outcome events.

---

## 5. Audit shape

When the 5% rule causes a transaction to be excluded from `PARTIAL_PAYMENT` and the final outcome is `NO_MATCH`, the audit payload carries a `below_partial_threshold_count` field counting how many invoices the transaction WOULD have matched against if the threshold were 0%:

```jsonc
{
  "transaction_id":              "uuid",
  "outcome":                     "NO_MATCH",
  "candidates_evaluated":        12,
  "candidates_above_threshold":  0,
  "below_partial_threshold_count": 3,    // 3 invoices the transaction was below 5% against
  "weighting_profile":           "IN_INCOME"
}
```

The `below_partial_threshold_count` is a forensic signal — if it's consistently non-zero for a business, the threshold may be miscalibrated for that business and the per-business override (§6) should be considered.

---

## 6. Configurability — per-business override (Stage 2+)

The 5% default can be overridden per business via `business_settings.matching.partial_payment_threshold_pct`:

```sql
ALTER TABLE business_settings
  ADD COLUMN matching_partial_payment_threshold_pct numeric(4,3) NOT NULL DEFAULT 0.050
  CHECK (matching_partial_payment_threshold_pct BETWEEN 0.000 AND 0.500);
```

Bounds: 0% (allow any partial — high noise) to 50% (only large partials count — low noise but may miss legitimate small partials). The default 5% is the conservative middle ground.

Override changes are:
- Audit-logged via `MATCHING_PARTIAL_THRESHOLD_CHANGED` (MEDIUM) — emit a row with `prior_pct`, `new_pct`, `actor_user_id`.
- Apply to FUTURE matching runs only. In-flight match records keep the threshold they were scored against (per `principal_context_snapshot_json` per-run authority — same pattern as role-change propagation).
- Step-up required per `permission_matrix.md` — `MATCHING_SETTINGS_EDIT` surface.

**Cross-block coordination flagged for B02·P11 settings UI:** the matching-settings section needs a control for `partial_payment_threshold_pct` with the [0%, 50%] slider + audit-event preview.

---

## 7. Cross-references

- `match_signal_weights.md` — OUT-side weight baseline
- `income_matching_signal_weighting.md` — IN-side weight variant (BOOK-218 sibling)
- `currency_comparison_reference_policy.md` — always-EUR comparison + frozen-at-intake FX
- `match_record_schema.md` — `match_records` candidate-narrowing step (where threshold is enforced)
- `cyprus_vat_rules.md` — HALF_UP rounding rule (consistent with §3.4)
- `audit_event_taxonomy.md` — `MATCHING_PARTIAL_THRESHOLD_CHANGED` (NEW; cross-block flagged for B05·P02)
- `audit_event_payload_schemas.md` — payload shape for `NO_MATCH` outcome carrying `below_partial_threshold_count` (NEW field)
- `permission_matrix.md` — `MATCHING_SETTINGS_EDIT` surface (Owner / Admin per §6 override)
- `role_change_propagation_policy.md` — per-run authority snapshot (consumed at §6 in-flight-run rule)
- `settings_page_ui_spec.md` — settings UI consumer of §6 override control
- Block 10 Phase 04 — split-payment combinatorial (handles the alternative path when below-threshold leads to multi-invoice allocation)
- Block 10 Phase 08 — income matching variant (owning phase; the 5% rule lives here)
- Block 13 — invoice generator (consumer; receives `PARTIAL_PAYMENT` outcomes filtered by this rule)
- Stage 1 decision — 5% partial-payment floor (binding to §1 default)
