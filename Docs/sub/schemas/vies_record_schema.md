# vies_record_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `vies_records` table, which caches VIES (VAT Information Exchange System) lookup results per counterparty. VIES lookups are required to confirm EU VAT registration before applying `EU_REVERSE_CHARGE` treatment to intra-EU transactions (Block 11 Phase 06). Results are cached for 30 days to avoid redundant external SOAP calls. The raw SOAP response is retained for every record to support audit and compliance obligations.

---

## Table definition

```sql
CREATE TABLE vies_records (
  vies_record_id            uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id               uuid        NOT NULL REFERENCES business_entities(id),
  counterparty_vat_number   text        NOT NULL,
  query_country_code        char(2)     NOT NULL,
  is_valid                  boolean     NOT NULL,
  trader_name               text,
  trader_address            text,
  query_date                date        NOT NULL,
  queried_at                timestamptz NOT NULL DEFAULT now(),
  response_raw_xml          text        NOT NULL,
  cache_expires_at          timestamptz NOT NULL,
  created_at                timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_vies_record_per_business_vat_date
    UNIQUE (business_id, counterparty_vat_number, query_date),

  CONSTRAINT chk_query_country_code_uppercase
    CHECK (query_country_code = upper(query_country_code)),

  CONSTRAINT chk_cache_expires_gt_queried
    CHECK (cache_expires_at > queried_at),

  CONSTRAINT chk_vat_number_nonempty
    CHECK (length(trim(counterparty_vat_number)) > 0)
);
```

---

## Column notes

- `vies_record_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing within millisecond precision; enables time-range scans on the VIES lookup history without a separate `created_at` index.
- `business_id` — tenant isolation anchor. Every RLS policy, index, and query path includes this column. VIES lookup results are business-scoped because the business's own VAT registration context may affect which lookups are needed.
- `counterparty_vat_number` — the full EU VAT number as submitted to the VIES SOAP service (e.g., `DE123456789`, `CY12345678X`). Stored verbatim as returned by the caller; no normalisation is applied here. The calling layer (`ledger.lookup_vies`) validates format before insertion. Leading/trailing whitespace is not permitted (enforced by the `chk_vat_number_nonempty` constraint on the trimmed value; the application layer trims before insert).
- `query_country_code` — ISO 3166-1 alpha-2 country code of the EU member state whose VIES service was queried (e.g., `DE`, `CY`, `NL`). The VIES service requires the country code to route the SOAP request to the correct national tax authority. Stored uppercase; the check constraint enforces this.
- `is_valid` — the boolean validity result returned by VIES. `true` means the VAT number was confirmed as valid and active at `query_date`. `false` means the number was found but invalid, inactive, or not registered. `false` does not mean the SOAP call failed; failures produce no row (see Section 4).
- `trader_name` — the legal name of the VAT-registered trader as returned by the VIES service. Null when VIES does not return name information for the queried member state (some EU states restrict name disclosure via VIES). Null is a valid operational value; it does not indicate a failed lookup.
- `trader_address` — the registered trading address as returned by VIES. Subject to the same null-allowed restriction as `trader_name`.
- `query_date` — the calendar date (not timestamp) on which the lookup was performed. Used as the cache key's date component and as the "validity as of" date for compliance records. The unique constraint is on `(business_id, counterparty_vat_number, query_date)` — one lookup record per VAT number per business per day.
- `queried_at` — the exact timestamp of the SOAP request. More granular than `query_date`; used for audit ordering within a day.
- `response_raw_xml` — the complete raw VIES SOAP response body, stored as text. Required for audit and compliance: Cyprus VAT regulations require that evidence of VIES validity checks be retained. The raw XML is the authoritative record of what VIES returned. It is not parsed beyond extracting `is_valid`, `trader_name`, and `trader_address`; the full response is preserved verbatim.
- `cache_expires_at` — timestamp after which the cached result must not be used; a fresh VIES lookup is required. Computed as `queried_at + INTERVAL '30 days'`. The 30-day cache window is a system constant; no per-business override is supported in MVP. After expiry, the row is not deleted; it remains as a historical record, but `ledger.lookup_vies` treats it as expired and issues a new VIES request, inserting a new row for the new `query_date`.
- `created_at` — insertion timestamp; immutable.

---

## Unique constraint semantics

```sql
CONSTRAINT uq_vies_record_per_business_vat_date
  UNIQUE (business_id, counterparty_vat_number, query_date)
```

One lookup result per business per VAT number per calendar day. If `ledger.lookup_vies` is called twice in the same day for the same VAT number on behalf of the same business, the second call returns the existing cached row without issuing a SOAP request. Idempotency is enforced at the application layer via `ON CONFLICT DO NOTHING` — the unique constraint prevents duplicate rows; the second call simply reads the existing row.

---

## Cache expiry logic

`ledger.lookup_vies` follows this decision tree before issuing a VIES SOAP call:

1. Query `vies_records` for the most recent row matching `(business_id, counterparty_vat_number)` with `cache_expires_at > now()`.
2. If found → return the cached result; no SOAP call.
3. If not found or all rows are expired → issue a VIES SOAP call.
4. On success → insert a new `vies_records` row.
5. On failure → no row is inserted; emit `VIES_LOOKUP_FAILED`; the calling context decides whether to fall back to `UNKNOWN` VAT treatment or raise a review issue.

The cache is per-business (not shared across businesses) because different businesses may query the same VAT number at different times and receive different validity results (e.g., if the counterparty's VAT registration changes between queries).

---

## RLS

```sql
CREATE POLICY vies_records_isolation ON vies_records
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Tenant isolation is enforced exclusively via `business_id`. No cross-tenant VIES lookup data is accessible regardless of role.

---

## Indexes

```sql
-- Tenant-scoped lookup by VAT number and cache validity
CREATE INDEX idx_vies_records_business_vat_expiry
  ON vies_records (business_id, counterparty_vat_number, cache_expires_at DESC);

-- Cache expiry sweep (background job that marks expired records)
CREATE INDEX idx_vies_records_vat_expiry
  ON vies_records (counterparty_vat_number, cache_expires_at)
  WHERE cache_expires_at > now();

-- Most recent lookup per business for VIES export generation
CREATE INDEX idx_vies_records_business_queried
  ON vies_records (business_id, queried_at DESC);
```

---

## Mobile write rejection

VIES lookup operations are server-side workflow operations. No mobile client can trigger a VIES SOAP call or write to `vies_records`. Write surfaces that feed VIES lookups (e.g., setting a counterparty's VAT number) are subject to `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `VIES_LOOKUP_COMPLETED` | VIES SOAP call succeeded; new `vies_records` row inserted | LOW |
| `VIES_LOOKUP_FAILED` | VIES SOAP call failed (all retries exhausted); no row inserted | MEDIUM |

Both events are emitted via `emitAudit()` per `audit_log_policies` and catalogued in `audit_event_taxonomy` under the VIES domain. The `VIES_LOOKUP_COMPLETED` payload includes `{ vies_record_id, counterparty_vat_number, is_valid, query_country_code, cache_expires_at }`. The `VIES_LOOKUP_FAILED` payload includes `{ counterparty_vat_number, query_country_code, error_code, attempt_count }`.

`VIES_LOOKUP_FAILED` at `MEDIUM` severity: a failed lookup means the system cannot confirm EU VAT registration, which may block `EU_REVERSE_CHARGE` treatment application and route the transaction to accountant review.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; canonical JSON serialization; no float amounts in this schema
- `audit_log_policies` — VIES domain (new domain added in this batch); `<DOMAIN>_<PAST_VERB>` naming convention
- `audit_event_taxonomy` — `VIES_LOOKUP_COMPLETED`, `VIES_LOOKUP_FAILED`
- `vat_rate_table_reference` — `EU_REVERSE_CHARGE` treatment that requires a valid VIES result; rate-to-treatment mapping
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
- `tool_naming_convention_policy` — `ledger.*` namespace; `ledger.lookup_vies` as the sole tool writing to this table
- Block 11 Phase 06 — reverse-charge and VIES relevance; primary consumer of this table
- Block 16 Phase 11 — VIES export generation; reads this table for the period-end VIES recapitulative statement
