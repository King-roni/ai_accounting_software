# archive_manifest_schemas

**Category:** Schemas · **Owning block:** 15 — Finalization & Secure Archive · **Co-owners:** 04, 16 · **Stage:** 4 sub-doc (Layer 2)

Three concerns merged into one sub-doc because they describe one feature surface: the canonical `manifest_v{N}.json` JSON shape inside the archive bundle, the two-pass self-reference construction algorithm with its convergence proof, and the query patterns over `archive.archive_manifests` for "latest version", "full history", and "ancestor-of-version" reads.

The manifest is **the index of an archive bundle**. Its bytes live both inside the zip (as `manifest_v{N}.json`) and in Postgres on `archive.archive_manifests.manifest_canonical_json` for fast indexed access. The two copies are byte-identical by construction.

---

## Canonical JSON shape — `schema_version: 1.0`

Per `data_layer_conventions_policy`: canonical JSON, object keys lexically sorted, no insignificant whitespace, strings minimally escaped.

```json
{
  "schema_version": "1.0",
  "manifest_version_number": 2,
  "prior_manifest_hash": "abc...",
  "archive_package_id": "01900000-0000-7000-0000-000000000000",
  "business_id": "...",
  "period_start": "2026-01-01",
  "period_end": "2026-01-31",
  "workflow_run_id": "...",
  "produced_by_approval_id": "...",
  "produced_at": "2026-04-15T10:23:45Z",
  "supersedes_manifest_version": 1,
  "delta_kinds_applied": ["RETROACTIVE_CREDIT_NOTE"],
  "evidence_inherited_from_versions": [1],
  "files": [
    {
      "name": "locked_ledger_entries.json",
      "size_bytes": 12345,
      "sha256": "..."
    },
    {
      "name": "manifest_v2.json",
      "size_bytes": 0,
      "sha256": "<self_hash_placeholder>"
    }
  ],
  "rfc_3161_anchor": {
    "timestamp_id": "...",
    "timestamp_value": "2026-04-15T10:23:50Z",
    "tsa_url": "..."
  },
  "bundle_hash_excluding_manifest": "...",
  "self_hash": "..."
}
```

### Field semantics

| Field | Type | Notes |
| --- | --- | --- |
| `schema_version` | string | `"<major>.<minor>"`; readers branch on major |
| `manifest_version_number` | integer ≥ 1 | Monotonic per `archive_package_id` |
| `prior_manifest_hash` | hex string \| null | SHA-256 of the prior version's `manifest_canonical_json`; null only when `manifest_version_number = 1` |
| `archive_package_id` | uuid v7 | FK to `archive.archive_packages.id` |
| `produced_by_approval_id` | uuid | The step-up approval row that authorized this finalization |
| `supersedes_manifest_version` | integer \| null | `manifest_version_number - 1` for adjustments; null for v1 |
| `delta_kinds_applied` | string[] | One of `RETROACTIVE_CREDIT_NOTE`, `WRITE_OFF`, `RECLASSIFICATION`, `BACKDATED_INVOICE`, `MANUAL_OVERRIDE` per `adjustment_record_schema` |
| `evidence_inherited_from_versions` | integer[] | Prior versions whose `evidence/<hash>.pdf` files this manifest references without duplicating them per Block 15 Phase 06 scan fix |
| `files[]` | array | Every file in the zip with its name + size + hash; sorted alphabetically by `name` |
| `bundle_hash_excluding_manifest` | hex string | Hash of the zip bytes after removing the manifest entry's payload but keeping the entry header — see two-pass construction |
| `self_hash` | hex string | SHA-256 of `manifest_canonical_json` with `self_hash` set to a fixed placeholder during computation — see convergence proof |

The `files[]` array is canonical: alphabetical sort by `name`. Insertion order in the JSON matches this sort.

## Two-pass construction with convergence proof

The manifest must contain its own hash. Direct self-reference creates an unsolvable equation. Two-pass construction resolves this deterministically.

### Algorithm

```
PASS 1 — Compute every file's hash EXCEPT the manifest's:
  1. Build the bundle's internal files (locked_ledger_entries.json, vies_export.csv, period_report.pdf, etc.)
  2. For each, compute SHA-256 of its bytes
  3. Assemble a draft manifest with:
       - All file entries populated with their real hashes
       - The manifest's own entry: { name: "manifest_v{N}.json", size_bytes: 0, sha256: "<self_hash_placeholder>" }
       - self_hash field set to "<self_hash_placeholder>" (literal string)
       - bundle_hash_excluding_manifest computed from the zip bytes with the manifest entry's payload set to an empty byte sequence

PASS 2 — Substitute the placeholder with the real hash:
  4. Serialize the draft manifest to canonical JSON
  5. Compute SHA-256 of that canonical JSON — call this H1
  6. Replace every occurrence of "<self_hash_placeholder>" in the canonical JSON with H1 (hex lowercase, 64 chars)
  7. Compute SHA-256 of the substituted canonical JSON — call this H2

  Note: H1 != H2 (substitution changed the bytes). That is intentional and OK.

PASS 3 — Verify convergence (one fixed iteration):
  8. The final manifest_canonical_json = the result of step 6
  9. The final self_hash = H1 (NOT H2)
  10. A verifier re-runs the construction:
        a. Reads manifest_canonical_json
        b. Replaces the self_hash field's value AND the manifest entry's sha256 in files[] with "<self_hash_placeholder>"
        c. Computes SHA-256 — must equal H1
```

### Convergence proof

The construction converges in exactly one substitution pass because:

1. The placeholder `<self_hash_placeholder>` is a fixed 64-character literal string with no dependency on the manifest contents
2. Hash H1 is deterministic given the placeholder-form bytes
3. Substituting placeholder → H1 is a pure string operation; no further hash depends on the substituted bytes (the verifier reverses the substitution, not re-applies it)

The verifier's role is to confirm step 10. If `SHA-256(canonical_json_with_placeholders) != self_hash`, the manifest is corrupt — `ARCHIVE_TAMPER_DETECTED` (BLOCKING).

Audit event on successful convergence: `ARCHIVE_MANIFEST_TWO_PASS_CONVERGED` with `{ archive_package_id, manifest_version_number, h1_hash, file_count }`.

### Why this is robust

Alternative approaches considered and rejected:

- **Recursive hashing without placeholder** — never converges; each iteration changes the bytes
- **Embed manifest hash externally** — works but loses the in-bundle self-describing property
- **Use a Merkle tree** — works but adds complexity for no benefit at our scale

The placeholder approach is the simplest deterministic answer and is symmetric with the `bundle_hash_excluding_manifest` pattern.

## Query patterns over `archive.archive_manifests`

Indexes per `archive_schema`:

```sql
CREATE INDEX idx_archive_manifests_package_version
  ON archive.archive_manifests(archive_package_id, manifest_version_number DESC);

CREATE INDEX idx_archive_manifests_prior_hash
  ON archive.archive_manifests(prior_manifest_hash)
  WHERE prior_manifest_hash IS NOT NULL;
```

### Pattern 1 — Latest version of a package

```sql
SELECT *
FROM archive.archive_manifests
WHERE archive_package_id = $pkg
ORDER BY manifest_version_number DESC
LIMIT 1;
```

P95: < 5 ms (index scan). Used by `block_16_as_of_view_schema`'s `v_ledger_entries_latest`.

### Pattern 2 — Full history of a package

```sql
SELECT *
FROM archive.archive_manifests
WHERE archive_package_id = $pkg
ORDER BY manifest_version_number ASC;
```

P95: < 50 ms (index scan; typical N < 10 versions per package). Used by Block 16 Phase 08's Period detail "Manifest chain" tab.

### Pattern 3 — Ancestor-of-version (walk back from any version)

```sql
WITH RECURSIVE chain AS (
  SELECT *, 0 AS depth
  FROM archive.archive_manifests
  WHERE id = $start_manifest_id

  UNION ALL

  SELECT am.*, c.depth + 1
  FROM archive.archive_manifests am
  INNER JOIN chain c
    ON am.manifest_hash = c.prior_manifest_hash
  WHERE c.depth < 100                             -- safety bound; real chains are short
)
SELECT * FROM chain ORDER BY depth ASC;
```

P95: < 20 ms (small recursion; typically 2–4 hops). Used by `archive_hash_anchor_integration` for full-chain re-verification.

### Pattern 4 — Manifest by version number explicitly

```sql
SELECT *
FROM archive.archive_manifests
WHERE archive_package_id = $pkg
  AND manifest_version_number = $version;
```

P95: < 5 ms (index seek on the composite index).

## `prior_manifest_hash` FK semantics

`prior_manifest_hash` is a logical FK by hash, not by ID, on purpose:

| Property | Why hash, not id |
| --- | --- |
| Tamper-evident | Recomputing hashes detects ANY change to a prior manifest |
| Cross-storage portable | A reader with only the manifest files (not the DB) can still walk the chain |
| Independent of UUID generation | The hash is content-addressed; the UUID is administrative |

The DB enforces internal consistency via a deferred check:

```sql
ALTER TABLE archive.archive_manifests
  ADD CONSTRAINT prior_manifest_hash_chain_consistent
  CHECK (
    (manifest_version_number = 1 AND prior_manifest_hash IS NULL)
    OR (manifest_version_number > 1 AND prior_manifest_hash IS NOT NULL)
  );
```

The hash's existence in the prior manifest is validated at write time by Block 15 Phase 06's lock sequence — the writer reads the prior manifest's `manifest_hash`, computes the new manifest with it as `prior_manifest_hash`, and INSERTs.

## `evidence_inherited_from_versions` field

Per Block 15 Phase 06 scan fix: evidence files are not duplicated across bundle versions. A v2 manifest may reference evidence files already inside `archive_v1_bundle.zip`. The reader's contract:

1. Look up `evidence_inherited_from_versions` on the current manifest
2. For each evidence hash referenced in the manifest's data files but NOT present in `files[]`: walk the inheritance chain — find the manifest version where the file first appeared
3. Read the file from THAT version's bundle

A reader of v3 may need v1, v2, AND v3 bundles to see all evidence. The retention engine keeps prior bundles until all members of the family have aged out per `archive_schema` "Per-bundle retention".

The `evidence_inherited_from_versions` field is canonical JSON `integer[]` sorted ascending. Empty array `[]` means no inheritance (original or fully self-contained adjustment).

## Schema-evolution rules

Additive-only, backward-compatible. Same rules as `accountant_pack_manifest_schema`:

| Change | Schema bump | Consumer impact |
| --- | --- | --- |
| New optional field | minor | Old consumers ignore |
| New value in `delta_kinds_applied` enum | minor | Old consumers skip unknown delta_kinds with a warning |
| Field renamed / removed | major | Old consumer version remains pinned to its `schema_version` |
| `prior_manifest_hash` semantics change | major | Would invalidate the chain — never permitted without a full migration |

Audit event on minor bump: handled via `WORKFLOW_TOOL_VERSION_BUMPED` (the tool registering the manifest writer).

## Determinism guarantee

Same logical inputs → byte-identical `manifest_canonical_json`. Stage 1 hard requirement (archive determinism). CI fixture `archive_bundle_determinism_fixtures` (Layer 2) asserts this end-to-end across two builds.

Sources of non-determinism eliminated:

- Map key ordering — canonical JSON sorts lexically
- Number formatting — currency-as-integer-minor-units or `numeric` string per `data_layer_conventions_policy`
- Time stamps — `produced_at` is the ONLY mutable field; the construction excludes it from the determinism contract by recording it once and reusing
- File ordering — alphabetical per `files[]` rule

## Mobile rejection

Manifest write paths are write surfaces — `archive.finalize_period` and `archive.adjustment_finalize` both reject `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints`. Manifest READ is allowed on mobile (drill-down through Block 16 Phase 02 to the Period detail).

## Audit events

| Event | Trigger |
| --- | --- |
| `ARCHIVE_PACKAGE_BUILT` | Bundle assembled (Block 15 Phase 05 step 3) |
| `ARCHIVE_PACKAGE_VERIFIED` | Pre-read verification passes |
| `ARCHIVE_MANIFEST_TWO_PASS_CONVERGED` | Construction algorithm completed |
| `FINALIZATION_MANIFEST_VERSION_INCREMENTED` | Per new manifest version on adjustment |
| `ARCHIVE_TAMPER_DETECTED` | Verifier finds a mismatch |
| `TIMESTAMP_RECORDED` | RFC 3161 anchor stored |

## Cross-references

- `archive_schema` — host tables `archive_packages` + `archive_manifests`
- `archive_bundle_layout_schema` — the zip layout that consumes this manifest
- `archive_hash_anchor_integration` — RFC 3161 anchoring of `manifest_hash`
- `archive_bundle_policies` — deterministic zip + per-bundle retention
- `data_layer_conventions_policy` — SHA-256 + canonical JSON
- `audit_log_policies` — `ARCHIVE_*` event family + chain partitioning
- `audit_event_taxonomy` — event catalogue
- `lock_sequence_policies` — when manifests are written
- `mobile_write_rejection_endpoints` — write-path mobile rejection
- `block_16_as_of_view_schema` — consumer of the chain
- `adjustment_record_schema` — `delta_kinds_applied` enum source
- Block 15 Phase 04 — original-finalization manifest (v1)
- Block 15 Phase 06 — adjustment manifest versioning (v2+)
- Block 15 Phase 07 — Object Lock + three-layer immutability
- Stage 1 decision — archive determinism is a strict requirement
