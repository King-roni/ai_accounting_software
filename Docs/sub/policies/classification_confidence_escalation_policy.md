# Classification Confidence Escalation Policy

**Block:** AI Classification
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

Every AI classification result carries a confidence score in the range `[0.0, 1.0]`. This policy governs what happens at each confidence tier: which results are accepted automatically, which are flagged for optional review, and which are escalated to `REVIEW_HOLD`. It also defines the override flow available to reviewers, how overrides are logged in `classification_override_log`, and how confirmed corrections feed back into the AI training pipeline.

The three-tier threshold structure is fixed at the platform level. Per-business configuration may raise the auto-accept threshold above `0.90` but cannot lower any tier below its floor. Confidence scores below `0.70` always escalate to `REVIEW_HOLD` regardless of business settings.

---

## Confidence Tiers

### Tier 1: ≥ 0.90 — Auto-Accept

**Condition:** `ai_classification_results.confidence >= 0.90`

**Behaviour:**
- The proposed VAT category and account code are written to the transaction immediately via `tool_classification_apply.md`.
- No review issue is created.
- The run continues without interruption.
- Audit event `AI_CLASSIFICATION_ACCEPTED` (LOW) is emitted with `source = AUTO_ACCEPT`.
- Vendor memory is incremented via `tool_vendor_memory_increment.md` so future transactions from the same vendor benefit from accumulated signal.

A vendor memory bonus of `+0.05` (see `classification_confidence_policy.md`) may push a Tier 2 result into Tier 1. When the bonus is applied, the `classification_output_schema.md` envelope records both `model_confidence` and `effective_confidence` so the promotion is auditable.

### Tier 2: 0.70–0.89 — Flag for Review

**Condition:** `0.70 <= ai_classification_results.confidence < 0.90`

**Behaviour:**
- The classification is NOT applied automatically.
- A review issue is created in the review queue with severity MEDIUM and status `OPEN`.
- The issue group is `CLASSIFICATION_REVIEW`.
- The workflow run transitions to `REVIEW_HOLD` if one or more transactions reach this state.
- The transaction remains in `PENDING_CLASSIFICATION` until a reviewer accepts or overrides.
- Audit event `AI_CLASSIFICATION_ACCEPTED` (LOW) is emitted only after the reviewer confirms the proposed category, with `source = REVIEW_CONFIRMED`.

Tier 2 results that are confirmed by a reviewer without modification are treated as implicit positive signals for the training pipeline: the confirmed result is exported alongside overrides (see Training Feedback section below).

### Tier 3: < 0.70 — Escalate to REVIEW_HOLD (BLOCKING)

**Condition:** `ai_classification_results.confidence < 0.70`

**Behaviour:**
- The classification is NOT applied.
- A review issue is created with severity HIGH and a BLOCKING flag.
- BLOCKING issues cannot be snoozed, deferred, or bypassed by any workflow mechanism.
- The run cannot transition from `REVIEW_HOLD` to `AWAITING_APPROVAL` while a BLOCKING classification issue is open.
- `tool_finalization_gate_check.md` will fail its gate predicate until all BLOCKING issues are resolved.
- Audit event `AI_CLASSIFICATION_ACCEPTED` (LOW) is emitted only after full resolution, with `source = BLOCKING_RESOLVED`.

---

## Interaction with run_status_enum

| Tier | Resulting run_status transition |
|---|---|
| Tier 1 — all transactions | Run remains RUNNING and advances normally |
| Tier 2 — at least one transaction | Run transitions RUNNING → REVIEW_HOLD |
| Tier 3 — at least one transaction | Run transitions RUNNING → REVIEW_HOLD with BLOCKING gate |
| All REVIEW_HOLD issues resolved | Run transitions REVIEW_HOLD → AWAITING_APPROVAL |

A run may carry both Tier 2 and Tier 3 issues simultaneously. The run remains in `REVIEW_HOLD` until every open classification issue is resolved. The BLOCKING predicate is checked first during gate evaluation; a run with any unresolved Tier 3 issue cannot advance even if all Tier 2 issues have been resolved.

Runs in `COMPENSATING` status are not re-evaluated for classification confidence. Compensation rolls back to the state prior to classification; confidence re-evaluation occurs when the run restarts.

---

## Override Flow

When a reviewer disagrees with the AI-proposed category, they invoke `tool_classification_override.md`. The override flow is:

1. Reviewer selects a transaction with a pending classification result in the review queue.
2. Reviewer supplies `override_vat_category`, `override_account_code`, and a mandatory `override_reason`.
3. `tool_classification_override.md` validates that the classification result is in `PENDING_REVIEW` or `ACCEPTED` state.
4. The tool marks the `ai_classification_results` row as `OVERRIDDEN` and writes the new values.
5. The override is recorded in `classification_override_log` (see `classification_override_log_schema.md`).
6. A row is inserted into `ai_training_feedback` (see `ai_training_feedback_schema.md`) with `correction_source = REVIEW_QUEUE_OVERRIDE`.
7. Audit event `AI_CLASSIFICATION_OVERRIDDEN` (MEDIUM) is emitted.
8. The review issue transitions to `RESOLVED`.

Force-accept (reviewer confirms the AI proposal without modification) follows the same path except no `classification_override_log` row is created and the audit event is `AI_CLASSIFICATION_ACCEPTED` with `source = REVIEW_CONFIRMED`.

### Override Permissions

A reviewer must hold the `review_queue:write` permission to perform an override. Platform administrators and accountants with elevated access hold this permission by default. Read-only viewers cannot trigger the override flow.

---

## Override Log

Every override writes one append-only row to `classification_override_log`. The log captures:
- The original AI-proposed category and confidence at the time of override.
- The replacement category chosen by the reviewer.
- The mandatory override reason (free text, non-empty after trim).
- The reviewer identity (`overridden_by → auth.users(id)`).

The log is never updated or deleted. Triggers on the table enforce this at the database level. See `classification_override_log_schema.md` for DDL and trigger definitions.

---

## Feedback Loop to AI Training Pipeline

Human corrections accumulated in `ai_training_feedback` are exported to the AI training pipeline on a scheduled basis. The export:

1. Queries rows where `exported_to_training_at IS NULL`.
2. Strips all PII before export (no counterparty names, no raw transaction descriptions, no business identifiers — only category codes, account codes, and normalised feature vectors).
3. Sets `exported_to_training_at = now()` on exported rows.
4. Delivers the payload to the training pipeline endpoint defined in `business_ai_config_schema.md`.

The training pipeline uses these corrections to fine-tune confidence calibration and to improve category predictions for transaction patterns that have high override rates. Corrections are not applied to the live model immediately; they accumulate until the next scheduled retraining cycle.

If the observed override rate for auto-accepted (Tier 1) classifications rises above 5% in a 30-day window, the `classification_confidence_drop_runbook.md` procedure is triggered automatically.

---

## Audit Events

| Event | Severity | Emitted when |
|---|---|---|
| `AI_CLASSIFICATION_ACCEPTED` | LOW | Classification is applied — auto, review-confirmed, or blocking-resolved |
| `AI_CLASSIFICATION_OVERRIDDEN` | MEDIUM | Reviewer replaces AI-proposed category with a different one |

`AI_CLASSIFICATION_ACCEPTED` payload: `transaction_id`, `business_entity_id`, `run_id`, `category_id`, `account_code`, `confidence`, `effective_confidence`, `source` (AUTO_ACCEPT, REVIEW_CONFIRMED, BLOCKING_RESOLVED).

`AI_CLASSIFICATION_OVERRIDDEN` payload: `transaction_id`, `business_entity_id`, `run_id`, `original_category_id`, `override_category_id`, `original_confidence`, `override_reason`, `reviewer_id`.

Both events are emitted via `emit_audit_api.md` and stored in the audit log per `audit_log_schema.md`.

---

## Related Documents

- `classification_confidence_policy.md` — confidence score definition, vendor memory bonus, rule engine override
- `classification_override_log_schema.md` — DDL and append-only enforcement for override log
- `ai_training_feedback_schema.md` — schema for training feedback rows produced by overrides
- `tool_classification_override.md` — tool that executes the override flow
- `tool_classification_apply.md` — tool that writes auto-accepted classifications
- `tool_finalization_gate_check.md` — gate that blocks runs with open BLOCKING issues
- `review_queue_policy.md` — how classification review issues are routed and resolved
- `classification_confidence_output_schema.md` — envelope that records model_confidence and effective_confidence
- `vendor_memory_schema.md` — vendor memory structure used for Tier 1 promotion
- `audit_event_naming_convention_policy.md` — naming rules for audit events
- `emit_audit_api.md` — audit emission API
