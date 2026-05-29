# AI Tier Escalation Policy

**Category:** Policies · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

This policy defines when the AI gateway changes the tier used for an invocation, in which direction, and under what constraints. Tier changes affect cost, latency, and — in the case of cost-ceiling downgrades — the quality of the result returned to the caller. All tier changes are auditable.

---

## Purpose

The platform runs AI at three tiers of increasing capability and cost. Automatic escalation allows cheaper tiers to handle most cases while preserving access to more capable models for ambiguous inputs. Downgrade rules prevent uncapped cost accumulation. This policy is the binding authority for any code that reads or writes the tier selection path inside `ai.invoke`.

---

## Tier definitions

| Tier | Class | Typical model class | Approximate use cases |
| --- | --- | --- | --- |
| `TIER_1` | Fast / low cost | Haiku-class | High-confidence classification, simple extraction, vendor memory lookups |
| `TIER_2` | Balanced | Sonnet-class | Moderate-confidence decisions, multi-field extraction, VIES context reasoning |
| `TIER_3` | High capability | Opus-class | Low-confidence complex classification, plain-language narrative generation, ambiguous ledger decisions |

The specific model identifiers bound to each tier are configured in `ai_tier_rates` within `ai_gateway_schema`. This policy references tiers abstractly; model-identifier changes do not require a policy amendment.

---

## Auto-escalation: confidence-based

Confidence scores are returned in the model response payload within the `output` object. The prompt schema for each `prompt_key` declares whether a `confidence` field is present. For prompts that include confidence, the following thresholds apply:

| Condition | Action |
| --- | --- |
| Tier 1 response has `confidence < 0.65` | Escalate to Tier 2; discard tier 1 output |
| Tier 2 response has `confidence < 0.70` | Escalate to Tier 3; discard tier 2 output |
| Tier 3 response (any confidence) | No further escalation; tier 3 is the ceiling |

When a tier's response has `confidence >= threshold`, that response is returned without escalation, regardless of the `tier_hint` in the original call.

For prompts that do not include a `confidence` field (e.g., pure generative prompts), confidence-based escalation does not apply. The tier used is determined solely by `tier_hint`, `tier_override`, and cost-ceiling rules.

Each escalation is a separate, complete invocation — the higher tier receives the same `input_payload` as the original attempt. Tier 1 and tier 2 outputs from unsuccessful attempts are not forwarded to the next tier.

### Audit event: `AI_TIER_ESCALATED`

**Severity:** LOW

Emitted once per escalation step. If a single call escalates from tier 1 → 2 → 3, two `AI_TIER_ESCALATED` events are emitted.

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `invocation_sequence_id` | uuid | A shared ID linking all escalation attempts within one logical invocation |
| `from_tier` | text | The tier that returned low confidence |
| `to_tier` | text | The tier dispatched next |
| `from_confidence` | numeric | The confidence score that triggered the escalation |
| `threshold` | numeric | The threshold that was not met (0.65 or 0.70) |
| `prompt_key` | text | The prompt identifier |
| `business_id` | uuid | Tenant context |
| `run_id` | uuid | Workflow run context |

---

## Manual override: `tier_override`

When `business_ai_config.tier_override` is non-null, it replaces automatic tier selection entirely. No confidence-based escalation occurs.

| `tier_override` | Escalation permitted | Downgrade permitted |
| --- | --- | --- |
| `TIER_1` | No | N/A (already at floor) |
| `TIER_2` | No | Yes (cost ceiling: TIER_2 → TIER_1) |
| `TIER_3` | No | Yes (cost ceiling: TIER_3 → TIER_1) |
| `NULL` | Yes (per confidence rules) | Yes (cost ceiling rules apply) |

Override changes are logged via `BUSINESS_UPDATED` at the business entity level. There is no separate AI-specific event for override changes; the field diff in `BUSINESS_UPDATED` is the record.

---

## Cost-ceiling downgrade

When `business_ai_config.spend_current_month_usd >= monthly_cost_ceiling_usd`:

- Tier 3 invocations are silently downgraded to tier 1.
- Tier 2 invocations are silently downgraded to tier 1.
- Tier 1 invocations proceed unchanged.

The downgrade is applied before the escalation logic. An invocation that would have escalated to tier 3 due to low confidence is downgraded to tier 1 at dispatch time and is not escalated regardless of the tier 1 confidence score. The ceiling represents a hard stop on cost, not a soft preference.

"Silently" means no error is raised to the caller. The `tier_used` field in the `ai.invoke` response reflects the actual tier used. The caller may observe that `tier_used` is lower than `tier_hint`; this is not an error condition.

### Audit event: `AI_TIER_DOWNGRADED_COST_CEILING`

**Severity:** HIGH

HIGH because a cost-ceiling downgrade means the business is receiving lower-capability AI results than it would otherwise. This may affect classification accuracy and requires operator awareness.

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `business_id` | uuid | The business whose ceiling is active |
| `requested_tier` | text | The tier that would have been used without the ceiling |
| `effective_tier` | text | The tier actually used (`TIER_1`) |
| `spend_usd` | text | Current `spend_current_month_usd` at downgrade time (decimal string) |
| `ceiling_usd` | text | The `monthly_cost_ceiling_usd` (decimal string) |
| `prompt_key` | text | The prompt identifier |
| `run_id` | uuid | Workflow run context |

`AI_TIER_DOWNGRADED_COST_CEILING` is not deduplicated per invocation — it fires on every invocation that is downgraded. The `AI_COST_CEILING_REACHED` event (from `business_ai_config_schema`) fires once at the moment the ceiling is first crossed. These two events serve different purposes: `AI_COST_CEILING_REACHED` is a threshold notification; `AI_TIER_DOWNGRADED_COST_CEILING` is an operational signal per affected invocation.

---

## Escalation cooldown: REVIEW_HOLD trigger

If a single workflow run accumulates 3 consecutive tier-3 escalations, the run is placed into `REVIEW_HOLD`. The counter tracks escalations to tier 3 within the same `run_id`, resetting at the start of each run and at each non-tier-3 invocation.

"Consecutive" means 3 tier-3 escalations in unbroken sequence with no tier-1 or tier-2 completion between them. A tier-1 or tier-2 result (with `confidence >= threshold`) between escalations resets the counter.

When the counter reaches 3:

1. `ai.invoke` emits `AI_ESCALATION_HOLD_TRIGGERED` before returning the tier-3 result.
2. The workflow engine detects the event and transitions the run to `REVIEW_HOLD`.
3. The run remains in `REVIEW_HOLD` until a reviewer resolves or dismisses the review issue created by the hold.

The tier-3 result from the 3rd escalation is still returned to the caller — the hold is non-blocking for the current invocation but blocks subsequent tool invocations in the run.

### Audit event: `AI_ESCALATION_HOLD_TRIGGERED`

**Severity:** HIGH

HIGH because a run in `REVIEW_HOLD` requires human intervention to proceed.

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `run_id` | uuid | The workflow run being held |
| `business_id` | uuid | Tenant context |
| `consecutive_tier3_count` | integer | Always 3 at trigger time |
| `last_prompt_key` | text | The prompt key of the 3rd escalating invocation |
| `hold_run_status_before` | text | The run status before transitioning to `REVIEW_HOLD` |

---

## Escalation counter state

The escalation counter is maintained in memory within the current workflow engine phase execution context — it is not persisted to the database between phase executions. If the engine restarts or a run is resumed from `PAUSED`, the counter resets to 0 for the resumed phase. This is an intentional trade-off: persisting the counter per run adds schema complexity for a guard that is effective within a single continuous execution window.

---

## Interaction summary

| Condition | Tier result |
| --- | --- |
| `tier_override = TIER_1` | TIER_1, no escalation |
| `tier_override = TIER_2` | TIER_2, no escalation |
| `tier_override = TIER_3`, ceiling not reached | TIER_3 |
| `tier_override = TIER_3`, ceiling reached | TIER_1 (downgraded) |
| `tier_override = NULL`, tier_hint = TIER_1, confidence >= 0.65 | TIER_1 |
| `tier_override = NULL`, tier_hint = TIER_1, confidence < 0.65, ceiling OK | TIER_2 |
| `tier_override = NULL`, tier_hint = TIER_1, confidence < 0.65, ceiling reached | TIER_1 (downgraded) |
| `tier_override = NULL`, tier 2 confidence < 0.70, ceiling OK | TIER_3 |
| `tier_override = NULL`, tier 2 confidence < 0.70, ceiling reached | TIER_1 (downgraded) |

---

## Cross-references

- `tool_gateway_invoke_ai.md` — `ai.invoke` tool that implements this policy
- `business_ai_config_schema.md` — `monthly_cost_ceiling_usd`, `spend_current_month_usd`, `tier_override` columns
- `ai_gateway_schema.md` — `ai_tier_rates`, `ai_invocation_records` tables
- `audit_event_taxonomy.md` — canonical entries for `AI_TIER_ESCALATED`, `AI_TIER_DOWNGRADED_COST_CEILING`, `AI_ESCALATION_HOLD_TRIGGERED`
- Block 06 AI Layer phase docs — gateway architecture and prompt schema conventions
