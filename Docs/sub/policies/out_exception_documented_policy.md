# OUT Exception Documented Policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Block reference:** BLOCK_12 · **Stage:** 4 sub-doc (Layer 2)

This document defines the semantics of the `EXCEPTION_DOCUMENTED` value of `transactions.effective_match_status`, including how it is triggered, stored, and reversed, and how it interacts with gate evaluation.

---

## Purpose

Not every business transaction can be matched to an invoice. A supplier may have issued a paper receipt that was lost, a one-off cash payment may have no corresponding document, or a transaction may represent an internal transfer that is matched bilaterally rather than via an invoice. In these cases, the accountant is not failing to find a match — they are explicitly confirming that no match exists and that the situation has been reviewed and accepted.

`EXCEPTION_DOCUMENTED` formalises that decision as a named status on the transaction rather than as an absence of data. This allows `engine.gate_matching_complete` to treat the transaction as resolved rather than blocking on it, while the full audit trail of the accountant's decision is preserved.

---

## Definition

`EXCEPTION_DOCUMENTED` is a value of the `effective_match_status` column on the `transactions` table. It means:

> An accountant with sufficient authority has reviewed this transaction and explicitly accepted that it will not be matched to an invoice for this period. The decision and reason are documented.

This status is distinct from `NO_MATCH`, which means "no match has been found yet and no explicit decision has been made." `EXCEPTION_DOCUMENTED` is a terminal review state; `NO_MATCH` is an intermediate state awaiting resolution.

---

## Storage

### Columns involved

| Column | Type | Semantics |
| --- | --- | --- |
| `transactions.effective_match_status` | `match_status_enum` | Set to `EXCEPTION_DOCUMENTED` when the exception is recorded |
| `transactions.prior_match_status` | `match_status_enum NULL` | Stores the value of `effective_match_status` at the time the exception was recorded |
| `transactions.exception_reason` | `text NULL` | Free-text reason provided by the accountant; max 1000 characters; required when status is `EXCEPTION_DOCUMENTED` |
| `transactions.exception_documented_by` | `uuid NULL` | FK to `users.id`; the accountant who documented the exception |
| `transactions.exception_documented_at` | `timestamptz NULL` | Timestamp of the write |

`prior_match_status` is preserved for audit and reversal purposes. If the exception is later reversed, `effective_match_status` is reset to `prior_match_status` (not unconditionally to `NO_MATCH`) so that a partially-scored match status is not lost.

### Permitted prior states

`out_workflow.document_exception` validates that the current `effective_match_status` is in the set of reversible states before proceeding:

- `NO_MATCH` — most common; the transaction was never matched.
- `PROBABLE_UNCONFIRMED` — the match was scored as probable but never confirmed; the accountant is choosing to document an exception instead of confirming.

Attempting to document an exception on a transaction that is already `MATCHED` or `EXCEPTION_DOCUMENTED` raises a validation error and does not proceed.

---

## Trigger

The exception is recorded by the tool `out_workflow.document_exception`.

### Tool registration shape

```ts
engine.registerTool({
  name:              "out_workflow.document_exception",
  schema_version:    "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier:           "NONE",
  audit_events:      ["OUT_WORKFLOW_EXCEPTION_DOCUMENTED"],
  description_ref:   "Docs/sub/tools/tool_out_workflow_document_exception.md",
});
```

### Input parameters

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `transaction_id` | uuid | Yes | The transaction to document the exception on |
| `reason` | text | Yes | Free-text reason; max 1000 characters |
| `run_id` | uuid | Yes | The active workflow run; used for scope validation |

### Validation

1. The run must be in status `RUNNING` or `REVIEW_HOLD`. The tool is not callable on a `FINALIZED` or `CANCELLED` run.
2. The caller's role must be `ACCOUNTANT`, `ADMIN`, or `OWNER`.
3. The transaction's `workflow_run_id` must equal the supplied `run_id`.
4. The current `effective_match_status` must be in the permitted prior states set.
5. `reason` must be non-empty after trimming.

The write is a single atomic transaction: update `effective_match_status`, `prior_match_status`, `exception_reason`, `exception_documented_by`, `exception_documented_at` together, then emit `OUT_WORKFLOW_EXCEPTION_DOCUMENTED`.

---

## Reversibility

### Before finalization

An accountant with role `OWNER`, `ADMIN`, or `ACCOUNTANT` may reverse an `EXCEPTION_DOCUMENTED` status before the run reaches `FINALIZING`. Reversal is performed by `out_workflow.reverse_exception`.

Reversal writes:

- `effective_match_status` ← `prior_match_status` (restores the pre-exception status)
- `prior_match_status` ← `NULL`
- `exception_reason` ← `NULL`
- `exception_documented_by` ← `NULL`
- `exception_documented_at` ← `NULL`

After reversal, the transaction returns to the normal matching flow. If it was in `PROBABLE_UNCONFIRMED` before the exception, it will re-appear in the matching review queue.

### After finalization

Once the run transitions to `FINALIZING`, the `EXCEPTION_DOCUMENTED` status is immutable. `out_workflow.reverse_exception` rejects calls where the run is in `FINALIZING`, `FINALIZED`, or any terminal state. This immutability is enforced both at the application layer (tool validation) and at the database layer (a `CHECK` constraint triggers a rejection if the run is finalized and the status is being changed).

Any correction to a finalized period's exception status requires an `OUT_ADJUSTMENT` run.

---

## Effect on gate evaluation

`engine.gate_matching_complete` evaluates whether all transactions in the run's scope have a resolved match status. The gate treats the following status values as resolved:

| `effective_match_status` | Counts as resolved for gate |
| --- | --- |
| `MATCHED` | Yes |
| `EXCEPTION_DOCUMENTED` | Yes |
| `NO_MATCH` | No — gate holds |
| `PROBABLE_UNCONFIRMED` | No — gate holds |
| `SPLIT_PENDING` | No — gate holds |

`EXCEPTION_DOCUMENTED` is explicitly equivalent to `MATCHED` for gate-pass purposes. This means a run where every transaction is either `MATCHED` or `EXCEPTION_DOCUMENTED` will pass `engine.gate_matching_complete` with no review-hold required.

The gate query:

```sql
SELECT COUNT(*) FROM transactions
WHERE  workflow_run_id = $run_id
AND    effective_match_status NOT IN ('MATCHED', 'EXCEPTION_DOCUMENTED');
```

Gate passes if this count is zero.

---

## Mobile rejection

`out_workflow.document_exception` carries the `WRITES_RUN_STATE` side-effect class. Per the platform-wide mobile write policy, all write tools are blocked when the client's `client_form_factor = MOBILE`. Any call to `out_workflow.document_exception` from a mobile client is rejected at the access-control layer before the tool body executes. The rejection emits `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full list of endpoints that reject mobile clients.

---

## Audit events

### `OUT_WORKFLOW_EXCEPTION_DOCUMENTED`

Severity: `LOW`

Emitted by `out_workflow.document_exception` on a successful write.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `transaction_id` | uuid | Transaction that was exception-documented |
| `workflow_run_id` | uuid | Active run |
| `prior_match_status` | text | Status before the exception was recorded |
| `exception_reason` | text | Reason supplied by the accountant |
| `documented_by_user_id` | uuid | Actor |
| `documented_at` | timestamptz | Timestamp of the write |

---

### `OUT_WORKFLOW_EXCEPTION_REVERSED`

Severity: `MEDIUM`

Emitted by `out_workflow.reverse_exception` on a successful reversal. MEDIUM because reversing an exception re-opens a transaction that was previously accepted as resolved — the gate may hold again as a result.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `transaction_id` | uuid | Transaction whose exception was reversed |
| `workflow_run_id` | uuid | Active run |
| `restored_match_status` | text | The `prior_match_status` value that was restored |
| `reversed_by_user_id` | uuid | Actor |
| `reversed_at` | timestamptz | Timestamp of the reversal |

---

## Cross-references

- `out_adjustment_type_definition.md` — how to correct an exception status after finalization via OUT_ADJUSTMENT
- `out_phase_gate_policy.md` — full gate-evaluation sequence for OUT_MONTHLY phases
- `gate_function_library_schema.md` — `engine.gate_matching_complete` definition and full gate pass criteria
- `mobile_write_rejection_endpoints.md` — complete list of tools blocked on mobile clients
- `audit_event_taxonomy.md` — `OUT_WORKFLOW_EXCEPTION_DOCUMENTED`, `OUT_WORKFLOW_EXCEPTION_REVERSED`
- `full_issue_type_to_group_routing_table.md` — `TRANSACTION_EXCEPTION_DOCUMENTED` issue type semantics (Block 12 row)
