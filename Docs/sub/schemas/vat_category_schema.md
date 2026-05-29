# VAT Category Schema

**Block:** Classification / Data
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `vat_categories` table is the authoritative lookup table for VAT category codes used during transaction classification and invoice generation. Each row represents a single VAT treatment (rate + type + jurisdiction) that can be assigned to a transaction, ledger line, or invoice line item.

This table is populated at deployment time via seed migrations and is updated only through schema migrations — not via application writes. No user-facing UI writes to this table. Rows are never deleted; superseded rates are deactivated via `is_active = false` and bounded with `effective_to`.

---

## DDL

```sql
CREATE TYPE vat_type_enum AS ENUM (
  'STANDARD',
  'REDUCED',
  'ZERO',
  'EXEMPT',
  'REVERSE_CHARGE',
  'INTRA_EU',
  'ACQUISITION'
);

CREATE TABLE vat_categories (
  id               UUID          NOT NULL DEFAULT gen_uuid_v7(),
  code             TEXT          NOT NULL,
  display_name     TEXT          NOT NULL,
  rate             NUMERIC(5,4)  NOT NULL,
    -- e.g. 0.1900 for 19%, 0.0900 for 9%, 0.0000 for zero-rated
  country_code     CHAR(2)       NOT NULL DEFAULT 'CY',
  vat_type         vat_type_enum NOT NULL,
  is_active        BOOLEAN       NOT NULL DEFAULT true,
  effective_from   DATE          NOT NULL,
  effective_to     DATE,
    -- NULL = currently active; set when a rate is superseded by a migration
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT vat_categories_pkey PRIMARY KEY (id),
  CONSTRAINT vat_categories_code_unique UNIQUE (code),
  CONSTRAINT vat_categories_rate_non_negative CHECK (rate >= 0),
  CONSTRAINT vat_categories_rate_max CHECK (rate <= 1.0000),
  CONSTRAINT vat_categories_effective_order
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);
```

### Column Notes

- `id` — generated via `gen_uuid_v7()`. UUID v7 provides time-ordered PKs consistent with the platform PK convention.
- `code` — machine-stable identifier used in classification rules and invoice line items. Format: `<COUNTRY>_<TYPE>_<RATE_BASIS>`. Examples: `CY_STANDARD_19`, `CY_REDUCED_9`, `CY_ZERO`, `CY_EXEMPT`. Codes are referenced by FK from `classification_rules`, `invoice_line_items`, and `vat_entries`. Codes are never reassigned to a different rate.
- `display_name` — human-readable label shown in the classification UI and on invoice PDFs. Example: `"Cyprus Standard Rate (19%)"`.
- `rate` — stored as a 4-decimal-place fraction. 19% is stored as `0.1900`. VAT calculations use HALF_UP rounding applied to this value. Never HALF_EVEN.
- `country_code` — ISO 3166-1 alpha-2. Defaults to `'CY'` for this deployment. The column exists to support multi-jurisdiction extensions without schema changes.
- `vat_type` — determines how the category is treated in VAT return assembly. REVERSE_CHARGE, INTRA_EU, and ACQUISITION categories require corresponding counterpart entries in `vat_entries`.
- `is_active` — false when the rate has been superseded. Classification rules may not reference inactive categories. The engine checks `is_active = true` before applying any VAT category.
- `effective_from` / `effective_to` — the calendar date range in which this rate is legally valid. The classification engine selects the row with `effective_from <= transaction_date AND (effective_to IS NULL OR effective_to > transaction_date)` when multiple rows share the same type and jurisdiction.

---

## Indexes

```sql
-- Primary lookup: find active categories by country
CREATE INDEX vat_categories_country_active_idx
  ON vat_categories (country_code, is_active)
  WHERE is_active = true;

-- Code lookup (classification rules, invoice line items)
CREATE INDEX vat_categories_code_idx
  ON vat_categories (code);

-- Effective date range queries
CREATE INDEX vat_categories_effective_idx
  ON vat_categories (country_code, effective_from, effective_to);
```

---

## Seed Data — Cyprus VAT Categories

The following rows are inserted via the initial seed migration. All have `country_code = 'CY'` unless otherwise noted.

| code | display_name | rate | vat_type | effective_from |
|---|---|---|---|---|
| `CY_STANDARD_19` | Cyprus Standard Rate (19%) | 0.1900 | STANDARD | 2018-01-01 |
| `CY_REDUCED_9` | Cyprus Reduced Rate (9%) | 0.0900 | REDUCED | 2012-01-01 |
| `CY_REDUCED_5` | Cyprus Reduced Rate (5%) | 0.0500 | REDUCED | 2012-01-01 |
| `CY_ZERO` | Cyprus Zero-Rated | 0.0000 | ZERO | 2004-05-01 |
| `CY_EXEMPT` | Cyprus Exempt | 0.0000 | EXEMPT | 2004-05-01 |
| `CY_REVERSE_CHARGE` | Cyprus Reverse Charge | 0.0000 | REVERSE_CHARGE | 2004-05-01 |
| `CY_INTRA_EU` | Cyprus Intra-EU Supply | 0.0000 | INTRA_EU | 2004-05-01 |
| `CY_ACQUISITION` | Cyprus EU Acquisition | 0.0000 | ACQUISITION | 2004-05-01 |

Notes on seed rows:

- `CY_EXEMPT`: applies to financial services, healthcare, education, and insurance per Cyprus VAT Law Article 26. No input VAT recovery.
- `CY_REVERSE_CHARGE`: used for services received from non-EU suppliers (Article 11B). The buyer self-accounts for VAT. The `rate` field is 0.0000 because the output tax is posted separately via the reverse charge mechanism in `vat_entries`.
- `CY_INTRA_EU`: intra-EU goods supplies at 0%. Requires valid VIES-verified recipient VAT number on the invoice. Validated via `tool_vies_validate.md`.
- `CY_ACQUISITION`: intra-EU acquisitions into Cyprus. Tax is self-accounted at the standard rate by the acquirer.

---

## Row-Level Security

```sql
ALTER TABLE vat_categories ENABLE ROW LEVEL SECURITY;

-- All authenticated users may read vat_categories (global reference data)
CREATE POLICY vat_categories_read_all
  ON vat_categories FOR SELECT
  TO authenticated
  USING (true);

-- No INSERT, UPDATE, or DELETE for the authenticated role
-- All DDL changes are made via schema migrations only
```

There is no `business_entity_id` column on this table. VAT categories are global reference data, not tenant-scoped. RLS grants read access to all authenticated users unconditionally.

---

## Usage in Classification

The classification engine references `vat_categories.code` when applying classification rules. The `classification_rules` table stores a `vat_category_code` column (TEXT, FK to `vat_categories.code`). At classification time the engine:

1. Resolves the applicable `vat_categories` row using the transaction date and `country_code`.
2. Confirms `is_active = true`.
3. Applies the `rate` to compute the VAT component using HALF_UP rounding.
4. Writes `vat_category_code` to the resulting `classification_output` record.

---

## Usage in Invoice Generation

Invoice line items reference `vat_categories.code` for display and tax computation. The invoice PDF renderer looks up `display_name` and `rate` from this table at generation time. The `rate` is stored directly on the invoice line item at write time (snapshot) so that historical invoices remain correct if the category row is later superseded.

---

## Related Documents

- `policies/vat_rate_policy.md` — VAT rate selection rules and effective-date precedence
- `policies/vat_treatment_policy.md` — Treatment rules per vat_type_enum value
- `reference/cyprus_vat_rule_catalog.md` — Full Cyprus VAT rule catalog
- `schemas/vat_entry_schema.md` — VAT entries table (references vat_category_code)
- `schemas/vat_period_schema.md` — VAT period schema
- `schemas/vat_return_schema.md` — VAT return schema
- `schemas/invoice_line_item_schema.md` — Invoice line items (stores vat_category_code snapshot)
- `schemas/classification_rule_schema.md` — Classification rules (references vat_category_code)
- `guides/cyprus_vat_compliance_guide.md` — End-to-end Cyprus VAT compliance guide
