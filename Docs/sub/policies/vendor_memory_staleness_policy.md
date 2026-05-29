# Vendor Memory Staleness Policy

**Category:** Policies · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

Binding rules for staleness detection, marking, pruning, and re-activation of vendor memory entries in the `vendor_memory` table. The `classification.apply_vendor_memory` tool must filter on staleness and deletion state before using any entry as a classification signal. The background staleness job must follow the TTL and pruning timelines defined here exactly.

---

## Purpose

Vendor memory accumulates counterparty-to-category associations derived from human-confirmed classifications. Over time, a business's counterparty roster changes: suppliers go inactive, contracts end, company names change. A stale vendor memory entry from an inactive supplier can produce incorrect category suggestions for new transactions from a different supplier who happens to share a similar name or IBAN prefix. Staleness management prevents this class of misclassification.

The policy has three phases: staleness marking, soft-delete pruning, and re-activation. Hard deletion is not used; entries are retained for audit and potential re-activation.

---

## Staleness definition

A vendor memory entry is stale when the counterparty it represents has not appeared in any classified transaction for the business within the preceding 12 months.

Formally: an entry is stale if:

```
last_seen_at < now() - INTERVAL '12 months'
```

where `last_seen_at` is the timestamp on the `vendor_memory` row recording the most recent transaction classification that updated or reinforced the entry.

The 12-month window is measured from the background job's execution time, not from the end of the current workflow run. This means an entry may become stale between workflow runs if no transaction from the counterparty was classified in the trailing 12 months.

---

## Staleness detection

A background job runs on the first day of each calendar month at 02:00 UTC. It executes the following scan:

```sql
UPDATE vendor_memory
SET    is_stale = TRUE,
       stale_marked_at = now()
WHERE  last_seen_at < now() - INTERVAL '12 months'
  AND  is_stale = FALSE
  AND  deleted_at IS NULL;
```

For each row updated, the job emits `CLASSIFICATION_VENDOR_MEMORY_MARKED_STALE` with:
- `memory_id` — the `vendor_memory.id` value
- `business_id`
- `vendor_key` — the normalised counterparty key
- `last_seen_at` — the value before marking
- `marked_stale_at` — the timestamp of the update

The job runs as a single transaction per business to ensure that the audit events and the row updates are atomic. If the job fails mid-run for a business, partial marks for that business are rolled back; the job retries at the next scheduled run.

---

## Pruning

Stale entries are soft-deleted 3 months after being marked stale. The background job (same monthly job, second phase) executes:

```sql
UPDATE vendor_memory
SET    deleted_at = now()
WHERE  is_stale = TRUE
  AND  deleted_at IS NULL
  AND  stale_marked_at < now() - INTERVAL '3 months';
```

For each row soft-deleted, the job emits `CLASSIFICATION_VENDOR_MEMORY_PRUNED` with:
- `memory_id`
- `business_id`
- `vendor_key`
- `stale_marked_at` — when the entry was first marked stale
- `pruned_at` — the timestamp of the soft-delete

Soft-deleted rows (`deleted_at IS NOT NULL`) are never hard-deleted. They are excluded from all classification lookups (see the lookup filter below) but remain in the table for audit trail and forensic queries. The 7-year Operational zone retention clock applies from the `deleted_at` timestamp; after that window they transition to Archive zone per the standard retention pipeline.

The 3-month grace period between staleness marking and soft-deletion allows operators who notice the marking (via audit events or the admin dashboard) to re-activate an entry before it is pruned. This is intentional: staleness marking is reversible; soft-deletion is not.

---

## Effect on classification

The `classification.apply_vendor_memory` tool applies the following filter on every lookup:

```sql
SELECT *
FROM   vendor_memory
WHERE  business_id = :business_id
  AND  vendor_key  = :vendor_key
  AND  is_stale    = FALSE
  AND  deleted_at  IS NULL;
```

Stale entries (`is_stale = TRUE`) are excluded from the lookup regardless of whether they have been soft-deleted. This means an entry marked stale but not yet pruned is also excluded from classification — the 3-month grace period does not affect classification behaviour, only the availability of re-activation.

When no qualifying hit is found, the tool emits `CLASSIFICATION_VENDOR_MEMORY_MISS` with `miss_reason: "NO_CONFIRMED_RECORDS"` (or an appropriate sub-reason). Staleness-excluded entries do not produce a dedicated miss reason; from the tool's perspective, a stale entry is equivalent to no entry.

---

## Re-activation

If a new transaction from the same counterparty is classified after an entry is marked stale but before it is soft-deleted, the entry is re-activated:

```sql
UPDATE vendor_memory
SET    is_stale     = FALSE,
       stale_marked_at = NULL,
       last_seen_at = now(),
       sample_count = sample_count + 1
WHERE  id = :memory_id;
```

Re-activation is triggered by the `classification.write_vendor_memory` tool at the end of a successful classification for the counterparty. The write-back tool checks for a stale (but not deleted) entry before deciding whether to insert a new row or update an existing one.

`CLASSIFICATION_VENDOR_MEMORY_REACTIVATED` is emitted on re-activation with:
- `memory_id`
- `business_id`
- `vendor_key`
- `was_stale_for_days` — integer days between `stale_marked_at` and the re-activation timestamp
- `reactivated_at`

Re-activation is not possible for soft-deleted entries (`deleted_at IS NOT NULL`). For a deleted entry, the write-back tool inserts a new row with `version = 1` and no link to the deleted entry. The new row starts a fresh history.

---

## Audit events

| Event | Trigger | Severity |
|---|---|---|
| `CLASSIFICATION_VENDOR_MEMORY_MARKED_STALE` | Background job marks entry stale | LOW |
| `CLASSIFICATION_VENDOR_MEMORY_PRUNED` | Background job soft-deletes stale entry | LOW |
| `CLASSIFICATION_VENDOR_MEMORY_REACTIVATED` | Write-back tool re-activates a stale entry | LOW |

All three events are emitted to the business audit chain (not the global chain). They use the `CLASSIFICATION` domain per `audit_log_policies`.

---

## Schema fields referenced

The following `vendor_memory` columns are directly governed by this policy:

| Column | Type | Governance |
|---|---|---|
| `is_stale` | boolean | Set to `TRUE` by the monthly job when `last_seen_at` crosses the 12-month threshold |
| `stale_marked_at` | timestamptz, nullable | Populated when `is_stale` first transitions to `TRUE`; cleared on re-activation |
| `deleted_at` | timestamptz, nullable | Set by the monthly pruning pass 3 months after `stale_marked_at`; never cleared |
| `last_seen_at` | timestamptz | Updated by `classification.write_vendor_memory` on each qualifying hit |

The full `vendor_memory` DDL is in `vendor_memory_schema.md`.

---

## Cross-references

- `vendor_memory_schema.md` — `vendor_memory` table DDL; all columns including `is_stale`, `deleted_at`, `last_seen_at`
- `tool_classification_vendor_memory_apply.md` — `classification.apply_vendor_memory` tool; lookup filter; `CLASSIFICATION_VENDOR_MEMORY_HIT` and `MISS` emission
- `tool_vendor_memory_writeback.md` — `classification.write_vendor_memory` tool; re-activation logic; new-row insertion for deleted entries
