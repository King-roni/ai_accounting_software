# Block 06 — Phase 02: Privacy Gateway Pipeline

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Privacy Gateway Pipeline section)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 4 — Security by Design; the gateway is the single chokepoint)

## Phase Goal

Build the chokepoint that every AI call passes through: typed input-schema validation, payload minimization, model dispatch, output-schema validation, and structured error returns. After this phase, no code path in the system can talk to a model without going through this pipeline, and the contract between caller and model is fully typed end-to-end.

## Dependencies

- Phase 01 (tier classification — the gateway routes based on tier)
- Block 03 Phase 03 (tool registration — schemas come from tool declarations)
- Block 03 Phase 08 (consumes the `MODEL_ERROR` variant for retry semantics)
- Block 05 Phase 02 (audit log emission)

## Deliverables

- **Gateway entry point:**
  - `gateway.invokeAI(toolDeclaration, input) → AIResult` — the only function that talks to a model.
  - Direct calls to the Anthropic API or to the local LLM endpoint outside this entry point are forbidden by lint rule and refused at runtime by the per-tier integrations (Phases 05, 06).
- **Pipeline steps** (in order, all inside one logical operation):
  1. Validate `input` against the tool's declared `input_schema` (Block 03 Phase 03). Failure → `SCHEMA_VIOLATION_INPUT`.
  2. Minimize the payload — drop any field not declared in the schema. The schema is allowlist-based by construction (per Block 06 architecture).
  3. Apply the redaction policy (Phase 03) — per-tier rules; allowlist enforcement.
  4. Route via `routeAICall` (Phase 01) — produces `TierAssignment`.
  5. Dispatch to the chosen model (Phase 05 for Tier 3, Phase 06 for Tier 2). Tier 1 calls don't reach this stage; they're handled by deterministic logic upstream.
  6. Validate the response against the tool's declared `output_schema`. Failure → `SCHEMA_VIOLATION_OUTPUT`.
  7. Log usage via Phase 07 (`AI_USAGE_RECORDED`).
  8. Return the typed `AIResult` to the caller.
- **`AIResult` variants:**
  - `SUCCESS` carrying validated typed output and metadata (tier, model_id, prompt_version, latency, cost_estimate).
  - `SCHEMA_VIOLATION_INPUT` (caller's bug — refuse to even reach the model).
  - `SCHEMA_VIOLATION_OUTPUT` (model returned unparseable output — treat as a tool failure for Block 03 Phase 08's retry/escalation logic).
  - `REDACTION_REJECTED` (a non-allowlisted field with PII shape detected — Phase 03 owns this).
  - `TIER_BLOCKED` (per-business opt-out from Phase 01).
  - `MODEL_ERROR` (transient model-side error — caller decides retry per Block 03 Phase 08).
- **Strict-validation principle:**
  - No "best-effort" parsing of malformed model output. A response that doesn't validate is a structured error, not a soft fallback.
  - This makes failures investigable and prevents silent data corruption.
- **Audit events:** `AI_GATEWAY_INVOKED` (every invocation that reaches model dispatch), `AI_GATEWAY_VALIDATION_FAILED` (with the failure variant), `AI_GATEWAY_RESPONSE_INVALID` (output schema failure). **On a cache hit (Phase 09), `AI_GATEWAY_INVOKED` is replaced by `AI_CACHE_HIT`** — the audit-log invariant ("every gateway call appears in the audit log") is satisfied by either event.
- **AI audit-event taxonomy** — Block 06 phases use namespaced prefixes that this phase coordinates: `AI_GATEWAY_*` (here), `AI_TIER_*` (Phase 01), `AI_REDACTION_*` (Phase 03), `AI_PROMPT_*` (Phase 04), `TIER_2_*` / `TIER_3_*` (Phases 05, 06 — integration internals), `AI_USAGE_*` (Phase 07), `AI_COST_*` (Phase 08), `AI_CACHE_*` (Phase 09), `PLAIN_LANGUAGE_*` (Phase 10), `END_SCAN_*` (Phase 11). The catalogue is registered in Block 05 Phase 02's audit-event taxonomy sub-doc; this prefix scheme is Block 06's contribution to it.

## Definition of Done

- A valid call with conforming input produces a `SUCCESS` with typed output.
- A call with input that doesn't match the tool's input schema returns `SCHEMA_VIOLATION_INPUT` without invoking any model.
- A response that doesn't match the output schema returns `SCHEMA_VIOLATION_OUTPUT`.
- Direct invocation of Anthropic or the local LLM outside the gateway is detected by the lint rule and rejected at runtime by the integration layer.
- Tests cover every `AIResult` variant.
- Every gateway call appears in the audit log.

## Sub-doc Hooks (Stage 4)

- **`gateway.invokeAI` API sub-doc** — exact signature, async semantics, time budget.
- **`AIResult` shape sub-doc** — type definitions per variant, including metadata fields.
- **Pipeline ordering sub-doc** — why redaction follows minimization and precedes routing; what fails at which step.
- **Bypass detection sub-doc** — the lint rule and the runtime check inside the per-tier integrations.
