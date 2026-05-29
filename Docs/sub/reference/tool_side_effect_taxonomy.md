# Tool Side-Effect Taxonomy

**Category:** Reference data · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

The closed six-value enum for the `side_effect_class` field in every tool registration. Every tool developer in Blocks 06–16 binds to this document when declaring the side-effect class of a tool. The CI lint suite validates that all declared classes are members of this enum.

---

## The six classes

### `READ_ONLY`

**Definition:** The tool performs no database writes and issues no external API calls. It may read from any zone (operational DB, processing zone, archive) subject to its phase's access policy, but it writes nothing. Pure compute tools (scoring, formatting, hashing, parsing in-memory) and proposer-pattern tools (which produce a proposal but leave the write to a separate single-writer tool) carry this class.

**Typical blocks:** 08 (classification rule evaluation), 10 (score computation), 11 (VAT treatment lookup), 14 (review issue read), any block using the proposer pattern.

**Composability:** Composable with `EXTERNAL_CALL` (a read-only tool that calls an external service for a read — e.g., an ECB rate lookup that writes nothing) and with `WRITES_AUDIT` (read-only tools that still emit audit events). Not composable with any `WRITES_*` class other than `WRITES_AUDIT`.

---

### `WRITES_PROCESSING_ZONE`

**Definition:** The tool writes exclusively to processing-zone tables and storage (intermediate extraction results, classifier outputs, pre-finalization scratch data). It does not write to operational-DB tables (`transactions`, `documents`, `match_records`, `review_issues`, etc.) or to the archive zone.

**Typical blocks:** 07 (statement parsing outputs), 08 (classification scratch), 09 (document extraction results), 06 (AI output staging).

**Composability:** Composable with `EXTERNAL_CALL` and `WRITES_AUDIT`. Mutually exclusive with `WRITES_RUN_STATE` and `WRITES_ARCHIVE` within a single tool (a tool that writes to both processing zone and run state must be split into two tools per `tool_atomicity_policy`).

---

### `WRITES_RUN_STATE`

**Definition:** The tool writes to operational-DB tables: `transactions`, `documents`, `match_records`, `review_issues`, `draft_ledger_entries`, `workflow_runs`, `tool_invocations`, and equivalent tables owned by Blocks 07–14. These are the live, pre-finalization business records.

**Typical blocks:** 07 (transaction creation), 10 (match record writes), 11 (ledger entry writes), 12 (OUT workflow state), 13 (IN workflow state, invoice creation), 14 (review issue resolution).

**Composability:** Composable with `WRITES_AUDIT`. May be combined with `EXTERNAL_CALL` when a single tool must both call an external service and write the result to run state (discouraged — prefer the proposer pattern; acceptable when the external call and the write are atomically linked). Mutually exclusive with `WRITES_ARCHIVE` (no tool may write to both run state and the archive in the same invocation).

---

### `WRITES_AUDIT`

**Definition:** The tool calls `emitAudit()` (the `security.emit_audit` tool, or the `emitAudit()` internal API) at least once during its execution path. Declared explicitly so the dependency analysis can statically identify every tool that touches the audit log.

**Typical blocks:** All blocks. Virtually every tool that performs a meaningful operation emits at least one audit event.

**Composability:** Fully composable with all other classes. `WRITES_AUDIT` is almost always co-declared with at least one other class; it is rare to have a tool that *only* writes to the audit log (that is the job of `security.emit_audit` itself).

**Note on the audit-log transaction contract:** `WRITES_AUDIT` tools write to the audit log as a separate short transaction immediately after the primary operation commits. This is the post-2026-05-08 amendment semantics. The audit write is not inside the same transaction as the operational write. See `emit_audit_api` for the full transaction semantics.

---

### `WRITES_ARCHIVE`

**Definition:** The tool writes to the finalized archive zone — the `archive.*` Postgres schema tables or the `archive-bundles` Supabase Storage bucket. Archive writes are immutable: once written, the data cannot be modified or deleted by any application-layer operation.

**Typical blocks:** Block 15 only. This class is reserved exclusively for Block 15 finalization and re-finalization tools.

**Composability:** Composable with `WRITES_AUDIT` and `EXTERNAL_CALL` (e.g., the RFC 3161 timestamp tool that calls the TSA during archive promotion). Not composable with `WRITES_RUN_STATE` or `WRITES_PROCESSING_ZONE`.

**Reservation rule:** Code review rejects any tool outside Block 15 attempting to register with `WRITES_ARCHIVE`. The block short-name allowlist from `tool_naming_convention_policy` enforces this: only tools with `archive` as their namespace may carry this class. An `archive.*` tool outside Block 15's migration-controlled namespace does not exist. If a reviewer encounters a non-`archive.*` tool with `WRITES_ARCHIVE` in its registration, the PR must be rejected with a reference to this rule and this document.

---

### `EXTERNAL_CALL`

**Definition:** The tool invokes at least one external API during its execution path. External APIs include: Document AI (OCR), Anthropic Claude (Tier 3 AI), Vault, RFC 3161 TSA, Gmail, Google Drive, ECB exchange-rate API, and any other system outside the project's Supabase instance.

**Typical blocks:** 06 (AI gateway), 07 (OCR, bank statement ingestion), 09 (document OCR, email finder, Drive finder), 11 (ECB rate fetch), 15 (TSA for archive timestamps).

**Composability:** Composable with all other classes. Tools carrying `EXTERNAL_CALL` must also declare `external_request_id` handling in their registration (per `tool_invocation_schema`) for idempotency on retry.

---

## Mutual exclusivity summary

| Class pair | Relationship |
| --- | --- |
| `READ_ONLY` + `WRITES_*` (any) | Mutually exclusive, except `READ_ONLY` + `WRITES_AUDIT` |
| `WRITES_PROCESSING_ZONE` + `WRITES_RUN_STATE` | Mutually exclusive |
| `WRITES_PROCESSING_ZONE` + `WRITES_ARCHIVE` | Mutually exclusive |
| `WRITES_RUN_STATE` + `WRITES_ARCHIVE` | Mutually exclusive |
| `WRITES_AUDIT` + any other class | Always composable |
| `EXTERNAL_CALL` + any other class | Always composable |

---

## Always-co-declared patterns

The following co-declarations appear on nearly every tool and are considered the standard pattern:

- Any tool that does useful work: `WRITES_RUN_STATE | WRITES_AUDIT`
- Any tool that calls an AI: `EXTERNAL_CALL | WRITES_PROCESSING_ZONE | WRITES_AUDIT`
- Proposer-pattern tools: `READ_ONLY | EXTERNAL_CALL | WRITES_AUDIT`
- Archive promotion tools (Block 15): `WRITES_ARCHIVE | EXTERNAL_CALL | WRITES_AUDIT`

---

## Dependency analysis use cases

The explicit side-effect class declaration enables static analysis of data-flow across the tool graph:

1. **Zone contamination detection.** A phase whose permitted side-effect class is `WRITES_PROCESSING_ZONE` cannot invoke a `WRITES_RUN_STATE` tool. The engine enforces this at runtime; static analysis catches it before deployment.
2. **Audit coverage audit.** A tool that is not `WRITES_AUDIT` is visible in the dependency graph as a tool with no audit trail. Reviewers can identify gaps in audit coverage from the graph.
3. **Archive write tracing.** The `WRITES_ARCHIVE` reservation means a search for `side_effect_class.includes("WRITES_ARCHIVE")` in the tool registry returns only Block 15 tools — a security-relevant invariant that can be verified programmatically.
4. **External call enumeration.** Compliance reviews that need to document all external API call sites can enumerate all `EXTERNAL_CALL` tools from the registry without reading every tool's source code.

---

## Worked example: `intake.ocr_and_extract` multi-class declaration

`intake.ocr_and_extract` is the Block 07/09 shared OCR tool. It:

1. Calls Document AI (an external OCR vendor) — `EXTERNAL_CALL`
2. Writes extracted text and field outputs to the processing zone — `WRITES_PROCESSING_ZONE`
3. Emits `DOCUMENT_OCR_COMPLETED` or `DOCUMENT_OCR_FAILED` to the audit log — `WRITES_AUDIT`

Registration declaration:

```typescript
engine.registerTool({
  name: "intake.ocr_and_extract",
  schema_version: "1.0",
  side_effect_class: ["EXTERNAL_CALL", "WRITES_PROCESSING_ZONE", "WRITES_AUDIT"],
  ai_tier: "NONE",  // Document AI is not an AI tier — it is OCR infrastructure
  input_schema_ref: "tool_intake_ocr_and_extract#v1.input",
  output_schema_ref: "tool_intake_ocr_and_extract#v1.output",
  audit_events: ["DOCUMENT_OCR_COMPLETED", "DOCUMENT_OCR_FAILED"],
  description_ref: "Docs/sub/tools/tool_intake_ocr_and_extract.md",
});
```

This declaration correctly excludes `WRITES_RUN_STATE` because the extracted results land in the processing zone, not in the operational `documents` table. A separate `intake.persist_extracted_fields` tool (with `WRITES_RUN_STATE | WRITES_AUDIT`) promotes the extraction output to run state after review.

---

## Cross-references

- `tool_naming_convention_policy` — side-effect class field in the registration call; `WRITES_ARCHIVE` reservation rule stated there
- `tool_registration_api` — full registration call shape; the `side_effect_class` array is a required field
- `tool_schema_definition_policy` — schema authoring rules used alongside side-effect declarations
- `tool_atomicity_policy` (Block 03) — proposer + single-writer pattern that governs when a tool must be split rather than combining write classes
- `emit_audit_api` — `security.emit_audit` tool; all tools with `WRITES_AUDIT` call this
- `tool_invocation_schema` — `external_request_id` column used by `EXTERNAL_CALL` tools
- `Docs/phases/03_workflow_engine/03_tool_registration_framework.md` — Phase 03 owner of the registration framework
- `Docs/phases/03_workflow_engine/06_phase_execution_engine.md` — Phase 06 that enforces phase-level side-effect class gating at runtime
