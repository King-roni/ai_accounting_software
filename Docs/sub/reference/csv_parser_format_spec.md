# csv_parser_format_spec

**Category:** Reference data · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the canonical CSV format specification for bank statement imports. It is the binding reference for the CSV parser registered in Block 07 Phase 02's parser framework. Every new `(provider, CSV)` parser must be validated against this spec. Deviations from the spec require a `decisions_log.md` amendment naming the specific parser and the deviation scope.

---

## Encoding

- **Required encoding:** UTF-8.
- **BOM handling:** UTF-8 BOM (`EF BB BF`) is stripped silently before parsing begins. No other BOM variant is accepted; files with a UTF-16 or UTF-32 BOM are rejected with `STATEMENT_FORMAT_REJECTED_UNSUPPORTED`.
- **Line endings:** `CRLF` and `LF` are both accepted; `CR`-only line endings are normalised to `LF` before parsing.
- **Files containing non-UTF-8 byte sequences** (after BOM strip) are rejected immediately with `STATEMENT_PARSER_FAILED`.

---

## Delimiter detection

The parser auto-detects the delimiter from the first (header) row using the following priority order:

| Priority | Delimiter | Rationale |
|---|---|---|
| 1 | Comma (`,`) | Most common; Revolut default |
| 2 | Semicolon (`;`) | Common in European bank exports (decimal comma regions) |
| 3 | Tab (`\t`) | Used by some traditional banks' export formats |

Detection algorithm: the first header row is examined for each delimiter in priority order. The delimiter that produces the most consistent column count across the first five data rows wins. If no delimiter produces a consistent count ≥ 3 columns, the file is rejected with `STATEMENT_FORMAT_REJECTED_UNSUPPORTED`.

Tab-delimited files with a `.csv` extension are accepted. Files with a `.tsv` extension are accepted only if the tab delimiter is detected.

---

## Header row

A header row is **required**. Files with no header row are rejected with `STATEMENT_PARSER_FAILED` and a clear message.

Header field names are matched case-insensitively after trimming leading and trailing whitespace. Canonical column name aliases are resolved per the per-bank alias table maintained in Block 07 Phase 02. Examples of canonical aliases:

| Canonical name | Accepted aliases |
|---|---|
| `date` | `Date`, `Transaction Date`, `Completed Date`, `Started Date`, `Value Date` |
| `amount` | `Amount`, `Debit/Credit`, `Transaction Amount` |
| `description` | `Description`, `Reference`, `Memo`, `Narrative`, `Details` |
| `balance` | `Balance`, `Running Balance`, `Account Balance` |
| `reference` | `Reference`, `Transaction Reference`, `Payment Reference` |
| `currency` | `Currency`, `Transaction Currency`, `CCY` |

The alias resolution is per-provider. Provider-specific alias tables are registered alongside the provider's parser and validated against this canonical name set.

---

## Mandatory columns

The following columns must be present and parseable. A file missing any mandatory column is rejected with `STATEMENT_PARSER_FAILED`:

| Column | Type after parsing | Notes |
|---|---|---|
| `date` | `date` (ISO 8601 `YYYY-MM-DD`) | Parsed via date format rules below |
| `amount` | `integer` (minor units) | Parsed via amount rules below |
| `description` | `text` | Trimmed; empty string allowed (not null) |

---

## Optional columns

Optional columns, when present, are parsed as follows:

| Column | Type after parsing | Absent behaviour |
|---|---|---|
| `balance` | `integer` (minor units) or null | Omitted from `ParsedRow` if column absent |
| `reference` | `text` or null | Omitted from `ParsedRow` if column absent |
| `currency` | `text` (ISO 4217 3-letter code) | Defaults to `EUR` when column absent or cell empty |

---

## Date format parsing rules

Dates are parsed in the following order of preference. The first pattern that produces a valid calendar date wins:

| Priority | Pattern | Example |
|---|---|---|
| 1 | ISO 8601: `YYYY-MM-DD` | `2026-03-15` |
| 2 | ISO 8601 with time: `YYYY-MM-DD HH:MM:SS` | `2026-03-15 14:30:00` |
| 3 | ISO 8601 with timezone: `YYYY-MM-DDTHH:MM:SSZ` | `2026-03-15T14:30:00Z` |
| 4 | Day/Month/Year: `DD/MM/YYYY` | `15/03/2026` |
| 5 | Month/Day/Year: `MM/DD/YYYY` | `03/15/2026` |
| 6 | Day-Month-Year: `DD-MM-YYYY` | `15-03-2026` |

When patterns 4 and 5 are ambiguous (e.g., `01/02/2026` — could be 1 Feb or 2 Jan), pattern 4 (`DD/MM/YYYY`) takes precedence. The parser emits a structured warning in the parse result for any row where ambiguity was resolved.

Dates with year < 2000 or year > 2099 are rejected as `STATEMENT_PARSER_FAILED` at the row level (emitted as a row-level parse error, not a file-level failure).

---

## Amount parsing rules

### Decimal separator

- `.` (full stop) is the preferred decimal separator.
- `,` (comma) is accepted as a decimal separator and normalised to `.` before numeric conversion.
- When both `.` and `,` appear in the same amount string, the rightmost separator is treated as the decimal separator (e.g., `1.234,56` → `1234.56`; `1,234.56` → `1234.56`).

### Negative amounts

Negative amounts (debits / outgoing transactions) are represented as either:

- Leading minus: `-123.45`
- Parentheses notation: `(123.45)` — normalised to `-123.45` before conversion.

### Minor-unit conversion

After parsing, the decimal amount is converted to integer minor units (cents for EUR). The conversion uses `round(amount * 100)` with ties-to-even rounding. Non-EUR currencies with different minor-unit scales (e.g., JPY has zero minor units) are handled per the ISO 4217 minor-unit scale for the detected currency.

### Currency amounts are never stored as floats

Per `data_layer_conventions_policy §3` currency special case, parsed amounts are stored as integer minor units. Floating-point intermediate representations are not persisted.

---

## Multi-currency handling

When the `currency` column is absent or all cells in the `currency` column are empty, all rows default to `EUR`.

When the `currency` column is present and a row contains a non-EUR currency code, the `currency` field in `ParsedRow` is set to that code. The matching engine and ledger layer handle FX conversion; the CSV parser does not apply any conversion.

Invalid currency codes (not in ISO 4217) trigger a row-level parse error for that row. The row is not inserted into `transactions`; the error is included in the parse result's `parse_errors` array.

---

## Row handling rules

| Condition | Behaviour |
|---|---|
| Empty row (all cells blank or row is blank) | Skipped silently; not counted in `row_count_accepted` or `row_count_rejected` |
| Header row | Consumed as column definitions; not emitted as a `ParsedRow` |
| Row with all mandatory columns present and parseable | Emitted as a `ParsedRow`; counted in `row_count_accepted` |
| Row with one or more mandatory columns missing or unparseable | Emitted as a row-level parse error; counted in `row_count_rejected` |
| Maximum row count: 100,000 rows per file | Files exceeding this limit are rejected with `STATEMENT_PARTIAL_UPLOAD_FLAGGED` |

---

## Worked example

Raw CSV input (Revolut-style, comma-delimited, UTF-8):

```
Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance
TRANSFER,Current,2026-03-01 09:12:00,2026-03-01 09:12:04,Payment to supplier,-500.00,0.00,EUR,COMPLETED,4500.00
TOPUP,Current,2026-03-02 11:00:00,2026-03-02 11:00:03,Top-Up by Jane Doe,2000.00,0.00,EUR,COMPLETED,6500.00
CARD_PAYMENT,Current,2026-03-03 14:22:11,2026-03-03 14:22:15,Amazon Web Services,-89.99,0.00,USD,COMPLETED,6410.01
,,,,,,,,,
```

Parsed output (after alias resolution and normalization):

| `date` | `amount` (minor units) | `description` | `currency` | `balance` (minor units) | `reference` |
|---|---|---|---|---|---|
| `2026-03-01` | `-50000` | `Payment to supplier` | `EUR` | `450000` | null |
| `2026-03-02` | `200000` | `Top-Up by Jane Doe` | `EUR` | `650000` | null |
| `2026-03-03` | `-8999` | `Amazon Web Services` | `USD` | `641001` | null |

Row 4 (blank row) — skipped silently.

Notes on the example:
- `Started Date` resolves to the `date` canonical alias via the Revolut provider alias table.
- `Amount` is the canonical alias; `Fee` is a provider-specific column, preserved in `raw` fields.
- USD row: `currency = USD`, `amount = -8999` (89.99 × 100, rounded).
- `State` and `Product` are preserved as provider-native fields in `ParsedRow.raw`; they do not map to any canonical column.

---

## Cross-references

- `audit_log_policies` — `STATEMENT_*` and `INTAKE_*` domains; audit events emitted on parse failure
- `audit_event_taxonomy` — `STATEMENT_PARSER_FAILED`, `STATEMENT_FORMAT_REJECTED_UNSUPPORTED`, `STATEMENT_UPLOAD_COMPLETED`
- `deduplication_fingerprint_schema` — the parsed `amount` (minor units) and `date` feed the fingerprint hash after normalization
- `data_layer_conventions_policy §3` — integer minor units for currency amounts; no floating-point persistence
- Block 07 Phase 02 — CSV parser and Revolut format; parser framework registration
- Block 07 Phase 04 — row normalization that follows parsing; consumes `ParsedRow` output
- `tool_naming_convention_policy` — `intake.*` namespace for all tools referencing this spec
