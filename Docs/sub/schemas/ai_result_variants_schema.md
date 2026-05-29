# ai_result_variants_schema

**Category:** Schemas · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

The typed return shape from `gateway.invokeAI(toolDeclaration, input) → AIResult` (Block 06 Phase 02). Every caller of the gateway destructures on this discriminated union; static analysis enforces exhaustive matching. The union has six variants — one success, five structured-error outcomes — and every variant carries the same metadata envelope so observability and `ai_usage_records` writes share a single code path. This is the on-the-wire contract between the gateway and the rest of the system.

---

## Discriminated union

`AIResult` is a tagged union on the `kind` discriminator. The TypeScript-ish shape (the language-neutral schema is canonical; TypeScript shown for readability):

```ts
type AIResult =
  | { kind: "SUCCESS";                 output: unknown;     metadata: AIResultMetadata }
  | { kind: "SCHEMA_VIOLATION_INPUT";  error: SchemaError;  metadata: AIResultMetadata }
  | { kind: "SCHEMA_VIOLATION_OUTPUT"; error: SchemaError;  metadata: AIResultMetadata }
  | { kind: "REDACTION_REJECTED";      error: RedactionError; metadata: AIResultMetadata }
  | { kind: "TIER_BLOCKED";            error: TierBlockError; metadata: AIResultMetadata }
  | { kind: "MODEL_ERROR";             error: ModelError;   metadata: AIResultMetadata };
```

The `kind` discriminator is a closed enum. No seventh variant exists; adding one requires a `Docs/decisions_log.md` amendment and a coordinated bump of every gateway consumer.

## `AIResultMetadata` envelope

Present on every variant — success and error alike. The fields are the same regardless of outcome so downstream `ai_usage_records` inserts execute one shared code path.

| Field | Type | Notes |
| --- | --- | --- |
| `tool_name` | string | The registered tool that invoked the gateway (`block_short_name.action` per `tool_naming_convention_policy`) |
| `declared_tier` | `tool_ai_tier_enum` | `NONE` / `LOCAL` / `EXTERNAL` per `tool_ai_tier_metadata` |
| `dispatched_tier` | `tool_ai_tier_enum` | Actual tier that handled the call; may differ from declared per `tool_ai_tier_metadata` |
| `prompt_name` | string \| null | Per `prompt_management_policies` naming; null when the tool short-circuited before prompt selection |
| `prompt_version` | string \| null | Semver `major.minor.patch` per `prompt_management_policies`; null when prompt didn't load |
| `redaction_policy_version` | string \| null | Semver per `redaction_policies`; null when redaction didn't run |
| `cache_hit` | boolean | True iff the result came from Block 06 Phase 09's in-run cache |
| `latency_ms` | integer | Wall-clock duration measured at the gateway entry/exit boundary |
| `cost_eur_cents` | integer | EUR minor units per `data_layer_conventions_policy` currency rule; `0` on cache_hit; `0` on errors raised before dispatch |
| `model_id` | string \| null | The provider-side model identifier (e.g., `claude-3-7-sonnet-2026-04-15`) — null when no dispatch occurred |
| `gateway_invocation_id` | uuid (v7) | The `ai_usage_records.id` value this result will write; generated up-front so caller and audit chain align |
| `started_at` | timestamptz | Gateway entry timestamp |
| `completed_at` | timestamptz | Gateway exit timestamp |

`cost_eur_cents` is the cost-of-this-call only — not the per-run cumulative. Per-run aggregation is `ai_usage_run_aggregation_schema` (sibling sub-doc). Floats are forbidden per the currency rule; the cost estimator (Phase 07) rounds half-to-even to integer cents at the gateway boundary.

## SUCCESS variant

```json
{
  "kind": "SUCCESS",
  "output": { /* validated against the tool's declared output_schema */ },
  "metadata": { "tool_name": "classification.tier_3_classifier", "dispatched_tier": "EXTERNAL", ... }
}
```

`output` is the model's validated response. The gateway runs output-schema validation per Phase 02 step 6 before constructing SUCCESS — any malformed response routes to `SCHEMA_VIOLATION_OUTPUT` instead.

## SCHEMA_VIOLATION_INPUT

Caller passed input that didn't conform to the tool's declared `input_schema`. The gateway short-circuits before redaction, dispatch, and audit; this is a caller-side bug.

```json
{
  "kind": "SCHEMA_VIOLATION_INPUT",
  "error": {
    "violations": [{ "path": "transaction.amount_signed", "expected": "integer", "actual": "string" }],
    "input_schema_ref": "tool_classification_tier_3_classifier#v2.input"
  },
  "metadata": { "dispatched_tier": "NONE", "cost_eur_cents": 0, "model_id": null, ... }
}
```

## SCHEMA_VIOLATION_OUTPUT

The model returned a response that didn't validate against the tool's declared `output_schema`. Per Phase 02's strict-validation principle: no best-effort parsing. The caller decides retry/escalation per Block 03 Phase 08.

```json
{
  "kind": "SCHEMA_VIOLATION_OUTPUT",
  "error": {
    "violations": [...],
    "output_schema_ref": "tool_classification_tier_3_classifier#v2.output",
    "raw_response_excerpt_sha256": "..."
  },
  "metadata": { "dispatched_tier": "EXTERNAL", "cost_eur_cents": 47, ... }
}
```

`raw_response_excerpt_sha256` is the SHA-256 hex per `data_layer_conventions_policy` of the first 1024 bytes of the malformed response — for forensic correlation with provider logs without storing the body.

## REDACTION_REJECTED

Phase 03 redaction failed schema validation after dropping disallowed fields (per `redaction_policies` Section 2). The call never reached the model.

```json
{
  "kind": "REDACTION_REJECTED",
  "error": {
    "redaction_policy_version": "1.4.0",
    "missing_required_field": "transaction.amount_signed",
    "dropped_field_paths": ["transaction.counterparty_iban"]
  },
  "metadata": { "dispatched_tier": "NONE", "cost_eur_cents": 0, ... }
}
```

## TIER_BLOCKED

Per-business `business_ai_config` disabled the tier the tool requires. The call never reached the model.

```json
{
  "kind": "TIER_BLOCKED",
  "error": {
    "declared_tier": "EXTERNAL",
    "blocked_reason": "external_ai_disabled",
    "business_id": "01935f0d-..."
  },
  "metadata": { "dispatched_tier": "NONE", "cost_eur_cents": 0, ... }
}
```

`blocked_reason` is a closed enum: `external_ai_disabled`, `tier_2_disabled`, `cost_ceiling_hit`, `tier_unavailable`. The fourth value carries the case from `tool_ai_tier_metadata` where both tiers are disabled.

## MODEL_ERROR

Transient provider-side error — timeout, rate-limit, 5xx. The caller decides retry per Block 03 Phase 08's retry/escalation rules; the gateway itself does not retry.

```json
{
  "kind": "MODEL_ERROR",
  "error": {
    "provider_status_code": 529,
    "provider_error_code": "OVERLOADED_ERROR",
    "is_retryable": true,
    "retry_after_ms": 5000
  },
  "metadata": { "dispatched_tier": "EXTERNAL", "cost_eur_cents": 0, ... }
}
```

`is_retryable` is computed by the per-tier integration (Phase 05 for Tier 3, Phase 06 for Tier 2). Non-retryable cases — auth failure, permanent provider-side rejection — set `is_retryable = false` and surface via Block 14 as a review issue.

## Validation rules

1. Every `AIResult` carries `metadata.kind ∈ {SUCCESS, SCHEMA_VIOLATION_INPUT, SCHEMA_VIOLATION_OUTPUT, REDACTION_REJECTED, TIER_BLOCKED, MODEL_ERROR}` — no other strings
2. `metadata.declared_tier` and `metadata.dispatched_tier` are members of `tool_ai_tier_enum` (`NONE`, `LOCAL`, `EXTERNAL`)
3. `metadata.cost_eur_cents` is a non-negative integer; never null; never float
4. `metadata.latency_ms` is a non-negative integer; measured at the same boundary regardless of variant
5. `metadata.gateway_invocation_id` is a UUID v7 per `data_layer_conventions_policy`
6. SUCCESS includes `output`; every error variant includes `error`; neither carries both
7. `cache_hit = true` implies `dispatched_tier ∈ {NONE, LOCAL, EXTERNAL}` (whatever the original cached call recorded) AND `cost_eur_cents = 0`

The validator is `validate_ai_result(jsonb) → boolean`, used in tests and in fixture-replay paths. Production gateway code constructs results from typed builders that satisfy the schema by construction.

## Persistence

The `AIResult` itself is NOT a Postgres table. Each invocation is persisted as one row in `ai_usage_records` (per `ai_usage_records_schema`, sibling sub-doc); the `kind` discriminator lands in `ai_usage_records.validation_outcome`. The error payload contents land in `ai_usage_records.error_kind` / `error_summary` (text fields), never the full JSON.

`metadata.gateway_invocation_id` equals `ai_usage_records.id`. Callers receive the ID immediately and can correlate forward without waiting for the persist-write to complete.

## Audit events

| Event | When | Variant |
| --- | --- | --- |
| `AI_GATEWAY_INVOKED` | Successful dispatch reached the model | SUCCESS, SCHEMA_VIOLATION_OUTPUT, MODEL_ERROR |
| `AI_GATEWAY_REJECTED` | Dispatch blocked pre-call | SCHEMA_VIOLATION_INPUT, REDACTION_REJECTED, TIER_BLOCKED |
| `AI_CACHE_HIT` | Cache short-circuit (replaces `AI_GATEWAY_INVOKED` per Phase 02) | SUCCESS with `cache_hit = true` |
| `AI_USAGE_RECORDED` | After every result (success and error) — one per `ai_usage_records` row | All |

All events emit per `audit_log_policies` chain partitioning (per-business chain).

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for `gateway_invocation_id`, EUR-minor-units integer cents, canonical JSON for payloads
- `tool_ai_tier_metadata` — `declared_tier` / `dispatched_tier` semantics
- `prompt_management_policies` — `prompt_name` + `prompt_version` shapes
- `redaction_policies` — `redaction_policy_version` shape and `REDACTION_REJECTED` rationale
- `ai_usage_records_schema` — the persisted row; `gateway_invocation_id` ↔ `ai_usage_records.id`
- `audit_log_policies` — `AI_GATEWAY_*` / `AI_CACHE_*` / `AI_USAGE_*` chain emission
- Block 06 Phase 02 — gateway pipeline (architecture)
- Block 06 Phase 09 — in-run cache (`cache_hit` semantics)
- Block 03 Phase 08 — caller-side retry/escalation on `MODEL_ERROR`
