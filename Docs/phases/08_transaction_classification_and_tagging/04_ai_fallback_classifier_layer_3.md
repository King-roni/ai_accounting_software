# Block 08 — Phase 04: AI Fallback Classifier (Layer 3)

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Layer 3 — AI Fallback)
- Block doc: `Docs/blocks/06_ai_layer.md` (Privacy Gateway, three tiers, prompt management)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 3 — AI assists, rules decide)

## Phase Goal

Build Layer 3: when neither deterministic rules (Phase 02) nor recurring-vendor memory (Phase 03) produces a confident classification, route the transaction through Block 06's Privacy Gateway as an AI classification call. After this phase, ambiguous transactions get a typed AI suggestion (Tier 2 by default, explicit Tier 3 only when Tier 2 is below threshold) — never silently escalated, always schema-validated, always confidence-scored.

## Dependencies

- Phase 02 (Layer 1 runs first; if matched cleanly, Layer 3 is not invoked)
- Phase 03 (Layer 2 runs second; if memory hits with high confidence, Layer 3 is not invoked)
- Block 06 Phase 02 (Privacy Gateway entry point)
- Block 06 Phase 03 (redaction policy applied to the call payload)
- Block 06 Phase 04 (prompt registry for the classification prompts)
- Block 06 Phase 05 (Tier 3 Anthropic Claude integration)
- Block 06 Phase 06 (Tier 2 local LLM integration)

## Deliverables

- **Classification prompts** registered in Block 06 Phase 04's registry:
  - `08.classify_transaction.tier2` — Tier 2, classifies a normalized transaction into one of the 12 types with optional tag suggestion. Input: minimized transaction (date, amount, currency, direction, normalized merchant, description). Output schema: `{ suggested_type, suggested_tag?, confidence, reasoning_short }`.
  - `08.classify_transaction.tier3` — Tier 3, same I/O contract but with a richer model. Used only when Tier 2's confidence is below threshold.
  - Both prompts have test corpora; CI runs them per Block 06 Phase 04's regression rules.
- **AI fallback dispatch** — `aiFallback(transaction, businessId, layer1Result, layer2Result) → AIClassificationResult`:
  1. Build the minimized payload (per Block 06's redaction policy: full IBAN → masked, address → omitted, raw email content → never present here).
  2. Invoke `08.classify_transaction.tier2` through `gateway.invokeAI`.
  3. If Tier 2's confidence ≥ threshold (default `0.65`, calibrated): return its result.
  4. If Tier 2's confidence < threshold: emit `AI_CLASSIFICATION_TIER2_LOW_CONFIDENCE` and explicitly invoke `08.classify_transaction.tier3` (a separate call, audit-logged distinctly per Block 06 Phase 01's "explicit, not silent" rule).
  5. Return Tier 3's result.
- **Confidence calibration:**
  - AI confidences are not directly comparable to rule/memory confidences; apply a per-tier scaling factor at integration time (Tier 2: × 0.85; Tier 3: × 0.95). Calibration values live in a sub-doc table that's tunable based on production data.
- **Output schema enforcement:**
  - Block 06 Phase 02 validates the response against the prompt's declared output schema. A schema-violation response is treated as `MODEL_ERROR` and falls through to a `classification.ai_fallback_failed` review issue with severity `MEDIUM`.
- **Cost / cache integration:**
  - Calls go through Block 06 Phase 09's within-run cache — same transaction normalization re-encountered in the same run returns the cached result.
  - Cost ceiling (Block 06 Phase 08) applies; an at-ceiling event surfaces a HIGH review issue and pauses the phase.
- **Outputs to the transaction:**
  - On success: writes `transaction_type` and optionally `system_tag`, sets `classification_method = AI_FALLBACK`, sets `classification_confidence` from the calibrated AI confidence.
- **Audit events:** `AI_CLASSIFICATION_INVOKED` (with tier), `AI_CLASSIFICATION_TIER2_LOW_CONFIDENCE`, `AI_CLASSIFICATION_TIER3_INVOKED`, `AI_CLASSIFICATION_RESULT` (with the chosen type), `AI_CLASSIFICATION_FAILED`. **Each gateway invocation also emits Block 06's standard `AI_GATEWAY_INVOKED` event independently** — Block 06 owns gateway-level audit; Block 08's `AI_CLASSIFICATION_*` events are domain-level annotations on top of that.

## Definition of Done

- A transaction with no Layer 1 or Layer 2 hit is dispatched to Tier 2 AI classification through the gateway.
- A Tier 2 response below the threshold triggers an explicit Tier 3 call (verified by audit-event sequence: `AI_CLASSIFICATION_INVOKED` (tier 2) → `AI_CLASSIFICATION_TIER2_LOW_CONFIDENCE` → `AI_CLASSIFICATION_TIER3_INVOKED`).
- Schema-violation responses are caught and surface a review issue.
- The same transaction normalized identically twice within a run returns from the gateway cache on the second call.
- Cost ceiling enforcement is honored; an at-ceiling event pauses the phase.
- Tests cover happy path, Tier 2 → Tier 3 escalation, schema violation, cache hit, ceiling hit.

## Sub-doc Hooks (Stage 4)

- **Classification prompt design sub-doc** — system + user prompt structure, examples, edge-case handling per type.
- **Tier 2 → Tier 3 escalation threshold sub-doc** — default value, calibration methodology, per-business override (post-MVP).
- **Confidence calibration sub-doc** — tier-to-engine scaling factors, recalibration cadence, A/B testing for threshold tweaks.
- **Test corpus sub-doc** — corpus structure, must-include cases per transaction type, regression-anchor cases.
