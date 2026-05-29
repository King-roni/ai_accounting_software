# dedup_key_generator_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine (heavy consumers: 12 — OUT Workflow, 13 — IN Workflow) · **Stage:** 4 sub-doc (Layer 2)

A playbook for constructing the `dedup_key` stored on `tool_invocations` rows. The dedup key is the idempotency identity for a tool call: if a row already exists in `tool_invocations` with `(workflow_run_id, tool_name, dedup_key, status='SUCCESS')`, the engine returns the cached output without re-invoking the tool. This policy defines what goes into the canonical JSON object that is hashed to produce the key, organized by tool category. Per `data_layer_conventions_policy`, the dedup key is a base64url-encoded SHA-256 hash of a canonical JSON object.

---

## Encoding contract

```
dedup_key = base64url_no_padding( SHA-256( canonical_JSON( dedup_payload ) ) )
```

- `canonical_JSON` — RFC 8785 JCS per `data_layer_conventions_policy` (keys sorted, no whitespace, null-explicit, decimal-string currency amounts).
- `SHA-256` — locked per `data_layer_conventions_policy`. No other hash algorithm in MVP.
- `base64url_no_padding` — URL-safe base64, no padding characters, 43 characters output. Matches the `dedup_key` encoding specified in `data_layer_conventions_policy`'s Use sites table.
- Collision resistance: SHA-256 produces 256 bits. At our maximum anticipated tool-invocation volume (tens of millions of rows per business lifetime), the probability of a collision is negligible — no practical collision risk.

---

## Core principle: semantic uniqueness

The dedup payload must include exactly those fields that make the operation semantically unique. The test is:

> If this tool were called again with the same dedup payload, should the engine treat it as the same invocation and return the prior result — or re-invoke?

If the answer is "same invocation, return prior result": those fields belong in the key.
If the answer is "different invocation, must re-run": one of those differing fields must be in the key.

`schema_version` is included in every key so that a breaking schema upgrade forces a fresh invocation even when all other inputs are identical.

---

## Generator patterns by tool category

### Category 1 — Parsing tools

Tools that parse raw uploaded artifacts (bank statement files, document files). The operation is semantically unique per uploaded artifact and schema version.

```json
{
  "tool_name": "intake.parse_statement",
  "upload_id": "<uuid-of-the-upload-row>",
  "schema_version": "1.0"
}
```

**Why `upload_id`:** the upload artifact is immutable once stored; same `upload_id` always refers to the same bytes. If the same file is uploaded twice (distinct `upload_id` values), the two parses are distinct operations and should each run.

**Why not `file_hash`:** `upload_id` is sufficient because the storage layer guarantees the file bytes are immutable per ID. Using the file hash would require reading the file before computing the key, which is wasteful and adds a dependency. If storage-layer integrity is a concern, that is Block 04's responsibility — the dedup key trusts `upload_id`.

---

### Category 2 — Classification tools

Tools that classify a single transaction row (Layers 1, 2, 3).

```json
{
  "tool_name": "classification.run_layer_1",
  "transaction_id": "<uuid-of-the-transaction-row>",
  "schema_version": "1.0"
}
```

**Why `transaction_id`:** classification operates on one transaction at a time. Same transaction + same schema version = same classification result (deterministic within a schema version).

**Why not `transaction_fingerprint`:** the fingerprint is derived from the transaction's content and is already encoded in `transaction_id`'s data lineage. Using the row ID is simpler and avoids a join to compute the key.

**Layer 3 (AI-assisted):** Layer 3 classification involves AI invocation. Its dedup key follows Category 4 (AI tools), not this category, because the input hash and prompt version are needed to capture the full semantic identity.

---

### Category 3 — Matching tools

Two sub-patterns depending on whether the tool is a proposer-only or a proposer+writer.

**Proposer+writer (tools that score and record a match):**
```json
{
  "tool_name": "matching.score_income_pairs",
  "transaction_id": "<uuid>",
  "document_id": "<uuid>",
  "schema_version": "1.0"
}
```

**Proposer-only (score only; no write side effect):**
```json
{
  "tool_name": "matching.score_pair",
  "transaction_id": "<uuid>",
  "schema_version": "1.0"
}
```

For proposer-only tools, `document_id` is omitted because the proposer evaluates all candidate documents for a transaction in one pass; the output is the full candidate list, not a per-pair result.

**Why both IDs for proposer+writer:** a match between transaction T and document D is a distinct operation from a match between T and document E. Both IDs are required to distinguish these two operations.

**Multi-invoice allocation tools:**
```json
{
  "tool_name": "matching.propose_multi_invoice_allocation",
  "transaction_id": "<uuid>",
  "schema_version": "1.0"
}
```

The allocation proposal is keyed on the transaction only; the set of candidate invoices is determined by the tool's query at invocation time.

---

### Category 4 — AI tools

Tools that invoke the AI gateway (Block 06). These require the input hash and prompt version in addition to context identifiers, because the AI output is a function of the prompt + input, not just the entity ID.

```json
{
  "tool_name": "ai.run_end_scan",
  "input_hash": "<sha256-hex-of-post-redaction-input-payload>",
  "prompt_version": "end_scan_v2.1",
  "schema_version": "1.0"
}
```

**`input_hash`:** SHA-256 (hex encoding, per `data_layer_conventions_policy`) of the AI input payload after Block 06's redaction pass. The hash is computed over the canonical JSON of the post-redaction payload. Using the post-redaction payload (not the pre-redaction payload) ensures the dedup key does not itself contain PII.

**`prompt_version`:** a bump in the prompt version must produce a fresh AI invocation even for an identical input. If a prompt is revised for accuracy, the prior cached output is stale.

**`schema_version`:** covers the tool's input/output schema. A schema major bump forces a fresh invocation.

**Note on `workflow_run_id` absence:** AI tool dedup is scoped per workflow run by the engine's `(workflow_run_id, tool_name, dedup_key)` lookup. The `workflow_run_id` is not in the dedup payload itself because it is already part of the lookup key at the `tool_invocations` table level. Adding it to the payload would be redundant.

---

### Category 5 — Ledger tools

Tools that prepare ledger entries for a specific transaction within a specific workflow run.

```json
{
  "tool_name": "ledger.prepare_income_entries",
  "workflow_run_id": "<uuid>",
  "transaction_id": "<uuid>",
  "schema_version": "1.0"
}
```

**Why `workflow_run_id`:** ledger entries are period-scoped. The same transaction processed in an adjustment run (`OUT_ADJUSTMENT`) produces different ledger entries from the original monthly run. Including `workflow_run_id` ensures adjustment runs generate fresh entries even when the transaction ID is unchanged.

**Invoice lifecycle ledger tools:**
```json
{
  "tool_name": "ledger.prepare_invoice_lifecycle_entries",
  "workflow_run_id": "<uuid>",
  "invoice_id": "<uuid>",
  "lifecycle_transition": "WRITTEN_OFF",
  "schema_version": "1.0"
}
```

The `invoice_id` replaces `transaction_id` here because this path is invoice-keyed, not transaction-keyed (per the 2026-05-08 amendment adding `prepare_invoice_lifecycle_entries`).

---

### Category 6 — Archive tools

Tools that build, seal, and promote the archive bundle for a workflow run.

```json
{
  "tool_name": "archive.lock_period",
  "workflow_run_id": "<uuid>",
  "manifest_version": 1,
  "schema_version": "1.0"
}
```

**`manifest_version`:** the archive bundle's manifest version number. Re-finalization (adjustment runs) increments the manifest version; the new archive invocation produces a fresh dedup key even though `workflow_run_id` is the parent run's ID.

**Why not `bundle_hash`:** the bundle hash is an output of the archive tool, not an input. It cannot be known before the tool runs, so it cannot be part of the dedup key.

---

## `schema_version` rules

`schema_version` in the dedup payload matches the tool's registered `schema_version` (major.minor) per `tool_naming_convention_policy`. Rules:

- **Major bump:** the tool's schema version changes; all in-flight runs that have not yet invoked this tool will compute a new dedup key and get a fresh invocation. Runs that already have a `SUCCESS` row with the old key use the cached result for the remainder of the run (they were started under the old schema version per `workflow_run_schema.effective_phase_sequence_json`).
- **Minor bump:** the schema version string changes; dedup keys containing the old minor version become stale and will result in fresh invocations. This is intentional for minor bumps that change behavior (e.g., a deterministic algorithm refinement that produces different output for some inputs).

---

## Canonical JSON construction

The dedup payload is serialized with RFC 8785 JCS, hashed with SHA-256, and the 32-byte digest is encoded as base64url without padding (43 characters). The same pinned canonical JSON library used for all project hashing applies here — per `data_layer_conventions_policy`'s determinism guarantee. Same input → byte-identical dedup key across all machines and library versions.

---

## What NOT to include / interaction with `external_request_id`

Never include in the dedup payload: wall-clock timestamps, invoking user IDs, request-level trace IDs, or pre-redaction PII fields (AI tools hash only the post-redaction payload).

The dedup key is complementary to `external_request_id`. The dedup key handles "same inputs → return prior result"; `external_request_id` handles "request issued, process crashed, retrieve result without re-issuing." Per Block 03 Phase 07, the engine checks the dedup key first; if no SUCCESS row exists but a PENDING row with a matching external request ID is found, it polls the external service rather than re-issuing.

---

## Cross-references

- `data_layer_conventions_policy` — SHA-256 algorithm (locked); base64url encoding for dedup keys; canonical JSON (RFC 8785); determinism guarantee
- `tool_naming_convention_policy` — tool name format; `schema_version` major/minor bump rules; `tool_invocations` table
- `audit_event_taxonomy` — `WORKFLOW_TOOL_DEDUP_HIT` (emitted when dedup key is found in `tool_invocations`)
- Block 03 Phase 07 — resumability framework; dedup-key lookup at `engine.invokeTool`; `external_request_id` complement
- Block 03 Phase 01 — `tool_invocations` table schema (column-level detail on `dedup_key`, `status`, `external_request_id`)
- Block 06 Phase 09 — AI cache; `input_hash` construction; post-redaction payload
- Block 12 — OUT Workflow (heavy consumer; parsing, classification, matching, ledger, archive tools)
- Block 13 — IN Workflow + Invoice Generator (heavy consumer; income matching, ledger, finalization tools)
