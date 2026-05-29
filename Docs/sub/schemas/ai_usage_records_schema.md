# ai_usage_records_schema

**Category:** Schemas · **Owning block:** 06 — AI Layer · **Co-owner:** 04 — Data Architecture (retention) · **Stage:** 4 sub-doc (Layer 2)

The persisted per-call record of every AI gateway invocation. One row per `gateway.invokeAI` outcome (success and error alike) per Block 06 Phase 07. The table is the single ground truth for cost, latency, drift, prompt-regression, and per-run aggregation; sibling sub-doc `ai_usage_run_aggregation_schema` defines the per-run rollup view. Consumers: Phase 08 cost-ceiling check, Block 16 reporting, ops dashboards.

---

## Table definition

```sql
CREATE TYPE ai_validation_outcome_enum AS ENUM (
  'SUCCESS',
  'SCHEMA_VIOLATION_INPUT',
  'SCHEMA_VIOLATION_OUTPUT',
  'REDACTION_REJECTED',
  'TIER_BLOCKED',
  'MODEL_ERROR'
);

-- tool_ai_tier_enum is declared once in the tool_registry schema per tool_ai_tier_metadata:
--   CREATE TYPE tool_ai_tier_enum AS ENUM ('NONE', 'LOCAL', 'EXTERNAL');

CREATE TABLE ai_usage_records (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id             uuid NOT NULL REFERENCES organizations(id),
  business_id                 uuid NOT NULL REFERENCES business_entities(id),

  -- Run linkage (nullable for system-level calls outside any workflow)
  workflow_run_id             uuid REFERENCES workflow_runs(workflow_run_id),
  phase_state_id              uuid REFERENCES phase_states(phase_state_id),
  tool_invocation_id          uuid REFERENCES tool_invocations(tool_invocation_id),

  -- Tool + prompt provenance
  tool_name                   text NOT NULL,
  prompt_name                 text,
  prompt_version              text,
  redaction_policy_version    text,

  -- Tier routing (per tool_ai_tier_metadata)
  declared_tier               tool_ai_tier_enum NOT NULL,
  dispatched_tier             tool_ai_tier_enum NOT NULL,
  model_id                    text,

  -- Timing
  started_at                  timestamptz NOT NULL,
  completed_at                timestamptz NOT NULL,
  latency_ms                  integer NOT NULL,

  -- Size + cost (currency in integer minor units per data_layer_conventions_policy)
  input_size_bytes            integer NOT NULL DEFAULT 0,
  output_size_bytes           integer NOT NULL DEFAULT 0,
  input_tokens                integer,
  output_tokens               integer,
  compute_seconds             numeric(10, 3),
  gpu_seconds                 numeric(10, 3),
  cost_eur_cents              integer NOT NULL DEFAULT 0,
  pricing_rate_version        text,

  -- Outcome
  validation_outcome          ai_validation_outcome_enum NOT NULL,
  cache_hit                   boolean NOT NULL DEFAULT false,
  error_kind                  text,
  error_summary               text,

  -- Redaction summary (NEVER the values — only field-path counts)
  redactions_applied          jsonb,

  -- Audit linkage
  gateway_invoked_event_id    uuid,

  -- Internal
  appended_at                 timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CHECK (latency_ms >= 0),
  CHECK (cost_eur_cents >= 0),
  CHECK (input_size_bytes >= 0 AND output_size_bytes >= 0),
  CHECK (completed_at >= started_at),
  CHECK ((cache_hit = false) OR (cost_eur_cents = 0)),
  CHECK ((validation_outcome = 'SUCCESS') OR (error_kind IS NOT NULL)),
  CHECK (
    -- redactions_applied carries counts only, not values; lint-enforced separately
    redactions_applied IS NULL OR jsonb_typeof(redactions_applied) = 'object'
  )
);
```

## ENUM rationale

### `ai_validation_outcome_enum` (6 values)

Mirrors the `AIResult.kind` discriminator from `ai_result_variants_schema`. Adding a seventh outcome requires a `Docs/decisions_log.md` amendment plus a coordinated bump of the union variant set.

### `tool_ai_tier_enum` (3 values)

Declared once in the `tool_registry` table per `tool_ai_tier_metadata`. Reused here for both `declared_tier` and `dispatched_tier`. The runtime invariant: `dispatched_tier ≠ declared_tier` is legitimate (cache hit, runtime downgrade per `business_ai_config`), but `dispatched_tier` is never **higher** than `declared_tier`.

## Column groups

### Run linkage

`workflow_run_id`, `phase_state_id`, `tool_invocation_id` are nullable for system-level calls (e.g., periodic end-scan jobs that don't belong to a user-facing workflow). When non-null, they back the per-run aggregation in `ai_usage_run_aggregation_schema`.

### Provenance

`tool_name` matches `tool_naming_convention_policy`'s `block_short_name.action` pattern. `prompt_name` and `prompt_version` are nullable for calls that short-circuit before prompt selection (e.g., `SCHEMA_VIOLATION_INPUT`). `redaction_policy_version` is nullable when redaction didn't run.

### Cost fields

EUR minor units as integer per `data_layer_conventions_policy` (floats forbidden). `pricing_rate_version` pins the rate table version the estimator used at the time of the call — Tier 3 rates evolve when Anthropic publishes new prices; the version field lets historical rows be re-priced consistently.

Tier 3 cost: `cost_eur_cents = round(input_tokens × input_rate_cents + output_tokens × output_rate_cents)`. Tier 2 cost: `cost_eur_cents = round(compute_seconds / 3600 × hourly_rate_cents)`. Cache hits: `cost_eur_cents = 0`.

### `redactions_applied`

JSONB shape: `{ "field_path_or_kind": count }`. Never the dropped values. Example: `{"transaction.counterparty_iban": 1, "line_items.*.description": 3}`. A repo lint rule `redactions_applied_value_lint` scans for any value-shaped (non-integer) leaf in this JSONB at write time.

### `gateway_invoked_event_id`

The audit event ID emitted by `emitAudit("AI_GATEWAY_INVOKED", ...)` (or `AI_GATEWAY_REJECTED` / `AI_CACHE_HIT` per variant). Nullable because audit emission is out-of-band (per `audit_log_policies` Section 4); the gateway records the row first, the audit emit fills the event ID asynchronously.

## RLS

Tenancy-scoped reads; INSERT only via the gateway-bound service role identified by the `app.ai_gateway_active` session variable (same pattern as `redaction_at_write_policy`'s `ai_payload_redacted` table).

```sql
ALTER TABLE ai_usage_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY ai_usage_records_read ON ai_usage_records
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

CREATE POLICY ai_usage_records_insert ON ai_usage_records
  FOR INSERT
  WITH CHECK (
    business_id = ANY (auth.business_ids_for_session())
    AND current_setting('app.ai_gateway_active', true) = 'true'
  );

CREATE POLICY ai_usage_records_no_update ON ai_usage_records
  FOR UPDATE
  USING (false);

CREATE POLICY ai_usage_records_no_delete ON ai_usage_records
  FOR DELETE
  USING (false);
```

Per-role visibility follows `audit_log_policies` Section 2 — Accountant and Reviewer see the `AI` domain summary; full row access is gated by `BUSINESS_SETTINGS_EDIT` for forensic detail. Cost figures are visible on the Block 16 dashboard via aggregated views; raw rows are administrative-only.

## Retention

Per `retention_policies_schema` (Layer 2 sibling, Block 04): default retention is **24 months** rolling from `appended_at`. Rows past the window are deleted by the retention engine unless a legal hold per `legal_hold_policies` applies. Pre-deletion, retention copies the aggregated totals into the per-run summary on `workflow_runs` so historical cost figures survive row purge.

The 24-month window is shorter than the operational 6-year archive retention because raw per-call records are observational; the audit trail (`AI_USAGE_RECORDED` events) lives in the audit log under its own 6-year window per `audit_log_policies`.

## Cache-hit semantics

When `cache_hit = true`:
- `cost_eur_cents = 0` (enforced by CHECK)
- `model_id`, `input_tokens`, `output_tokens`, `compute_seconds`, `gpu_seconds` are inherited from the original cached call (the gateway propagates these for observability)
- `dispatched_tier` reflects the original call's dispatched tier
- `validation_outcome = 'SUCCESS'`
- The audit event is `AI_CACHE_HIT` (not `AI_GATEWAY_INVOKED`) per Block 06 Phase 02

## Audit events

| Event | When | Payload sketch |
| --- | --- | --- |
| `AI_GATEWAY_INVOKED` | INSERT with `validation_outcome IN ('SUCCESS', 'SCHEMA_VIOLATION_OUTPUT', 'MODEL_ERROR')` AND `cache_hit = false` | `{ tool_name, declared_tier, dispatched_tier, prompt_name, prompt_version }` |
| `AI_GATEWAY_REJECTED` | INSERT with `validation_outcome IN ('SCHEMA_VIOLATION_INPUT', 'REDACTION_REJECTED', 'TIER_BLOCKED')` | `{ tool_name, declared_tier, error_kind }` |
| `AI_CACHE_HIT` | INSERT with `cache_hit = true` | `{ tool_name, original_invocation_id, cached_at }` |
| `AI_USAGE_RECORDED` | INSERT (any) | `{ ai_usage_record_id, validation_outcome, cost_eur_cents }` |
| `AI_PAYLOAD_REDACTED` | Co-emitted by the gateway when redaction ran | Per `redaction_at_write_policy` |

The four events are written as separate transactions per `audit_log_policies` emit-as-separate-transaction rule.

## Indexes

```sql
CREATE INDEX idx_ai_usage_records_business_time
  ON ai_usage_records(business_id, appended_at DESC);

CREATE INDEX idx_ai_usage_records_run
  ON ai_usage_records(workflow_run_id, dispatched_tier)
  WHERE workflow_run_id IS NOT NULL;

CREATE INDEX idx_ai_usage_records_business_run_tier_cost
  ON ai_usage_records(business_id, workflow_run_id, dispatched_tier, cost_eur_cents)
  WHERE cache_hit = false;

CREATE INDEX idx_ai_usage_records_drift
  ON ai_usage_records(business_id, prompt_name, prompt_version, validation_outcome)
  WHERE validation_outcome <> 'SUCCESS';

CREATE INDEX idx_ai_usage_records_model_perf
  ON ai_usage_records(model_id, started_at)
  WHERE validation_outcome = 'SUCCESS';
```

- `business_time` supports the audit-tape and dashboard recent-activity queries
- `run` supports the per-run cost rollup consumed by Phase 08 (`getRunAIUsage`)
- `business_run_tier_cost` is the hot index backing the cost-ceiling pre-call check (per `ai_usage_run_aggregation_schema`)
- `drift` supports prompt-regression analysis: count of non-SUCCESS outcomes per `(prompt_name, prompt_version)` over time
- `model_perf` supports latency-per-model dashboards and SLO tracking

## Mobile

The gateway is server-side only; no client form factor reaches this table directly. The cost-ceiling override surface (`ai.override_cost_ceiling`) is desktop-only per `mobile_write_rejection_endpoints` — mobile cannot trigger the writes that bypass the ceiling.

## Cross-references

- `data_layer_conventions_policy` — UUID v7 IDs, EUR-minor-units integer cents, JSONB shape rules
- `tool_ai_tier_metadata` — `declared_tier` / `dispatched_tier` semantics, `tool_ai_tier_enum`
- `audit_log_policies` — `AI_GATEWAY_*` / `AI_USAGE_*` event family, separate-transaction emission
- `redaction_at_write_policy` — sibling table `ai_payload_redacted`; shared `app.ai_gateway_active` write-gate pattern
- `ai_result_variants_schema` — `AIResult.kind` ↔ `validation_outcome` mapping
- `ai_usage_run_aggregation_schema` — per-run rollup view
- `retention_policies_schema` (Block 04) — 24-month retention window
- `mobile_write_rejection_endpoints` — cost-ceiling override is desktop-only
- Block 06 Phase 02 — gateway pipeline (architecture)
- Block 06 Phase 07 — usage logging (architecture)
- Block 06 Phase 08 — cost ceiling consumer
