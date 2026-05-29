# Export Definitions Catalog

**Category:** Reference data · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 16, Phases 04–06 (export pipeline, accountant pack, signed URL delivery).

**Purpose:** The single source of truth for all 13 export formats available in the system. Every UI component that presents format options, every tool that generates an export, and every schema that references format identifiers binds to this catalog. Adding a new format requires an amendment to this file and a corresponding tool registration.

---

## Format catalog

The table below is the canonical definition. Fields are explained in the section following the table.

| `format_id` | Display name | Category | `mime_type` | Extension | Scope | TTL | `tool_name` | `min_role` |
|---|---|---|---|---|---|---|---|---|
| `ledger_csv` | Ledger Entries (CSV) | Accounting | `text/csv` | `.csv` | Per-period ledger entries | 24h | `report.export_ledger` | ACCOUNTANT |
| `vat_return_xml` | VAT Return (XML) | Tax | `application/xml` | `.xml` | Per-period VAT summary | 24h | `report.export_vat_return` | ACCOUNTANT |
| `invoice_list_csv` | Invoice List (CSV) | Accounting | `text/csv` | `.csv` | Per-period invoices | 24h | `report.export_invoice_list` | ACCOUNTANT |
| `transaction_list_csv` | Transaction List (CSV) | Accounting | `text/csv` | `.csv` | Per-period transactions | 24h | `report.export_transaction_list` | ACCOUNTANT |
| `audit_log_csv` | Audit Log (CSV) | Compliance | `text/csv` | `.csv` | Per-period audit events | 24h | `report.export_audit_log` | ADMIN |
| `archive_bundle_zip` | Archive Bundle (ZIP) | Archive | `application/zip` | `.zip` | Per-run sealed archive | Permanent (Object Lock) | `archive.download_bundle` | OWNER |
| `bank_statement_csv` | Bank Statement (CSV) | Bank | `text/csv` | `.csv` | Per-period bank rows | 24h | `report.export_bank_statement` | ACCOUNTANT |
| `income_summary_pdf` | Income Summary (PDF) | Accounting | `application/pdf` | `.pdf` | Per-period income | 24h | `report.generate_period_report` | ACCOUNTANT |
| `expense_summary_pdf` | Expense Summary (PDF) | Accounting | `application/pdf` | `.pdf` | Per-period expenses | 24h | `report.generate_period_report` | ACCOUNTANT |
| `vies_submission_csv` | VIES Submission (CSV) | Tax | `text/csv` | `.csv` | Per-period intra-EU transactions | 24h | `report.export_vies_submission` | ACCOUNTANT |
| `match_report_csv` | Match Report (CSV) | Accounting | `text/csv` | `.csv` | Per-period match records | 24h | `report.export_match_report` | ACCOUNTANT |
| `accountant_pack_zip` | Accountant Pack (ZIP) | Archive | `application/zip` | `.zip` | Configurable multi-format bundle | 24h | `report.generate_accountant_pack` | ACCOUNTANT |
| `custom_report_pdf` | Custom Report (PDF) | Accounting | `application/pdf` | `.pdf` | User-configured period report | 24h | `report.generate_custom_report` | ACCOUNTANT |

---

## Field definitions

**`format_id`** — snake_case identifier. Used as the value in `report_jobs.report_type`, `accountant_pack_config.included_formats[]`, and any API parameter that selects a format. Case-sensitive; must match exactly.

**Display name** — the string shown in the export dialog and accountant pack configuration UI. Must not be changed without a corresponding UI update. Translations are handled by the i18n layer; this catalog stores the English canonical form.

**Category** — used for grouping in the export dialog UI. Four categories: Accounting, Tax, Bank, Archive, Compliance. See `export_pipeline_ui_spec.md` for the display order within each category.

**`mime_type`** — the `Content-Type` header value sent with the file. Also used for the `accountant_pack_zip` inner file entries. Must match the actual generated content — a mismatch will cause browser download failures for strict `Content-Sniffing` policies.

**Extension** — appended to the generated filename. The filename pattern is `<business_slug>_<period_start>_<format_id>.<extension>` (e.g., `acme_ltd_2026-01_ledger_csv.csv`).

**Scope** — what data the export covers. All per-period formats use the `period_start` / `period_end` from the originating `workflow_run`. The scope is not configurable by the user at export time (the period is fixed once selected or derived from context).

**TTL** — how long the exported file is retained in the Export temp data zone per `data_retention_policy.md`. All formats use 24h except `archive_bundle_zip`, which uses permanent retention via Object Lock (see note below). The 24h TTL begins at `report_jobs.completed_at`, not at download time.

**`tool_name`** — the registered tool that generates the export. All tool names follow the `<namespace>.<action>` convention per `tool_naming_convention_policy.md`. The `report` namespace owns all export tools except `archive.download_bundle`.

**`min_role`** — the minimum role required to trigger this export. Enforced by `auth.can_perform` at the tool invocation layer, not only in the UI. Roles in ascending order: READ_ONLY < REVIEWER < ACCOUNTANT < BOOKKEEPER < ADMIN < OWNER. A user with `min_role = ACCOUNTANT` can trigger the export if their role is ACCOUNTANT, BOOKKEEPER, ADMIN, or OWNER.

---

## Notes on specific formats

### `archive_bundle_zip` — permanent retention

This is the only format with permanent retention. The archive bundle is stored in the Archive data zone with Object Lock (COMPLIANCE mode) and is never subject to the 24-hour Export temp TTL.

The signed URL used to download the bundle still has a 24-hour TTL — the signed URL is a temporary access credential, not the object itself. The object persists permanently in Object-Locked storage regardless of whether the signed URL is used.

The `archive.download_bundle` tool generates a signed URL for the existing locked object; it does NOT re-generate the bundle. Calling `archive.download_bundle` for an `archive_bundle_id` that does not have `lock_status = 'LOCKED'` returns an error.

### `income_summary_pdf` and `expense_summary_pdf` — shared tool

Both PDF summary formats are generated by the same tool (`report.generate_period_report`) with a `report_variant` parameter (`INCOME` or `EXPENSE`). This is not visible to the user — from the UI's perspective, they are two distinct selectable formats. The `format_id` is what distinguishes them in `report_jobs.report_type`.

### `accountant_pack_zip` — container format

The accountant pack ZIP is a container format: it is not a raw data export but a ZIP archive containing one or more of the other formats, as configured in `accountant_pack_config.included_formats`. When a user selects `accountant_pack_zip` from the export dialog, the system generates a pack using the current `accountant_pack_config` for the business. If no pack configuration exists, the export button is disabled with tooltip: "Configure accountant pack settings first."

The `accountant_pack_zip` format has a 24-hour TTL. If `archive_bundle_zip` is included as one of the inner formats within the pack, the inner `archive_bundle_zip` object retains its permanent Object Lock — but the outer pack ZIP and its signed URL expire after 24 hours.

### `vat_return_xml` — Cyprus-specific schema

The VAT return XML follows the Cyprus Tax Department's prescribed XML schema for VAT returns. The file is not a standard EU VAT XML; it is Cyprus-specific. The schema version is managed by `report_template_policy.md`. If the Cyprus Tax Department updates the schema, the tool must be updated and a schema version bump recorded.

### `vies_submission_csv` — EU-eligible transactions only

The VIES submission CSV is only generated for periods containing EU reverse charge or intra-EU B2B transactions. If the period contains no eligible transactions, the tool returns an empty file (headers only) with a warning. The UI shows a tooltip on the format when the period has no VIES-eligible data: "No intra-EU transactions in this period."

### `audit_log_csv` — ADMIN minimum role

The audit log export requires ADMIN role because the audit log contains actor emails, IP addresses, and system-level security events. The export is subject to a 30-day time-range limit per `audit_log_policies.md` Section 3. Requests spanning more than 30 days are rejected at the tool layer with a structured error.

---

## Role hierarchy for access control

The `min_role` column uses the platform's ordered role hierarchy. For export access, roles rank as:

`READ_ONLY` < `REVIEWER` < `ACCOUNTANT` < `BOOKKEEPER` < `ADMIN` < `OWNER`

A user with a role at or above `min_role` may trigger the export. The check is enforced at two layers:

1. **UI layer:** Formats below the user's role are greyed out and unselectable in the export dialog (see `export_pipeline_ui_spec.md`).
2. **Tool layer:** `auth.can_perform` checks the role against the tool's `min_role` requirement before invocation. A mismatch returns `ACCESS_DENIED` with audit event `AUTH_PERMISSION_DENIED`.

The two-layer enforcement means that UI role-gating alone is not the security boundary. Bypassing the UI (e.g., a direct API call) will still be rejected at the tool layer.

**Role-to-format summary:**

| Role | Accessible formats |
|---|---|
| ACCOUNTANT | All formats except `audit_log_csv` and `archive_bundle_zip` |
| BOOKKEEPER | Same as ACCOUNTANT (BOOKKEEPER ≥ ACCOUNTANT in hierarchy) |
| ADMIN | All formats except `archive_bundle_zip` |
| OWNER | All 13 formats |

REVIEWER and READ_ONLY roles have no export access. None of the 13 formats has `min_role` below ACCOUNTANT.

---

## Async vs synchronous routing by format

The export pipeline routes each format request through a size estimate before dispatch. The per-format typical path is:

| Format | Typical path | Notes |
|---|---|---|
| `ledger_csv` | Synchronous (< 500 rows most periods) | Async if period exceeds 500 ledger entries |
| `transaction_list_csv` | Synchronous | |
| `bank_statement_csv` | Synchronous | |
| `invoice_list_csv` | Synchronous | |
| `match_report_csv` | Synchronous | |
| `vies_submission_csv` | Synchronous | Empty file if no eligible transactions |
| `audit_log_csv` | Async | Audit log rows are high-volume; always async |
| `vat_return_xml` | Synchronous | XML generation is fast; schema is compact |
| `income_summary_pdf` | Async | PDF render overhead |
| `expense_summary_pdf` | Async | PDF render overhead |
| `custom_report_pdf` | Async | User-configured layout; render time varies |
| `accountant_pack_zip` | Always async | Multi-format assembly |
| `archive_bundle_zip` | Always async | Bundle may be very large |

The threshold is 2 seconds estimated duration, evaluated per `report.estimate_export_size`. The typical-path designations above are guidance; a large-period `ledger_csv` will route async if the estimate crosses the threshold.

---

## Adding a new format

To add a new export format:

1. Assign a `format_id` following the `<data_type>_<format_extension>` pattern.
2. Register the generating tool following `tool_naming_convention_policy.md`.
3. Add the tool to the audit event taxonomy (`EXPORT_REQUESTED` payload must include `format_id`).
4. Add the format to this catalog with all 8 fields populated.
5. Add a `decisions_log.md` entry documenting the addition rationale.

The 13-format count is not a hard limit; the accountant pack's 6-format-per-pack limit is a separate constraint that applies only to pack configuration.

---

## Cross-references

- `export_pipeline_ui_spec.md` — export dialog format picker, async/sync threshold, signed URL delivery
- `accountant_pack_config_schema.md` — `included_formats` field, pack configuration structure
- `data_retention_policy.md` — Export temp zone (24h TTL), Archive zone (permanent Object Lock)
- `report_template_policy.md` — PDF rendering templates, `vat_return_xml` schema version management
- `tool_naming_convention_policy.md` — `report` and `archive` namespace tool naming constraints
- `audit_event_taxonomy.md` — `EXPORT_REQUESTED`, `EXPORT_COMPLETED`, `EXPORT_FAILED`, `EXPORT_DELIVERED_SIGNED_URL`
