# Tool: matching.confirm

**Category:** Tools · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

Confirms a proposed match, creating the ledger cross-reference and updating the transaction's
effective match status. This is the manual or rule-forced counterpart to the auto-confirmation
path in `matching.propose`. It transitions a PROPOSED match_record to CONFIRMED and propagates
downstream state changes to the matched invoice and the transaction.

---

## Identity

| Field | Value |
| --- | --- |
| Tool name | `matching.confirm` |
| Side effect class | WRITES_RUN_STATE, WRITES_AUDIT |
| Idempotent | Yes — same idempotency_key returns the existing output without re-writing |
| Mobile write policy | REJECTED — mobile clients cannot call `matching.confirm` |

Mobile rejection: any call where `client_form_factor = MOBILE` is rejected before precondition
checks. The response is HTTP 403 with audit event MOBILE_WRITE_REJECTED. See
mobile_write_rejection_endpoints.md.

---

## Input schema

```
{
  match_record_id:       uuid,   -- required; the match_records row to confirm
  confirmed_by_user_id:  uuid,   -- required; the user performing the confirmation
  confirmation_method:   enum,   -- required; MANUAL | AUTO_THRESHOLD | RULE_FORCED
  run_id:                uuid,   -- required; the IN workflow run context
  idempotency_key:       string  -- required; caller-supplied, max 128 chars
}
```

`confirmation_method` values:
- `MANUAL` — a human user clicked "Confirm" in the UI.
- `AUTO_THRESHOLD` — called programmatically when a threshold rule fires (distinct from
  the auto-confirmation path inside `matching.propose`, which does not call this tool).
- `RULE_FORCED` — a workflow gate or reviewer resolution action forced confirmation.

All UUID fields are `gen_uuid_v7()` PKs on their respective tables.

---

## Preconditions

All preconditions are checked in order before any writes occur. Failing a precondition returns
an error response with no state changes.

1. `match_record.status = PROPOSED`
   If status is CONFIRMED: return MATCH_ALREADY_CONFIRMED (idempotent success if same
   idempotency_key; error otherwise).
   If status is SUPERSEDED or VOID: return MATCH_NOT_IN_PROPOSED_STATUS.

2. The transaction associated with the match_record must not already have an EXACT confirmed match
   from a different match_record.
   If an EXACT confirmed match exists on a different record: return TRANSACTION_ALREADY_MATCHED.
   A STRONG_PROBABLE confirmed match on a different record does not block confirmation; the new
   confirmation supersedes it per matching_policy.md conflict rules.

3. The `run_id` in the input must match the `run_id` on the match_record row.
   Mismatch: return RUN_ID_MISMATCH.

---

## On confirmation — writes

All writes occur in a single database transaction. If the transaction aborts, no state changes
persist.

### match_records update

| Field | New value |
| --- | --- |
| status | CONFIRMED |
| confirmed_at | current timestamptz |
| confirmed_by_user_id | from input |
| confirmation_method | from input |

### Transaction effective match status

The transaction's `effective_match_status` column is updated to the `match_level` of the
confirmed match_record.

If the transaction previously had a lower-confidence confirmed match (e.g. STRONG_PROBABLE), the
older match_record is set to SUPERSEDED and `superseded_at` is set to the current timestamp.
The update and supersession occur in the same transaction.

### Invoice status update

If the match_record references a `matched_invoice_id`:

1. Retrieve all CONFIRMED match_records for the invoice (including the newly confirmed one).
2. Sum their transaction amounts.
3. Compare to `invoice.total_amount`:
   - If sum >= `invoice.total_amount - 0.01`: transition invoice status to PAID.
   - If sum < `invoice.total_amount - 0.01`: transition invoice status to PARTIALLY_PAID.
4. The invoice status write occurs in the same database transaction.

The 0.01 tolerance handles rounding differences in multi-currency or split-payment scenarios.

### Partial payment relationship

If the invoice status transitions to PARTIALLY_PAID, a row is written to (or updated in) the
`split_payment_relationships` table per split_payment_relationship_schema.md. This records the
partial match chain linking all contributing transactions to the invoice.

### Ledger cross-reference

A cross-reference row is written linking the ledger entry (from the match_record's
`matched_ledger_entry_id`) to the bank transaction row (`transaction_id`). If
`matched_ledger_entry_id` is null (invoice-only match), no ledger cross-reference row is written.

### Snooze clear

If the transaction has an open review issue of type `MATCH_REVIEW`, that review issue is resolved
and any active snooze is cleared. The review issue's `resolved_at` is set to the current timestamp
and `resolution_method` is set to `MATCH_CONFIRMED`.

---

## Output schema

```
{
  match_record_id:                   uuid,         -- the confirmed match_records PK
  transaction_effective_match_status: text,        -- EXACT | STRONG_PROBABLE | WEAK_POSSIBLE
  invoice_status:                    text | null   -- PAID | PARTIALLY_PAID | null (no invoice)
}
```

`invoice_status` is null when the match was against a ledger entry with no associated invoice.

---

## Idempotency

If a call is made with a previously used `idempotency_key`, the tool returns the stored output
from the original call without re-writing any rows. The idempotency window is 24 hours.

A call with the same `idempotency_key` but different input parameters returns HTTP 409
IDEMPOTENCY_KEY_CONFLICT.

---

## Audit events

| Event | Severity | Emitted when |
| --- | --- | --- |
| MATCH_CONFIRMED | LOW | A match_record transitions to CONFIRMED |
| MATCHING_INVOICE_FULLY_MATCHED | LOW | Invoice transitions to PAID as a result of this confirmation |

`MATCH_CONFIRMED` payload: `match_record_id`, `transaction_id`, `run_id`, `match_level`,
`confirmed_by_user_id`, `confirmation_method`.

`MATCHING_INVOICE_FULLY_MATCHED` payload: `invoice_id`, `match_record_id`, `total_confirmed_amount`,
`invoice_total_amount`.

Both events are emitted within the same `emitAudit()` call sequence after the database transaction
commits. Per audit_log_policies.md Section 4, audit emit runs out-of-band of the operational
transaction.

---

## Error conditions

| Code | HTTP | Condition |
| --- | --- | --- |
| MATCH_RECORD_NOT_FOUND | 404 | match_record_id does not exist in the run's business |
| MATCH_NOT_IN_PROPOSED_STATUS | 422 | match_record.status is SUPERSEDED or VOID |
| MATCH_ALREADY_CONFIRMED | 409 | match_record.status is already CONFIRMED (non-idempotent call) |
| TRANSACTION_ALREADY_MATCHED | 409 | Transaction has an EXACT confirmed match on a different record |
| RUN_ID_MISMATCH | 422 | Input run_id does not match match_record.run_id |
| MOBILE_WRITE_REJECTED | 403 | client_form_factor = MOBILE |
| IDEMPOTENCY_KEY_CONFLICT | 409 | Same key used with different input parameters |

---

## Cross-references

- match_record_schema.md — match_records table structure, status enum, confirmation fields
- matching_policy.md — conflict resolution rules, confirmation method semantics
- split_payment_relationship_schema.md — partial payment chain schema
- invoice_schema.md — invoice status enum, total_amount field
- mobile_write_rejection_endpoints.md — mobile rejection policy
- audit_log_policies.md — emit-out-of-band convention, Section 4

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.