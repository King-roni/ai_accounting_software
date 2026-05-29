# Tool: classification.apply_vendor_memory

**Category:** Tools · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

Queries the vendor memory table for prior classification history on a given counterparty within a business, and returns a confidence boost and a suggested category when a qualifying hit is found. The tool is READ_ONLY; it never writes vendor memory — that is the responsibility of `classification.write_vendor_memory` (see `tool_vendor_memory_writeback.md`).

---

## Block reference

Block 08 — Transaction Classification. This tool is called at the start of the classification phase, before any AI gateway call. A qualifying hit may eliminate the AI call entirely via tier promotion.

---

## Purpose

Vendor memory stores a business's confirmed classification history keyed by counterparty. Reusing that history for recurring transactions from the same counterparty avoids redundant AI calls, reduces latency, and produces more consistent classifications over time. This tool exposes the lookup as a discrete, auditable step in the classification pipeline.

---

## Tool signature

```
classification.apply_vendor_memory({
  transaction_id:   UUID,   // UUID v7; references transactions.id
  counterparty_id:  UUID,   // UUID v7; references counterparties.id
  business_id:      UUID    // UUID v7; tenant isolation
}) → {
  hit:                     boolean,
  suggested_category:      string | null,
  confidence_boost:        number,          // 0.15 on hit; 0.0 on miss
  source_transaction_count: number          // count of prior transactions that produced the hit
}
```

---

## Registration shape

```ts
engine.registerTool({
  name: "classification.apply_vendor_memory",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_classification_vendor_memory_apply#v1.input",
  output_schema_ref: "tool_classification_vendor_memory_apply#v1.output",
  audit_events: [
    "CLASSIFICATION_VENDOR_MEMORY_HIT",
    "CLASSIFICATION_VENDOR_MEMORY_MISS"
  ],
  description_ref: "Docs/sub/tools/tool_classification_vendor_memory_apply.md",
});
```

---

## Hit semantics

A hit requires all three conditions:

1. The `vendor_memory` table contains at least **3 prior transactions** for the same `(counterparty_id, business_id)` pair.
2. All qualifying prior transactions share the **same `category` value** — 100% agreement is required. If any prior transaction in the set carries a different `category`, the hit fails and `hit = false` is returned.
3. The qualifying transactions must have `status = CONFIRMED` in the classification history (human-confirmed or auto-confirmed classifications only; PROPOSED records do not count).

When all three conditions are met:

- `hit = true`
- `suggested_category` = the agreed category string
- `confidence_boost = 0.15`
- `source_transaction_count` = the count of qualifying prior transactions (≥ 3)

**Miss path:** if any condition fails, the tool returns `hit: false`, `suggested_category: null`, `confidence_boost: 0`, `source_transaction_count: 0`. The caller proceeds to normal TIER_2 or TIER_3 AI classification.

The minimum count of 3 is intentional. A single prior transaction is insufficient to establish a reliable pattern; two could be coincidental. Three confirmed consistent classifications represent a durable business pattern.

---

## Tier promotion on hit

A vendor memory hit promotes the classification tier from TIER_2 to TIER_1 (rule-based, no AI call) **if** the confidence score after applying the boost meets or exceeds the `STRONG_MATCH` threshold for classification:

```
effective_confidence = base_confidence + confidence_boost
```

Where `base_confidence` for a vendor memory scenario is `1.00` (the memory lookup itself is deterministic — it either hits or misses). Therefore:

- Vendor memory hit → `effective_confidence = 1.00 + 0.15 = 1.15` (capped at 1.00 in the calibrated envelope).
- Tier promotion to TIER_1 occurs when `effective_confidence ≥ 0.85` after calibration cap.

In practice, every vendor memory hit with the standard `confidence_boost = 0.15` will trigger tier promotion because the effective confidence always exceeds `0.85`. The explicit threshold check is retained for correctness in the case where `confidence_boost` is ever changed via a calibration update.

When tier promotion occurs, no AI gateway call is made for this transaction. The classification proceeds directly to the write step. The `tier_used` field in the `classification_confidence_output_schema` envelope is set to `TIER_1`.

---

## Side-effect contract

| Class | Description |
| --- | --- |
| `READ_ONLY` | Queries `vendor_memory` table only. No DB writes. |
| `WRITES_AUDIT` | Emits `CLASSIFICATION_VENDOR_MEMORY_HIT` or `CLASSIFICATION_VENDOR_MEMORY_MISS` via `emitAudit()`. |

This tool never writes to `vendor_memory`, `transactions`, or any other operational table. The proposer pattern is maintained: this tool is the proposer; `classification.write_vendor_memory` is the designated writer.

---

## Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `CLASSIFICATION_VENDOR_MEMORY_HIT` | LOW | All three hit conditions are met; boost and suggested category are returned |
| `CLASSIFICATION_VENDOR_MEMORY_MISS` | LOW | Any hit condition fails; miss path is returned |

`CLASSIFICATION_VENDOR_MEMORY_HIT` payload: `transaction_id`, `counterparty_id`, `business_id`, `suggested_category`, `confidence_boost`, `source_transaction_count`, `tier_promoted_to_tier_1`.

`CLASSIFICATION_VENDOR_MEMORY_MISS` payload: `transaction_id`, `counterparty_id`, `business_id`, `miss_reason` (one of `INSUFFICIENT_HISTORY`, `CATEGORY_DISAGREEMENT`, `NO_CONFIRMED_RECORDS`).

Both events are emitted at LOW severity. Vendor memory activity is informational; the downstream classification result carries the operationally significant audit trail.

---

## Idempotency

Idempotency is guaranteed by the READ_ONLY side-effect class. Re-invoking the tool with the same inputs on a replayed run returns the same result as long as `vendor_memory` has not been modified between invocations. Memory modifications between runs are expected (the writeback tool runs after successful classification); callers that replay across run boundaries should expect the result to reflect the current state of vendor memory.

---

## Failure modes

The tool has no network dependencies and operates against a local database table. Failures are limited to:

| Condition | Behaviour |
| --- | --- |
| `vendor_memory` table unavailable (DB error) | Tool returns an error; the workflow engine retries per `retry_policy`. The classification phase does not skip this step — vendor memory must be consulted before any AI call to honour the tier promotion path. |
| `counterparty_id` is a placeholder (COUNTERPARTY_PLACEHOLDER) | Tool returns `hit: false`, `miss_reason: NO_CONFIRMED_RECORDS`. Placeholder counterparties have no classification history by definition. No error is raised. |

There is no timeout declared for this tool; the query is a simple indexed SELECT. If query latency exceeds 5 seconds, the DB `statement_timeout` fires and the workflow engine handles it as a standard DB error.

---

## Pipeline position

Within the Block 08 classification phase, the call order is:

1. `classification.apply_vendor_memory` (this tool) — check memory first
2. If `hit = true` and tier promotion fires: skip to step 5
3. `ai.invoke_classification_layer_1` — rule-based TIER_1 pass
4. `ai.invoke_classification_layer_2` (or TIER_3 on escalation) — model-based pass
5. Assemble `classification_confidence_output_schema` envelope — apply calibration factors and boosts
6. `classification.write_vendor_memory` (if result is confirmed) — persist the new classification to memory

Calling this tool after the AI classification step (steps 3–4) would produce the same result but defeats the purpose of tier promotion. The call order is enforced by the phase definition in Block 08.

---

## Mobile

`classification.vendor_memory_apply` is an internal classification pipeline step, not a user-callable endpoint. Mobile clients cannot invoke classification pipeline tools directly. Mobile write rejection is enforced at the workflow engine layer per `mobile_write_rejection_endpoints.md`.

## Cross-references

- `vendor_memory_schema.md` — DDL for the `vendor_memory` table; `sample_count` field; category consensus query
- `tool_vendor_memory_writeback.md` — the corresponding writer tool that persists new classifications back to vendor memory
- `tool_vendor_memory_increment.md` — increments `sample_count` on an existing vendor memory row after a confirmed classification
- `confidence_score_schema.md` — confidence score fields and the `0.85` STRONG_MATCH threshold used in tier promotion
- `classification_confidence_output_schema.md` — the output envelope where `vendor_memory_boost_applied` and `tier_used` are set based on this tool's result
- Block 08 — Transaction Classification phase doc
- `tool_naming_convention_policy.md` — tool registration conventions
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy; enforced at the workflow engine layer
