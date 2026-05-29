# tool_clients_registry

**Category:** Tools · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owner:** 11 — Ledger & Cyprus VAT Engine · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The IN-side counterparty lookup contract. Two helper APIs exposed by Block 13 Phase 02's clients registry: lookup-by-name and lookup-by-VAT-number. Consumed by Block 11 Phase 04's IN-side counterparty resolver (Step 1.5 per the 2026-05-08 amendment) as the analog of Block 08's vendor memory on the OUT side.

The amendment pinned this cross-block contract: the OUT side has `recurring_vendor_memory`, the IN side has the `clients` registry. Block 11 Phase 04 explicitly branches on IN-side runs to consult this registry ahead of vendor memory.

---

## Function signatures

```ts
in_workflow.get_client_by_name({
  business_id: uuid,
  normalized_name: string,               // pre-normalized per vendor_signature_normalization
  fuzzy: boolean,                        // true → fuzzy fallback with confidence score
}): {
  client: Client | null,
  match_confidence: number,              // 0.0–1.0 (1.0 on exact normalized match)
  matched_via: "exact" | "fuzzy" | "alias" | null,
};

in_workflow.get_client_by_vat_number({
  business_id: uuid,
  vat_number_normalized: string,         // pre-normalized per vat_number_format_catalog
}): {
  client: Client | null,
  matched_via: "exact" | null,
};
```

### `Client` shape (canonical)

```ts
type Client = {
  client_id: uuid,
  business_id: uuid,
  display_name: string,
  normalized_name: string,               // the indexed normalized form
  vat_number_normalized: string | null,
  country_iso: string | null,            // 2-letter ISO when known
  aliases: string[],                     // alternative normalized names (Stage 2+ multi-alias)
  active: boolean,
  created_at: timestamptz,
  metadata: ClientMetadata,
};
```

## Side-effect class and AI tier

- **Side-effect class:** `READ_ONLY` (lookup; never writes)
- **AI tier:** `NONE`

These helpers are pure read functions. Client creation, update, and deactivation are separate tools (`data.create_client`, `data.update_client`, `data.deactivate_client` — Block 13 Phase 02) with their own `WRITES_RUN_STATE` declarations.

## Audit events emitted

| Event | When | Payload |
| --- | --- | --- |
| `CLIENT_REGISTRY_LOOKUP` | Per lookup call (aggregated; see below) | `{ business_id, lookup_kind: "by_name" \| "by_vat_number", matched: boolean }` |

Per `review_audit_volume_aggregation_policy` (Block 14): the per-lookup event is aggregated within a workflow phase — one summary event per (phase, business_id, lookup_kind) rather than per-call. The summary fires at phase end.

## Lookup semantics

### Name lookup

1. **Exact normalized name** — `normalized_name` matches `clients.normalized_name` exactly → `match_confidence = 1.0`, `matched_via = "exact"`
2. **Alias match** — `normalized_name` matches any entry in `clients.aliases` exactly → `match_confidence = 1.0`, `matched_via = "alias"`
3. **Fuzzy match** (only if `fuzzy: true`):
   - Edit-distance / Jaro-Winkler against `clients.normalized_name` + `clients.aliases`
   - Threshold 0.85 for a match; below threshold returns `client: null`
   - `match_confidence` = the similarity score
   - `matched_via = "fuzzy"`
4. **No match** — `client: null`, `match_confidence = 0.0`, `matched_via: null`

Name normalization (per `vendor_signature_normalization`): lowercase, strip diacritics, strip legal-suffix variations (Ltd / LLC / GmbH / etc.), strip punctuation, collapse whitespace. The same normalization applies on both sides of the comparison.

### VAT number lookup

1. **Exact match** — `vat_number_normalized` matches `clients.vat_number_normalized` exactly → `client` returned, `matched_via = "exact"`
2. **No match** — `client: null`, `matched_via: null`

VAT number normalization (per `vat_number_format_catalog`): country prefix + digits, uppercase, no spaces or punctuation. Cyprus VAT numbers normalize to `CY` + 9 chars; EU formats per the catalogue.

There's no fuzzy match for VAT numbers — typo'd VAT numbers route to `UNKNOWN` per Block 11 Phase 04's strict-equality rule (a VAT number is a regulator identifier; near-matches are wrong by definition).

## Cross-block contract

Block 11 Phase 04 Step 1.5 (per the 2026-05-08 amendment) invokes both helpers for IN-side runs:

```ts
// inside ledger.resolve_counterparty for IN side
const byVat = await in_workflow.get_client_by_vat_number({ business_id, vat_number_normalized });
if (byVat.client) return resolved(byVat.client);

const byName = await in_workflow.get_client_by_name({ business_id, normalized_name, fuzzy: true });
if (byName.client && byName.match_confidence >= 0.85) return resolved(byName.client);

// fall through to next step in Phase 04 chain (vendor memory, OCR-extracted fields, etc.)
```

OUT side runs do NOT call these helpers — they call `recurring_vendor_memory` lookups per Block 08.

The contract: these helper names are stable (`in_workflow.get_client_by_name`, `in_workflow.get_client_by_vat_number`). Signature changes require an amendment.

## Multi-business safety

Both helpers REQUIRE `business_id`. There is no cross-business lookup. RLS on `clients` enforces tenant isolation at the SQL level; the helpers respect that.

A Stage 2+ post-MVP enhancement is cross-business client aliasing (e.g., the same supplier known to two of an Owner's businesses). That's deferred via `client_multi_name_alias_schema` and not part of this MVP contract.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `in_workflow.get_client_by_vat_number` | 5 ms | 15 ms | 50 ms |
| `in_workflow.get_client_by_name` (exact / alias) | 10 ms | 30 ms | 100 ms |
| `in_workflow.get_client_by_name` (fuzzy fallback, 1000 clients) | 50 ms | 200 ms | 800 ms |

Indexes per `clients` schema: `(business_id, normalized_name)` btree; `(business_id, vat_number_normalized)` partial-unique (when not null); `(business_id) include (aliases)` for fuzzy scans.

## Concurrent reads

No contention. Read-only lookups on indexed columns. Block 13 Phase 02's `clients` table supports thousands of concurrent reads per business.

## Failure modes

| Failure | Behavior |
| --- | --- |
| `business_id` missing or invalid | Throws; caller error |
| Normalization yields empty string | Returns `client: null` (treated as no-match, not error) |
| DB connection error | Throws (transient — caller retries) |

The helpers never write — there's no transactional concern.

## Registration

```ts
engine.registerTool({
  name: "in_workflow.get_client_by_name",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY"],
  ai_tier: "NONE",
  input_schema_ref: "tool_clients_registry#v1.input_by_name",
  output_schema_ref: "tool_clients_registry#v1.output",
  audit_events: ["CLIENT_REGISTRY_LOOKUP"],
  description_ref: "Docs/sub/tools/tool_clients_registry.md",
});

engine.registerTool({
  name: "in_workflow.get_client_by_vat_number",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY"],
  ai_tier: "NONE",
  input_schema_ref: "tool_clients_registry#v1.input_by_vat",
  output_schema_ref: "tool_clients_registry#v1.output",
  audit_events: ["CLIENT_REGISTRY_LOOKUP"],
  description_ref: "Docs/sub/tools/tool_clients_registry.md",
});
```

Both tools share the same description sub-doc (this one) because they're a tightly-coupled pair.

## Cross-references

- `tool_naming_convention_policy` — naming + registration
- `audit_log_policies` — `CLIENT_REGISTRY_LOOKUP` event
- `review_audit_volume_aggregation_policy` — per-lookup aggregation rule
- `vendor_signature_normalization` (Block 08) — same normalization on both sides
- `vat_number_format_catalog` (Block 11 Reference data) — VAT-number normalization rules
- `tool_vendor_memory_increment` — OUT-side analog (`recurring_vendor_memory`)
- `client_multi_name_alias_schema` — Stage 2+ multi-alias support
- Block 11 Phase 04 — counterparty resolver (canonical consumer)
- Block 13 Phase 02 — client database (implementation home)
- 2026-05-08 decisions-log amendment — Block 11 Phase 04 IN-side resolver branch

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.