# Schema: clients (Client Registry)

**Block:** Tenancy & Access / Counterparty Management
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`clients` is the counterparty registry. Each row represents a client or supplier known to a specific business entity. This table is distinct from `business_entities`, which holds the platform tenants (the businesses using the software). `clients` holds the third parties that a tenant invoices or pays.

A single real-world company may appear as a `clients` row in multiple business entities — there is no global deduplication of client records across tenants. Each business entity owns its own client list.

The `iban` column stores encrypted ciphertext via Supabase Vault. Application code never reads the raw IBAN; the decrypted value is accessed only through the Vault function and never returned in list queries. Display shows only the last four characters of the IBAN.

---

## Enum Definition

```sql
CREATE TYPE client_type_enum AS ENUM (
  'INDIVIDUAL',
  'COMPANY',
  'EU_COMPANY',
  'NON_EU_COMPANY'
);
```

- `INDIVIDUAL` — a natural person, not a registered company.
- `COMPANY` — a Cyprus-registered company.
- `EU_COMPANY` — a company registered in another EU member state. EU VAT rules apply.
- `NON_EU_COMPANY` — a company registered outside the EU. Export VAT rules apply.

The `client_type_enum` drives VAT treatment defaulting: EU_COMPANY triggers VIES validation; NON_EU_COMPANY triggers zero-rate export classification by default.

---

## DDL

```sql
CREATE TABLE clients (
  id                    UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id    UUID          NOT NULL
                          REFERENCES business_entities(id)
                          ON DELETE RESTRICT,
  client_name           TEXT          NOT NULL,
  client_type           client_type_enum NOT NULL,
  vat_number            TEXT              NULL,
  country_code          CHAR(2)       NOT NULL DEFAULT 'CY',
  iban                  TEXT              NULL,
  email                 TEXT              NULL,
  phone                 TEXT              NULL,
  address_json          JSONB             NULL,
  eu_vat_registered     BOOLEAN       NOT NULL DEFAULT false,
  preferred_currency    CHAR(3)       NOT NULL DEFAULT 'EUR',
  is_active             BOOLEAN       NOT NULL DEFAULT true,
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT clients_pkey PRIMARY KEY (id),

  CONSTRAINT clients_client_name_nonempty
    CHECK (length(trim(client_name)) > 0),

  CONSTRAINT clients_country_code_uppercase
    CHECK (country_code = upper(country_code)),

  CONSTRAINT clients_preferred_currency_uppercase
    CHECK (preferred_currency = upper(preferred_currency)),

  CONSTRAINT clients_eu_vat_registered_requires_vat_number
    CHECK (
      eu_vat_registered = false
      OR vat_number IS NOT NULL
    ),

  CONSTRAINT clients_eu_company_requires_eu_vat_registered
    CHECK (
      client_type NOT IN ('EU_COMPANY')
      OR eu_vat_registered = true
    )
);
```

`iban` stores the Vault-encrypted ciphertext of the IBAN string. The application inserts the ciphertext returned by `vault.create_secret()`. Reads use `vault.decrypted_secrets` view only when the full IBAN is needed for payment processing; all other reads use a display function that returns the last 4 characters of the decrypted value.

`address_json` is an unvalidated JSONB blob at the schema level. Application-layer validation enforces the expected shape: `{ line1, line2?, city, postcode, country_code }`. Schema-level validation is intentionally omitted to accommodate address format variation across countries.

---

## Indexes

```sql
CREATE UNIQUE INDEX idx_clients_business_entity_id_client_name
  ON clients (business_entity_id, lower(client_name))
  WHERE is_active = true;

CREATE INDEX idx_clients_business_entity_id
  ON clients (business_entity_id);

CREATE INDEX idx_clients_vat_number
  ON clients (business_entity_id, vat_number)
  WHERE vat_number IS NOT NULL;

CREATE INDEX idx_clients_client_type
  ON clients (business_entity_id, client_type);

CREATE INDEX idx_clients_country_code
  ON clients (business_entity_id, country_code);

CREATE INDEX idx_clients_is_active
  ON clients (business_entity_id, is_active);

CREATE INDEX idx_clients_created_at
  ON clients (created_at DESC);
```

The unique index on `(business_entity_id, lower(client_name))` is partial: it applies only to active clients (`is_active = true`). Two deactivated clients may share the same name; an active and a deactivated client may share the same name. This matches user expectations — a deactivated client does not "block" creation of a new client with the same name.

---

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `business_entity_id` | UUID | No | FK to `business_entities(id)`. Tenant owner of this client record. |
| `client_name` | TEXT | No | Display name of the client or counterparty. |
| `client_type` | client_type_enum | No | Classification driving VAT and reporting treatment. |
| `vat_number` | TEXT | Yes | VAT registration number. Required if eu_vat_registered = true. |
| `country_code` | CHAR(2) | No | ISO 3166-1 alpha-2. Default 'CY'. |
| `iban` | TEXT | Yes | Vault-encrypted IBAN ciphertext. Display: last 4 chars only. |
| `email` | TEXT | Yes | Contact email address. |
| `phone` | TEXT | Yes | Contact phone number. |
| `address_json` | JSONB | Yes | Structured address. Shape: `{ line1, line2?, city, postcode, country_code }`. |
| `eu_vat_registered` | BOOLEAN | No | True if client holds a valid EU VAT registration. Default false. |
| `preferred_currency` | CHAR(3) | No | ISO 4217 currency code for invoicing. Default 'EUR'. |
| `is_active` | BOOLEAN | No | Soft-delete flag. Inactive clients do not appear in selectors. |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |
| `updated_at` | TIMESTAMPTZ | No | Last update timestamp. Maintained by trigger. |

---

## Row-Level Security

```sql
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;

CREATE POLICY clients_select
  ON clients
  FOR SELECT
  USING (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
  );

CREATE POLICY clients_insert
  ON clients
  FOR INSERT
  WITH CHECK (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
  );

CREATE POLICY clients_update
  ON clients
  FOR UPDATE
  USING (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
  );
```

DELETE is not permitted via RLS. Clients are deactivated (`is_active = false`), never deleted, to preserve historical invoice and payment associations.

---

## Business Rules

1. A client name must be unique (case-insensitive) within a business entity's active clients.
2. `eu_vat_registered = true` requires a non-NULL `vat_number`. The system will trigger VIES validation on save when `client_type = EU_COMPANY`.
3. IBAN is stored encrypted. Plain-text IBAN must never appear in logs, error messages, or API responses.
4. `preferred_currency` defaults to EUR but may be any supported ISO 4217 code. Currency availability is checked against the platform's supported currency list at creation time.
5. Deactivated clients cannot be selected when creating new invoices or payments. Existing associations to deactivated clients remain valid.

---

## Audit Events

| Event | Trigger |
|---|---|
| `CLIENT_CREATED` | New client row inserted |
| `CLIENT_UPDATED` | Any mutable field changed |
| `CLIENT_DEACTIVATED` | is_active set to false |
| `CLIENT_REACTIVATED` | is_active set to true |

---

## Related Documents

- `counterparty_schema.md` — broader counterparty resolution context
- `client_schema.md` — alternate view schema reference
- `invoice_schema.md` — client_id FK target on invoices
- `payment_schema.md` — client_id FK target on payments
- `client_vat_validation_policy.md` — VAT number validation and VIES lookup rules
- `vies_record_schema.md` — VIES validation result records
- `counterparty_encryption_schema.md` — encryption details for IBAN and sensitive fields
- `client_data_policy.md` — data retention and PII handling for client records
- `gdpr_right_to_erasure_policy.md` — erasure handling for client PII
