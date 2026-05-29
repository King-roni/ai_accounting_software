# Finalization Lock Policy

**Category:** Policies · Block 15 — Finalization & Secure Archive  
**Owner:** engine  
**Last updated:** 2026-05-16

---

## 1. Purpose

This policy defines the FINALIZATION_LOCK — a short-lived distributed execution lock acquired during the final phase of a workflow run. It prevents concurrent finalization of the same period and ensures finalization is a single-writer operation.

---

## 2. Distinction from Period Lock

These are two different locks serving different purposes:

| Attribute | FINALIZATION_LOCK | Period Lock |
|-----------|------------------|-------------|
| Lifetime | Short-lived; held only during finalization execution | Permanent post-finalization record |
| Table | `finalization_locks` | `period_locks` |
| Purpose | Prevents concurrent finalization | Prevents post-finalization mutations |
| Acquired | When run enters `FINALIZING` status | When run transitions to `FINALIZED` |
| Released | On success (FINALIZED) or failure (FAILED) | Never released |
| Schema | `finalization_lock_schema.md` | `period_lock_schema.md` |

---

## 3. Lock Acquisition

When a workflow run's `run_status` transitions to `FINALIZING`, the engine immediately attempts to acquire the FINALIZATION_LOCK:

1. `engine.acquire_finalization_lock` is called with `(business_id, period_year, period_month, workflow_run_id)`.
2. A row is inserted into `finalization_locks` with:
   - `status = ACTIVE`
   - `acquired_at = now()`
   - `ttl_expires_at = now() + interval '30 minutes'`
   - `workflow_run_id` referencing the acquiring run
3. The insert uses a unique constraint on `(business_id, period_year, period_month, workflow_type)` WHERE `status = ACTIVE` to enforce exclusivity.

Audit event emitted: `ENGINE_FINALIZATION_LOCK_ACQUIRED` (LOW).

---

## 4. Exclusivity

Only one FINALIZATION_LOCK may exist per `(business_id, period_year, period_month, workflow_type)` at a time, enforced via a partial unique index:

```sql
CREATE UNIQUE INDEX uq_finalization_locks_active
  ON finalization_locks (business_id, period_year, period_month, workflow_type)
  WHERE status = 'ACTIVE';
```

If a second acquisition attempt is made while an active lock exists, the engine receives a unique constraint violation. This is surfaced as error `ENGINE_FINALIZATION_LOCK_CONFLICT` (HIGH).

**Conflict handling:** The conflicting run transitions to `FAILED` with `failure_reason = 'FINALIZATION_LOCK_CONFLICT'`. The operator must investigate which run holds the active lock and whether it is stale (section 7).

Audit event emitted: `ENGINE_FINALIZATION_LOCK_CONFLICT` (HIGH).

---

## 5. Lock Renewal

If finalization processing exceeds 25 minutes (5 minutes before the 30-minute TTL), the engine renews the lock:

1. `engine.renew_finalization_lock` is called with the `lock_id`.
2. `ttl_expires_at` is extended by 30 minutes from the renewal time.
3. `renewed_at` and `renewal_count` are updated on the lock row.

There is no cap on the number of renewals, but each renewal is audited. If a renewal fails (e.g., the lock was concurrently marked STALE), finalization is aborted and the run transitions to `FAILED`.

Audit event emitted: `ENGINE_FINALIZATION_LOCK_RENEWED` (LOW).

---

## 6. Lock Release

The lock is released in two scenarios:

**Successful finalization:**
1. The period lock is written to `period_locks` (atomically, inside the FINALIZED transition transaction).
2. `engine.release_finalization_lock` sets the lock row's `status` to `RELEASED` and `released_at = now()`.
3. Run status is `FINALIZED`.

Audit event emitted: `ENGINE_FINALIZATION_LOCK_RELEASED` (LOW).

**Finalization failure:**
1. The run transitions to `FAILED` (or `COMPENSATING` — see section 8).
2. `engine.release_finalization_lock` sets `status = RELEASED`, `released_at = now()`, `release_reason = 'FAILED'`.
3. No period lock is written.

---

## 7. Stale Lock Detection

A lock whose `ttl_expires_at` has passed without being released is considered stale. Stale locks indicate a crashed or hung finalization process.

**Detection:** A background job (`engine.detect_stale_finalization_locks`) runs every 5 minutes. It queries:
```sql
SELECT * FROM finalization_locks
WHERE status = 'ACTIVE' AND ttl_expires_at < now()
```

For each stale lock found:
1. The lock's `status` is set to `STALE`.
2. The associated `workflow_run_id` is flagged for investigation.
3. An operator alert is triggered.
4. The run is reviewed and either resumed (via `engine.resume_run`) or marked `FAILED`.

Audit event emitted: `ENGINE_FINALIZATION_LOCK_STALE_DETECTED` (HIGH).

**Recovery:** Once a stale lock's status is `STALE`, a new finalization attempt may acquire a fresh lock. The stale lock remains in the table as an audit record.

---

## 8. Compensation Interaction

If the workflow run enters `COMPENSATING` status while holding a FINALIZATION_LOCK:

1. Lock release is the **first step** in the compensation sequence.
2. This is enforced in `out_phase_compensation_policy.md` — no compensation step may execute before the lock is released.
3. After release, compensation proceeds normally.

This ensures that a compensating run does not block subsequent finalization retries.

---

## 9. Lock Lifecycle States

```
ACTIVE -> RELEASED  (normal path)
ACTIVE -> STALE     (background job detects expired TTL)
STALE  -> (terminal; manually resolved via operator action)
```

---

## 10. Tools

| Tool | Action |
|------|--------|
| `engine.acquire_finalization_lock` | Acquires lock when FINALIZING begins |
| `engine.renew_finalization_lock` | Extends TTL before expiry |
| `engine.release_finalization_lock` | Releases lock on success or failure |
| `engine.detect_stale_finalization_locks` | Background stale detection |
| `engine.resume_run` | Resumes a run after stale lock investigation |

All `engine` WRITE tools: see `mobile_write_rejection_endpoints.md` — write operations are rejected on mobile clients.

---

## 11. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `ENGINE_FINALIZATION_LOCK_ACQUIRED` | LOW | Lock row inserted, status ACTIVE |
| `ENGINE_FINALIZATION_LOCK_RELEASED` | LOW | Lock released on success or failure |
| `ENGINE_FINALIZATION_LOCK_RENEWED` | LOW | TTL extended |
| `ENGINE_FINALIZATION_LOCK_STALE_DETECTED` | HIGH | Background job finds expired active lock |
| `ENGINE_FINALIZATION_LOCK_CONFLICT` | HIGH | Second acquisition attempt blocked |

---

## 12. Cross-References

- `finalization_lock_schema.md`
- `period_lock_policy.md`
- `workflow_run_schema.md`
- `out_phase_compensation_policy.md`
- `mobile_write_rejection_endpoints.md`
