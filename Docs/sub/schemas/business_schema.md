# Business Schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `businesses` table. A business is the primary operational tenant unit — all transaction data, workflow runs, audit logs, and ledger entries are scoped to a `business_id`. Users access a business through `business_user_roles`; the business record itself carries identity, jurisdiction, and fiscal configuration. The Cyprus-specific fields (`vat_number`, `tax_authority_identifier`) are first-class columns, not metadata.

Note: the underlying platform table instantiated in Block 02 Phase 01 is `business_entities`. This sub-doc defines the canonical shape; references to `businesses` throughout the codebase resolve to `business_entities`. The alias is used in application-layer APIs; the Postgres table name is `business_entities`.

---

## Table: `business_entities` (canonical alias: `businesses`)

```sql
CREATE TABLE business_entities (
  id                          uuid            NOT NULL DEFAULT gen_uuid_v7(),
  display_name                text            NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 255),
  legal_name                  text            CHECK (char_length(legal_name) BETWEEN 1 AND 512),
  vat_number                  text,
  tax_authority_identifier    text,
  country_code                char(2)         NOT NULL DEFAULT 'CY',
  currency                    char(3)         NOT NULL DEFAULT 'EUR',
  timezone                    text            NOT NULL DEFAULT 'Asia/Nicosia',
  fiscal_year_start_month     integer         NOT NULL DEFAULT 1
    CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  organization_id             uuid            NOT NULL,
  created_by_user_id          uuid,
  is_active                   boolean         NOT NULL DEFAULT true,
  created_at                  timestamptz     NOT NULL DEFAULT now(),
  updated_at                  timestamptz     NOT NULL DEFAULT now(),

  CONSTRAINT business_entities_pkey        PRIMARY KEY (id),
  CONSTRAINT business_entities_org_fk      FOREIGN KEY (organization_id)
    REFERENCES organizations(id) ON DELETE RESTRICT,
  CONSTRAINT business_entities_creator_fk  FOREIGN KEY (created_by_user_id)
    REFERENCES users(id) ON DELETE SET NULL
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `id` | UUID v7 PK via `gen_uuid_v7()` per `data_layer_conventions_policy`. |
| `display_name` | Short trading name shown in the UI. NOT NULL; must be set at creation. |
| `legal_name` | Full registered legal name. Nullable — a business may operate before its legal registration is confirmed; required before finalization in Block 15. |
| `vat_number` | Cyprus VAT registration number (e.g., `CY12345678L`). Nullable until VAT-registered. Subject to partial VIES validation in Block 11. |
| `tax_authority_identifier` | Cyprus Tax Identification Code (TIC). Separate from the VAT number; used in filings with the Tax Department of Cyprus. Nullable. |
| `country_code` | ISO 3166-1 alpha-2. Defaults to `CY` (Cyprus). Must be two uppercase characters. |
| `currency` | ISO 4217 three-letter code. Defaults to `EUR`. All ledger amounts are stored in this currency as `numeric(15,4)`; FX treatment is Block 11's concern. |
| `timezone` | IANA timezone string. Defaults to `Asia/Nicosia`. Used for fiscal-period boundary calculations and scheduled job windows. |
| `fiscal_year_start_month` | Integer 1–12. Default 1 (January). Governs period labelling in OUT/IN workflow runs and reporting. |
| `organization_id` | FK to `organizations`. Every business belongs to exactly one organization. NOT NULL. |
| `created_by_user_id` | FK to `users.id`. Records which user created the business record. SET NULL on user deletion to preserve the business row. |
| `is_active` | Soft-delete flag per `soft_delete_vs_status_policy`. `false` = deactivated. The business can no longer initiate new workflow runs; its historical data is retained under the 7-year post-deactivation window defined in `data_retention_policy`. |
| `created_at` / `updated_at` | Standard audit timestamps; `updated_at` maintained by the `set_updated_at` trigger. |

---

## Indexes

```sql
-- Standard org scoping index (from tenancy_schema_definition pattern).
CREATE INDEX idx_business_entities_org_id ON business_entities (organization_id);

-- Status filter for active-business queries.
CREATE INDEX idx_business_entities_org_status ON business_entities (organization_id, is_active);

-- Unique VAT number where present — prevents duplicate VAT registration within the platform.
CREATE UNIQUE INDEX idx_business_entities_vat_number
  ON business_entities (vat_number)
  WHERE vat_number IS NOT NULL;
```

The partial unique index on `vat_number` enforces platform-wide uniqueness for businesses that have registered a VAT number, while permitting multiple NULL values (businesses not yet VAT-registered).

---

## RLS policies

Row-level security is enabled via `ALTER TABLE business_entities ENABLE ROW LEVEL SECURITY`.

### SELECT

Any user with an active role in `business_user_roles` for this business may SELECT its row:

```sql
CREATE POLICY business_entities_select_members
  ON business_entities FOR SELECT
  USING (id = ANY(current_user_businesses()));
```

### UPDATE

Only users with role `OWNER` on the business may UPDATE:

```sql
CREATE POLICY business_entities_update_owner
  ON business_entities FOR UPDATE
  USING (current_user_role(id) = 'OWNER')
  WITH CHECK (current_user_role(id) = 'OWNER');
```

### INSERT / DELETE / DEACTIVATE

INSERT is performed by the platform setup flow (service role). Deactivation (`is_active = false`) is Owner-only and requires step-up MFA per `archive_step_up_policy`. Hard-delete is not permitted from any application role; business deactivation is the only supported lifecycle terminal for MVP.

### Mobile

Write surfaces (UPDATE, INSERT) reject requests where `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints.md`, emitting `MOBILE_WRITE_REJECTED`. Read (SELECT) operations are permitted on mobile.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `BUSINESS_CREATED` | Row inserted | LOW |
| `BUSINESS_UPDATED` | Any field updated by Owner | LOW |
| `BUSINESS_DEACTIVATED` | `is_active` set to `false` — platform admin action only | HIGH |

`BUSINESS_DEACTIVATED` is HIGH because deactivation triggers the 7-year retention clock and prevents new workflow runs. Only the platform admin role may deactivate a business; Owner may not self-deactivate. Events are emitted via `security.emit_audit` in the `BUSINESS` domain.

---

## Cyprus-specific considerations

- `vat_number` format: Cyprus VAT numbers follow the pattern `CY` + 8 digits + 1 letter. Format validation is enforced at the application layer, not the DB constraint, to allow future multi-country expansion without a migration.
- `tax_authority_identifier` (TIC): 8-digit number issued by the Cyprus Tax Department. Required for statutory filings; optional at creation.
- `timezone` default `Asia/Nicosia`: Cyprus observes EET/EEST (UTC+2/UTC+3). Fiscal-period boundary computations in Block 11 and Block 12/13 use this timezone to determine month start/end timestamps.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK, canonical JSON for audit payloads, currency as `numeric(15,4)` strings
- `tenancy_schema_definition` — authoritative parent definition; this doc elaborates the `business_entities` table shape
- `user_schema` — `created_by_user_id` FK; users access businesses through `business_user_roles`
- `rls_helper_functions` — `current_user_businesses()`, `current_user_role()` used in RLS policies
- `soft_delete_vs_status_policy` — governs `is_active` and prohibition on hard-delete
- `data_retention_policy` — 7-year post-deactivation retention window for business data
- `audit_log_policies` — `BUSINESS` domain naming convention, severity enum
- `audit_event_taxonomy` — `BUSINESS_CREATED`, `BUSINESS_UPDATED`, `BUSINESS_DEACTIVATED` catalogue entries
- `mobile_write_rejection_endpoints.md` — write-surface rejection rule for mobile clients
- `Docs/phases/02_tenancy_and_access/01_schema_scaffolding.md` — phase that instantiates this table
