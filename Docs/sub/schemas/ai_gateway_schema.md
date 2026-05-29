# ai_gateway_schema

**Category:** Schemas · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `ai_invocation_records` table, which stores one row per AI gateway call routed through `gateway.invokeAI`. The table is the authoritative metadata record for every invocation regardless of tier. No prompt payloads, input text, or model responses are stored here; those live in the Processing zone per `data_layer_conventions_policy`. This table records cost-attribution metadata, operational status, and the structural facts needed for cost tracking, audit, and debugging.

---

## Table definition

```sql
CREATE TYPE ai_tier_enum AS ENUM (
  'LOCAL',
  'EXTERNAL'
);

CREATE TYPE ai_invocation_status_enum AS ENUM (
  'SUCCESS',
  'FAILED',
  'TIMEOUT',
  'RATE_LIMITED'
);

CREATE TABLE ai_invocation_records (
  invocation_id          uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id            uuid          NOT NULL REFERENCES business_entities(id),
  workflow_run_id        uuid          REFERENCES workflow_runs(id),        -- nullable; some invocations occur outside a run
  phase_name             text          NOT NULL,
  tool_name              text          NOT NULL,                             -- the workflow tool that triggered this invocation
  ai_tier                ai_tier_enum  NOT NULL,
  model_identifier       text          NOT NULL,                             -- e.g. 'claude-sonnet-4-6', 'local-llm-v1'
  prompt_template_ref    text          NOT NULL,                             -- reference to the prompt template used, per prompt_management_policies
  input_token_count      integer       NOT NULL CHECK (input_token_count >= 0),
  output_token_count     integer       NOT NULL CHECK (output_token_count >= 0),
  latency_ms             integer       NOT NULL CHECK (latency_ms >= 0),
  redacted_before_send   boolean       NOT NULL DEFAULT true,                -- whether PII redaction ran on the input payload
  response_cached        boolean       NOT NULL DEFAULT false,               -- true when the gateway returned a cached response per ai_cache_within_run
  status                 ai_invocation_status_enum NOT NULL,
  error_class            text,                                               -- populated when status != 'SUCCESS'; maps to AIResult error variant names
  created_at             timestamptz   NOT NULL DEFAULT now()
);
```

### Column notes

- `invocation_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing; suitable for time-range queries on the hot path.
- `business_id` — non-nullable. Even invocations occurring outside a workflow run are scoped to a business. RLS enforces tenant isolation using this column.
- `workflow_run_id` — nullable FK to `workflow_runs.id`. Set when the gateway call is triggered from within a workflow phase. Null for out-of-band invocations (e.g., the end-scan engine Phase 11 running between scheduled runs).
- `phase_name` — the workflow phase name string as declared at registration time. Free text; no FK; mirrors the phase name in the workflow engine.
- `tool_name` — must conform to the `<block_short_name>.<action>` pattern per `tool_naming_convention_policy`. The tool that triggered the gateway call. Not a FK — the tool registry holds the canonical record; this column is a metadata snapshot.
- `ai_tier` — `LOCAL` for Tier 2 invocations (local LLM, Block 06 Phase 06); `EXTERNAL` for Tier 3 invocations (Anthropic Claude, Block 06 Phase 05). Tier 1 (deterministic) calls never reach the gateway and produce no row.
- `model_identifier` — the exact model identifier string as returned by the tier integration. For Anthropic Claude, this is the API-reported model name (e.g., `claude-sonnet-4-6`). For the local LLM, it is the model name registered in Block 06 Phase 06. Stored at invocation time; not updated if the model identifier changes later.
- `prompt_template_ref` — the string key referencing the prompt template in the prompt library. Per `prompt_management_policies`, no generative prompts are constructed at runtime; all prompts are from the fixed library. This column records which template was used.
- `input_token_count` / `output_token_count` — token counts as reported by the model or estimated by the gateway for cost tracking (Block 06 Phase 07). Both are non-negative integers.
- `latency_ms` — wall-clock latency from gateway dispatch to first-byte response completion, in milliseconds.
- `redacted_before_send` — boolean indicating whether the PII redaction engine (Block 06 Phase 03) ran on this invocation's input payload. Per `redaction_policies`, redaction is mandatory for all `EXTERNAL` tier invocations. `LOCAL` tier invocations follow the same policy. This flag being `false` is an anomaly that triggers `AI_PRIVACY_GATEWAY_BYPASS_DETECTED`.
- `response_cached` — `true` when the gateway returned a cached result per the within-run AI cache (Block 06 Phase 09). When `true`, `latency_ms` reflects the cache lookup latency, not model latency.
- `error_class` — populated when `status != SUCCESS`. Maps to the `AIResult` variant names: `SCHEMA_VIOLATION_INPUT`, `SCHEMA_VIOLATION_OUTPUT`, `REDACTION_REJECTED`, `TIER_BLOCKED`, `MODEL_ERROR`, `TIMEOUT`, `RATE_LIMITED`. Null on success.

---

## Payload storage policy

No prompt input text, model response text, or extracted payload content is stored in this table. The Processing zone (per `data_layer_conventions_policy`) is the only location where in-flight AI payload data may reside, and only for the duration of the workflow run. This table stores operational metadata only.

This separation is intentional and non-negotiable. Storing prompt content in the operational database would create a PII-in-at-rest risk for any field that was redacted before transmission but whose pre-redaction value could be inferred from the prompt context. The gateway's privacy guarantee depends on payloads being ephemeral. Any proposal to add a `prompt_snapshot` or `response_snapshot` column requires a security review and a `decisions_log.md` amendment before it can proceed.

---

## Cost attribution

The `ai_invocation_records` table is the primary source for per-business, per-run AI cost attribution. Block 06 Phase 07 aggregates `(input_token_count + output_token_count)` across invocations grouped by `(business_id, workflow_run_id)` to produce cost summaries. The `model_identifier` and `ai_tier` columns allow the cost estimator to apply the correct per-token pricing from the cost-ceiling configuration (Block 06 Phase 08).

Cache hits (`response_cached = true`) contribute zero model cost. The row is still inserted with `input_token_count` and `output_token_count` set to the values that would have been incurred without a cache — this allows cost-comparison analysis (cost avoided by caching) while keeping `latency_ms` accurate for the cache-path timing.

---

## RLS

```sql
CREATE POLICY ai_invocation_records_isolation ON ai_invocation_records
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Tenant isolation by `business_id`. Out-of-band invocations with a `business_id` remain scoped to that business. There is no cross-business read path.

---

## Indexes

```sql
-- Cost tracking and run-level queries
CREATE INDEX idx_ai_invocations_run
  ON ai_invocation_records (workflow_run_id, created_at)
  WHERE workflow_run_id IS NOT NULL;

-- Business-scoped usage history
CREATE INDEX idx_ai_invocations_business_time
  ON ai_invocation_records (business_id, created_at);

-- Failed invocation monitoring
CREATE INDEX idx_ai_invocations_failed
  ON ai_invocation_records (business_id, status, created_at)
  WHERE status != 'SUCCESS';
```

---

## Mobile write rejection

This table is written exclusively by the `ai` gateway internals running server-side. No client or mobile write path exists for `ai_invocation_records`. Any write attempt originating from a mobile client is rejected per `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `AI_INVOCATION_COMPLETED` | Invocation row inserted with `status = SUCCESS` | LOW |
| `AI_INVOCATION_FAILED` | Invocation row inserted with `status` in `{FAILED, TIMEOUT, RATE_LIMITED}` | MEDIUM |

Both events are emitted via `emitAudit()` per `audit_log_policies`. The `AI_INVOCATION_FAILED` event payload includes `error_class`, `model_identifier`, `tool_name`, and `latency_ms` to support operational alerting. Existing AI domain events (`AI_GATEWAY_INVOKED`, `AI_GATEWAY_REJECTED`, `AI_TIER_ESCALATED`, etc.) remain the primary gateway-level events; `AI_INVOCATION_COMPLETED` and `AI_INVOCATION_FAILED` are the record-level events scoped to this table's lifecycle.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; no payload storage in this table; Processing zone rule
- `tool_naming_convention_policy` — `tool_name` must satisfy `<block_short_name>.<action>` pattern; `ai.*` namespace for gateway tools
- `audit_log_policies` — `AI_*` domain; `<DOMAIN>_<PAST_VERB>` naming; per-business chain
- `audit_event_taxonomy` — `AI_INVOCATION_COMPLETED`, `AI_INVOCATION_FAILED`, `AI_GATEWAY_INVOKED`, `AI_TIER_ESCALATED`
- `redaction_policies` — governs `redacted_before_send`; bypass detection
- `tool_ai_tier_metadata` (Block 03 / Block 06) — tier declaration on the calling tool; maps to `ai_tier` here
- `prompt_management_policies` (Block 06 Phase 04) — prompt template library; `prompt_template_ref` format
- Block 06 Phase 02 — privacy gateway pipeline; `gateway.invokeAI` entry point
- Block 06 Phase 05 — Tier 3 Anthropic Claude integration
- Block 06 Phase 06 — Tier 2 local LLM integration
- Block 06 Phase 07 — AI usage logging and cost tracking; primary consumer of token count columns
- Block 06 Phase 09 — within-run AI cache; governs `response_cached`
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
