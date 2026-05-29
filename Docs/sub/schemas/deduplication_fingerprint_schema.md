# deduplication_fingerprint_schema

**Category:** Schemas · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

This sub-doc specifies the two complementary deduplication mechanisms operating on the `transactions` table: hard deduplication via `source_row_hash` (exact-match, row-level identity) and soft deduplication via `fingerprint` (semantic-match, surface-as-review). Together they prevent duplicate transaction rows from appearing in the operational database regardless of whether a statement is re-uploaded verbatim or uploaded with minor rendering differences. Both mechanisms use SHA-256 hex per `data_layer_conventions_policy`.

---

## Mechanism 1 — Hard deduplication (`source_row_hash`)

### Hash construction

`source_row_hash` is the SHA-256 hex digest of the canonical JSON serialization of the raw parsed row, before any normalization. The input object contains all fields as they appear in the original file, keyed by their raw column names after a lowercase-trim pass. Serialization follows RFC 8785 (JCS) per `data_layer_conventions_policy §3`.

```
source_row_hash = sha256_hex(canonical_json({
  "raw_date": "<string as parsed>",
  "raw_amount": "<string as parsed>",
  "raw_description": "<string as parsed>",
  "raw_reference": "<string as parsed | null>",
  "raw_balance": "<string as parsed | null>",
  ... (all other raw columns, keys sorted lexically)
}))
```

Floating-point amounts are serialized as their original string representation from the file, not re-encoded as JSON numbers, to avoid IEEE 754 rounding drift between the compute and storage path.

### Uniqueness enforcement

```sql
CREATE UNIQUE INDEX idx_transactions_hard_dedup
  ON transactions (bank_account_id, source_row_hash)
  WHERE dedup_status != 'SOFT_DUPLICATE';
```

The partial index excludes `SOFT_DUPLICATE` rows to avoid blocking insertion when a soft-duplicate row is manually confirmed as new by a reviewer (the confirmed row carries a distinct `source_row_hash` by definition; the index still holds).

### Rejection semantics

When the dedup engine queries `(bank_account_id, source_row_hash)` and finds an existing row:
- The incoming row is marked `HARD_DUPLICATE` (maps to `dedup_status = 'DUPLICATE_EXACT'` on `transactions`).
- The row is not inserted into `transactions`.
- The `bank_statement_uploads.row_count_accepted` is not incremented for this row.
- `STATEMENT_DEDUP_HARD_DUPLICATE_DETECTED` is emitted with `{ source_row_hash, existing_transaction_id, upload_id, row_index }`.

Hard duplicates are silent rejections — no review issue is raised. The hash identity is proof the row is identical; no human review is needed.

---

## Mechanism 2 — Soft deduplication (`fingerprint`)

### Hash construction

`fingerprint` is the SHA-256 hex digest of the canonical JSON serialization of a normalized four-field tuple:

```
fingerprint = sha256_hex(canonical_json({
  "account_id": "<bank_account_id as UUID string>",
  "amount_signed": <integer minor units — same sign convention as transactions.amount_signed>,
  "date": "<YYYY-MM-DD>",
  "normalized_description": "<normalized per Block 07 Phase 04 normalization rules>"
}))
```

Key ordering is fixed (RFC 8785 lexical sort: `account_id`, `amount_signed`, `date`, `normalized_description`). Currency amounts use integer minor units per `data_layer_conventions_policy §3` currency special case. The `normalized_description` is the post-normalization form — whitespace-collapsed, merchant-prefix-stripped per Block 07 Phase 04.

### Index

```sql
CREATE INDEX idx_transactions_soft_dedup
  ON transactions (bank_account_id, fingerprint);
```

Non-unique. Multiple rows may share a `fingerprint` when legitimate recurring transactions have identical normalized attributes (e.g., monthly standing-order payments of the same amount to the same payee). The index is used for lookup-and-compare, not for unique enforcement.

### Soft-match query

The dedup engine queries:

```sql
SELECT transaction_id, transaction_date, dedup_status
FROM transactions
WHERE bank_account_id = $1
  AND fingerprint = $2
  AND transaction_date BETWEEN $3 AND $4
  AND dedup_status NOT IN ('SOFT_DUPLICATE', 'DUPLICATE_EXACT')
```

where `$3` = `incoming_date - date_window_days` and `$4` = `incoming_date + date_window_days`.

### Date-window tolerance

| Setting | Default value | Scope |
|---|---|---|
| `date_window_days` | 3 (±3 days) | System-wide default |
| Per-business override | Configurable via `business_dedup_config` | Per-business override table (Block 07 Phase 05) |

The window is symmetric around the incoming row's date. Only the date field is windowed; amount must match exactly (see below).

### Amount tolerance

Amount matching is exact: `amount_signed` in the fingerprint is compared as an integer minor-unit value. No fuzzy amount tolerance is applied at the soft-dedup layer. The rationale: small rounding differences (±1 cent) are caught by the hard-dedup `source_row_hash` only when the raw string also differs — if the raw string matches, the hard-dedup fires; if it differs by a rounding variant, the soft-dedup fingerprint will differ by the same cent and will not collide. Fuzzy amount matching at the soft layer produced unacceptable false-positive rates in design review.

### Soft-duplicate semantics

When the soft-match query returns a candidate row:
- The incoming row is inserted into `transactions` with `dedup_status = 'DUPLICATE_PROBABLE'` (mapped from `SOFT_DUPLICATE` in the conceptual model).
- A `review_issues` row is created with `issue_type = 'bank_pipeline.soft_duplicate_flagged'`, `issue_group = 'Possible Wrong Match'`, severity `MEDIUM`.
- `STATEMENT_DEDUP_SOFT_DUPLICATE_FLAGGED` is emitted with `{ fingerprint, incoming_transaction_id, candidate_transaction_id, date_delta_days, upload_id }`.
- The user's resolution options: confirm-as-new (row stays with `dedup_status = 'NEW'`), mark-as-duplicate (row removed), or edit-and-confirm.

---

## `dedup_status` conceptual outcomes

<!-- Authoritative DDL for dedup_status_enum: transactions_schema.md -->
<!-- The three conceptual outcomes below (dedup_policy_outcome) map to the operational enum defined there. -->

This sub-doc defines the conceptual three-value policy outcome (`dedup_policy_outcome`). The `transactions` table (per `transactions_schema`) uses a slightly extended operational form (`NEW`, `DUPLICATE_EXACT`, `DUPLICATE_PROBABLE`, `NEEDS_REVIEW`) for granularity. The mapping is:

| Conceptual value (this sub-doc) | Operational value (`transactions.dedup_status`) |
|---|---|
| `ACCEPTED` | `NEW` |
| `HARD_DUPLICATE` | `DUPLICATE_EXACT` |
| `SOFT_DUPLICATE` | `DUPLICATE_PROBABLE` |

`NEEDS_REVIEW` in `transactions_schema` represents ambiguous cases (fingerprint matches but outside the date window, or a hard-dedup collision detected within-batch before DB insertion) and is surfaced to the review queue similarly to `SOFT_DUPLICATE`.

---

## Within-batch deduplication

The dedup engine processes all rows from a single `statement_upload_id` as one batch. Within-batch hard duplicates (the same raw row appearing twice in the same file) are detected before any DB write: the engine builds an in-memory set of `source_row_hash` values for the current batch and rejects second-occurrence rows as `HARD_DUPLICATE` before the batch insert.

Within-batch soft duplicates (same fingerprint, same date window, different raw row) are flagged as `SOFT_DUPLICATE` for user review.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `STATEMENT_DEDUP_HARD_DUPLICATE_DETECTED` | Hard-dedup match found; row rejected | LOW |
| `STATEMENT_DEDUP_SOFT_DUPLICATE_FLAGGED` | Soft-dedup match found; row inserted as `DUPLICATE_PROBABLE`; review issue raised | MEDIUM |

Both events are emitted via `emitAudit()` per `audit_log_policies` and exist in `audit_event_taxonomy`.

---

## Cross-references

- `data_layer_conventions_policy` — SHA-256 hex encoding for both hash columns; canonical JSON (RFC 8785) for hash inputs; integer minor units for currency in fingerprint
- `audit_log_policies` — `STATEMENT_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `STATEMENT_DEDUP_HARD_DUPLICATE_DETECTED`, `STATEMENT_DEDUP_SOFT_DUPLICATE_FLAGGED`
- `bank_upload_status_transitions_schema` — upload-level status that this dedup pass drives toward `DEDUPLICATION_COMPLETE`
- `transactions_schema` — canonical `transactions` table; `source_row_hash`, `fingerprint`, `dedup_status` columns
- Block 07 Phase 04 — normalization rules that produce `normalized_description` (fingerprint input)
- Block 07 Phase 05 — deduplication engine architecture and `STATEMENT_DEDUP_BATCH_COMPLETED` aggregate event
- `tool_naming_convention_policy` — `intake.*` namespace for all tools referencing this schema
