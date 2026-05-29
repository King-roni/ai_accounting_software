# Classification Confidence Policy

**Block:** Classification
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

Every classification result produced by the AI model or the rules engine carries a confidence score in the range `[0.0, 1.0]`. This score represents the model's certainty that a transaction belongs to the assigned category. This policy defines how the platform interprets that score, what actions are taken at each confidence band, and how the rules engine and vendor memory interact with model-generated scores.

The goal of this policy is to maximize the share of transactions that are classified without human intervention while ensuring that uncertain classifications do not silently degrade the accuracy of the ledger. Thresholds are calibrated to produce a false-positive rate below 2% on known transaction types.

## Confidence Score Definition

A confidence score is a float in `[0.0, 1.0]`:

- `1.0` — the engine is certain (typically a matched classification rule with `confidence_override = 1.0`).
- `0.90–0.99` — very high confidence. Model assigns this when features are strongly aligned with a single category.
- `0.85–0.89` — high confidence. Model assigns this when features predominantly align but there is some ambiguity.
- `0.70–0.84` — moderate confidence. Features partially align; one or more competing categories have meaningful probability mass.
- `< 0.70` — low confidence. The model cannot reliably assign a category from available features.

Scores are stored in `classification_output_schema.md` at the `ai_classification_results.confidence` column, and in `confidence_score_schema.md` for the structured output envelope.

## Default Threshold

The default auto-accept threshold is **0.85**.

This value is stored in `business_settings.classification_confidence_threshold` (see `business_settings_schema.md`). Business owners and accountants can raise this threshold (to require higher confidence before auto-accept) but cannot lower it below **0.80**. The platform minimum of 0.80 is enforced at the API layer and cannot be overridden by per-business configuration.

## Behaviour by Confidence Band

### Band 1: ≥ 0.90 — Auto-Accept with Vendor Memory Confirmation

**Condition:** `confidence >= 0.90` AND vendor memory confirms the classification for this vendor (i.e. `vendor_memory.category_id` matches the proposed category).

**Action:**
- Classification is applied immediately via `tool_classification_apply.md`.
- No review issue is created.
- Transaction advances in the workflow without human involvement.
- Audit event `CLASSIFICATION_APPLIED` (LOW) is emitted.

**Condition (no vendor memory):** `confidence >= 0.90` AND no vendor memory entry exists for this vendor.

**Action:**
- Classification is applied immediately.
- No review issue is created.
- Vendor memory is created or incremented via `tool_vendor_memory_increment.md` so the next transaction from this vendor benefits from memory.

### Band 2: 0.85–0.89 — Auto-Accept, Flagged for Optional Review

**Condition:** `0.85 <= confidence < 0.90`.

**Action:**
- Classification is applied immediately.
- A review issue is created with severity LOW and status `INFORMATIONAL`. This issue does not block workflow progression.
- The issue appears in the review queue under the "Classification" group, filtered as optional.
- Accountants who review the queue will see this issue and can override if the classification is wrong.
- Audit event `CLASSIFICATION_APPLIED` (LOW) is emitted.

The optional review flag exists because the 0.85–0.89 band has a higher observed correction rate than the ≥0.90 band. Flagging without blocking preserves throughput while giving reviewers visibility.

### Band 3: 0.70–0.84 — NEEDS_REVIEW

**Condition:** `0.70 <= confidence < 0.85` (or `< business_settings.classification_confidence_threshold` if threshold was raised above 0.85).

**Action:**
- Classification is NOT applied automatically.
- A review issue is created with severity MEDIUM and status `OPEN`.
- The issue is placed in the review queue and must be resolved before the transaction can advance.
- Workflow run transitions to `REVIEW_HOLD` if one or more transactions are in this state.
- The transaction remains in `PENDING_CLASSIFICATION` status until a reviewer accepts or overrides.
- Audit event `CLASSIFICATION_APPLIED` (LOW) is emitted only after a human resolves the issue (the event records the final applied category and the source as `MANUAL_REVIEW`).

### Band 4: < 0.70 — MANUAL_REQUIRED (BLOCKING)

**Condition:** `confidence < 0.70`.

**Action:**
- Classification is NOT applied.
- A review issue is created with severity HIGH and a BLOCKING flag.
- The workflow run cannot advance past the classification phase while BLOCKING issues are open.
- The BLOCKING flag means the issue cannot be snoozed or deferred; it must be resolved (accepted, overridden, or explicitly rejected with a documented exception).
- Audit event `CLASSIFICATION_APPLIED` (LOW) is emitted only after resolution, with source `MANUAL_REQUIRED_RESOLVED`.

BLOCKING issues of this type prevent `tool_finalization_gate_check.md` from passing. See `finalization_gate_sql_schema.md` for the SQL predicate.

## Vendor Memory Influence

When a transaction's vendor is recognized in `vendor_memory` (see `vendor_memory_schema.md`), the effective confidence used for band evaluation is:

```
effective_confidence = min(1.0, model_confidence + 0.05)
```

The +0.05 bonus applies only when:
1. `vendor_memory.category_id` matches the proposed category from the model.
2. `vendor_memory.match_count >= 3` (at least three confirmed transactions for this vendor in this category).
3. Vendor memory is not flagged as stale (see `vendor_memory_staleness_policy.md`).

The bonus is recorded in the classification output envelope so it is auditable. It does not modify the stored model confidence — it only affects the band evaluation.

## Rule Engine Override

When a classification rule matches a transaction (see `classification_rule_schema.md`), the rule's `confidence_override` value is used in place of the model confidence:

- If `confidence_override IS NOT NULL`: the rule-provided value replaces the model score entirely. This means a rule with `confidence_override = 1.0` always auto-accepts, regardless of model output.
- If `confidence_override IS NULL`: the rule confirms the category but does not alter the model confidence. The model confidence still determines the band.

System rules (`is_system = true`) shipped with the platform use `confidence_override = 1.0` for well-defined transaction patterns (e.g. bank charges, payroll runs). User-created rules should not use `confidence_override` unless the rule is highly specific and the business owner accepts the risk of suppressing review.

Rule matching is evaluated before the model's band logic. If a rule matches, the standard band evaluation below does not apply unless `confidence_override IS NULL`.

## Model Fallback (AI Unavailable)

If the AI classification service is unavailable (circuit breaker open, timeout, or model error):

- The rules engine runs alone.
- Transactions matched by a rule receive `confidence = 1.0` (from the rule) and are treated as Band 1.
- Transactions not matched by any rule receive `confidence = 0.0` and fall into Band 4 (MANUAL_REQUIRED, BLOCKING).
- The fallback state is recorded in `ai_classification_results.fallback_reason`.
- A platform alert is raised via `alert_schema.md` with severity HIGH so operators are aware that AI classification is degraded.

No transaction is silently left unclassified. The rules engine always produces a definitive outcome (matched or unmatched).

## Confidence Degradation

If the observed correction rate for a business's auto-accepted classifications rises above 5% in a 30-day rolling window, the platform triggers the confidence degradation runbook:

- See `classification_confidence_drop_runbook.md` for step-by-step response.
- The threshold for auto-accept may be raised automatically as a precautionary measure.
- Affected classification rules are flagged for review.

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `CLASSIFICATION_APPLIED` | LOW | Emitted when a classification is applied to a transaction, whether automatically or after human review. Payload includes `category_id`, `confidence`, `effective_confidence`, `source` (MODEL, RULE, MANUAL_REVIEW, MANUAL_REQUIRED_RESOLVED), `vendor_memory_applied` (bool). |
| `CLASSIFICATION_MANUAL_OVERRIDE_SET` | LOW | Emitted when a reviewer overrides the model's proposed category with a different one. Payload includes original `proposed_category_id`, `proposed_confidence`, `override_category_id`, `reviewer_id`. |

## Related Documents

- `classification_rule_schema.md` — rule table DDL and confidence_override column
- `classification_confidence_drop_runbook.md` — response to degraded accuracy
- `vendor_memory_schema.md` — vendor memory structure
- `vendor_memory_staleness_policy.md` — when vendor memory entries expire
- `classification_confidence_output_schema.md` — structured confidence output envelope
- `review_queue_policy.md` — how review issues are routed and resolved
- `finalization_gate_sql_schema.md` — gate predicate that blocks on BLOCKING issues
- `business_settings_schema.md` — per-business threshold configuration
- `tool_classification_apply.md` — tool that writes the classification to the transaction
- `tool_ai_classify.md` — tool that calls the AI model and returns confidence
