# Tool: ledger.reconcile

**Block:** 15 — Finalization & Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`ledger.reconcile` verifies that the ledger is balanced before a run enters FINALIZING status. It sums all debit and credit entries recorded for the period under the given run, checks that the totals match, identifies any entries without a corresponding counterpart, confirms that every classified transaction has a ledger entry, and validates that the VAT control account balance is consistent with the period's `vat_periods` calculation. The tool is called automatically by `engine.gate_finalization` and may also be called manually by an accountant from the review queue.

The tool is idempotent: calling it multiple times for the same `run_id` and `period_id` always recomputes from the current ledger state and emits a fresh audit event. It does not modify any rows.

---

## Tool identifier

`ledger.reconcile`

## Side effect class

`WRITES_AUDIT`

---

## Input schema

```json
{
  "run_id":    "uuid — the workflow run whose ledger is being reconciled, required",
  "period_id": "uuid — the vat_periods row for the accounting period, required"
}
```

Both fields are required. The tool resolves `business_id` from `workflow_runs.business_id` using `run_id`; no explicit `business_id` input is needed.

---

## Output schema

```json
{
  "reconciliation_result": {
    "balanced":           "bool — true when total_debits == total_credits",
    "total_debits":       "numeric(15,2) — sum of all debit entry amounts in EUR for the period",
    "total_credits":      "numeric(15,2) — sum of all credit entry amounts in EUR for the period",
    "variance":           "numeric(15,2) — abs(total_debits - total_credits); 0.00 when balanced",
    "entry_count":        "integer — total ledger entries evaluated",
    "unbalanced_entries": "array — empty when balanced; populated with unbalanced_entry objects when not",
    "missing_entries":    "array — transactions that have a classification but no ledger entry",
    "vat_control_check":  {
      "passed":                "bool",
      "vat_control_balance":   "numeric(15,2) — sum of vat_amount_eur across all entries in period",
      "vat_period_calculated": "numeric(15,2) — total_vat_due from vat_periods row",
      "vat_variance":          "numeric(15,2)"
    }
  }
}
```

### unbalanced_entry object

```json
{
  "entry_id":          "uuid",
  "transaction_id":    "uuid",
  "entry_date":        "date",
  "debit_account_id":  "uuid",
  "credit_account_id": "uuid",
  "amount_eur":        "numeric(15,2)",
  "issue":             "text — human-readable description of the imbalance"
}
```

### missing_entry object

```json
{
  "transaction_id":       "uuid",
  "classification_id":    "uuid",
  "transaction_date":     "date",
  "amount_eur":           "numeric(15,2)",
  "classification_label": "text"
}
```

---

## Logic

### Step 1 — Resolve scope

```sql
SELECT le.entry_id, le.amount_eur, le.debit_account_id,
       le.credit_account_id, le.vat_amount_eur, le.transaction_id
FROM   ledger_entries le
JOIN   workflow_runs wr ON wr.id = le.workflow_run_id
JOIN   vat_periods   vp ON vp.business_id = wr.business_id
                        AND le.entry_date BETWEEN vp.period_start AND vp.period_end
WHERE  le.workflow_run_id = $run_id
  AND  vp.id = $period_id;
```

### Step 2 — Sum debits and credits

```sql
SELECT
  SUM(amount_eur)                                          AS total_amount,
  COUNT(*)                                                 AS entry_count
FROM ledger_entries
WHERE workflow_run_id = $run_id
  AND entry_date BETWEEN $period_start AND $period_end;
```

Because every `ledger_entries` row represents one complete double-entry (debit_account_id + credit_account_id + amount_eur), the sum of `amount_eur` is the total of both sides. A balanced ledger has `total_debits = total_credits`, which means the effective double-entry sum across all rows must be even. The reconciler computes the debit sum by joining to `chart_of_accounts` and checking `account_type IN ('ASSET','EXPENSE')` for normal debit-side accounts, and the credit sum for `account_type IN ('LIABILITY','EQUITY','REVENUE')`. The CHECK constraint on `ledger_entries (debit_account_id != credit_account_id)` is validated at row creation; the reconciler trusts this invariant and focuses on period-level balance.

### Step 3 — Flag entries without a matching counterpart

The tool checks that for every debit posting to a clearing or suspense account, a corresponding credit posting exists within the same period with the same `transaction_id`. Entries without a matching counterpart are added to `unbalanced_entries`.

```sql
SELECT entry_id, transaction_id, debit_account_id, credit_account_id, amount_eur
FROM   ledger_entries
WHERE  workflow_run_id = $run_id
  AND  (debit_account_id IN (SELECT id FROM chart_of_accounts WHERE account_type = 'CLEARING')
     OR credit_account_id IN (SELECT id FROM chart_of_accounts WHERE account_type = 'CLEARING'))
  AND  transaction_id NOT IN (
         SELECT transaction_id FROM ledger_entries
         WHERE  workflow_run_id = $run_id
         GROUP  BY transaction_id HAVING COUNT(*) >= 2
       );
```

### Step 4 — Verify all classified transactions have ledger entries

```sql
SELECT t.id AS transaction_id, cr.id AS classification_id,
       t.transaction_date, t.amount_eur, cr.classification_label
FROM   transactions t
JOIN   classification_results cr ON cr.transaction_id = t.id
                                 AND cr.run_id = $run_id
                                 AND cr.is_active = true
LEFT   JOIN ledger_entries le ON le.transaction_id = t.id
                              AND le.workflow_run_id = $run_id
WHERE  t.business_id = $business_id
  AND  t.transaction_date BETWEEN $period_start AND $period_end
  AND  le.entry_id IS NULL;
```

Any rows returned are added to `missing_entries`.

### Step 5 — VAT control account check

```sql
SELECT COALESCE(SUM(vat_amount_eur), 0.00) AS vat_control_balance
FROM   ledger_entries
WHERE  workflow_run_id = $run_id
  AND  entry_date BETWEEN $period_start AND $period_end;
```

Compare against `vat_periods.total_vat_due` for `period_id`. A variance greater than `0.01` (rounding tolerance) marks `vat_control_check.passed = false`.

### Step 6 — Determine result and emit audit event

If `balanced = true`, `missing_entries` is empty, and `vat_control_check.passed = true`, the tool emits `LEDGER_RECONCILIATION_COMPLETED` (severity LOW).

If any check fails, the tool emits `LEDGER_RECONCILIATION_FAILED` (severity HIGH) and returns the full detail arrays.

---

## Audit events

| Event | Severity | Condition |
|---|---|---|
| `LEDGER_RECONCILIATION_COMPLETED` | LOW | All checks passed |
| `LEDGER_RECONCILIATION_FAILED` | HIGH | Any check failed |

Audit payload includes `run_id`, `period_id`, `balanced`, `total_debits`, `total_credits`, `variance`, `missing_entry_count`, `vat_control_passed`.

---

## Idempotency

The tool performs only SELECT queries plus a single audit event INSERT. Calling it N times for the same inputs produces N audit rows but does not alter ledger state. The gate check (`engine.gate_finalization`) reads only the most recent `LEDGER_RECONCILIATION_COMPLETED` event to determine if reconciliation passed.

---

## Called by

- `engine.gate_finalization` — automatically, as gate check item (5)
- Review queue UI — manually, by accountant when investigating a ledger imbalance
- `runbooks/ledger_imbalance_runbook.md` — step 1 (manual diagnostic call)

---

## Mobile

`ledger.reconcile` is classified as `WRITES_AUDIT`. Mobile clients may not trigger reconciliation directly. Any request with `client_form_factor = MOBILE` is rejected with status `MOBILE_WRITE_REJECTED` before the SELECT queries run. The review queue UI on mobile surfaces the most recent reconciliation result (read-only) from the audit log but does not provide a re-run button. See `mobile_write_rejection_endpoints.md`.

---

## Error codes

| Code | Meaning |
|---|---|
| `RUN_NOT_FOUND` | `run_id` does not exist or is not owned by the calling session's business |
| `PERIOD_NOT_FOUND` | `period_id` does not match an existing `vat_periods` row for the business |
| `PERIOD_MISMATCH` | The run's business_id does not match the period's business_id |
| `LEDGER_RECONCILE_INTERNAL_ERROR` | Unexpected database error during aggregation |

---

## Related Documents

- `tool_ledger_post.md` — the tool that creates ledger entries
- `tool_finalization_gate_check.md` — gate that calls this tool
- `ledger_entry_schema.md` — ledger_entries table DDL
- `vat_period_schema.md` — vat_periods table DDL
- `runbooks/ledger_imbalance_runbook.md` — diagnosis and remediation steps
- `finalization_gate_sql_schema.md` — SQL fragments for gate checks
