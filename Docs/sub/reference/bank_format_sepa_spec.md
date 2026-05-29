# Bank Format — SEPA Credit Transfer CSV Specification

**Category:** Reference · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

Canonical column specification and parser rules for SEPA credit transfer CSV exports. This document is the binding reference for the SEPA CSV parser implementation in Block 07 Phase 02. Any change to parser behaviour that affects column mapping, date handling, amount sign convention, or header variant detection requires an amendment here before the implementation changes.

---

## Purpose

SEPA CSV exports from European banks follow a broadly consistent structure, but headers, delimiters, and column presence vary by bank. This document specifies the canonical column set, the two known header variants, and the parsing rules that apply uniformly regardless of variant. The Revolut Business SEPA export is the primary reference bank; its format is documented in detail in `csv_parser_revolut_format_spec.md`. This document covers the generic SEPA CSV layer that applies to all banks.

---

## Column specification

The following columns are defined for the canonical SEPA CSV format. All column names are matched case-insensitively and whitespace-trimmed after split.

| Column name | Required | Type | Notes |
|---|---|---|---|
| `Execution Date` | Yes | Date | The bank's execution date. Used as `booking_date` in `transactions`. |
| `Value Date` | Yes | Date | The value date for interest and settlement purposes. Used as `value_date` in `transactions`. |
| `Transaction Amount` | Yes | Decimal | Signed numeric; no currency symbol. See amount encoding below. |
| `Currency` | Yes | String | ISO 4217 three-character code (e.g. `EUR`, `USD`). |
| `Debtor/Creditor Name` | No | String | Counterparty name. Maps to `counterparty_name`. Nullable if absent or blank. |
| `Debtor/Creditor Account (IBAN)` | No | String | Counterparty IBAN. Maps to `counterparty_iban`. Nullable if absent or blank. |
| `BIC` | No | String | BIC/SWIFT code of the counterparty bank. Not persisted to `transactions`; used only for counterparty resolution in Block 11. |
| `Transaction Type` | Yes | String | Controlled vocabulary; see transaction type mapping table below. |
| `Remittance Information` | No | String | Free-text remittance field. Maps to `description_raw`. May contain invoice references; see reference hint extraction below. |
| `End to End ID` | No | String | SEPA end-to-end identifier. Present in Revolut Business exports; absent in generic bank exports. Its presence is the discriminator for header variant detection. |

---

## Date format

Dates in SEPA CSV exports use the European `DD/MM/YYYY` format. The parser must also accept `DD-MM-YYYY` (hyphen delimiter) because some banks emit hyphens when the user exports from a date picker with regional settings. No other date formats are accepted.

Parsing rules:

1. Split on `/` first; if the result is three parts of the expected lengths, parse as `DD/MM/YYYY`.
2. If the split on `/` does not produce a valid date, attempt split on `-`.
3. If neither split produces a valid date, the row is rejected with `BANK_UPLOAD_PARSE_FAILED` and a `row_parse_error` entry is appended to the `bank_upload_parse_errors` array.
4. The two-digit year format (`DD/MM/YY`) is not accepted. If a year value is less than 1000 after parsing, the row is rejected.

The parsed date is stored as an ISO 8601 `DATE` in Postgres (`YYYY-MM-DD`). The conversion is applied once in the parser; downstream consumers always receive ISO 8601 dates.

---

## Amount encoding

`Transaction Amount` is a signed decimal number. No currency symbol appears in the field. Positive values represent credits (inflows to the account). Negative values represent debits (outflows from the account). The sign convention follows the account holder's perspective, not the counterparty's.

Encoding rules:

- Decimal separator: `.` (period). The parser does not accept `,` (comma) as a decimal separator. Files with comma decimals are rejected at the format-detection step.
- Thousands separator: none. Files with comma thousands separators (e.g. `1,200.00`) are rejected; this is ambiguous with comma-decimal locales and the parser refuses to guess.
- Sign: explicit `-` prefix for debits. No `+` prefix for credits. `+1200.00` is rejected.
- The value is parsed into a `NUMERIC(15, 2)` Postgres column. Values exceeding 13 digits before the decimal point are rejected.

The parser stores the amount in `amount_eur` if the `Currency` column value is `EUR`. For non-EUR currencies, the original amount is stored in `original_amount` and `original_currency`; `amount_eur` is populated after FX conversion via the ECB rate pipeline (Block 11).

---

## Transaction type mapping

The `Transaction Type` column carries one of five controlled values. Unrecognised values map to `UNKNOWN` in `transaction_type_enum`; a `BANK_UPLOAD_ROW_SKIPPED` event is not emitted for unknown types (the row is ingested; only the type is degraded).

| CSV value | `transaction_type_enum` | Notes |
|---|---|---|
| `CREDIT TRANSFER` | `CREDIT_TRANSFER` | Standard SEPA credit transfer |
| `DIRECT DEBIT` | `DIRECT_DEBIT` | SEPA direct debit collection |
| `FEE` | `FEE` | Bank fee or service charge |
| `INTEREST` | `INTEREST` | Interest payment or receipt |
| `REVERSAL` | `REVERSAL` | Reversal of a prior transaction; see reversal handling below |

Values are matched case-insensitively.

---

## Header variant detection

Two header variants are recognised:

**Variant A — Generic SEPA CSV.** Contains all required columns plus optional columns. Does NOT contain `End to End ID`. The parser detects this variant when the header row does not include `End to End ID` (case-insensitive, whitespace-trimmed).

**Variant B — Revolut Business SEPA export.** Contains all Variant A columns plus `End to End ID`. The parser detects this variant by the presence of `End to End ID` in the header row. When Variant B is detected, the parser delegates to the Revolut-specific handling rules defined in `csv_parser_revolut_format_spec.md`, which include additional column mapping (`State`, `Balance`) and state-based row filtering (`PENDING`, `REVERTED`, `FAILED` rows are skipped).

Detection logic:

```
if header.includes("End to End ID") {
  parser_mode = REVOLUT_SEPA
} else {
  parser_mode = GENERIC_SEPA
}
```

No other variants are recognised in MVP. A file with an unrecognised header set is rejected with `STATEMENT_FORMAT_REJECTED_UNSUPPORTED`.

---

## Reference hint extraction from `Remittance Information`

The `Remittance Information` field (mapped to `description_raw`) may contain an invoice reference number embedded in the free-text by the payer. The parser applies a reference hint extractor after row normalisation.

Extraction pattern: a substring matching the regex `INV-\d{4}-\d{4,}` is extracted as a `reference_hint` string and passed to the Matching Engine alongside the transaction. Multiple matches in the same field produce an array; all matches are passed.

The `reference_hint` value is not stored in the `transactions` table. It is carried in the Processing zone scratch record and consumed by `matching.score_pair` as an additional scoring signal. If no match is found, `reference_hint` is `null`.

Extraction is best-effort. A row with no extractable reference hint is not rejected or flagged.

---

## Reversal handling

Rows with `Transaction Type = REVERSAL` require special handling:

1. The row is ingested normally and receives `transaction_type = REVERSAL` in `transactions`.
2. The deduplication fingerprint is computed from the reversed row's fields, not the original. Reversals are NOT automatically matched to their original transaction by the parser; that is the responsibility of the Matching Engine.
3. A compensating transaction record is created in the Processing zone scratch with `is_reversal = true` and a `reversal_hint` linking to any transaction in the same run whose amount is the sign-inverse and value date is within 5 days.
4. The compensating link is passed to the ledger phase as a candidate for `INTERNAL_TRANSFER_DETECTED`.

---

## File encoding and delimiter

SEPA CSV exports must be encoded in UTF-8 or UTF-8-BOM. The parser strips the BOM if present. Files in ISO-8859-1 (Latin-1) or Windows-1252 are not accepted in MVP; the upload is rejected with `STATEMENT_FORMAT_REJECTED_UNSUPPORTED` and the rejection reason identifies the detected encoding.

The field delimiter is `,` (comma). The parser does not accept semicolons, tabs, or pipes. Fields containing a comma must be quoted with `"` (double quote). Escaped double quotes inside a quoted field use the `""` convention (RFC 4180). A field that is quoted but empty (`""`) is treated as an empty string, which is then normalised to `null` for nullable columns.

Row terminator: `CRLF` (`\r\n`) or `LF` (`\n`). Mixed terminators within a file are accepted.

A trailing empty line at the end of the file is silently ignored.

---

## Row validation

Each row is validated after parsing and before deduplication. The following checks are applied in order:

1. **Column count.** The row must have the same number of fields as the header row. A row with fewer or more fields is rejected as a `ROW_COLUMN_COUNT_MISMATCH` parse error; it is skipped with a `BANK_UPLOAD_ROW_SKIPPED` event.
2. **Required fields non-empty.** `Execution Date`, `Value Date`, `Transaction Amount`, `Currency`, and `Transaction Type` must be non-empty after trimming. An empty required field produces a `ROW_REQUIRED_FIELD_MISSING` error.
3. **Date parseable.** Both date fields must pass the date parsing rules in the Date format section above.
4. **Amount parseable.** `Transaction Amount` must parse to a valid `NUMERIC(15, 2)` per the amount encoding rules. An unparseable amount produces a `ROW_AMOUNT_PARSE_FAILED` error.
5. **Currency code.** `Currency` must be a 3-character uppercase ISO 4217 code. Unknown codes are not rejected here; they are passed through and handled by the FX pipeline in Block 11. If the value is not 3 characters, the row is rejected.

Rows that fail validation are recorded in `bank_upload_parse_errors` (a JSONB array on the `bank_uploads` row) and counted in `bank_uploads.parse_error_count`. They do not block the rest of the file from being processed.

---

## Normalisation applied during parsing

Before inserting into the Processing zone scratch record, the parser applies the following normalisation steps to string fields:

- **Counterparty name.** Trim leading and trailing whitespace. Collapse internal whitespace sequences to a single space. No case normalisation; the raw-but-trimmed value is stored in `counterparty_name`. The ledger counterparty resolver applies further normalisation downstream.
- **Counterparty IBAN.** Uppercase, strip spaces. Validate the IBAN checksum per ISO 13616; if the checksum fails, store the value as-is in `counterparty_iban` and set a `COUNTERPARTY_IBAN_CHECKSUM_WARNING` flag on the Processing zone scratch record. The warning is not a rejection.
- **Description raw.** Trim leading and trailing whitespace. No other normalisation; the raw value is stored verbatim in `description_raw`.
- **Transaction type.** Uppercase and trim, then map to `transaction_type_enum` per the mapping table above.

---

## Cross-references

- `csv_parser_format_spec.md` — base CSV parsing rules (delimiter detection, encoding, error taxonomy)
- `csv_parser_revolut_format_spec.md` — Revolut Business SEPA export specifics (Variant B, state column filtering, `End to End ID` usage)
- `bank_statement_rows_schema.md` — raw parsed row schema; field-level mapping from CSV columns to schema columns
- `transaction_schema.md` — `transactions` table DDL; the destination table for normalised and zone-promoted rows
