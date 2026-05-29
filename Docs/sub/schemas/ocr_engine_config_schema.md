# OCR Engine Config Schema

**Block:** Document Intake (Block 07)
**Layer:** 2 — Sub-Doc
**Status:** Active
**Last updated:** 2026-05-17

---

## Overview

The `ocr_engine_configs` table stores per-business OCR provider configuration used by
`intake.ocr_and_extract` when processing `PDF_OCR` format bank statements. Each business
entity may have at most one active configuration row. If no row exists, the platform
defaults apply (`provider = FALLBACK_TESSERACT`, `confidence_threshold = 0.70`,
`language_hints = '{el,en}'`).

This schema is referenced by `tools/tool_intake_ocr_and_extract.md` whenever the tool
selects the OCR engine and evaluates extraction confidence against the per-business
threshold.

---

## Enum Type

```sql
CREATE TYPE ocr_provider_enum AS ENUM (
    'GOOGLE_DOCUMENT_AI',
    'AZURE_FORM_RECOGNIZER',
    'FALLBACK_TESSERACT'
);
```

### Provider Descriptions

| Value | Description |
|---|---|
| `GOOGLE_DOCUMENT_AI` | Google Cloud Document AI. Highest accuracy for structured tables. Best choice for Bank of Cyprus and Hellenic Bank modern statement PDFs. Requires a configured Google Cloud service account per the `secrets_management_policy.md`. |
| `AZURE_FORM_RECOGNIZER` | Azure Form Recognizer (now Azure AI Document Intelligence). Excellent table extraction. Preferred for AstroBank and Eurobank Cyprus statements that use strict column layouts. Requires Azure credentials in Supabase Vault. |
| `FALLBACK_TESSERACT` | Open-source Tesseract OCR. Zero marginal cost. Lowest accuracy on low-quality scans but strong support for Greek + English bilingual text. Used as the last-resort fallback engine regardless of primary selection. Always available; no external credentials required. |

---

## Table Definition

```sql
CREATE TABLE ocr_engine_configs (
    id                      UUID            NOT NULL DEFAULT gen_uuid_v7()              PRIMARY KEY,
    business_entity_id      UUID            NOT NULL REFERENCES business_entities(id)   ON DELETE CASCADE,
    provider                ocr_provider_enum NOT NULL DEFAULT 'FALLBACK_TESSERACT',
    confidence_threshold    NUMERIC(3, 2)   NOT NULL DEFAULT 0.70
                                            CHECK (confidence_threshold BETWEEN 0.00 AND 1.00),
    language_hints          TEXT[]          NOT NULL DEFAULT '{el,en}',
    model_version           TEXT,                    -- provider-specific model version pin; NULL = use provider default
    fallback_enabled        BOOLEAN         NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_ocr_engine_configs_business UNIQUE (business_entity_id)
);
```

### Column Descriptions

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | No | Primary key. Generated via `gen_uuid_v7()` for time-ordered insertion. |
| `business_entity_id` | uuid | No | FK to `business_entities(id)`. One config row per business; enforced by unique constraint. |
| `provider` | ocr_provider_enum | No | The primary OCR provider for this business. |
| `confidence_threshold` | numeric(3,2) | No | Per-business confidence threshold below which a row is flagged `needs_review = true`. Range 0.00–1.00. Default 0.70. |
| `language_hints` | text[] | No | BCP 47 language codes passed to the OCR engine. Default `'{el,en}'` for Greek + English bilingual bank statements. Override to `'{en}'` for English-only statement sources. |
| `model_version` | text | Yes | Optional model version pin (provider-specific). NULL means "use provider's current default model". Pin to a specific version when a model upgrade breaks extraction accuracy for a known statement format. |
| `fallback_enabled` | boolean | No | When `true`, the tool falls back to `FALLBACK_TESSERACT` if the primary provider fails or returns `overall_confidence < confidence_threshold / 2`. When `false`, the tool fails hard on primary engine failure. Default `true`. |
| `created_at` | timestamptz | No | Row creation timestamp. |
| `updated_at` | timestamptz | No | Last update timestamp. Updated by trigger on any column change. |

---

## Indexes

```sql
-- Primary lookup: fetch config for a given business during OCR pipeline execution
CREATE INDEX idx_ocr_engine_configs_business_entity_id
    ON ocr_engine_configs (business_entity_id);
```

The unique constraint on `business_entity_id` also creates an index, which serves the
lookup query. The explicit index above is a redundant alias for documentation clarity.

---

## Business Rules

### One Config Per Business

The `UNIQUE (business_entity_id)` constraint enforces a maximum of one OCR config row per
business. INSERT operations that would create a second row for the same business are
rejected at the database level with `unique_violation`. The application layer should use
an `INSERT ... ON CONFLICT (business_entity_id) DO UPDATE` pattern for upsert operations.

### Confidence Threshold and Fallback

When `intake.ocr_and_extract` evaluates an extracted row:

1. Per-row `confidence < confidence_threshold` → row is flagged `needs_review = true`.
2. If `overall_confidence < confidence_threshold * 0.5` AND `fallback_enabled = true` →
   the tool retries with the next engine in the fallback order.
3. If `fallback_enabled = false` → the tool returns `INTAKE_OCR_FAILED` immediately on
   primary engine failure without attempting any fallback.

Operators should set `fallback_enabled = false` only for businesses where the primary
provider is contractually required and fallback output is operationally unacceptable.

### Language Hints and Greek Bank Statements

Cyprus bank statements (Hellenic Bank, Bank of Cyprus, AstroBank, Eurobank Cyprus) are
frequently bilingual (Greek and English). The default `language_hints = '{el,en}'` ensures
the OCR engine optimises character recognition for both scripts on each page.

For businesses that exclusively upload English-only statements, setting
`language_hints = '{en}'` improves accuracy by removing the Greek recognition pass.

Greek-specific number formats (e.g., `1.234,56` = 1234.56) and date abbreviations (Ιαν,
Φεβ, etc.) are handled by `intake.parse_statement_text` independently of `language_hints`.

### Model Version Pinning

The `model_version` column allows operators to pin a specific provider model version for
a business. This is useful when a provider releases a new model that degrades extraction
accuracy for a known statement format. Pinning to the last-known-good version allows
continued processing while the extraction rules are updated.

Setting `model_version = NULL` (the default) instructs the tool to use the provider's
current default model. This is the recommended setting for most businesses.

---

## Row-Level Security

```sql
ALTER TABLE ocr_engine_configs ENABLE ROW LEVEL SECURITY;

-- Members can view their business's OCR config
CREATE POLICY ocr_engine_configs_select ON ocr_engine_configs
    FOR SELECT
    USING (
        business_entity_id = (auth.jwt() ->> 'business_id')::uuid
        AND (auth.jwt() ->> 'role') IN ('owner', 'admin', 'member')
    );

-- Only owner and admin can insert or update OCR config
CREATE POLICY ocr_engine_configs_insert ON ocr_engine_configs
    FOR INSERT
    WITH CHECK (
        business_entity_id = (auth.jwt() ->> 'business_id')::uuid
        AND (auth.jwt() ->> 'role') IN ('owner', 'admin')
    );

CREATE POLICY ocr_engine_configs_update ON ocr_engine_configs
    FOR UPDATE
    USING (
        business_entity_id = (auth.jwt() ->> 'business_id')::uuid
        AND (auth.jwt() ->> 'role') IN ('owner', 'admin')
    );

-- Hard delete not permitted; use update to change provider or disable fallback
CREATE POLICY ocr_engine_configs_no_delete ON ocr_engine_configs
    FOR DELETE
    USING (false);
```

Service-role context (used by the intake pipeline and `intake.ocr_and_extract`) bypasses
RLS to fetch config during workflow execution. This is consistent with all pipeline tool
patterns. See `policies/row_level_security_policies.md`.

---

## Audit Events

Changes to `ocr_engine_configs` rows are not individually captured in a dedicated audit
event. Provider or threshold changes are logged via the generic `WORKFLOW_TOOL_INVOKED`
event when the config update is made through a tool call. Operators who require a full
change history for OCR config should use the Supabase audit log or the table's
`updated_at` column in combination with an external change-data-capture stream.

---

## Migration Notes

The table is created in the Block 07 Phase 02 migration. The `ocr_provider_enum` type must
be created before the table. On schema rollback, drop the table before the enum type.

```sql
-- Rollback order
DROP TABLE IF EXISTS ocr_engine_configs;
DROP TYPE IF EXISTS ocr_provider_enum;
```

---

## Related Documents

- `tools/tool_intake_ocr_and_extract.md` — primary consumer of this schema
- `policies/extraction_policies.md` — extraction rules applied after OCR
- `policies/intake_size_limits_policy.md` — page count and file size limits
- `policies/row_level_security_policies.md` — RLS template and patterns
- `policies/secrets_management_policy.md` — provider credentials storage in Supabase Vault
- `reference/audit_event_taxonomy.md` — `INTAKE_OCR_COMPLETED`, `INTAKE_OCR_FAILED`
- `schemas/bank_statement_raw_schema.md` — `file_id` source table
