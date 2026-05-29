# Runbook: VAT Recalculation After Classification or Matching Correction
**Category:** Runbooks · Block 11 — Ledger & Cyprus VAT
**Last updated:** 2026-05-17

---

## Trigger

This runbook is initiated when either of the following occurs:

- An `OUT_WORKFLOW_ADJUSTMENT_APPROVED` event is emitted with `adjustment_type = VAT_CORRECTION`.
- An accountant identifies that a transaction was classified with the wrong VAT rate
  (e.g., standard 19% applied instead of reduced 9%, or exempt treatment applied incorrectly).

Proceed through the steps in order. If the affected period is `FINALIZED`, skip to
Step 2b (post-finalization path). If the period is still `RUNNING`, use the in-period path.

---

## Step 1 — Identify Affected Entries

Query `vat_entries` for all entries linked to the affected transaction or invoice:

```sql
SELECT
  ve.id,
  ve.transaction_id,
  ve.invoice_id,
  ve.vat_rate,
  ve.vat_amount,
  ve.vat_direction,
  ve.ledger_entry_id,
  ve.vat_period_id,
  ve.correction_of_id
FROM vat_entries ve
WHERE ve.transaction_id = '<transaction_id>'
   OR ve.invoice_id     = '<invoice_id>'
ORDER BY ve.created_at;
```

Record:
- The original `vat_rate` and `vat_amount` that are incorrect.
- All `ledger_entry_ids` associated with the incorrect entries.
- The `vat_period_id` — this determines which path to follow.

Check the period status:
```sql
SELECT vp.id, vp.period_start, vp.period_end, wr.run_status
FROM vat_periods vp
JOIN workflow_runs wr ON wr.vat_period_id = vp.id
WHERE vp.id = '<vat_period_id>'
ORDER BY wr.created_at DESC
LIMIT 1;
```

---

## Step 2a — In-Period Correction (run_status != FINALIZED)

Use this path when the period's most recent `workflow_run` has `run_status` in
`CREATED`, `RUNNING`, `PAUSED`, `REVIEW_HOLD`, or `AWAITING_APPROVAL`.

**2a.1 — Post a reversal entry:**

```
ledger.post(
  business_entity_id = '<entity_id>',
  entry_type         = 'VAT_REVERSAL',
  amount             = -<original_vat_amount>,
  debit_account      = <original_credit_account>,
  credit_account     = <original_debit_account>,
  reference_entry_id = <original_ledger_entry_id>,
  memo               = 'VAT reversal: incorrect rate correction'
)
```

**2a.2 — Post the corrected entry:**

```
ledger.post(
  business_entity_id = '<entity_id>',
  entry_type         = 'VAT_ENTRY',
  amount             = <corrected_vat_amount>,
  debit_account      = <correct_debit_account>,
  credit_account     = <correct_credit_account>,
  vat_rate           = <correct_rate>,
  reference_id       = '<transaction_id_or_invoice_id>',
  memo               = 'VAT correction: corrected rate applied'
)
```

**2a.3 — Update `vat_entries`:**

Mark the original `vat_entries` row as reversed (set `reversed = true`,
`reversal_ledger_entry_id` = the reversal entry ID). Insert a new `vat_entries` row
with the corrected `vat_rate` and `vat_amount`.

**2a.4 — Update `vat_periods` totals:**

```sql
UPDATE vat_periods
SET
  vat_due_amount   = vat_due_amount - <delta>,
  net_vat_payable  = net_vat_payable - <delta>,
  updated_at       = now()
WHERE id = '<vat_period_id>';
```

Where `<delta>` = original `vat_amount` minus corrected `vat_amount` (may be negative
if the correction increases the amount owed).

---

## Step 2b — Post-Finalization Correction (run_status = FINALIZED)

Use this path when the period's workflow run is in `FINALIZED` status. Direct in-place
edits to a finalized period are not permitted. The correction must go through an OUT
adjustment run as defined in `adjustment_policy.md`.

**2b.1 — Create an adjustment record:**

Navigate to the period in the Dashboard and click "Request Amendment", or call:

```
adjustment.create(
  business_entity_id = '<entity_id>',
  period_id          = '<period_id>',
  adjustment_type    = 'VAT_CORRECTION',
  affected_entry_ids = ['<vat_entry_id>', ...],
  description        = 'Incorrect VAT rate applied to transaction <transaction_id>'
)
```

This creates an `adjustment_records` row with `status = PENDING_APPROVAL`.

**2b.2 — Obtain OWNER approval** per `approval_expiry_policy.md` (72-hour TTL).

**2b.3 — Adjustment run execution:**

On approval, an OUT adjustment run is created. The run posts correction ledger entries
that reference the original entries (`reference_entry_id`). New `vat_entries` rows are
inserted with `correction_of_id` pointing to the original entry being corrected.

**2b.4 — Update `vat_periods` totals** as in Step 2a.4 above. The adjustment run
handles this automatically if executed through the engine; verify the totals after run
completion.

---

## Step 3 — VIES Impact Assessment

If the corrected transaction involved an intra-EU supply (i.e., the counterparty's
`vat_country_code != 'CY'` and the supply type is `INTRA_EU_GOODS` or `INTRA_EU_SERVICES`):

1. Recalculate the quarterly VIES total for the affected quarter.
2. Compare the new total against the previously submitted VIES total.
3. If the difference is greater than €100 (absolute), flag for VIES amendment:
   - Set `vies_quarterly_submissions.amendment_required = true` for the affected quarter.
   - Follow `vies_quarterly_eligibility_policy.md` for the amendment submission procedure.
   - If the VIES submission has already been filed, refer to
     `vies_submission_failure_runbook.md` Scenario 4 (partial resubmission).

Differences of ≤€100 do not require a VIES amendment but must be noted in
`decisions_log.md`.

---

## Step 4 — Verification

After the correction is applied (either path), run the following verification query:

```sql
SELECT
  vp.net_vat_payable          AS period_net_vat_payable,
  SUM(ve.vat_amount)          AS sum_of_entries
FROM vat_periods vp
JOIN vat_entries ve ON ve.vat_period_id = vp.id
WHERE vp.id = '<vat_period_id>'
  AND ve.reversed IS DISTINCT FROM true
GROUP BY vp.net_vat_payable;
```

The two columns must match. If they diverge, there is an unreconciled entry — investigate
before closing the runbook.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `LEDGER_VAT_REVERSAL_POSTED` | LOW | Reversal ledger entry created |
| `LEDGER_VAT_CORRECTION_POSTED` | LOW | Corrected entry posted |
| `VAT_PERIOD_TOTALS_UPDATED` | LOW | `vat_periods` totals recalculated |
| `OUT_WORKFLOW_ADJUSTMENT_APPROVED` | MEDIUM | Adjustment run approved for finalized period |
| `VIES_AMENDMENT_FLAGGED` | MEDIUM | VIES total deviation >€100 detected |

---

## Cross-References

- `vat_entry_schema.md`
- `vat_period_schema.md`
- `ledger_entry_schema.md`
- `adjustment_schema.md`
- `adjustment_policy.md`
- `vies_quarterly_eligibility_policy.md`
- `vies_submission_failure_runbook.md`
- `decisions_log.md`
