# tool_run_finalize

**Category:** Tools — Block 15: Finalization & Secure Archive
**Tool name:** `engine.finalize`
**Side effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
**Mobile rejection:** YES — mobile clients cannot call `engine.finalize`. See `mobile_write_rejection_endpoints.md`.

---

## Purpose

Executes the finalization sequence for a workflow run that has reached `FINALIZING`
status. Finalization is an ordered, partially-atomic sequence that produces a
period lock, an Object Lock-protected archive bundle, and an RFC 3161 timestamp.
The sequence may not be interrupted once the `FINALIZATION_LOCK` is held.

---

## Input Schema

```json
{
  "run_id":          "uuid",
  "idempotency_key": "string"
}
```

Both fields are required.

---

## Output Schema

```json
{
  "run_id":             "uuid",
  "finalized_at":       "timestamptz",
  "archive_bundle_id":  "uuid",
  "period_lock_id":     "uuid"
}
```

---

## Preconditions

All of the following must be true before the sequence begins. If any precondition fails,
the tool returns a `409` error and does not acquire the lock.

1. `run_status` must be `FINALIZING`. Any other status returns `409 RUN_NOT_FINALIZING`.
2. The `FINALIZATION_LOCK` must be acquirable for the run's `(business_id, period_year,
   period_month, workflow_type)` tuple. If a lock row with `status = 'HELD'` already
   exists, returns `409 FINALIZATION_LOCK_HELD`.
3. All gate checks for the `FINALIZING` phase must have passed. Unresolved gate failures
   return `409 GATE_CHECK_FAILED` with the list of failing gates.

---

## Finalization Steps

Steps execute in the order below. Steps ii and iii are atomic (single transaction).
All other steps are sequential.

| # | Step | On failure |
|---|---|---|
| i | Call `archive.verify_hash_chain` to verify the integrity of the archive bundle's hash chain. | Abort; run → `FAILED`; lock released. |
| ii | Write `period_locks` row (atomic with step iii). | Abort; run → `FAILED`; lock released. |
| iii | Call `archive.promote` to upload the bundle to Archive S3 with Object Lock. | Abort; run → `FAILED`; lock released. |
| iv | Request RFC 3161 timestamp from the configured TSA for the bundle's hash. Stamp is stored on the `archive_bundles` row. | Abort; run → `FAILED`; lock released. |
| v | Release `FINALIZATION_LOCK` (set `status = 'RELEASED'`, `released_at = now()`). | Non-blocking warning; proceed to step vi. |
| vi | Transition `run_status → FINALIZED`. | Fatal; run stuck in `FINALIZING`; requires manual intervention. |

---

## Failure Handling

If any step i–iv fails:

- `run_status` transitions to `FAILED`. `FAILED` is not `CANCELLED` — finalization
  failures indicate a data integrity or infrastructure issue and require investigation
  before the run can be retried.
- The `FINALIZATION_LOCK` is released immediately after the status transition.
- The `archive_bundles` row is not cleaned up automatically; the promotion runbook
  (`archive_promotion_failure_runbook.md`) governs remediation.
- A `BLOCKING` audit event is written if hash chain integrity fails; other failures
  write `HIGH`.

---

## Idempotency

If called again for a run that is already `FINALIZED` with the same `idempotency_key`:

- Returns success immediately.
- Returns the original `finalized_at`, `archive_bundle_id`, and `period_lock_id`.
- No steps are re-executed.
- No additional audit events are written.

If called with a different `idempotency_key` for an already-`FINALIZED` run, returns
`409 RUN_ALREADY_FINALIZED`.

---

## Lock Lifecycle

The `FINALIZATION_LOCK` row is written to the `finalization_locks` table with
`expires_at = acquired_at + 30 minutes`. The finalization sequence is expected to
complete well within this window under normal conditions. If the process crashes
mid-sequence, a background job detects `status = 'HELD' AND expires_at < now()` and
sets `status = 'STALE'`, releasing the lock for retry. See `finalization_lock_policy.md`
for stale recovery procedures.

---

## Audit Events

| Event                              | Severity | Trigger                                |
|---|---|---|
| `ARCHIVE_FINALIZATION_COMPLETED`   | MEDIUM   | run_status transitions to FINALIZED    |
| `ARCHIVE_PERIOD_LOCKED`            | MEDIUM   | period_locks row is written            |

Both events reference `run_id` and `business_id` in the audit payload.

---

## Error Codes

| Code                        | HTTP | Meaning                                             |
|---|---|---|
| `RUN_NOT_FOUND`             | 404  | run_id does not exist                               |
| `RUN_NOT_FINALIZING`        | 409  | run_status is not FINALIZING                        |
| `FINALIZATION_LOCK_HELD`    | 409  | another process holds the lock                      |
| `GATE_CHECK_FAILED`         | 409  | one or more gate checks have not passed             |
| `HASH_CHAIN_BROKEN`         | 500  | archive.verify_hash_chain returned failure          |
| `PERIOD_LOCK_CONFLICT`      | 409  | period_locks row already exists for this period     |
| `ARCHIVE_PROMOTION_FAILED`  | 500  | archive.promote returned failure after retries      |
| `TSA_TIMESTAMP_FAILED`      | 500  | RFC 3161 timestamp request failed                   |
| `RUN_ALREADY_FINALIZED`     | 409  | run is FINALIZED; idempotency_key mismatch          |

---

## Cross-References

- `finalization_lock_policy.md` — lock acquisition, renewal, stale detection, recovery
- `period_lock_schema.md` — DDL for period_locks table
- `archive_bundle_construction_schema.md` — bundle structure and hash chain spec
- `hash_chain_verification_policy.md` — verification algorithm and failure thresholds
- `rfc3161_timestamp_policy.md` — TSA endpoint, retry policy, stamp storage
- `mobile_write_rejection_endpoints.md` — mobile rejection policy and error format

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.