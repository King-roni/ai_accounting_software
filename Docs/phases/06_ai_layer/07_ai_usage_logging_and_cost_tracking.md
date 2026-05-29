# Block 06 — Phase 07: AI Usage Logging & Cost Tracking

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (AI Usage Logging section)

## Phase Goal

Record one structured row per gateway call so cost, latency, drift, and prompt-regression analysis are first-class queryable data. After this phase, every AI call leaves a paper trail with prompt version, tier, model id, redaction count, validation outcome, and a cost estimate — and per-run aggregations are available for Phase 08's cost ceiling and for Block 16's reporting.

## Dependencies

- Phase 02 (gateway emits the event after a call)
- Phase 03 (redaction counts come from this phase)
- Phase 04 (prompt id and version)
- Phase 05, 06 (Tier 3 / Tier 2 integrations supply token counts and latencies)
- Block 05 Phase 02 (audit log emission)

## Deliverables

- **`ai_usage_records` table:**
  - `id` (UUID v7), `organization_id`, `business_id`, `workflow_run_id` (nullable for system-level calls), `phase_state_id` (nullable)
  - `tool_name`, `prompt_id`, `prompt_version`, `policy_version` (redaction policy version per Phase 03)
  - `ai_tier` (`LOCAL_LLM`, `EXTERNAL_LLM`), `model_id`
  - `started_at`, `completed_at`, `latency_ms`
  - `input_size_bytes`, `output_size_bytes`
  - `input_tokens`, `output_tokens` (Tier 3); `compute_seconds`, `gpu_seconds` (Tier 2 — nullable on hardware that doesn't expose the breakdown)
  - `validation_outcome` (`SUCCESS`, `SCHEMA_VIOLATION_INPUT`, `SCHEMA_VIOLATION_OUTPUT`, `REDACTION_REJECTED`, `TIER_BLOCKED`, `MODEL_ERROR`)
  - `redactions_applied` (JSONB — count by `field_kind` + `default_action`; never the values)
  - `cost_estimate`, `cost_estimate_currency` (default `EUR`)
  - `cache_hit` (boolean, default `false`) — `true` when the row was produced by a Phase 09 cache hit; in that case `cost_estimate = 0` and `model_id`, token counts, and compute counts are inherited from the original cached call's row
  - `error_kind`, `error_summary` (nullable; populated on non-success)
- **Cost estimator:**
  - **Tier 3 (Anthropic):** `cost_estimate = input_tokens × input_rate + output_tokens × output_rate`. Rates are sourced from a `tier_3_pricing` table that's updated when Anthropic publishes new rates; rate version is recorded on the row.
  - **Tier 2:** `cost_estimate ≈ (compute_seconds / 3600) × hourly_compute_rate`, where the hourly rate is configurable per business (default reflects amortised hardware + electricity). Fallback estimator uses `latency_ms × constant_per_ms` when GPU-seconds aren't available.
- **Per-run aggregation:**
  - `ai_usage_run_totals` view (or refreshed table): `(workflow_run_id, ai_tier) → (call_count, total_input_tokens, total_output_tokens, total_compute_seconds, total_latency_ms, total_cost_estimate)`.
  - Read API: `getRunAIUsage(workflow_run_id) → AIUsageSummary` consumed by Phase 08 (cost ceiling) and by Block 16 (reporting).
- **RLS** on `ai_usage_records` — tenancy-scoped reads; INSERT only via service role used by the gateway.
- **Audit events:** `AI_USAGE_RECORDED` (one per call), `AI_USAGE_AGGREGATION_REFRESHED`.

## Definition of Done

- Every successful gateway call produces an `ai_usage_records` row with all fields populated correctly.
- Failed calls also produce a row with `validation_outcome` other than `SUCCESS` and a structured `error_kind`/`error_summary`.
- Tier 3 cost estimates are within ±10 % of the corresponding Anthropic billing line for the same period.
- Tier 2 cost estimates use the configurable hourly rate; the fallback estimator works when GPU-seconds are missing.
- `getRunAIUsage` returns accurate per-tier totals for an active run.
- The `redactions_applied` JSONB never contains the redacted values, only counts.

## Sub-doc Hooks (Stage 4)

- **`ai_usage_records` schema sub-doc** — full column types, constraints, retention.
- **Tier 3 pricing table sub-doc** — table shape, update procedure when Anthropic publishes new rates, rate-version semantics.
- **Tier 2 cost model sub-doc** — exact formula, configurable parameters, fallback path when GPU telemetry is absent.
- **Per-run aggregation refresh sub-doc** — view vs materialised table, refresh cadence, query performance.
