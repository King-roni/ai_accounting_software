# Block 09 — Phase 01: Schema for Documents & Source Mappings

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md`
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 03 — `documents` table already provisioned)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 08 — `drive_folder_mappings` already provisioned)

## Phase Goal

Lay down the additional tables Block 09 needs beyond what Blocks 04 and 02 already provided: query-template definitions for the email finder, the per-business sender allowlist, extraction-results history per document, and the cross-source link records that let Phase 08 detect the same document arriving via multiple paths. After this phase, the schema is in place; subsequent phases populate and read it.

## Dependencies

- Block 02 Phase 01 (tenancy schema)
- Block 02 Phase 05 (RLS template)
- Block 02 Phase 08 (`drive_folder_mappings` already exists; this phase doesn't redefine it)
- Block 04 Phase 03 (`documents` table; this phase doesn't redefine it)

## Deliverables

- **`gmail_search_query_templates` table:**
  - `id` (UUID v7), `organization_id`, `business_id` (nullable for global default templates)
  - `template_name` (e.g., `invoice_by_amount_and_supplier`, `receipt_by_merchant_and_date`)
  - `pattern_jsonb` — the parameterised Gmail query template (e.g., `{ has: "attachment", from: "{supplier_domain}", subject_contains: "invoice", date_window_days: 7 }`)
  - `enabled`, `priority`, `created_at`, `updated_at`, `created_by`
- **`business_sender_allowlist` table:**
  - `id` (UUID v7), `organization_id`, `business_id`
  - `entry_kind` (`EMAIL_DOMAIN`, `EMAIL_ADDRESS`)
  - `value` (the domain or full address — case-insensitive match)
  - `notes` (free text, e.g., "Google billing, primary supplier")
  - `added_by`, `added_at`
  - Unique on `(business_id, entry_kind, lower(value))`.
- **`document_extraction_results` table:**
  - `id` (UUID v7), `document_id`, `extraction_layer` (`DETERMINISTIC`, `TIER2_AI`, `TIER3_AI`)
  - `extracted_fields` (JSONB — typed extracted-field map)
  - `confidence_per_field` (JSONB — float per field name)
  - `started_at`, `completed_at`, `prompt_version` (nullable for `DETERMINISTIC`)
  - `succeeded` (boolean), `error_summary` (nullable)
  - One document can have multiple rows (one per layer attempted) — preserves the extraction history for audit and recalibration.
- **`document_source_links` table:**
  - `id` (UUID v7), `organization_id`, `business_id`, `document_id`
  - `source_kind` (`EMAIL`, `DRIVE`, `MANUAL`, `INVOICE_GENERATOR`)
  - `source_external_id` (Gmail message id, Drive file id, manual upload id, generated invoice id)
  - `discovered_at`, `discovery_reason` (which Phase 05 query yielded this; or `manual_upload`, etc.)
  - Multiple rows allowed per document — Phase 08 records every source the same hash arrived via.
  - Unique on `(business_id, source_kind, source_external_id)` to prevent re-recording the same source twice.
- **RLS** on every new table per the Block 02 Phase 05 standard template.
- **Indexes:**
  - `gmail_search_query_templates(business_id, enabled, priority)`
  - `business_sender_allowlist(business_id, lower(value))`
  - `document_extraction_results(document_id, extraction_layer)`
  - `document_source_links(business_id, document_id)` — primary lookup for source provenance
  - `document_source_links(source_kind, source_external_id)` — quick check for whether a Gmail/Drive id has already been seen

## Definition of Done

- All four new tables exist with their columns, FKs, and constraints.
- RLS prevents cross-tenant reads/writes; the global-template exception (where `business_id IS NULL`) is verified.
- A test inserts a Gmail query template, an allowlist entry, an extraction result row per layer for one document, and source links from two sources for the same document hash; the round-trip reads correctly.
- Constraint enforcement for sender-allowlist uniqueness (case-insensitive) is verified.

## Sub-doc Hooks (Stage 4)

- **Gmail query template JSONB schema sub-doc** — exact parameter set, tokenisation, validation rules, evolution policy.
- **Sender allowlist matching sub-doc** — exact case-folding, domain-vs-address precedence, subdomain handling.
- **Extraction-results history sub-doc** — retention rules, what layers retain on success vs failure, recalibration use.
- **Source-link provenance sub-doc** — what counts as "the same document arriving via two sources"; how it differs from a true duplicate upload.
