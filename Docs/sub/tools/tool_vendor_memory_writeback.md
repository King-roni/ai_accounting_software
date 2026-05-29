# tool_vendor_memory_writeback

**Category:** Tools · **Owning block:** 11 — Ledger & Cyprus VAT Engine · **Co-owner:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The cross-block writeback from Block 11's ledger preparation into the `recurring_vendor_memory` table. When Block 11's counterparty resolution (Phase 04) finds a vendor through extracted-document fields (rather than through vendor memory lookup), the resolution success is written back so future runs can resolve the same counterparty via memory.

Distinct from `tool_vendor_memory_increment`:
- `increment_confirmation` bumps the confirmation count after a match / classification is confirmed
- `writeback` records a (vendor_id, transaction_signature) association after a successful ledger preparation — does NOT increment confirmation count

Block 10 Phase 03 is the canonical reader of vendor memory; Block 11 Phase 04 is the canonical writer (via this tool).

---

## Function signature

```ts
classification.writeback_vendor_memory({
  business_id: uuid,
  vendor_id: uuid,
  transaction_signature: string,         // normalized per vendor_signature_normalization
  resolution_evidence: ResolutionEvidence,
  ledger_entry_id: uuid,                 // FK to the draft_ledger_entries row that triggered the writeback
}): {
  inserted: boolean,                     // false if association already existed
  last_seen_at: timestamptz,
};

type ResolutionEvidence = {
  resolution_method: "ocr_field" | "vat_number_lookup" | "client_registry" | "manual_override",
  source_document_id?: uuid,             // present when resolved via document extraction
  source_field?: string,                 // e.g., "supplier_name", "supplier_vat_number"
  confidence?: number,                   // present for OCR/extraction resolutions
};
```

## What gets written

1. `recurring_vendor_memory` — INSERT or UPDATE:
   - If `(business_id, vendor_id, transaction_signature)` does not exist: insert with `confirmations_count = 0`, `first_seen_at = now()`, `last_seen_at = now()`
   - If it exists: UPDATE `last_seen_at = now()` only (confirmations_count is untouched)
2. `vendor_memory_resolution_log` — INSERT with the `resolution_evidence`:
   - Provides forensic trace of how the vendor was resolved
   - Used by Phase 04's `counterparty_resolver_tracing_schema`

The crucial property: writeback **does not increment confirmations_count**. Counts only increment via `tool_vendor_memory_increment` after a match or classification is confirmed — preventing inflation of memory counts from raw ledger preparation.

## When to call

Block 11 Phase 04's counterparty resolver calls this tool when:

- The counterparty was resolved via OCR-extracted fields (not via vendor memory lookup)
- The counterparty was resolved via VIES validation (the EU VAT-number check succeeded)
- The counterparty was resolved via the client registry (IN-side; per `tool_clients_registry`)
- A manual override mapped a transaction to a known vendor

Block 11 Phase 04 does NOT call this tool when:

- The counterparty was already resolved via vendor memory (no new association to record)
- The counterparty was unresolved (no vendor_id to associate)

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
- **AI tier:** `NONE`

The tool writes:
1. `recurring_vendor_memory` (UPDATE or INSERT)
2. `vendor_memory_resolution_log` (INSERT)
3. Audit event

Mobile clients are rejected at the API gateway for all write operations on this tool. See `mobile_write_rejection_endpoints` for the full rejection surface.

## Audit events

| Event | When |
| --- | --- |
| `LEDGER_COUNTERPARTY_RESOLVED` | Emitted by Block 11 Phase 04 at resolution time; this tool inherits the event chain (does not emit a separate writeback event) |

## Idempotency

The same `(business_id, vendor_id, transaction_signature)` re-written produces no new behavior:

- `recurring_vendor_memory.last_seen_at` updates (current time)
- `vendor_memory_resolution_log` gets a new row (each resolution is a separate forensic record)
- Returns `inserted: false`

Idempotency is per-association, not per-call — a second call with a different `ledger_entry_id` (which would happen on a re-run) records the second resolution event as well.

## Concurrency

Per-(business_id, vendor_id) row lock during update. Concurrent writebacks on different vendors proceed independently.

## Cross-block contract

Block 11 Phase 04 commits to calling this helper when one of the above writeback conditions is met. Block 10 Phase 03 reads `recurring_vendor_memory` to compute the recurring-vendor signal per `match_signal_weights` — the writeback is the upstream that populates what matching reads.

The contract: writeback never increments counts; only `tool_vendor_memory_increment` does that. This separation prevents Block 11's run-side from inflating match-side data.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `classification.writeback_vendor_memory` (single call) | 10 ms | 50 ms | 200 ms |
| 50 writebacks in a single ledger-prep batch | 200 ms | 1 s | 3 s |

The 50-batch number reflects a typical OUT_MONTHLY ledger preparation where 50 transactions resolve their counterparties.

## Pre-conditions and errors

| Error | Cause |
| --- | --- |
| `VENDOR_NOT_FOUND` | `vendor_id` does not exist for `business_id` |
| `BUSINESS_ID_REQUIRED` | Missing |
| `RESOLUTION_EVIDENCE_INVALID` | `resolution_method` not in enum, or required sub-fields missing |

## Registration

```ts
engine.registerTool({
  name: "classification.writeback_vendor_memory",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_vendor_memory_writeback#v1.input",
  output_schema_ref: "tool_vendor_memory_writeback#v1.output",
  audit_events: ["LEDGER_COUNTERPARTY_RESOLVED"],
  description_ref: "Docs/sub/tools/tool_vendor_memory_writeback.md",
});
```

## Cross-references

- `tool_naming_convention_policy` — naming + registration
- `tool_vendor_memory_increment` — sibling helper (count-incrementing path)
- `tool_clients_registry` — IN-side analog (read-only registry)
- `match_signal_weights` — downstream consumer of `recurring_vendor_memory`
- `audit_log_policies` — event naming
- `counterparty_resolver_tracing_schema` (Block 11 Phase 04) — forensic trace consumer
- Block 11 Phase 04 — counterparty resolver (canonical caller)
- Block 08 Phase 03 — `recurring_vendor_memory` (implementation home)
- `mobile_write_rejection_endpoints` — mobile write rejection enforcement
- Block 10 Phase 03 — Strong-Probable auto-confirm (downstream reader)

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.