# Block 06 — Phase 05: Tier 3 (Anthropic Claude) Integration

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Tier 3 — External LLM with Redaction)
- Decisions log: `Docs/decisions_log.md` (Anthropic Claude EU/zero-retention for Tier 3)

## Phase Goal

Implement the Tier 3 model integration: an Anthropic Claude API client using the EU-residency / zero-retention endpoint, with credentials fetched from the secrets manager and every call dispatched only through the Privacy Gateway (no bypass paths). After this phase, the gateway can dispatch a Tier 3 call end-to-end with the right prompt, the right redaction, and the right cost telemetry.

## Dependencies

- Phase 02 (gateway pipeline — calls reach this phase only via the gateway)
- Phase 03 (redaction applied before dispatch)
- Phase 04 (prompts resolved from the registry)
- Block 03 Phase 08 (consumes the `MODEL_ERROR.transient` flag this phase produces, for retry policy)
- Block 05 Phase 01 (TLS + cert pinning required for outbound calls to Anthropic)
- Block 05 Phase 07 (Anthropic API key fetched via `getSecret`)

## Deliverables

- **Anthropic API client:**
  - Configured to hit the **EU-residency / zero-retention** endpoint (Stage 1 decision).
  - Uses the official Anthropic SDK (or a thin custom client if the SDK doesn't expose the EU endpoint cleanly).
  - API key fetched at runtime via `getSecret('anthropic_api_key')` from Block 05 Phase 07; never read directly from environment variables in long-lived processes.
- **Request shape:**
  - System prompt + user message construction from the prompt registry (Phase 04).
  - Model id selected by the prompt's `meta.yaml` (e.g., `claude-sonnet-4-6` or whatever the prompt declares).
  - Temperature + other parameters declared per prompt version.
- **Response parsing:**
  - Structured JSON output extracted and returned to the gateway for output-schema validation (Phase 02 step 6).
  - Free-text outputs returned as-is for the caller's downstream validation.
- **Error mapping:**
  - 429 (rate limit) → `MODEL_ERROR` with `transient: true` so Block 03 Phase 08's retry policy applies.
  - 5xx server error → `MODEL_ERROR` with `transient: true`.
  - 4xx (other than 429) → `MODEL_ERROR` with `transient: false` — usually a request-shape bug in the calling phase.
  - Timeout → `MODEL_ERROR` with `transient: true`.
- **Bypass-detection runtime guard:**
  - Direct callers of the Anthropic API outside the gateway fail at runtime — the integration's entry function checks a "called via gateway" flag in the call context and refuses otherwise.
  - The lint rule from Phase 02 catches static-analysis-visible bypasses; this guard catches the rest.
- **Token counting:**
  - Input + output token counts captured per call for the cost estimator in Phase 07.
- **Audit events:** `TIER_3_INVOKED`, `TIER_3_RESPONSE_RECEIVED`, `TIER_3_FAILED`, `TIER_3_BYPASS_ATTEMPT_BLOCKED`.

## Definition of Done

- A Tier 3 call dispatched through the gateway succeeds end-to-end with a registered prompt and produces a validated typed response.
- The API key is fetched via `getSecret`; an attempt to read `process.env.ANTHROPIC_API_KEY` directly is blocked by the lint rule.
- A simulated rate-limit response maps to `MODEL_ERROR` with `transient: true`.
- A direct call to the Anthropic SDK from outside the gateway is rejected at runtime with `TIER_3_BYPASS_ATTEMPT_BLOCKED`.
- Token counts are captured on every successful call.
- The integration uses the EU-residency / zero-retention endpoint; configuration is verified on startup.

## Sub-doc Hooks (Stage 4)

- **Anthropic client configuration sub-doc** — exact endpoint URL, region selection, zero-retention flag, SDK version pinning.
- **Request shape sub-doc** — system vs user message split, temperature/top-p defaults per prompt category, max-token settings.
- **Error-mapping sub-doc** — full HTTP status → `MODEL_ERROR` table, retry semantics, observability.
- **Bypass-detection guard sub-doc** — call-context flag, runtime check, audit shape on bypass.
- **Token counting sub-doc** — input/output token attribution, image vs text, integration with cost estimator.
