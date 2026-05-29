# Tool: ai.classify

**Block:** AI Classification  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`ai.classify` invokes the AI gateway to classify a batch of transactions against the business's chart of accounts. It accepts up to 50 transaction IDs per call, enforces per-transaction token budgets, applies confidence thresholds to route low-confidence results to the review queue, and falls back to the rules engine when the AI gateway is unavailable. The tool emits `AI_CLASSIFICATION_BATCH_COMPLETED` on every successful batch, regardless of whether individual results met the confidence threshold.

## Tool Signature

**Namespace:** `ai`  
**Action:** `classify`  
**Full name:** `ai.classify`  
**Capability flags:** `WRITES_AUDIT`

## Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| `run_id` | UUID | Yes | The active workflow run to classify transactions for. Must be in `RUNNING` status. |
| `transaction_ids` | UUID[] | Yes | Array of transaction IDs to classify. Max 50 per call. All must belong to the same `run_id`. |
| `model_hint` | TEXT | No | Optional model identifier override (e.g. `gpt-4o`, `claude-3-5-haiku`). When omitted, the gateway selects the model according to the business's AI tier configuration and the current `ai_tier_escalation_policy.md`. |
| `confidence_threshold` | DECIMAL(5,4) | No | Minimum confidence score for a result to be accepted without review. When omitted, the value is read from `business_settings.ai_confidence_threshold`. Allowed range: `0.5000`–`1.0000`. |

## Outputs

The tool returns a `classification_results[]` array. Each element contains:

| Field | Type | Description |
|---|---|---|
| `transaction_id` | UUID | The transaction that was classified. |
| `suggested_category_id` | UUID | FK to `chart_of_accounts.id`. The category the model selected. |
| `confidence` | DECIMAL(5,4) | Model confidence score (0.0000–1.0000). |
| `reasoning_tokens` | INT | Number of tokens consumed for reasoning on this transaction. |
| `model_used` | TEXT | The model identifier that produced this result. |
| `latency_ms` | INT | Wall-clock time in milliseconds the gateway took to respond for this transaction. |
| `below_threshold` | BOOLEAN | True when `confidence < confidence_threshold`. Results with this flag set are routed to the review queue and written as `review_issues` of type `LOW_CONFIDENCE_CLASSIFICATION`. |
| `fallback_used` | BOOLEAN | True when the rules engine was used in place of the AI gateway. |

## Batch Behaviour

The tool processes up to 50 transactions per invocation. When the caller provides more than 50 IDs, the tool returns an `INVALID_INPUT` error immediately — it does not silently truncate. Callers are responsible for chunking larger sets.

Internally the tool builds a single prompt payload containing all transactions in the batch. Each transaction slot is allocated a maximum of 2000 tokens. If the batch would exceed the model's context window after applying the per-transaction budget, the tool splits the payload into sub-batches and issues multiple gateway calls, then merges results before returning.

All transactions in the batch are classified in a single logical operation from the caller's perspective. Partial success is possible: individual transactions whose gateway response cannot be parsed are marked `fallback_used = true` and classified via the rules engine. The batch is still considered successful as long as at least one transaction produces a valid result.

## Token Budget Enforcement

- Maximum tokens per transaction: **2000**
- The budget covers: transaction metadata context, vendor memory context, chart of accounts context, model response
- If vendor memory context for a given counterparty would push a single transaction over 2000 tokens, vendor memory is truncated to the most recent 10 entries
- Token counts are recorded in `ai_classification_results.token_count` per transaction
- Aggregate token usage for the run is accumulated in `ai_usage_run_aggregations`

## Confidence Threshold Routing

When a result's `confidence` is below the effective threshold:

1. The result is still written to `ai_classification_results` with `confidence` recorded accurately.
2. A `review_issues` record of type `LOW_CONFIDENCE_CLASSIFICATION` is created via `review_queue.create_issue`.
3. The transaction is placed in `REVIEW_HOLD` within the run's phase tracker.
4. The classification is not applied to the ledger until the review issue is resolved.

Transactions that clear the threshold are passed directly to `classification.apply` for ledger staging.

## Fallback to Rules Engine

The rules-engine fallback is triggered in these conditions:

- The AI gateway returns HTTP 5xx
- The gateway response cannot be parsed as valid classification output
- The gateway latency exceeds 30 seconds for any single transaction
- The business's `ai_enabled` flag is `false` in `business_ai_config`

When the fallback fires, the tool invokes `classification.run_rules` for the affected transactions. Results produced by the rules engine are written to `ai_classification_results` with `model_used = 'rules_engine'`, `fallback_used = true`, and `confidence = null`.

Fallback results are not subject to the confidence threshold — they are applied directly or routed to the review queue based on the rules engine's own `match_level` output.

## Retry Policy

The tool applies exponential backoff on transient gateway failures:

| Attempt | Delay |
|---|---|
| 1 (initial) | immediate |
| 2 | 2 seconds |
| 3 | 4 seconds |

After 3 failed attempts, the tool falls back to the rules engine for affected transactions. Non-retryable errors (HTTP 400, 401, 403) do not retry.

## Idempotency

The tool is idempotent per `(run_id, transaction_id)`. If `ai_classification_results` already contains a row for a given `(run_id, transaction_id)`, the tool skips re-classification for that transaction and returns the existing result. To force reclassification, the existing row must be explicitly deleted by a service-role operation before re-invoking the tool.

## Audit Events

| Event | Severity | When emitted |
|---|---|---|
| `AI_CLASSIFICATION_BATCH_COMPLETED` | LOW | After the full batch (including any sub-batches and fallbacks) has been processed and results written |

The audit payload includes: `run_id`, `batch_size`, `fallback_count`, `below_threshold_count`, `total_tokens_used`, `model_used`, `latency_ms_p99`.

## Data Written

Results are persisted to `ai_classification_results` (see `ai_classification_result_schema.md`). Each row is in the Processing data zone and is deleted 7 days after the run is finalized, except for rows where `overridden_by IS NOT NULL`, which are promoted to the Operational zone.

## Mobile

`ai.classify` carries the `WRITES_AUDIT` flag. On mobile clients, this tool is available for invocation but the following constraints apply:

- The mobile client must be in an active session with a valid step-up token when the classification batch exceeds 25 transactions, consistent with `step_up_auth_for_workflow_approval_policy.md`.
- The mobile UI surfaces only the `below_threshold` and `fallback_used` summary counts from the result; the full `classification_results[]` array is not rendered inline.
- If network conditions cause the request to time out before the server responds, the mobile client must not retry automatically. Manual retry is initiated by the user from the run's phase detail screen.
- Review issues created by this tool are surfaced in the mobile review queue with the same priority ordering as on desktop.

## Error Codes

| Code | Meaning |
|---|---|
| `INVALID_INPUT` | `transaction_ids` exceeds 50, or contains IDs from a different `run_id` |
| `RUN_NOT_ACTIVE` | The run is not in `RUNNING` status |
| `GATEWAY_UNAVAILABLE` | Gateway failed after retries; fallback was applied |
| `TOKEN_BUDGET_EXCEEDED` | A single transaction's context could not be reduced below 2000 tokens |
| `ALREADY_CLASSIFIED` | All provided IDs already have results; nothing was processed |

## Related Documents

- `ai_classification_result_schema.md` — output table DDL
- `ai_gateway_schema.md` — gateway request/response schema
- `ai_usage_records_schema.md` — per-call token usage records
- `ai_tier_escalation_policy.md` — model selection logic
- `tool_gateway_invoke_ai.md` — low-level gateway invocation tool
- `tool_review_queue_create_issue.md` — review queue issue creation
- `classification_confidence_drop_runbook.md` — operational response to confidence degradation
- `classification_override_log_schema.md` — accountant override records

## Observability

The tool records a `tool_invocations` row for every call (see `tool_invocation_schema.md`). Metric dimensions emitted to the monitoring layer: `run_id`, `batch_size`, `model_used`, `fallback_count`, `p50_latency_ms`, `p99_latency_ms`. Alerting threshold: if `fallback_count / batch_size > 0.5` on any single call, an `alert_schema` record of severity `MEDIUM` is created.
