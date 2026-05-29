# Block 06 — Phase 01: Tier Classification & Routing

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (The Three Tiers section)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 03's tool registration includes `ai_tier`)
- Decisions log: `Docs/decisions_log.md` (Tier 3 = Anthropic Claude EU/zero-retention; Tier 2 = operator hardware)

## Phase Goal

Define the three AI tiers as canonical code constants and build the routing decision that maps a tool's declared `ai_tier` (from Block 03 Phase 03) to the actual model that will serve the call. After this phase, every AI invocation has an unambiguous tier assignment that the rest of the gateway pipeline depends on.

## Dependencies

- Block 03 Phase 03 (tool registration; tools declare `ai_tier` here)

## Deliverables

- **Tier constants:**
  - `TIER_1_NONE` — no AI; deterministic logic only.
  - `TIER_2_LOCAL_LLM` — local model on the operator's dedicated hardware (Stage 1 decision); operator-controlled environment over a private channel (Phase 06). This controlled boundary is what justifies Tier 2's less-restrictive redaction defaults in Phase 03.
  - `TIER_3_EXTERNAL_LLM` — Anthropic Claude via the EU-residency / zero-retention endpoint.
- **Routing decision function:**
  - `routeAICall(toolDeclaration, callContext) → TierAssignment`.
  - Inputs: the tool's declared `ai_tier`, the calling phase, the workflow run id, the business id, and any per-business tier override.
  - Output: `TierAssignment` carrying `tier`, `model_id`, `prompt_version` (looked up via Phase 04), `routing_reason`.
- **Per-business tier configuration:**
  - Default: all three tiers enabled.
  - Per-business override: a business may opt out of Tier 3 entirely (the call is rejected at routing rather than redacted-and-sent).
  - Configuration stored in a `business_ai_config` table; updated via Owner action with audit. **Phase 08 extends this same table with the cost-ceiling columns** so all per-business AI policy lives in one row per business.
- **Tier escalation policy:**
  - Routing is **explicit, not silent**: a Tier 2 call that returns low confidence does not auto-escalate to Tier 3 inside the gateway. The calling phase decides whether to retry at Tier 3 with an explicit second invocation.
  - This preserves Block 01 Principle 3 (AI assists, rules decide) — AI tier choice is never opaque.
- **Block-Tier-3 path:**
  - When a business has opted out of Tier 3, any tool whose declared tier is `EXTERNAL_LLM` returns a structured `TIER_BLOCKED` error from `routeAICall`. The calling phase decides whether to fall back to Tier 2, surface a review issue, or skip the operation.
- **Audit events:** `AI_TIER_ROUTED` (every route, including Tier 1), `AI_TIER_BLOCKED` (per-business opt-out hit), `AI_TIER_CONFIG_UPDATED` (Owner change).

## Definition of Done

- Tier constants are exported and used by every AI call site.
- `routeAICall` correctly returns the tier matching the tool's declared `ai_tier`.
- A business with Tier 3 opt-out causes Tier-3 calls to return `TIER_BLOCKED`.
- Owner can update the per-business config; the change is audit-logged.
- Tests cover happy-path routing, opt-out blocking, missing tool declaration, malformed config.

## Sub-doc Hooks (Stage 4)

- **Tier definition sub-doc** — exact constants, what each represents, when to use which.
- **Routing decision sub-doc** — full decision tree, including per-business config lookup and the absence of silent escalation.
- **`business_ai_config` schema sub-doc** — table shape, default values, update API.
- **Tier escalation policy sub-doc** — when an explicit Tier 3 retry is appropriate, who decides, how the audit trail captures both calls.
