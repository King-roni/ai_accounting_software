# Plain Language Pipeline Prompt

**Block:** 06 — AI Layer
**Category:** Prompts
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Specifies the prompt used by the plain-language explanation pipeline to convert a
structured transaction record into a single human-readable sentence. The output is
displayed in the review queue issue card and on the transaction detail view in the
dashboard. It is not used for any ledger or classification decision; it is a
display-only formatting step.

---

## Prompt Key and Versioning

```
prompt_key:     plain_language_pipeline_v1
prompt_version: 1.0.0
```

`prompt_version` follows semver. A major bump (breaking change to input or output
shape) requires a corresponding major bump in `prompt_key` name and a deprecation
notice in `prompt_management_policies.md`. Minor and patch bumps (improved wording,
instruction clarification) do not change the key.

The active version at any point is the one loaded in `prompt_management_policies.md`'s
version table. The cache key for this prompt (per `ai_cache_schema.md`) is derived
from `plain_language_pipeline_v1:1.0.0:canonical_json(input)`, ensuring that a patch
or minor version bump to the prompt produces new LLM calls for inputs already cached
under the old version.

---

## Tier Assignment

**TIER_1 always.** This is a low-stakes formatting task with no financial, legal, or
classification consequence. Tier escalation does not apply to this prompt. The
`ai.invoke` call sets `max_tier = TIER_1`; the AI gateway rejects any escalation
attempt with `TIER_ESCALATION_REJECTED_MAX_TIER`.

TIER_1 is the locally-operated model. No plaintext transaction data leaves the
platform infrastructure to reach a third-party LLM provider on this path.

---

## Input Schema

```typescript
{
  amount_eur:        number,        // positive decimal; never negative (use category for direction)
  currency:          string,        // ISO 4217 three-letter code, e.g. "EUR"
  counterparty_name: string,        // resolved canonical counterparty name
  value_date:        string,        // ISO 8601 date, e.g. "2026-03-15"
  category:          string,        // transaction category from transaction_type_enum
  description_raw:   string | null, // raw bank statement description; null if absent
  vat_treatment:     string         // VAT treatment string from the ledger VAT enum
}
```

All fields are required except `description_raw`, which may be null. Callers must not
omit keys; a missing key causes `ai.invoke` to reject the payload before the prompt
is dispatched (`INPUT_SCHEMA_VALIDATION_FAILED`).

`amount_eur` is provided as a decimal number (not minor units) because the output is
human-facing. Example: `450.00` for €450. Per `data_layer_conventions_policy`
Section 3 currency rules, the value is serialised as a decimal-precise string in the
canonical JSON that feeds the cache key, but the field in the prompt payload itself is
a JSON number.

---

## Output Schema

```typescript
{
  plain_description: string,   // max 120 characters
  confidence:        number    // 0.0–1.0
}
```

`plain_description` is the final display string. It must be a single sentence in
English. Maximum 120 characters inclusive of punctuation.

`confidence` reflects the model's self-assessed certainty that the description
accurately represents the input. A value below 0.50 triggers the fallback template
(see "Failure Handling" below).

---

## Prompt Design

### System prompt (canonical)

```
You are a bookkeeping assistant that writes clear, concise transaction descriptions
for business owners. Given structured transaction data, write exactly one English
sentence describing the transaction.

Rules:
- Maximum 120 characters.
- Use the category field to infer the purpose of the transaction.
- Do not invent amounts, dates, or counterparty names not present in the input.
- Do not include VAT treatment in the description unless it is REVERSE_CHARGE, in
  which case append "(reverse charge)" at the end of the sentence.
- Write the amount as a formatted currency value, e.g. "€450.00".
- Write the date as a human-readable month and year, e.g. "March 2026".
- If description_raw is present and contains a meaningful reference (e.g. an invoice
  number or service description), you may include it.

Output JSON only, with no markdown wrapper:
{ "plain_description": "...", "confidence": 0.0 }
```

### Prompt notes

- The `description_raw` field is provided verbatim. The model is instructed to use it
  only if it adds meaningful context; it is not required to reproduce the raw string.
- The `category` field is the primary signal for purpose. Example categories:
  `PROFESSIONAL_SERVICES`, `TRAVEL`, `UTILITIES`, `PAYROLL`. The model maps these to
  natural-language purpose phrases.
- Amounts are never hallucinated; the model is explicitly prohibited from inventing
  values. The input schema provides the canonical amount.
- The `REVERSE_CHARGE` carve-out exists because reverse charge has a specific legal
  meaning that reviewers and accountants need to see at a glance.

---

## Failure Handling

Two failure conditions trigger the deterministic fallback template:

1. **Low confidence:** `confidence < 0.50`
2. **Overlong output:** `plain_description` exceeds 120 characters after trimming

Fallback template:

```
"{category} of {amount_eur} {currency} to {counterparty_name} on {value_date}"
```

Example output: `"PROFESSIONAL_SERVICES of 450.00 EUR to Acme Ltd on 2026-03-15"`

The fallback is applied by the calling code in `out_workflow` or `review_queue`; it is
not produced by the LLM. The `confidence` value from the failed LLM call is not
propagated to the display layer; the fallback is displayed without a confidence
indicator.

If the LLM call itself fails (network error, timeout, rate limit), `ai.invoke` retries
per the retry policy in Block 06. After exhaustion, the fallback template is applied
and no review issue is raised — the consequence is a less readable description, not a
blocking error.

---

## Cross-references

- `ai_gateway_schema.md` — `ai_invocation_records` table; invocation records for
  `plain_language_pipeline_v1` calls
- `tool_gateway_invoke_ai.md` — `ai.invoke` implementation; hit path, tier enforcement,
  and retry policy
- `ai_tier_escalation_policy.md` — tier escalation rules; this prompt is max TIER_1
  and is excluded from the escalation path
- `prompt_management_policies.md` — versioning lifecycle, deprecation, active-version
  table
- `ai_cache_schema.md` — cache key derivation for within-run dedup
- Block 06 Phase 10 — Plain language pipeline (phase doc)
