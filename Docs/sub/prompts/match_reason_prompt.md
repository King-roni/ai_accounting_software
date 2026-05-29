# Match Reason Prompt Spec

**Block ref:** 10 — Matching Engine · **Category:** Prompts · **Prompt key:** `match_reason_v1` · **Tier:** TIER_1

---

## Purpose

Converts a `match_record` and its associated signal evidence into a 1–2 sentence plain-English explanation of why the match was proposed. The output is displayed in the match review card and in the accountant-facing match confirmation dialog. The explanation must be deterministic enough for an accountant to verify without opening the underlying records.

Example output: "Matched to invoice INV-2026-0042 based on exact amount (€1,250.00) and counterparty name match (Acme Ltd). Date is 3 days after invoice due date, within the allowed window."

---

## Prompt key

`match_reason_v1`

Prompt keys follow the convention `<feature>_<purpose>_v<major>` defined in `prompt_management_policies.md`. A major version bump is required if either the input or output schema changes or if the system-prompt instructions change materially. The `v1` form is not pinned to a specific model version — that is the AI gateway's concern.

---

## Input schema

```json
{
  "match_id": "string (UUID v7)",
  "invoice_number": "string",
  "invoice_amount_eur": "string (decimal, e.g. \"1250.00\")",
  "transaction_amount_eur": "string (decimal)",
  "transaction_date": "string (ISO 8601 date, e.g. \"2026-03-18\")",
  "counterparty_name": "string",
  "match_level": "EXACT | STRONG_PROBABLE | WEAK_POSSIBLE",
  "signal_breakdown": [
    {
      "signal_name": "string",
      "weight": "number (0–1)",
      "score": "number (0–1)"
    }
  ],
  "cross_period": "boolean"
}
```

All amount fields are decimal strings per `data_layer_conventions_policy.md` (currency special case: human-readable decimal string context). The `signal_breakdown` array is ordered descending by `weight × score`. An empty `signal_breakdown` is a caller error; the prompt is not invoked in that case — the fallback template applies directly.

---

## Output schema

```json
{
  "reason_text": "string (max 200 chars)",
  "confidence": "number (0–1, two decimal places)"
}
```

`reason_text` is rendered directly in the UI with no further transformation. Callers must not truncate it — if the AI returns a string exceeding 200 characters, the gateway rejects the response and the fallback is applied.

`confidence` reflects the model's self-assessed certainty that the explanation accurately represents the signal evidence. It is not a re-scoring of the match itself.

---

## System prompt instructions

The system prompt (stored in the prompt registry under `match_reason_v1`) instructs the model to:

1. Mention only the two strongest signals — those with the highest `weight × score` product from `signal_breakdown`. Do not enumerate all signals.
2. Quantify: include the specific euro amounts and dates from the input. Do not round or approximate.
3. For `EXACT` matches: state facts directly. Do not use "likely", "probably", "appears to", or any hedging language. The word "exact" may be used when describing an exact-amount signal.
4. For `STRONG_PROBABLE` and `WEAK_POSSIBLE` matches: a single hedging qualifier is permitted ("close to", "within the expected range") only when the amount or date is genuinely approximate. Do not stack qualifiers.
5. If `cross_period` is `true`, include a brief note that the match spans a period boundary (e.g., "cross-period match").
6. Produce exactly 1–2 sentences. Do not produce zero sentences or more than two.
7. Do not mention the `match_id` or internal identifiers.
8. Do not mention VAT amounts or category labels — those are outside the matching engine's concern.

The system prompt provides the full signal-name vocabulary (amount_exact, amount_close, counterparty_name_exact, counterparty_name_fuzzy, reference_number_match, date_within_window, date_outside_window) so the model can translate signal names into human-readable phrasing.

---

## Fallback

If `confidence < 0.50`, discard the model response and use the deterministic template:

```
"Matched based on {match_level} signal score. Primary signals: {top_2_signals}."
```

where `top_2_signals` is the `signal_name` of the two entries with the highest `weight × score` product, joined with " and ".

The fallback never fails — it requires only the input fields that are always present. The audit event `MATCHING_REASON_FALLBACK_APPLIED` is emitted when the fallback path is taken. `MATCHING_REASON_GENERATED` is emitted on successful AI output.

---

## Invocation path

The prompt is invoked by `matching.generate_reason` as a TIER_1 task routed through the AI gateway (`ai.invoke`). Because TIER_1 tasks are low-stakes formatting calls, the gateway does not apply the escalation policy. Cost ceiling enforcement still applies.

Side-effect class: `READ_ONLY | EXTERNAL_CALL | WRITES_AUDIT`. The tool reads the `match_records` row and its signal evidence; it writes no run state. The only writes are the audit events emitted on completion or fallback.

---

## Caching

Match reason text is cacheable within a workflow run: if the same `match_id` with the same `signal_breakdown` has already produced a response in this run, the AI cache returns the cached `reason_text` without re-invoking the model. Cache key: canonical JSON of `{ match_id, signal_breakdown }` per `data_layer_conventions_policy.md`.

---

## Error handling

The AI gateway enforces a 5-second timeout on TIER_1 calls. If the model does not respond within the timeout window, the gateway returns a `TIMEOUT` error and the tool applies the fallback template. The timeout is intentionally tight because `matching.generate_reason` runs in the MATCHING phase; a slow explanation generator should not delay the phase.

If the gateway returns a response where `reason_text` exceeds 200 characters, the tool discards the response and applies the fallback. The model is instructed to stay within 200 characters, but character-count adherence is not guaranteed and is validated by the tool, not the gateway.

If the input `signal_breakdown` array is empty, the tool does not invoke the model. The fallback is returned immediately with `top_2_signals = ""` (empty string) and `confidence = 0`. The audit event `MATCHING_REASON_FALLBACK_APPLIED` is still emitted.

---

## Versioning

`match_reason_v1` is the current stable version. A v2 will be required if:

- The `signal_breakdown` schema changes (new fields added, types changed)
- The output max character limit changes
- The system prompt instructions change in a way that materially alters output behaviour (not minor wording refinements)

The v1 registration remains active for one full workflow-run cycle (30 days minimum) after v2 is deployed, per `prompt_management_policies.md` deprecation rules. During the overlap window, the engine routes new runs to v2 and in-progress runs to the version they started with.

---

## Cross-references

- `match_record_schema.md` — `match_records` table, `match_level` enum, signal evidence columns
- `match_signal_evidence_schema.md` — `signal_breakdown` structure and signal-name vocabulary
- `prompt_management_policies.md` — prompt key versioning, registry, and deprecation rules
- `ai_tier_escalation_policy.md` — tier routing; TIER_1 tasks bypass escalation
- `tool_matching_generate_reason.md` — tool registration for `matching.generate_reason`
- `audit_event_taxonomy.md` — `MATCHING_REASON_GENERATED`, `MATCHING_REASON_FALLBACK_APPLIED`
- `ai_gateway_schema.md` — timeout configuration, gateway error classes
- `audit_log_policies.md` — audit chain for `WRITES_AUDIT` side-effect class
