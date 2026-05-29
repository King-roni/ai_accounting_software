# inline_vs_storage_decision_policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

The decision rule for storing a Processing-zone artefact's payload in the `payload_inline jsonb` column versus offloading it to `payload_storage_path` in the `processing-zone` Storage bucket. Inline payloads are simpler (joinable, indexable, easier to debug) but bloat the DB; Storage offload keeps the DB lean but adds a round-trip on every read. This policy pins the size threshold, the XOR enforcement, the encoding rules, and the migration path between modes.

---

## The XOR rule

```sql
ALTER TABLE processing_artifacts ADD CONSTRAINT payload_storage_xor CHECK (
  (payload_inline IS NOT NULL AND payload_storage_path IS NULL)
  OR
  (payload_inline IS NULL AND payload_storage_path IS NOT NULL)
);
```

Every artefact has EXACTLY ONE of inline or storage. Both NULL is invalid (no payload = no artefact); both populated is invalid (single source of truth violated). The CHECK constraint is the load-bearing guard.

## Size threshold

```
IF size_bytes < 10_240 (10 KB):   payload_inline
ELSE IF size_bytes < 65_536 (64 KB): payload_inline (acceptable; some bloat)
ELSE:                             payload_storage_path
```

The 10 KB threshold is the soft target — below it, inline is the default. Between 10 KB and 64 KB, inline is still acceptable when the artefact is frequently read (the round-trip cost outweighs the bloat). Above 64 KB, mandatory offload.

`size_bytes` is the JSON-serialised byte length of the canonical-JSON payload (per `data_layer_conventions_policy`) when storing inline; the file size at upload when offloading.

## Per-artefact-type defaults

Per `processing_artefact_taxonomy_policy`:

| `artifact_type` | Default mode | Override condition |
| --- | --- | --- |
| `OCR_TEXT` | STORAGE | Always — OCR text is typically 50+ KB |
| `EXTRACTED_FIELDS_DRAFT` | INLINE | Always — structured fields are tiny |
| `AI_PAYLOAD_REDACTED` | INLINE if <10 KB; STORAGE if larger | Per Tier — Tier 3 long-context payloads exceed 10 KB and offload |
| `AI_RESPONSE` | Same as paired `AI_PAYLOAD_REDACTED` | Pair-mode rule — both should be consistent |
| `MATCH_CANDIDATE_BUNDLE` | STORAGE if >25 KB; else INLINE | Override threshold (25 KB) because B14 review queue reads candidate bundles when rendering the held-run UI — round-trip cost matters |

The producer's writer must compute `size_bytes` and decide inline vs storage. Per Block 04 Phase 06's writer-trigger validation, the wrong-mode write is rejected (e.g., inline write of a 100 KB payload is rejected).

## Inline payload encoding

Inline payloads are stored as `jsonb`. They MUST be canonical JSON per `data_layer_conventions_policy` §3 (RFC 8785 JCS) — the same encoding that feeds `payload_hash`. This guarantees hash-byte determinism: re-reading the inline payload and re-hashing produces the same hash on every machine.

JSONB storage internally normalises key order, but the `payload_hash` is computed BEFORE the INSERT against the canonical JSON byte stream, so the hash is stable regardless of Postgres's internal JSONB representation.

## Storage payload encoding

Storage-offloaded payloads:

- File extension: `.json` for JSON payloads; `.txt` for OCR text; `.bin` for opaque binary
- Path convention: `{business_id}/{workflow_run_id}/{tool_invocation_id}/{artifact_id}.{ext}` per `storage_bucket_configuration` §3
- Content-Type: `application/json` or `text/plain` or `application/octet-stream`
- The file itself is the canonical-JSON byte stream (for JSON) or the raw bytes (for OCR / binary)
- `payload_hash` is computed against the file bytes BEFORE upload, then verified post-upload

If the post-upload hash verification fails, the row is NOT inserted and the Storage object is deleted. The producer must retry.

## Reading inline vs storage

Consumer code:

```ts
async function loadProcessingArtefact(artifact_id: uuid): Promise<unknown> {
  const row = await db.queryOne(
    `SELECT artifact_type, payload_inline, payload_storage_path, payload_hash
     FROM processing_artifacts WHERE id = $1`,
    [artifact_id]
  );

  if (row.payload_inline !== null) {
    return row.payload_inline;                       // JSONB → direct return
  }
  // Storage-offloaded
  const blob = await supabase.storage
    .from("processing-zone")
    .download(row.payload_storage_path);
  // Verify hash matches
  if (sha256_hex(blob) !== row.payload_hash) {
    throw new ProcessingArtifactHashMismatch(artifact_id);
  }
  return JSON.parse(blob);                           // or raw bytes if non-JSON
}
```

The hash verification on read is critical — it catches corruption / tampering between write and read. Per `data_layer_conventions_policy`, every Storage payload is hash-anchored.

## Migration between modes

Once written, an artefact's mode is IMMUTABLE — no UPDATE may change `payload_inline` ↔ `payload_storage_path`. If the producer realises after-the-fact that the wrong mode was chosen, the only path is to DELETE the artefact + re-create with the correct mode. This is rare in practice — the size_bytes calculation at write time is usually correct.

Mode migration during a Postgres VACUUM or table rewrite is forbidden — the rewrite must preserve the original mode bit-for-bit.

## DB bloat budget

The Processing zone's inline payload column is bounded by:

- Per-row hard cap: 64 KB (per the §size-threshold rule)
- Per-business soft cap: 100 MB cumulative inline payload across all artefacts for one business
- Soft-cap exceeded: emit `PROCESSING_ZONE_INLINE_BUDGET_EXCEEDED` (MEDIUM) for ops review

The soft cap is generous — a business with thousands of active runs each producing a few KB of inline payload sits well below. The cap exists to catch producer bugs (e.g., a tool that writes huge inline JSON blobs by mistake).

## Performance characteristics

| Mode | Read latency | DB CPU | Bloat | Best for |
| --- | --- | --- | --- | --- |
| Inline | <2 ms (single row read) | Negligible | High (in the DB) | Small frequently-read artefacts |
| Storage | 50–200 ms (round-trip to Supabase Storage) | Negligible | Zero (in the DB) | Large infrequently-read artefacts |

The 50–200 ms range for Storage reads includes the signed-URL generation + the S3-compatible GET. For consumers that need <10ms reads, inline is the only option.

## Cross-references

- `processing_artefact_taxonomy_policy` — sibling defining the 5 artifact_type values
- `processing_zone_ttl_and_prune_policy` — sibling defining TTL + prune job
- `storage_bucket_configuration` §3 — processing-zone bucket
- `data_layer_conventions_policy` §3 — canonical JSON encoding for both modes
- `redaction_at_write_policy` — `AI_PAYLOAD_REDACTED` writer uses this policy's threshold
- `audit_event_payload_schemas` (Stage-6 catalog) — `PROCESSING_ZONE_INLINE_BUDGET_EXCEEDED` shape
- `cross_tenant_alerting_runbook` — soft-cap alerting
- Block 04 Phase 06 — owning phase
- Block 06 / 09 / 10 — producer blocks
