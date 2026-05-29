# VAT Validation Cache Schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Canonical DDL for the `vat_validation_cache` table. This table caches VIES VAT number validation results to avoid redundant API calls to the EU VIES SOAP service. One active cache entry per `(business_id, vat_number, country_code)` is maintained at any time; when a subsequent validation returns a different result, the old row is soft-invalidated and a new row is inserted.

---

## Enum type declaration

```sql
CREATE TYPE vat_validation_status_enum AS ENUM (
  'VALID',
  'INVALID',
  'UNAVAILABLE',
  'EXPIRED'
);
```

`UNAVAILABLE` means the VIES service returned an error or was unreachable during the lookup. `EXPIRED` is set by the TTL sweep job when `expires_at` passes and no fresh validation has replaced the row.

---

## Table DDL

```sql
CREATE TABLE vat_validation_cache (
  id                  uuid        NOT NULL DEFAULT gen_uuid_v7()    PRIMARY KEY,
  business_id         uuid        NOT NULL REFERENCES business_entities(id),

  vat_number          text        NOT NULL,
  country_code        char(2)     NOT NULL,

  validation_status   vat_validation_status_enum NOT NULL,

  -- validated_at: when the VIES API call was made for this row.
  validated_at        timestamptz NOT NULL,

  -- expires_at:
  --   VALID or INVALID: 24 hours after validated_at.
  --   UNAVAILABLE: expires_at = validated_at (immediate re-validation allowed).
  --   EXPIRED: set retroactively by the TTL sweep.
  expires_at          timestamptz NOT NULL,

  -- Trader details returned by VIES when validation_status = VALID.
  -- NULL for INVALID, UNAVAILABLE, and EXPIRED.
  trader_name         text        NULL,
  trader_address      text        NULL,

  -- VIES correlation ID for this request. Useful for support tracing.
  vies_request_id     text        NULL,

  -- Soft-invalidation: set when a subsequent VIES call returns a different
  -- result from this row's validation_status. The new result is inserted
  -- as a fresh row; this row is retained for audit purposes.
  invalidated_at      timestamptz NULL,

  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- One active cache entry per (business_id, vat_number, country_code).
  -- Enforced as a partial unique index on non-invalidated rows (see below).
  CONSTRAINT vat_validation_cache_identity_uniq
    UNIQUE (business_id, vat_number, country_code)
);
```

The `UNIQUE` constraint above is supplemented by a partial unique index that covers only non-invalidated rows. The base constraint is present for FK reference stability; the partial index prevents duplicate active entries.

---

## Indexes

```sql
-- Primary lookup: given a VAT number, find the current cache entry.
CREATE INDEX vat_validation_cache_lookup_idx
  ON vat_validation_cache (business_id, vat_number)
  WHERE invalidated_at IS NULL;

-- TTL sweep: find expired rows needing cleanup or re-validation.
CREATE INDEX vat_validation_cache_expires_at_idx
  ON vat_validation_cache (expires_at)
  WHERE invalidated_at IS NULL AND validation_status != 'EXPIRED';

-- Partial unique index: prevent two active (non-invalidated) entries
-- for the same (business_id, vat_number, country_code).
CREATE UNIQUE INDEX vat_validation_cache_active_uniq
  ON vat_validation_cache (business_id, vat_number, country_code)
  WHERE invalidated_at IS NULL;
```

---

## Row-level security

```sql
ALTER TABLE vat_validation_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY vat_validation_cache_tenant_isolation
  ON vat_validation_cache
  USING (business_id = auth.current_business_id());
```

---

## TTL and cache invalidation rules

**TTL by validation_status:**
- `VALID`: 24 hours from `validated_at`. After expiry, the next lookup triggers a fresh VIES call.
- `INVALID`: 24 hours from `validated_at`. Invalid results are cached to avoid hammering VIES with known-bad numbers.
- `UNAVAILABLE`: `expires_at = validated_at`. Re-validation is allowed immediately on the next request.

**Invalidation:** When a fresh VIES call returns a result that differs from the current cached `validation_status`, the current row's `invalidated_at` is set to `now()` and a new row is inserted with the fresh result. This preserves the history of all validation results for audit and tracing.

**EXPIRED sweep:** A background job runs daily to mark rows where `expires_at < now()` and `invalidated_at IS NULL` as `validation_status = EXPIRED`. The `invalidated_at` is not set by the sweep — EXPIRED rows remain the "active" row for the VAT number until a fresh validation replaces them.

---

## Data zone

Operational zone (Postgres). Retention aligned with transaction records: 7 years per `data_retention_policy`. Cache rows are not moved to an archive zone; they are small and low-cardinality relative to the retention period.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `LEDGER_VAT_NUMBER_VALIDATED` | LOW | VIES call completes and a new cache row is inserted with `VALID` status |
| `LEDGER_VAT_NUMBER_INVALID` | MEDIUM | VIES call returns `INVALID` status for a VAT number |

Both events carry `cache_record_id`, `business_id`, `vat_number`, `country_code`, and `validation_status`. `LEDGER_VAT_NUMBER_INVALID` additionally carries `trader_name` (null) and `vies_request_id` to aid operator investigation.

---

## Cross-references

- `vies_record_schema.md` — VIES lookup records that are the source of truth for intra-EU transactions
- `vies_quarterly_eligibility_policy.md` — governs when VIES lookup is required
- `client_vat_validation_policy.md` — policy for when to validate a client's VAT number
- `data_layer_conventions_policy` — identifier generation, canonical JSON
- `audit_event_taxonomy` — canonical event catalogue for LEDGER domain events
