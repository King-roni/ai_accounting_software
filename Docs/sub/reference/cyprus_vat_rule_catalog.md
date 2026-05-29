# Cyprus VAT Rule Catalog

**Category:** Reference data · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Canonical reference for Cyprus VAT rates, deductibility rules, intra-EU treatment, reverse charge application, and special schemes. The ledger engine reads from `vat_treatment_enum` and the rate table; this document is the human-readable source of truth for those values. Contradictions between this document and the code are bugs to be fixed in the code.

---

## Block reference

Block 11 — Ledger & Cyprus VAT. The `ledger.compute_vat_amounts` tool applies rules from this catalog when assigning `vat_treatment` and computing `vat_amount_eur` on ledger entries.

---

## Legal basis

- **Cyprus VAT Law:** N.95(I)/2000 as amended. The primary domestic instrument. Governs registration thresholds, return filing obligations, rate schedules, and exemptions applicable in Cyprus.
- **EU VAT Directive 2006/112/EC:** The EU framework directive. Cyprus is bound by its provisions as an EU member state. Where Cyprus national law and the Directive conflict, the Directive prevails per EU law hierarchy.
- **Council Implementing Regulation (EU) 282/2011:** Technical implementing rules for the Directive, directly applicable in Cyprus without national transposition.

Rate changes enacted by the Cyprus Tax Department are reflected in `vat_rate_table_versions`. The platform does not apply rates retroactively; the rate in effect on the transaction date applies.

---

## Rate table

| Rate | Category | Applies to |
| --- | --- | --- |
| **19%** | Standard | All goods and services not listed below. Default rate when no specific rule applies. |
| **9%** | Reduced | Hotel accommodation and related services; restaurant and catering services; passenger transport (taxi, bus, ferry within Cyprus). |
| **5%** | Reduced | Books and printed publications (including e-books as of 2022 amendment); newspapers and periodicals; pharmaceutical products and medicines; infant formula and baby food. |
| **0%** | Zero | Exports of goods outside the EU; intra-EU supplies of goods to VAT-registered businesses (B2B); international passenger transport; food supplied by charities. |
| **Exempt** | Exempt | Financial services (lending, deposits, payment processing); insurance and reinsurance; medical and dental services by licensed practitioners; educational services by recognised institutions; letting of immovable property (where VAT option has not been exercised by the landlord); postal services by the national operator. |

**Exempt vs. Zero distinguished:** Zero-rated supplies are taxable at 0%; the supplier can reclaim input VAT. Exempt supplies are outside the VAT system for output purposes; the supplier cannot reclaim input VAT attributable to exempt supplies.

The standard 19% rate applies unless the platform's classification output includes an explicit `vat_treatment` value that maps to a reduced, zero, or exempt rate. Unclassified transactions default to 19%.

---

## Deductibility table

Input VAT incurred in connection with a Cyprus VAT-registered business is deductible subject to the following rules:

| Category | Deductibility | Condition |
| --- | --- | --- |
| Business goods and services at standard or reduced rate | **100%** | Used exclusively for taxable business purposes |
| Passenger cars (purchase, lease, fuel) | **50%** | Applies regardless of business-use proportion; hardcoded by Cyprus VAT law. No apportionment above 50% is permitted. |
| Entertainment and hospitality | **0%** | Non-deductible in full. Applies to restaurant meals, events, gifts above minor threshold. |
| Non-business expenditure | **0%** | Personal or non-business use; no deduction. |
| Mixed-use (partly taxable, partly exempt activities) | **Partial (pro-rata)** | Deductible proportion = `taxable_turnover / total_turnover` for the period. Computed at business level, not per transaction. |

The 50% cap on passenger cars is encoded as `vat_deductibility_rate = 0.50` in the VAT entry for relevant transaction categories. The platform sets this automatically when `transaction_category = VEHICLE_EXPENSE` and `vehicle_type = PASSENGER_CAR`.

---

## Intra-EU treatment matrix

For Cyprus businesses transacting with other EU member state counterparties:

| Transaction type | VAT treatment | Notes |
| --- | --- | --- |
| B2B goods sold to EU-registered buyer | `ZERO_INTRAEU` | Supplier charges 0%; buyer accounts for acquisition VAT in their own country. VIES validation of buyer's VAT number is mandatory before applying this treatment. |
| B2B services to EU-registered buyer (general rule) | `REVERSE_CHARGE` | Place of supply = buyer's country; buyer self-accounts for VAT. Cyprus supplier does not charge VAT. |
| B2C goods below OSS threshold (€10,000 p.a.) | `STANDARD_19` | Supplier accounts for VAT at Cyprus rate. Once threshold exceeded, OSS or registration in buyer's country applies. |
| B2C goods above OSS threshold | `OSS` | Supplier registers under One Stop Shop; charges buyer's country rate; accounts via OSS return. Platform flags these for manual VAT return handling. |
| B2B goods received from EU supplier (acquisitions) | `ACQUISITION_REVERSE_CHARGE` | Buyer (Cyprus business) self-accounts: output VAT recorded at 19%, input VAT reclaimed at 19% (net zero for fully taxable businesses). |

**VIES validation requirement:** `ZERO_INTRAEU` and `REVERSE_CHARGE` treatments cannot be applied without a confirmed `vies_records` row showing `is_valid = true` for the counterparty's VAT number. If VIES validation is pending or failed, treatment defaults to `STANDARD_19` with a review issue raised.

---

## Reverse charge application

Reverse charge applies when `vat_treatment = REVERSE_CHARGE` or `ACQUISITION_REVERSE_CHARGE`.

The ledger engine creates two VAT entries for the same ledger entry:

1. An **output VAT entry**: `vat_type = OUTPUT`, `vat_rate = 0.19`, `vat_amount_eur = gross_amount × 0.19`. This entry represents the VAT the business notionally owes as recipient.
2. An **input VAT entry**: `vat_type = INPUT`, `vat_rate = 0.19`, `vat_amount_eur = gross_amount × 0.19`. This entry represents the input VAT the business reclaims.

For fully taxable businesses these two entries net to zero. For businesses with partial exemption, the input VAT entry is subject to the pro-rata deductibility calculation.

Both entries reference the same `ledger_entry_id` and are tagged with `reverse_charge = true`.

---

## Special schemes

### Tour Operators Margin Scheme (TOMS)

Applies to Cyprus businesses acting as tour operators buying in and reselling travel services as principal. VAT is calculated on the margin (selling price minus cost of bought-in services) rather than on the full supply value. `vat_treatment = TOMS_MARGIN` flags these entries. Bought-in travel services under TOMS carry `vat_treatment = TOMS_BOUGHT_IN` and are non-deductible for input VAT.

### Margin scheme for second-hand goods

Applies to dealers in second-hand goods, works of art, collector's items, and antiques. VAT is calculated on the dealer's margin. `vat_treatment = MARGIN_SCHEME` flags these entries. No input VAT is deductible on the original purchase of the goods sold under the margin scheme.

Both special schemes require manual classification; the platform does not auto-detect TOMS or margin scheme eligibility. They are surfaced as review issues when the classification engine flags `SPECIAL_SCHEME_CANDIDATE`.

---

## VAT return filing obligations

| Threshold / Condition | Obligation |
| --- | --- |
| Taxable turnover > €15,600/year | Mandatory VAT registration |
| Voluntary registration | Permitted below threshold |
| Standard VAT return period | Quarterly |
| VIES (ESL) return period | Quarterly for goods; monthly if intra-EU services exceed threshold |
| VAT payment due | 40 days after end of the return period |

VIES return generation and submission tracking are handled by Block 16. See `vies_submission_tracking_schema.md`.

---

## Platform VAT treatment enum mapping

The following table maps the closed `vat_treatment` enum values used throughout the platform to the rules in this catalog. Any `vat_treatment` not listed here is invalid and will be rejected at ledger entry creation time.

| `vat_treatment` value | Rate applied | Deductibility | Description |
| --- | --- | --- | --- |
| `STANDARD_19` | 19% | 100% (default) | Standard Cyprus rate |
| `REDUCED_9` | 9% | 100% | Reduced rate: hospitality, transport |
| `REDUCED_5` | 5% | 100% | Reduced rate: books, medicines, infant food |
| `ZERO_EXPORT` | 0% | 100% | Zero-rated export |
| `ZERO_INTRAEU` | 0% | 100% | Zero-rated intra-EU B2B supply; VIES required |
| `REVERSE_CHARGE` | 0% (output); 19% self-account | Per deductibility rules | B2B services from EU supplier |
| `ACQUISITION_REVERSE_CHARGE` | 0% net for fully taxable businesses | Per deductibility rules | Intra-EU goods acquisition |
| `EXEMPT` | N/A | 0% input VAT | Exempt supply category |
| `TOMS_MARGIN` | 19% on margin only | N/A | Tour Operators Margin Scheme |
| `TOMS_BOUGHT_IN` | 0% | 0% | Bought-in services under TOMS |
| `MARGIN_SCHEME` | 19% on margin only | 0% on purchase | Second-hand goods margin scheme |
| `OSS` | Buyer's country rate | 100% | One Stop Shop B2C cross-border |
| `UNKNOWN` | Pending | Pending | Unresolved; triggers review issue |

`UNKNOWN` is a valid runtime value indicating that VAT treatment could not be determined during the LEDGER phase. It is never a terminal state; all `UNKNOWN` entries must be resolved before period finalization. Finalization precondition checks reject any period containing unresolved `UNKNOWN` entries.

---

## VAT number format reference

Cyprus VAT numbers follow the format `CY` + 8 digits + 1 letter (e.g., `CY12345678X`). Format validation is handled by `client_vat_validation_policy.md`. VIES validation confirms the number is active; format validation is a prerequisite before a VIES call is made.

EU member state VAT number formats are validated using the per-country regex patterns maintained in the platform's country VAT format reference table. Format validation failure prevents `ZERO_INTRAEU` or `REVERSE_CHARGE` treatment from being applied and raises a `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED` event.

---

## Cross-references

- `vat_entry_schema.md` — DDL for `vat_entries`; `vat_treatment` field and rate storage
- `vat_treatment_enum.md` — the closed enum of valid `vat_treatment` values; maps to rates in this catalog
- `client_vat_validation_policy.md` — client-side VAT number format validation; VIES trigger conditions
- `vies_record_schema.md` — VIES lookup result storage; `is_valid`, `cache_expires_at`
- Block 11 — Ledger & Cyprus VAT phase doc
- Block 16 — Dashboard & Reporting (VIES return generation and submission lifecycle)
