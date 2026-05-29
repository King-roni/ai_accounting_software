# Tool: ai.detect_anomalies

**Block:** AI Anomaly Detection  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`ai.detect_anomalies` scans all classified transactions in a workflow run for statistical outliers and pattern breaks. It runs as a post-classification step and does not modify transaction data directly. Results are written to a staging table and, for anomalies that exceed the score threshold, review queue issues are created so accountants can investigate before the run advances to matching. The tool emits `AI_ANOMALY_DETECTION_COMPLETED` upon finishing the scan.

## Tool Signature

**Namespace:** `ai`  
**Action:** `detect_anomalies`  
**Full name:** `ai.detect_anomalies`  
**Capability flags:** `WRITES_AUDIT`

## Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| `run_id` | UUID | Yes | The active workflow run to scan. The run must have completed the classification phase (`run_phase = 'CLASSIFICATION_DONE'`). |
| `sensitivity` | TEXT | Yes | Controls detection thresholds. Accepted values: `'LOW'`, `'MEDIUM'`, `'HIGH'`. Higher sensitivity produces more anomalies at lower score thresholds. Defaults applied per sensitivity level are defined in the score threshold table below. |

## Outputs

The tool returns an `anomalies[]` array. Each element contains:

| Field | Type | Description |
|---|---|---|
| `transaction_id` | UUID | The transaction where the anomaly was detected. |
| `anomaly_type` | TEXT | One of the defined anomaly type codes (see Anomaly Types). |
| `score` | DECIMAL(5,4) | Anomaly score from 0.0000 (no signal) to 1.0000 (strong signal). |
| `description` | TEXT | Human-readable explanation of why this transaction was flagged, suitable for display in the review queue. |
| `suggested_action` | TEXT | One of: `'REVIEW'`, `'IGNORE'`, `'ESCALATE'`. Informational only; does not trigger automated action. |
| `routed_to_review` | BOOLEAN | True when the score exceeded the sensitivity threshold and a review issue was created. |

## Anomaly Types

| Type Code | Description |
|---|---|
| `AMOUNT_OUTLIER` | Transaction amount is more than 3 standard deviations from the vendor's historical mean for this category within this business. |
| `DUPLICATE_VENDOR` | Two or more transactions share the same vendor, same amount, and fall within a 5-day window, suggesting a duplicate payment. |
| `UNUSUAL_TIMING` | Transaction date falls on a weekend, public holiday, or outside the vendor's known operating pattern. |
| `VENDOR_CATEGORY_MISMATCH` | The AI-assigned category differs from the vendor's dominant category in vendor memory by more than one chart level. |
| `ROUND_AMOUNT_PATTERN` | Three or more transactions to the same vendor in the run are round numbers (no cents), suggesting manual entry or fraud pattern. |
| `RAPID_SEQUENCE` | More than five transactions to the same vendor occur within a 24-hour window in the run. |

## Score Threshold by Sensitivity

| Sensitivity | Route-to-review threshold | Description |
|---|---|---|
| `LOW` | 0.8000 | Only high-confidence anomalies create review issues |
| `MEDIUM` | 0.6000 | Balanced — recommended default for most businesses |
| `HIGH` | 0.4000 | Aggressive flagging; expect higher false-positive rate |

The threshold applied is recorded in the audit event payload so reviewers can understand why a particular transaction was or was not routed.

## Execution Timing

`ai.detect_anomalies` is invoked by the workflow orchestrator after `tool_run_advance_phase.md` moves the run from `CLASSIFICATION` to `ANOMALY_DETECTION`. It is not invoked in parallel with `ai.classify` — classification must be fully settled before anomaly detection begins, because several anomaly types depend on the assigned category.

The tool processes all transactions in the run in a single pass. There is no batching limit analogous to `ai.classify`'s 50-item constraint; the tool is designed to handle full run sizes (up to the run's configured transaction limit, typically 5000).

## Behaviour: No Direct Data Modification

This tool does not write to `transactions`, `ai_classification_results`, `ledger_entries`, or any other transaction-of-record table. Its only writes are:

1. Anomaly detection results written to `ai_anomaly_results` (staging table, Processing zone).
2. Review queue issues created via `review_queue.create_issue` for anomalies above threshold.
3. The `AI_ANOMALY_DETECTION_COMPLETED` audit event.

If an accountant dismisses an anomaly in the review queue, the `ai_anomaly_results` row is updated to `dismissed = true` but the transaction itself is unchanged.

## Review Queue Integration

For each anomaly where `score >= threshold`:

1. A `review_issues` record is created with `issue_type = 'ANOMALY_DETECTED'`.
2. The `issue_type_registry_schema.md` entry for `ANOMALY_DETECTED` maps to the `review_queue` with priority derived from the anomaly score: score ≥ 0.9 → `HIGH`; 0.7–0.9 → `MEDIUM`; below 0.7 → `LOW`.
3. The review issue references both the `transaction_id` and the `ai_anomaly_results.id` so the reviewer has full context.
4. The run does not advance to the matching phase until all `HIGH`-priority anomaly issues are resolved. `MEDIUM` and `LOW` issues may be snoozed by the accountant.

## Audit Events

| Event | Severity | When emitted |
|---|---|---|
| `AI_ANOMALY_DETECTION_COMPLETED` | LOW | After the full run scan completes and all review issues are created |

The audit payload includes: `run_id`, `sensitivity`, `total_transactions_scanned`, `anomalies_detected_count`, `routed_to_review_count`, `anomaly_type_breakdown` (a JSON object with counts per type), `duration_ms`.

## Idempotency

If anomaly detection has already run for a given `run_id` (i.e., `ai_anomaly_results` contains rows for the run and the run's phase is `ANOMALY_DETECTION_DONE`), re-invoking the tool returns the existing results without re-scanning. To force a re-scan, the run phase must be reset to `CLASSIFICATION_DONE` by a service-role operation, and existing `ai_anomaly_results` rows for the run must be deleted.

## Mobile

`ai.detect_anomalies` carries the `WRITES_AUDIT` flag. On mobile clients:

- The tool can be invoked from the mobile client when the accountant manually triggers a re-scan from the run detail screen. Automatic orchestrator-triggered invocations originate server-side and are not subject to mobile session constraints.
- The mobile UI surfaces a summary card showing counts per `anomaly_type` and a list of transactions routed to review. The full `anomalies[]` array with raw scores is available on tap.
- The `suggested_action` field is rendered as a chip on each anomaly card: `REVIEW` (blue), `IGNORE` (grey), `ESCALATE` (amber).
- If the mobile client loses connectivity mid-scan, the server-side scan continues independently. The mobile client polls the run's phase status and renders results when the phase transitions to `ANOMALY_DETECTION_DONE`.

## Error Codes

| Code | Meaning |
|---|---|
| `RUN_NOT_IN_CORRECT_PHASE` | The run's current phase is not `CLASSIFICATION_DONE` |
| `INVALID_SENSITIVITY` | `sensitivity` is not one of `LOW`, `MEDIUM`, `HIGH` |
| `NO_CLASSIFIED_TRANSACTIONS` | The run has no transactions in classified state |
| `SCAN_ALREADY_COMPLETE` | Anomaly detection already completed for this run; use re-scan flow to override |

## Related Documents

- `ai_classification_result_schema.md` — classification results consumed as input to detection
- `review_issues_schema.md` — review queue issues created by this tool
- `tool_review_queue_create_issue.md` — issue creation tool invoked internally
- `tool_run_advance_phase.md` — phase advancement that precedes and follows this tool
- `matching_policy.md` — matching phase that follows anomaly detection
- `vendor_memory_schema.md` — vendor history used for AMOUNT_OUTLIER and VENDOR_CATEGORY_MISMATCH detection
- `issue_escalation_policy.md` — governs ESCALATE routing for anomaly issues

## Observability

A `tool_invocations` row is written for every call. Metric dimensions emitted: `run_id`, `sensitivity`, `anomalies_detected_count`, `routed_to_review_count`, `duration_ms`. If `routed_to_review_count / total_transactions_scanned > 0.20`, an `alert_schema` record of severity `MEDIUM` is created to notify the assigned accountant that an unusually high anomaly rate was detected. This may indicate a data quality problem with the uploaded bank statement or a misconfigured sensitivity level.

## Data Retention

`ai_anomaly_results` rows are in the Processing data zone. They are deleted 7 days after the run is finalized. Review issues created from anomaly results are in the Operational zone and follow the standard 7-year retention policy defined in `data_retention_policy.md`.

## Interaction with Vendor Memory

The `AMOUNT_OUTLIER` and `VENDOR_CATEGORY_MISMATCH` anomaly types read from `vendor_memory` to establish baseline expectations. Vendor memory is read-only during anomaly detection. If a business has fewer than 5 historical transactions for a vendor (insufficient baseline), amount outlier detection is skipped for that vendor and `suggested_action` is set to `'IGNORE'` with the description noting the insufficient baseline. This prevents false positives for new vendors.

## Configuration and Tuning

Sensitivity can be overridden at the business level via `business_ai_config.anomaly_sensitivity_default`. When the orchestrator invokes this tool, it reads that setting and passes it as the `sensitivity` parameter. Individual accountants can override sensitivity for a specific run by invoking the tool manually from the run detail screen with a different value; that override is not persisted to `business_ai_config` and applies only to the current run scan.

## Limitations

`ai.detect_anomalies` operates within a single run. It does not perform cross-run anomaly detection (e.g., identifying a pattern spanning multiple monthly runs). Cross-run pattern analysis is handled by the analytics layer and is out of scope for this tool.
