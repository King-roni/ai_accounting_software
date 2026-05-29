# tool_classification_run.md

**Category:** Tools · Block 08 — Transaction Classification
**Tool:** `classification.run`
**Cross-ref:** classification_rule_schema.md, vendor_memory_schema.md, tag_conflict_resolution_policy.md, ai_tier_escalation_policy.md, mobile_write_rejection_endpoints.md

---

## Overview

`classification.run` executes the full classification pipeline for a batch of bank_statement_rows within a workflow run. It applies deterministic rules first, then vendor memory, then AI fallback tiers in order. Results are written to the transactions table. Transactions that fall below the confidence threshold are added to the review queue.

The tool accepts up to 500 transaction IDs per call. For runs with more transactions, the orchestrator calls the tool in sequential batches.

---

## Classification

| Property | Value |
|---|---|
| Side-effect class | WRITES_RUN_STATE, WRITES_AUDIT |
| Mobile rejection | Yes — mobile clients cannot call classification.run |
| Idempotent | Yes — same idempotency_key is a no-op for already-classified transactions |

Mobile rejection is enforced at the API gateway layer per mobile_write_rejection_endpoints.md.

---

## Input Schema

```json
{
  "run_id":              "uuid (required) — references workflow_runs.id",
  "transaction_ids":     "uuid[] (required) — up to 500 IDs; references bank_statement_rows.id",
  "classification_mode": "enum (required) — RULE_FIRST | AI_FIRST | RULES_ONLY",
  "idempotency_key":     "string (required)"
}
```

| classification_mode | Behaviour |
|---|---|
| RULE_FIRST | Rules → vendor memory → AI tiers (default production mode) |
| AI_FIRST | AI tier 1 → rules fallback for overrides → vendor memory update |
| RULES_ONLY | Rules and vendor memory only; no AI calls |

---

## Pipeline Steps

### Step 1 — Deterministic Rule Engine

The rule engine from classification_rule_schema.md is applied to each transaction. Rules are evaluated in priority order. The first matching rule assigns a tag and marks classification_source = 'RULE'.

Transactions with a rule match skip Steps 2 and 3.

### Step 2 — Vendor Memory

For transactions not matched by a rule, `classification.vendor_memory_apply` is called. Vendor memory stores past human-confirmed classifications keyed on vendor name normalisation (per vendor_memory_schema.md). A vendor memory hit assigns classification_source = 'VENDOR_MEMORY'.

Transactions matched by vendor memory skip Step 3.

### Step 3 — AI Fallback (RULE_FIRST and AI_FIRST modes)

Remaining unclassified transactions are sent to the AI tier pipeline:

| Tier | Escalation trigger |
|---|---|
| AI_TIER_1 | Default; used first for all unclassified transactions |
| AI_TIER_2 | Escalated if AI_TIER_1 confidence < low_confidence_threshold |
| AI_TIER_3 | Escalated if AI_TIER_2 confidence < low_confidence_threshold |

Tier thresholds and escalation rules are defined in ai_tier_escalation_policy.md. Each tier call is logged with the model version used. classification_source is set to AI_TIER_1, AI_TIER_2, or AI_TIER_3 accordingly.

---

## Result Storage

For each transaction, the result is written to transactions.classification_result as a jsonb column:

```json
{
  "tag":                  "string — the assigned classification tag",
  "confidence_score":     "number 0.0–1.0",
  "classification_source":"RULE | VENDOR_MEMORY | AI_TIER_1 | AI_TIER_2 | AI_TIER_3",
  "rule_id":              "uuid | null — populated if classification_source = RULE"
}
```

---

## Conflict Resolution

If multiple sources assign different tags to the same transaction, the priority chain from tag_conflict_resolution_policy.md is applied:

1. Human override (highest priority)
2. RULE
3. VENDOR_MEMORY
4. AI_TIER_1
5. AI_TIER_2
6. AI_TIER_3 (lowest priority)

The winning tag is written to classification_result. The losing sources and their tags are preserved in classification_result.conflict_log for audit purposes.

---

## Review Queue

Transactions where the winning confidence_score falls below the configured review threshold are created as CLASSIFICATION_REVIEW issues in the review queue. The review queue entry references the transaction_id and the classification_result so the reviewer sees what was proposed.

The confidence threshold is configurable per business (stored in in_run_config_schema.md). Default: 0.75.

---

## Idempotency

If called with the same idempotency_key and the transactions already have classification_result populated:

1. The tool returns the stored output counts.
2. No re-classification occurs.
3. No new review issues are created.
4. No audit events are emitted.

Idempotency window: 24 hours.

---

## Output Schema

```json
{
  "classified_count":       "integer — transactions assigned a tag",
  "unclassified_count":     "integer — transactions that remain unclassified after all steps",
  "review_issues_created":  "integer — new review queue entries created"
}
```

unclassified_count > 0 does not fail the tool call. The orchestrator checks this value and may trigger a REVIEW_HOLD state on the run if unclassified_count exceeds a configured threshold.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| CLASSIFICATION_RUN_COMPLETED | LOW | Tool completes without error; written once per batch call |
| CLASSIFICATION_AI_FALLBACK_USED | LOW | At least one transaction was classified via an AI tier |

---

## Run State Side Effects

- transactions.classification_result is written for each processed transaction.
- Review queue rows are inserted for low-confidence results.
- workflow_runs is not directly mutated by this tool; the IN workflow orchestrator reads the output counts and advances run state.

---

## Preconditions

- All transaction_ids must belong to the same business_id as the run.
- run must be in RUNNING or REVIEW_HOLD state.
- transaction_ids array length must be between 1 and 500 inclusive.

Violations return a 422 with a specific error code before any classification begins.

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.