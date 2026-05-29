# csv_parser_revolut_format_spec

**Category:** Reference data · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 07 Phase 02 — CSV parser framework; Revolut provider registration.

**Purpose:** Binding format specification for the Revolut-specific CSV parser. Documents column layout, date encoding, debit/credit conventions, state filtering rules, edge-case handling, and the three known header variants the parser must recognise. Every Revolut-format fixture and every code change to the Revolut parser validates against this spec.

---

## Column specification

A standard Revolut CSV export contains the following columns, left to right:

| Column | Type | Notes |
|---|---|---|
| `Type` | text | Transaction type as classified by Revolut (e.g., `TRANSFER`, `CARD_PAYMENT`, `TOPUP`, `EXCHANGE`, `FEE`). Preserved in `ParsedRow.raw`; not mapped to `transaction_type_enum`. |
| `Product` | text | Account product type (e.g., `Current`, `Savings`). Preserved in `ParsedRow.raw`; not used in downstream processing. |
| `Started Date` | text | The ISO 8601 datetime the transaction was initiated. Used to detect header variant (see below). |
| `Completed Date` | text | The ISO 8601 datetime the transaction was settled. This is the canonical date used to populate `parsed_date`. |
| `Description` | text | Human-readable transaction narrative. Maps to the `description` canonical column. |
| `Amount` | text | Signed decimal amount in the transaction currency. Negative = outflow; positive = inflow. Maps to the `amount` canonical column. |
| `Fee` | text | Fee amount charged by Revolut for the transaction. Always zero or a negative decimal. Recorded as a separate virtual transaction row (see Fee handling below). |
| `Currency` | text | ISO 4217 three-letter currency code for `Amount` and `Fee`. Maps to the `currency` canonical column. |
| `State` | text | Settlement state. Only `COMPLETED` rows are ingested (see State filtering below). |
| `Balance` | text | Account balance after this transaction, in the transaction currency. Maps to the `balance` canonical column. |

All columns are present in every known Revolut export. There are no optional columns; a file that omits any of these ten columns is rejected with `STATEMENT_FORMAT_REJECTED_UNSUPPORTED`.

---

## Date encoding

Revolut timestamps dates in both `Started Date` and `Completed Date` as ISO 8601 datetime strings in UTC:

```
YYYY-MM-DD HH:MM:SS
```

Example: `2026-03-15 09:12:04`

Key properties:
- No timezone suffix is present in the exported file. The values are UTC despite the absence of a `Z` suffix or explicit offset. The parser treats these values as UTC.
- The time component is preserved in `ParsedRow.raw` but is discarded when populating `parsed_date`. Only the date portion (`YYYY-MM-DD`) is stored.
- `Completed Date` is the canonical date. `Started Date` is preserved in `ParsedRow.raw` and surfaced in the deduplication fingerprint as a secondary signal when `Completed Date` values collide.
- Date strings that cannot be parsed per the above format cause a row-level parse error on that row; the file continues parsing.

---

## Header variants

Revolut has changed column names across export versions. The parser detects the variant from the header row before processing any data rows.

### Variant A — Current (2024–present)

```
Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance
```

Detection signal: header contains the literal string `Started Date`. This is the canonical variant. All 14 column names match the specification above exactly (case-sensitive match after whitespace trim).

### Variant B — Legacy (2022–2023)

```
Type,Product,Date,Description,Amount,Fee,Currency,State,Balance
```

Detection signal: header contains `Date` but not `Started Date`. In this variant the single `Date` column corresponds to the completed/settled date. `Started Date` is absent; the parser sets `parsed_date` from `Date` and records `started_date_raw = null` on the `ParsedRow`. `Balance` is also absent in many Variant B exports; the parser treats `Balance` as optional for this variant only.

### Variant C — Early (pre-2022)

```
Completed Date,Description,Paid Out (EUR),Paid In (EUR),Exchange Rate,Balance (EUR),Category
```

Detection signal: header contains `Paid Out (EUR)` or `Paid In (EUR)`. The parser reconstructs `Amount` by computing `(Paid In - Paid Out)` as a signed value. `Currency` is inferred as `EUR` from the column label. `Type`, `Product`, `Started Date`, `State`, and `Fee` are absent; the parser applies defaults: `State` is treated as `COMPLETED` for all rows (Variant C exports contained only settled transactions), and `Fee` is treated as `0.00`.

Detection priority: the parser checks for Variant C first (most distinct signal), then Variant A (`Started Date` present), then Variant B. If none of the three detection signals match, the file falls through to the generic CSV parser and is attempted under the alias resolution rules in `csv_parser_format_spec`.

---

## Debit/credit encoding

Revolut encodes transaction direction in the sign of the `Amount` field:

| Sign | Direction | Meaning |
|---|---|---|
| Negative (e.g., `-500.00`) | Outflow (debit) | Money left the account |
| Positive (e.g., `2000.00`) | Inflow (credit) | Money entered the account |

The `Fee` column is always zero (`0.00`) or negative (e.g., `-0.25`). A non-zero `Fee` value means Revolut charged the business for the transaction in addition to the main `Amount`.

### Fee handling

A non-zero `Fee` generates a synthetic additional row in `bank_statement_rows` immediately after the parent row:

- `description` = `"Revolut fee: {parent description}"` (truncated to 255 characters)
- `amount` = the `Fee` value (already negative, mapped directly)
- `parsed_date` = same as parent row's `parsed_date`
- `raw_currency` = same as parent row's `Currency`
- `Type` in `ParsedRow.raw` = `"FEE"` (synthetic value; not from the source file column)
- `parent_row_id` = `row_id` of the parent row (cross-reference stored in `ParsedRow.raw.fee_parent_row_id`)

Zero-amount fee rows (`Fee = 0.00` or `Fee = 0`) produce no synthetic row. The fee row shares the parent row's `Completed Date` and is therefore subject to the same state filter.

---

## State filtering

The `State` column controls which rows are ingested.

| State value | Action |
|---|---|
| `COMPLETED` | Row is parsed and promoted to `bank_statement_rows` |
| `PENDING` | Row is skipped; `BANK_UPLOAD_ROW_SKIPPED` audit event emitted |
| `REVERTED` | Row is skipped; `BANK_UPLOAD_ROW_SKIPPED` audit event emitted |
| `FAILED` | Row is skipped; `BANK_UPLOAD_ROW_SKIPPED` audit event emitted |

The `BANK_UPLOAD_ROW_SKIPPED` event payload includes: `upload_id`, `business_id`, `row_index`, `state_value`, `description_truncated` (first 80 chars), `amount_raw`. The skipped row is counted in a `skipped_row_count` field on the parse result (separate from `parse_error_count`). Skipped rows do not count toward `row_count_accepted` or `row_count_rejected`.

Variant C files (pre-2022) have no `State` column; all rows are treated as `COMPLETED` as noted above.

---

## Edge cases

### Zero-amount rows

A row where `Amount = 0.00` (or `Amount = 0`) and `Fee = 0.00` is a no-op transaction. These rows are parsed but flagged with `is_zero_amount = true` in `ParsedRow`. The downstream deduplication step drops zero-amount non-fee rows unless they carry a non-zero `Balance` delta, in which case they are preserved for balance-reconciliation purposes. Zero-amount fee rows (fee-only transactions) are handled as described in Fee handling above.

### Duplicate row detection

Duplicate detection uses a deduplication fingerprint derived from three fields:

```
fingerprint = SHA-256( canonical_json({
  "completed_date": "<YYYY-MM-DD>",
  "amount_minor_units": <integer>,
  "description_normalised": "<normalised description>"
}) )
```

Where `description_normalised` is the result of lowercasing, collapsing runs of whitespace, and stripping leading/trailing whitespace from the raw `Description` value.

When two rows in the same upload share the same fingerprint, the second row is flagged `is_duplicate = true` in `bank_statement_rows`. Duplicate rows are not promoted to `transactions`. The deduplication check also runs across previously-ingested rows for the same business and bank account (cross-upload dedup), using the `transactions.fingerprint` column.

### Multi-currency rows

When a row's `Currency` column contains a non-EUR code (e.g., `USD`, `GBP`, `CHF`), the row is parsed with `parsed_currency = <code>` and `parsed_amount_eur = null`. The `parsed_amount_eur` column is populated during the FX conversion step by `ledger.fetch_ecb_rate` using the ECB rate for the `Completed Date`. The full conversion pipeline is documented in `ecb_fx_rate_cache_reference`.

Conversion formula: `amount_eur = amount_foreign / rate_eur` where `rate_eur` is the ECB reference rate expressed as units of foreign currency per 1 EUR. Rounding is HALF_UP to 2 decimal places. Results are stored as `numeric(15,2)` — never as floats.

If no ECB rate exists for the currency (either because the currency is outside the ECB's 32-currency publication list or because no manual override is present), the transaction is flagged with a `LEDGER_CURRENCY_UNSUPPORTED` review issue and blocked from ledger entry until the issue is resolved.

---

## Audit events emitted by this parser

| Event | When | Severity |
|---|---|---|
| `BANK_UPLOAD_ROW_SKIPPED` | A row with `State` in `{PENDING, REVERTED, FAILED}` is encountered | LOW |
| `BANK_UPLOAD_PARSE_COMPLETED` | Parse completes successfully | LOW |
| `BANK_UPLOAD_PARSE_FAILED` | File-level parse error (format unrecognised or variant detection fails) | MEDIUM |

`BANK_UPLOAD_ROW_SKIPPED` is a per-row event emitted inside the parse loop. In files with many `PENDING` rows (e.g., an export taken mid-day), this event may fire many times. The parse result aggregates the total `skipped_row_count`; individual events are queryable via the audit log's `events_by_subject` pattern on `subject_id = upload_id`.

---

## Cross-references

- `csv_parser_format_spec` — generic CSV encoding, delimiter detection, amount parsing, and alias resolution rules that apply to all formats including Revolut
- `bank_statement_rows_schema` — the Processing-zone table that receives parsed Revolut rows; column definitions consumed by this parser
- `bank_upload_schema` — the `bank_uploads` table that tracks the source file and drives status transitions
- `ecb_fx_rate_cache_reference` — FX conversion pipeline for non-EUR Revolut transactions
- `audit_event_taxonomy` — `BANK_UPLOAD_ROW_SKIPPED`, `BANK_UPLOAD_PARSE_COMPLETED`, `BANK_UPLOAD_PARSE_FAILED`
- `data_layer_conventions_policy §1` — SHA-256 hex encoding for deduplication fingerprint
- `data_layer_conventions_policy §3` — integer minor units and `numeric(15,2)` for currency amounts; no float persistence
- Block 07 Phase 02 — CSV parser framework; Revolut provider registration and alias table
- Block 07 Phase 04 — row normalization phase that consumes `ParsedRow` output from this parser
