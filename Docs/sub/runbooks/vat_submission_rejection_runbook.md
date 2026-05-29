# Runbook: VAT Return Rejection

**Block:** Ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This runbook covers the end-to-end procedure for handling a VAT return rejection received from the Cyprus Tax Department. A rejection is indicated by the `VAT_RETURN_REJECTED` audit event (severity HIGH) and by `vat_returns.status = 'REJECTED'` on the return record.

Under Cyprus VAT law, a business has 30 calendar days from the original filing deadline to correct and resubmit a rejected return without penalty. Corrections submitted after this window are subject to late-filing penalties and interest on any underpayment. Where the rejection is received close to the 30-day limit, this runbook should be executed on the same business day.

---

## Prerequisites

- Access to the Cyprus Tax Department's portal (TAXISnet) to retrieve the rejection reason
- Supabase service-role read access to `vat_returns`, `vat_entries`, `ledger_entries`, and `vies_records`
- Accountant or admin role on the platform
- The `period_id` and `vat_returns.id` of the rejected return

---

## Step 1 — Receive and Record the Rejection

### 1.1 Confirm the Rejection in the Platform

```sql
SELECT
  vr.id                AS return_id,
  vr.business_id,
  vr.period_id,
  vr.status,
  vr.output_vat,
  vr.input_vat,
  vr.net_vat_payable,
  vr.vies_value,
  vr.filing_deadline,
  vr.submitted_at,
  vr.reference_number
FROM vat_returns vr
WHERE vr.id = '<return_id>';
```

A rejected return has `status = 'REJECTED'`. If `reference_number` is NULL, the Tax Department rejected the return before assigning a reference. If `reference_number` is set, the rejection occurred after an initial processing step.

### 1.2 Retrieve the Rejection Reason from TAXISnet

Log in to the TAXISnet portal and navigate to the VAT return history for the period. Rejection reasons typically fall into the following categories:

| Rejection Code (TAXISnet) | Platform Root Cause Category         |
|---------------------------|---------------------------------------|
| ERR_VAT_CALC              | Calculation error                     |
| ERR_VIES_MISSING          | Missing or incomplete VIES data       |
| ERR_PERIOD_OVERLAP        | Period overlap with prior return      |
| ERR_VAT_NUMBER_INVALID    | Incorrect VAT registration number     |
| ERR_SUBMISSION_FORMAT     | Technical XML/format error at portal  |
| ERR_LATE                  | Return submitted after deadline       |

Record the rejection code and the rejection reason text in a review issue on the platform (see 1.3).

### 1.3 Create a HIGH Review Issue

```
review_queue.create_issue(
  entity_type   = 'VAT_RETURN',
  entity_id     = '<return_id>',
  severity      = 'HIGH',
  issue_type    = 'VAT_RETURN_REJECTED',
  description   = '<TAXISnet rejection code> — <rejection reason text from portal>'
)
```

This review issue gates the next steps and ensures an accountant must explicitly sign off on the correction before resubmission.

---

## Step 2 — Identify the Root Cause

### Root Cause A — Calculation Error

Indicators: TAXISnet code `ERR_VAT_CALC`; the Tax Department's stated figures differ from the submitted return.

Pull all VAT entries for the period to verify the submitted figures:

```sql
SELECT
  ve.id,
  ve.entry_type,       -- OUTPUT_VAT or INPUT_VAT
  ve.vat_rate_code,
  ve.gross_amount,
  ve.vat_amount,
  ve.currency,
  ve.fx_rate,
  ve.posting_date,
  ve.status
FROM vat_entries ve
WHERE ve.period_id  = '<period_id>'
  AND ve.business_id = '<business_id>'
  AND ve.status      = 'POSTED'
ORDER BY ve.entry_type, ve.posting_date;
```

Compare the sums against the submitted `output_vat` and `input_vat` on the return. Common causes:
- A ledger entry was posted after the return was generated (ledger generation advanced post-calculation)
- An FX conversion used a stale ECB rate
- A blocked input VAT entry was incorrectly included

### Root Cause B — Missing or Incomplete VIES Data

Indicators: TAXISnet code `ERR_VIES_MISSING`; `vat_returns.vies_value > 0` but the VIES declaration was not submitted or contained errors.

```sql
SELECT
  vr.id,
  vr.vat_number,
  vr.supply_value,
  vr.period_id,
  vr.submission_status,
  vr.submitted_at
FROM vies_records vr
WHERE vr.period_id   = '<period_id>'
  AND vr.business_id = '<business_id>';
```

Check whether all intra-EU customers have validated EU VAT numbers in `counterparty.vat_number_validated = true`. Unvalidated VAT numbers cause VIES rejection. Also verify `vies_submission_tracking` for the period to confirm the VIES declaration was actually submitted.

### Root Cause C — Period Overlap

Indicators: TAXISnet code `ERR_PERIOD_OVERLAP`; the return's date range overlaps with a previously accepted return.

```sql
SELECT
  vr.id,
  vr.status,
  vp.period_start,
  vp.period_end
FROM vat_returns vr
JOIN vat_periods vp ON vp.id = vr.period_id
WHERE vr.business_id = '<business_id>'
  AND vr.status IN ('ACCEPTED', 'SUBMITTED')
ORDER BY vp.period_start;
```

Identify any date overlap between the rejected period and adjacent accepted periods. This typically happens when a quarterly period was accidentally split into two overlapping submissions.

### Root Cause D — Incorrect VAT Registration Number

Indicators: TAXISnet code `ERR_VAT_NUMBER_INVALID`; the VAT number on the return does not match the Tax Department's records.

Check `business_entities.vat_number` and cross-reference against the TAXISnet-registered number. A mismatch in formatting (with/without CY prefix) is a common cause. Correct the `vat_number` on the business entity record before resubmission.

---

## Step 3 — Amend the Return

### 3.1 Mark the Current Return as AMENDED

The rejected return row is updated to `status = 'AMENDED'`. This releases the unique index on `(business_id, period_id)` and permits a new return row to be created.

This transition is performed by the server-side `ledger.amend_vat_return` function:

```
ledger.amend_vat_return(
  return_id     = '<return_id>',
  amendment_reason = '<description of what is being corrected>'
)
```

After this call, `vat_returns.status = 'AMENDED'` and the `VAT_RETURN_AMENDED` audit event (MEDIUM severity) is emitted.

### 3.2 Recalculate VAT via ledger.calc_vat

Re-run the VAT calculation with `recalculate = true` to ensure the latest ledger state is used. This is mandatory — do not rely on the cached calculation that produced the rejected return.

```
ledger.calc_vat(
  run_id      = '<correction_run_id>',
  period_id   = '<period_id>',
  recalculate = true
)
```

Review the updated `vat_summary` output carefully:
- Confirm `output_vat` and `input_vat` match expected values
- Verify `vies_value` is correct if VIES data was the root cause
- Check all reverse-charge entries are correctly included

If the root cause was a missing or incorrect ledger entry, correct the entry via the amendment ledger flow (see `runbooks/period_amendment_runbook.md`) before recalculating.

### 3.3 Create the Amended Return Record

Once the recalculated figures are verified, create a new `vat_returns` row with:
- `status = 'DRAFT'`
- Updated `output_vat`, `input_vat` from the recalculation
- Updated `vies_value` if applicable
- A new `filing_deadline` if the original deadline has passed (use the corrected deadline based on the 30-day window)

The new row is linked to the same `period_id`. Because the previous row is now `AMENDED`, the unique index permits the new row.

---

## Step 4 — Accountant Review and Re-Filing

### 4.1 Accountant Review

The amended return must be reviewed by the accountant before submission. The review issue created in Step 1.3 must be resolved (or transitioned to a resolution-pending state) by the accountant acknowledging the corrections.

The accountant should verify:
- All transaction-level VAT entries are correct
- VIES values match the recalculated VIES record totals
- The net_vat_payable figure is consistent with the business's known VAT position
- Any penalty or interest implications are communicated to the client

### 4.2 Approval for Resubmission

For amended returns, a second approval is required from the org owner or admin before submission. This is enforced by the `workflow_approvals` table entry created by the amendment flow.

### 4.3 Submit the Amended Return

Once approved, submit via the VAT return submission API endpoint. The platform transmits the return to TAXISnet and updates `vat_returns.status` to `SUBMITTED` and `submitted_at` to the current timestamp.

### 4.4 VIES Recalculation (if applicable)

If the root cause was missing VIES data (Root Cause B), recalculate and resubmit the VIES declaration separately via the VIES submission tool. VIES and the main VAT return are filed independently on TAXISnet; a corrected VIES filing does not automatically resubmit the VAT return.

---

## Step 5 — Document the Outcome

### 5.1 Confirm Acceptance

Monitor `vat_returns.status` for the new amended return row. When TAXISnet accepts the return:
- `status` transitions to `ACCEPTED`
- `reference_number` is populated with the Tax Department's reference

The `VAT_RETURN_ACCEPTED` (LOW) audit event is emitted.

### 5.2 Update Period Records

If the correction altered the net_vat_payable:
- Update `vat_periods.net_vat_payable_final` to reflect the accepted figures
- If a payment was made based on the original figures, check whether a top-up or refund is required and note this in the review issue before closing it

### 5.3 Resolve the Review Issue

Close the HIGH review issue created in Step 1.3 with outcome: "Amended return accepted. Reference: <new_reference_number>."

### 5.4 Penalty Documentation

If the correction was filed after the 30-day window, or if the Tax Department has assessed a penalty:

1. Record the penalty amount as a separate ledger entry in the period the penalty was assessed (not the original VAT period).
2. Create a note on the client record with the penalty details.
3. Notify the account holder.

---

## 30-Day Correction Window

Under Cyprus VAT law (VAT Law 95(I)/2000 as amended), a rejected or incorrect return may be corrected within 30 calendar days of the original filing deadline without incurring a late-filing surcharge. Corrections submitted after this window attract:

- A fixed penalty for late filing
- Interest on any underpayment at the rate prescribed by the Tax Department (currently 2 % per annum, compounded)

The platform calculates the remaining correction window as:

```
correction_deadline = filing_deadline + INTERVAL '30 days'
days_remaining      = correction_deadline - CURRENT_DATE
```

If `days_remaining <= 5`, escalate to the accountant immediately and flag the review issue as BLOCKING.

---

## Queries Summary

### Pull Affected Transactions for a Period

```sql
SELECT
  t.id,
  t.amount,
  t.currency,
  t.posting_date,
  t.vat_amount,
  t.vat_rate_code,
  t.counterparty_id,
  t.description
FROM transactions t
WHERE t.period_id   = '<period_id>'
  AND t.business_id = '<business_id>'
  AND t.status      = 'POSTED'
ORDER BY t.posting_date;
```

### Check VIES Records for a Period

```sql
SELECT
  vr.id,
  vr.counterparty_vat_number,
  vr.supply_value,
  vr.vat_validated,
  vr.submission_status
FROM vies_records vr
WHERE vr.period_id   = '<period_id>'
  AND vr.business_id = '<business_id>';
```

---

## Audit Events in This Flow

| Event                   | Severity | When                                               |
|-------------------------|----------|----------------------------------------------------|
| VAT_RETURN_REJECTED     | HIGH     | Tax Department rejects the return (Step 1)         |
| VAT_RETURN_AMENDED      | MEDIUM   | Old return row marked AMENDED (Step 3.1)           |
| VAT_PERIOD_CALCULATED   | LOW      | Recalculation via ledger.calc_vat (Step 3.2)       |
| VAT_RETURN_SUBMITTED    | LOW      | Amended return submitted (Step 4.3)                |
| VAT_RETURN_ACCEPTED     | LOW      | Tax Department accepts amended return (Step 5.1)   |

---

## Related Documents

- `schemas/vat_return_schema.md` — vat_returns table and status lifecycle
- `schemas/vies_record_schema.md` — VIES intra-EU supply records
- `schemas/vies_submission_tracking_schema.md` — VIES declaration tracking
- `tools/tool_vat_calc.md` — VAT recalculation tool (recalculate=true)
- `tools/tool_period_lock.md` — period lock preconditions reference accepted return
- `runbooks/period_amendment_runbook.md` — ledger corrections inside a period
- `runbooks/vies_submission_failure_runbook.md` — VIES-specific failure recovery
- `runbooks/vat_recalculation_runbook.md` — forced recalculation operational guide
- `policies/vies_quarterly_eligibility_policy.md` — VIES obligation rules
