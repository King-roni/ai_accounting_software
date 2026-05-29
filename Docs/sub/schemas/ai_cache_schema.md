# AI Cache Schema

**Block:** 06 — AI Layer
**Category:** Schemas
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Documents the within-run AI response cache (`ai_cache_entries` table). The cache
prevents duplicate LLM invocations for identical inputs within a single workflow run,
reducing latency and cost on resumed or retried runs. The cache is strictly run-scoped;
no entry is ever shared across `workflow_run_id` boundaries.

---

## Table DDL

```sql
CREATE TABLE ai_cache_entries (
  id                  UUID        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id         UUID        NOT NULL REFERENCES business_entities(id),
  workflow_run_id     UUID        NOT NULL REFERENCES workflow_runs(id),
  cache_key           TEXT        NOT NULL,   -- SHA-256 hex (64 chars)
  prompt_key          TEXT        NOT NULL,
  prompt_version      TEXT        NOT NULL,   -- semver string e.g. "1.0.0"
  response_payload    JSONB       NOT NULL,
  tier_used           TEXT        NOT NULL,   -- 'TIER_1' | 'TIER_2' | 'TIER_3'
  tokens_used         INTEGER     NOT NULL CHECK (tokens_used >= 0),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at          TIMESTAMPTZ NOT NULL
    GENERATED ALWAYS AS (created_at + INTERVAL '7 days') STORED,

  CONSTRAINT ai_cache_entries_key_per_run UNIQUE (workflow_run_id, cache_key)
);

CREATE INDEX ai_cache_entries_lookup
  ON ai_cache_entries (workflow_run_id, cache_key);

CREATE INDEX ai_cache_entries_expiry
  ON ai_cache_entries (expires_at)
  WHERE expires_at < NOW();
```

`id` uses `gen_uuid_v7()` (time-ordered, B-tree-friendly) per
`data_layer_conventions_policy`. `business_id` is denormalised onto the table to
support tenant-scoped queries and RLS without a join to `workflow_runs`.

`expires_at` is a generated column set to `created_at + INTERVAL '7 days'`, matching
the Processing zone TTL. The column is not updatable; cache entries cannot have their
TTL extended.

---

## Cache Key Derivation

```
cache_key = LOWER(HEX(SHA-256(
  prompt_key || ':' || prompt_version || ':' || canonical_json(input_payload)
)))
```

**Canonical JSON** follows `data_layer_conventions_policy` Section 3: object keys
sorted lexicographically by UTF-16 codepoint, no insignificant whitespace, nulls
explicit, arrays in insertion order. The same logical input always produces the
same canonical JSON bytes regardless of serialization order from the caller.

**Example derivation:**

```
prompt_key      = "document_extraction_v1"
prompt_version  = "1.2.0"
input_payload   = { "page_count": 3, "raw_text": "Invoice ...", "source_type": "PDF" }

canonical_json  = '{"page_count":3,"raw_text":"Invoice ...","source_type":"PDF"}'
hash_input      = "document_extraction_v1:1.2.0:{\"page_count\":3,...}"
cache_key       = SHA-256(hash_input) as 64-char lowercase hex
```

Because `prompt_version` is included in the hash input, a version bump (e.g. `1.2.0`
→ `2.0.0`) produces a different `cache_key` for the same `input_payload`. No explicit
cache invalidation is needed when a prompt version changes.

---

## Hit Path

`ai.invoke` checks the cache before dispatching to the LLM provider:

1. Compute `cache_key` from the prompt key, prompt version, and input payload.
2. Query `ai_cache_entries` for a row matching `(workflow_run_id, cache_key)` where
   `expires_at > NOW()`.
3. **On hit:** return the cached `response_payload` with the field `cached: true`
   injected at the top level of the response. No `ai_invocation_records` row is
   written. No cost is recorded. Audit event: `AI_CACHE_HIT`.
4. **On miss:** proceed to the LLM gateway. On success, insert a new
   `ai_cache_entries` row. Audit event: `AI_CACHE_STORED`.

The hit check runs inside the same database transaction as the tool invocation's dedup
check, ensuring that a resumed run that re-executes a tool sees the same cached
response as the original execution (provided the run's 7-day window has not expired).

---

## Cache Miss and Storage

On a cache miss, after a successful LLM response:

```sql
INSERT INTO ai_cache_entries (
  business_id, workflow_run_id, cache_key,
  prompt_key, prompt_version, response_payload,
  tier_used, tokens_used
)
VALUES (
  $business_id, $workflow_run_id, $cache_key,
  $prompt_key, $prompt_version, $response_payload,
  $tier_used, $tokens_used
)
ON CONFLICT (workflow_run_id, cache_key) DO NOTHING;
```

`ON CONFLICT DO NOTHING` handles the race where two concurrent tool invocations in the
same run compute the same cache key simultaneously. The first writer wins; the second
discards its result and re-reads the row on the hit path.

---

## Data Zone and TTL

`ai_cache_entries` lives in the Processing zone. Processing zone TTL is 7 days
post-run per `data_layer_conventions_policy`.

A nightly background job deletes rows where `expires_at < NOW()`:

```sql
DELETE FROM ai_cache_entries
WHERE expires_at < NOW();
```

The job runs at 03:00 UTC and targets a maximum of 10,000 rows per execution to avoid
long-running deletes that contend with live queries. If more rows are eligible, the
job re-runs at the next scheduled window. Audit event on each purge batch:
`AI_CACHE_EVICTED` (LOW, with payload `rows_deleted`, `run_at`).

---

## No Cross-Run Sharing

Cache entries carry a `workflow_run_id` FK and the unique constraint covers
`(workflow_run_id, cache_key)`. A run cannot read another run's cache entries. There
is no API to copy cache entries between runs.

This restriction is intentional: the same input prompt may produce a valid response in
run A that is stale or inappropriate in run B (e.g., the business's AI config changed
between runs, or a manual review changed upstream data). Run-scoping avoids this class
of stale-cache bugs entirely.

---

## No Explicit Invalidation API

There is no `ai.invalidate_cache` tool and no API endpoint to delete cache entries for
a specific key. Cache entries expire via TTL only. Prompt version bumps produce new
cache keys naturally. If a specific entry must be removed (e.g., a bad LLM response
was cached), the only path is a direct database delete by a platform operator, which
emits `AI_CACHE_EVICTED`.

---

## RLS

`ai_cache_entries` is protected by RLS. The policy enforces `business_id` isolation:

```sql
CREATE POLICY ai_cache_entries_isolation ON ai_cache_entries
  USING (business_id = auth.current_business_id());
```

Application roles cannot read or write cache entries for other businesses. The
workflow engine's internal role (`app.engine_role`) bypasses RLS for the cache insert
and hit-check paths.

---

## Cross-references

- `tool_gateway_invoke_ai.md` — `ai.invoke` implementation; hit path and cache-store
  path live here
- `business_ai_config_schema.md` — per-business AI config; tier and cost ceiling used
  when a cache miss falls through to the LLM
- `data_layer_conventions_policy.md` — canonical JSON serialization (Section 3) and
  SHA-256 encoding (Section 1) used in cache key derivation
- `audit_event_taxonomy.md` — `AI_CACHE_HIT`, `AI_CACHE_STORED`, `AI_CACHE_EVICTED`
- Block 06 Phase 09 — AI cache within-run (phase doc)
