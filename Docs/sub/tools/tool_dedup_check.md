# Tool: intake.check_dedup

**Block:** Intake  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`intake.check_dedup` runs after `intake.parse` has produced a set of transaction rows from a bank statement. It examines every newly parsed transaction and determines whether it is genuinely new or a duplicate of a transaction that already exists in the system for the same business.

The tool supports two duplicate signals: an exact structural match and a fuzzy probabilistic match. Exact duplicates are blocked from advancing automatically. Probable duplicates are held in the review queue for human confirmation before being allowed through.

---

## Tool Signature

**Name:** `intake.check_dedup`  
**Namespace:** `intake`  
**Action:** `check_dedup`

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `run_id` | UUID | Yes | FK to `workflow_runs(id)`. The run must be in the INTAKE phase and status RUNNING. |
| `transaction_ids` | UUID[] | Yes | Array of transaction IDs produced by the current parse operation. All IDs must belong to the same `run_id`. Maximum 5,000 IDs per call. |

### Outputs

| Field | Type | Description |
|---|---|---|
| `dedup_results` | `DedupResult[]` | One result per input `transaction_id`. |
| `summary` | `DedupSummary` | Aggregate counts: `new_count`, `duplicate_exact_count`, `duplicate_probable_count`, `needs_review_count`. |

#### DedupResult shape

```jsonc
{
  "transaction_id": "<uuid>",
  "dedup_status": "NEW",
  "matched_transaction_id": null,
  "match_confidence": null
}
```

```jsonc
{
  "transaction_id": "<uuid>",
  "dedup_status": "DUPLICATE_EXACT",
  "matched_transaction_id": "<uuid of existing transaction>",
  "match_confidence": 1.0
}
```

```jsonc
{
  "transaction_id": "<uuid>",
  "dedup_status": "DUPLICATE_PROBABLE",
  "matched_transaction_id": "<uuid of best candidate>",
  "match_confidence": 0.91
}
```

---

## Deduplication Logic

### Exact Match

An exact match is determined by the following composite key:

```
(business_id, amount, currency, value_date, counterparty_name, reference)
```

SQL:

```sql
SELECT id
FROM   transactions
WHERE  business_id       = :business_id
  AND  amount            = :amount
  AND  currency          = :currency
  AND  value_date        = :value_date
  AND  counterparty_name = :counterparty_name
  AND  reference         = :reference
  AND  id               != :transaction_id;
```

If a match is found, `dedup_status` is set to `DUPLICATE_EXACT` and `match_confidence` is `1.0`.

Reference key definition: `deduplication_fingerprint_schema.md`, `dedup_key_generator_policy.md`.

### Fuzzy Match

When no exact match is found, a fuzzy search is performed over:

- `amount` — must be identical (no tolerance; amount drift indicates a different transaction).
- `currency` — must be identical.
- `value_date` — within ±2 calendar days of the candidate.
- `counterparty_name` — trigram similarity score > 0.85, computed via `pg_trgm`.

```sql
SELECT   id,
         similarity(counterparty_name, :counterparty_name) AS name_sim
FROM     transactions
WHERE    business_id = :business_id
  AND    amount      = :amount
  AND    currency    = :currency
  AND    value_date  BETWEEN :value_date - INTERVAL '2 days'
                         AND :value_date + INTERVAL '2 days'
  AND    similarity(counterparty_name, :counterparty_name) > 0.85
ORDER BY name_sim DESC
LIMIT    1;
```

If a candidate is found, `dedup_status` is set to `DUPLICATE_PROBABLE`. `match_confidence` is set to the trigram similarity score.

### No Match

If neither exact nor fuzzy match is found, `dedup_status` is `NEW`. The transaction advances normally to classification.

---

## Status Written

Results are written to `dedup_results` (Processing zone) and the `dedup_status` column on `transactions`:

```sql
UPDATE transactions
SET    dedup_status = :dedup_status,
       dedup_checked_at = now()
WHERE  id = :transaction_id;
```

Rows with `dedup_status = 'DUPLICATE_EXACT'` are flagged `do_not_advance = true` and will not move to the classification phase. They are excluded from all subsequent pipeline steps within the current run.

Rows with `dedup_status = 'DUPLICATE_PROBABLE'` are flagged `do_not_advance = true` pending review. A review issue is opened (see below).

Rows with `dedup_status = 'NEW'` proceed normally.

---

## Review Issue Creation

For every `DUPLICATE_PROBABLE` result, a review issue is created via `review_queue.create_issue`:

```jsonc
{
  "issue_type": "DUPLICATE_PROBABLE",
  "severity": "MEDIUM",
  "run_id": "<run_id>",
  "transaction_id": "<transaction_id>",
  "matched_transaction_id": "<candidate_id>",
  "match_confidence": 0.91,
  "requires_human_confirmation": true
}
```

A human reviewer must either confirm the duplicate (transaction is permanently excluded from this and future runs) or reject the duplicate signal (transaction is released to classification).

`DUPLICATE_EXACT` transactions do NOT generate a review issue. They are silently excluded; the business can inspect them via the intake history view.

---

## Audit Events

| Event | Severity | Emitted when |
|---|---|---|
| `DEDUP_CHECK_COMPLETED` | LOW | After all results are written, once per run |

The event is emitted once per `check_dedup` invocation, not once per transaction row. Payload:

```jsonc
{
  "run_id": "<uuid>",
  "business_id": "<uuid>",
  "checked_count": 150,
  "new_count": 143,
  "duplicate_exact_count": 4,
  "duplicate_probable_count": 3,
  "duration_ms": 312
}
```

Emitted via `emit_audit_api.md`.

---

## Idempotency

`intake.check_dedup` is safe to retry. If called again with the same `transaction_ids`:

- Rows already written to `dedup_results` are overwritten with the fresh result.
- Existing `DUPLICATE_PROBABLE` review issues are not duplicated; the tool checks for an existing open issue before creating a new one.
- Audit event is emitted on every successful completion, including retries.

---

## Error Handling

| Failure mode | Behaviour |
|---|---|
| `run_id` not found or wrong phase | Returns error `RUN_NOT_FOUND_OR_WRONG_PHASE`; no state written |
| `transaction_ids` contains IDs not in the run | Returns error `TRANSACTION_NOT_IN_RUN` for each offending ID; remaining IDs processed |
| `pg_trgm` extension unavailable | Fuzzy check is skipped; all rows default to `NEW` with warning `FUZZY_CHECK_SKIPPED` |
| Batch size > 5,000 | Returns error `BATCH_TOO_LARGE`; caller must split |

---

## Preconditions

- `run_id` must be in phase INTAKE and status RUNNING.
- All `transaction_ids` must belong to the specified `run_id`.
- `pg_trgm` extension should be enabled (soft dependency — see error handling).

---

## Mobile

`intake.check_dedup` is classified as `WRITES_AUDIT`.

On mobile clients:

- Results are not displayed in real time during the check. The mobile client polls run status and presents a summary card once `DEDUP_CHECK_COMPLETED` is received via the notification channel.
- `DUPLICATE_PROBABLE` issues surface as action-required cards in the review queue on mobile. Each card shows the two transactions side by side (amount, date, counterparty) and presents Confirm Duplicate / Not a Duplicate actions.
- `DUPLICATE_EXACT` exclusions are visible in the intake history detail view; no action is required from the mobile user.
- Batch size limit of 5,000 is enforced server-side regardless of client type.

---

## Related Documents

- `tool_intake_parse.md` — produces the `transaction_ids` this tool consumes
- `dedup_result_schema.md` — DDL for the `dedup_results` table
- `deduplication_fingerprint_schema.md` — composite key definition
- `dedup_key_generator_policy.md` — key normalisation rules
- `deduplication_policy.md` — policy governing exact vs. fuzzy thresholds
- `review_queue_schema.md` — review issue structure
- `tool_review_queue_create_issue.md` — issue creation tool called internally
- `emit_audit_api.md` — audit emission API
- `transactions_schema.md` — `dedup_status` column definition
