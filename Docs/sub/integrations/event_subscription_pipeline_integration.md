# event_subscription_pipeline_integration

**Category:** Integrations · **Owning block:** 03 — Workflow Engine · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The internal event-bus contract — how blocks subscribe to audit-log events to react to cross-block signals like `ARCHIVE_PROMOTION_COMPLETED`, `STATEMENT_UPLOAD_COMPLETED`, `WORKFLOW_RUN_STATE_CHANGED`. Backed by Postgres LISTEN/NOTIFY + a subscription registry; not a separate message queue per the 2026-05-08 amendment.

---

## Subscription API

Per Block 05 Phase 02 — the canonical implementation home for `subscribeByEventType`.

```ts
// At service boot
subscribeByEventType("ARCHIVE_PROMOTION_COMPLETED", async (event) => {
  // event.payload has the structured payload from the emit
  await rebuild_analytics_for_period(event.payload);
});

subscribeByEventType("STATEMENT_UPLOAD_COMPLETED", async (event) => {
  await trigger_ingestion_workflow(event.payload);
});
```

Registration is boot-time. Adding a subscription at runtime is not supported (avoids race conditions with mid-flight events).

## Underlying mechanism — Postgres LISTEN/NOTIFY

```
1. emitAudit() inside Block 05 Phase 02 inserts the audit_log row + calls NOTIFY channel '<event_type>' with the event_id
2. Subscribers LISTEN on the channel
3. On NOTIFY receipt, the subscriber's connection fetches the audit_log row for the event_id
4. The subscriber's handler runs in its own transaction
5. trigger_events_processed records the outcome per trigger_events_processed_schema
```

The NOTIFY-receipt-to-handler latency is typically < 100 ms.

## Guaranteed delivery (with caveats)

Postgres NOTIFY is **best-effort** — a subscriber that's offline during the NOTIFY misses it. Per Block 03 Phase 07's resumability framework:

1. Each subscriber tracks its last-processed `event_id` per event_type in `subscription_progress`
2. On service restart, the subscriber catches up by reading audit_log rows newer than the last-processed event_id
3. The dedup table (`trigger_events_processed`) ensures handler side-effects are idempotent

```sql
CREATE TABLE subscription_progress (
  subscription_kind           text PRIMARY KEY,                   -- the subscription identifier
  last_processed_event_id     uuid,
  last_processed_at           timestamptz,
  catchup_in_progress         boolean NOT NULL DEFAULT false
);
```

On boot: subscriber sets `catchup_in_progress = true`, reads audit_log from `last_processed_event_id + 1` forward in event_id order, processes each, updates `last_processed_event_id`. Sets `catchup_in_progress = false` when caught up. After catchup, switches to LISTEN/NOTIFY for steady-state.

## Cross-business ordering

Per `audit_log_policies` Section 4 — three-chain partitioning. NOTIFY channels are per event_type, not per chain. Subscribers consume events in `event_id` order; UUID v7's time-ordering gives a coarse global ordering, but within the same millisecond, ordering across chains is unspecified.

Subscribers that need strict per-business ordering filter the audit_log query by business_id; UUID v7 inside a single chain is strictly monotonic.

## Subscriber failure handling

| Outcome | Recorded as | Behavior |
| --- | --- | --- |
| Handler succeeds | `trigger_events_processed.outcome = PROCESSED` | Move on |
| Handler throws transient (DB timeout, network) | `outcome = TRANSIENT_FAILURE` | Retry per Block 03 Phase 08 retry policy |
| Handler throws permanent (validation, missing data) | `outcome = PERMANENT_FAILURE` | Raise review issue; do not retry |
| No subscriber registered | `outcome = NO_MATCHING_SUBSCRIPTION` | Recorded; no action |

Retry uses the same exponential backoff scheme as `event_emission_transactional_policy` (1s → 2s → 4s → 8s, max 4 retries).

## Subscriber concurrency

A single subscription handler processes events serially for the same `subscription_kind`. The handler MAY parallelize internally (e.g., the analytics rebuild may fan out to per-card MV refreshes), but the outer subscription processes events in arrival order to preserve handler-side ordering.

Multiple distinct subscription_kinds run concurrently — Block 16's dashboard refresh and Block 04's analytics rebuild both react to the same event simultaneously.

## Subscription registry

```sql
CREATE TABLE event_subscriptions (
  subscription_kind           text PRIMARY KEY,
  handler_module              text NOT NULL,                       -- e.g., 'block_04.analytics_refresh_subscriber'
  event_types                 text[] NOT NULL,                     -- the events this subscription reacts to
  enabled                     boolean NOT NULL DEFAULT true,
  registered_at               timestamptz NOT NULL DEFAULT now(),
  last_invoked_at             timestamptz
);
```

The registry is read at boot. Disabled subscriptions don't register a LISTEN — useful for staged deployment where a new subscription's handler is rolled out gradually.

## Audit events

| Event | When |
| --- | --- |
| `EVENT_SUBSCRIPTION_REGISTERED` | At boot per subscription_kind |
| `EVENT_SUBSCRIPTION_DISABLED` | When `enabled = false` is set |
| `WORKFLOW_TOOL_INVOKED` | Subscriber handler invoked (general) |
| `TRIGGER_EVENTS_PROCESSED_RECORDED` | Outcome recorded |

Per `audit_log_policies` aggregation: high-volume events (e.g., `WORKFLOW_RUN_STATE_CHANGED` consumed by dashboard) are aggregated per-session.

## Performance

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| NOTIFY → handler invocation | 50 ms | 200 ms | 1 s |
| Catchup (1000 backlog events) | 5 s | 30 s | 90 s |
| Handler dispatch | depends on handler — see per-block budgets |

## Throughput

Postgres NOTIFY supports thousands of messages per second per channel. The bottleneck is typically the handler's processing rate, not the channel.

A heavy-volume subscription (e.g., `WORKFLOW_RUN_STATE_CHANGED` consumed by dashboard refresh) handles ~100 events / second per business in steady state.

## Subscription registration

Consumers register subscriptions by calling `subscribeByEventType(event_type, handler)` at service boot. The call inserts a row into `event_subscriptions` if one does not exist for the `subscription_kind`, or updates `last_invoked_at` on boot if the subscription is already registered. Duplicate registration of the same `subscription_kind` at boot is idempotent — the handler reference is updated in memory; no duplicate DB row is created. Runtime registration (after boot) is not supported; any call to `subscribeByEventType` after the boot phase throws an `ILLEGAL_RUNTIME_SUBSCRIPTION` error.

## Event ordering guarantees

Events are delivered in `event_id` (UUID v7) order per subscription, which corresponds to insertion order within a business chain. Within a single business, ordering is guaranteed — a subscriber processing `ARCHIVE_PROMOTION_COMPLETED` for business A will see events in the order they were committed. Across different businesses, ordering is NOT guaranteed. A subscriber that processes events for multiple businesses concurrently must not assume that event A for business 1 preceded event B for business 2, even if their `event_id` values suggest an ordering.

## Dead-letter handling

Events that exhaust all retries (max 4 retries per Block 03 Phase 08 exponential backoff) are recorded in `trigger_events_processed` with `outcome = PERMANENT_FAILURE`. These become dead-lettered events. The system does not automatically re-deliver them. Recovery requires:
1. Operator identifies the `PERMANENT_FAILURE` rows via the `trigger_events_processed` table.
2. Root cause is resolved (e.g., missing upstream data, code bug fixed).
3. Operator re-queues via `engine.manual_trigger` referencing the original `event_id`, which replays the audit log row through the subscription handler with a fresh dedup key.

## Cross-references

- `audit_log_policies` — three-chain partitioning + canonical-emission semantics
- `audit_event_taxonomy` — the catalogue of subscribable events
- `trigger_events_processed_schema` — per-subscription dedup table
- `archive_promotion_completed_event_integration` — canonical example of a cross-block subscription
- `analytics_refresh_runbook` — analytics-rebuild subscriber procedure
- Block 03 Phase 07 — resumability framework (catchup mechanism)
- Block 03 Phase 09 — event-driven workflow trigger (architecture)
- Block 05 Phase 02 — `subscribeByEventType` API + NOTIFY emit
- 2026-05-08 decisions-log amendment — event-bus model (no separate queue)
