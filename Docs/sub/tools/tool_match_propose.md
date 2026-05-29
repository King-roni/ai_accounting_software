# Tool: matching.propose

**Category:** Tools · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

Proposes a match between a bank transaction and one or more invoices or ledger entries. The tool
computes match signals for each candidate, assigns a match level, and writes a match_records row.
If the composite score meets the auto-confirmation threshold, the match is confirmed in the same
write transaction without a separate PROPOSED record.

---

## Identity

| Field | Value |
| --- | --- |
| Tool name | `matching.propose` |
| Side effect class | WRITES_RUN_STATE, WRITES_AUDIT |
| Idempotent | Yes — same idempotency_key returns the existing match_record_id |
| Mobile write policy | REJECTED — mobile clients cannot call `matching.propose` |

Mobile rejection: any call where `client_form_factor = MOBILE` is rejected before signal
computation begins. The response is HTTP 403 with audit event MOBILE_WRITE_REJECTED. See
mobile_write_rejection_endpoints.md.

---

## Input schema

```
{
  transaction_id:              uuid,          -- required; the bank_statement_row being matched
  run_id:                      uuid,          -- required; the IN workflow run context
  candidate_invoice_ids:       uuid[],        -- optional; invoices to score against
  candidate_ledger_entry_ids:  uuid[],        -- optional; ledger entries to score against
  signal_overrides:            object | null, -- optional; pins specific signal scores (test use only)
  idempotency_key:             string         -- required; caller-supplied, max 128 chars
}
```

At least one of `candidate_invoice_ids` or `candidate_ledger_entry_ids` must be non-empty.
Passing both is valid; all candidates are scored independently.

`signal_overrides` is accepted only when the workflow run is in a test fixture context
(`run.is_fixture = true`). In production, a non-null `signal_overrides` with `run.is_fixture = false`
returns HTTP 422 with error code `SIGNAL_OVERRIDE_DISALLOWED_IN_PRODUCTION`.

UUIDs for `transaction_id`, `run_id`, `candidate_invoice_ids`, and `candidate_ledger_entry_ids`
are all `gen_uuid_v7()` PKs on their respective tables.

---

## Signal computation

For each candidate, the following match signals are computed:

| Signal | Description | Score range |
| --- | --- | --- |
| `amount_delta_score` | Closeness of candidate amount to transaction amount | 0.00–1.00 |
| `date_proximity_score` | Calendar distance between transaction date and candidate date | 0.00–1.00 |
| `counterparty_match_score` | String similarity between resolved counterparty and candidate client | 0.00–1.00 |
| `reference_string_match_score` | Substring or fuzzy match of invoice number in bank description | 0.00–1.00 |

Signal weights are read from match_signal_weights.md at runtime. Weights sum to 1.0.

Composite score formula:
  composite_score = sum(signal_score_i * weight_i) for all signals i

If `signal_overrides` is provided (test fixture context), the overridden signal scores replace
computed values before the weighted sum is calculated.

---

## Match level assignment

The composite score is mapped to a `match_level_enum` value per the thresholds defined in
matching_policy.md. The thresholds as of MVP:

| Composite score range | match_level |
| --- | --- |
| >= 0.95 | EXACT |
| 0.75 – 0.94 | STRONG_PROBABLE |
| 0.50 – 0.74 | WEAK_POSSIBLE |
| < 0.50 | NO_MATCH |

Thresholds are configuration values read from matching_policy.md; they are not hardcoded in the
tool implementation.

---

## Proposal record write

One `match_records` row is written per call per candidate that produces a score >= 0.50
(NO_MATCH candidates do not produce a record).

If a prior PROPOSED record exists for the same `transaction_id` (any candidate), its status is
set to SUPERSEDED and `superseded_at` is set to the current timestamp. The new record becomes
the active proposal.

The SUPERSEDED write and the new PROPOSED insert occur in the same database transaction.
If the transaction aborts, no state changes persist.

Fields written to `match_records`:

| Field | Value |
| --- | --- |
| match_record_id | gen_uuid_v7() |
| transaction_id | from input |
| run_id | from input |
| matched_invoice_id | from candidate (nullable if candidate is a ledger entry) |
| matched_ledger_entry_id | from candidate (nullable if candidate is an invoice) |
| match_level | assigned enum value |
| composite_score | computed numeric, 4 decimal places |
| status | PROPOSED (or CONFIRMED — see auto-confirmation below) |
| signal_scores | JSONB of individual signal scores and weights |
| proposed_at | current timestamptz |

---

## Auto-confirmation

If `match_level = EXACT` AND `composite_score >= 0.95`, the proposal is immediately confirmed in
the same write transaction:

- No PROPOSED record is created.
- The `match_records` row is written with `status = CONFIRMED`, `confirmed_at` set, and
  `confirmed_by_user_id = NULL` (system confirmation), `confirmation_method = AUTO_THRESHOLD`.
- The transaction's `effective_match_status` column is updated to EXACT.
- If the matched invoice is fully covered (sum of confirmed matches >= invoice.total_amount - 0.01),
  invoice status transitions to PAID in the same transaction.
- Audit event MATCHING_AUTO_CONFIRMED (LOW) is emitted in addition to MATCH_PROPOSED (LOW).

When `auto_confirmed = true` in the output, the caller should not call `matching.confirm` for the
same match_record_id; the record is already in CONFIRMED status.

---

## Output schema

```
{
  match_record_id:  uuid,    -- the written match_records PK
  match_level:      text,    -- EXACT | STRONG_PROBABLE | WEAK_POSSIBLE
  composite_score:  numeric, -- 4 decimal places
  auto_confirmed:   boolean  -- true if auto-confirmation path was taken
}
```

If multiple candidates were scored, the output contains the highest-scoring candidate that
produced a record. All scored candidates' records are written; only the best is returned in the
primary output. A `candidate_results` array field may be added in a future amendment.

---

## Idempotency

If a call is made with a previously used `idempotency_key`, the tool returns the existing output
without recomputing signals or writing new rows. The idempotency window is 24 hours.

---

## Audit events

| Event | Severity | Emitted when |
| --- | --- | --- |
| MATCH_PROPOSED | LOW | A PROPOSED record is written |
| MATCHING_AUTO_CONFIRMED | LOW | Auto-confirmation path is taken |

Both events carry: `match_record_id`, `transaction_id`, `run_id`, `match_level`, `composite_score`.

---

## Error conditions

| Code | HTTP | Condition |
| --- | --- | --- |
| TRANSACTION_NOT_FOUND | 404 | transaction_id does not exist in the run's business |
| NO_CANDIDATES_PROVIDED | 422 | Both candidate arrays are empty or null |
| SIGNAL_OVERRIDE_DISALLOWED_IN_PRODUCTION | 422 | signal_overrides non-null in non-fixture run |
| MOBILE_WRITE_REJECTED | 403 | client_form_factor = MOBILE |
| IDEMPOTENCY_KEY_CONFLICT | 409 | Same key used with different input parameters |

---

## Cross-references

- match_record_schema.md — match_records table structure and status enum
- matching_policy.md — match level thresholds, confirmation rules
- match_signal_weights.md — signal weight configuration
- match_level_enum.md — match_level_enum values
- mobile_write_rejection_endpoints.md — mobile rejection policy

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.