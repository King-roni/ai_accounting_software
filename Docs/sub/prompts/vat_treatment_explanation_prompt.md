# VAT Treatment Explanation Prompt Spec

**Block ref:** 11 — Ledger & Cyprus VAT · **Category:** Prompts · **Prompt key:** `vat_treatment_explanation_v1` · **Tier:** TIER_1

---

## Purpose

Generates a 1-sentence accountant-facing explanation of why a specific VAT treatment was applied to a transaction. The sentence is displayed in the ledger detail view alongside the VAT entry. It is intended for qualified accountants who need a quick legal reference, not for end-user consumers.

Example output: "Standard 19% VAT applied — domestic B2B service supply under Cyprus VAT Law Article 5."

The explanation must cite the specific Cyprus VAT rule or article that governs the applied treatment. It must not be speculative.

---

## Prompt key

`vat_treatment_explanation_v1`

---

## Input schema

```json
{
  "transaction_id": "string (UUID v7)",
  "vat_treatment": "string (value from vat_treatment_enum)",
  "counterparty_country": "string (ISO 3166-1 alpha-2)",
  "counterparty_vat_number": "string | null",
  "vies_validated": "boolean",
  "amount_eur": "string (decimal, e.g. \"4800.00\")",
  "category": "string (transaction category label)"
}
```

`amount_eur` is a decimal string. The model uses it for context only — it does not perform arithmetic. `counterparty_vat_number` is passed in redacted form (first 4 and last 2 characters visible, remainder masked) per the AI gateway redaction policy; the model does not receive the full number. `vies_validated` is a boolean indicating whether the counterparty's VAT number passed a live VIES SOAP check.

---

## Output schema

```json
{
  "explanation_text": "string (max 150 chars)",
  "confidence": "number (0–1, two decimal places)"
}
```

`explanation_text` is rendered directly in the ledger detail UI. Callers must not truncate it — responses exceeding 150 characters cause the gateway to apply the fallback.

---

## System prompt instructions

The system prompt (stored in the prompt registry under `vat_treatment_explanation_v1`) instructs the model to:

1. Produce exactly one sentence. No more, no less.
2. Always cite the specific Cyprus VAT Law article or rule that governs the applied treatment. The system prompt supplies the full Cyprus VAT rule catalog as a reference table mapping `vat_treatment` values to their governing article numbers.
3. Never use "probably", "may be", "likely", "appears to", or any hedging language. Every supported `vat_treatment` value has a deterministic legal basis; the model is not being asked to infer one.
4. If `vies_validated` is `true` and the treatment is `EU_REVERSE_CHARGE`, the sentence must mention that the counterparty's VAT number was VIES-validated.
5. If `counterparty_vat_number` is `null` and the treatment is `EU_REVERSE_CHARGE`, the sentence must note the absence of a VAT number on record.
6. Do not mention the transaction ID, internal identifiers, or amounts in the explanation — the accountant sees those fields separately.
7. Do not invent article numbers. If the `vat_treatment` value is not in the rule catalog provided, output only the fallback.

The system prompt catalog covers all values in `vat_treatment_enum.md`: `STANDARD_19`, `REDUCED_9`, `REDUCED_5`, `ZERO_RATED`, `EXEMPT`, `EU_REVERSE_CHARGE`, `NON_EU_OUT_OF_SCOPE`, `UNKNOWN`. `UNKNOWN` always routes to the fallback, not the model.

---

## Fallback

If `confidence < 0.60` or if `vat_treatment = "UNKNOWN"`, discard the model response and return:

```
"VAT treatment: {vat_treatment}. See cyprus_vat_rule_catalog for details."
```

The fallback is deterministic and always succeeds. Audit event `AI_PROMPT_INVOKED` is emitted on every invocation. No separate fallback-specific event is registered for this prompt; callers log the fallback path via the tool's own audit emission.

---

## Invocation path

Invoked by `ledger.generate_vat_explanation` as a TIER_1 task. TIER_1 tasks do not trigger the escalation policy. The tool is `READ_ONLY | EXTERNAL_CALL | WRITES_AUDIT`.

The explanation is generated after `ledger.compute_vat_amounts` has written the `vat_entries` row. The explanation is stored on the `vat_entries.explanation_text` column (nullable text, max 150 chars). If the explanation generation fails or returns the fallback, the `vat_entries` row is still valid — the explanation column is populated with the fallback string, not left null.

---

## Caching

Cacheable within a workflow run. Cache key: canonical JSON of `{ transaction_id, vat_treatment, vies_validated }`. Amount and category are excluded from the cache key — a corrected amount for the same transaction retains the same VAT treatment and explanation.

---

## Error handling

The AI gateway enforces a 5-second timeout on TIER_1 calls. On timeout the tool applies the fallback string and continues — a missing VAT explanation does not block ledger entry creation.

If the gateway returns a `reason_text` exceeding 150 characters, the tool truncates to 148 characters and appends "…". This is a last-resort safety measure; the system prompt instructs the model to stay within 150 characters. The audit log records the truncation flag.

If the HIBP-style pattern check in the redaction layer strips the `counterparty_vat_number` field entirely (because the VAT number matched a PII pattern not in the allowlist), the tool proceeds with `counterparty_vat_number = null` in the payload. The system prompt handles the null case via instruction 5 above.

---

## Supported VAT treatment values

The system prompt catalog covers all values in `vat_treatment_enum.md`. Brief mapping for reference:

| `vat_treatment` | Governing rule |
|---|---|
| `STANDARD_19` | Cyprus VAT Law Article 5 — standard rate |
| `REDUCED_9` | Cyprus VAT Law Article 6(1) — reduced rate (accommodation, restaurants) |
| `REDUCED_5` | Cyprus VAT Law Article 6(2) — reduced rate (food, books, pharmaceuticals) |
| `ZERO_RATED` | Cyprus VAT Law Article 7 — zero-rated supplies |
| `EXEMPT` | Cyprus VAT Law Article 8 — exempt supplies |
| `EU_REVERSE_CHARGE` | EU VAT Directive Article 196 / Cyprus VAT Law Article 11B |
| `NON_EU_OUT_OF_SCOPE` | Outside the territorial scope of Cyprus VAT Law |
| `UNKNOWN` | No treatment determined — always routes to fallback |

The governing article cited in the explanation is drawn from the catalog in the system prompt, not from the model's training data. This prevents the model from citing articles that do not exist in Cyprus VAT law.

---

## Versioning

`vat_treatment_explanation_v1` is the current stable version. A v2 is required if the Cyprus VAT rule catalog changes (new treatment added, article number amended by legislation) or if the output schema changes. The rule catalog is a versioned artifact in `cyprus_vat_rule_catalog.md`; prompt version bumps are tied to catalog version bumps where the output would materially change.

---

## Cross-references

- `cyprus_vat_rule_catalog.md` — article-to-treatment mapping supplied in the system prompt
- `vat_treatment_enum.md` — closed enum of supported VAT treatment values
- `vat_entry_schema.md` — `vat_entries` table, `explanation_text` column
- `prompt_management_policies.md` — prompt key versioning and registry rules
- `ai_tier_escalation_policy.md` — TIER_1 bypass of escalation
- `tool_ledger_generate_vat_explanation.md` — tool registration for `ledger.generate_vat_explanation`
- `audit_event_taxonomy.md` — `AI_PROMPT_INVOKED`, `LEDGER_VAT_TREATMENT_DECIDED`
- `ai_gateway_schema.md` — timeout configuration, response validation
