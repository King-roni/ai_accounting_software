# processing_artefact_taxonomy_policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owners:** 06 — AI Layer, 09 — Document Intake, 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

The closed enum of `processing_artifacts.artifact_type` values — what each represents, which block produces it, and where its payload lives. The Processing zone is a short-lived staging area; this policy pins the 5 canonical artefact categories so downstream blocks know what they're consuming and the prune engine knows how to schedule expiry per `processing_zone_ttl_and_prune_policy`.

---

## The 5 artifact types

```sql
CREATE TYPE artifact_type_enum AS ENUM (
  'OCR_TEXT',
  'EXTRACTED_FIELDS_DRAFT',
  'AI_PAYLOAD_REDACTED',
  'AI_RESPONSE',
  'MATCH_CANDIDATE_BUNDLE'
);
```

| `artifact_type` | Producer block | What it carries | Typical size | Inline vs Storage |
| --- | --- | --- | --- | --- |
| `OCR_TEXT` | B09·P04 Document OCR | Raw text extracted from the source PDF/image via Document AI | 10–500 KB | Storage (almost always) |
| `EXTRACTED_FIELDS_DRAFT` | B09·P05 Field extraction | Structured candidate fields (counterparty, amount, VAT, line items) BEFORE classification confirms them | <10 KB | Inline (mostly) |
| `AI_PAYLOAD_REDACTED` | B06 AI Privacy Gateway | Post-redaction payload actually sent to the AI provider (Tier 2 / Tier 3 only) | 1–50 KB | Inline if <10 KB, Storage if larger |
| `AI_RESPONSE` | B06 AI Privacy Gateway | The provider's response (Tier 2 / Tier 3 only) | 1–50 KB | Inline if <10 KB, Storage if larger |
| `MATCH_CANDIDATE_BUNDLE` | B10 Matching Engine | Pre-confirm candidate set for a transaction (top-N proposed matches with scores + signal breakdowns) | 5–100 KB | Storage if >25 KB |

The enum is closed. Adding a new artefact type requires:

1. ALTER TYPE migration adding the value (see project gotcha: deferred visibility → split into two migrations when used in same migration)
2. Update to this policy + the producer block's docs
3. Update to `processing_zone_ttl_and_prune_policy` if TTL differs
4. Update to the prune background job's per-type handling

## Producer block rules

Each block that writes to `processing_artifacts` MUST declare the artifact_type explicitly. The engine's INSERT path validates the producer's tool registration against the artifact_type — a tool with `side_effect_class` that does NOT include `WRITES_PROCESSING_ZONE` cannot insert. The validation lives in the writer-trigger per Block 04 Phase 06.

### Producer ↔ artifact_type lock

| Block | Permitted artifact_type values |
| --- | --- |
| B06 (AI Layer) | `AI_PAYLOAD_REDACTED`, `AI_RESPONSE` (exclusive — only B06 may write these) |
| B09 (Document Intake) | `OCR_TEXT`, `EXTRACTED_FIELDS_DRAFT` (exclusive — only B09 may write these) |
| B10 (Matching Engine) | `MATCH_CANDIDATE_BUNDLE` (exclusive) |
| All others | NONE — no other block may write Processing-zone artefacts |

The exclusivity rule is enforced by the writer-trigger: it checks the calling tool's registered block against the artifact_type. A B11 tool attempting to write `OCR_TEXT` is rejected with `PROCESSING_ARTIFACT_PRODUCER_MISMATCH`.

## Source reference polymorphism

Every artefact references the operational entity it derives from via `source_reference_type` + `source_reference_id`. Per phase doc B04·P06: this is NOT a Postgres-native FK; integrity is enforced via CHECK constraint on the `(source_reference_type, source_reference_id)` pair plus a write-time validator.

| `artifact_type` | Allowed `source_reference_type` values |
| --- | --- |
| `OCR_TEXT` | `documents` |
| `EXTRACTED_FIELDS_DRAFT` | `documents` |
| `AI_PAYLOAD_REDACTED` | `documents`, `transactions`, `match_records` (whichever entity the AI call was reasoning about) |
| `AI_RESPONSE` | Same as `AI_PAYLOAD_REDACTED` — paired records share the same source reference |
| `MATCH_CANDIDATE_BUNDLE` | `transactions` |

## Consumer block rules

Downstream blocks read Processing-zone artefacts via `source_reference` joins:

- **B11 (Ledger)** reads `EXTRACTED_FIELDS_DRAFT` for invoice line-item details + VAT classification inputs
- **B10 (Matching)** reads `OCR_TEXT` for document text similarity scoring
- **B14 (Review queue)** reads `MATCH_CANDIDATE_BUNDLE` to render the candidate list when a transaction is held for review
- **B16 (Dashboard)** does NOT read Processing zone directly — only via operational tables (the per-source data is the operational record)

Read access is gated by RLS per `storage_bucket_configuration` §3 (service-internal only for the Storage payload portion; the row itself is per-business RLS).

## Lifecycle markers

Every artefact carries:

- `created_at` (set at INSERT)
- `expires_at` (set by producer per `processing_zone_ttl_and_prune_policy` defaults)
- `payload_inline jsonb NULL` OR `payload_storage_path text NULL` (XOR enforced by CHECK — see `inline_vs_storage_decision_policy`)
- `payload_hash text NOT NULL` (SHA-256 hex per `data_layer_conventions_policy` §1)

Once written, artefacts are immutable: no UPDATE / DELETE except the prune job (per Block 04 Phase 06's `WRITES_PROCESSING_ZONE` writer role).

## Audit events

```ts
emitAudit("PROCESSING_ARTIFACT_CREATED", {
  artifact_id, business_id, workflow_run_id,
  artifact_type,
  source_reference_type, source_reference_id,
  payload_hash,
  size_bytes,
  storage_mode: "INLINE" | "STORAGE",
  created_at
});
```

Severity LOW. Aggregated per audit-volume policy when bulk-inserting (e.g., 50 candidate bundles for a 50-tx run aggregate into 1 event with `aggregated_count: 50`).

## Cross-references

- `processing_zone_ttl_and_prune_policy` — per-type TTL windows + prune job + legal-hold override
- `redaction_at_write_policy` — `AI_PAYLOAD_REDACTED` single-writer rule
- `inline_vs_storage_decision_policy` — `payload_inline` vs `payload_storage_path` decision tree
- `storage_bucket_configuration` §3 — processing-zone bucket
- `data_layer_conventions_policy` — UUID v7 + SHA-256 + canonical JSON
- `tool_side_effect_taxonomy` — `WRITES_PROCESSING_ZONE` class
- `audit_event_payload_schemas` (Stage-6 catalog) — `PROCESSING_ARTIFACT_*` payloads
- Block 04 Phase 06 — owning phase
- Block 06 Phase 09 — AI Privacy Gateway producer
- Block 09 Phase 04 / 05 — OCR + field-extraction producers
- Block 10 — matching engine producer
- Block 11 — extracted-fields consumer
- Block 14 — match-candidate-bundle consumer
