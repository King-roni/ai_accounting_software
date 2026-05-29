# Fixtures: Bank Statement Pipeline

**Category:** Fixtures · Block 07 — Bank Statement Pipeline

---

## Purpose

Per-fixture test data for the bank statement parsing and deduplication pipeline. Each
fixture defines the raw input format, the expected `bank_statement_rows` output, the
expected deduplication outcome, and the assertion steps for the live integration test.

All fixtures are run as part of the `bank_statement_live_integration_runbook.md` test
suite before deploying pipeline changes.

---

## FIXTURE_BANK_REVOLUT_CLEAN

### Description

A standard Revolut CSV export with 5 rows. No duplicates. All transactions are in EUR.
Each row has a distinct counterparty.

### Raw Input Format

Revolut CSV, format spec: `csv_parser_revolut_format_spec.md`.
Columns: `Date`, `Description`, `Amount`, `Currency`, `Balance`.

```
Date,Description,Amount,Currency,Balance
2024-01-10,OFFICE SUPPLIES LTD,-120.00,EUR,4880.00
2024-01-11,CLIENT ALPHA PAYMENT,5000.00,EUR,9880.00
2024-01-12,INTERNET SERVICE PROVIDER,-49.00,EUR,9831.00
2024-01-13,FUEL STATION NICOSIA,-85.50,EUR,9745.50
2024-01-14,FREELANCER PAYMENT,-750.00,EUR,8995.50
```

### Expected bank_statement_rows Output

All 5 rows parsed. 0 rows skipped.

| field                       | row 1                  | row 2                   |
|-----------------------------|------------------------|-------------------------|
| dedup_status                | NEW                    | NEW                     |
| currency                    | EUR                    | EUR                     |
| fx_rate                     | null                   | null                    |
| counterparty_resolution_status | RESOLVED            | RESOLVED                |

Pattern applies to all 5 rows.

### Expected Deduplication Outcome

| rows_parsed | rows_skipped | duplicate_exact | duplicate_fuzzy |
|-------------|--------------|-----------------|-----------------|
| 5           | 0            | 0               | 0               |

### Assertion Steps

1. Upload fixture CSV via `intake.ingest_bank_statement`.
2. Assert `bank_statement_rows` count = 5 for the test business.
3. Assert all rows have `dedup_status = 'NEW'`.
4. Assert all rows have `currency = EUR` and `fx_rate IS NULL`.
5. Assert no `deduplication_fingerprints` collision records were created.

---

## FIXTURE_BANK_REVOLUT_DEDUP

### Description

A Revolut CSV with 6 rows where row 4 is an exact duplicate of row 2. Row 4 has the same
date, amount, description, and produces the same `raw_row_hash` as row 2.

### Raw Input Format

```
Date,Description,Amount,Currency,Balance
2024-01-10,OFFICE SUPPLIES LTD,-120.00,EUR,4880.00
2024-01-11,CLIENT ALPHA PAYMENT,5000.00,EUR,9880.00
2024-01-12,INTERNET SERVICE PROVIDER,-49.00,EUR,9831.00
2024-01-11,CLIENT ALPHA PAYMENT,5000.00,EUR,9880.00
2024-01-13,FUEL STATION NICOSIA,-85.50,EUR,9745.50
2024-01-14,FREELANCER PAYMENT,-750.00,EUR,8995.50
```

Row 4 is the duplicate of row 2. The `raw_row_hash` computed by the parser will be
identical for both rows (same date, amount, description, currency).

### Expected bank_statement_rows Output

5 rows inserted. 1 row skipped (row 4).

| field                | row 2 (original)  | row 4 (duplicate)   |
|----------------------|-------------------|---------------------|
| dedup_status         | NEW               | DUPLICATE_EXACT     |
| skipped              | false             | true                |

### Expected Deduplication Outcome

| rows_parsed | rows_skipped | duplicate_exact | duplicate_fuzzy |
|-------------|--------------|-----------------|-----------------|
| 5           | 1            | 1               | 0               |

### Assertion Steps

1. Upload fixture CSV via `intake.ingest_bank_statement`.
2. Assert `bank_statement_rows` count = 5 (skipped row not inserted).
3. Assert the `deduplication_fingerprints` table contains 1 record with
   `match_type = DUPLICATE_EXACT` referencing the original row 2.
4. Assert the skipped row is recorded in the ingest run summary with reason
   `DUPLICATE_EXACT`.
5. Assert no audit event `BANK_STATEMENT_ROWS_SKIPPED` exceeds severity LOW.

---

## FIXTURE_BANK_SEPA_XML

### Description

A SEPA XML pain.001 file with 3 transactions. One transaction is denominated in GBP
(non-EUR). The GBP transaction requires an FX rate lookup from `ecb_fx_rate_cache`.

### Raw Input Format

SEPA XML pain.001, format spec: `bank_format_sepa_spec.md`.

Transactions:
1. EUR 200.00 — vendor DE89370400440532013000
2. EUR 1500.00 — vendor NL91ABNA0417164300
3. GBP 350.00 — vendor GB29NWBK60161331926819

### Expected bank_statement_rows Output

3 rows parsed. 0 rows skipped.

| field          | row 1 (EUR)   | row 2 (EUR)   | row 3 (GBP)                         |
|----------------|---------------|---------------|-------------------------------------|
| currency       | EUR           | EUR           | GBP                                 |
| fx_rate        | null          | null          | populated from ecb_fx_rate_cache    |
| amount_eur     | 200.00        | 1500.00       | computed: 350.00 * fx_rate          |
| dedup_status   | NEW           | NEW           | NEW                                 |

### Expected Deduplication Outcome

| rows_parsed | rows_skipped | fx_converted |
|-------------|--------------|--------------|
| 3           | 0            | 1            |

### Assertion Steps

1. Seed `ecb_fx_rate_cache` with a GBP/EUR rate for the transaction date.
2. Upload fixture XML via `intake.ingest_bank_statement`.
3. Assert 3 rows in `bank_statement_rows`.
4. Assert row 3 has `currency = GBP`, `fx_rate IS NOT NULL`, and `amount_eur` equals
   `350.00 * fx_rate` (rounded to 2 decimal places).
5. Assert rows 1 and 2 have `fx_rate IS NULL`.

---

## FIXTURE_BANK_MT940

### Description

An MT940 file from a Cypriot bank with 4 rows. One row has an ambiguous counterparty
name that the counterparty resolver cannot confidently assign to a known counterparty.

### Raw Input Format

MT940 structured format. Cypriot bank header conventions apply.

Transactions:
1. EUR 2000.00 — counterparty "ALPHA BANK CY" (known, resolvable)
2. EUR 450.00 — counterparty "COSTA CONSTRUCTIONS" (known, resolvable)
3. EUR 1200.00 — counterparty "COSTA CONSTRUCTIONS" (same as row 2)
4. EUR 88.00 — counterparty "MISC VENDOR 2024 REF 447" (ambiguous; cannot be resolved)

### Expected bank_statement_rows Output

4 rows parsed. 0 rows skipped.

| field                           | rows 1-3    | row 4        |
|---------------------------------|-------------|--------------|
| dedup_status                    | NEW         | NEW          |
| counterparty_resolution_status  | RESOLVED    | UNRESOLVED   |
| counterparty_id                 | populated   | null         |

### Expected Deduplication Outcome

| rows_parsed | rows_skipped | unresolved_counterparties |
|-------------|--------------|---------------------------|
| 4           | 0            | 1                         |

### Assertion Steps

1. Upload fixture MT940 via `intake.ingest_bank_statement`.
2. Assert 4 rows in `bank_statement_rows`.
3. Assert rows 1, 2, 3 have `counterparty_resolution_status = RESOLVED` and
   `counterparty_id IS NOT NULL`.
4. Assert row 4 has `counterparty_resolution_status = UNRESOLVED` and
   `counterparty_id IS NULL`.
5. Assert row 4 appears in the run's unresolved counterparty report.
6. Assert no rows have `dedup_status != 'NEW'`.

---

## Cross-References

- `bank_statement_rows_schema.md` — table field definitions
- `deduplication_fingerprint_schema.md` — fingerprint and match_type definitions
- `csv_parser_revolut_format_spec.md` — Revolut CSV column mapping
- `bank_format_sepa_spec.md` — SEPA XML pain.001 parsing rules
- `counterparty_resolution_policy.md` — resolution confidence thresholds
- `bank_statement_live_integration_runbook.md` — test execution procedures
