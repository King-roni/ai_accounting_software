# Client Contact Schema

**Block:** IN Workflow / Data
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `client_contacts` table stores individual contact records for clients. A single client may have multiple contacts — for example, separate contacts for accounts payable, general enquiries, and legal correspondence. One contact per client may be designated the primary contact via `is_primary = true`.

Contact records are used by the invoice generation and notification subsystems to determine the correct recipient for outbound communications. The `email` field is the primary routing address for invoice delivery and overdue reminders.

---

## DDL

```sql
CREATE TABLE client_contacts (
  id                  UUID        NOT NULL DEFAULT gen_uuid_v7(),
  client_id           UUID        NOT NULL
    REFERENCES clients(id) ON DELETE CASCADE,
  business_entity_id  UUID        NOT NULL
    REFERENCES business_entities(id) ON DELETE RESTRICT,
  contact_name        TEXT        NOT NULL,
  role                TEXT,
    -- Optional label for the contact's function, e.g. 'Accounts Payable',
    -- 'Managing Director', 'Tax Advisor'. Free-text; not enumerated.
  email               TEXT,
    -- nullable; not all contacts have email addresses
  phone               TEXT,
    -- nullable; E.164 format recommended but not enforced at DB level
    -- application layer validates format on write
  is_primary          BOOLEAN     NOT NULL DEFAULT false,
  preferred_language  CHAR(5)     NOT NULL DEFAULT 'el-CY',
    -- IETF BCP 47 language tag; used for invoice and notification localisation
    -- Default: Greek (Cyprus). Other supported values: 'en-CY', 'en-GB', 'ru-RU'
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT client_contacts_pkey
    PRIMARY KEY (id),
  CONSTRAINT client_contacts_email_unique_per_client
    UNIQUE NULLS NOT DISTINCT (client_id, email)
    -- Enforces uniqueness of (client_id, email) only when email IS NOT NULL.
    -- Multiple contacts for the same client may have NULL email.
);
```

**Note on `UNIQUE NULLS NOT DISTINCT`:** requires Postgres 15+. On earlier versions, use the equivalent partial unique index:

```sql
CREATE UNIQUE INDEX idx_client_contacts_email_per_client
  ON client_contacts (client_id, email)
  WHERE email IS NOT NULL;
```

### Column Notes

- `id` — generated via `gen_uuid_v7()`. Time-ordered PK consistent with the platform data layer convention.
- `client_id` — FK to `clients(id)`. ON DELETE CASCADE ensures that deleting a client removes all associated contact records. The cascade is intentional: contacts have no independent existence outside their parent client.
- `business_entity_id` — denormalised FK to `business_entities(id)` included for RLS policy support. Must always match `clients.business_id` for the referenced client. This is enforced by a BEFORE INSERT trigger that reads the parent client's `business_id` and rejects mismatches.
- `contact_name` — full name of the contact person. Required. No minimum length enforced at DB level; application layer requires at least 2 characters.
- `role` — optional functional label. Examples: `'Accounts Payable'`, `'Managing Director'`, `'Legal Representative'`. Not validated against an enum; the field is descriptive.
- `email` — nullable. When present, must be a valid email address format enforced at the application layer (not at DB level). The unique constraint prevents two contacts for the same client sharing an email address.
- `phone` — nullable. E.164 format is recommended (e.g., `+35722123456`) but not enforced at DB level. Application layer validates the format on write and normalises it.
- `is_primary` — only one contact per client should have `is_primary = true`. This is enforced by a BEFORE INSERT/UPDATE trigger (see Primary Contact Constraint section).
- `preferred_language` — IETF BCP 47 language tag used to select the localisation template for invoices, reminders, and system notifications. Defaults to `'el-CY'` (Greek, Cyprus).

---

## Primary Contact Constraint

The uniqueness of `is_primary = true` per client is enforced by a database trigger rather than a partial unique index, to allow a smooth primary-contact handoff:

```sql
CREATE OR REPLACE FUNCTION enforce_single_primary_contact()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_primary = true THEN
    UPDATE client_contacts
    SET is_primary = false, updated_at = now()
    WHERE client_id = NEW.client_id
      AND id <> NEW.id
      AND is_primary = true;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER client_contacts_primary_contact_guard
  BEFORE INSERT OR UPDATE ON client_contacts
  FOR EACH ROW EXECUTE FUNCTION enforce_single_primary_contact();
```

The trigger automatically demotes the previously primary contact when a new primary is set. This avoids the need for callers to explicitly clear the old primary before setting the new one.

---

## Indexes

```sql
-- Primary lookup: all contacts for a client
CREATE INDEX client_contacts_client_idx
  ON client_contacts (client_id);

-- Business-scoped queries (used by RLS and admin views)
CREATE INDEX client_contacts_business_idx
  ON client_contacts (business_entity_id);

-- Primary contact fast lookup
CREATE INDEX client_contacts_primary_idx
  ON client_contacts (client_id, is_primary)
  WHERE is_primary = true;

-- Email lookup for deduplication checks
CREATE INDEX client_contacts_email_idx
  ON client_contacts (email)
  WHERE email IS NOT NULL;
```

---

## Row-Level Security

```sql
ALTER TABLE client_contacts ENABLE ROW LEVEL SECURITY;

-- Business members may read and write contacts for their own business
CREATE POLICY client_contacts_member_access
  ON client_contacts FOR ALL
  TO authenticated
  USING (
    business_entity_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  )
  WITH CHECK (
    business_entity_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );
```

RLS is scoped via `business_entity_id`. Because this column is denormalised from the parent `clients` row, the BEFORE INSERT trigger that validates `business_entity_id` against the parent is a required integrity control.

---

## Supported Language Tags

| Tag | Language | Region |
|---|---|---|
| `el-CY` | Greek | Cyprus (default) |
| `en-CY` | English | Cyprus |
| `en-GB` | English | United Kingdom |
| `ru-RU` | Russian | Russia |

Additional language tags may be added via a schema migration without changing the column type. The notification and PDF rendering subsystems validate `preferred_language` against the supported tag list at template selection time; unsupported tags fall back to `en-CY`.

---

## Usage in Invoice Generation

When the invoice generator dispatches a tax invoice or payment reminder:

1. It reads the primary contact for the client (`is_primary = true`).
2. If no primary contact exists, it falls back to the `clients.email` column.
3. If `clients.email` is also null, the invoice is marked `SEND_FAILED` and flagged for manual delivery.
4. The `preferred_language` of the primary contact determines the invoice template locale.

---

## Related Documents

- `schemas/client_schema.md` — Parent client table DDL
- `schemas/clients_registry_schema.md` — Client registry and multi-business client tracking
- `schemas/invoice_schema.md` — Invoice table (uses primary contact email for delivery)
- `policies/client_data_policy.md` — Client data handling and retention rules
- `tools/tool_invoice_send.md` — Invoice dispatch tool (reads primary contact)
- `tools/tool_notify_send.md` — Push notification dispatch
