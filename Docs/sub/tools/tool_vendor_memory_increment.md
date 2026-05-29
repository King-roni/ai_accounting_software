# tool_vendor_memory_increment

**Category:** Tools · **Owning block:** 10 — Matching Engine · **Co-owner:** 08 — Transaction Classification & Tagging · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The increment helper that bumps `recurring_vendor_memory.confirmations_count` when a vendor-attribution is reinforced — a match auto-confirms, a user confirms a match, a classification is user-confirmed. Per the Block 10 scan fix: the helper carries a `source` field keyed for idempotency to prevent dual-source double-counting (the same user action firing both classification.user_confirm AND matching.user_confirm would otherwise double-count).

Block 08 Phase 03 owns the `recurring_vendor_memory` table. Block 10 Phase 03 + Block 08 Phase 03 are the canonical callers.

---

## Function signature

```ts
classification.increment_vendor_memory_confirmation({
  business_id: uuid,
  vendor_id: uuid,
  transaction_signature: string,         // normalized signature per vendor_signature_normalization
  source_kind: SourceKind,
  source_id: uuid,                       // FK to the source event (match_record_id, classification_decision_id, etc.)
  actor_user_id?: uuid,                  // present for user-driven sources
}): {
  prior_count: integer,
  new_count: integer,
  tier_transition?: "MEDIUM" | "HIGH",   // present when count crosses a tier boundary
  noop: boolean,                         // true if the (source_kind, source_id) was already recorded
};

type SourceKind = "matching.auto_confirm" | "matching.user_confirm"
                | "classification.auto_confirm" | "classification.user_confirm";
```

## Idempotency

Per the Block 10 scan: the `(source_kind, source_id)` tuple is recorded alongside each increment. A second invocation with the same tuple is a no-op — returns `noop: true` with `prior_count` and `new_count` equal.

Without this idempotency, the following scenario would double-count:

1. User confirms a Strong-Probable match in review (`matching.user_confirm` fires)
2. The match-confirmation cascade fires `classification.user_confirm` to confirm the underlying classification
3. Both events would otherwise call the increment helper — double-count

The idempotency table (`vendor_memory_increment_log`) carries:

```sql
business_id      uuid NOT NULL,
vendor_id        uuid NOT NULL,
source_kind      text NOT NULL,
source_id        uuid NOT NULL,
applied_at       timestamptz NOT NULL,
UNIQUE (business_id, vendor_id, source_kind, source_id)
```

The unique constraint catches the second call. The function detects the conflict, returns `noop: true`, and does not increment.

## Tier transitions

Per Block 08 Phase 03 and `match_signal_weights`:

| Count threshold | Tier | Auto-confirm eligibility |
| --- | --- | --- |
| 0 | (initial) | No |
| 1 | MEDIUM | No (Block 08 Phase 03 medium tier) |
| 3 | HIGH | Yes (STRONG_PROBABLE auto-confirm per `strong_probable_threshold_policy`) |
| 6 | (saturation) | (no behavior change) |

When the increment causes a tier transition, `tier_transition` is populated in the return value. Callers use this signal to emit an audit event (`CLASSIFICATION_VENDOR_MEMORY_TIER_TRANSITION`) and to invalidate caches that depend on the tier.

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
- **AI tier:** `NONE`

The tool writes:
1. `recurring_vendor_memory.confirmations_count` increment (UPDATE)
2. `vendor_memory_increment_log` insertion (the idempotency record)
3. Audit event on tier transition

Mobile clients are rejected at the API gateway for all write operations on this tool. See `mobile_write_rejection_endpoints` for the full rejection surface.

## Audit events

| Event | When |
| --- | --- |
| `CLASSIFICATION_VENDOR_MEMORY_INCREMENTED` | Per invocation — aggregated per `audit_log_policies` aggregation rule (one summary event per phase) |
| `CLASSIFICATION_VENDOR_MEMORY_TIER_TRANSITION` | On tier crossing (MEDIUM at count 1, HIGH at count 3) |

The aggregated event captures `{ business_id, increment_count_in_phase, tier_transitions[] }`. Per-call events are not emitted to avoid audit-log volume blow-up (matching can fire many increments per run).

## Concurrency

Same `vendor_id` from concurrent callers serializes on the `recurring_vendor_memory` row lock. The unique constraint on the idempotency log prevents double-increment under any race.

Different vendors increment independently.

## Cross-block contract

Per the Block 10 scan: the helper signature with `source_kind` + `source_id` is the contract. Block 08 commits to passing the canonical source kinds. Block 10 commits the same. Adding a new source kind requires an amendment.

The original two-source pattern from Block 08 Phase 03 (medium-confidence from one confirmation, high-confidence from three) is preserved.

## Pre-conditions and errors

| Error | Cause |
| --- | --- |
| `VENDOR_NOT_FOUND` | `vendor_id` does not exist for `business_id` |
| `SOURCE_KIND_INVALID` | Not in the enum |
| `BUSINESS_ID_REQUIRED` | Missing |

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Single increment | 5 ms | 30 ms | 100 ms |
| 100 concurrent increments on different vendors | 50 ms | 200 ms | 500 ms |

Indexed: `(business_id, vendor_id)` on `recurring_vendor_memory`. Lookups are sub-millisecond; row lock acquisition dominates.

## Registration

```ts
engine.registerTool({
  name: "classification.increment_vendor_memory_confirmation",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_vendor_memory_increment#v1.input",
  output_schema_ref: "tool_vendor_memory_increment#v1.output",
  audit_events: ["CLASSIFICATION_VENDOR_MEMORY_INCREMENTED", "CLASSIFICATION_VENDOR_MEMORY_TIER_TRANSITION"],
  description_ref: "Docs/sub/tools/tool_vendor_memory_increment.md",
});
```

## Cross-references

- `tool_naming_convention_policy` — naming + registration
- `tool_vendor_memory_writeback` — sibling helper (Block 11-side writeback)
- `match_signal_weights` — tier thresholds and weights
- `strong_probable_threshold_policy` — the 0.88 cutoff (count ≥ 3)
- `audit_log_policies` — aggregation rule + event naming
- `tool_clients_registry` — IN-side analog
- Block 08 Phase 03 — recurring vendor memory (implementation home)
- Block 10 Phase 03 — Strong Probable auto-confirm rule (canonical caller)
- `mobile_write_rejection_endpoints` — mobile write rejection enforcement
- Block 10 scan fix — source-keyed idempotency

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.