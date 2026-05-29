# vies_quarterly_eligibility_policy

**Category:** Policies · **Owning block:** 11 — Ledger & Cyprus VAT Engine · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

Cyprus quarterly VIES (VAT Information Exchange System) eligibility rules. VIES filings cover intra-EU supplies of goods and services; Cyprus businesses file quarterly returns to the Cyprus VAT authority. This policy pins which transactions roll up into which VIES quarter, plus the period-field-change behaviour for adjustments.

Per Stage 1 decision: "VIES scope in MVP: Full VIES file export to the current specification — not just a data model and summary report." This policy supports the canonical implementation.

---

## VIES eligibility per transaction

A transaction is VIES-relevant when `draft_ledger_entries.vies_relevant = true`. The projection is:

```sql
CASE
  WHEN vat_treatment = 'EU_REVERSE_CHARGE' THEN true
  WHEN vat_treatment = 'IMPORT_OR_ACQUISITION'
    AND import_acquisition_subtype = 'INTRA_EU_ACQUISITION' THEN true
  ELSE false
END
```

Per `vat_treatment_enum`. The full list of cases:

| `vat_treatment` | VIES-relevant? |
| --- | --- |
| `EU_REVERSE_CHARGE` (IN-side B2B service to validated EU client) | ✓ |
| `IMPORT_OR_ACQUISITION` with `intra_eu_acquisition_subtype` (OUT-side acquisition) | ✓ |
| `IMPORT_OR_ACQUISITION` with non-EU subtype | ✗ |
| `NON_EU_SERVICE` (zero-rated export of services to non-EU) | ✗ (per the 2026-05-08 Block 11 Phase 05 IN-3 fix) |
| `DOMESTIC_*` (any) | ✗ |
| `OUTSIDE_SCOPE` | ✗ |
| `UNKNOWN` | ✗ (UNKNOWN treatments are deferred — they don't enter VIES until resolved) |

## Cyprus quarterly periods

Cyprus VAT quarters align with calendar quarters by default:

| Quarter | Months | Submission deadline |
| --- | --- | --- |
| Q1 | Jan / Feb / Mar | 10th of May |
| Q2 | Apr / May / Jun | 10th of August |
| Q3 | Jul / Aug / Sep | 10th of November |
| Q4 | Oct / Nov / Dec | 10th of February (following year) |

(Cyprus tax authority's actual deadlines may vary; Block 16's reminder system tracks the current deadline per the operator's tax-advisor input. The dates above are illustrative.)

## Period assignment per transaction

A VIES-eligible transaction's quarter is determined by the accounting-impact date — typically the transaction date, but per the Block 13 Phase 11 dual-date rule, late credit notes may have a different accounting-impact date than their issuance date:

```
accounting_impact_date =
  CASE
    WHEN credit_note_against_invoice_in_earlier_period THEN original_invoice_accounting_date
    ELSE transaction_date
  END
```

The accounting_impact_date determines the VIES quarter via:

```
period_year = year_of(accounting_impact_date)
period_quarter = ceil(month_of(accounting_impact_date) / 3)
```

## Aggregation

Per `vies_record_format`: one VIES record per `(client_country_iso, client_vat_number, transaction_type, period_year, period_quarter)` tuple. Multiple invoices to the same client in the same quarter aggregate into one record with summed `value_eur_cents` and `transaction_count`.

```sql
SELECT
  counterparty_country_iso,
  counterparty_vat_number,
  CASE
    WHEN vat_treatment = 'EU_REVERSE_CHARGE' AND direction = 'IN_INCOME' THEN 'SERVICE'
    WHEN vat_treatment = 'EU_REVERSE_CHARGE' AND direction IN ('OUT_EXPENSE') THEN 'GOODS_SUPPLY'
    -- ... etc per vies_record_format
  END AS transaction_type,
  $period_year AS period_year,
  $period_quarter AS period_quarter,
  SUM(amount_eur_cents) AS value_eur_cents,
  COUNT(*) AS transaction_count
FROM archive.locked_ledger_entries
WHERE business_id = $business_id
  AND vies_relevant = true
  AND ...
GROUP BY counterparty_country_iso, counterparty_vat_number, transaction_type;
```

## Period-field-change behaviour for adjustments

When an adjustment changes a record's VIES classification (e.g., via `CORRECT_VAT_TREATMENT` per `out_adjustment_policies`):

| Change | VIES impact |
| --- | --- |
| Non-VIES → VIES | A new VIES record is added for the original quarter (NOT the adjustment quarter) |
| VIES → non-VIES | The original quarter's VIES record decrements |
| VIES → different VAT number | The original record decrements; a new record for the new VAT number is added to the same quarter |
| VIES amount changes | The original record's value_eur_cents is adjusted |

All changes apply to the **original** quarter, not the adjustment quarter. This is the Cyprus dual-date rule: the accounting-impact date for VIES purposes is the original transaction's period.

A subsequent VIES export of the affected quarter shows the corrected aggregation. Per Block 16 Phase 11's regulator XML generation: the export uses the most-recent corrected state.

## Re-filing

Per Cyprus VIES rules, a previously-filed quarter can be amended via a corrective filing. The product surfaces this via:

1. Operator triggers "Regenerate Q1 VIES for filing" from settings
2. Block 16 Phase 11 generates the current state (incorporating any post-original-filing adjustments)
3. The export carries a "corrective filing" marker that the user reads alongside the regulator's submission

Per Stage 1: filing the corrective return is the user's responsibility — the product produces the artefact, the user submits it.

## Inclusion of historical adjustments

An adjustment dated within the current quarter against a transaction from the previous quarter:

- Modifies the **previous** quarter's VIES aggregation (per the dual-date rule)
- Does NOT affect the current quarter's aggregation

This is counterintuitive at first (the adjustment "happens" in the current quarter) but matches Cyprus VAT logic — the accounting impact is for the transaction's original period.

## Audit events

| Event | When |
| --- | --- |
| `LEDGER_VIES_PERIOD_ASSIGNED` | New VIES-relevant entry created |
| `LEDGER_VIES_PERIOD_CHANGED` | Adjustment shifted a record's VIES quarter (rare — typically the period stays the same; this fires when a credit note's accounting-impact date crosses a quarter) |
| `EXPORT_VIES_GENERATED` | Block 16 produces the export |
| `EXPORT_VIES_CORRECTIVE_FILING_FLAGGED` | Export marked as corrective |

## Cross-references

- `vat_treatment_enum` — closed VAT taxonomy + VIES projection
- `vies_record_format` — record shape (CSV + XML)
- `transaction_type_enum` — IN_INCOME / OUT_EXPENSE / acquisition routing
- `out_adjustment_policies` — adjustment-driven VIES changes
- `tool_credit_note_ledger_mapping` — credit-note Cyprus dual-date rule
- `audit_log_policies` — event family
- Block 11 Phase 06 — reverse charge & VIES relevance (architecture)
- Block 13 Phase 11 — IN_ADJUSTMENT workflow type + dual-date rule
- Block 16 Phase 11 — accountant pack & VIES regulator XML
- Stage 1 decision — full VIES file export in MVP
