# Tier-3 Classifier Prompt

**Block:** 08 — Transaction Classification
**Category:** Prompts
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Specifies the prompt used for TIER_3 classification — the last-resort AI classification
pass for transactions where both the TIER_1 rule-based classifier (Layer 1) and the
TIER_2 vendor-memory classifier (Layer 2) produced confidence below 0.65. If this pass
also produces confidence below 0.50, the transaction falls to human review. No further
AI escalation occurs beyond TIER_3.

The `reasoning` field in the output is displayed to the human reviewer in the review
queue to explain why the AI chose the category it did.

---

## Prompt Key and Versioning

```
prompt_key:     transaction_classifier_tier3_v1
prompt_version: 1.0.0
```

`prompt_version` follows semver. A major bump (changed input or output shape)
deprecates the old version. Both versions remain registered for one full
workflow-run cycle (30 days) before removal, per `tool_naming_convention_policy.md`.
Minor and patch bumps do not affect the cache key prefix.

---

## Tier Assignment

**TIER_3 always.** This prompt is never invoked at TIER_1 or TIER_2. The `ai.invoke`
call sets `min_tier = TIER_3` and `max_tier = TIER_3`. There is no further escalation
from TIER_3 — the gateway rejects any escalation attempt with
`TIER_ESCALATION_REJECTED_MAX_TIER`. Audit event: `AI_CLASSIFICATION_LAYER_3_INVOKED`.

TIER_3 is Anthropic Claude. The input payload passes through the AI privacy gateway
(Block 06 Phase 02) before reaching the external API. Sensitive fields are redacted
per `redaction_field_map.md`; `counterparty_name` is passed through because it is
required for meaningful classification and is the canonical resolved name (not the raw
bank description).

---

## Input Schema

```typescript
{
  amount_eur:              number,          // positive decimal
  counterparty_name:       string,          // canonical resolved name
  counterparty_country:    string,          // ISO 3166-1 alpha-2 country code
  description_raw:         string | null,   // raw bank statement description
  value_date:              string,          // ISO 8601 date
  prior_tier1_category:    string | null,   // category output from Layer 1, or null
  prior_tier2_category:    string | null,   // category output from Layer 2, or null
  prior_tier1_confidence:  number,          // 0.0–1.0
  prior_tier2_confidence:  number,          // 0.0–1.0
  business_context: {
    industry:        string,                // business industry descriptor
    vat_registered:  boolean
  }
}
```

`prior_tier1_category` and `prior_tier2_category` are the category outputs from the
lower tiers. They are included so the TIER_3 model can consider prior classifications
as weak signals. A null value means the corresponding tier did not produce a usable
category (e.g. Layer 1 returned `RULE_NO_MATCH`).

`business_context.industry` is a free-text descriptor from the business entity
configuration (e.g., `"IT consulting"`, `"retail"`, `"logistics"`). It provides
domain context that helps the model distinguish between otherwise ambiguous
transactions.

---

## Output Schema

```typescript
{
  category:   string,   // value from transaction_type_enum
  confidence: number,   // 0.0–1.0
  reasoning:  string    // max 300 characters; displayed in review queue
}
```

`category` must be a value from `transaction_type_enum.md`. The output-schema
validation step in `ai.invoke` rejects any category not present in the enum with
`OUTPUT_SCHEMA_VALIDATION_FAILED`. If the model cannot classify the transaction, it
must return `UNCATEGORISED` — not an invented category.

`confidence` is the model's self-assessed certainty. It is not post-processed or
capped; the raw model output is used.

`reasoning` is a short plain-English explanation of why the model chose the category.
Maximum 300 characters. If the model returns a reasoning string exceeding 300
characters, it is truncated at 300 characters before storage. The reasoning is stored
on the Processing zone scratch record and displayed in the review queue issue card to
assist the human reviewer.

---

## Low-Confidence Path

If `confidence < 0.50` in the TIER_3 output:

1. `category` is overridden to `UNCATEGORISED` by the calling code (the model's
   suggested category is discarded).
2. A `CLASSIFICATION_CONFIDENCE_LOW` review issue is raised in the review queue.
3. The `reasoning` field from the model output is preserved and attached to the review
   issue; it is the reviewer's primary context for making a manual classification
   decision.
4. Audit event: `AI_CLASSIFICATION_LAYER_3_DECIDED` with `decided_category =
   'UNCATEGORISED'` and `confidence_below_threshold = true`.

The `reasoning` is never discarded on the low-confidence path. A human reviewer
making a decision without any AI reasoning context is at a disadvantage; preserving
the partial reasoning is better than discarding it.

---

## Prompt Design

### System prompt (canonical)

```
You are a Cyprus bookkeeping assistant specialising in transaction classification.
You will receive a bank transaction that previous classification layers could not
classify with sufficient confidence. Your task is to classify it into one of the
provided categories and explain your reasoning.

Transaction type enum (use exactly one of these values for "category"):
{transaction_type_enum_values}

Cyprus VAT treatment mapping by category:
{cyprus_vat_treatment_mapping}

Rules:
- Choose the category that best fits the transaction given the counterparty, amount,
  date, and description.
- Prefer the category that aligns with the business context (industry, VAT registration
  status).
- Use the prior tier classifications as weak signals: if both tiers agree, weight that
  category more heavily unless you have strong evidence against it.
- If the transaction is genuinely ambiguous and you cannot assign a category with
  confidence >= 0.50, return "UNCATEGORISED".
- The "reasoning" field must be 300 characters or fewer. Explain your choice in plain
  English as if briefing a human accountant.
- Do not invent facts not present in the input.

Output JSON only, no markdown wrapper:
{ "category": "...", "confidence": 0.0, "reasoning": "..." }
```

The `{transaction_type_enum_values}` and `{cyprus_vat_treatment_mapping}` placeholders
are filled at prompt dispatch time from the registered enum and VAT mapping tables.
They are injected as a compact JSON array and object respectively; they are not
hardcoded in the prompt template so that updates to the enum or VAT rates do not
require a prompt version bump.

Cyprus VAT treatment mapping includes: standard 19%, reduced 9%/5%, 0%, exempt, and
EU reverse charge rules for intra-EU B2B services. The mapping is used by the model to
infer expected VAT treatment alongside category, which feeds the `reasoning` field.

---

## Cross-references

- `ai_tier_escalation_policy.md` — rules governing when TIER_3 is invoked and the
  TIER_3 ceiling (no further escalation)
- `classification_confidence_output_schema.md` — confidence thresholds (0.65 for
  escalation, 0.50 for human-review fallback)
- `transaction_type_enum.md` — canonical enum values injected into the system prompt
- `prompt_management_policies.md` — versioning lifecycle, active-version table,
  deprecation procedure
- `ai_cache_schema.md` — within-run cache; TIER_3 results are cached per
  `(workflow_run_id, cache_key)` to avoid duplicate external API calls on retry
- `audit_event_taxonomy.md` — `AI_CLASSIFICATION_LAYER_3_INVOKED`,
  `AI_CLASSIFICATION_LAYER_3_DECIDED`
- Block 08 Phase 04 — AI fallback classifier layer 3 (phase doc)
