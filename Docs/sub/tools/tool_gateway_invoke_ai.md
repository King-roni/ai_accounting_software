# tool: ai.invoke

**Category:** Tools · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

`ai.invoke` is the central AI dispatch function. All AI invocations in the platform route through this tool. It handles tier selection, cache lookup, retry logic, cost tracking, and audit emission. No tool may call an LLM provider directly; all external AI calls must go through `ai.invoke`.

---

## Tool registration

```ts
engine.registerTool({
  name: "ai.invoke",
  schema_version: "1.0",
  side_effect_class: ["EXTERNAL_CALL", "WRITES_AUDIT"],
  ai_tier: "EXTERNAL",
  input_schema_ref: "tool_ai_invoke#v1.input",
  output_schema_ref: "tool_ai_invoke#v1.output",
  audit_events: [
    "AI_INVOCATION_COMPLETED",
    "AI_INVOCATION_FAILED",
    "AI_INVOCATION_RETRY_ATTEMPTED",
    "AI_CACHE_HIT",
  ],
  description_ref: "Docs/sub/tools/tool_gateway_invoke_ai.md",
});
```

`ai.invoke` is `EXTERNAL_CALL` because it calls the LLM provider API. It is not `WRITES_RUN_STATE` — it never writes to `workflow_runs` or other run-state tables. The `WRITES_AUDIT` class covers the four audit events it emits.

---

## Signature

```ts
ai.invoke({
  prompt_key:     string,          // registered prompt identifier (e.g. "classification.layer3_decide")
  prompt_version: string,          // semver string matching a row in ai_prompts (e.g. "2.1")
  input_payload:  object,          // the prompt variable bindings; must match the prompt's input schema
  business_id:    string,          // UUID v7 — the tenant context for cost tracking
  run_id:         string,          // UUID v7 — the workflow run context for audit trail
  tier_hint?:     "TIER_1" | "TIER_2" | "TIER_3",  // optional preference; not a guarantee
}) → {
  output:     object,              // the model's structured response, parsed per the prompt's output schema
  tier_used:  "TIER_1" | "TIER_2" | "TIER_3",
  tokens_used: number,             // total tokens (input + output) for cost calculation
  cached:     boolean,             // true if the response came from the AI cache
}
```

The `output` shape is governed by the prompt's output schema registered in `ai_prompts`. Output structure validation is the responsibility of the calling tool.

---

## Tier selection

`tier_hint` is a preference signal, not a binding constraint. The actual tier used is determined by the following priority order:

1. **Cost ceiling check.** If `business_ai_config.spend_current_month_usd >= monthly_cost_ceiling_usd`, tier 3 requests are downgraded to tier 1. This takes precedence over all other signals.
2. **`tier_override` in `business_ai_config`.** If non-null, this value is used. Escalation logic in `ai_tier_escalation_policy` is bypassed.
3. **`tier_hint` from the caller.** Used as the starting tier for the escalation evaluation.
4. **Automatic escalation.** If the tier-1 response has confidence < 0.65, `ai.invoke` escalates to tier 2. If tier 2's confidence is < 0.70, it escalates to tier 3. Full rules are in `ai_tier_escalation_policy`.

When `tier_used` in the response differs from `tier_hint`, the caller should not treat this as an error. The tier difference is logged in `ai_invocation_records` as `requested_tier` vs. `ai_tier`.

---

## Cache hit path

Before dispatching to the LLM provider, `ai.invoke` computes a cache key from:

```
cache_key = SHA-256(canonical_json({ prompt_key, prompt_version, input_payload }))
```

Canonical JSON serialization follows `data_layer_conventions_policy`. The resulting hex digest is looked up in `ai_cache` (see `ai_cache_schema`).

If a cache hit is found and the entry has not expired:

- The cached `output` is returned immediately.
- `tier_used` is the tier that originally produced the cached result.
- `tokens_used` is `0` — no tokens are consumed on a cache hit.
- `cached: true` is set in the return value.
- **No tier spend is recorded** — `business_ai_config.spend_current_month_usd` is not incremented.
- `AI_CACHE_HIT` is emitted with the `cache_key` in the payload.

Cache hits bypass the retry contract, cost ceiling check, and escalation logic entirely.

### Audit event: `AI_CACHE_HIT`

**Severity:** LOW

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `cache_key` | text | The SHA-256 hex digest used as the lookup key |
| `prompt_key` | text | The prompt identifier |
| `prompt_version` | text | The prompt version |
| `business_id` | uuid | Tenant context |
| `run_id` | uuid | Workflow run context |
| `cached_tier` | text | The tier that originally produced the cached entry |

---

## Retry contract

`ai.invoke` retries on transient failures only. Transient failures are:

- HTTP 5xx responses from the LLM provider
- Connection timeouts (threshold: 30 seconds)
- Rate limit responses (HTTP 429) from the provider, with the `Retry-After` header respected

Non-transient failures (HTTP 4xx except 429, schema validation errors on the response, malformed JSON output) are not retried.

**Retry schedule:** up to 2 retries after the initial attempt (3 total attempts). Backoff is exponential with jitter: 1s, then 2–4s (random in range).

On each retry attempt:

- `AI_INVOCATION_RETRY_ATTEMPTED` is emitted before the retry fires.
- The `attempt_number` in the payload identifies which retry this is (1 or 2).

After 3 failed attempts:

- `AI_INVOCATION_FAILED` is emitted.
- `ai.invoke` throws an error to the caller with code `AI_INVOCATION_EXHAUSTED`.
- No `output` is returned.
- No spend is recorded for failed invocations.

### Audit event: `AI_INVOCATION_RETRY_ATTEMPTED`

**Severity:** LOW

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `invocation_id` | uuid | The `ai_invocation_records.id` for this attempt sequence |
| `attempt_number` | integer | 1 for the first retry, 2 for the second |
| `prompt_key` | text | The prompt identifier |
| `tier_attempted` | text | The tier attempted before the failure |
| `error_class` | text | `TIMEOUT`, `PROVIDER_5XX`, or `PROVIDER_RATE_LIMITED` |
| `business_id` | uuid | Tenant context |
| `run_id` | uuid | Workflow run context |

### Audit event: `AI_INVOCATION_FAILED`

**Severity:** MEDIUM

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `invocation_id` | uuid | The `ai_invocation_records.id` |
| `prompt_key` | text | The prompt identifier |
| `prompt_version` | text | The prompt version |
| `tier_attempted` | text | The final tier attempted |
| `error_class` | text | The class of failure that caused exhaustion |
| `attempt_count` | integer | Always 3 (total attempts including the initial) |
| `business_id` | uuid | Tenant context |
| `run_id` | uuid | Workflow run context |

---

## Successful invocation

On a successful LLM provider response: the response is parsed per the prompt's output schema; an `ai_invocation_records` row is inserted with `status = 'SUCCESS'`; the `fn_increment_ai_spend` trigger increments `business_ai_config.spend_current_month_usd`; `AI_INVOCATION_COMPLETED` is emitted (LOW severity). Payload: `invocation_id`, `prompt_key`, `prompt_version`, `tier_used`, `tokens_used`, `cost_usd` (decimal string), `latency_ms`, `business_id`, `run_id`.

---

## Cost tracking

```
cost_usd = tokens_used × tier_rate.cost_per_token_usd
```

`tier_rate` is from `ai_tier_rates` in `ai_gateway_schema`, pinned at invocation time to `ai_invocation_records`. The spend increment is executed by trigger, not by `ai.invoke` directly — spend tracking survives any application-layer failure after the record is written. Cache hits produce no `ai_invocation_records` row and do not trigger the increment.

---

## Side-effect contract summary

| Class | Effect |
| --- | --- |
| `EXTERNAL_CALL` | Calls the LLM provider API (Anthropic Claude or local model endpoint, per tier) |
| `WRITES_AUDIT` | Emits one of: `AI_INVOCATION_COMPLETED`, `AI_INVOCATION_FAILED`, `AI_INVOCATION_RETRY_ATTEMPTED`, `AI_CACHE_HIT` |

`ai.invoke` never writes to `workflow_runs`, `transactions`, `invoices`, or any other run-state table. The `ai_invocation_records` insert is an audit/cost-tracking table owned by Block 06, not a run-state write.

---

## Error codes thrown to callers

| Code | When | Retryable by caller |
| --- | --- | --- |
| `AI_INVOCATION_EXHAUSTED` | All 3 attempts failed | No — caller must handle or trigger REVIEW_HOLD |
| `PROMPT_NOT_FOUND` | `(prompt_key, prompt_version)` not in `ai_prompts` | No — code error |

The cost ceiling causes tier downgrade, not rejection. Blocking AI entirely would halt the workflow run; running on a cheaper tier is always preferable to halting.

---

## Mobile

`ai.invoke` is an internal pipeline tool not exposed as a direct endpoint. Mobile write rejection is enforced at the caller level — the workflow engine rejects mobile clients before invoking `ai.invoke`. This tool itself has no independent mobile exposure per `mobile_write_rejection_endpoints.md`.

## Cross-references

- `business_ai_config_schema.md` — cost ceiling, spend tracking, tier override
- `ai_gateway_schema.md` — `ai_invocation_records`, `ai_prompts`, `ai_tier_rates`, `ai_cache` tables
- `ai_tier_escalation_policy.md` — escalation trigger conditions and cooldown rules
- `ai_cache_schema.md` — cache entry structure, TTL, and eviction policy
- `audit_event_taxonomy.md` — canonical entries for `AI_INVOCATION_COMPLETED`, `AI_INVOCATION_FAILED`, `AI_INVOCATION_RETRY_ATTEMPTED`, `AI_CACHE_HIT`
- `data_layer_conventions_policy.md` — canonical JSON for cache keys; decimal string for currency amounts
- Block 06 AI Layer — gateway phase docs
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy; enforced at the workflow engine caller layer
