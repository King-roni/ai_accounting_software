# Business Settings Schema

**Block:** 02 — Tenancy, Auth & Org Management  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines the `business_settings` table, which stores per-business configuration values that control intake limits, classification thresholds, invoice defaults, and VAT treatment. Each business has exactly one settings row (enforced via a UNIQUE constraint on `business_id`). Settings rows are created automatically when a business entity is provisioned.

---

## 1. Table Definition

```sql
CREATE TABLE business_settings (
    id                                  UUID            PRIMARY KEY DEFAULT gen_uuid_v7(),

    business_id                         UUID            NOT NULL UNIQUE
                                                        REFERENCES business_entities(id)
                                                        ON DELETE CASCADE,
    -- UNIQUE ensures one settings row per business.
    -- CASCADE: if the business entity is deleted, its settings row is deleted.

    -- VAT configuration
    vat_registration_number             TEXT,
    -- Cyprus format: 'CY' + 8 digits + 1 uppercase letter (e.g., CY12345678A).
    -- NULL for businesses that are not VAT-registered.
    -- Validated by application layer; see Section 3.

    vat_scheme                          TEXT            NOT NULL DEFAULT 'STANDARD'
                                                        CHECK (vat_scheme IN (
                                                            'STANDARD',
                                                            'FLAT_RATE',
                                                            'EXEMPT'
                                                        )),
    -- STANDARD: standard method VAT accounting.
    -- FLAT_RATE: flat rate scheme (Cyprus Flat Rate).
    -- EXEMPT: business is below registration threshold or otherwise exempt.

    -- Currency and fiscal year
    default_currency                    CHAR(3)         NOT NULL DEFAULT 'EUR',
    -- ISO 4217 code. EUR is the primary currency for Cyprus.
    -- Must be a value in currency_code_enum or 'RUB' (handled as TEXT; see currency_enum.md).

    fiscal_year_start_month             INT             NOT NULL DEFAULT 1
                                                        CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
    -- The month (1–12) in which the fiscal year begins.
    -- Default 1 = January. Cyprus standard is January; some businesses use April.

    -- Approval thresholds
    auto_approve_threshold              DECIMAL(15,2),
    -- If set, workflow runs with a total absolute value (sum of |transaction amounts|)
    -- below this threshold are automatically approved without human review.
    -- NULL means all runs require explicit approval regardless of size.
    -- Expressed in default_currency.

    -- Intake configuration
    max_intake_file_mb                  INT             NOT NULL DEFAULT 25
                                                        CHECK (max_intake_file_mb BETWEEN 1 AND 200),
    -- Maximum file size accepted by the intake pipeline for this business.
    -- Overrides the platform-wide default when set lower.
    -- The platform maximum is 200 MB regardless of this setting.
    -- Referenced by tool_intake_parse when validating uploaded file sizes.

    -- Classification configuration
    classification_confidence_threshold DECIMAL(4,3)    NOT NULL DEFAULT 0.850
                                                        CHECK (
                                                            classification_confidence_threshold >= 0.500
                                                        AND classification_confidence_threshold <= 1.000
                                                        ),
    -- Minimum confidence score required for an AI classification result to be
    -- accepted without routing to REVIEW_HOLD.
    -- Range: 0.500–1.000. Default 0.850.
    -- Results below this threshold receive match_level = WEAK_POSSIBLE or NO_MATCH
    -- and are routed to the review queue per matching_policy.md.
    -- Referenced by the classification engine at classification output validation time.

    -- Invoice configuration
    invoice_due_days                    INT             NOT NULL DEFAULT 30
                                                        CHECK (invoice_due_days BETWEEN 0 AND 365),
    -- Number of days from invoice date to due date.
    -- Used as the default when creating new invoices via tool_invoice_create.
    -- 0 = due immediately (pro-forma or prepayment scenarios).

    reminder_days_before_due            INT[]           NOT NULL DEFAULT '{7, 3, 1}',
    -- Array of day offsets before the due date at which payment reminder emails
    -- are dispatched. Empty array = no automatic reminders.
    -- Example: {7, 3, 1} sends reminders 7 days, 3 days, and 1 day before due date.
    -- Values must be positive integers. Duplicates are removed on write.

    -- Metadata
    created_at                          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at                          TIMESTAMPTZ     NOT NULL DEFAULT now()
);
```

---

## 2. Indexes

```sql
-- Primary lookup path: business settings retrieval by business_id
-- The UNIQUE constraint on business_id creates an implicit index; this explicit
-- index includes updated_at for cache-invalidation queries.
CREATE INDEX idx_business_settings_business_id
    ON business_settings (business_id);

-- VAT number lookup for duplicate detection across businesses
CREATE INDEX idx_business_settings_vat_number
    ON business_settings (vat_registration_number)
    WHERE vat_registration_number IS NOT NULL;
```

---

## 3. Validation Rules

### 3.1 VAT Registration Number Format (Cyprus)

Cyprus VAT registration numbers follow the format:

```
CY + 8 digits + 1 uppercase letter
```

Examples: `CY12345678A`, `CY00012345Z`.

Application-layer validation regex:

```
^CY\d{8}[A-Z]$
```

The application layer validates this format before inserting or updating `vat_registration_number`. The database does not enforce this constraint via a CHECK clause to allow for future format changes without a migration.

For businesses registered in other EU member states (e.g., a Cyprus-registered holding with a UK establishment), non-Cyprus VAT numbers may be stored in an extended `counterparty_vat_numbers` structure rather than in this field.

### 3.2 `reminder_days_before_due` Array Constraint

The application layer enforces:
- All values must be positive integers (> 0).
- No duplicates.
- Maximum 10 entries.
- Values are sorted descending before storage.

The database enforces none of these constraints directly; they are enforced at the API layer before write.

### 3.3 `default_currency` Validation

The `default_currency` value must be a valid ISO 4217 code supported by the platform. Supported codes are defined in `currency_enum.md`. The application layer validates this at write time. The database column is `CHAR(3)` to enforce the three-character length constraint only.

### 3.4 `auto_approve_threshold`

The `auto_approve_threshold` is expressed in `default_currency`. If `default_currency` is changed after `auto_approve_threshold` is set, the threshold value is not automatically converted. The DPO or admin must review the threshold after a currency change.

---

## 4. Row-Level Security

```sql
ALTER TABLE business_settings ENABLE ROW LEVEL SECURITY;

-- All business members can read settings
CREATE POLICY business_settings_select
    ON business_settings FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM org_members
            WHERE user_id     = auth.uid()
              AND business_id = business_settings.business_id
        )
    );

-- Only OWNER or ADMIN can update settings
CREATE POLICY business_settings_update
    ON business_settings FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM org_members
            WHERE user_id     = auth.uid()
              AND business_id = business_settings.business_id
              AND role        IN ('OWNER', 'ADMIN')
        )
    );

-- Insert is performed by the platform provisioning service (service role)
-- when a new business entity is created. Not directly accessible by users.
CREATE POLICY business_settings_insert_service
    ON business_settings FOR INSERT
    WITH CHECK (false);
-- Service role bypasses RLS; this policy prevents API-level inserts.
```

---

## 5. Provisioning

A `business_settings` row is created automatically by the business provisioning trigger when a new `business_entities` row is inserted. The trigger uses the platform defaults defined in Section 1.

```sql
CREATE OR REPLACE FUNCTION fn_provision_business_settings()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO business_settings (business_id)
    VALUES (NEW.id)
    ON CONFLICT (business_id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_provision_business_settings
    AFTER INSERT ON business_entities
    FOR EACH ROW EXECUTE FUNCTION fn_provision_business_settings();
```

---

## 6. Audit Events

Settings changes are audited using the `BUSINESS_UPDATED` event defined in `audit_event_taxonomy.md`. This event is emitted by the update handler with a field diff payload identifying which settings fields changed and their old and new values.

| Event | Severity | Trigger |
|-------|----------|---------|
| `BUSINESS_UPDATED` | LOW | Emitted whenever a `business_settings` row is updated. Payload includes `business_id`, `updated_by_user_id`, and a `changed_fields` object with before/after values for each modified column. Sensitive values (e.g., `vat_registration_number`) are included in the diff; they are not considered secret. |

The `updated_at` column is updated automatically on each write via a trigger:

```sql
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_business_settings_updated_at
    BEFORE UPDATE ON business_settings
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
```

---

## 7. Integration Points

### 7.1 `tool_intake_parse`

The `max_intake_file_mb` setting is read by `tool_intake_parse` at the start of each intake operation. If the uploaded file exceeds this value, the intake is rejected with error code `INTAKE_FILE_TOO_LARGE`. This setting cannot be set higher than the platform limit of 200 MB.

### 7.2 Classification Engine

The `classification_confidence_threshold` is read by the classification engine after each AI classification result is produced. Results with a confidence score below the threshold are treated as `WEAK_POSSIBLE` and routed to the review queue. This threshold allows businesses with high-quality chart-of-accounts mappings to raise the bar for auto-classification, while new businesses can lower it to reduce false review-queue noise during initial setup.

### 7.3 Invoice Generator

The `invoice_due_days` and `reminder_days_before_due` settings are used by `tool_invoice_create` as defaults when `due_date` or `reminder_schedule` is not explicitly specified in the invocation payload. Explicit values in the invocation payload override these defaults.

### 7.4 Approval Workflow

The `auto_approve_threshold` is evaluated by `engine.gate_approval` at the `AWAITING_APPROVAL` gate. If the run's total absolute transaction value is below the threshold, the gate passes without requiring a human approval action.

---

## 8. Migration Notes

The `reminder_days_before_due` column uses PostgreSQL array syntax. When modifying this column in migrations, use `array_agg` functions rather than direct literal syntax to avoid compatibility issues across PostgreSQL versions.

Default value notation for integer arrays in Supabase migrations:

```sql
ALTER TABLE business_settings
    ALTER COLUMN reminder_days_before_due
    SET DEFAULT '{7,3,1}'::INT[];
```

---

## Related Documents

- `schemas/tenancy_schema_definition.md`
- `schemas/business_schema.md`
- `schemas/classification_output_schema.md`
- `schemas/invoice_schema.md`
- `policies/matching_policy.md`
- `policies/intake_size_limits_policy.md`
- `reference/audit_event_taxonomy.md`
- `reference/currency_enum.md`
