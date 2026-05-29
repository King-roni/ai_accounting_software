# accountant_pack_manifest_schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Co-owners:** 04, 15 · **Stage:** 4 sub-doc (Layer 2)

The canonical JSON shape of the `manifest.json` file embedded at the root of every Cyprus accountant export pack. The pack is the deterministic zip bundle Block 16 Phase 11 assembles per-business on demand. The manifest is a **pack-scope index** of every included component — distinct from the `archive.archive_manifests` chain (Block 15) which is the source-of-truth archive index.

Field-evolution is additive-only in MVP, mirroring Block 15 Phase 06's manifest-versioning pattern. Tamper detection at pack-read time follows `accountant_pack_tamper_runbook` (deferred Layer 2 forward reference).

---

## Scope and provenance

| Concept | Source |
| --- | --- |
| What gets bundled | `accountant_pack_config.component_visibility` per business |
| Where components come from | Block 15 archive zone (latest manifest version per period) |
| How the bundle is built | Block 16 Phase 11's `accountant_pack.generate` |
| Where the pack lives once built | Block 04 Phase 05's Raw Upload zone with a signed-URL TTL |
| Who can build | `REPORT_EXPORT_FULL` (Owner / Admin / Accountant) |

The pack is NEVER a substitute for the archive bundle. It is a re-bundling for accountant convenience; the archive bundle remains the legal source-of-truth.

## Canonical JSON shape — `schema_version: 1.0`

The `manifest.json` is canonical JSON per `data_layer_conventions_policy`. Object keys lexicographically sorted; integer minor units forbidden in this manifest (currency is not carried here — only component metadata).

```json
{
  "schema_version": "1.0",
  "pack_id": "01900000-0000-7000-0000-000000000000",
  "generated_at": "2026-04-15T10:23:45Z",
  "generated_by_user_id": "...",
  "generated_by_run_id": null,
  "business": {
    "id": "...",
    "legal_name": "Acme Trading Ltd",
    "country": "CY",
    "vat_number": "CY10123456X",
    "trn": "..."
  },
  "scope": {
    "kind": "period",
    "period_start": "2026-01-01",
    "period_end": "2026-01-31"
  },
  "config_snapshot": {
    "accountant_pack_config_id": "...",
    "config_updated_at": "2026-03-01T08:00:00Z",
    "component_visibility": {
      "locked_ledger_csv": true,
      "supplier_overview_csv": false,
      "vies_export_xml": true
    }
  },
  "components": [
    {
      "component_id": "locked_ledger_csv",
      "relative_path": "ledger/locked_ledger_entries.csv",
      "sha256": "abc...",
      "byte_size": 12345,
      "source_archive_package_id": "...",
      "source_manifest_version_number": 2,
      "format": "csv",
      "rendered_at": "2026-04-15T10:23:30Z"
    }
  ],
  "source_archive_packages": [
    {
      "archive_package_id": "...",
      "manifest_version_number": 2,
      "bundle_hash": "...",
      "period_start": "2026-01-01",
      "period_end": "2026-01-31"
    }
  ],
  "bundle_hash": "...",
  "rfc_3161_anchor": null
}
```

### Field semantics

| Field | Type | Notes |
| --- | --- | --- |
| `schema_version` | string | `"<major>.<minor>"`; consumers branch on major |
| `pack_id` | uuid v7 | The `exports` row id; matches `exports.export_id` |
| `generated_at` | timestamptz | ISO 8601 with `Z` suffix; UTC only |
| `generated_by_user_id` | uuid | The principal who triggered the export |
| `generated_by_run_id` | uuid \| null | Set when Stage 2+ scheduled delivery fires it; null for on-demand |
| `business.country` | ISO 3166 alpha-2 | Always `CY` in MVP |
| `business.vat_number` | string | Cyprus VAT format per Block 11 Phase 04 validation |
| `scope.kind` | enum | One of `period` / `quarter` / `year` per Phase 11 |
| `config_snapshot` | object | Snapshot of the `accountant_pack_config` row at generation time — preserves "what was selected" even if config is later edited |
| `components[]` | array | One entry per included component file inside the zip; order matches alphabetical relative_path (canonical) |
| `components[].sha256` | hex string (64) | Per `data_layer_conventions_policy` — hex lowercase |
| `components[].source_manifest_version_number` | integer | The manifest version the component was drawn from; for quarter/year scope, multiple manifests resolve to multiple entries |
| `components[].format` | enum | One of `csv` / `xlsx` / `pdf` / `xml` / `txt` |
| `source_archive_packages[]` | array | The full set of archive packages the pack draws from; one entry per `(archive_package_id, manifest_version_number)` pair |
| `bundle_hash` | hex string (64) | SHA-256 of the zip bundle bytes EXCLUDING the manifest.json's own self-hash — populated via the same two-pass construction as `archive_manifest_schemas` |
| `rfc_3161_anchor` | object \| null | Optional anchor per `archive_hash_anchor_integration`; MVP leaves null |

`generated_at` is the ONLY value that varies between two builds of the same pack with the same inputs. The bundle's determinism contract excludes this single field; CI fixture asserts every other byte is identical.

## Component-id closed enum

The `component_id` values match Phase 11's pack-config component list. Closed enum:

```
period_bounds                business_identification
locked_ledger_csv            locked_ledger_xlsx            locked_ledger_pdf
vat_summary_pdf              vat_summary_xlsx              vies_export_xml
evidence_index_csv           evidence_files_directory
reconciled_invoice_list_csv  reconciled_invoice_list_pdf
adjustment_records_csv       adjustment_records_pdf
finalization_approval_record_pdf
signed_manifest_pdf
supplier_overview_csv
period_report_pdf
```

Adding a component_id requires a `Docs/decisions_log.md` amendment AND a schema-version minor bump (additive).

## Pack zip file ordering

Per Block 15 Phase 05's deterministic zip pattern (carried forward):

- File order: alphabetical by `relative_path` ascending
- File mtime: zeroed (Unix epoch)
- File permissions: `0644` for files, `0755` for `evidence/`
- Compression: DEFLATE level 6
- Zip64 enabled uniformly
- No central directory comment

The `manifest.json` itself sits at the zip root and is the FIRST file in alphabetical order on its own row.

## Tamper detection at pack-read time

A reader verifying a downloaded pack:

1. Open the zip; read `manifest.json`
2. Parse and validate against `schema_version`
3. For each `components[]` entry: re-compute SHA-256 of the file at `relative_path`; compare to `components[].sha256`
4. Re-compute `bundle_hash` using the same two-pass algorithm; compare to `manifest.bundle_hash`
5. Any mismatch → reader rejects the pack with `accountant_pack_tamper_detected`

Block 16 Phase 11 emits `ACCOUNTANT_PACK_MANIFEST_TAMPER_DETECTED` (BLOCKING per `severity_enum`) when verification fails server-side at re-download time; the runbook is `accountant_pack_tamper_runbook` (Layer 2 forward reference).

## Schema-evolution rules

Additive-only, backward-compatible. Two change classes:

| Change | Schema bump | Consumer impact |
| --- | --- | --- |
| New optional field on existing object | minor (`1.0` → `1.1`) | Old consumers ignore the field; no break |
| New component_id added to the closed enum | minor | Old consumers skip the unknown component_id with a log warning |
| Field renamed / removed | major (`1.x` → `2.0`) | Old consumer version must remain readable; new consumer version reads `2.0+` |
| Field type changed | major | Same |
| Object-key reordering | none — canonical JSON sorts deterministically |

A minor bump emits `ACCOUNTANT_PACK_MANIFEST_SCHEMA_VERSION_BUMPED` with `{ old_version, new_version, added_fields }`. Major bumps require a `Docs/decisions_log.md` amendment plus a parallel consumer rollout per `tool_naming_convention_policy` Section "Schema versioning".

## Per-business config preservation

Per Phase 11 Stage 1 commitment: configuration is preserved across periods so two consecutive months for the same business produce the same component set. `config_snapshot` carries the `config_updated_at` so a reader can detect "config changed mid-quarter" cases when reconciling against an `accountant_pack_config_history` audit (Stage 2+).

## Mobile rejection

Pack generation is a write surface — `report.trigger_accountant_pack` rejects `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints`. Mobile clients can `report.download_export` an already-generated pack (read intent).

## Audit events

| Event | When | Payload anchor |
| --- | --- | --- |
| `ACCOUNTANT_PACK_CONFIG_UPDATED` | Per-business config toggled via `BUSINESS_SETTINGS_EDIT` | `{ business_id, actor_user_id, before, after }` |
| `ACCOUNTANT_PACK_GENERATION_STARTED` | Pipeline invoked | `{ pack_id, business_id, scope, config_snapshot_id }` |
| `ACCOUNTANT_PACK_GENERATION_COMPLETED` | Bundle persisted | `{ pack_id, bundle_hash, component_count }` |
| `ACCOUNTANT_PACK_GENERATION_FAILED` | Any step failure | `{ pack_id, failing_step, error_kind }` |
| `ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED` | Pre-generation check | `{ business_id, period_start, period_end }` |
| `ACCOUNTANT_PACK_REJECTED_TAMPER_DETECTED` | Pre-read verification of any source archive fails | `{ archive_package_id, expected_hash, observed_hash }` |
| `ACCOUNTANT_PACK_MANIFEST_TAMPER_DETECTED` | Server-side re-verification fails | `{ pack_id, failing_component_id }` |
| `ACCOUNTANT_PACK_MANIFEST_SCHEMA_VERSION_BUMPED` | Schema-version increment | `{ old_version, new_version }` |

All events live under the `ACCOUNTANT_PACK` domain per `audit_log_policies` allowlist amendment.

## Cross-references

- `archive_manifest_schemas` — source-of-truth archive manifest chain consumed by the pack
- `archive_bundle_layout_schema` — zip determinism pattern carried forward
- `data_layer_conventions_policy` — UUID v7, SHA-256 hex, canonical JSON
- `audit_log_policies` — `ACCOUNTANT_PACK` domain + RLS visibility
- `audit_event_taxonomy` — `ACCOUNTANT_PACK_*` events
- `mobile_write_rejection_endpoints` — `report.trigger_accountant_pack` is MOBILE-rejected
- `permission_matrix` — `REPORT_EXPORT_FULL` + `BUSINESS_SETTINGS_EDIT` surfaces
- `vies_record_format` — VIES XML component shape
- Block 16 Phase 11 — accountant pack composition + VIES XML
- Block 15 Phase 05 / 06 — source archive structure
- 2026-05-09 decisions-log amendment — `BUSINESS_SETTINGS_EDIT` for config writes
- `accountant_pack_tamper_runbook` (Layer 2 forward reference) — operator response to manifest tamper
