# Bank Feed Schema

**Category:** Schemas · Block 04 — Data Ingestion & Intake
**Owner:** data
**Last updated:** 2026-05-17

---

## 1. Purpose

DDL and field reference for the `bank_feeds` table. This table stores the configuration
for a live bank connection attached to a business entity — which bank, which account
(identified by last 4 digits of IBAN for storage safety), which feed provider, how
often to sync, and the current sync health. One row represents one bank account
connection. A business entity may have multiple rows (multiple bank accounts). Each
row is independently managed; sync frequency, credential reference, and active flag
are per-connection, not per-business.

---

## 2. Enum Definitions

```sql
CREATE TYPE bank_feed_provider_enum AS ENUM (
  'NORDIGEN',
  'SALT_EDGE',
  'MANUAL_UPLOAD'
);

CREATE TYPE bank_sync_status_enum AS ENUM (
  'SUCCESS',
  'PARTIAL',
  'FAILED',
  'RATE_LIMITED'
);
```

| Provider value | Meaning |
|----------------|---------|
| `NORDIGEN` | GoCardless Open Banking API. Covers most EU banks. |
| `SALT_EDGE` | Salt Edge PSD2 aggregator. Used for banks not on Nordigen. |
| `MANUAL_UPLOAD` | No live connection. Statements uploaded as CSV or OFX. |

`MANUAL_UPLOAD` feeds do not sync on a schedule. `sync_frequency` and `last_synced_at`
are ignored. `last_sync_status` reflects the most recent manual upload processing run.

| Sync status value | Meaning |
|-------------------|---------|
| `SUCCESS` | Sync completed; all transactions retrieved. |
| `PARTIAL` | Sync completed but some pages were unavailable. |
| `FAILED` | Sync failed; no transactions retrieved. Triggers an alert. |
| `RATE_LIMITED` | Provider returned rate-limit; sync not attempted. |

`PARTIAL` and `RATE_LIMITED` do not block the next scheduled sync. Only `FAILED`
triggers an alert via the notification routing in `notification_schema.md`.

---

## 3. DDL

```sql
CREATE TABLE bank_feeds (
  id                  uuid          NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id  uuid          NOT NULL REFERENCES business_entities(id),
  bank_name           text          NOT NULL,
  iban_last4          char(4)       NOT NULL,
  feed_provider       bank_feed_provider_enum NOT NULL,
  credential_ref      text          NOT NULL,
  sync_frequency      interval      NOT NULL DEFAULT '4 hours',
  last_synced_at      timestamptz   NULL,
  last_sync_status    bank_sync_status_enum NULL,
  is_active           boolean       NOT NULL DEFAULT true,
  created_at          timestamptz   NOT NULL DEFAULT now(),
  updated_at          timestamptz   NOT NULL DEFAULT now(),

  CONSTRAINT bank_feeds_pkey PRIMARY KEY (id)
);
```

---

## 4. Column Reference

**`id`** — `uuid NOT NULL DEFAULT gen_uuid_v7()`. Surrogate PK. Uses `gen_uuid_v7()`
(time-ordered UUID v7). Never `gen_random_uuid()` on business PKs.

**`business_entity_id`** — `uuid NOT NULL REFERENCES business_entities(id)`. Owning
business entity. FK references `business_entities(id)`, never `businesses(id)`.

**`bank_name`** — `text NOT NULL`. Display-only bank name (e.g., `"Bank of Cyprus"`).
Not used in matching or classification logic. Max 255 characters at application layer.

**`iban_last4`** — `char(4) NOT NULL`. Last four characters of the IBAN. The platform
never stores the full IBAN in the operational database. The full IBAN lives in the
Vault secret referenced by `credential_ref`. The `char(4)` type enforces a hard
maximum of four characters at the Postgres level. Used in UI to identify the account
(e.g., `"... 4782"`).

**`feed_provider`** — `bank_feed_provider_enum NOT NULL`. Determines which sync adapter
is invoked. `MANUAL_UPLOAD` disables the scheduler entirely for this row.

**`credential_ref`** — `text NOT NULL`. Vault path (e.g.,
`vault/data/bank-feeds/<business_entity_id>/<feed_id>`) pointing to encrypted provider
credentials. Credential content is never in this table. Rotation updates the Vault
entry at the same path; this column does not change on rotation.

**`sync_frequency`** — `interval NOT NULL DEFAULT '4 hours'`. Scheduling interval.
Accepted values: `'1 hour'`, `'4 hours'`, `'24 hours'`. Ignored for `MANUAL_UPLOAD`.

**`last_synced_at`** — `timestamptz NULL`. Timestamp of the last sync attempt, whether
successful or not. `NULL` until the first sync attempt.

**`last_sync_status`** — `bank_sync_status_enum NULL`. Result of the most recent sync.
`NULL` until first attempt. Updated atomically with `last_synced_at`.

**`is_active`** — `boolean NOT NULL DEFAULT true`. When `false`, the scheduler skips
this feed. Setting `is_active = false` is the only supported soft-disable path; there
is no hard-delete for `bank_feeds` rows.

**`created_at`** / **`updated_at`** — `timestamptz NOT NULL DEFAULT now()`. Set at
INSERT by the database clock. `updated_at` is maintained by a `BEFORE UPDATE` trigger.
Application code must not set `updated_at` explicitly.

---

## 5. Indexes

```sql
CREATE INDEX idx_bank_feeds_business_entity_id
  ON bank_feeds (business_entity_id);

CREATE INDEX idx_bank_feeds_active_sync
  ON bank_feeds (feed_provider, last_synced_at)
  WHERE is_active = true;

CREATE INDEX idx_bank_feeds_failed
  ON bank_feeds (business_entity_id, last_sync_status)
  WHERE last_sync_status = 'FAILED';
```

---

## 6. IBAN Storage Rule

The full IBAN is never written to `bank_feeds` or any other operational table.
Enforcement operates at two layers:

1. The intake API strips the IBAN to `iban_last4` before constructing the INSERT.
   The full IBAN is forwarded to Vault and then discarded from application memory.
2. An audit-layer trigger detects any column value matching the IBAN regex
   `[A-Z]{2}[0-9]{2}[A-Z0-9]{4}[0-9]{7}([A-Z0-9]?){0,16}` in a write path,
   emits `SECURITY_IBAN_PLAINTEXT_DETECTED` (BLOCKING), and rolls back the transaction.

---

## 7. Row-Level Security

```sql
ALTER TABLE bank_feeds ENABLE ROW LEVEL SECURITY;

CREATE POLICY bank_feeds_select ON bank_feeds FOR SELECT TO authenticated
  USING (business_entity_id IN (
    SELECT business_entity_id FROM org_members WHERE user_id = auth.uid()
  ));

CREATE POLICY bank_feeds_insert ON bank_feeds FOR INSERT
  TO service_role WITH CHECK (true);

CREATE POLICY bank_feeds_update ON bank_feeds FOR UPDATE
  TO service_role USING (true) WITH CHECK (true);
-- No DELETE policy for any role.
```

Authenticated JWT users may read their own business entity's feeds. All writes go
through server-side tools (`data.connect_bank_feed`, `data.update_sync_frequency`)
which run under `service_role`.

---

## 8. Business Rules

- A business entity may have up to 20 active feeds. Exceeding this returns
  `BANK_FEED_LIMIT_EXCEEDED` from the connection API.
- Feeds with `last_sync_status = 'FAILED'` for more than 48 consecutive hours trigger
  an alert notification to ADMIN members of the business entity.
- `MANUAL_UPLOAD` feeds retain their `sync_frequency` value but it is never read by
  the scheduler.

---

## 9. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `BANK_FEED_CONNECTED` | MEDIUM | New row inserted |
| `BANK_FEED_DEACTIVATED` | MEDIUM | `is_active` set to `false` |
| `BANK_FEED_SYNC_FAILED` | HIGH | `last_sync_status` set to `FAILED` |
| `SECURITY_IBAN_PLAINTEXT_DETECTED` | BLOCKING | Full IBAN detected in write path |

---

## 10. Cross-References

- `bank_statement_raw_schema.md` — raw transaction rows from feed sync
- `bank_upload_schema.md` — manual upload ingestion path for `MANUAL_UPLOAD` feeds
- `bank_upload_status_transitions_schema.md` — upload lifecycle state machine
- `secrets_management_policy.md` — Vault path conventions for credential storage
- `notification_schema.md` — alert routing for sync failure notifications
- `data_retention_policy.md` — retention rules for feed configuration rows
