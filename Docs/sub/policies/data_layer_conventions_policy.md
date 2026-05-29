# Data Layer Conventions Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 1 convention)

Three locked conventions every Schema sub-doc binds to: hashing, identifier generation, and canonical JSON serialization. These conventions are the foundation for tamper-resistance (audit chain), determinism (archive bundles, evidence PDFs, exports), and tenant isolation safety. Migration paths are explicit so the conventions can evolve without breaking existing data.

Block 04 Phase 01 is the canonical implementation home for the helper functions referenced below.

---

## 1. Hashing

**Algorithm: SHA-256 (locked Stage 1).**

SHA-256 is chosen for ubiquity, hardware acceleration on modern CPUs, and conservative cryptographic margin. The hash output is 256 bits, sufficient for collision resistance at our scale (every business' lifetime production volume) by an enormous margin. BLAKE3 is faster but adoption is uneven; SHA-256 is the safer default for an integrity-critical system that operates partly on regulator-readable artefacts.

### Encoding

| Context | Encoding | Rationale |
| --- | --- | --- |
| Database string columns (text) | hex (lowercase, 64 chars) | Human-readable in pgAdmin / queries; stable copy-paste |
| URL or filename contexts | base64url (no padding, 43 chars) | URL-safe; shorter than hex |
| Binary column (`bytea`) contexts | raw bytes (32) | Avoids encoding overhead on hot paths |

Mixing encodings within the same logical hash value is forbidden. If a hash is computed in one encoding and consumed in another, the conversion happens once at the boundary and is documented at the call site.

### Use sites (canonical)

| Field | Hash input | Encoding |
| --- | --- | --- |
| `transactions.source_row_hash` | canonical JSON of the raw parsed row from the bank statement | hex |
| `transactions.fingerprint` | canonical JSON of `{date, amount_signed, account_id, normalized_description}` | hex |
| `documents.evidence_hash` | the file bytes after content-sniff validation | hex |
| `documents.content_hash` | OCR-stripped text bytes — used for cross-source dedup | hex |
| `archive.archive_packages.bundle_hash` | the full sealed zip bundle bytes | hex |
| `archive.archive_manifests.manifest_hash` | canonical JSON of the manifest JSON object | hex |
| Audit chain | `prev_chain_hash || canonical_json(event_payload)` | hex (stored on `audit_log.chain_hash`) |
| `dedup_key` (engine) | canonical JSON of the dedup payload per `dedup_key_generator_policy` | base64url |

### Future migration to BLAKE3

Deferred Stage 2+. The migration approach if and when adopted: add a `hash_alg` discriminator column (default `'sha256'`); compute new hashes with both algorithms during a transition window; queries continue to use SHA-256 until the discriminator flips per-table. No table loses access to its history during the transition.

This policy commits to no migration in MVP. Calling a non-SHA-256 algorithm is a code-review-blocking violation.

---

## 2. Identifier generation

**Default: UUID v7 (locked Stage 1).**

UUID v7 prefixes a 48-bit Unix-millisecond timestamp before a random tail. The result is monotonically increasing within ~1 ms precision, B-tree-friendly (hot pages stay clustered), and — critically — sorts in approximate creation-order without needing a separate `created_at` index for time-range scans.

UUID v4 (purely random) is reserved for contexts where the time prefix is information leakage:

| Use UUID v7 (default) | Use UUID v4 (exceptions) |
| --- | --- |
| Primary keys on every business-data table | Session IDs |
| Run / phase / tool-invocation IDs | Password reset tokens |
| Document / transaction / match-record IDs | Invitation tokens |
| Audit event IDs (sequencer also enforces order) | OAuth state nonces |
| Archive package / manifest IDs | Step-up MFA tokens (`step_up_tokens.id`) |
| | Anything where seeing creation time leaks security-relevant info |

Step-up MFA tokens use UUID v4 for the same reason as password-reset tokens — these are short-lived, unpredictable security tokens where temporal ordering is irrelevant and a time-ordered prefix would leak the approximate creation time to anyone who can read the token ID.

### Time-skew tolerance

UUID v7 generation tolerates clock skew up to 1 second between Postgres replicas. Beyond that, ordering is approximate but never wrong by more than the skew window. Postgres synchronized commits on the primary are sufficient for our tier of operations.

### Tenant isolation

UUID v7 alone does NOT carry tenant information. Tenant isolation is enforced exclusively via the `business_id` column and RLS — never by attempting to derive tenancy from the ID itself. This is non-negotiable; deriving tenancy from IDs is a class of bug the project's threat model rules out.

### Generation site

Postgres-side via the `gen_uuid_v7()` helper function declared in Block 04 Phase 01. Application-layer generation is permitted only for tokens (which use v4 anyway). The `gen_uuid_v7()` helper is implemented using the `pg_uuidv7` extension where available, with a fallback SQL implementation pinned in the same phase.

---

## 3. Canonical JSON serialization

**Standard: RFC 8785 (JCS) with project-specific clarifications below.**

Canonical JSON is the deterministic encoding used wherever bytes-equal-bytes matters: hash inputs, audit event payloads, archive manifests, dedup keys, and integrity verification.

### Rules

1. **Object keys** sorted lexically by UTF-16 codepoint (RFC 8785 §3.2.3).
2. **No insignificant whitespace** anywhere — no spaces after commas or colons, no trailing newline.
3. **Strings** escape only what JSON requires: `"`, `\`, control characters U+0000 through U+001F (using the `\u` form for those without a single-character escape). Forward slash is not escaped. Unicode code points above U+007F are emitted as-is in UTF-8 byte form, never as `\uXXXX` escapes.
4. **Numbers**:
   - Integers exactly representable as a JSON number — written as integers (`42`, not `42.0`).
   - Non-integers — shortest round-trip decimal (the value that, parsed back, yields the original IEEE 754 double).
   - No `+` prefix, no leading zeros, no trailing decimal point.
   - Currency amounts are NEVER serialized as floats. Currency lives as integer minor units (cents) or `numeric(15, 4)` strings — see "Currency special case" below.
5. **null** is explicit. A field with value `null` appears in the object; an absent field is structurally different. Serializers that "drop nulls" are forbidden.
6. **Arrays** preserve insertion order. Sorting an array changes its meaning.
7. **Booleans** lowercase: `true` / `false`.

### Determinism guarantee

Same input → byte-identical output across runs, machines, library versions, and CPU architectures. The library used is pinned by `csv_xlsx_pdf_library_integration` at the project level; this policy commits to the determinism property regardless of which library implements it.

### Currency special case

Floating-point currency is forbidden. Two acceptable forms:

- Integer minor units in a JSON `number` (e.g., `1234` for €12.34). The unit is documented at the schema level (always EUR minor units in this project unless a per-row currency column says otherwise).
- Decimal-precise string in a JSON `string` (e.g., `"12.34"`). Used in evidence-PDF and archive-manifest contexts where downstream readers expect human-readable amounts.

Mixing forms within the same logical field is forbidden. The chosen form is pinned per schema in the relevant Schemas sub-doc.

### Use sites (canonical)

| Field | Why canonical JSON |
| --- | --- |
| `audit_log.event_payload_canonical_json` | hash chain integrity — bytes feed into `chain_hash` |
| `archive.archive_manifests.manifest_canonical_json` | manifest hash determinism, cross-version reproducibility |
| `transactions.source_row_canonical_json` | feeds `source_row_hash`; required for cross-replica equality |
| `dedup_key` (engine) | feeds `dedup_key` hash per `dedup_key_generator_policy` |
| `archive_bundle_layout_schema` per-file JSONs | file-level hashes inside the bundle |
| AI cache key (Block 06 Phase 09) | cache-hit determinism across runs in the same workflow |

---

## Cross-references

- Block 04 Phase 01 — Hashing & ID utilities (canonical implementation home)
- Block 04 Phase 02 / 03 / 04 — Schemas that consume these conventions
- Block 05 Phase 02 / 03 — Audit log uses canonical JSON for chain hashing
- Block 15 Phase 04 / 05 — Archive bundles consume all three conventions
- `audit_log_policies` — audit chain partitioning and hash usage
- `dedup_key_generator_policy` (Block 03) — where canonical JSON feeds dedup keys

## Open items deferred to later sub-docs

- Specific JSON serialization library choice — `csv_xlsx_pdf_library_integration` (Stage 4 sub-doc, Block 16 owns)
- Specific UUID v7 implementation library/extension — Block 04 Phase 01 sub-doc
- BLAKE3 migration plan — out of MVP scope; revisited Stage 2+ if SHA-256 becomes a hot-path bottleneck
