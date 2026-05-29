# Tool: matching.score_pair

**Category:** Tools · Block 10 — Matching  
**Tool name:** `matching.score_pair`  
**Owner:** matching  
**Last updated:** 2026-05-17  
**WRITES_AUDIT:** Yes — emits `MATCHING_PAIR_SCORED`

---

## 1. Purpose

`matching.score_pair` computes a composite match score and match level for a single transaction–invoice pair. It is the atomic scoring primitive used by `matching.propose` to evaluate all candidate pairs during the matching phase of a workflow run.

This tool may also be called directly by accountants (via the review UI) to re-score a pair after a manual data correction (e.g., after fixing an invoice amount or date).

---

## 2. Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| `transaction_id` | uuid | Yes | FK to `transactions.id`. The bank transaction to score. |
| `invoice_id` | uuid | Yes | FK to `invoices.id`. The invoice to score against. |
| `scoring_config_id` | uuid | No | FK to `match_scoring_configs.id`. The scoring configuration to use. Defaults to the active configuration for the transaction's `business_id`. If no active config exists, the tool fails with `NO_ACTIVE_SCORING_CONFIG`. |
| `run_id` | uuid | No | FK to `workflow_runs.id`. If provided, the score result is linked to the run in the audit event payload. |

---

## 3. Outputs

| Field | Type | Description |
|---|---|---|
| `match_level` | match_level_enum | The resulting match level: `EXACT`, `STRONG_PROBABLE`, `WEAK_POSSIBLE`, or `NO_MATCH`. |
| `composite_score` | float (0.0–1.0) | Weighted sum of all signal scores. |
| `breakdown` | object | Per-signal scores. See Breakdown Schema. |
| `scoring_config_id` | uuid | The config that was used to produce this score. |
| `scored_at` | timestamptz | When the score was computed. |

### 3.1 Breakdown Schema

| Field | Type | Description |
|---|---|---|
| `amount_score` | float (0.0–1.0) | Score for amount proximity. See Amount Scoring. |
| `date_score` | float (0.0–1.0) | Score for date proximity. See Date Scoring. |
| `reference_score` | float (0.0–1.0) | Score for reference/description match. See Reference Scoring. |
| `vendor_score` | float (0.0–1.0) | Score for vendor/counterparty identity match. See Vendor Scoring. |
| `currency_score` | float (0.0–1.0) | Score for currency match. See Currency Scoring. |

---

## 4. Scoring Logic

### 4.1 Amount Scoring

Comparison: `transaction.amount_eur` vs `invoice.total_amount_eur`.

| Condition | amount_score | Notes |
|---|---|---|
| Deviation ≤ 0.01% | 1.0 | EXACT tier — used for EXACT match level |
| Deviation ≤ 2.00% | 0.8 | STRONG_PROBABLE tier |
| Deviation ≤ 5.00% | 0.5 | WEAK_POSSIBLE tier |
| Deviation > 5.00% | 0.0 | No match on amount |

Deviation is computed as: `ABS(transaction_amount - invoice_amount) / invoice_amount * 100`.

For split payments (partial payments), the `invoice.remaining_balance_eur` is used instead of `invoice.total_amount_eur`. Split payment detection is handled by `matching.detect_split_payment` before `score_pair` is called.

### 4.2 Date Scoring

Comparison: `transaction.value_date` vs `invoice.issue_date` (or `invoice.due_date` if closer).

| Date difference (abs) | date_score | Match tier |
|---|---|---|
| 0 days | 1.0 | EXACT |
| 1–3 days | 0.8 | STRONG |
| 4–14 days | 0.5 | WEAK |
| > 14 days | 0.0 | No match on date |

The 14-day window accommodates payment processing delays, bank value dating, and settlement T+2. The window is defined in the active `match_scoring_configs` row and may be customised per business.

### 4.3 Reference Scoring

Comparison: `transaction.description` vs `invoice.invoice_number` and `invoice.reference_field`.

Two sub-scores are combined:
- **Exact token match:** `1.0` if any token in `transaction.description` exactly matches `invoice.invoice_number` (e.g., "INV-2026-0042" found in description).
- **Fuzzy token overlap:** Jaro-Winkler similarity score between normalised description tokens and normalised reference tokens. Used when exact match fails.

| Condition | reference_score |
|---|---|
| Exact token match | 1.0 |
| Fuzzy similarity ≥ 0.90 | 0.8 |
| Fuzzy similarity ≥ 0.75 | 0.5 |
| Fuzzy similarity < 0.75 | 0.0 |

Normalisation: lowercase, remove punctuation, collapse whitespace. Greek character normalisation applied (tonos removed, sigma variants unified).

### 4.4 Vendor Scoring

Comparison: `transaction.counterparty_id` vs `invoice.client_id` (for income) or `invoice.vendor_id` (for expense).

| Condition | vendor_score |
|---|---|
| Exact counterparty_id match | 1.0 |
| Matching IBAN (last 8 chars) | 0.9 |
| Matching VAT number | 0.9 |
| Normalised name similarity ≥ 0.85 | 0.7 |
| Normalised name similarity ≥ 0.70 | 0.4 |
| No match | 0.0 |

IBAN matching uses the last 8 characters (account number suffix) to accommodate IBAN formatting variants. VAT number matching uses the normalised form (country prefix removed, spaces stripped).

### 4.5 Currency Scoring

Comparison: `transaction.currency` vs `invoice.currency`.

| Condition | currency_score |
|---|---|
| Exact match | 1.0 |
| Mismatch | 0.0 |

Currency matching is strict. An EXACT match level requires `currency_score = 1.0`. A currency mismatch caps the maximum `match_level` at `WEAK_POSSIBLE`.

---

## 5. Composite Score and Match Level

```
composite_score = (
  amount_score    * weight_amount    +
  date_score      * weight_date      +
  reference_score * weight_reference +
  vendor_score    * weight_vendor    +
  currency_score  * weight_currency
)
```

Weights are defined in the active `match_scoring_configs` row for the business. The weights must sum to 1.0 (enforced by `MATCHING_SCORING_CONFIG_INVALID`).

Default weights (from the platform default config):

| Signal | Default Weight |
|---|---|
| amount | 0.35 |
| date | 0.20 |
| reference | 0.20 |
| vendor | 0.15 |
| currency | 0.10 |

### 5.1 Match Level Determination

Match level is determined by both the `composite_score` and individual signal scores:

| Level | Required conditions |
|---|---|
| `EXACT` | `composite_score >= 0.95` AND `amount_score = 1.0` AND `currency_score = 1.0` AND `date_score >= 0.8` |
| `STRONG_PROBABLE` | `composite_score >= 0.75` AND `amount_score >= 0.8` AND `currency_score = 1.0` |
| `WEAK_POSSIBLE` | `composite_score >= 0.50` |
| `NO_MATCH` | `composite_score < 0.50` |

The thresholds are defined in the active `match_scoring_configs` row for the business. See `match_scoring_calibration_policy.md` for how thresholds are recalibrated over time.

---

## 6. Auto-Confirm Logic

`matching.score_pair` does not itself confirm matches. It returns a score result. The confirmation decision is made by `matching.propose` based on the score result and the business's auto-confirm configuration:

| Condition | Action |
|---|---|
| `match_level = EXACT` AND `auto_confirm_exact = true` | `MATCHING_AUTO_CONFIRMED` emitted; `match_records` row inserted with `AUTO_CONFIRMED` |
| `match_level = STRONG_PROBABLE` AND `composite_score >= auto_confirm_threshold` | Same as above |
| Otherwise | Match proposal created; requires human confirmation |

---

## 7. Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `MATCHING_PAIR_SCORED` | LOW | `matching.score_pair` completes for a pair |

### MATCHING_PAIR_SCORED Payload

```json
{
  "transaction_id": "<uuid>",
  "invoice_id": "<uuid>",
  "business_id": "<uuid>",
  "run_id": "<uuid>",
  "scoring_config_id": "<uuid>",
  "match_level": "STRONG_PROBABLE",
  "composite_score": 0.823,
  "breakdown": {
    "amount_score": 0.8,
    "date_score": 0.8,
    "reference_score": 0.5,
    "vendor_score": 1.0,
    "currency_score": 1.0
  },
  "scored_at": "2026-05-17T10:00:00.000Z"
}
```

---

## 8. Error Codes

| Code | Description |
|---|---|
| `TRANSACTION_NOT_FOUND` | `transaction_id` does not exist |
| `INVOICE_NOT_FOUND` | `invoice_id` does not exist |
| `BUSINESS_MISMATCH` | Transaction and invoice belong to different `business_id` values |
| `INCOME_OUTCOME_MISMATCH` | Transaction is INCOME but invoice is a vendor invoice (or vice versa) |
| `NO_ACTIVE_SCORING_CONFIG` | No active `match_scoring_configs` row found for the business |
| `SCORING_CONFIG_INVALID` | Active config's signal weights do not sum to 1.0 |
| `CURRENCY_NOT_IN_ECB_RATES` | Non-EUR currency in transaction or invoice with no FX rate available |

---

## 9. Mobile

This tool is **not directly callable from mobile clients**. It runs server-side as part of the matching pipeline. Mobile clients do not call `matching.score_pair` directly; they trigger it indirectly via workflow submission (e.g., submitting a bank statement upload or requesting a matching run via the mobile UI).

**Minimal mobile interaction pattern:**

1. The mobile client triggers a workflow action (e.g., statement upload or manual matching run request) via the mobile API.
2. The workflow engine invokes `matching.propose`, which calls `matching.score_pair` for each candidate transaction–invoice pair — this is entirely server-side and asynchronous relative to the mobile action.
3. Mobile receives an async notification of matching results (`MATCHING_PAIR_SCORED`, auto-confirm outcomes, or a summary push notification) when the matching phase completes. See `tool_notify_send.md` for the notification dispatch.
4. The mobile client may then display the proposed matches for accountant review and confirmation.

`MOBILE_WRITE_REJECTED` is not emitted for this tool because it is not exposed at the authenticated mobile API layer.

---

## 10. Performance Notes

- Target latency: < 5ms per pair for in-memory scoring (no database reads beyond the initial data fetch).
- The scoring function is pure: given the same inputs and config, it always returns the same output.
- `matching.propose` batches all candidate pairs for a run and calls `score_pair` in parallel (up to 50 concurrent invocations). The scoring function must be stateless.
- For runs with > 10,000 candidate pairs, `matching.propose` uses the batch scoring variant `matching.score_pairs_batch` (not documented here) which uses a single SQL query with window functions.

---

## Mobile

This tool is server-side only. Mobile clients do not invoke it directly. Matching is triggered as part of the workflow pipeline on the server. Mobile receives async notification of matching results.

---

## 11. Cross-References

- `reference/match_level_enum.md` — `match_level_enum` values and threshold definitions
- `schemas/match_scoring_config_schema.md` — signal weights; per-business configuration
- `schemas/match_records_schema.md` — the permanent outcome record created after scoring + confirmation
- `matching_engine_policy.md` — full matching phase logic; candidate generation; auto-confirm rules
- `match_scoring_calibration_policy.md` — how thresholds are recalibrated over time
- `audit_event_taxonomy.md` — `MATCHING_PAIR_SCORED`
- `policies/tool_schema_definition_policy.md` — tool definition standards
- Block 10 Phase 03 — matching engine implementation; `matching.propose`
