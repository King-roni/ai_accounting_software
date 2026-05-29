# Tool: classification.vendor_memory_update

**Category:** Tools · Block 08 — Transaction Classification
**Side-effect class:** WRITES_RUN_STATE | WRITES_AUDIT
**Mobile restriction:** Mobile clients cannot call `classification.vendor_memory_update`
(see `mobile_write_rejection_endpoints.md`)

---

## Purpose

Writes or updates a vendor memory entry linking a counterparty to a classification tag.
Vendor memory is the persistent learned association between a counterparty and its expected
classification. It feeds the vendor memory pass in the classification pipeline, allowing
previously confirmed tags to be applied with high confidence without consuming AI tier
capacity.

This tool handles three scenarios: new entry creation, confirmation increment on an
existing matching entry, and conflict detection when the incoming tag differs from the
stored tag.

---

## Input Schema

```json
{
  "business_id": "uuid",
  "counterparty_id": "uuid",
  "tag": "text",
  "confidence_increment": "numeric",
  "source": "enum",
  "confirmed_by_user_id": "uuid | null",
  "run_id": "uuid | null",
  "idempotency_key": "string"
}
```

| Field                | Type             | Required | Default        | Notes                                             |
|----------------------|------------------|----------|----------------|---------------------------------------------------|
| business_id          | uuid             | yes      | —              | REFERENCES business_entities(id)                  |
| counterparty_id      | uuid             | yes      | —              | REFERENCES counterparties(id)                     |
| tag                  | text             | yes      | —              | Classification tag value                          |
| confidence_increment | numeric          | no       | 1.0            | Added to confirmation_count on UPDATED            |
| source               | enum             | yes      | —              | MANUAL_CONFIRM, AUTO_LEARN, or BULK_IMPORT        |
| confirmed_by_user_id | uuid or null     | no       | null           | Required when source = MANUAL_CONFIRM             |
| run_id               | uuid or null     | no       | null           | Associates the update with an in-progress run     |
| idempotency_key      | string           | yes      | —              | Deduplicates repeated calls                       |

---

## Upsert Logic

### Case 1 — No Existing Row

Insert a new `vendor_memory` row with:
- `confirmation_count = confidence_increment`
- `last_confirmed_at = now()`
- `source = source`
- `confirmed_by_user_id` as provided
- `pk = gen_uuid_v7()`

Action returned: `CREATED`.

### Case 2 — Existing Row, Same Tag

Increment `confirmation_count` by `confidence_increment`. Update `last_confirmed_at`.
If `source = MANUAL_CONFIRM`, update `confirmed_by_user_id`. Evaluate staleness rules
after write (see Staleness section below).

Action returned: `UPDATED`.

### Case 3 — Existing Row, Different Tag

Do not overwrite the stored tag. Instead:

1. Create a conflict record in `vendor_memory_conflicts` (schema in
   `vendor_memory_conflicts_schema.md`) recording both the stored tag and the incoming tag,
   the source, the run_id, and the timestamp.
2. Apply `tag_conflict_resolution_policy.md` to determine whether the new tag should
   override the existing entry or remain pending human review.
3. If the policy resolves automatically, update the `vendor_memory` row and mark the
   conflict as AUTO_RESOLVED.
4. If the policy requires human review, leave the existing tag in place and flag the
   conflict as PENDING_REVIEW.

Action returned: `CONFLICT_DETECTED`. `conflict_id` is populated in the output.

---

## Staleness Evaluation

After any write, the tool evaluates `vendor_memory_staleness_policy.md` rules against the
updated row. If the staleness check determines the entry is stale (e.g. last_confirmed_at
is beyond the staleness window), the row is marked `staleness_flag = true`. Stale entries
are skipped by the vendor memory pass in the classification pipeline, causing those
counterparties to fall through to rule engine or AI classification.

---

## Write-Through Behavior

If `run_id` is provided and a classification step for the same `counterparty_id` is
currently in progress in that run, the new or updated vendor memory is applied immediately
to that in-progress classification. The classification result is updated without requiring
a re-run.

---

## Idempotency

If a call is received with a `idempotency_key` that matches a prior completed call:
- Return the original `record_id` and `action` from that call.
- No database writes occur.
- The response is structurally identical to the original call's response.

Idempotency window: 72 hours from original call timestamp.

---

## Output Schema

```json
{
  "record_id": "uuid",
  "action": "CREATED | UPDATED | CONFLICT_DETECTED",
  "conflict_id": "uuid | null"
}
```

| Field       | Type          | Notes                                              |
|-------------|---------------|----------------------------------------------------|
| record_id   | uuid          | The vendor_memory row pk (gen_uuid_v7())           |
| action      | enum          | Reflects the upsert outcome                        |
| conflict_id | uuid or null  | Populated only when action = CONFLICT_DETECTED     |

---

## Audit Events

| Event                                    | Severity | Condition                            |
|------------------------------------------|----------|--------------------------------------|
| CLASSIFICATION_VENDOR_MEMORY_UPDATED     | LOW      | Every successful CREATED or UPDATED  |
| CLASSIFICATION_VENDOR_CONFLICT_DETECTED  | MEDIUM   | action = CONFLICT_DETECTED           |

Both events are emitted via `security.emit_audit` after the database write commits.

---

## Mobile Rejection

Per `mobile_write_rejection_endpoints.md`, any call to
`classification.vendor_memory_update` from a mobile client is rejected with HTTP 403
before any database writes occur. The rejection itself does not emit an audit event.

---

## Cross-References

- `vendor_memory_schema.md` — table definition and indexes
- `vendor_memory_conflicts_schema.md` — conflict record structure
- `tag_conflict_resolution_policy.md` — resolution rules for tag disagreements
- `vendor_memory_staleness_policy.md` — staleness window thresholds
- `mobile_write_rejection_endpoints.md` — mobile rejection rules
