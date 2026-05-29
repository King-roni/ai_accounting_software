# Tool AI Tier Metadata

**Category:** Reference data · **Owning block:** 03 — Workflow Engine · **Co-owner:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 1 reference)

How the AI tier flows from a registered tool through Block 03's invocation framework into Block 06's gateway authorization scope. Every tool with AI-tier `LOCAL` or `EXTERNAL` binds to this contract. Tools with tier `NONE` carry the field for completeness; the gateway is bypassed.

This sub-doc unifies the contract between Block 03 Phase 03 (Tool registration framework) and Block 06 Phase 01 (Tier classification & routing).

---

## The 3 tier values

Per `tool_naming_convention_policy` Section 4, closed enum:

| Tier | Meaning |
| --- | --- |
| `NONE` | No AI invocation in this tool's call path |
| `LOCAL` | May invoke Tier 2 (locally-operated machine) |
| `EXTERNAL` | May invoke Tier 3 (Anthropic Claude EU/zero-retention) |

Tier is the **maximum** reachable tier. A tool that typically runs `LOCAL` but escalates to `EXTERNAL` on low confidence declares `EXTERNAL` — the gateway's authorization scope must cover both code paths.

## Where tier metadata flows

```
1. Tool registration (Block 03 Phase 03)
   engine.registerTool({ ai_tier: "EXTERNAL", ... })
                              ↓
2. Tool invocation (Block 03 Phase 06)
   Tool's invocation record carries ai_tier_declared
                              ↓
3. AI Gateway entry (Block 06 Phase 02)
   Gateway reads declared tier, applies authorization scope
                              ↓
4. Tier routing (Block 06 Phase 01)
   Routing decision: NONE → bypass; LOCAL → Tier 2; EXTERNAL → may go Tier 2 or Tier 3
                              ↓
5. Audit (audit_log_policies)
   AI_GATEWAY_INVOKED with { tool_name, declared_tier, dispatched_tier }
```

## Wrapping tools

A tool that wraps a downstream AI-invoking tool but does not itself invoke AI declares `NONE`. The downstream tool carries its own tier declaration. Example (per Block 09 Phase 09 fix):

| Tool | Declared tier | Rationale |
| --- | --- | --- |
| `out_workflow.upload_invoice` | NONE | Wrapper — the AI invocation lives in `intake.ocr_and_extract` |
| `intake.ocr_and_extract` | EXTERNAL | The actual AI-tier-bearing tool |
| `intake.manual_upload_handler` | NONE | Wrapper; AI calls happen in downstream `intake.ocr_and_extract` |

The pattern enforces single-source-of-truth: only the tool that actually invokes the gateway declares the tier. Wrappers are NONE.

## Per-invocation override (`business_ai_config`)

Per Block 06 Phase 01, the per-business `business_ai_config` table can downgrade a tool's effective tier at runtime:

| Configuration | Effect on EXTERNAL tools | Effect on LOCAL tools |
| --- | --- | --- |
| `external_ai_disabled = true` | Downgrade to LOCAL; if tool can't operate at LOCAL, fail with `AI_TIER_UNAVAILABLE` | Unaffected |
| `tier_2_gating_enabled = true` | Cost ceiling check fires before Tier 2 dispatch (per Block 06 Phase 08) | Same |
| `external_ai_disabled = true` AND `tier_2_disabled = true` | Tool fails with `AI_TIER_UNAVAILABLE` (no AI at all) | Tool fails with `AI_TIER_UNAVAILABLE` |

Downgrade never **widens** — a `LOCAL`-declared tool can never run as `EXTERNAL` at runtime. Configuration only narrows.

## Audit interaction

| Event | When | Payload |
| --- | --- | --- |
| `AI_GATEWAY_INVOKED` | Every gateway entry | `{ tool_name, declared_tier, dispatched_tier, prompt_name, prompt_version }` |
| `AI_TIER_ESCALATED` | LOCAL escalates to EXTERNAL within an invocation chain | `{ tool_name, escalation_reason, low_confidence_score }` |
| `AI_TIER_UNAVAILABLE` | Tool can't run because `business_ai_config` disables required tier | `{ tool_name, declared_tier, business_id, reason }` |
| `AI_CACHE_HIT` | Cache hits replace the gateway invoke event per Block 06 Phase 02 | (no tier-routing fields; cache short-circuits before dispatch) |

`dispatched_tier ≠ declared_tier` is normal:
- `dispatched_tier = NONE` on cache hit (no dispatch)
- `dispatched_tier = LOCAL` for an EXTERNAL-declared tool whose first attempt succeeded at Tier 2

## Lint rules

1. Every `engine.registerTool` call declares `ai_tier` as one of `NONE` / `LOCAL` / `EXTERNAL` (no other strings)
2. A tool that contains a call to `gateway.invoke()` MUST declare `LOCAL` or `EXTERNAL`. Static analysis catches `NONE`-declared tools that contain `gateway.invoke()` and fails the build
3. A tool that declares `LOCAL` MUST NOT call the `Tier 3` dispatch path directly (the gateway handles routing per Phase 01)
4. The wrapper / wrapped relationship is captured in the tool's `dependencies` list (Block 03 Phase 03 registration); static analysis enforces that a `NONE`-declared wrapper has at least one non-NONE-declared dependency

## Schema

The `tool_registry` table (per Block 03 Phase 03) carries:

```sql
ai_tier         tool_ai_tier_enum NOT NULL,
CREATE TYPE tool_ai_tier_enum AS ENUM ('NONE', 'LOCAL', 'EXTERNAL');
```

The `ai_usage_records` table (per Block 06 Phase 07) carries:

```sql
declared_tier   tool_ai_tier_enum NOT NULL,
dispatched_tier tool_ai_tier_enum NOT NULL,
cache_hit       boolean NOT NULL DEFAULT false,
```

## Cross-references

- `tool_naming_convention_policy` — AI tier declaration in `engine.registerTool` call shape
- `audit_log_policies` — `AI_*` event naming convention
- `business_ai_config_schema` (Block 06) — per-business runtime configuration
- `ai_usage_records_schema` (Block 06) — usage record structure
- `gateway_pipeline_ordering_policy` (Block 06) — pipeline position of tier routing
- `gateway_bypass_detection_policy` (Block 06 / 07) — guard against bypassing the gateway
- Block 03 Phase 03 — tool registration framework
- Block 06 Phase 01 — tier classification & routing
- Block 06 Phase 02 — gateway pipeline

---

## Escalation path when a lower tier fails

A tool that declares `EXTERNAL` may attempt Tier 2 (LOCAL) first if the lower tier can satisfy the prompt (e.g., a smaller model handles routine classification before reaching for Tier 3). When Tier 2 fails or produces a low-confidence result, the tool escalates to Tier 3 automatically — the gateway handles the routing decision.

The escalation chain:

```
NONE tier: no AI invocation at all; if the tool returns an error, the calling phase
           handles it as a regular tool failure (no gateway involvement)

LOCAL tier: invoke Tier 2 machine
           → on success: return result; emit AI_GATEWAY_INVOKED with dispatched_tier = LOCAL
           → on Tier 2 failure (timeout, capacity, model error):
               if business_ai_config.external_ai_disabled = true → fail with AI_TIER_UNAVAILABLE
               otherwise → emit AI_TIER_ESCALATED; invoke Tier 3 (EXTERNAL path)

EXTERNAL tier: may invoke Tier 2 first (cost-saving path) then fall through to Tier 3
               on Tier 3 failure → no further escalation; fail with AI_TIER_UNAVAILABLE
```

`AI_TIER_ESCALATED` payload includes the reason for escalation (`timeout`, `low_confidence_score`, `capacity_error`) and the score that triggered escalation (for `low_confidence_score` cases). This supports cost analysis: how often does Tier 2 fail and force Tier 3 invocations?

A LOCAL-declared tool CANNOT escalate to EXTERNAL even on failure — the declaration is a ceiling. A LOCAL tool that fails at Tier 2 fails the tool entirely and bubbles the error to the calling phase.

---

## Cost-ceiling interaction rules

Block 06 Phase 08 maintains per-business monthly AI cost ceilings. When a tool invocation is about to dispatch to Tier 2 or Tier 3, the gateway checks whether the dispatch would exceed the ceiling.

| Scenario | Gateway behavior |
| --- | --- |
| Ceiling not yet reached | Dispatch proceeds; cost is estimated and reserved |
| Ceiling would be reached but not exceeded by this invocation | Dispatch proceeds; a `AI_COST_CEILING_APPROACHING` warning event is emitted |
| Ceiling would be exceeded by this invocation | Dispatch is blocked; `AI_TIER_UNAVAILABLE` is returned with `reason = COST_CEILING_REACHED`; the tool fails |
| Ceiling is reached mid-run (a concurrent invocation pushed it over) | The next dispatch attempt in the same run sees the exceeded state; blocked with the same error |

When the ceiling is reached mid-run, the workflow run transitions to `REVIEW_HOLD` with a `Needs Confirmation` issue explaining that AI-assisted steps could not complete. The bookkeeper must either wait until the next billing month, increase the ceiling (Owner/Admin action in business settings), or manually complete the steps the AI was assisting.

The monthly cost counter resets on the 1st of each calendar month at 00:00 UTC. Runs in progress at reset time continue uninterrupted; the new month's ceiling applies to new dispatches after reset.

---

## Per-tier latency budget

These are the P50 / P95 targets Block 03 uses when deciding whether a gateway invocation is within the workflow's overall time budget.

| Tier | Operation | P50 | P95 | P99 |
| --- | --- | --- | --- | --- |
| NONE | No dispatch (pass-through) | < 1 ms | < 5 ms | < 10 ms |
| LOCAL (Tier 2) | LLM inference, short prompt (< 1,000 tokens) | 400 ms | 1.5 s | 4 s |
| LOCAL (Tier 2) | LLM inference, medium prompt (1,000–5,000 tokens) | 1 s | 4 s | 10 s |
| EXTERNAL (Tier 3, Anthropic) | Claude inference, typical classification prompt | 1.5 s | 5 s | 12 s |
| EXTERNAL (Tier 3, Document AI) | OCR + extraction, single-page document | 2 s | 6 s | 15 s |
| Cache hit (any tier) | Response served from `ai_response_cache` | < 20 ms | < 50 ms | < 100 ms |

Latency targets inform gate-timeout settings. A gate that depends on a Tier 3 invocation must budget ≥ P95 + retry margin. Cache hits short-circuit the dispatch and the latency budget is effectively zero.

---

## Cross-references (extended)

- `ai_gateway_schema` — gateway record structure, `ai_usage_records` table columns, cost fields
- `business_ai_config_schema` — per-business ceiling, tier-disable flags, monthly reset behavior
