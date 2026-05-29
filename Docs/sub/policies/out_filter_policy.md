# OUT Filter Policy

**Category:** Policies · **Owning block:** 07 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

This policy defines which transactions are included in, or excluded from, an OUT workflow run. The OUT workflow processes outgoing payments and expense matching. Correct filtering is essential to avoid double-counting, misclassification of internal movements, and inclusion of items outside the run's scope.

---

## 1. What the OUT Workflow Processes

The OUT workflow matches bank statement debit entries against supplier invoices and recorded expenses. The primary inputs are:

- **Bank statement debit lines** — negative-amount entries from imported bank statements within the run's period.
- **Recorded supplier invoices** — `invoices` rows with `direction = 'OUT'` in SENT or OVERDUE status within the run's period.
- **Bank charges** — fee lines identified by the bank statement parser as bank-originated charges (e.g. service fees, transfer fees). These are classified and matched separately from supplier invoices.

---

## 2. Inclusion Criteria

A bank statement line is included in the OUT workflow run if all of the following are true:

1. `amount < 0` (debit entry on the statement — money leaving the account).
2. `transaction_date` falls within the run period ± 3 days buffer (see Section 7).
3. `status` is not `EXCLUDED` (lines manually excluded by a reviewer remain excluded).
4. The line has not been finalised in a previous run (i.e. no confirmed match from a prior finalised run).
5. The bank account associated with the statement belongs to the business entity (RLS enforced).

Supplier invoices are included if:

1. `direction = 'OUT'`.
2. `status IN ('SENT', 'OVERDUE')`.
3. `due_date` or `invoice_date` falls within the run period ± 3 days buffer.
4. The invoice has not been fully allocated by a prior confirmed match.

---

## 3. Exclusion Rules

The following categories are excluded from OUT workflow runs. Exclusions are applied before the matching engine sees the data.

### 3.1 Transfers Between Own Accounts

Bank statement lines identified as transfers between accounts owned by the same business entity are excluded. Identification criteria:

- The counterparty IBAN on the statement line matches another bank account registered to the same business entity in `bank_feed_schema.md`.
- The line is tagged `transfer_type = 'INTERNAL'` by the bank statement parser.

Excluded lines emit no review queue item. They are recorded with `exclusion_reason = 'INTERNAL_TRANSFER'`.

### 3.2 Internal Journal Entries

Manually created journal entries (ledger entries with `source = 'MANUAL_JOURNAL'`) do not appear as bank statement lines and are never included in the OUT workflow matching scope. Journal entries are applied directly to the ledger and do not require matching.

### 3.3 Salary Payments

Lines identified as salary or payroll payments are excluded from standard OUT workflow processing. Identification relies on:

- Counterparty reference matching a known payroll provider pattern.
- Description text matching the configured payroll keyword list.
- Manual tagging by a reviewer in a prior run.

Excluded salary lines are routed to the payroll reconciliation flow (separate from the OUT matching pipeline). The exclusion is recorded with `exclusion_reason = 'SALARY_PAYMENT'`.

### 3.4 VAT Payments to Tax Authority

Lines where the counterparty is identified as the Cyprus Tax Department (by IBAN or known reference prefix `TAX-CY-`) are excluded from OUT matching. These are handled by the VAT reconciliation flow.

---

## 4. Duplicate Filtering

Duplicate detection runs before the matching phase. Two duplicate classifications affect inclusion:

### 4.1 DUPLICATE_EXACT

A line classified as `DUPLICATE_EXACT` (exact match to an already-processed line by amount, date, and reference) is automatically excluded from the run. No review queue item is created. The line is recorded with `dedup_status = 'DUPLICATE_EXACT'` and `exclusion_reason = 'DUPLICATE_EXACT'`.

The dedup key for DUPLICATE_EXACT is the combination of: `(business_entity_id, bank_account_id, amount, transaction_date, bank_reference)`. See `deduplication_fingerprint_schema.md`.

### 4.2 DUPLICATE_PROBABLE

A line classified as `DUPLICATE_PROBABLE` (high-confidence but not certain duplicate) is flagged for review. It remains in the run scope but is marked with a review queue item of type `DUPLICATE_REVIEW`. A reviewer must confirm or dismiss the duplicate flag before the line proceeds to matching.

Dismissing the flag (reviewer confirms it is not a duplicate) removes the flag and allows matching to proceed normally. Confirming the flag excludes the line with `exclusion_reason = 'DUPLICATE_PROBABLE_CONFIRMED'`.

---

## 5. Date Range Filtering

The run period is defined by the `period_start` and `period_end` fields of the OUT run configuration (`out_run_config_schema.md`). The effective date range for transaction inclusion is:

```
effective_start = period_start - INTERVAL '3 days'
effective_end   = period_end   + INTERVAL '3 days'
```

The ±3 day buffer exists to capture bank statement lines whose value date falls slightly outside the nominal period due to weekend, holiday, or cross-bank settlement delays. Transactions included via the buffer but outside the strict period are flagged as `buffer_included = true` in the run scope table.

The buffer is non-configurable at the run level. If a business requires a different buffer, it must be set in the `out_config_schema.md` per-business configuration (max buffer: 7 days).

---

## 6. Manual Exclusion Override

Reviewers with `org:accountant` or `org:owner` role may manually exclude any in-scope line from an active run. Manual exclusion requires an `exclusion_reason` text entry. Manual exclusions:

- Are recorded in the run scope with `exclusion_source = 'MANUAL'`.
- Emit `OUT_LINE_MANUALLY_EXCLUDED` to the audit log.
- Are reversible within the same run (reviewer may re-include the line before finalisation).

After run finalisation, manually excluded lines cannot be re-included in the same run. They may appear in a subsequent run if they still fall within the next run's date range.

---

## 7. Audit Events

| Event | Trigger |
|---|---|
| `OUT_LINE_INCLUDED` | Line added to run scope |
| `OUT_LINE_EXCLUDED_INTERNAL_TRANSFER` | Line excluded as internal transfer |
| `OUT_LINE_EXCLUDED_SALARY` | Line excluded as salary payment |
| `OUT_LINE_EXCLUDED_DUPLICATE_EXACT` | Line excluded as exact duplicate |
| `OUT_LINE_FLAGGED_DUPLICATE_PROBABLE` | Line flagged for duplicate review |
| `OUT_LINE_MANUALLY_EXCLUDED` | Line manually excluded by reviewer |
| `OUT_LINE_MANUAL_EXCLUSION_REVERSED` | Manual exclusion reversed within same run |

---

## Related Documents

- `out_run_config_schema.md` — run period and configuration
- `out_config_schema.md` — per-business OUT workflow settings
- `deduplication_policy.md` — deduplication rules and classification criteria
- `deduplication_fingerprint_schema.md` — dedup key construction
- `dedup_result_schema.md` — dedup classification results
- `bank_statement_line_schema.md` — source lines for OUT matching
- `matching_engine_policy.md` — matching pipeline that follows filtering
- `internal_transfer_cross_workflow_dedup_policy.md` — internal transfer detection rules
- `out_adjustment_policies.md` — adjustment rules for OUT run corrections
