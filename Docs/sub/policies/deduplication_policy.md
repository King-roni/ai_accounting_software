# Deduplication Policy

**Category:** Policies · **Owning block:** 07 — Bank Statement Pipeline / 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

Binding rules for transaction deduplication during bank statement ingestion. Every tool in the intake and ingestion pipeline that writes to `transactions` must follow these rules. CI enforces that no insert path bypasses the fingerprint check.

---

## Purpose

Deduplication prevents the same bank statement row from being ingested twice, whether from a re-upload of the same file, an overlapping upload covering a shared date range, or a bug in the parser that emits a row more than once. There are two tiers of duplicate: HARD (reject the row) and SOFT (insert with a flag and raise a review issue).

The fingerprint is the sole mechanism for duplicate detection. No other heuristic (e.g. amount + date proximity) is used for deduplication. The scoring-based comparison used by the Matching Engine to link transactions to invoices is a separate system and must not be confused with deduplication.

---

## Fingerprint derivation

```
dedup_fingerprint = SHA-256(
  business_id                         ||
  value_date.toISOString()            ||   -- "YYYY-MM-DD"
  amount_eur.toFixed(2)               ||   -- e.g. "1200.00"; always two decimal places
  (counterparty_iban ?? '')           ||
  normalise(description_raw ?? '')
)
```

The result is encoded as a 64-character lowercase hex string and stored in `transactions.dedup_fingerprint`.

`normalise()` is defined as:

1. Lowercase the entire string.
2. Collapse all whitespace sequences (spaces, tabs, newlines) to a single ASCII space.
3. Strip all characters that are not in `[a-z0-9 ]` (remove punctuation, special characters).
4. Trim leading and trailing spaces.

`normalise("")` returns `""`. `normalise(null)` is not called; the caller substitutes `''` for null before calling normalise.

The concatenation uses `||` (string concatenation) with no separator between fields. This means field order is significant. The order is fixed as above and must not be changed without a migration that rehashes all existing fingerprints.

Hashing uses SHA-256 per `data_layer_conventions_policy`. Output encoding is hex (lowercase, 64 characters). No salt is applied; the fingerprint is deterministic across runs for the same input.

---

## HARD duplicate

A HARD duplicate occurs when a row being inserted has a `dedup_fingerprint` that already exists for the same `business_id` in the `transactions` table.

**Rule:** reject the second row. Do NOT insert it.

**Detection mechanism:** the UNIQUE index `idx_transactions_dedup_fingerprint ON transactions (business_id, dedup_fingerprint)` enforces this at the database layer. An insert that would violate the constraint is caught before the row reaches disk.

**Outcome:**
- The row is not inserted.
- `BANK_UPLOAD_ROW_SKIPPED` is emitted with `reason: "HARD_DUPLICATE"` and `row_index` identifying the position of the duplicate in the upload file.
- `BANK_UPLOAD_DEDUP_HARD_DUPLICATE_DETECTED` is emitted as a business-chain audit event with `upload_id`, `business_id`, `fingerprint`, `original_transaction_id` (the ID of the previously-inserted row with the same fingerprint), and `row_index`.
- The `bank_uploads.skipped_row_count` counter is incremented.

The second row is silently discarded at the application layer after the constraint violation is caught. No error is surfaced to the user for a HARD duplicate in isolation; the upload completes normally. If the entire upload produces zero new inserts (all rows are HARD duplicates), the upload transitions to `FULLY_DEDUPLICATED` status and a review issue is raised for operator awareness.

---

## SOFT duplicate

A SOFT duplicate occurs when the same fingerprint appears in a different bank upload for the same business — i.e., the `business_id` and `dedup_fingerprint` match, but the `bank_upload_id` differs from the existing row's `bank_upload_id`.

**Rule:** insert the row, but flag it.

The HARD duplicate check fires on the UNIQUE constraint `(business_id, dedup_fingerprint)`. Because both rows (old and new) have the same fingerprint and business, the UNIQUE constraint would block the second insert regardless of `bank_upload_id`. Therefore, SOFT duplicate detection must be performed as a pre-insert check at the application layer, before the database insert is attempted.

**Pre-insert check:** before inserting, query `transactions` for a row with `business_id = :business_id AND dedup_fingerprint = :fingerprint`. If a row exists:
- Check whether `bank_upload_id` of the existing row differs from the current upload's `bank_upload_id`.
- If yes → SOFT duplicate. Mark the in-memory row as `effective_match_status = DUPLICATE_PROBABLE` and proceed to insert.
- If the existing row belongs to the same upload → HARD duplicate (handled above; this should not be reached in normal flow, but is guarded against).

**Outcome for SOFT duplicate:**
- The row is inserted with `effective_match_status = DUPLICATE_PROBABLE`.
- `STATEMENT_DUPLICATE_DETECTED` review issue is raised with severity `MEDIUM`, referencing both the new transaction's ID and the original transaction's ID.
- No `BANK_UPLOAD_ROW_SKIPPED` event is emitted; the row was accepted.

Note: the UNIQUE constraint on `(business_id, dedup_fingerprint)` means only one row per fingerprint per business can exist in `transactions`. The SOFT duplicate scenario describes a case where the same fingerprint already exists from a prior upload session but has not yet been finalized; a truly identical row in a different upload at the same time would still be blocked by the constraint. In practice, SOFT duplicates arise from re-uploads of prior-period statements into a new run, not from concurrent inserts.

---

## Same-day tolerance

Two transactions with the same amount and the same counterparty IBAN on the same `value_date`, but with different `description_raw` values, are NOT duplicates.

This is intentional and correct. A business may legitimately pay the same vendor twice on the same day for two different invoices. The fingerprint includes `normalise(description_raw)`, which will differ when the descriptions differ (e.g. two different invoice references). Different fingerprints → no duplicate detection → both rows are inserted as `UNIQUE`.

This case must not be treated as a SOFT duplicate. Any change to the fingerprint derivation that would cause two legitimately distinct same-day, same-amount, same-vendor transactions to collide must be rejected.

---

## Re-upload idempotency

Re-uploading a previously processed bank statement (same file, same date range, same business) must produce exactly zero new inserts for rows already in the database. The HARD duplicate mechanism guarantees this: every row in the re-uploaded file will have a fingerprint that already exists in `transactions` for the business, and all rows will be skipped.

This property is a correctness guarantee, not a performance optimisation. Tests in the live integration runbook assert that a re-upload of a previously fully-processed statement results in `bank_uploads.new_row_count = 0` and `bank_uploads.skipped_row_count = (original row count)`.

---

## Overlapping upload windows

An overlapping upload occurs when a business uploads a bank statement covering a date range that partially overlaps with a range already ingested in the same or a prior run. For example: first upload covers January 1–31; second upload covers January 15 to February 28.

The deduplication engine handles this transparently. Rows from January 15–31 in the second upload will have fingerprints that match existing rows from the first upload. They are treated as HARD duplicates and skipped. Rows from February 1–28 are new and are inserted normally.

No special handling is required for overlapping windows beyond the standard HARD duplicate path. The parser does not need to detect or reject overlapping date ranges; the fingerprint mechanism alone provides the correct outcome.

The `bank_uploads.period_start` and `bank_uploads.period_end` fields record the declared date range of each upload. These are informational fields used for display and for the `STATEMENT_PARTIAL_UPLOAD_FLAGGED` review issue; they do not control deduplication behaviour.

---

## Deduplication and finalized periods

The deduplication fingerprint is computed the same way regardless of whether the transaction's period has been finalized. A row in a finalized period can still receive a HARD duplicate rejection on a re-upload attempt; the `transactions` row persists in the Operational zone after finalization and the UNIQUE index remains active.

Operators sometimes attempt to re-ingest a statement for a correction; this is the wrong approach for a finalized period. The correct path is an adjustment run (Block 03 Phase 11). The deduplication rejection for a finalized-period row does not distinguish between "row finalized" and "row in active run"; both produce the same HARD duplicate outcome.

---

## Audit events

| Event | Trigger | Severity |
|---|---|---|
| `BANK_UPLOAD_ROW_SKIPPED` | Emitted per skipped row (HARD duplicate) | LOW |
| `BANK_UPLOAD_DEDUP_HARD_DUPLICATE_DETECTED` | Emitted per HARD duplicate detection | LOW |
| `STATEMENT_DUPLICATE_DETECTED` | Review issue raised for SOFT duplicate | MEDIUM (review issue) |

`BANK_UPLOAD_DEDUP_HARD_DUPLICATE_DETECTED` payload: `upload_id`, `business_id`, `fingerprint` (hex), `original_transaction_id`, `row_index`.

---

## Cross-references

- `deduplication_fingerprint_schema.md` — detailed fingerprint field definitions and edge cases for null handling
- `transaction_schema.md` — `transactions` table DDL; `dedup_fingerprint` column; `effective_match_status` and `prior_match_status` columns; UNIQUE index definition
- `bank_upload_schema.md` — `bank_uploads` table; `skipped_row_count`, `new_row_count` counters; upload status transitions
- `bank_statement_rows_schema.md` — raw parsed row schema before fingerprint computation
