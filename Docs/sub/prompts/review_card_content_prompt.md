# Review Card Content Prompt Spec

**Block ref:** 14 — Review Queue · **Category:** Prompts · **Prompt key:** `review_card_content_v1` · **Tier:** TIER_1

---

## Purpose

Generates a 2–3 sentence context summary displayed at the top of an expanded review issue card. The summary explains what the issue is, what data triggered it, and what the accountant needs to do to resolve it.

The summary is the first thing an accountant reads when they open a card. It must be direct, specific, and actionable. It must reference concrete values from the affected record — not generic descriptions.

---

## Prompt key

`review_card_content_v1`

---

## Input schema

```json
{
  "issue_type": "string (from issue_type_registry)",
  "issue_group": "string",
  "severity": "LOW | MEDIUM | HIGH | BLOCKING",
  "affected_record_type": "string (e.g. \"transaction\", \"match_record\", \"invoice\")",
  "affected_record_summary": {
    "// structure varies by affected_record_type": "see issue_type_registry_schema.md"
  },
  "prior_resolution_attempts": "number (integer >= 0)",
  "carry_forward_count": "number (integer >= 0)"
}
```

`affected_record_summary` is a typed object whose shape is defined per `issue_type` in `issue_type_registry_schema.md`. It always contains at a minimum: `record_id`, `amount_eur` (decimal string where applicable), and a `display_date` field. Additional fields depend on the issue type. The AI gateway redacts any fields tagged `PII` in the registry before passing the payload to the model.

`prior_resolution_attempts` is the count of times a reviewer has interacted with this issue (submitted a resolution that was subsequently re-opened or carried forward). A value greater than 0 signals a recurring or difficult issue. `carry_forward_count` is the number of times this issue has been carried forward from a prior run without resolution.

---

## Output schema

```json
{
  "summary_text": "string (max 300 chars)",
  "suggested_action": "string (max 100 chars)",
  "confidence": "number (0–1, two decimal places)"
}
```

`summary_text` is displayed in the expanded card header. `suggested_action` is displayed as a short call-to-action label on the primary card button. Both are rendered as plain text; no markdown.

---

## System prompt instructions

The system prompt (stored in the prompt registry under `review_card_content_v1`) instructs the model to:

1. Produce exactly 2–3 sentences for `summary_text`. The first sentence states what the issue is. The second sentence states what specific data triggered it, using amounts and dates from `affected_record_summary`. The optional third sentence provides context — prior attempts or carry-forward history — only if `prior_resolution_attempts > 1` or `carry_forward_count > 0`.
2. Be direct. Do not use "it appears", "it seems", "it looks like", "you may want to", or any tentative phrasing. State facts.
3. Reference specific amounts (as euro amounts with two decimal places) and dates (as `DD MMM YYYY`) from `affected_record_summary` where available. Do not describe the issue in purely abstract terms.
4. Tailor `suggested_action` to the `issue_type`. The system prompt includes a lookup table of `issue_type → canonical_action_verb_phrase` covering all registered issue types. Use the canonical action from that table as the basis for the `suggested_action` text.
5. Do not mention internal identifiers (UUIDs) in either field.
6. Do not mention the `severity` label — severity is displayed separately by the UI.
7. If `carry_forward_count >= 3`, the third sentence must explicitly note that this issue has carried forward across multiple periods, as this signals to the reviewer that it requires priority attention.

---

## Fallback

If `confidence < 0.55`, discard the model response entirely and return:

```json
{
  "summary_text": null,
  "suggested_action": "Review the {affected_record_type} and resolve manually.",
  "confidence": 0
}
```

When `summary_text` is `null`, the UI renders no summary paragraph — the card header is empty except for the issue type label and severity badge. The `suggested_action` button is always rendered because it always has a value (even in the fallback).

The fallback `suggested_action` format uses the `affected_record_type` field, which is always present in the input.

---

## Invocation path

Invoked by `review_queue.generate_card_content` when a review issue card is expanded for the first time in a session, or when the accountant requests a card regeneration. The tool is `READ_ONLY | EXTERNAL_CALL | WRITES_AUDIT`.

The generated content is not persisted — it is generated on demand and returned in the API response. This keeps the review_issues table schema decoupled from prompt versioning. If caching is desired within a session, it is the caller's responsibility to cache the response client-side; the server does not cache card content between sessions.

Side-effect class declaration: `READ_ONLY | EXTERNAL_CALL | WRITES_AUDIT`. No `WRITES_RUN_STATE` class is claimed. The `REVIEW_CARD_REGENERATED` audit event is emitted when the accountant explicitly requests regeneration (not on the initial load).

---

## Caching

Not cached server-side between sessions. Within a single API request this prompt is invoked at most once per card expansion. The AI gateway's within-run cache applies for workflow-run-scoped contexts, but review card generation is typically triggered outside a workflow run context (it is a UI action, not a phase tool). The gateway processes this as a non-run-scoped TIER_1 call.

---

## Error handling

If the AI gateway returns a `summary_text` exceeding 300 characters or a `suggested_action` exceeding 100 characters, the tool applies the fallback for the offending field only: `summary_text` is discarded (set to null) or `suggested_action` is replaced with the fallback text. Partial fallback is permitted — it is valid to have a model-generated `suggested_action` with a null `summary_text` if only the summary exceeded the limit.

If the `affected_record_summary` object contains no usable date or amount fields (all relevant fields are null), the model is instructed to omit references to specific values and describe the issue by type only. The summary will be less specific but still valid.

The gateway does not retry TIER_1 calls on timeout. On a 5-second timeout, the fallback is applied immediately. This keeps card-expansion latency bounded.

---

## `affected_record_summary` shape examples

The shape varies by `issue_type`. Two representative examples:

**For `issue_type = TRANSACTION_UNMATCHED`:**
```json
{
  "record_id": "uuid",
  "amount_eur": "1250.00",
  "display_date": "14 Mar 2026",
  "description_truncated": "SEPA Credit Transfer - Acme Ltd",
  "counterparty_name": "Acme Ltd"
}
```

**For `issue_type = LEDGER_VAT_UNKNOWN`:**
```json
{
  "record_id": "uuid",
  "amount_eur": "4800.00",
  "display_date": "02 Mar 2026",
  "vat_treatment": "UNKNOWN",
  "counterparty_country": "DE"
}
```

The full shape per issue type is defined in `issue_type_registry_schema.md`. The AI gateway redacts any field tagged `PII` in the registry before passing the object to the model.

---

## Versioning

`review_card_content_v1` is the current stable version. A v2 is required if:

- The `issue_type_registry` adds new issue types that require new `affected_record_summary` shapes not covered by the v1 system prompt catalog
- The `suggested_action` max length changes
- The instruction to reference `carry_forward_count` changes materially

During the v1/v2 overlap window, existing open issues retain their v1 card content on cached renders; newly opened or regenerated cards use v2.

---

## Cross-references

- `review_queue_card_layout_ui_spec.md` — card layout, placement of `summary_text` and `suggested_action`
- `issue_type_registry_schema.md` — `issue_type` values, `affected_record_summary` shapes per type, canonical action verbs
- `prompt_management_policies.md` — prompt key versioning, registry, deprecation rules
- `ai_tier_escalation_policy.md` — TIER_1 bypass of escalation
- `tool_review_queue_generate_card_content.md` — tool registration for `review_queue.generate_card_content`
- `audit_event_taxonomy.md` — `REVIEW_CARD_REGENERATED`, `AI_PROMPT_INVOKED`
- `snooze_carry_forward_policy.md` — `carry_forward_count` field semantics
- `ai_gateway_schema.md` — timeout configuration, PII redaction field tagging
