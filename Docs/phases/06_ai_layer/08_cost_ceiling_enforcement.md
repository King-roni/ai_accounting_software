# Block 06 — Phase 08: Cost Ceiling Enforcement

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Cost Control & Caching section)
- Decisions log: `Docs/decisions_log.md` (soft ceiling per workflow run — warn at threshold, allow override)

## Phase Goal

Implement the soft cost ceiling per workflow run: warn the user as the run approaches the threshold and pause the phase (with a review issue) when the ceiling is hit, allowing override after step-up authentication. After this phase, AI cost is an observable, controllable dimension of every run rather than a back-end surprise.

## Dependencies

- Phase 07 (per-run AI cost aggregation)
- Block 03 Phase 04 (state machine — pausing at the ceiling routes through `transitionRun` to `REVIEW_HOLD`)
- Block 03 Phase 05 (gates — the ceiling check runs inside the gateway as a soft pre-call gate)
- Block 02 Phase 06 (step-up auth required for override)

## Deliverables

- **Per-business ceiling configuration** — extends `business_ai_config` (introduced in Phase 01) with the cost-ceiling columns:
  - `default_ceiling_per_run` (numeric, currency)
  - `warning_threshold_pct` (default 80)
  - `currency` (default `EUR`)
  - `tier_2_gating_enabled` (boolean, default `false` — opt-in to gating Tier 2 alongside Tier 3)
  - `updated_at`, `updated_by`
  - Owner can update via a settings UI; updates are audit-logged.
- **Pre-call ceiling check** inside `gateway.invokeAI`:
  - **Cache hits (Phase 09) bypass this check entirely** — projected cost is 0 and the cached `AIResult.SUCCESS` is returned without consulting the ceiling. Phase 09's cache lookup runs strictly before this gate.
  - Before dispatching a Tier 3 call (cache miss), sum the run's current Tier 3 cost from Phase 07's aggregation (`getRunAIUsage` filtered to `cache_hit = false`). If `tier_2_gating_enabled` is true on the business config, include Tier 2 in the sum; otherwise Tier 2 is tracked but not gated.
  - If projected new total < warning threshold → proceed silently.
  - If projected new total ≥ warning threshold AND < ceiling → emit `AI_COST_WARNING` (one per run; deduplicated), proceed.
  - If projected new total ≥ ceiling → do **not** dispatch. Emit `AI_COST_CEILING_HIT`, surface a review issue in Block 14 (severity `HIGH`), and transition the run to `REVIEW_HOLD` per Block 03's state machine.
- **Override flow:**
  - User clicks "Continue past AI cost ceiling" in the review queue.
  - Step-up auth required (Block 02 Phase 06; this surface is in Block 06's sensitive-surface list).
  - User selects a continuation amount (default: extend ceiling by another full ceiling's worth for this run only, or set a custom higher value).
  - Override audit-logged with reason text.
  - The run transitions from `REVIEW_HOLD` back to `RUNNING` and the held phase resumes.
- **One-time-per-run override:**
  - Once override is used, additional ceiling hits within the same run only require step-up (no full review issue), to keep closeout flowing once the user has accepted the cost.
- **Audit events:** `AI_COST_CONFIG_UPDATED`, `AI_COST_WARNING`, `AI_COST_CEILING_HIT`, `AI_COST_OVERRIDE_REQUESTED`, `AI_COST_OVERRIDE_GRANTED`, `AI_COST_OVERRIDE_DENIED`.

## Definition of Done

- A run that crosses 80% of the per-business ceiling on a Tier 3 call emits exactly one `AI_COST_WARNING` and proceeds.
- A run that would cross the ceiling on a Tier 3 call does not dispatch; the phase pauses; a review issue appears in Block 14.
- An Owner with step-up can override; the run resumes and the override is audit-logged.
- A second ceiling hit in the same run after override only requires step-up, not a full review issue.
- Per-business ceiling updates take effect on the next run start; in-flight runs use the ceiling captured at start.
- Tests cover: warning, ceiling hit, override, post-override second hit, configuration update.

## Sub-doc Hooks (Stage 4)

- **Default ceiling values sub-doc** — initial defaults, calibration approach against early production data, per-business override guidance.
- **Cost-projection sub-doc** — how the pre-call check estimates the cost of the call about to be made (lookup in `tier_3_pricing` for the chosen prompt's typical token count + a safety margin).
- **Override UX sub-doc** — review-queue card layout, step-up modal, continuation-amount picker.
- **Tier 2 gating sub-doc** — when a business should opt-in, how the Tier 2 cost compares to the ceiling for budget hygiene purposes.
