# cross_source_index_schema

**Category:** Schemas · **Owning block:** 09 — Document Intake & Extraction · **Co-owner:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

The index strategy and query plans that back Block 09 Phase 08's cross-source document deduplication. Per Block 09 Phase 08's sub-doc hook "Index strategy sub-doc — query plans, partial indexes if needed at scale" — the canonical contract for how `documents` and `document_source_links` are indexed so that cross-source hash lookups, active-vs-dismissed filtering, and per-source provenance walks all stay inside the Block 09 row of `fixture_performance_budget`.

Cross-source dedup is the act of recognising that the same content (same `document_hash` per `data_layer_conventions_policy`) was discovered through multiple paths — email finder, Drive finder, manual upload. The index strategy must support O(1) lookup of "have I seen this content before" at every finder invocation, while staying compact under the volume of dismissed-but-historically-recorded documents.

---

## Index inventory

The three tables involved:

- `documents` — one row per logical document
- `document_source_links` — one row per (document, source-path) observation
- `manual_upload_re_entries` — re-entry records when a user splits a `DUPLICATE_PROBABLE` (per `tool_manual_upload_re_entry`)

### `documents` indexes for cross-source dedup

```sql
-- Primary cross-source dedup lookup: "have I seen this hash before within this business?"
CREATE UNIQUE INDEX idx_documents_business_hash_active
  ON documents(business_id, document_hash)
  WHERE state <> 'DISMISSED';

-- Historical hash lookup including dismissed (used by re-entry tool's "intentional new" path)
CREATE INDEX idx_documents_business_hash_all
  ON documents(business_id, document_hash);

-- State-bucketed scan: "active documents needing OCR / extraction"
CREATE INDEX idx_documents_state_pending
  ON documents(business_id, state, created_at)
  WHERE state IN ('DISCOVERED', 'INGESTED');
```

The first index is the workhorse — partial on `state <> 'DISMISSED'` because the active fleet is dramatically smaller than the historical fleet (per Block 14 retention metrics, dismissed documents accumulate over 6 years). The partial index keeps cross-source dedup queries scanning only live rows; the second index lets `tool_manual_upload_re_entry`'s `CONFIRM_AS_NEW` path explicitly check "did this hash exist historically" without paying the full-history cost on every finder invocation.

### `document_source_links` indexes

```sql
-- Per-document provenance walk: "every source that has discovered this document"
CREATE INDEX idx_source_links_document
  ON document_source_links(document_id, observed_at DESC);

-- Per-source idempotency: "have I already linked this source to this document?"
CREATE UNIQUE INDEX idx_source_links_unique
  ON document_source_links(business_id, document_id, source_kind, source_external_id);

-- Cross-business provenance scan (ops queries, not application path)
CREATE INDEX idx_source_links_business_observed
  ON document_source_links(business_id, observed_at DESC);
```

The unique index enforces "the same external ID cannot link to the same document twice" — finder reruns hit `ON CONFLICT DO NOTHING` rather than producing duplicate rows.

### `manual_upload_re_entries` index

```sql
CREATE INDEX idx_re_entries_original
  ON manual_upload_re_entries(business_id, original_document_id);
```

Used by the audit-history view to walk "every re-entry decision on a given duplicate-flagged document."

## Active vs dismissed: partial-index strategy

The asymmetry between active and dismissed documents drives the partial-index choice. At steady state:

| Cohort | Cardinality (per business, year 6 of retention) | Index pressure |
| --- | --- | --- |
| Active (`DISCOVERED`, `INGESTED`, `LINKED_TO_*`) | ~5–20% | hot |
| Dismissed (`DISMISSED`) | ~80–95% | cold |

A non-partial unique index on `(business_id, document_hash)` would contend with dismissed-row writes (state transitions from `INGESTED → DISMISSED` rewrite the index entry) and inflate B-tree pages with rows the active query path never reads. The partial index avoids both costs.

The trade-off: the partial index does NOT enforce uniqueness against dismissed rows. A user can re-discover dismissed content through a new source; the partial-index lookup misses it, and the document is correctly treated as new (per `tool_manual_upload_re_entry`'s rationale). When the user explicitly wants the dismissed row resurrected, the audit log carries the prior dismissal — the second-discovery flow is "create a new active row + record the historical dismissed row in the audit chain."

## Query plans

### Query 1 — Cross-source dedup check (Block 09 Phase 08 hot path)

```sql
SELECT document_id, state, source AS first_source
FROM documents
WHERE business_id  = $1
  AND document_hash = $2;
```

**Plan:** index-only scan on `idx_documents_business_hash_active`. The query intentionally omits a `state <> 'DISMISSED'` predicate — when the partial index matches, the active row is returned; when no row matches, an empty result correctly indicates "no active duplicate" and the finder creates a new document.

**Latency budget:** per the Block 09 row of `fixture_performance_budget` (`intake_cross_source_dedupe_100_documents` at P50 1 s, P95 3 s, P99 6 s) — that fixture exercises 100 lookups + 100 link inserts. Per-lookup target: P95 < 30 ms, P99 < 60 ms.

### Query 2 — Provenance for an existing document

```sql
SELECT source_kind, source_external_id, observed_at
FROM document_source_links
WHERE document_id = $1
ORDER BY observed_at DESC;
```

**Plan:** index-only scan on `idx_source_links_document`. Result set is at most ~3–5 rows per document (the realistic source-fan-out cap). Latency: < 5 ms.

### Query 3 — User-initiated "intentional new" check (`tool_manual_upload_re_entry` CONFIRM_AS_NEW)

```sql
SELECT document_id, state
FROM documents
WHERE business_id  = $1
  AND document_hash = $2;
```

**Plan:** index scan on `idx_documents_business_hash_all` — explicitly includes dismissed rows so the re-entry seed can be appended to avoid hash collision with historical content. Latency: P95 < 100 ms (slightly higher than Query 1 because the index is full, not partial).

### Query 4 — Finder dry-run "how many cross-source dupes would I produce?"

```sql
SELECT d.document_id, COUNT(dsl.id) AS source_count
FROM documents d
JOIN document_source_links dsl USING (document_id)
WHERE d.business_id  = $1
  AND d.state <> 'DISMISSED'
  AND dsl.observed_at >= $2
GROUP BY d.document_id
HAVING COUNT(dsl.id) > 1;
```

**Plan:** uses `idx_documents_business_hash_active` to filter active, then nested-loop into `idx_source_links_document` per row. Used by the Phase 08 fixture suite; not in the application hot path.

## Per-business idempotency

Per Block 09 Phase 08: cross-source dedup is scoped to `(business_id, document_hash)`. The unique partial index enforces this — two businesses can independently hold the same content without collision. The cross-business hash visibility surface does not exist; an attacker cannot probe other businesses' documents by computing hashes because the RLS predicate gates the index lookup before the partial-index narrows.

## Confidence-boost interaction

When `Query 1` returns a hit, the cross-source dedup engine emits `DOCUMENT_CROSS_SOURCE_DEDUPED` (per `audit_event_taxonomy`) and updates `documents.discovery_confidence` per Phase 08's boost rule (`min(0.95, max_source_confidence + 0.10)`). The update is a single UPDATE statement, not a recompute — the index is unaffected.

## State-transition impact on indexes

Documents move through:

```
DISCOVERED → INGESTED → LINKED_TO_<target> | DISMISSED
DUPLICATE_PROBABLE → NEW (via re-entry) | LINKED_TO_<target> | DISMISSED
NEEDS_REVIEW → NEW | DISMISSED
```

Per the partial-index strategy:

- Transitions into `DISMISSED` cause the row to drop out of `idx_documents_business_hash_active`. The B-tree write is one delete operation per transition.
- Transitions out of `DISMISSED` (rare; `tool_manual_upload_re_entry` does not move back into active states — it creates fresh rows) are a non-issue.
- Transitions within active states (`DISCOVERED → INGESTED`) do not move the row in/out of the partial index; the `state` column is not indexed in `idx_documents_business_hash_active`.

The third bullet matters: the dedup lookup doesn't filter by state beyond the partial predicate, so an `INGESTED` document and a `DISCOVERED` document with the same hash are both candidates. Phase 08's logic handles the merge by preferring the `INGESTED` row (it's already past OCR / extraction; the new discovery becomes a `document_source_links` row, not a re-OCR).

## Recovery & re-indexing

Index drift recovery follows the standard Postgres `REINDEX CONCURRENTLY` runbook. Because the dedup hot path is read-only against the partial index, reindexing does not block writers. Cross-source dedup operates on the rebuilt index when it completes; until then, the planner falls back to `idx_documents_business_hash_all`, which is slower but correct.

## Performance budgets summary

| Operation | P50 | P95 | P99 | Source |
| --- | --- | --- | --- | --- |
| Cross-source dedup lookup (single hash) | < 5 ms | < 30 ms | < 60 ms | derived from `fixture_performance_budget` |
| Cross-source dedup batch (100 hashes) | 500 ms | 1 s | 2 s | derived |
| Full fixture `intake_cross_source_dedupe_100_documents` | 1 s | 3 s | 6 s | `fixture_performance_budget` Block 09 |
| Provenance walk (single document, ≤ 5 sources) | < 5 ms | < 15 ms | < 30 ms | derived |

The single-hash budget is dominated by the partial-index B-tree height plus RLS predicate evaluation — both negligible. The batch budget assumes pipelined lookups inside one DB connection.

## RLS

Standard tenant isolation per `documents`' existing RLS:

```sql
CREATE POLICY documents_business_isolation ON documents
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));

CREATE POLICY source_links_business_isolation ON document_source_links
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

The RLS predicate is evaluated before the partial-index lookup; cross-business hash visibility is impossible regardless of index structure.

## Audit emission

Per `audit_event_taxonomy`, cross-source dedup emits exactly one event per detected duplicate:

- `DOCUMENT_CROSS_SOURCE_DEDUPED` — fires on every successful dedup hit, carrying both source kinds (first + new).

The event payload includes `{ document_id, primary_source_kind, new_source_kind, source_count_after }` and is canonical-JSON-serialised per `data_layer_conventions_policy`. The emit follows `audit_log_policies` Section 4 per-business chain partitioning and the emit-as-separate-transaction rule. A dedup hit that produces no third-source observation does not emit a "third source observed" event in MVP — Block 09 Phase 08's earlier proposal of `DOCUMENT_THIRD_SOURCE_OBSERVED` was not catalogued and is folded into the single dedup event with `source_count_after = 3`.

## Mobile considerations

The cross-source dedup engine runs server-side via finder workers (email finder, Drive finder) and the manual-upload pipeline. No mobile surface writes directly to `documents` or `document_source_links` — the upstream `intake.upload_document` API is mobile-rejected per `mobile_write_rejection_endpoints`.

## Cross-references

- `tool_manual_upload_re_entry` — `CONFIRM_AS_NEW` path uses `idx_documents_business_hash_all`
- `data_layer_conventions_policy` — SHA-256 hex `document_hash`, UUID v7 for `document_id`
- `audit_log_policies` — per-business chain partitioning, emit-as-separate-transaction
- `audit_event_taxonomy` — `DOCUMENT_CROSS_SOURCE_DEDUPED`, `DOCUMENT_MANUAL_UPLOADED`, `DOCUMENT_EMAIL_FINDER_RAN`, `DOCUMENT_DRIVE_FINDER_RAN`
- `fixture_performance_budget` — Block 09 latency targets
- `mobile_write_rejection_endpoints` — `intake.upload_document` rejects mobile
- `document_line_items_schema` — sibling schema for extracted line items
- Block 09 Phase 08 — cross-source document deduplication
- Block 09 Phase 01 — `documents` and `document_source_links` schema
- Block 09 Phase 02 — document lifecycle state machine
- Block 04 Phase 03 — `documents.document_hash` column definition
- Block 04 Phase 01 — `hashFile` helper
