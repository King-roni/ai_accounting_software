# Tool: ledger.post

**Category:** Tools · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Posts a double-entry ledger transaction by writing exactly one debit and one credit `ledger_entries` row within a single database transaction. If either write fails, both are rolled back. This tool is server-side only; mobile clients cannot call it.

---

## Tool identifier

`ledger.post`

## Side effect class

`WRITES_RUN_STATE | WRITES_AUDIT`

## Mobile

Mobile clients are rejected. All ledger posting occurs server-side within workflow runs. Any request originating from a mobile client (`client_form_factor = MOBILE`) is rejected before execution with status `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full list of write endpoints that apply this rule.

---

## Input schema

```json
{
  "run_id":               "uuid — the workflow run that owns this posting, required",
  "transaction_id":       "uuid — the transaction being posted, required",
  "debit_account_code":   "text — account code from chart_of_accounts, required",
  "credit_account_code":  "text — account code from chart_of_accounts, required",
  "amount":               "numeric(15,2) — positive, required",
  "currency":             "char(3) — ISO 4217, required",
  "fx_rate":              "numeric(12,6) | null — required if currency != 'EUR'",
  "fx_rate_date":         "date | null — required if currency != 'EUR'",
  "description":          "text — human-readable description, required",
  "posting_date":         "date — the effective date of the posting, required",
  "vat_entry_id":         "uuid | null — links this posting to a vat_entries row",
  "idempotency_key":      "string — required; must be unique per posting within the run"
}
```

---

## Validation

1. `debit_account_code` and `credit_account_code` must both exist in the business's `chart_of_accounts` with `is_active = true`. A missing or inactive account code returns `LEDGER_ACCOUNT_NOT_FOUND`.
2. `debit_account_code` and `credit_account_code` must not be the same account. A same-account double-entry returns `LEDGER_SAME_ACCOUNT_ERROR`.
3. `amount` must be positive (> 0). Zero or negative returns `LEDGER_INVALID_AMOUNT`.
4. If `currency != 'EUR'`, both `fx_rate` and `fx_rate_date` are required. Missing either returns `LEDGER_FX_RATE_REQUIRED`. The fx_rate must have been sourced from `ledger.fx_convert`; callers must pass the `ecb_cache_record_id` from that call via the `fx_rate_date` provenance chain.
5. `posting_date` must fall within an OPEN or UNDER_REVIEW VAT period for the business. Posting to a CLOSED or SUBMITTED period returns `LEDGER_PERIOD_LOCKED`.
6. `idempotency_key` is checked against a per-run index before any write. Duplicate key = idempotent no-op (see below).

---

## Double-entry enforcement

The tool writes exactly two rows to `ledger_entries` in the same database transaction:

- Row 1: `entry_type = DEBIT`, `account_code = debit_account_code`
- Row 2: `entry_type = CREDIT`, `account_code = credit_account_code`

Both rows carry the same `transaction_id`, `run_id`, `amount`, `currency`, `posting_date`, and `description`. If the INSERT for either row fails (constraint violation, lock timeout, or any other error), the transaction is rolled back and neither row is committed. The tool returns `LEDGER_POST_FAILED` with the underlying error detail.

---

## VAT linkage

If `vat_entry_id` is provided, the tool updates the corresponding `vat_entries` row to set `is_posted = true` and `ledger_entry_id = debit_entry_id` within the same database transaction. If the `vat_entries` row does not exist or is already posted, the tool returns `LEDGER_VAT_ENTRY_LINK_FAILED` and rolls back the entire transaction.

---

## Idempotency

A second call with the same `idempotency_key` within the same run is a no-op. The tool returns the original `debit_entry_id` and `credit_entry_id` from the first successful call. No new rows are written and no audit events are emitted on the duplicate call. The idempotency check uses a unique index on `(run_id, idempotency_key)` in `ledger_entries`.

---

## Output schema

```json
{
  "debit_entry_id":   "uuid — the ledger_entries row id for the debit",
  "credit_entry_id":  "uuid — the ledger_entries row id for the credit",
  "posted_at":        "timestamptz — the commit timestamp of the posting"
}
```

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `LEDGER_ENTRY_POSTED` | LOW | Both ledger rows committed successfully |
| `LEDGER_ENTRY_POST_FAILED` | MEDIUM | Any validation or write failure; rows rolled back |

`LEDGER_ENTRY_POSTED` carries `debit_entry_id`, `credit_entry_id`, `transaction_id`, `run_id`, `business_id`, `amount`, `currency`, `posting_date`. `LEDGER_ENTRY_POST_FAILED` carries `run_id`, `transaction_id`, `business_id`, `error_code`, `error_detail`.

---

## Cross-references

- `ledger_entry_schema.md` — schema for the rows this tool writes
- `ledger_account_chart_schema.md` — account code validation source
- `vat_entry_schema.md` — VAT entry rows linked via vat_entry_id
- `tool_fx_convert.md` — READ_ONLY tool that produces fx_rate and fx_rate_date
- `mobile_write_rejection_endpoints.md` — full list of mobile-rejected write endpoints
- `audit_event_taxonomy` — LEDGER_ENTRY_POSTED and LEDGER_ENTRY_POST_FAILED definitions
- `data_layer_conventions_policy` — identifier generation, canonical JSON for audit payloads

---

## Error codes

| Code | Condition |
|---|---|
| `LEDGER_ACCOUNT_NOT_FOUND` | debit or credit account code missing or inactive |
| `LEDGER_SAME_ACCOUNT_ERROR` | debit and credit account codes are identical |
| `LEDGER_INVALID_AMOUNT` | amount is zero or negative |
| `LEDGER_FX_RATE_REQUIRED` | currency is not EUR but fx_rate or fx_rate_date is null |
| `LEDGER_PERIOD_LOCKED` | posting_date falls in a CLOSED or SUBMITTED VAT period |
| `LEDGER_VAT_ENTRY_LINK_FAILED` | vat_entry_id does not exist or is already posted |
| `LEDGER_POST_FAILED` | database-level failure; see error_detail |

---

## Concurrency behaviour

`ledger.post` uses the database transaction to provide isolation. Concurrent calls for the same `transaction_id` with different idempotency keys are both permitted — this covers multi-line journal entries (e.g. a transaction with both a VAT line and a net line). The double-entry invariant is enforced at the row level; the run-level balance check runs as a phase gate after all postings for a run complete.

---

## Open items deferred to later sub-docs

- Run-level balance reconciliation gate — Block 11 Phase 05
- Retroactive adjustment entry posting (AMENDED VAT period flow) — Block 11 Phase 07
- Period-end lock propagation to `ledger_entries.is_locked` — `ledger_entry_schema.md`
- Bulk posting API for batch migration workflows — Stage 2+

## Related tools

`ledger.fx_convert` (READ_ONLY) must be called before `ledger.post` for any non-EUR transaction. The `converted_amount`, `rate_used`, `rate_date`, and `ecb_cache_record_id` returned by `ledger.fx_convert` are passed directly into `ledger.post` as `amount`, `fx_rate`, `fx_rate_date`. Do not compute FX rates outside of `ledger.fx_convert`; ad-hoc rate computation bypasses the ECB cache provenance chain and will fail the ledger phase gate audit.
