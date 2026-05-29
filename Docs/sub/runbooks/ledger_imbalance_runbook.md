# Runbook: Ledger Imbalance

**Block:** 15 — Finalization & Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook covers the diagnosis and correction of a ledger imbalance detected during reconciliation. A ledger imbalance means the sum of debit-side amounts does not equal the sum of credit-side amounts for the period, or that individual transactions have orphaned ledger entries without a complete double-entry counterpart.

`ledger.reconcile` is the entry point for diagnosis. It is called automatically by `engine.gate_finalization` (check 5) and may also be called manually as described below. When reconciliation fails, `engine.gate_finalization` returns `passed: false` for check 5 and the run remains in `AWAITING_APPROVAL` until the imbalance is resolved.

HALF_UP rounding must be used throughout all monetary calculations in this platform. Inconsistent rounding is a common source of small variances. All corrections must also use HALF_UP.

---

## Prerequisites

- Query access to the Supabase database (read + write via service role for corrections)
- Access to the `ledger_entries`, `transactions`, `classification_results`, `chart_of_accounts`, and `vat_periods` tables
- The affected `run_id` and `period_id`

---

## Step 1 — Identify the variance

### Manual reconciliation call

Call `ledger.reconcile` manually with the affected run and period:

```bash
# Via platform admin console or Supabase Edge Function direct call
POST /functions/v1/ledger-reconcile
{
  "run_id":    "<run_id>",
  "period_id": "<period_id>"
}
```

The response includes `total_debits`, `total_credits`, `variance`, `unbalanced_entries[]`, and `missing_entries[]`.

### Direct SQL diagnostic

```sql
-- Get high-level debit/credit summary for the run
SELECT
  coa.account_type,
  coa.account_code,
  coa.account_name,
  SUM(le.amount_eur)   AS total_amount_eur,
  COUNT(*)             AS entry_count
FROM   ledger_entries le
JOIN   chart_of_accounts coa_debit  ON coa_debit.id  = le.debit_account_id
JOIN   chart_of_accounts coa_credit ON coa_credit.id = le.credit_account_id
CROSS  JOIN (
  SELECT account_type, id FROM chart_of_accounts
) coa
WHERE  le.workflow_run_id = $run_id
GROUP  BY coa.account_type, coa.account_code, coa.account_name
ORDER  BY coa.account_type, total_amount_eur DESC;
```

Determine the direction of the imbalance:
- `total_debits > total_credits` → debit-heavy: a debit entry exists without a credit counterpart
- `total_credits > total_debits` → credit-heavy: a credit entry exists without a debit counterpart

Note the `variance` value. A variance under `0.01 EUR` is likely a rounding error (see Step 3). A variance of exactly the amount of a known transaction strongly suggests a missing entry for that transaction.

**Expected audit events at this stage:**
- `LEDGER_RECONCILIATION_FAILED` (HIGH) — already emitted by the gate check that triggered this runbook

---

## Step 2 — Trace to source transaction

Use the `unbalanced_entries` array from the reconciliation result to identify which transactions produced the orphaned entries.

### Trace unbalanced entries to transactions

```sql
SELECT
  le.entry_id,
  le.transaction_id,
  t.description          AS transaction_description,
  t.transaction_date,
  t.amount_eur           AS transaction_amount,
  le.amount_eur          AS ledger_amount,
  le.debit_account_id,
  le.credit_account_id,
  coa_d.account_code     AS debit_account_code,
  coa_c.account_code     AS credit_account_code,
  cr.classification_label,
  cr.classification_code
FROM   ledger_entries le
JOIN   transactions     t    ON t.id    = le.transaction_id
JOIN   chart_of_accounts coa_d ON coa_d.id = le.debit_account_id
JOIN   chart_of_accounts coa_c ON coa_c.id = le.credit_account_id
LEFT   JOIN classification_results cr
         ON cr.transaction_id = le.transaction_id
        AND cr.run_id         = le.workflow_run_id
        AND cr.is_active      = true
WHERE  le.entry_id IN (/* unbalanced_entry_ids from reconcile result */)
ORDER  BY le.entry_id;
```

### Identify missing entries

```sql
-- Transactions with classification but no ledger entry
SELECT
  t.id            AS transaction_id,
  t.description,
  t.transaction_date,
  t.amount_eur,
  cr.classification_label,
  cr.classification_code
FROM   transactions t
JOIN   classification_results cr
         ON cr.transaction_id = t.id
        AND cr.run_id         = $run_id
        AND cr.is_active      = true
WHERE  t.business_id     = $business_id
  AND  t.transaction_date BETWEEN $period_start AND $period_end
  AND  NOT EXISTS (
    SELECT 1 FROM ledger_entries le
    WHERE  le.transaction_id   = t.id
      AND  le.workflow_run_id  = $run_id
  )
ORDER  BY t.transaction_date;
```

---

## Step 3 — Common root causes

### Cause A — Missing contra-entry (single-sided account mapping)

Symptom: the `ledger_account_mapping` for a classification code maps to a debit account but has no credit account defined, or vice versa.

Check:

```sql
SELECT lam.classification_code, lam.debit_account_id, lam.credit_account_id
FROM   ledger_account_mapping lam
WHERE  lam.business_id = $business_id
  AND  (lam.debit_account_id IS NULL OR lam.credit_account_id IS NULL);
```

Correction: fix the mapping in `chart_of_accounts` via the admin console and re-run classification for affected transactions.

### Cause B — FX rounding error

Symptom: variance is small (< 0.10 EUR) and affects transactions with non-EUR currencies.

The platform mandates HALF_UP rounding for all `numeric(15,2)` calculations. If any code path used HALF_EVEN or ROUND_CEILING instead, small rounding differences accumulate.

Check:

```sql
-- Find FX-converted entries where rounded amount differs from expected
SELECT
  le.entry_id,
  le.amount_eur                                AS stored_amount,
  ROUND(le.amount_original * le.fx_rate, 2)   AS recalculated_amount,
  le.amount_eur - ROUND(le.amount_original * le.fx_rate, 2) AS rounding_diff
FROM ledger_entries le
WHERE le.workflow_run_id = $run_id
  AND le.currency       != 'EUR'
  AND ABS(le.amount_eur - ROUND(le.amount_original * le.fx_rate, 2)) > 0;
```

PostgreSQL's `ROUND(numeric, 2)` uses HALF_UP by default for `numeric` types (as distinct from `float`). Ensure no intermediate float casts were applied. If rounding differences are found, create compensating entries per Step 4.

### Cause C — VAT control account misconfiguration

Symptom: `vat_control_check.passed = false` in the reconciliation result but the main debit/credit balance is correct.

Check:

```sql
SELECT
  COALESCE(SUM(le.vat_amount_eur), 0.00)  AS vat_control_balance,
  vp.total_vat_due                         AS vat_period_calculated
FROM   ledger_entries le
JOIN   vat_periods vp ON vp.id = $period_id
WHERE  le.workflow_run_id = $run_id
  AND  le.entry_date BETWEEN vp.period_start AND vp.period_end
GROUP  BY vp.total_vat_due;
```

If the VAT control balance does not match `total_vat_due`, the most common cause is a `vat_treatment` mismatch where `vat_amount_eur` was computed with the wrong rate. Re-running `tool_vat_calc.md` for the affected transactions will recompute `vat_amount_eur` values. After recalculation, re-run `ledger.post` for affected entries.

### Cause D — Manual adjustment without counterpart

Symptom: an adjustment entry (created via Block 13 adjustment tools) posted a single-sided entry.

Check:

```sql
SELECT le.entry_id, le.transaction_id, le.amount_eur,
       le.debit_account_id, le.credit_account_id, ar.adjustment_type
FROM   ledger_entries le
JOIN   adjustment_records ar ON ar.run_id = le.workflow_run_id
                              AND ar.transaction_id = le.transaction_id
WHERE  le.workflow_run_id = $run_id;
```

Compare against `adjustment_delta_payload_schema.md` to verify both sides of the entry were posted.

---

## Step 4 — Apply correction

Choose the correction method based on the root cause identified in Step 3.

### Option A — Create a compensating ledger entry

Use this for FX rounding errors and small variances that do not require re-running classification.

```sql
-- Only via service role; never write directly from client code
INSERT INTO ledger_entries (
  entry_id, business_id, workflow_run_id, transaction_id,
  entry_date, debit_account_id, credit_account_id,
  amount_eur, currency, amount_original, fx_rate,
  vat_treatment, vat_amount_eur, description, created_at
) VALUES (
  gen_uuid_v7(),
  $business_id,
  $run_id,
  $transaction_id,
  $entry_date,
  $debit_account_id,   -- rounding adjustment account
  $credit_account_id,  -- rounding adjustment account
  $variance_amount,    -- the exact variance, rounded HALF_UP to 2 dp
  'EUR',
  NULL,
  NULL,
  'OUTSIDE_SCOPE',
  0.00,
  'Compensating rounding adjustment — ledger_imbalance_runbook step 4A',
  now()
);
```

The compensating entry should reference the `rounding_adjustment` account code in `chart_of_accounts`. This account is a zero-net-impact clearing account used only for reconciliation corrections.

### Option B — Re-run classification for affected transaction

Use this when the root cause is a missing account mapping (Cause A) or an incorrect classification code.

1. Fix the `ledger_account_mapping` row for the affected classification code.
2. Set `classification_results.is_active = false` for the affected transaction in this run.
3. Re-invoke `ai.classify` for the transaction with `force_reclassify = true`.
4. After reclassification, re-invoke `ledger.post` for the transaction.

### Option C — Fix VAT control account mapping

Use this for VAT control account mismatches (Cause C).

1. Identify the affected `chart_of_accounts` row where `account_type = 'VAT_CONTROL'`.
2. Update the mapping in `ledger_account_mapping` to point to the correct VAT control account.
3. Re-run `tool_vat_calc.md` to recompute `vat_amount_eur` for affected entries.
4. Re-run `ledger.post` for affected transactions to replace incorrect entries.

All corrective writes must be performed via the service role through platform tools, not direct SQL in production. The correction is documented in the run's notes field.

---

## Step 5 — Verify and re-reconcile

After applying the correction, re-run `ledger.reconcile` to confirm the imbalance is resolved:

```bash
POST /functions/v1/ledger-reconcile
{
  "run_id":    "<run_id>",
  "period_id": "<period_id>"
}
```

Confirm:
- `balanced = true`
- `unbalanced_entries = []`
- `missing_entries = []`
- `vat_control_check.passed = true`
- `variance = 0.00`

### Post-correction documentation

Add a note to the run record:

```sql
UPDATE workflow_runs
SET    notes = COALESCE(notes, '') || E'\n[ledger_imbalance_runbook] Correction applied: ' || $correction_description
WHERE  id = $run_id;
```

`$correction_description` should include: root cause, entries affected, correction method used, and who applied the correction.

**Expected audit events at this stage:**
- `LEDGER_RECONCILIATION_COMPLETED` (LOW) — emitted when re-reconciliation passes

After confirmation, `engine.gate_finalization` may be retried. If the gate was failing only on check 5, it should now pass and the run will transition to `FINALIZING`.

---

## HALF_UP rounding enforcement

All monetary values in `ledger_entries.amount_eur` and `ledger_entries.vat_amount_eur` must be rounded using HALF_UP to exactly 2 decimal places. HALF_UP always rounds the 0.005 boundary away from zero. Never cast to `float` before rounding, as `float` uses IEEE 754 round-half-to-even, which produces different results at the 0.005 boundary.

Example:
- `ROUND(2.345::numeric, 2)` → `2.35` (HALF_UP: rounds up at the 0.005 boundary)
- `ROUND(2.355::numeric, 2)` → `2.36` (HALF_UP: rounds up at the 0.005 boundary)

Any code path that produces ledger entries must use `numeric` arithmetic throughout. FX conversion must use `ROUND(amount_original::numeric * fx_rate::numeric, 2)`.

---

## Audit events generated by this runbook

| Event | Severity | Step |
|---|---|---|
| `LEDGER_RECONCILIATION_FAILED` | HIGH | Pre-existing when runbook starts (from gate check) |
| `LEDGER_ENTRY_CORRECTION_APPLIED` | MEDIUM | When a compensating entry is inserted (Step 4A) |
| `LEDGER_RECONCILIATION_COMPLETED` | LOW | After successful re-reconciliation (Step 5) |

---

## Related Documents

- `tool_ledger_reconcile.md` — the reconciliation tool called in Steps 1 and 5
- `tool_ledger_post.md` — used to post corrective entries
- `tool_finalization_gate_check.md` — gate check 5 that triggered this runbook
- `ledger_entry_schema.md` — ledger_entries DDL
- `ledger_account_mapping_schema.md` — account mapping DDL
- `chart_of_accounts_schema.md` — chart of accounts DDL
- `vat_period_schema.md` — vat_periods DDL
- `tool_vat_calc.md` — VAT recalculation tool
- `runbooks/vat_recalculation_runbook.md` — companion runbook for VAT correction
- `data_layer_conventions_policy.md` — HALF_UP rounding policy (§3)
