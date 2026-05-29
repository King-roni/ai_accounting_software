# audit_history_slice_query_schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The SQL query patterns Block 16 Phase 02 and Phase 08 use to render the per-record "Audit history" tab in drill-down detail views. The surface is keyed by `subject_id` (the polymorphic id of the record under inspection) and returns a chronological audit-log slice respecting `audit_log_policies` RLS overlay.

This sub-doc pins the SQL shape, the index dependencies, the per-role visibility filtering, and the latency budget. It does NOT define the audit log itself — that's owned by Block 05 Phase 02.

---

## Surface contract

```ts
dashboard.getAuditHistorySlice({
  business_id: uuid,
  subject_id: uuid,
  subject_kind: SubjectKind,                  // per review_issues_schema subject_kind_enum
  from?: timestamptz,                         // optional time-range lower bound
  to?: timestamptz,                           // optional upper bound
  page_cursor?: string,                       // opaque cursor per Phase 02 cursor pagination
  limit?: integer,                            // default 50, max 200
  actor_role: Role,                           // the requester's resolved role on the business
}): {
  events: AuditEventSlice[],
  next_cursor: string | null,
  has_more: boolean,
}
```

Each `AuditEventSlice` is a redacted projection of an `audit_log` row — see "Per-role visibility filtering" below.

## Canonical SQL pattern

The base query — the variant for the most common case (no time bound, default page):

```sql
SELECT
  al.event_id,
  al.event_type,
  al.event_time,
  al.actor_user_id,
  al.actor_role,
  al.chain_id,
  al.sequence_number,
  al.chain_hash,
  al.event_payload                                   -- JSONB; may be redacted in projection
FROM audit_log al
WHERE al.business_id = $business_id
  AND al.subject_id = $subject_id
  AND al.subject_kind = $subject_kind
  AND ($from IS NULL OR al.event_time >= $from)
  AND ($to IS NULL OR al.event_time < $to)
  AND al.event_id > $page_cursor_event_id            -- cursor decode
ORDER BY al.event_time ASC, al.event_id ASC
LIMIT $limit + 1;                                    -- + 1 to compute has_more
```

The trailing `+1` is the standard cursor-pagination idiom — if the result has `$limit + 1` rows, `has_more = true` and the cursor is the last visible row's `event_id`.

`subject_kind` is matched against the polymorphic kind enum: `transactions`, `documents`, `match_records`, `invoices`, `ledger_entries`, `workflow_runs`. Per `review_issues_schema` `subject_kind_enum`.

## Index dependency

Per `audit_log_policies` Section 3 "Indexed lookups":

```sql
CREATE INDEX idx_audit_log_subject
  ON audit_log(business_id, subject_id, event_time);
```

This index is the canonical lookup path. The composite supports:

- Subject-keyed history for one record (this surface) — P95 < 100 ms per `audit_log_policies` target
- Subject-keyed history across a time window — same index, range scan on the trailing column
- Subject-keyed last-N events — same index, backward scan with LIMIT

A second covering index on `(business_id, subject_kind, subject_id, event_time)` is OPTIONAL — only added if profiling shows the `subject_kind` filter doesn't selectively prune at the table layer. MVP ships without it; Stage 2+ may add it.

## Per-role visibility filtering

Per `audit_log_policies` Section 2: RLS restricts which events a role can read. The slice query MUST be invoked under the requester's session — RLS denies cross-business reads automatically.

Per-role event filtering happens via the RLS policy declared alongside the table. The query above doesn't need to add `event_type IN (...)` filters — RLS handles it.

| Role | Effect on this query |
| --- | --- |
| **Owner** | All event rows returned |
| **Admin** | All EXCEPT `KEY_*` / `BACKUP_KEY_*` domains |
| **Bookkeeper** | All EXCEPT `KEY`, `BACKUP`, `GDPR`, `SECURITY` domains AND EXCEPT events whose `actor_role = Accountant` |
| **Accountant** | Operational/reporting/ledger domain events only per `audit_log_policies` |
| **Reviewer** | `REVIEW`, `WORKFLOW`, `WORKFLOW_GATE`, `FINALIZATION` domains only; actor PII (email, IP) masked at the projection layer |
| **Read-only** | `WORKFLOW`, `FINALIZATION` domains only |

The actor-PII masking is NOT done in SQL — it's done in the API projection layer per Block 05 Phase 06's access control runtime. The SQL returns full rows; the projection redacts.

## Per-role projection redaction

After SQL returns rows, the projection masks fields based on `actor_role`:

| Field | Visible to | Hidden from |
| --- | --- | --- |
| `actor_user_id` | All authorized roles | — |
| `actor_email` (from a join) | Owner, Admin, Bookkeeper, Accountant | Reviewer (masked as `"<reviewer-hidden>"`), Read-only |
| `actor_ip` | Owner, Admin | Bookkeeper, Accountant, Reviewer, Read-only |
| `event_payload.decrypted_field_marker` (if present) | Owner only | All others — masked to `"<marker-hidden>"` |
| `chain_hash`, `sequence_number` | All authorized roles | — (these are integrity values, not PII) |

The projection layer uses `withAccessControl` from Block 02 Phase 06.

## Latency budget

Per `audit_log_policies` Section 3 + `fixture_performance_budget`:

| Scenario | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Subject with < 50 events, no time bound | 5 ms | 30 ms | 100 ms |
| Subject with 50–500 events, no time bound | 20 ms | 100 ms | 300 ms |
| Subject with > 500 events, time-range scan | 50 ms | 500 ms | 2 s |
| Cross-month time-range scan (cold) | 200 ms | 2 s | 5 s |
| Anything exceeding 5 s | killed by `statement_timeout`; `SECURITY_AUDIT_QUERY_TIMEOUT` audit event |

The 5-second `statement_timeout` is the cap. Users requesting a wider window than the index supports see a structured error ("This range exceeds the dashboard's query budget — use the export pipeline") rather than a runtime exception.

## Cursor format

Opaque to consumers; internally a base64url-encoded canonical JSON object:

```json
{ "event_id": "01900000-0000-7000-0000-000000000000", "event_time": "2026-04-15T10:23:45Z" }
```

Per `data_layer_conventions_policy`: canonical JSON, UUID v7, ISO 8601 timestamps.

The cursor enforces stable pagination across refreshes — adding a new event mid-pagination doesn't shift the visible window. The `event_id` is the primary sort key; `event_time` is decoration for client display.

## Aggregated events

Per `audit_event_taxonomy`: some events are aggregations (e.g., `OUT_FILTER_RAN`, `ARCHIVE_DATA_READ_SESSION_SUMMARY`, `FINALIZATION_LEDGER_BULK_LOCKED`). The slice query returns these as-is; the UI renders them with an "Aggregated" badge so the user understands a single visible row represents many underlying operations.

The aggregation does NOT lose information — the aggregated event's `event_payload` carries the per-affected-id list.

## Audit event for this surface

Reading the audit log IS itself an auditable event:

| Event | When | Payload |
| --- | --- | --- |
| `DASHBOARD_AUDIT_HISTORY_SLICE_READ` | Per call | `{ business_id, subject_id, subject_kind, event_count_returned, time_range, actor_role }` |

This event lives under the `DASHBOARD` domain per `audit_log_policies` allowlist. Per Stage 1 audit-volume control: the event is emitted at the per-record-detail level, NOT per-event-row-returned.

A user repeatedly opening the same record's audit history within 5 minutes emits one event (deduped per session per record per 5-min window). The dedup mechanism is per `audit_log_policies` "Aggregation events".

## Reverse lookup — from event back to record

Often a user reads an event and wants to navigate to the record it touched. The reverse direction is a Block 05 surface, not this one — Block 16 Phase 02 links events to record-detail pages via the `subject_id` on each event row.

## Mobile read-only

This surface is read-only — `dashboard.getAuditHistorySlice` is NOT in the `mobile_write_rejection_endpoints` list. Mobile clients can fetch their own audit history slice for drill-down inspection.

The per-role projection runs identically on mobile.

## Concurrent slice queries

Two users querying the same record's audit history slice do not contend — they both run read-only SQL with no row locks. Postgres MVCC isolates them.

The per-role projection is per-request; one user's projection does not affect another's.

## Failure modes

| Failure | Behavior |
| --- | --- |
| Subject doesn't exist | Returns empty `events` array; no error (consistent with permission-denied "no leakage") |
| Subject exists but no events ever recorded | Same as above |
| Query exceeds 5s `statement_timeout` | Postgres kills; surface returns structured error; `SECURITY_AUDIT_QUERY_TIMEOUT` event fires |
| RLS denies all rows | Returns empty `events` array; no error |
| Cursor decode failure | Returns 400 with `invalid_cursor` error |

## Cross-references

- `audit_log_policies` — RLS overlay, naming, query patterns, chain partitioning
- `audit_event_taxonomy` — what event types may appear in the slice
- `data_layer_conventions_policy` — UUID v7, canonical JSON, cursor format
- `review_issues_schema` — `subject_kind_enum` shared
- `permission_matrix` — `DASHBOARD_VIEW` surface
- `tool_hash_chain_append` — what produces the events being read
- Block 16 Phase 02 — drill-down routing
- Block 16 Phase 08 — detail-view audit-history tab
- Block 05 Phase 02 — audit log schema + `emitAudit()`
- Block 05 Phase 06 — access control runtime + per-role redaction
- Block 02 Phase 04 — permission matrix consumed by RLS
- `fixture_performance_budget` — latency budget
- 2026-05-08 decisions-log amendment — aggregated event emissions
