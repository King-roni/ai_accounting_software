# Tool: ledger.calc_vat

**Block:** Ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`ledger.calc_vat` computes the VAT obligation for a given accounting period against the current ledger state. It sums output VAT collected on sales invoices, sums input VAT recoverable from expense ledger entries, and produces a net VAT payable figure together with a full line-item breakdown. Results are cached against the period; callers must set `recalculate = true` to force a fresh computation when the ledger has changed after the first call.

This tool emits an audit event on every successful computation and respects Cyprus-specific VAT rules including the 19 % standard rate, the 9 % and 5 % reduced rates, zero-rated intra-EU supplies subject to VIES reporting, and the reverse-charge mechanism under Article 196 of the EU VAT Directive for cross-border B2B services.

---

## Tool Signature

```
ledger.calc_vat(
  run_id        UUID,          -- the workflow run requesting the calculation
  period_id     UUID,          -- the VAT period to calculate
  recalculate   BOOLEAN        -- if true, bypasses the cache and recomputes from ledger
) -> vat_summary
```

### Capabilities

| Flag             | Value |
|------------------|-------|
| WRITES_AUDIT     | YES   |
| WRITES_RUN_STATE | NO    |
| READS_LEDGER     | YES   |

---

## Inputs

### run_id
- Type: UUID (gen_uuid_v7 format)
- Required: YES
- The workflow run that initiated this calculation. Used to scope audit events and enforce run-level authorization. The run must be in RUNNING or REVIEW_HOLD state; calls from a PAUSED, FINALIZED, or CANCELLED run return 409.

### period_id
- Type: UUID (gen_uuid_v7 format)
- Required: YES
- References `vat_periods(id)`. The period must belong to the same `business_entity_id` as the run. If the period status is LOCKED, the tool returns a 409 PERIOD_ALREADY_LOCKED error without modifying any data.

### recalculate
- Type: BOOLEAN
- Required: NO (default: false)
- When false, the tool returns a cached `vat_summary` if one was produced during the current period and the ledger generation counter has not advanced. When true, the cache is bypassed and the full calculation is re-executed. A recalculation still emits VAT_PERIOD_CALCULATED.

---

## Outputs

The tool returns a `vat_summary` object:

```json
{
  "output_vat":       "<DECIMAL(15,2)>",
  "input_vat":        "<DECIMAL(15,2)>",
  "net_vat_payable":  "<DECIMAL(15,2)>",
  "period_id":        "<UUID>",
  "calculated_at":    "<TIMESTAMPTZ>",
  "from_cache":       "<BOOLEAN>",
  "line_items": [
    {
      "source_type":    "SALES_INVOICE | EXPENSE | REVERSE_CHARGE | VIES_SUPPLY",
      "document_id":    "<UUID>",
      "vat_rate":       "<DECIMAL(5,4)>",
      "vat_rate_label": "STANDARD_19 | REDUCED_9 | REDUCED_5 | ZERO | REVERSE_CHARGE",
      "gross_amount":   "<DECIMAL(15,2)>",
      "net_amount":     "<DECIMAL(15,2)>",
      "vat_amount":     "<DECIMAL(15,2)>",
      "currency":       "<ISO-4217>",
      "fx_rate":        "<DECIMAL(12,6) | null>"
    }
  ]
}
```

`net_vat_payable` = `output_vat` − `input_vat`. A negative result indicates a VAT refund position.

---

## Calculation Logic

### Step 1 — Collect Output VAT

Query all ledger entries in the period where:
- `entry_type = 'OUTPUT_VAT'`
- `business_entity_id` matches the run's entity
- `posting_date` falls within `[period_start, period_end]`
- `status = 'POSTED'` (draft entries excluded)

Sum `vat_amount` across all matching entries. Group by `vat_rate` for the line-item breakdown.

### Step 2 — Collect Input VAT

Query all ledger entries in the period where:
- `entry_type = 'INPUT_VAT'`
- Same business and date constraints as above
- `status = 'POSTED'`
- `blocked_input_vat = false` (certain entertainment expenses have blocked recovery)

Sum `vat_amount` across all matching entries.

### Step 3 — Intra-EU VIES Supplies

Identify ledger entries tagged `vat_treatment = 'INTRA_EU_SUPPLY'`:
- These carry 0 % VAT for output purposes.
- Their gross supply value is accumulated in `vies_value` and reported separately on the VIES declaration; they do NOT reduce net_vat_payable.
- Source documents for VIES entries must have a validated EU VAT number on the counterparty record.

### Step 4 — Reverse Charge (Art. 196 VAT Directive)

For EU B2B cross-border service purchases:
- `vat_treatment = 'REVERSE_CHARGE_RECEIVED'`
- Output VAT is self-assessed and simultaneously recorded as input VAT in the same entry pair.
- Net effect on `net_vat_payable` is zero for fully taxable businesses.
- Both the output and input legs appear in `line_items` with `source_type = 'REVERSE_CHARGE'`.
- Non-deductible reverse charge entries (partial exemption) are flagged separately.

### Step 5 — Currency Conversion

All amounts denominated in non-EUR currencies are converted to EUR using the ECB reference rate for the transaction date. The `fx_rate` field in each line item records the rate applied. If no ECB rate is available for the transaction date, the tool falls back to the nearest available prior-day rate and emits a LOW-severity audit note.

### Step 6 — Cache Write

On successful completion the summary is written to `vat_calculation_cache` keyed on `(period_id, ledger_generation)`. Subsequent calls with `recalculate = false` and the same ledger generation return this cached record without re-querying ledger entries.

---

## Cyprus VAT Rate Reference

| Rate Label    | Rate  | Applicability                                              |
|---------------|-------|------------------------------------------------------------|
| STANDARD_19   | 19 %  | Default rate for goods and services                        |
| REDUCED_9     |  9 %  | Restaurant services, hotel accommodation, passenger transport |
| REDUCED_5     |  5 %  | Food, books, newspapers, pharmaceutical products, medical equipment |
| ZERO          |  0 %  | Intra-EU supplies (VIES), qualifying exports               |
| REVERSE_CHARGE|  0 %  | EU B2B services — tax self-assessed by recipient            |

Rate assignments are driven by the `vat_rate_code` on the ledger entry, which is set at classification time and validated against the Cyprus VAT rate schedule stored in `vat_rate_config`.

---

## Audit Events

| Event                   | Severity | Trigger                                          |
|-------------------------|----------|--------------------------------------------------|
| VAT_PERIOD_CALCULATED   | LOW      | Every successful invocation, cached or live      |

Audit payload includes: `period_id`, `run_id`, `net_vat_payable`, `from_cache`, `line_item_count`, `calculated_at`, `actor_id`.

---

## Error Reference

| Code                   | HTTP | Description                                                              |
|------------------------|------|--------------------------------------------------------------------------|
| PERIOD_ALREADY_LOCKED  | 409  | The requested period is locked; recalculation is not permitted           |
| PERIOD_NOT_FOUND       | 404  | `period_id` does not exist or belongs to a different business entity     |
| RUN_NOT_ACTIVE         | 409  | The calling run is not in RUNNING or REVIEW_HOLD state                   |
| LEDGER_INCONSISTENT    | 422  | Ledger generation mismatch detected mid-calculation; retry required      |
| ECB_RATE_UNAVAILABLE   | 503  | Required FX rate not available; see ecb_rate_unavailable_runbook.md      |

---

## Quarterly Period Default

Cyprus VAT returns are filed quarterly by default (January–March, April–June, July–September, October–December). Businesses with annual turnover exceeding the monthly filing threshold may be required to file monthly; this is stored in `vat_period_config.filing_frequency`. The tool reads `filing_frequency` from the period record and includes it in the audit payload. Annual reconciliation periods are also supported (`return_type = 'ANNUAL'`).

---

## Idempotency

Calling `ledger.calc_vat` multiple times for the same `(run_id, period_id)` combination with `recalculate = false` is idempotent — the same cached summary is returned. With `recalculate = true`, each call performs a fresh computation and overwrites the cache; the audit log records each recalculation as a distinct event.

---

## Mobile

`ledger.calc_vat` does not carry `WRITES_RUN_STATE` and therefore is not subject to the mobile write rejection rule for run-state mutations. However, because it carries `WRITES_AUDIT`, mobile clients must observe the following constraint:

- Mobile callers (identified by `client_platform = 'MOBILE'` in the request context) may call this tool in read-only mode by passing `recalculate = false`.
- Mobile clients must NOT pass `recalculate = true`. Attempts to do so from a mobile session are rejected with HTTP 403 and error code `MOBILE_RECALC_FORBIDDEN`.
- The mobile restriction exists because forced recalculation can trigger downstream cache invalidation and audit chain writes that require a stable, non-interrupted session context.
- Display-only VAT summaries on mobile are served from the `vat_calculation_cache` table via the reporting API and do not invoke this tool directly.

---

## Related Documents

- `schemas/vat_period_schema.md` — period record structure
- `schemas/vat_return_schema.md` — VAT return filing record
- `schemas/vat_entry_schema.md` — individual VAT ledger entry structure
- `schemas/vies_record_schema.md` — VIES intra-EU supply record
- `runbooks/vat_recalculation_runbook.md` — operational guide for forced recalculations
- `runbooks/vat_submission_rejection_runbook.md` — handling Tax Department rejections
- `policies/vies_quarterly_eligibility_policy.md` — VIES eligibility rules
- `tools/tool_ledger_post.md` — upstream ledger posting tool
