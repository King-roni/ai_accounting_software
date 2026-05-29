# matching_tools_io_schemas

**Category:** Schemas · **Owning block:** 10 — Matching Engine · **Co-owner:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

The canonical **JSON input/output schemas** for the 5 matching tools registered by Block 10 Phase 09 with the workflow engine. These schemas are referenced from `engine.registerTool` calls as `input_schema_ref` and `output_schema_ref`; the workflow engine validates every tool invocation against them.

The 5 tools: `matching.score_pair`, `matching.detect_split_payments`, `matching.detect_duplicates`, `matching.generate_reasons`, `matching.income_match_outcome`.

---

## 1. matching.score_pair

Scores a single `(transaction, document)` pair via Phase 02 + checks Phase 06 rejection memory + applies Phase 03 auto-confirm rule.

### Input

```jsonc
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["run_id", "transaction_id", "document_id"],
  "additionalProperties": false,
  "properties": {
    "run_id":        { "type": "string", "format": "uuid" },
    "transaction_id":{ "type": "string", "format": "uuid" },
    "document_id":   { "type": "string", "format": "uuid" },
    "weighting_profile": {
      "type": "string",
      "enum": ["OUT_EXPENSE", "IN_INCOME"],
      "default": "OUT_EXPENSE"
    }
  }
}
```

### Output

```jsonc
{
  "type": "object",
  "required": ["scored", "match_record_id"],
  "additionalProperties": false,
  "properties": {
    "scored":               { "type": "boolean" },
    "match_record_id":      { "type": ["string", "null"], "format": "uuid" },
    "score":                { "type": "number", "minimum": 0, "maximum": 1 },
    "match_level":          { "type": "string", "enum": ["EXACT", "STRONG_PROBABLE", "WEAK_POSSIBLE", "NO_MATCH"] },
    "suppressed_by_rejection_memory": { "type": "boolean" },
    "auto_confirmed":       { "type": "boolean" }
  }
}
```

`match_record_id` is `null` when `scored = false` (rejection-memory suppressed OR Level 4 NO_MATCH where no row is created — but typically NO_MATCH does emit a forensic row; refer to `match_record_schema.md` for the exact rule).

`weighting_profile` per `income_matching_signal_weighting.md` §4 — selects which weight set the scoring engine applies.

---

## 2. matching.detect_split_payments

Runs Phase 04's combinatorial detection over remaining unmatched transactions.

### Input

```jsonc
{
  "type": "object",
  "required": ["run_id", "side"],
  "additionalProperties": false,
  "properties": {
    "run_id": { "type": "string", "format": "uuid" },
    "side":   { "type": "string", "enum": ["OUT", "IN"] },
    "max_groups_to_propose": { "type": "integer", "minimum": 1, "maximum": 50, "default": 20 }
  }
}
```

### Output

```jsonc
{
  "type": "object",
  "required": ["groups_proposed", "transactions_processed"],
  "additionalProperties": false,
  "properties": {
    "groups_proposed":        { "type": "integer", "minimum": 0 },
    "transactions_processed": { "type": "integer", "minimum": 0 },
    "review_issues_created":  { "type": "integer", "minimum": 0 },
    "timed_out":              { "type": "boolean" },
    "fallback_to_greedy":     { "type": "boolean" }
  }
}
```

`timed_out` + `fallback_to_greedy` per `split_payment_combinatorial_bounds.md` (BOOK-188 anchor doc): 10s timeout per group, greedy fallback if bounded search doesn't converge.

---

## 3. matching.detect_duplicates

Runs Phase 05's pattern detection (Patterns A + B) at phase exit.

### Input

```jsonc
{
  "type": "object",
  "required": ["run_id"],
  "additionalProperties": false,
  "properties": {
    "run_id": { "type": "string", "format": "uuid" },
    "patterns": {
      "type": "array",
      "items": { "type": "string", "enum": ["PATTERN_A", "PATTERN_B"] },
      "default": ["PATTERN_A", "PATTERN_B"]
    }
  }
}
```

### Output

```jsonc
{
  "type": "object",
  "required": ["duplicates_found", "review_issues_created"],
  "additionalProperties": false,
  "properties": {
    "duplicates_found":       { "type": "integer", "minimum": 0 },
    "review_issues_created":  { "type": "integer", "minimum": 0 },
    "pattern_a_count":        { "type": "integer", "minimum": 0 },
    "pattern_b_count":        { "type": "integer", "minimum": 0 }
  }
}
```

---

## 4. matching.generate_reasons

Runs Phase 07's plain-language reason generation for new match records. The only AI-tier-bearing tool in the matching engine.

### Input

```jsonc
{
  "type": "object",
  "required": ["run_id"],
  "additionalProperties": false,
  "properties": {
    "run_id": { "type": "string", "format": "uuid" },
    "match_record_ids": {
      "type": "array",
      "items": { "type": "string", "format": "uuid" },
      "description": "Optional explicit list; if omitted, processes all match_records in the run with NULL match_reason_plain_language"
    }
  }
}
```

### Output

```jsonc
{
  "type": "object",
  "required": ["reasons_generated"],
  "additionalProperties": false,
  "properties": {
    "reasons_generated":      { "type": "integer", "minimum": 0 },
    "fallback_applied_count": { "type": "integer", "minimum": 0 },
    "cache_hit_count":        { "type": "integer", "minimum": 0 },
    "tier_2_used":            { "type": "integer", "minimum": 0 },
    "tier_3_used":            { "type": "integer", "minimum": 0 }
  }
}
```

The `tier_2_used` + `tier_3_used` counts are inputs to the post-run AI-cost audit. `fallback_applied_count` non-zero triggers the LOW-severity review-issue path per BOOK-217 regeneration policy.

---

## 5. matching.income_match_outcome

Runs Phase 08's IN-side outcome computation; calls Block 13's invoice-lifecycle functions.

### Input

```jsonc
{
  "type": "object",
  "required": ["run_id", "transaction_id"],
  "additionalProperties": false,
  "properties": {
    "run_id":         { "type": "string", "format": "uuid" },
    "transaction_id": { "type": "string", "format": "uuid" }
  }
}
```

### Output

```jsonc
{
  "type": "object",
  "required": ["outcome"],
  "additionalProperties": false,
  "properties": {
    "outcome": {
      "type": "string",
      "enum": [
        "FULL_MATCH",
        "PARTIAL_PAYMENT",
        "OVERPAYMENT",
        "MULTIPLE_INVOICES_ONE_PAYMENT",
        "ONE_INVOICE_MULTIPLE_PAYMENTS",
        "NO_MATCH",
        "POSSIBLE_REFUND_OR_TRANSFER"
      ]
    },
    "match_record_ids":   { "type": "array", "items": { "type": "string", "format": "uuid" } },
    "invoice_ids":        { "type": "array", "items": { "type": "string", "format": "uuid" } },
    "lifecycle_calls_made": { "type": "integer", "minimum": 0 },
    "review_issue_id":    { "type": ["string", "null"], "format": "uuid" }
  }
}
```

The 7-value outcome enum follows the phase doc B10·P08 — this perpetuates the Stage-6 drift noted at BOOK-223 (`tool_invoice_lifecycle_integration.md` uses different enum names). Stage-6 reconciliation must align both docs.

---

## 6. Schema versioning

Each tool's schemas are versioned together as part of `tool_registry.schema_version` (per `tool_naming_convention_policy.md`):

- Current version: **`1.0`** for all 5 tools.
- A backwards-compatible schema change (adding an optional output field, widening an enum) → minor bump to `1.1`.
- A breaking schema change (new required input field, removed output field, narrowed enum) → major bump to `2.0`; the old version remains active for the deprecation overlap window.

The schema definitions above are the authoritative `1.0` shape. Implementation must reference these schemas; deviation requires a schema-version bump.

---

## 7. Schema validation at the gateway

The workflow engine's `engine.invokeTool` wrapper validates input against the registered schema BEFORE dispatching to the tool implementation. Output validation runs AFTER the tool returns, BEFORE the engine commits the run-state delta.

| Validation failure | Behaviour |
|---|---|
| Input invalid | Tool not invoked; `TOOL_INPUT_SCHEMA_VIOLATION` emitted; phase retry per Block 03 Phase 08 |
| Output invalid | Run-state delta NOT committed; `TOOL_OUTPUT_SCHEMA_VIOLATION` emitted; HIGH-severity review issue raised against the run |

Output-validation failure is HIGH severity because it indicates the tool implementation has drifted from its registered contract — a programmer error, not a runtime data condition. The review issue routes to engineering, not the business user.

---

## 8. Cross-references

- `tool_naming_convention_policy.md` — registration + schema-version rules
- `tool_side_effect_taxonomy.md` — side-effect class declarations
- `engine.registerTool` API (Block 03 Phase 03) — registration entry point
- `engine.invokeTool` API (Block 03 Phase 06) — schema-validation gateway
- `match_record_schema.md` — `match_records` table written by tools 1, 4, 5
- `split_payment_relationship_schema.md` — `split_payment_groups` table written by tool 2
- `split_payment_combinatorial_bounds.md` — timeout + greedy fallback referenced by tool 2 output
- `match_reason_prompt.md` — AI tier referenced by tool 4 (Stage-6 drift queue noted at BOOK-213)
- `match_reason_regeneration_audit_policy.md` — `fallback_applied_count` consumer (BOOK-217)
- `income_matching_signal_weighting.md` — `weighting_profile` enum source (BOOK-218)
- `tool_invoice_lifecycle_integration.md` — outcome enum (Stage-6 drift at BOOK-223)
- `audit_event_taxonomy.md` — `TOOL_INPUT_SCHEMA_VIOLATION` + `TOOL_OUTPUT_SCHEMA_VIOLATION` events
- Block 10 Phase 09 — workflow phase registration (owning phase)
- Block 03 Phase 03 — tool registration + schema validation framework
- Stage 1 decision — declared-side-effects contract for all matching tools
