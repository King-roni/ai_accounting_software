# Transaction Indexing Strategy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

Index strategy for the `transactions` table — the highest-volume operational table in the system. This policy enumerates every index, its purpose, the query pattern it serves, and the maintenance approach. Adding, removing, or modifying an index on `transactions` requires the query-plan and volume-threshold decision rule defined in this document. The index set is designed to serve the six primary access patterns without creating unnecessary write amplification.

---

## Why UUID v7 avoids index bloat

The `transactions` table uses UUID v7 PKs per `data_layer_conventions_policy`. UUID v7 prefixes a 48-bit Unix-millisecond timestamp before a random tail. The monotonically increasing prefix means that new rows are always appended near the end of the B-tree index (the "hot page"), which:

1. Eliminates the random-write fragmentation that UUID v4 causes in B-tree indexes. UUID v4 inserts scatter writes across all leaf pages, causing page splits that bloat index size and degrade cache hit rates.
2. Reduces autovacuum and `FILLFACTOR` pressure. With UUID v7, the primary key index grows linearly; with UUID v4, it grows in a fan pattern requiring aggressive autovacuum to reclaim dead pages.
3. Makes time-range scans naturally sequential. A `WHERE transaction_date BETWEEN ...` query on a UUID v7 keyed table can use the PK as an approximate time filter before hitting the composite date index.

The trade-off: UUID v7 leaks approximate creation time to anyone reading the ID. For business-data records, this is acceptable — the creation time is not sensitive. For invitation tokens and session IDs (which are externally-visible credentials), UUID v4 is used per `data_layer_conventions_policy`.

---

## Index catalogue

### (a) Primary key index — UUID v7, B-tree, clustered

```sql
-- Implicitly created by the PRIMARY KEY constraint:
CONSTRAINT transactions_pkey PRIMARY KEY (id)
-- uuid v7 → monotonically increasing → no manual CLUSTER needed
-- Fill factor: default 90 (Postgres default); adjust to 80 if autovacuum lag observed
```

**Serves:** single-row lookups by `id` (drill-down, audit trail reconstruction, match-record FK joins).

**Notes:** because UUID v7 is monotonically increasing, the PK index behaves like a clustered index — new inserts always land at the end. Physical table order does not drift from index order over time, keeping cache efficiency high.

---

### (b) Composite `(business_id, transaction_date DESC)` — time-range dashboard queries

```sql
CREATE INDEX idx_transactions_business_date
  ON transactions (business_id, transaction_date DESC);
```

**Serves:** dashboard date-range queries: "show all transactions for business X between dates A and B." This is the most frequent read path. The `DESC` ordering matches the default UI sort (newest first).

**Notes:**
- `business_id` is the leading column because the RLS `USING` clause filters by `business_id = ANY(current_user_businesses())`. Leading with `business_id` activates index use even without a date filter.
- This index also serves the workflow filter passes (`OUT_FILTER`, `IN_FILTER`) which scan transactions within a business for a period.

---

### (c) Composite `(business_id, workflow_run_id)` — per-run transaction lookups

```sql
CREATE INDEX idx_transactions_business_run
  ON transactions (business_id, workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;
```

**Serves:** the execution loop's per-run queries: "fetch all transactions associated with this workflow run." Used by the classification phase, matching phase, and ledger-entry preparation.

**Notes:** partial index (`WHERE workflow_run_id IS NOT NULL`) excludes manually-entered or imported transactions that are not associated with a run, keeping the index smaller. `business_id` leads for RLS index activation.

---

### (d) `(source_row_hash)` — exact dedup, partial unique index

```sql
CREATE UNIQUE INDEX idx_transactions_source_hash
  ON transactions (business_id, source_row_hash)
  WHERE source_row_hash IS NOT NULL;
```

**Serves:** exact deduplication in the bank statement pipeline (Block 07 Phase 04). `source_row_hash` is the SHA-256 hex digest of the canonical JSON of the raw parsed row from the bank statement, per `data_layer_conventions_policy`. If a row with the same hash already exists for the business, the new import is classified as `DUPLICATE_EXACT`.

**Notes:** unique constraint is partial — NULL hashes (manually created transactions without a source row) are excluded. `business_id` is included in the index to scope uniqueness per tenant.

---

### (e) `(fingerprint)` — soft-dedup, non-unique

```sql
CREATE INDEX idx_transactions_fingerprint
  ON transactions (business_id, transaction_fingerprint)
  WHERE transaction_fingerprint IS NOT NULL;
```

**Serves:** soft deduplication — finding transactions with the same `{date, amount, account, normalized_description}` fingerprint, which may indicate a possible duplicate from a different import or a legitimate recurring transaction. Used by Block 07 Phase 04 to set `dedup_status = 'DUPLICATE_PROBABLE'`.

**Notes:** non-unique index (the same fingerprint can and should appear in legitimate recurring transactions). This index does not prevent inserts; it only accelerates the lookup that sets the `dedup_status` flag.

---

### (f) `(classification_status)` — queue processing, partial index

```sql
CREATE INDEX idx_transactions_unclassified
  ON transactions (business_id, created_at ASC)
  WHERE classification_status = 'UNCLASSIFIED';
```

**Serves:** the classification engine's work-queue scan: "fetch all UNCLASSIFIED transactions for business X in creation order." Created in ascending order to process oldest-first.

**Notes:** partial index (`WHERE classification_status = 'UNCLASSIFIED'`) keeps the index small — once a transaction is classified, it no longer needs to appear in this index and the row is automatically excluded. For a business with 10,000 transactions of which 500 are UNCLASSIFIED, this index covers only ~5% of the table.

---

## When to add a new index: decision rule

A new index on `transactions` is justified when **both** of the following thresholds are met:

1. **Query plan evidence** — `EXPLAIN (ANALYZE, BUFFERS)` shows a sequential scan (Seq Scan) on a table with > 10,000 rows for a query that executes more than once per workflow run. Index scans (Index Scan or Bitmap Index Scan) are the target for all hot-path queries.

2. **Volume threshold** — the query is estimated to execute at least 100 times per business per month (workflow run frequency × phases that invoke the query). One-off administrative queries do not justify a permanent index.

When both thresholds are met, a new index migration is drafted and reviewed. The migration MUST use `CREATE INDEX CONCURRENTLY` to avoid table locks during deployment.

---

## Adding indexes in migrations

```sql
-- Always use CONCURRENTLY for production table indexes
CREATE INDEX CONCURRENTLY idx_transactions_new_index
  ON transactions (...);

-- Never use without CONCURRENTLY for tables > 1,000 rows in production:
-- CREATE INDEX idx_transactions_blocking ON transactions (...);  -- BLOCKED in CI for large tables
```

A CI lint rule checks that migration files applying to the `transactions` table do not include `CREATE INDEX` without `CONCURRENTLY` (exception: initial migration only, before any data exists).

---

## Maintenance: `REINDEX CONCURRENTLY` schedule

B-tree indexes on high-insert tables accumulate dead pages from updated and deleted rows. For `transactions`, the expected pattern is append-heavy (new rows from statement imports) with moderate updates (status columns updated during workflow phases). Dead-page accumulation is low compared to a CRUD-heavy table, but the partial indexes (`idx_transactions_unclassified`) will see more churn as rows transition through `classification_status`.

Recommended maintenance schedule:
- **Weekly** — autovacuum runs nightly by default; verify via `pg_stat_user_tables` that `n_dead_tup` for `transactions` stays below 5% of `n_live_tup`. Alert if exceeded.
- **Monthly** — run `REINDEX CONCURRENTLY` on `idx_transactions_unclassified` (partial index with highest churn) during a low-traffic window.
- **Quarterly** — run `REINDEX CONCURRENTLY` on `idx_transactions_fingerprint` and `idx_transactions_business_date` to defragment.

```sql
-- Safe for production — does not lock the table:
REINDEX INDEX CONCURRENTLY idx_transactions_unclassified;
REINDEX INDEX CONCURRENTLY idx_transactions_fingerprint;
REINDEX INDEX CONCURRENTLY idx_transactions_business_date;
```

`REINDEX TABLE CONCURRENTLY transactions` (all indexes at once) should be reserved for post-bulk-import scenarios where all indexes show > 30% bloat.

---

## Index summary table

| Index name | Columns | Type | Partial? | Unique? | Primary access pattern |
| --- | --- | --- | --- | --- | --- |
| `transactions_pkey` | `(id)` | B-tree | No | Yes | Single-row lookup |
| `idx_transactions_business_date` | `(business_id, transaction_date DESC)` | B-tree | No | No | Dashboard date-range |
| `idx_transactions_business_run` | `(business_id, workflow_run_id)` | B-tree | Yes (`workflow_run_id IS NOT NULL`) | No | Per-run transaction fetch |
| `idx_transactions_source_hash` | `(business_id, source_row_hash)` | B-tree | Yes (`source_row_hash IS NOT NULL`) | Yes | Exact dedup |
| `idx_transactions_fingerprint` | `(business_id, transaction_fingerprint)` | B-tree | Yes (`transaction_fingerprint IS NOT NULL`) | No | Soft dedup |
| `idx_transactions_unclassified` | `(business_id, created_at ASC)` | B-tree | Yes (`classification_status = 'UNCLASSIFIED'`) | No | Classification queue |

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 monotonicity rationale; SHA-256 hex encoding for `source_row_hash` and `transaction_fingerprint`
- `audit_log_policies` — no direct audit events emitted by indexing strategy; audit events on transaction mutations are owned by the producing blocks
- `rls_policy_template` — `business_id` leading column design decision driven by RLS USING clause structure
- `Docs/phases/04_data_architecture/02_bank_statement_and_transaction_schema.md` — owning phase; enumerates all columns referenced by these indexes
- Block 07 Phase 04 — dedup logic that consumes `idx_transactions_source_hash` and `idx_transactions_fingerprint`
- Block 08 — classification engine that consumes `idx_transactions_unclassified`
- Block 10 — matching engine that joins via `idx_transactions_business_run`
