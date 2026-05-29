# Block 06 — Phase 09: AI Cache (Within Run)

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Cost Control & Caching section)
- Decisions log: `Docs/decisions_log.md` (cache by input hash within a run; no cross-run cache in MVP)

## Phase Goal

Build the within-run AI cache: identical Tier 2 / Tier 3 calls inside the same workflow run return the cached response without re-invoking the model. After this phase, repeated supplier-name normalizations or repeated invoice-extraction calls on the same input cost zero additional model spend within a run, while still being recorded in the run's audit trail and usage logs.

## Dependencies

- Phase 02 (gateway pipeline — cache check sits inside the pipeline)
- Phase 07 (usage logging — cache hits are logged distinctly)
- Block 03 Phase 07 (resumability + dedup-key pattern — same primitive shape)
- Block 04 Phase 06 (Processing zone — cache rows live here and are pruned with the run)

## Deliverables

- **`ai_cache` table** in the operational schema (lives logically with the Processing zone):
  - `id` (UUID v7), `organization_id`, `business_id`, `workflow_run_id`
  - `cache_key` (SHA-256 over `tool_name` + `prompt_id` + `prompt_version` + canonical JSON of the input — produced by Block 04 Phase 01's helpers)
  - `tool_name`, `prompt_id`, `prompt_version`
  - `response` (JSONB — the validated typed `AIResult.SUCCESS` payload only; non-success responses are not cached)
  - `hit_count`, `last_hit_at`, `created_at`
  - Unique constraint on `(workflow_run_id, cache_key)`.
- **Cache lookup inside the gateway pipeline:**
  - Inserted **after redaction (step 3) and before routing (step 4) and dispatch (step 5)** of Phase 02's pipeline. On a cache hit, both routing and dispatch are skipped — the cached `AIResult.SUCCESS` is returned directly.
  - The cache lookup also runs **before Phase 08's pre-call cost-ceiling check**, so cache hits never count toward the ceiling.
  - On hit: return the cached `AIResult.SUCCESS`, increment `hit_count`, set `last_hit_at`, emit `AI_CACHE_HIT`. **`AI_GATEWAY_INVOKED` is NOT emitted on a hit** (same pattern as Block 03 Phase 07's `WORKFLOW_TOOL_DEDUP_HIT`).
  - On miss: continue the pipeline normally (routing → dispatch → output validation). After a successful call, write the cache row and emit `AI_CACHE_STORED`.
- **Scope rules:**
  - **Per-run only** (Stage 1 decision). No cross-run cache in MVP.
  - Cache rows are tenanted via `organization_id` + `business_id` and bound to a single `workflow_run_id`.
- **Lifecycle:**
  - Cache rows are pruned with the run's other Processing-zone artefacts (Block 04 Phase 06's TTL policy: 24 hours after `FINALIZED`, 30 days after failure).
  - Legal hold (Block 04 Phase 11) defers the prune.
- **Cache key invariants:**
  - Different `prompt_version` for the same input produces a different cache key (so a prompt update doesn't return stale results).
  - Different redaction policy version produces a different cache key — `policy_version` is included in the hash so a redaction-policy change invalidates the cache automatically.
- **Usage-log linkage:**
  - On cache hit, an `ai_usage_records` row is still produced (Phase 07) with `validation_outcome = SUCCESS`, `cost_estimate = 0`, `cache_hit = true`. This keeps the usage log complete and lets the cost ceiling check honor cache hits transparently.
- **Audit events:** `AI_CACHE_HIT`, `AI_CACHE_STORED`, `AI_CACHE_PRUNED`.

## Definition of Done

- A repeated identical call inside the same run returns the cached response and emits `AI_CACHE_HIT` (not `AI_GATEWAY_INVOKED`).
- A different `prompt_version` for the same input bypasses the cache and dispatches.
- Two different runs do not share cache entries (verified by test).
- Cache rows are pruned after the run finalizes per Block 04 Phase 06's TTL.
- Cache hits produce a `cost_estimate = 0` row in `ai_usage_records`.
- Failed calls (any `validation_outcome` other than `SUCCESS`) are not cached.

## Sub-doc Hooks (Stage 4)

- **Cache key derivation sub-doc** — exact serialization, included fields, why `policy_version` is in the key.
- **Cache pruning sub-doc** — interaction with Block 04 Phase 06's TTL policy and Phase 11's legal hold.
- **Hit-rate observability sub-doc** — metrics for cache effectiveness, alert on near-zero hit rate (which would suggest cache-key over-specification).
- **Cross-run cache (post-MVP) sub-doc** — design space for promoting stable normalizations (e.g., supplier-name canonicalization) to a cross-run cache, with the prompt-versioning invalidation that's needed.
