# archive_promotion_completed_event_integration

**Category:** Integrations · **Owning block:** 15 — Finalization & Secure Archive · **Co-owners:** 04, 16 · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The cross-block event-bus contract for `ARCHIVE_PROMOTION_COMPLETED` — the canonical signal that a period (or adjustment-finalization) has been archived and downstream consumers should react. Per the 2026-05-08 amendment: "The act of writing this audit event IS the analytics-enqueue mechanism (event-bus subscription model — no separate queue infrastructure)."

This integration replaced what would otherwise have been a separate message queue — by piggy-backing on the audit log (which already has subscription mechanics from Block 05 Phase 02), the system gets event-driven coordination without adding infrastructure.

---

## The event

```
event_type: ARCHIVE_PROMOTION_COMPLETED
domain: ARCHIVE
emitted by: Block 15 Phase 04 step 7 (original finalization) + Block 15 Phase 06 (adjustment-finalization)
```

### Payload shape

```json
{
  "archive_package_id": "<uuid>",
  "manifest_version_number": 1,
  "business_id": "<uuid>",
  "period_start": "2026-01-01",
  "period_end": "2026-01-31",
  "workflow_run_id": "<uuid>",
  "promoted_at": "2026-02-05T14:23:00Z",
  "is_adjustment_finalization": false
}
```

For adjustment-finalization: `is_adjustment_finalization = true`, `manifest_version_number > 1`, `workflow_run_id` is the `*_ADJUSTMENT` run that triggered the new bundle.

## Producers

| Source | Block 15 Phase | Trigger |
| --- | --- | --- |
| Original finalization | Phase 04 step 7 | After all 8 lock-sequence steps complete successfully |
| Adjustment finalization | Phase 06 | After adjustment-bundle promotion and manifest-v{N} write |

Both producers emit the event via `emitAudit("ARCHIVE_PROMOTION_COMPLETED", payload)` per Block 05 Phase 02's API.

Per the 2026-05-08 amendment: emit is a SEPARATE short transaction from the lock-sequence commit, handled by Block 03 Phase 07's resumability framework if the audit emit fails after the lock-sequence commit.

## Subscribers

Per `audit_event_taxonomy` cross-block events table:

| Block | Subscription handler | Reaction |
| --- | --- | --- |
| 04 | `analytics_rebuild_subscriber` | Triggers `archive.mv_ledger_entries_latest` MV refresh per `block_16_as_of_view_schema` |
| 16 | `dashboard_refresh_subscriber` | Invalidates dashboard cache; emits `DASHBOARD_REFRESH_REQUESTED` for any active session |
| 04 (auxiliary) | `retention_engine_subscriber` | Records the bundle in the retention scheduler for future Object Lock expiry checks |

Additional subscribers post-MVP: notification dispatch (email Owner that finalization completed), Block 16 export pipeline auto-invalidation, etc.

## Subscription mechanism

Per Block 05 Phase 02's `subscribeByEventType(event_type, handler)` API:

```ts
subscribeByEventType("ARCHIVE_PROMOTION_COMPLETED", async (event) => {
  const { archive_package_id, business_id, period_start, period_end } = event.payload;
  // Handler logic
});
```

The subscription registry lives in Block 05 Phase 02; handlers register at boot. The audit log emit triggers the matching subscriptions synchronously (within the same Postgres NOTIFY/LISTEN flow) but processes them in the subscriber's own transaction context.

## Dedup

Per `trigger_events_processed_schema`: each subscription records its observation of the event. The unique constraint `(business_id, event_id, subscription_kind)` prevents double-processing.

Re-runs of a subscription handler (e.g., service restart in the middle of handling) read the trigger_events_processed row before acting:

- If `outcome = PROCESSED`, the handler skipped (event already fully processed)
- If `outcome = CONCURRENT_RUN_BLOCKING` or similar, the handler retries

## Delivery guarantees

The integration is **at-least-once** with dedup. A subscriber may receive the same event multiple times (in failure-recovery scenarios) but the dedup table ensures the side effect runs exactly once.

The event is NOT guaranteed to be observed in real-time. The subscription pattern uses Postgres NOTIFY which is best-effort — a subscriber that's offline during the NOTIFY misses it. Per Block 03 Phase 07's resumability framework, subscribers replay missed events from the audit log on restart.

Per Stage 1 "Analytics layer refresh: Eventual consistency via background jobs. Dashboards may lag a few minutes after finalization" — this lag is intentional, and the missed-NOTIFY case is covered by the resumability replay.

## Failure handling

| Failure | Behavior |
| --- | --- |
| Handler throws transient error | Audit log records the failure (`trigger_events_processed.outcome = TRANSIENT_FAILURE`); retry per Block 03 Phase 08 retry policy |
| Handler throws permanent error | `outcome = PERMANENT_FAILURE`; raise `data.analytics_refresh_failed` review issue (HIGH); no auto-retry |
| Subscriber subscription not registered | `outcome = NO_MATCHING_SUBSCRIPTION`; event is recorded but no handler fired |

## Audit visibility

The event itself is in `audit_log` (per `audit_event_taxonomy`). Subscriber dispatches are in `trigger_events_processed` (per `trigger_events_processed_schema`).

The two tables together give full observability: who emitted the event, who observed it, what outcome resulted.

## Ordering

Per-business ordering is preserved by the audit log's per-business chain. Two `ARCHIVE_PROMOTION_COMPLETED` events for the same business are guaranteed to be observable in commit order.

Cross-business ordering is NOT guaranteed — different chains. Subscribers MUST NOT rely on cross-business ordering.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Event emit | 5 ms | 30 ms | 100 ms |
| Subscriber dispatch | 100 ms | 500 ms | 2 s |
| Full propagation to dashboard | 2 s | 5 s | 30 s |

The "few minutes lag" Stage 1 budgeted is the outer bound including subscriber retries. Typical operation: < 10 seconds.

## Consumer registration details

The following components are registered subscribers to `ARCHIVE_PROMOTION_COMPLETED` at service boot:

| subscription_kind | Component | handler_module |
| --- | --- | --- |
| `analytics_rebuild` | Block 04 analytics zone | `block_04.analytics_refresh_subscriber` |
| `dashboard_refresh` | Block 16 dashboard | `block_16.dashboard_refresh_subscriber` |
| `retention_schedule` | Block 04 retention engine | `block_04.retention_engine_subscriber` |

New subscribers must be added to the `event_subscriptions` registry via the standard `subscribeByEventType` registration call at boot. Adding a subscriber does not require a decisions-log amendment unless the subscriber performs a BLOCKING or irreversible side effect.

## Event replay semantics

`ARCHIVE_PROMOTION_COMPLETED` can be replayed safely: the dedup table (`trigger_events_processed`) ensures each subscriber's side effect runs exactly once per `(business_id, event_id, subscription_kind)` tuple. If a subscriber must be re-run after a permanent failure (e.g., a code bug was fixed), the operator clears the relevant `trigger_events_processed` row and uses `engine.manual_trigger` to replay the event. The analytics rebuild and dashboard refresh handlers are both idempotent — replaying produces the same materialized view state.

## Cross-references

- `audit_event_taxonomy` — `ARCHIVE_PROMOTION_COMPLETED` event definition
- `audit_log_policies` — three-chain partitioning + emit-as-separate-transaction
- `trigger_events_processed_schema` — per-subscription dedup
- `event_subscription_pipeline_integration` (Block 03) — generic subscription mechanism
- `analytics_refresh_runbook` (Block 04) — analytics rebuild subscriber details
- `archive_schema` — `archive_packages`, `archive_manifests` tables referenced in event payload
- `archive_promotion_failure_runbook` — failure response
- `block_16_as_of_view_schema` — analytics MV consumer
- Block 05 Phase 02 — audit log schema + `subscribeByEventType`
- Block 15 Phase 04 — original lock sequence (producer)
- Block 15 Phase 06 — adjustment finalization (producer)
- Block 04 Phase 09 — analytics zone (subscriber)
- Block 16 — dashboard refresh (subscriber)
- 2026-05-08 decisions-log amendment — `ARCHIVE_PROMOTION_COMPLETED` canonical event
