# counterparty_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the full column set for the `counterparties` table, which stores vendor and supplier records derived from transaction data. Counterparty records are created and updated by the ledger counterparty resolver (Block 11 Phase 04) and are referenced as FK targets from `ledger_entries`. Sensitive fields — specifically `vat_number` — are encrypted at rest; the encryption scheme is defined in `counterparty_encryption_schema` (Layer 1). This sub-doc covers column-level semantics and the full table structure.

---

## Table definition

```sql
CREATE TABLE counterparties (
  counterparty_id              uuid              PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                  uuid              NOT NULL REFERENCES business_entities(id),
  normalised_name              text              NOT NULL,                        -- canonical form after normalisation; used as the lookup key
  display_name                 text              NOT NULL,                        -- human-readable form for UI surfaces
  vat_number                   text,                                              -- encrypted at rest; see counterparty_encryption_schema
  country_code                 char(2),                                           -- ISO 3166-1 alpha-2; nullable when country is unknown
  is_intraeu_supplier          boolean           NOT NULL DEFAULT false,          -- derived from country_code and vat_number presence; updated on write
  default_vat_treatment        vat_treatment_enum NOT NULL DEFAULT 'UNKNOWN',
  suggested_ledger_account_id  uuid              REFERENCES chart_of_accounts(id), -- nullable; set as ledger mappings mature
  transaction_count            integer           NOT NULL DEFAULT 0 CHECK (transaction_count >= 0), -- denormalised; updated on each transaction association
  created_at                   timestamptz       NOT NULL DEFAULT now(),
  updated_at                   timestamptz       NOT NULL DEFAULT now(),

  CONSTRAINT uq_counterparties_business_normalised_name
    UNIQUE (business_id, normalised_name)
);
```

### Column notes

- `counterparty_id` — UUID v7 per `data_layer_conventions_policy §2`.
- `business_id` — non-nullable. Counterparties are tenant-scoped. The same vendor may appear as distinct `counterparties` rows under different businesses with different `normalised_name` values if transaction description formatting varies across business bank accounts. RLS enforces tenant isolation.
- `normalised_name` — the canonical form of the vendor name after the normalisation pass (Block 11 Phase 04): lowercase, punctuation-stripped, whitespace-collapsed. This is the deduplication key — two transactions with different raw descriptions that normalise to the same string resolve to the same counterparty row. The unique constraint on `(business_id, normalised_name)` enforces this.
- `display_name` — the human-readable name presented in UI surfaces and exported documents. Initially set to the first raw vendor name observed for this normalised key; may be updated by an Owner or Admin through the counterparty management surface.
- `vat_number` — nullable text column. When populated, the value is encrypted at rest using the DEK hierarchy per `counterparty_encryption_schema`. The application layer decrypts on read for authorised roles only; encrypted bytes are stored in this column. A null value indicates the VAT number is unknown or not applicable for this counterparty. The VIES lookup (Block 11 Phase 06) may populate this field after a successful lookup.
- `country_code` — ISO 3166-1 alpha-2 country code. Nullable when the counterparty's country cannot be determined from the transaction data or VAT number. Derived from the `vat_number` prefix (EU VAT numbers begin with a 2-letter country code) or from the business address when available.
- `is_intraeu_supplier` — boolean derived field. Set to `true` when `country_code` is a EU member state (excluding Cyprus — domestic suppliers are `is_intraeu_supplier = false`) AND `vat_number` is non-null. Updated by the counterparty resolver on every write. This flag drives the `EU_REVERSE_CHARGE` VAT treatment candidate in Block 11 Phase 05.
- `default_vat_treatment` — the VAT treatment to apply to transactions from this counterparty when no transaction-level or rule-level override exists. Initial default: `UNKNOWN`. Updated by the VAT treatment classifier (Block 11 Phase 05) once sufficient signals are available. Drawn from the closed 8-value `vat_treatment_enum`.
- `suggested_ledger_account_id` — nullable FK to `chart_of_accounts.id`. Set as the ledger mapping layer (Block 11 Phase 07) learns which account is most frequently used for this counterparty's transactions. Used as a hint in the mapping resolution algorithm per `ledger_account_mapping_schema`.
- `transaction_count` — denormalised integer count of transactions associated with this counterparty. Incremented by the counterparty resolver on each new association. Used for UI ordering (frequent counterparties first) and for vendor memory confidence weighting. Updated in the same transaction as the association write.

---

## Normalised name derivation

The `normalised_name` column is the output of the same vendor-signature normalisation pass used by `vendor_memory_schema` (Block 08 Phase 03), applied to the raw counterparty name extracted from the transaction description. The steps are: lowercase, remove punctuation, collapse whitespace, strip merchant-prefix tokens. The result is the deduplication key for counterparty identity within a business.

Two transactions that produce the same `normalised_name` resolve to the same `counterparty_id`. Two transactions from what is semantically the same vendor but with different bank-formatted names (e.g., `AMAZON EU SARL` vs. `AMAZON PAYMENTS EUROPE`) will produce different `normalised_name` values and therefore different `counterparty_id` values. Counterparty aliasing — linking multiple `counterparty_id` rows that represent the same real-world entity — is a Stage 2 feature; MVP treats each distinct `normalised_name` as an independent counterparty.

The `display_name` is initially set to the first observed raw counterparty name string (un-normalised) for readability. Owners and Admins may update `display_name` via the counterparty management surface without affecting `normalised_name`. Updating `normalised_name` directly is not permitted after creation; it would break the deduplication invariant.

---

## `is_intraeu_supplier` derivation

The derivation rule applied by `ledger.resolve_counterparty` (Block 11 Phase 04):

```
is_intraeu_supplier = (
  country_code IS NOT NULL
  AND country_code != 'CY'                   -- Cyprus is domestic, not intra-EU
  AND country_code IN (eu_member_state_codes) -- closed list per EU membership at deploy time
  AND vat_number IS NOT NULL
)
```

The EU member state code list is a seeded constant table (`eu_member_states`) managed by Block 11 Phase 01. When a country joins or leaves the EU, the `eu_member_states` table is updated and affected counterparty rows are re-evaluated in the next classification run.

---

## `transaction_count` maintenance

The `transaction_count` column is a denormalised integer maintained by `ledger.resolve_counterparty` on each new transaction-to-counterparty association. The update is an atomic `UPDATE counterparties SET transaction_count = transaction_count + 1 WHERE counterparty_id = $1` executed in the same database transaction as the `ledger_entries` row insertion that references this counterparty.

This column must not be used as a transactional aggregate for financial reporting. It is a display hint for UI ordering and vendor memory weighting only. If the value drifts (e.g., due to a failed transaction that partially wrote a ledger entry), a background reconciliation scan can recompute it from `ledger_entries.counterparty_id`. The reconciliation procedure is defined in Block 11 Phase 04 and is triggered manually by operators; it does not run automatically in MVP.

---

## Encryption note

The `vat_number` column is subject to field-level encryption per `counterparty_encryption_schema`. The cipher text is stored in the column; the plaintext is accessible only through the decryption helper function available to authorised application-layer calls. The decryption event emits `FIELD_DECRYPTED` per `audit_log_policies`. This sub-doc does not reproduce the encryption scheme; refer to `counterparty_encryption_schema` for key hierarchy, rotation, and decryption surface.

---

## RLS

```sql
CREATE POLICY counterparties_isolation ON counterparties
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

---

## Indexes

```sql
-- Primary lookup: normalised name deduplication
CREATE UNIQUE INDEX idx_counterparties_business_name
  ON counterparties (business_id, normalised_name);

-- Intra-EU filter for VAT treatment classifier
CREATE INDEX idx_counterparties_intraeu
  ON counterparties (business_id, is_intraeu_supplier)
  WHERE is_intraeu_supplier = true;

-- Ledger account suggestion lookup
CREATE INDEX idx_counterparties_ledger_account
  ON counterparties (business_id, suggested_ledger_account_id)
  WHERE suggested_ledger_account_id IS NOT NULL;
```

---

## Mobile write rejection

`ledger.resolve_counterparty` is a server-side tool that creates and updates counterparty rows during the LEDGER workflow phase. Direct writes from mobile clients are rejected per `mobile_write_rejection_endpoints.md`. Display name updates, if exposed through a settings surface, also route through a server-side API endpoint.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `COUNTERPARTY_CREATED` | New `counterparties` row inserted by `ledger.resolve_counterparty` | LOW |
| `COUNTERPARTY_UPDATED` | Existing row updated — `default_vat_treatment`, `vat_number`, `display_name`, or `suggested_ledger_account_id` changed | LOW |

Both events are emitted via `emitAudit()` per `audit_log_policies`. The `COUNTERPARTY_CREATED` payload includes `counterparty_id`, `business_id`, `normalised_name`, `country_code`, and `is_intraeu_supplier`. The `COUNTERPARTY_UPDATED` payload includes the changed field names and their new values (not the raw encrypted `vat_number` — audit payloads for encrypted fields record only the field name and the fact of change, not the decrypted value). Existing taxonomy events `LEDGER_COUNTERPARTY_RESOLVED` and `LEDGER_COUNTERPARTY_UNRESOLVED` (Block 11) cover the resolver-level semantics; `COUNTERPARTY_CREATED` and `COUNTERPARTY_UPDATED` are the table-lifecycle events for this schema.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; normalised_name derivation follows canonical string conventions
- `counterparty_encryption_schema` (Block 05 / Block 11) — encryption scheme for `vat_number`; key hierarchy; decryption surface
- `vat_treatment_enum` — closed 8-value enum; `default_vat_treatment` values
- `ledger_account_mapping_schema` — `suggested_ledger_account_id` is used as a hint in the mapping resolution algorithm
- `audit_log_policies` — `COUNTERPARTY_*` domain (see audit_log_policies domain allowlist extension); `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `COUNTERPARTY_CREATED`, `COUNTERPARTY_UPDATED`, `LEDGER_COUNTERPARTY_RESOLVED`
- Block 11 Phase 04 — counterparty resolver; primary writer; `ledger.resolve_counterparty` tool
- Block 11 Phase 05 — VAT treatment classifier; reads `is_intraeu_supplier` and `default_vat_treatment`
- Block 11 Phase 06 — reverse charge and VIES relevance; may populate `vat_number` after VIES lookup
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
