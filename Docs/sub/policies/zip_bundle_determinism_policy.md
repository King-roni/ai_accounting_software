# ZIP Bundle Determinism Policy

**Category:** Policies · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

This policy defines the rules that guarantee byte-for-byte reproducibility of the archive bundle ZIP and all PDF artefacts it contains. Determinism is required for two independent reasons: (1) the bundle's SHA-256 hash is recorded in the audit chain and the RFC 3161 timestamp — a non-deterministic render would produce a different hash on re-render, breaking verification; (2) regulators or auditors may independently verify that a re-rendered bundle matches the sealed one.

Violations of this policy are build-blocking. The CI determinism check described in this document is a required gate on every PR that touches ZIP assembly, PDF generation, or the pinned library versions.

---

## Purpose

Byte-for-byte reproducibility means: given the same input data (manifest entries, document bytes, invoice fields, period parameters), two independent renders of the bundle — on different machines, at different times, using the same pinned library versions — produce identical output bytes. The SHA-256 of both renders is identical.

This property is not automatic. ZIP files and PDFs contain several sources of non-determinism that must be explicitly suppressed.

---

## ZIP determinism rules

### File sort order

All entries in the ZIP archive are sorted by their `file_path_in_bundle` value, lexicographic ascending (byte-order comparison on UTF-8 encoded paths). The sort is applied before any entry is written. Two bundles with the same files but different insertion orders are non-deterministic and fail the CI check.

The sort key is the relative path within the ZIP, not the Object Storage `object_key`. Example sort order:

```
audit/audit_slice.json
evidence/doc-019186f4.pdf
evidence/doc-019186f5.pdf
ledger/period_report.json
manifest.json
```

### Stored timestamps

All ZIP entries use Unix epoch 0 (`1970-01-01T00:00:00Z`) as the stored last-modified timestamp. The local file header `last mod file time` and `last mod file date` fields are both set to 0. No entry carries a real filesystem timestamp. This eliminates the most common source of ZIP non-determinism.

### Compression

All entries use DEFLATE compression at a fixed compression level of 6. The compression level is passed explicitly to the ZIP library at the call site — it is never left to a library default, because library defaults may change across versions. Level 6 balances size and CPU cost and is the project standard.

The `store` (no compression) mode is not used for any entry in the archive bundle. Mixing compression modes produces different bytes for the same content.

### Operating system metadata

The ZIP entry external attributes field is set to 0 for all entries. No Unix permission bits, Windows file attributes, or OS-specific metadata are written. ZIP files created on macOS, Linux, or Windows must produce identical external attributes.

### ZIP64 extension

ZIP64 extensions are enabled unconditionally (not only when file sizes require it). This prevents a class of non-determinism where bundles near the 4 GB ZIP size limit produce different structures depending on whether the library enables ZIP64 before or during write.

---

## PDF/A-2a determinism rules

Invoice PDFs and evidence PDFs included in the bundle must conform to PDF/A-2a (ISO 19005-2). PDF/A-2a compliance is both an archival requirement (see `pdf_accessibility_policy.md`) and a prerequisite for determinism: the standard constrains metadata fields that are common sources of render variance.

### CreationDate pinning

The PDF `CreationDate` metadata field is set to the document's logical timestamp, not the render timestamp:

- For invoice PDFs: set to the invoice `issued_at` timestamp.
- For evidence PDFs: set to the `document.created_at` timestamp of the source document row.
- For the period report PDF: set to the `workflow_run.finalized_at` timestamp.

Under no circumstances is `CreationDate` set to the current wall clock at render time. Wall-clock render timestamps are the primary cause of PDF non-determinism.

`ModDate` is set to the same value as `CreationDate`. No other time-varying metadata field is written.

### Font pinning

All fonts used in PDF generation are declared in `pdf_font_version_manifest.json` at the repository root. The manifest records, for each font:

- `font_family`: the font family name (e.g., `"Inter"`)
- `font_weight`: e.g., `400`, `700`
- `file_path`: repository-relative path to the font file
- `sha256_hex`: SHA-256 of the font file bytes

The PDF rendering library loads fonts exclusively from the paths declared in this manifest. It never resolves fonts from the host OS font directory. This guarantee is enforced by a startup assertion in the PDF rendering module that fails if any font load path falls outside the repository font directory.

Upgrading a font requires:
1. Adding a new entry to `pdf_font_version_manifest.json` (or replacing the existing entry with an incremented version note).
2. Running the CI determinism check against the updated manifest.
3. A code-review approval from a Block 15 owner before merge.

Downgrading a font version is not permitted without a decisions log amendment.

### No random metadata

PDF producer metadata (the `Producer` field in the document information dictionary) is set to a static string pinned in the PDF rendering module configuration. It does not include the library version string, hostname, or any runtime-variable value. Changes to the producer string require the same approval path as font upgrades.

PDF `ID` array entries (the two 16-byte strings in the PDF trailer) are derived deterministically from the SHA-256 of the document's canonical JSON payload, not from a random UUID generator.

---

## Library version pinning

The ZIP assembly library and the PDF rendering library are pinned in `package-lock.json`. Automated dependency upgrades (Dependabot, Renovate, or equivalent) are blocked on these two packages. The blocking configuration is enforced by:

- An explicit `ignore` or `pin` rule in the dependency update configuration file.
- A CI job that fails if either library version in `package-lock.json` does not match the version recorded in `Docs/sub/policies/pinned_library_versions.md`.

Upgrading either library requires:
1. Running the CI determinism check (see below) with the new version.
2. If the check passes, updating `pinned_library_versions.md` with the new version and the date of validation.
3. Code-review approval from a Block 15 owner.

---

## CI determinism check

A dedicated CI step runs on every PR that touches:
- Any file under `src/archive/` (ZIP assembly, bundle construction)
- Any file under `src/pdf/` (invoice and evidence PDF rendering)
- `pdf_font_version_manifest.json`
- `package-lock.json` (specifically the ZIP or PDF library entry)

The check procedure:

1. Render the same test input set twice using separate process invocations (no shared in-process state).
2. Assert byte-for-byte equality of the output ZIP (for bundle assembly) or output PDF (for PDF rendering).
3. If the assertion fails, emit `ARCHIVE_DETERMINISM_VALIDATION_FAILED` in the CI audit log (not a runtime emission — CI test infrastructure only) and block the PR.

The test input set is a fixture defined in `test/fixtures/determinism_bundle_fixture/`. It covers at least one invoice PDF, one evidence PDF, one period report, and one audit slice. Fixture data must not contain real business data.

---

## Audit event

| Event | Severity | Emission point |
|---|---|---|
| `ARCHIVE_DETERMINISM_VALIDATION_FAILED` | BLOCKING | CI determinism check step, on byte-inequality between two renders |

`ARCHIVE_DETERMINISM_VALIDATION_FAILED` (BLOCKING) — emitted by the CI determinism check when two renders of the same inputs produce different output bytes. BLOCKING because a non-deterministic render invalidates the hash recorded in the RFC 3161 timestamp and breaks post-seal verification. Payload (CI audit context): `failing_component` (`ZIP_ASSEMBLY` or `PDF_RENDER`), `fixture_name`, `render_1_sha256_hex`, `render_2_sha256_hex`, `git_commit_sha`.

This event is emitted in the CI test audit context, not in the runtime audit chain. It does not appear in the business-scoped `audit_log` table.

---

## Cross-references

- `archive_bundle_construction_schema.md` — two-pass construction that produces the ZIP this policy governs
- `archive_verification_policy.md` — post-seal verification that relies on deterministic hash reproducibility
- `rfc3161_timestamp_policy.md` — RFC 3161 timestamp is applied to the sealed ZIP; determinism is required for hash consistency
- `invoice_pdf_schema.md` — invoice PDF field definitions; `CreationDate` pinning applies to invoice renders
- `pdf_accessibility_policy.md` — PDF/A-2a compliance requirements; accessibility and determinism share the same standard
- `audit_event_taxonomy.md` — canonical definition for `ARCHIVE_DETERMINISM_VALIDATION_FAILED`
