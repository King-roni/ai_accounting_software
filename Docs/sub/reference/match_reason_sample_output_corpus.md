# match_reason_sample_output_corpus

**Category:** Reference · **Owning block:** 10 — Matching Engine · **Co-owner:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

The **golden test corpus** of known-good match-reason outputs, organised by match level + edge case. Used as regression test input by `matching.generate_reason` test runners. Every new prompt version (`match_reason_v1`, `match_reason_v2`, ...) MUST produce outputs that pass the corpus assertions before the version can be promoted to production.

Note on match-level naming: per project-meta Stage-6 drift queue, three competing conventions coexist (numeric 1-4 / EXACT-STRONG_PROBABLE-WEAK_POSSIBLE / STRONG_MATCH-PROBABLE_MATCH-WEAK_MATCH). This corpus uses **numeric 1-4** as the canonical match-level identifier per the phase doc, with named aliases in parentheses for traceability against `match_reason_prompt.md` v1. Stage-6 reconciliation will collapse to one naming.

---

## 1. Corpus structure

```
tests/golden/match_reason/
  level_1/
    01_invoice_exact_eur.json
    02_invoice_exact_eur_with_supplier_alias.json
    03_invoice_exact_eur_paid_same_day.json
    ...
  level_2/
    01_strong_probable_supplier_fuzzy.json
    ...
  level_3/
    01_weak_possible_amount_only.json
    ...
  level_4/
    01_no_match_fallback_only.json
  cross_currency/
    01_usd_to_eur_bank_paired_leg.json
    02_gbp_to_eur_ecb_fallback.json
  cross_period/
    01_invoice_dec_paid_jan.json
    02_invoice_q1_paid_q2.json
  fallback/
    01_ai_timeout.json
    02_ai_schema_validation_failed.json
    03_ai_rate_limited.json
```

Each `.json` file is a single test case:

```jsonc
{
  "case_id": "01_invoice_exact_eur",
  "match_level": 1,
  "match_level_alias_v1": "EXACT",
  "input": {
    // Full input matching match_reason_prompt.md §Input schema
  },
  "expected_output": {
    "reason_text": "Matched: invoice amount EUR 49.00, transaction amount EUR 49.00, supplier Google Ireland Ltd, invoice dated one day before the payment.",
    "confidence_min": 0.85,
    "max_chars": 300
  },
  "assertions": [
    {"kind": "char_count_lte", "value": 300},
    {"kind": "contains_amount", "value": "EUR 49.00"},
    {"kind": "no_hedging_words", "words": ["likely", "probably", "appears", "perhaps"]},
    {"kind": "mentions_at_most_signals", "count": 2}
  ]
}
```

`assertions` is a list of declarative checks per `match_reason_prompt.md` §"System prompt instructions" rules 1-8. The test runner consumes this list; assertions never embed implementation logic in the corpus file.

---

## 2. Level 1 (numeric 1 / EXACT) — 5 canonical samples

| # | Case | Expected output |
|---|---|---|
| 1 | Invoice EUR 49.00 = transaction EUR 49.00; supplier Google Ireland Ltd; date 1 day before payment | "Matched: invoice amount EUR 49.00, transaction amount EUR 49.00, supplier Google Ireland Ltd, invoice dated one day before the payment." |
| 2 | Invoice EUR 1,250.00 = transaction EUR 1,250.00; supplier "Acme Ltd" matches "Acme Limited" via canonical alias; date same day | "Matched: invoice INV-2026-0042 amount EUR 1,250.00 paid same day; supplier Acme Limited matched via canonical alias." |
| 3 | Invoice EUR 49.00 = transaction EUR 49.00; supplier exact; date same day; reference number on transaction also matches | "Matched: invoice INV-2026-0042 amount EUR 49.00, reference INV-2026-0042 on transaction; supplier Google Ireland Ltd; paid same day." |
| 4 | Invoice EUR 0.99 = transaction EUR 0.99; supplier Stripe Payments Europe; date same day (micro-payment) | "Matched: invoice amount EUR 0.99, transaction amount EUR 0.99, supplier Stripe Payments Europe, paid same day." |
| 5 | Invoice EUR 12,500.00 = transaction EUR 12,500.00; supplier Hellenic Telecommunications Organisation OTE PLC (long name); date 3 days after | "Matched: invoice amount EUR 12,500.00, transaction amount EUR 12,500.00, supplier OTE PLC, invoice dated 3 days before the payment." |

Common assertions for ALL Level 1 cases:
- `char_count_lte: 300`
- `no_hedging_words: [likely, probably, appears, perhaps, possibly, may]`
- `mentions_at_most_signals: 2`
- `contains_match_level_indicator: false` (NO "exact match" or "perfect match" word; the structure speaks for itself per rule 3)

---

## 3. Level 2 (numeric 2 / STRONG_PROBABLE) — 5 canonical samples

| # | Case | Expected output |
|---|---|---|
| 1 | Amount EUR 49.00 matches; supplier "Google IE" matches "Google Ireland Ltd" with 92% fuzzy confidence; vendor memory shows 4 prior confirmations | "Likely match: amount EUR 49.00 and currency match exactly; supplier 'Google Ireland Ltd' matches 'Google IE' with 92% confidence; you've confirmed this supplier 4 times before." |
| 2 | Amount EUR 1,250.00 matches; date 7 days after invoice (within typical 30d window); supplier exact | "Likely match: amount EUR 1,250.00 paid 7 days after the invoice date; supplier Acme Limited exact match." |
| 3 | Amount EUR 49.00 close (within €0.01 of EUR 48.99); supplier exact; date 1 day before | "Likely match: amount EUR 48.99 close to invoice EUR 49.00 (within 1 cent); supplier Google Ireland Ltd; paid 1 day before invoice date." |
| 4 | Amount EUR 100.00 = invoice EUR 100.00; vendor memory shows 2 confirmations; supplier name only partial-match (60% fuzzy) | "Likely match: amount EUR 100.00 exact; supplier name partial match (60%); 2 prior confirmations for this supplier." |
| 5 | Reference number partial match (last 6 digits); amount exact; date in range | "Likely match: amount EUR 350.00 exact; reference number ends in 042 matching invoice INV-2026-0042 last digits; paid 2 days after invoice." |

Common assertions:
- `char_count_lte: 300`
- `max_hedging_qualifiers: 1` (single "likely" / "close to" / "within X%" permitted; no stacking per rule 4)
- `mentions_at_most_signals: 2`

---

## 4. Level 3 (numeric 3 / WEAK_POSSIBLE) — 5 canonical samples

| # | Case | Expected output |
|---|---|---|
| 1 | Amount matches; supplier name different; date different | "Possible match: amount matches, but supplier name and date are different. Please review." |
| 2 | Amount close (within €5 of invoice); supplier fuzzy 70%; date 60 days after | "Possible match: amount close to invoice (within EUR 5); supplier partial match; paid 60 days after invoice. Please review." |
| 3 | Amount exact; no supplier match; reference number absent | "Possible match: amount EUR 250.00 exact; supplier name not matched; please review and confirm." |
| 4 | Amount close (within 5%); supplier name partial; date in extended window (90d) | "Possible match: amount close to invoice (within 5%); supplier partial match; paid 90 days after the invoice. Please review." |
| 5 | Reference number exact; amount differs by €50; supplier different | "Possible match: reference number INV-2026-0042 on transaction; amount differs by EUR 50.00; please review." |

Common assertions:
- `char_count_lte: 300`
- `must_contain_review_prompt: true` (one of: "Please review", "please review and confirm", "review the match")
- `mentions_at_most_signals: 2`

---

## 5. Level 4 (no match — fallback only)

Level 4 is the no-match case. The matching engine emitted a `match_records` row only to record the proposal failure for audit. No AI call is made. The plain-language reason is hard-coded:

```
"No match found within the configured thresholds. Manual review required."
```

There is exactly ONE Level 4 sample (`level_4/01_no_match_fallback_only.json`) because the output is deterministic.

---

## 6. Cross-currency samples — 4 cases

| # | Case | Expected output |
|---|---|---|
| 1 | Invoice USD 100.00; transaction EUR 91.20; FX rate 1.097 USD/EUR from bank's paired leg | "Matched: invoice USD 100.00 converts to EUR 91.20 at the bank's recorded rate (1.097 USD/EUR); transaction amount EUR 91.20." |
| 2 | Invoice GBP 80.00; transaction EUR 93.50; FX rate from ECB fallback 0.856 GBP/EUR | "Matched: invoice GBP 80.00 converts to EUR 93.50 at ECB rate 0.856 GBP/EUR; transaction amount EUR 93.50." |
| 3 | Invoice USD 1,000.00; transaction EUR 912.00; FX rate 1.097 from bank's paired leg; supplier exact; date same day | "Matched: invoice USD 1,000.00 converts to EUR 912.00 at the bank's recorded rate (1.097); supplier Stripe Inc; paid same day." |
| 4 | Invoice CHF 200.00; transaction EUR 205.80; FX rate from ECB fallback (no paired leg) | "Likely match: invoice CHF 200.00 converts to EUR 205.80 at ECB rate; supplier Swisscom AG matches; paid 2 days after invoice." |

Cross-currency assertions:
- `must_mention_fx_rate: true`
- `must_mention_fx_source: true` (one of: "bank's recorded rate", "ECB rate", "bank's paired leg")
- `char_count_lte: 300`
- Cross-currency cases ESCALATE to higher AI tier per `match_reason_prompt.md` (and Stage-6-reconciliation tier-drift; current doc says TIER_1 always; phase doc says Tier 3 for cross-currency — the corpus tests the OUTPUT regardless of which tier produces it).

---

## 7. Cross-period samples — 2 cases

| # | Case | Expected output |
|---|---|---|
| 1 | Invoice December 2025; payment January 2026; amount exact; supplier exact | "Matched: invoice INV-2025-1099 amount EUR 49.00 paid in January 2026 (cross-period match)." |
| 2 | Invoice Q1 2026; payment Q2 2026; amount close; supplier fuzzy | "Likely match: amount EUR 49.00 close to invoice; supplier partial match; cross-period match (Q1 invoice paid in Q2)." |

Cross-period assertions:
- `must_contain_phrase: "cross-period match"` (rule 5 from `match_reason_prompt.md`)
- `char_count_lte: 300`

---

## 8. Fallback samples — 3 cases

When the AI call fails, the deterministic fallback template is invoked. Output must match exactly (no AI variance):

| # | Failure category | Expected output |
|---|---|---|
| 1 | `AI_TIMEOUT` (5s gateway timeout reached) | "Match details: amount exact, supplier exact, date within 1 day. Plain-language summary unavailable; structured signals only." |
| 2 | `AI_SCHEMA_VALIDATION_FAILED` (response > 300 chars or malformed JSON) | "Match details: amount close, supplier fuzzy, date within 7 days. Plain-language summary unavailable; structured signals only." |
| 3 | `AI_RATE_LIMITED` (gateway rate-limit cap hit) | "Match details: amount matches, supplier name differs, date differs. Plain-language summary unavailable; structured signals only." |

Fallback assertions:
- `exact_text_match: true` (deterministic — no AI variance allowed)
- `must_emit_audit: MATCHING_REASON_FALLBACK_APPLIED`
- `audit_payload_failure_category: one_of [AI_TIMEOUT, AI_SCHEMA_VALIDATION_FAILED, AI_RATE_LIMITED, AI_OTHER]`

The fallback samples specifically test that the local fallback path runs without invoking the AI gateway. The test harness simulates each failure category by mocking the gateway response.

---

## 9. Corpus maintenance

### Adding a new sample

1. Identify the case category (level / cross-currency / cross-period / fallback).
2. Create `<category>/<NN>_<descriptive_name>.json` following the §1 schema.
3. Run `pnpm test:match_reason:corpus -- --update` to capture the current model's output as the expected baseline (if not already known).
4. Manually review the captured baseline against `match_reason_prompt.md` rules 1-8.
5. Commit the JSON file.

### Removing or updating a sample

Removing a sample requires PR review + a one-line justification in the PR description. Samples are not silently removed — they are the regression net. Updating expected output (e.g., when the prompt rules change in a way that produces different surface text) follows the same review path.

### Corpus rotation

After each major prompt version bump (`v1` → `v2`), the corpus is duplicated to `tests/golden/match_reason/v1/` (frozen) and the live corpus migrates to `v2/`. The `v1` corpus is retained for the deprecation overlap window per `prompt_management_policies.md` (30 days minimum).

This lets pre-v2 in-flight runs (still using v1) continue to validate against v1 expectations while new runs validate against v2.

### CI integration

The corpus runs as part of the AI-layer test suite, not the tenant-isolation suite. Budget: ≤ 30 s for the full corpus (≤ 25 cases × ~1.2 s per case on the production model). Run via `pnpm test:match_reason:corpus`.

Cross-block coordination flagged for **B06·P10 implementation:** the test harness needs `ai.invoke` mocking primitives that can return canned responses + simulate the 4 failure categories at the gateway boundary.

---

## 10. Cross-references

- `match_reason_prompt.md` — the 8-rule style guide the corpus enforces (with Stage-6 drift queue noted at §intro)
- `prompt_management_policies.md` — `match_reason_v1` registration; deprecation overlap window
- `match_record_schema.md` — input source for `match_signals.score_breakdown` referenced by §1 schema
- `match_signal_evidence_schema.md` — `signal_breakdown` array structure
- `audit_event_taxonomy.md` — `MATCHING_REASON_GENERATED`, `MATCHING_REASON_FALLBACK_APPLIED`, `MATCHING_REASON_CACHE_HIT`, `MATCHING_REASON_REGENERATED`
- `ai_tier_escalation_policy.md` — tier classification (Stage-6 drift queue; corpus tests the OUTPUT regardless of tier)
- `ai_gateway_schema.md` — timeout configuration; mocked by the test harness for fallback samples §8
- `data_layer_conventions_policy.md` — decimal-string currency format used in inputs
- Block 10 Phase 07 — match reason generation (owning phase; deliverables sourced sample examples here)
- Block 06 Phase 10 — plain-language pipeline (consumer of corpus assertions via test harness)
- Stage 1 decision — plain-language explanations; deterministic-fallback principle
