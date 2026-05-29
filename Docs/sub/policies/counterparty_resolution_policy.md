# Counterparty Resolution Policy

**Category:** Policies · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Defines how the ledger engine derives a canonical `counterparties` record from raw transaction data. The policy covers country code derivation from IBAN and BIC, name canonicalization for deduplication, VIES validation triggers, merge rules, and the placeholder path for unresolvable counterparties.

---

## Block reference

Block 11 — Ledger & Cyprus VAT. Counterparty resolution runs during the LEDGER phase via `ledger.resolve_counterparty`, before VAT treatment is assigned.

---

## Purpose

Raw bank transaction data contains free-text sender/receiver fields, IBANs, and BIC codes of varying quality. This policy standardises how a durable, deduplicated `counterparties` record is produced from that raw material, and specifies what happens when resolution cannot be completed.

---

## IBAN country derivation

The first two characters of an IBAN are the ISO 3166-1 alpha-2 country code.

- Extract characters 1–2 (1-indexed) from `transactions.raw_counterparty_iban`.
- Validate against the ISO 3166-1 alpha-2 allowlist maintained in the platform's country reference table.
- Store the result in `counterparties.country_code`.

If the IBAN passes the format check (`raw_counterparty_iban` matches the basic `^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$` pattern) but the two-character prefix is not in the ISO 3166-1 allowlist, the IBAN is treated as malformed and falls back to BIC derivation.

IBAN-derived `country_code` is preferred over BIC-derived `country_code` when both are present.

---

## BIC country derivation

When no valid IBAN is available, the country code is derived from the BIC/SWIFT code.

BIC structure: `[Bank Code 4][Country Code 2][Location Code 2][Branch Code 3 optional]`

Characters 5–6 of the BIC are the ISO 3166-1 alpha-2 country code.

- Extract characters 5–6 from `transactions.raw_counterparty_bic`.
- Validate against the ISO 3166-1 alpha-2 allowlist.
- Store in `counterparties.country_code` with `country_code_source = 'BIC'`.

If neither IBAN nor BIC yields a valid country code, `country_code` is left NULL and the counterparty is flagged for review (see Unresolvable counterparty section below).

---

## Name canonicalization

The canonical name is used as the primary deduplication signal alongside `country_code` and `iban`.

**Procedure:**

1. Take `transactions.raw_counterparty_name`.
2. Strip trailing and leading legal-entity suffixes and prefixes from the following set (case-insensitive):
   `Ltd`, `Limited`, `LLC`, `L.L.C.`, `GmbH`, `AG`, `SA`, `S.A.`, `NV`, `BV`, `B.V.`, `PLC`, `Corp`, `Corporation`, `Inc`, `Inc.`, `Incorporated`, `SRL`, `S.R.L.`, `SARL`, `S.A.R.L.`, `OÜ`, `AS`, `UAB`, `SIA`, `AB`, `Kft`, `Sp. z o.o.`
3. Lowercase the result.
4. Trim leading/trailing whitespace; collapse internal runs of whitespace to a single space.
5. Store in `counterparties.canonical_name`.

The original raw name is retained in `counterparties.raw_name` for reference. Canonicalization is a projection for dedup purposes — it does not affect displayed names, which use `raw_name`.

---

## VIES validation trigger

VIES validation is triggered when all three conditions are met:

1. `counterparties.country_code` is an EU member state code (see EU country code list in `client_vat_validation_policy.md`).
2. `counterparties.country_code` is NOT `CY` (Cyprus domestic counterparties are not subject to intra-EU VIES validation).
3. A VAT number is present on the counterparty record (`counterparties.vat_number` is non-null after extraction from the document or transaction data).

When triggered, `ledger.resolve_counterparty` calls the VIES SOAP API via the AI gateway EXTERNAL_CALL path. The result (valid/invalid, VAT number status, registered name) is stored in a new `vies_records` row.

**Cache behaviour:** if a `vies_records` row for the same `(vat_number, country_code)` pair exists and `cache_expires_at` is in the future, no new VIES call is made; the cached result is used. Default cache TTL is 30 days.

**VIES failure:** if the VIES call fails (see `VIES_LOOKUP_FAILED`), VAT treatment assignment is deferred. The counterparty is created without VIES validation; a review issue is created to prompt operator follow-up. Processing is not blocked — the run continues with a conservative VAT treatment placeholder.

---

## Deduplication rule

Two `counterparties` rows represent the same real-world counterparty if all three of the following match:

- `canonical_name` (exact match after canonicalization)
- `country_code` (exact match)
- `iban` (exact match, including NULL — two rows where both `iban` are NULL do not match on this criterion alone)

When a duplicate is detected during resolution:

1. The **older** record (the one with the smaller UUID v7, indicating earlier creation) is retained. Its `id` is kept.
2. The **newer** record's unique attributes (any additional `raw_name` variants, `bic` values, `vat_number` if not already present) are merged into the older record's data.
3. The newer record's row is deleted (hard delete — it has no ledger entries yet at merge time; if it does, the merge is deferred to a review issue instead).
4. `COUNTERPARTY_MERGED` is emitted with both `retained_counterparty_id` and `discarded_counterparty_id` in the payload.

If dedup is not possible at merge time (because the newer record already has associated ledger entries), a review issue is created and the two records coexist until a human resolves the conflict.

---

## Unresolvable counterparty

If, after exhausting IBAN derivation, BIC derivation, and name canonicalization, none of the following can be established:

- A valid `country_code`
- A valid `canonical_name` (non-empty after stripping)
- A recognisable `iban` or `bic`

...then a `COUNTERPARTY_PLACEHOLDER` record is created:

- `is_placeholder = TRUE`
- `canonical_name = NULL`
- `country_code = NULL`
- `iban = NULL`
- `raw_name` contains whatever text was present in `transactions.raw_counterparty_name`

The placeholder is immediately flagged in the review queue with issue type `COUNTERPARTY_UNRESOLVABLE`. Ledger entries for the transaction reference the placeholder `counterparty_id`; VAT treatment is set to `UNKNOWN` until the review is resolved.

`COUNTERPARTY_PLACEHOLDER_CREATED` is emitted on placeholder insertion.

---

## Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `COUNTERPARTY_RESOLVED` | LOW | A new `counterparties` row is created (non-placeholder) or an existing one is matched and used |
| `COUNTERPARTY_MERGED` | LOW | Dedup rule fires; two records are merged; older record retained |
| `COUNTERPARTY_PLACEHOLDER_CREATED` | MEDIUM | Resolution failed; placeholder record inserted and flagged for review |

`COUNTERPARTY_RESOLVED` payload: `counterparty_id`, `business_id`, `country_code`, `country_code_source` (`IBAN` or `BIC`), `canonical_name`, `is_intraeu_supplier`, `vies_triggered`, `run_id`.

`COUNTERPARTY_MERGED` payload: `retained_counterparty_id`, `discarded_counterparty_id`, `business_id`, `merge_reason`, `run_id`.

`COUNTERPARTY_PLACEHOLDER_CREATED` payload: `counterparty_id`, `business_id`, `raw_name`, `raw_iban`, `raw_bic`, `run_id`.

MEDIUM severity on `COUNTERPARTY_PLACEHOLDER_CREATED` because the transaction will carry an `UNKNOWN` VAT treatment until the review is resolved, which affects ledger accuracy.

---

## Cross-references

- `counterparty_schema.md` — full DDL for `counterparties` table including all columns and indexes
- `vies_record_schema.md` — DDL for `vies_records`; cache TTL; SOAP response field mapping
- `client_vat_validation_policy.md` — EU member state country code list; VAT number format rules; VIES validation gates for client-side VAT numbers
- Block 11 — Ledger & Cyprus VAT phase doc
- `data_layer_conventions_policy.md` — UUID v7 generation; canonical JSON
- `audit_log_policies.md` — `COUNTERPARTY` domain ownership
