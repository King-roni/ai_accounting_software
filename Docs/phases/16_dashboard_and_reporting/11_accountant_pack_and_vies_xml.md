# Block 16 — Phase 11: Accountant Export Pack & VIES Regulator XML Generator

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Accountant Export Pack — configurable per business; PDF + CSV + XLSX from day one; scheduled delivery deferred)
- Decisions log: `Docs/decisions_log.md` (configurable accountant pack per business; full VIES file to current specification; scheduled delivery deferred)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (archive package source for the pack components)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 06 VIES contract — vies_relevant flag + per-counterparty rollup)
- Phase 09 (export dispatcher — registers `accountant_export_pack` and `vies_export_file`)
- Phase 10 (PDF generators — accountant-pack-component PDFs)

## Phase Goal

Build the two highest-stakes Cyprus-specific exports: the **accountant export pack** (a configurable bundle handed to a Cyprus accountant for tax filing or audit) and the **VIES regulator-filed XML file** (the formal Cyprus VIES return distinct from the CSV inside the archive bundle). Both are gated by `REPORT_EXPORT_FULL`, both audit-logged, both deterministic, both compliant with current Cyprus regulator specifications. After this phase, the platform produces the export an accountant or auditor would request first.

## Dependencies

- Phase 09 (export dispatcher; `exports` table; permission gates)
- Phase 10 (per-component PDF generators)
- Block 04 Phase 07 (Finalized Archive zone — pack composition reads from here)
- Block 11 Phase 06 (VIES contract — `vies_relevant` flag + per-counterparty rollup; canonical 8-treatment enum source)
- Block 15 Phase 05 / 06 (archive bundle structure; manifest chain)
- Block 02 Phase 04 (`REPORT_EXPORT_FULL` and `BUSINESS_SETTINGS_EDIT` permission surfaces — per the 2026-05-09 decisions-log amendment)
- Block 02 Phase 11 (settings UI surface — desktop-only constraint inherited)
- Block 02 Phase 06 (step-up auth — sub-doc tracks per-business policy)

## Deliverables

- **Accountant pack composition (per-business configurable; Stage 1 decision):**
  - **`accountant_pack_config` table** — per-business component-selection config:
    - `id` (UUID v7), `organization_id`, `business_id`
    - `component_visibility` (JSONB; map of `component_id → boolean`; missing keys default to true). Components match the architecture-doc list:
      - `period_bounds`, `business_identification`
      - `locked_ledger_csv`, `locked_ledger_xlsx`, `locked_ledger_pdf`
      - `vat_summary_pdf`, `vat_summary_xlsx`, `vies_export_xml`
      - `evidence_index_csv`
      - `evidence_files_directory`
      - `reconciled_invoice_list_csv`, `reconciled_invoice_list_pdf`
      - `adjustment_records_csv`, `adjustment_records_pdf`
      - `finalization_approval_record_pdf`
      - `signed_manifest_pdf`
      - `supplier_overview_csv` (architecture lists this as opt-out-friendly)
      - `period_report_pdf` (Block 15 Phase 05's canonical PDF)
    - `created_at`, `updated_at`, `last_updated_by`
    - **Unique constraint:** `(business_id)` — one config per business.
    - Stage 1 default: every component enabled. Per-business opt-out via the settings surface (Block 02 Phase 11).
  - **Configuration is preserved across periods** so exports are consistent (the Stage 1 architecture commitment).
  - **Three formats from day one** for every applicable component (PDF + CSV + XLSX) per the Stage 1 decision; sub-doc owns the per-component format matrix.

- **Accountant pack composition pipeline** — `accountant_pack.generate({ business_id, period_start, period_end, scope: 'period' | 'quarter' | 'year' }) → { export_id, signed_url? }`:
  - Invoked by Phase 09's dispatcher when `export_kind = accountant_export_pack`.
  - **Permission gate:** `REPORT_EXPORT_FULL` (Owner / Admin / Accountant).
  - **Composition logic:**
    1. Read `accountant_pack_config` for the business → resolved component list.
    2. For each enabled component, invoke the relevant Phase 10 generator (or Phase 09 sub-dispatcher for CSV/XLSX components) to produce its bytes.
    3. For evidence files, retrieve from the archive zone via Block 15's manifest chain (latest manifest per period).
    4. Assemble a **single sealed zip** with deterministic file ordering (per Block 15 Phase 05's pattern — lexicographic, mtime zeroed).
    5. Compute the bundle's SHA-256 → `bundle_hash_anchor`.
    6. Embed a `manifest.json` at the root listing every included component with its file path + hash + byte size + the source archive_package_ids the components were drawn from.
    7. Persist the zip to Block 04 Phase 05's Raw Upload zone; populate the `exports` row.
  - **Quarterly / annual scope:** the composer assembles components across multiple periods (3 for quarter, 12 for year); each component's data is concatenated chronologically; the `manifest.json` carries the full period range.
  - **Deterministic output:** same business + same period range + same config + same source archive state → byte-identical zip (verified by Phase 13's fixture).

- **Accountant pack `manifest.json` structure** (canonical):
  ```json
  {
    "schema_version": "1.0",
    "generated_at": "2026-04-15T10:23:45Z",
    "business": { "id": "...", "name": "...", "country": "CY", "vat_number": "..." },
    "scope": { "kind": "period", "period_start": "2026-01-01", "period_end": "2026-01-31" },
    "components": [
      { "component_id": "locked_ledger_csv", "relative_path": "ledger/locked_ledger_entries.csv", "hash": "sha256:...", "byte_size": 12345 },
      ...
    ],
    "source_archive_packages": [
      { "archive_package_id": "...", "manifest_version_number": 2, "bundle_hash_anchor": "sha256:..." }
    ],
    "bundle_hash_anchor": "sha256:..."
  }
  ```
- **Manifest schema-evolution policy** (additive only in MVP; mirrors Block 15 Phase 06's manifest-versioning pattern):
  - **Additive changes** (new fields, new component_ids) are backward-compatible — old packs without the new field still parse; consumers ignore unknown fields.
  - **Breaking changes** (rename / remove fields, reorder required fields) bump `schema_version` and require a new consumer version. Old packs continue to be readable by their original-version consumer; the `schema_version` field tells the consumer which schema to apply.
  - Sub-doc tracks the per-version delta history. Stage 1 ships `schema_version: 1.0` with the structure above.

- **VIES regulator XML generator** — `vies.generateXml({ business_id, period_start, period_end }) → { xml_bytes, file_hash, byte_size }`:
  - Invoked by Phase 09's dispatcher when `export_kind = vies_export_file`.
  - **Permission gate:** `REPORT_EXPORT_FULL`.
  - **Source data:** locked ledger entries with `vies_relevant = true` (Block 11 Phase 06's contract); per-counterparty rollup at export time (sum `vies_value_basis_eur` per `(counterparty_country, counterparty_vat_number)`).
  - **Output format:** Cyprus regulator-required XML per the current Cyprus VIES specification. Stage 1 — sub-doc owns the exact XSD schema URL + per-element template; the deferred Stage 2+ option of XBRL is sub-doc-tracked.
  - **Distinct from the bundle's CSV:** Block 15 Phase 05's archive bundle includes `vies_export.csv` for archive integrity / accountant import. THIS XML is the formal regulator filing — different format, different audience. Per the 2026-05-08 decisions-log amendment.
  - **Validation:** the generator validates the produced XML against the Cyprus VIES XSD before returning; validation failure → standard exception → Phase 09's failure-mode taxonomy (TRANSIENT for transient validation errors; DETERMINISTIC for source-data errors that need user resolution).
  - **Per-counterparty record format** (canonical fields per Cyprus VIES; sub-doc owns the exact element names):
    - Counterparty country (ISO-3166 alpha-2)
    - Counterparty VAT number (format-validated per Block 11 Phase 04)
    - Total value of supplies in EUR (rolled up from `vies_value_basis_eur`)
    - Goods vs services indicator (derived from `vat_treatment` per Block 11 Phase 06's mapping rule — `IMPORT_OR_ACQUISITION` → goods; `EU_REVERSE_CHARGE` IN-side → services)
  - **Header / declarant fields:** business VAT number, declaration period, declaration year, contact info (sub-doc owns the exhaustive list).
  - **Quarterly threshold rule** (deferred Stage 2+): some Cyprus businesses qualify for quarterly VIES instead of monthly; sub-doc tracks the eligibility logic.

- **Configuration UX (cross-block contract with Block 02 Phase 11 settings surface):**
  - A "Accountant pack" section in the business settings page lists every component with a checkbox.
  - Checkbox toggles update `accountant_pack_config.component_visibility`.
  - "Reset to default" button restores all components enabled.
  - **Permission gate for edits:** `BUSINESS_SETTINGS_EDIT` (Owner / Admin only per the 2026-05-09 decisions-log amendment). Bookkeeper / Accountant / Reviewer / Read-only can VIEW the configuration (settings page is generally accessible) but cannot toggle. Audit-event `ACCOUNTANT_PACK_CONFIG_UPDATED` records the actor + role.
  - Desktop-only per Block 14 Phase 09 — mobile users see a soft prompt for write actions.

- **Scheduled delivery deferred** (per Stage 1):
  - In MVP, the user generates and downloads packs on demand via Phase 09's dispatcher.
  - Sub-doc tracks the Stage 2+ scheduled-delivery feature (cron-driven monthly auto-generation + email to a configured accountant address).

- **Pre-generation validation:**
  - Before generating, the composer verifies the period(s) are FINALIZED — accountant packs are NEVER generated against in-flight runs (would surface preliminary data as final). Non-finalized period rejection → `ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED`.
  - Pre-read verification (Block 15 Phase 07's Layer 3) fires on every archive read; tamper detection blocks the pack with `ACCOUNTANT_PACK_REJECTED_TAMPER_DETECTED` BLOCKING issue.

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `ACCOUNTANT_PACK` and `VIES`):
  - `ACCOUNTANT_PACK_CONFIG_UPDATED` (per per-business config change)
  - `ACCOUNTANT_PACK_GENERATION_STARTED`
  - `ACCOUNTANT_PACK_GENERATION_COMPLETED` (with bundle_hash_anchor and component count)
  - `ACCOUNTANT_PACK_GENERATION_FAILED`
  - `ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED`
  - `ACCOUNTANT_PACK_REJECTED_TAMPER_DETECTED`
  - `VIES_XML_GENERATION_STARTED`
  - `VIES_XML_GENERATION_COMPLETED`
  - `VIES_XML_GENERATION_FAILED`
  - `VIES_XML_VALIDATION_FAILED` (XSD validation specifically)

## Definition of Done

- `accountant_pack_config` table exists with the unique constraint; bootstrap loader seeds the default-all-enabled config on business creation.
- A user with `REPORT_EXPORT_FULL` requests an accountant pack for a finalized period → bundle assembles → signed URL returned → download succeeds → audit events fire.
- The bundle is byte-identical across two builds with the same input (deterministic).
- Per-business config disabling `supplier_overview_csv` correctly excludes that file from the bundle.
- Quarterly scope assembles 3 periods correctly.
- Generation against a non-finalized period is rejected.
- Pre-read verification on a tampered archive blocks the pack with the right error.
- VIES XML generator produces XSD-valid output; validation failure raises the right error.
- The XML's per-counterparty totals match the source `locked_ledger_entries.vies_value_basis_eur` rollup.
- A Bookkeeper attempting `accountant_pack` is denied per the `REPORT_EXPORT_FULL` gate.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Cyprus VIES XSD schema sub-doc** — exact regulator schema URL + per-element template + per-period filing requirements.
- **Per-component format matrix sub-doc** — which components support PDF / CSV / XLSX from day one.
- **Quarterly VIES eligibility sub-doc (deferred Stage 2+)** — Cyprus business qualification rules.
- **Scheduled accountant-pack delivery sub-doc (deferred Stage 2+)** — cron timing, email integration, recipient management.
- **Multi-period concatenation sub-doc** — per-component concatenation rules for quarter / year scopes.
- **Manifest schema canonical sub-doc** — exact JSON schema; field-evolution policy.
- **Tamper-detection-during-pack-generation runbook sub-doc** — operator instructions when an archive in the pack scope has a tamper alert.
- **Per-business pack-config UI sub-doc** — exact settings-page layout; reset-to-default UX.
