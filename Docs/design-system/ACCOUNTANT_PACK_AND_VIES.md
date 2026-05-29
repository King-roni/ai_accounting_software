# Accountant Pack & VIES Regulator XML

Two highest-stakes Cyprus-specific exports. Both gated by `REPORT_EXPORT_FULL`, both deterministic, both audit-logged through B16·P09's dispatcher.

**Phase**: B16·P11 (BOOK-158) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/11_accountant_pack_and_vies_regulator_xml.md` · **Schema**: `accountant_pack_config` table + 3 RPCs from `20260526000035_b16p11_accountant_pack_and_vies.sql`

---

## Accountant Export Pack

A configurable per-business ZIP bundle handed to a Cyprus accountant for tax filing or audit. Composed from Block-15 archive components.

### Component catalog (18 canonical component_ids)

| Component id | What it contains |
|---|---|
| `period_bounds` | Period start / end metadata |
| `business_identification` | Business name, country, VAT number |
| `locked_ledger_csv` | Locked ledger entries as CSV |
| `locked_ledger_xlsx` | Locked ledger entries as XLSX |
| `locked_ledger_pdf` | Locked ledger book PDF (P10 generator) |
| `vat_summary_pdf` | VAT preparation report PDF |
| `vat_summary_xlsx` | VAT preparation report XLSX |
| `vies_export_xml` | VIES XML (regulator-filed format; see below) |
| `evidence_index_csv` | Per-document hash + filename + transaction link |
| `evidence_files_directory` | Actual evidence file bytes (PDFs etc.) |
| `reconciled_invoice_list_csv` | Invoice + payment-allocation reconciliation CSV |
| `reconciled_invoice_list_pdf` | Reconciliation PDF |
| `adjustment_records_csv` | adjustment_records rows CSV |
| `adjustment_records_pdf` | adjustment_records PDF (before/after) |
| `finalization_approval_record_pdf` | workflow_run_approvals row with STEP_UP timestamp |
| `signed_manifest_pdf` | Pretty-print of the latest manifest JSON |
| `supplier_overview_csv` | Distinct counterparties with vendor-memory tier + total spend |
| `period_report_pdf` | Block-15 P05's canonical `period_report.pdf` |

**Stage 1 default**: every component enabled. Per-business opt-out via the settings surface (Block 02 P11). The `component_visibility` JSONB on `accountant_pack_config` carries the per-component flag; missing keys default to `true`.

**Three formats from day one** for every applicable component (PDF + CSV + XLSX) per Stage 1 decision; sub-doc owns the per-component format matrix.

### Pre-generation validation

Before composing, the pipeline calls `validate_accountant_pack_request(business, org, period_start, period_end, actor, ctx)` which checks:

1. **Permission**: actor has `REPORT_EXPORT_FULL`. Denied → `{decision:'REJECTED', reason:'PERMISSION_DENIED'}` (no audit emit here; the dispatcher's own EXPORT_REQUEST_REJECTED_PERMISSION covers it).
2. **FINALIZED check**: every OUT_MONTHLY / IN_MONTHLY workflow_run whose period falls in scope must have `status = 'FINALIZED'`. If any run is in another status → emits `ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED` and rejects. **Non-negotiable** — accountant packs against in-flight runs would surface preliminary data as final.
3. **Tamper check**: no OPEN `archive.tamper_detected` review_issue for the business → otherwise emits `ACCOUNTANT_PACK_REJECTED_TAMPER_DETECTED` and rejects.

On PASS: emits `ACCOUNTANT_PACK_GENERATION_STARTED` with the resolved `component_visibility` map and returns `{decision:'OK', period_start, period_end, component_visibility}`.

### Composition pipeline (application-layer)

After validation:

1. Resolve enabled component list from `accountant_pack_config.component_visibility` (default-all-enabled if config missing).
2. For each enabled component, invoke the P10 generator or P09 sub-dispatcher to produce bytes.
3. For evidence files, retrieve from the archive zone via B15 manifest chain (latest manifest per period).
4. Assemble a **single sealed zip** with deterministic file ordering (per B15·P05's pattern — lexicographic, mtime zeroed).
5. Compute the bundle's SHA-256 → `bundle_hash_anchor`.
6. Embed a `manifest.json` at the root listing every included component (path + hash + byte_size) + the source `archive_package_ids` the components were drawn from.
7. Persist the zip to Block 04 P05's Raw Upload zone; populate the `exports` row via `mark_accountant_pack_completed`.

**Quarterly / annual scope**: composer assembles components across multiple periods (3 for quarter, 12 for year); each component's data concatenated chronologically; manifest.json carries the full period range.

**Deterministic output**: same business + same period range + same config + same source archive state → byte-identical zip.

### Manifest.json canonical schema (v1.0)

```json
{
  "schema_version": "1.0",
  "generated_at": "2026-04-15T10:23:45Z",
  "business": { "id": "...", "name": "...", "country": "CY", "vat_number": "..." },
  "scope": { "kind": "period", "period_start": "2026-01-01", "period_end": "2026-01-31" },
  "components": [
    { "component_id": "locked_ledger_csv", "relative_path": "ledger/locked_ledger_entries.csv", "hash": "sha256:...", "byte_size": 12345 }
  ],
  "source_archive_packages": [
    { "archive_package_id": "...", "manifest_version_number": 2, "bundle_hash_anchor": "sha256:..." }
  ],
  "bundle_hash_anchor": "sha256:..."
}
```

### Manifest schema-evolution policy (additive-only in v1.0)

- **Additive changes** (new fields, new component_ids) are backward-compatible — old packs without the new field still parse; consumers ignore unknown fields.
- **Breaking changes** (rename / remove fields, reorder required fields) bump `schema_version` and require a new consumer version. Old packs continue to be readable by their original-version consumer; the `schema_version` field tells the consumer which schema to apply.
- Sub-doc tracks the per-version delta history.

### Configuration UX (cross-block contract with B02·P11)

- "Accountant pack" section in the business settings page lists every component with a checkbox.
- Checkbox toggles call `update_accountant_pack_config(business, org, component_id, enabled, actor, ctx)`.
- "Reset to default" restores all components enabled.
- **Permission gate for edits**: `BUSINESS_SETTINGS_EDIT` (Owner / Admin only). Bookkeeper / Accountant / Reviewer / Read-only can VIEW but not toggle. Audit event `ACCOUNTANT_PACK_CONFIG_UPDATED` records actor + role.
- Desktop-only per B14·P09 — mobile users see soft prompt for write actions.

---

## VIES Regulator XML

The formal Cyprus VIES return, distinct from the archive bundle's CSV.

### Source data

Locked ledger entries with `vies_relevant = true` (per B11·P06's contract). Rolled up per counterparty at export time:

```sql
SELECT counterparty_country, counterparty_vat_number,
       SUM(vies_value_basis_eur) AS total_value_eur
  FROM archive.locked_ledger_entries
 WHERE business_id = $b AND vies_relevant = true
   AND archive_package_id IN (<packages-in-scope>)
 GROUP BY counterparty_country, counterparty_vat_number;
```

### Output format

Cyprus regulator-required XML per the current Cyprus VIES specification. Stage 1 — sub-doc owns the exact XSD schema URL + per-element template; deferred Stage 2+ option of XBRL is sub-doc-tracked.

### Distinct from `vies_export.csv`

- B15·P05's archive bundle includes `vies_export.csv` for archive integrity / accountant import.
- **THIS XML is the formal regulator filing** — different format, different audience.
- Engineers must NOT reuse the CSV bytes as XML; the generator composes XML from source data per the XSD.

### Validation

Every generated XML validated against the Cyprus VIES XSD before returning. Validation failure → emits `VIES_XML_VALIDATION_FAILED` audit + the dispatcher's standard P09 FAILED status. The XSD validation is non-optional — submitting an invalid XML to the regulator is a compliance incident.

### Per-counterparty record fields

| Field | Source / rule |
|---|---|
| Counterparty country | ISO-3166 alpha-2 |
| Counterparty VAT number | format-validated per B11·P04 |
| Total value of supplies EUR | rolled up from `vies_value_basis_eur` |
| Goods vs services indicator | derived from `vat_treatment` per B11·P06 mapping rule: `IMPORT_OR_ACQUISITION` → goods; `EU_REVERSE_CHARGE` IN-side → services |

### Header / declarant fields

Business VAT number · declaration period · declaration year · contact info (sub-doc owns the exhaustive list).

### Quarterly threshold rule (deferred Stage 2+)

Some Cyprus businesses qualify for quarterly VIES instead of monthly; sub-doc tracks the eligibility logic.

---

## Three tricky rules (engineering must honor)

- **Pre-generation FINALIZED check is non-negotiable**. Accountant packs against in-flight runs would surface preliminary data as final. Reject with `ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED`. Quarterly / annual scope MUST verify every period in scope is finalized — not just the start period.
- **Manifest schema-evolution is additive-only in v1.0**. New fields / new component_ids are backward-compatible. Breaking changes (rename / remove / reorder required fields) bump `schema_version` and require a new consumer version. Don't sneak breaking changes into v1.0.
- **VIES XML is distinct from the archive CSV**. Different format, different audience (regulator vs accountant). Don't reuse the CSV bytes as XML; the generator must compose XML from the source data per the XSD. Submitting an invalid XML to the regulator is a compliance incident, not a UX bug.

---

## Audit events (10 new actions)

### ACCOUNTANT_PACK domain

- `ACCOUNTANT_PACK_CONFIG_UPDATED` — per per-business config change (with actor + role)
- `ACCOUNTANT_PACK_CONFIG_UPDATE_REJECTED` — permission denial on config edit
- `ACCOUNTANT_PACK_GENERATION_STARTED` — emitted by validate_accountant_pack_request on PASS
- `ACCOUNTANT_PACK_GENERATION_COMPLETED` — emitted by mark_accountant_pack_completed (with bundle_hash_anchor + component_count)
- `ACCOUNTANT_PACK_GENERATION_FAILED` — emitted by app-layer on composition failure
- `ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED` — pre-gen FINALIZED check rejection
- `ACCOUNTANT_PACK_REJECTED_TAMPER_DETECTED` — pre-gen tamper check rejection

### VIES domain

- `VIES_XML_GENERATION_STARTED`
- `VIES_XML_GENERATION_COMPLETED`
- `VIES_XML_GENERATION_FAILED`
- `VIES_XML_VALIDATION_FAILED` — XSD validation specifically (non-optional)

---

## Definition of Done

- `accountant_pack_config` table exists with the unique constraint on `business_id`; bootstrap loader seeds default-all-enabled config on business creation.
- A user with `REPORT_EXPORT_FULL` requests an accountant pack for a finalized period → bundle assembles → signed URL returned → download succeeds → audit events fire.
- The bundle is byte-identical across two builds with the same input (deterministic).
- Per-business config disabling `supplier_overview_csv` correctly excludes that file from the bundle.
- Quarterly scope assembles 3 periods correctly.
- Generation against a non-finalized period is rejected.
- Pre-read verification on a tampered archive blocks the pack with the right error.
- VIES XML generator produces XSD-valid output; validation failure raises the right error.
- The XML's per-counterparty totals match the source `locked_ledger_entries.vies_value_basis_eur` rollup.
- A Bookkeeper attempting `accountant_export_pack` is denied per the REPORT_EXPORT_FULL gate.
- All audit events fire with the right payloads.

---

## Sub-doc hooks (Stage 4)

- Cyprus VIES XSD schema — exact regulator schema URL + per-element template + per-period filing requirements
- Per-component format matrix — which components support PDF / CSV / XLSX from day one
- Quarterly VIES eligibility (deferred Stage 2+) — Cyprus business qualification rules
- Scheduled accountant-pack delivery (deferred Stage 2+) — cron timing, email integration, recipient management
- Multi-period concatenation — per-component concatenation rules for quarter / year scopes
- Manifest schema canonical — exact JSON schema; field-evolution policy
- Tamper-detection-during-pack-generation runbook — operator instructions when an archive in pack scope has a tamper alert
- Per-business pack-config UI — exact settings-page layout; reset-to-default UX
