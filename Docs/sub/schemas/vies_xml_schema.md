# VIES XML Schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

Structure of the VIES XML submission file for the EC Sales List (ESL) — the periodic Cyprus-specific report of intra-EU supplies submitted to the Cyprus Tax Department. The XML produced by `report.generate_vies_xml` is the formal regulator filing artifact, distinct from the `vies_export.csv` included in the finalization archive bundle.

---

## 1. Overview and regulatory context

The EC Sales List (ESL) is a mandatory periodic declaration for Cyprus VAT-registered businesses that make intra-EU supplies. It reports the total value of zero-rated intra-EU supplies per trading partner (counterparty VAT number and country) for the declaration period. Cyprus businesses submit the ESL to the Cyprus Tax Department via the TaxisNet portal.

**Filing periodicity:** monthly (standard). Quarterly eligibility is deferred to Stage 2+ per `archive_step_up_policy` scope decisions. This sub-doc covers monthly filings only.

**Currency:** all values are in EUR. Transactions settled in other currencies are converted using the ECB reference rate on the transaction date (per `vat_rate_table_reference`, Section 3 — ECB rate sourcing).

**Source filter:** only locked ledger entries with `vat_treatment = INTRAEU_SUPPLY_ZERO` are included. All other VAT treatments are excluded from the VIES XML.

---

## 2. XSD conformance

The generated XML conforms to the Cyprus Tax Department's official VIES XSD.

**Reference version:** Cyprus VIES Submission XSD v2.1 (as published by the Cyprus Tax Department at `https://www.taxisnet.mof.gov.cy/` — external reference; the actual XSD is not reproduced here but is version-pinned in the `report.generate_vies_xml` tool implementation).

The generator validates the produced XML against the XSD before returning. Validation failure triggers the Phase 09 export pipeline's failure-mode taxonomy (see `export_pipeline_policy`). The XSD version is recorded in the export artifact metadata. If the Cyprus Tax Department publishes a new XSD version, the tool requires a schema version bump per `tool_naming_convention_policy`.

---

## 3. File-level structure

The VIES XML file follows this high-level structure:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<VIESDeclaration
  xmlns="urn:cy:mof:taxisnet:vies:v2.1"
  schemaVersion="2.1">

  <DeclarationHeader>
    <SubmissionPeriod>...</SubmissionPeriod>
    <SubmitterVATNumber>...</SubmitterVATNumber>
    <SubmitterName>...</SubmitterName>
    <SubmissionDate>...</SubmissionDate>
    <DeclarationCurrency>EUR</DeclarationCurrency>
    <TotalRecords>...</TotalRecords>
    <TotalValueEUR>...</TotalValueEUR>
  </DeclarationHeader>

  <Transactions>
    <Transaction>
      <CounterpartyCountryCode>...</CounterpartyCountryCode>
      <CounterpartyVATNumber>...</CounterpartyVATNumber>
      <TotalValueEUR>...</TotalValueEUR>
      <TransactionType>...</TransactionType>
    </Transaction>
    <!-- one Transaction element per unique counterparty -->
  </Transactions>

</VIESDeclaration>
```

---

## 4. Header fields

| XML element | Format | Source | Notes |
|---|---|---|---|
| `SubmissionPeriod` | `YYYY-MM` | Input parameter `period_start` | Monthly period identifier |
| `SubmitterVATNumber` | Text | `businesses.vat_number` | Cyprus VAT number, format `CY` + 8 digits + letter |
| `SubmitterName` | Text | `businesses.legal_name` | Legal business name as registered |
| `SubmissionDate` | ISO 8601 `YYYY-MM-DD` | `now()` at generation time | Date the XML was generated |
| `DeclarationCurrency` | Static `EUR` | — | Always EUR; non-EUR amounts are converted before aggregation |
| `TotalRecords` | Integer | Count of `Transaction` elements | Must match actual count in `Transactions` |
| `TotalValueEUR` | Decimal string 2dp | Sum of all `TotalValueEUR` in `Transaction` | Cross-check field; XSD validator confirms this matches |

---

## 5. Per-counterparty row (`Transaction` element)

Each `Transaction` element represents the aggregated total of all intra-EU supplies to one counterparty for the declaration period.

| XML element | Format | Source | Notes |
|---|---|---|---|
| `CounterpartyCountryCode` | ISO 3166-1 alpha-2 | `ledger_entries.counterparty_country_code` | EU member state codes only; non-EU rows are excluded at source filter |
| `CounterpartyVATNumber` | Text | `ledger_entries.counterparty_vat_number` | Format-validated per Block 11 Phase 04; must pass EU VIES format check |
| `TotalValueEUR` | Decimal string 2dp | Sum of `vies_value_basis_eur` from `archive.locked_ledger_entries` per counterparty | Rounded to 2 decimal places at aggregation; rounding mode: `ROUND_HALF_UP` |
| `TransactionType` | Enum — see below | Derived from `vat_treatment` mapping | One of `GOODS`, `SERVICES`, `TRIANGULATION` |

### TransactionType derivation

| Source condition | `TransactionType` |
|---|---|
| `vat_treatment = INTRAEU_SUPPLY_ZERO` AND `transaction_type = OUT_EXPENSE` (goods purchase) | `GOODS` |
| `vat_treatment = INTRAEU_SUPPLY_ZERO` AND `transaction_type = IN_INCOME` (services rendered) | `SERVICES` |
| `vat_treatment = INTRAEU_SUPPLY_ZERO` AND `is_triangulation_supply = true` | `TRIANGULATION` |

The `is_triangulation_supply` flag is a column on `archive.locked_ledger_entries` populated by Block 11 Phase 06's VIES counterparty assignment logic. If a counterparty has both `GOODS` and `SERVICES` transactions in the same period, two separate `Transaction` elements are emitted — one per `TransactionType`. Aggregation key is `(counterparty_country_code, counterparty_vat_number, transaction_type)`.

---

## 6. Currency conversion

Transactions not settled in EUR are converted to EUR using the ECB reference rate on the transaction date. The conversion rate source and storage are governed by `vat_rate_table_reference`. The `vies_value_basis_eur` field on `archive.locked_ledger_entries` stores the pre-converted EUR value; the VIES XML generator consumes this field directly and does not re-convert.

If `vies_value_basis_eur` is NULL for a qualifying row (conversion failure at finalization time), the generator raises a `VIES_XML_GENERATION_FAILED` error with `reason = MISSING_EUR_BASIS`. This is treated as a deterministic failure; the user must resolve the source data issue and re-request the export.

---

## 7. `report.generate_vies_xml` tool

```typescript
engine.registerTool({
  name: "report.generate_vies_xml",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT", "EXTERNAL_CALL"],
  // EXTERNAL_CALL: XSD validation may use an external schema registry
  ai_tier: "NONE",
  audit_events: ["VIES_XML_GENERATED"],
  description_ref: "Docs/sub/tools/tool_report_generate_vies_xml.md",
});
```

**Input schema:**

```typescript
interface GenerateViesXmlInput {
  business_id: string;               // UUID v7
  period_start: string;              // ISO 8601 date (first day of the month)
  period_end: string;                // ISO 8601 date (last day of the month)
  workflow_run_id?: string;          // Optional: scope to a specific run
}
```

**Output:** the generated XML bytes, a `file_hash` (SHA-256 hex), and `byte_size`. The export is stored as an export artifact in the export-temp bucket (Block 04 Phase 05), not in the `archive-bundles` bucket. Export artifact retention follows the 24-hour TTL per `export_pipeline_policy` Section 4 (operational export, not archive-derived).

**Permission gate:** `REPORT_EXPORT_FULL` per `export_pipeline_policy` Section 5.

**Source data requirement:** the period must be `FINALIZED`. If the period is not finalized, generation is rejected with `EXPORT_FAILED` and `reason = PERIOD_NOT_FINALIZED`.

---

## 8. Corrective filing

If a previously submitted VIES XML contained an error and a corrective XML must be generated (following Cyprus Tax Department procedures), the generator accepts a `corrective_for_period` parameter. Corrective XMLs include an `AmendmentIndicator = true` element in the header. The corrective filing emits `EXPORT_VIES_CORRECTIVE_FILING_FLAGGED` (which exists in `audit_event_taxonomy` under the `EXPORT` domain).

---

## 9. Audit events

| Event | Severity | When |
|---|---|---|
| `VIES_XML_GENERATED` | LOW | XML file successfully produced and stored as export artifact |

---

## Cross-references

- `data_layer_conventions_policy` — SHA-256 file hash; decimal string amounts; canonical JSON for audit payloads
- `export_pipeline_policy` — async dispatch; signed-URL TTL; permission gate (`REPORT_EXPORT_FULL`); operational export retention (24-hour TTL per export_pipeline_policy)
- `vat_rate_table_reference` — ECB reference rate sourcing for non-EUR currency conversion
- `vies_record_schema` — per-ledger-entry VIES fields (`vies_relevant`, `vies_value_basis_eur`, `counterparty_vat_number`, `is_triangulation_supply`)
- `vat_treatment_enum` — 8-value closed enum; `INTRAEU_SUPPLY_ZERO` is the sole qualifying treatment
- `locked_ledger_entries_schema` — source table; `vies_value_basis_eur` field
- `audit_log_policies` — `VIES_XML_GENERATED` event naming; `EXPORT` domain (under `EXPORT_VIES_*`)
- `audit_event_taxonomy` — `EXPORT` domain: `EXPORT_VIES_GENERATED`, `EXPORT_VIES_CORRECTIVE_FILING_FLAGGED`
- `tool_naming_convention_policy` — `report.generate_vies_xml` tool name; `EXTERNAL_CALL` side-effect class
- `mobile_write_rejection_endpoints` — export configuration is desktop-only; export initiation is permitted on mobile per `export_pipeline_policy` Section 6
- Block 16 Phase 11 — accountant pack and VIES XML generator architecture
- Block 16 Phase 09 — export dispatcher; `vies_export_file` export kind registration
- Block 11 Phase 06 — VIES contract; `vies_relevant` flag; counterparty rollup logic
- Block 04 Phase 05 — export-temp bucket; 24-hour TTL export storage
