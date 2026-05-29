# VAT Treatment Policy

**Category:** Policies · **Owning block:** 09 — VAT & Compliance · **Stage:** 4 sub-doc (Layer 2)

This policy defines how specific transaction types are treated for VAT purposes on the platform. It covers domestic sales, intra-EU supplies and acquisitions, imports and exports, reverse charge, self-billing, and vouchers. For the rate values themselves (19%, 9%, 5%, zero, exempt), see `vat_rate_policy.md`.

---

## 1. Domestic Sales

Sales made by a Cyprus VAT-registered business to customers in Cyprus are subject to the following treatment:

| Supply Type | VAT Treatment | Platform Category Code |
|---|---|---|
| Standard goods and services | 19% standard rate | CY_STANDARD |
| Hospitality and passenger transport | 9% reduced rate | CY_REDUCED_9 |
| Food, books, pharmaceuticals, cultural | 5% reduced rate | CY_REDUCED_5 |
| Exports to non-EU | Zero-rated | CY_ZERO |
| Healthcare, education, financial, insurance | Exempt | CY_EXEMPT |

The platform assigns the default treatment based on the account code mapped to the transaction. The AI classification engine may override the default if the transaction description provides higher-confidence evidence of a different treatment.

---

## 2. Intra-EU Supplies (Sales to EU VAT-Registered Businesses)

Sales from a Cyprus business to a VAT-registered business in another EU member state qualify as zero-rated intra-Community supplies, subject to the following conditions:

1. The customer is registered for VAT in another EU member state (confirmed via VIES — see `vies_record_schema.md`).
2. Goods physically move from Cyprus to another EU member state (for goods) or the service qualifies under the B2B general rule (for services).
3. The Cyprus supplier holds valid proof of the customer's VAT registration at the time of supply.

Platform behaviour: when `client.client_type = 'EU_COMPANY'` and `client.eu_vat_registered = true`, the platform defaults to zero-rate treatment for the supply and triggers VIES validation. The VAT category is set to `CY_ZERO` with a sub-type of `INTRA_EU_SUPPLY`.

VIES validation failures block invoice issuance at the BLOCKING severity level. The business must resolve the validation failure before the invoice can be finalised.

---

## 3. Intra-EU Acquisitions (Purchases from EU VAT-Registered Businesses)

When a Cyprus VAT-registered business receives goods or services from a VAT-registered supplier in another EU member state, the acquisition VAT mechanism applies:

- The buyer accounts for VAT as if they had made the supply themselves (acquisition VAT).
- The buyer simultaneously records the acquisition VAT as output tax and — if the goods/services are used for taxable purposes — claims an equivalent input tax credit.
- Net VAT effect: zero, unless the goods/services relate to exempt activities (in which case the input credit is restricted).

Platform behaviour: transactions with `client.client_type = 'EU_COMPANY'` on the buy side are flagged for acquisition VAT treatment. Two `vat_entries` rows are created: one as `ACQUISITION_OUTPUT` and one as `ACQUISITION_INPUT`. Both appear on the VAT return in the correct boxes.

---

## 4. Exports Outside the EU

Sales of goods or services to customers outside the EU are zero-rated for VAT purposes. No VAT is charged on the supply. The exporter may recover input VAT on costs related to the export.

Evidence requirements: the platform records the `client.country_code` and `client.client_type = 'NON_EU_COMPANY'`. The zero-rate treatment is applied automatically. Customs documentation (CMR, export declaration) is stored as an attachment to the invoice but is not validated by the platform.

Platform category code: `CY_ZERO` with sub-type `EXPORT_NON_EU`.

---

## 5. Imports from Outside the EU

VAT on goods imported from outside the EU is collected by Cyprus Customs at the point of importation. The import VAT is paid to Customs, not to the supplier.

Platform behaviour: import VAT is recorded as a separate bank charge line (paid to Customs) and linked to the relevant import invoice. The import VAT is recorded as `IMPORT_VAT_INPUT` and is recoverable as input VAT if the goods are used for taxable purposes.

The platform does not generate a customs declaration. It records the import VAT payment and the associated input credit claim.

---

## 6. Reverse-Charge Mechanism

The reverse-charge mechanism applies in Cyprus in the following domestic scenarios:

- Supplies of construction services where the recipient is a VAT-registered building contractor.
- Supplies of certain electronic and other goods listed in the Cyprus VAT Law Fourth Schedule.
- B2B supplies of services received from overseas suppliers (under the general rule, the Cyprus recipient accounts for VAT under reverse charge).

Under reverse charge, the supplier does not charge VAT. The recipient accounts for both the output tax (as if they made the supply) and the input tax credit (if the supply is for taxable use).

Platform behaviour: when the `vat_treatment_enum` is set to `REVERSE_CHARGE`, the platform creates two `vat_entries` rows: `REVERSE_CHARGE_OUTPUT` and `REVERSE_CHARGE_INPUT`. The net effect on the VAT return is zero if the recipient is fully taxable.

---

## 7. Self-Billing Arrangements

Self-billing is permitted under Cyprus VAT law when agreed in writing between the supplier and the recipient. Under self-billing, the recipient (not the supplier) issues the invoice.

Platform support: self-billing invoices are flagged with `is_self_billed = true` on the `invoices` table. The VAT treatment of a self-billed invoice follows the same rules as a standard invoice — the supply type and applicable rate determine the VAT treatment, not the billing direction.

The self-billing agreement must be documented and attached to the first self-billed invoice. The platform records the agreement reference in `invoice.self_billing_agreement_ref`.

---

## 8. Vouchers and Tokens

Cyprus has implemented the EU Voucher Directive (2016/45/EU). The VAT treatment of vouchers depends on whether they are single-purpose vouchers (SPV) or multi-purpose vouchers (MPV):

- **Single-purpose voucher (SPV)**: VAT treatment is known at the time of issue (because the goods/services and supply location are known). VAT is due at the time of transfer of the voucher.
- **Multi-purpose voucher (MPV)**: VAT treatment is not yet known at the time of issue. VAT is due only when the voucher is redeemed.

Platform support: vouchers issued by the business are classified on the `invoice.voucher_type` field (`SPV` or `MPV`). SPV issuance generates a VAT entry. MPV issuance does not generate a VAT entry; the VAT entry is created on redemption.

---

## 9. VAT Return Box Mapping

| Transaction Type | Box on Cyprus VAT Return |
|---|---|
| Standard rated supplies | Box 1 (output VAT) |
| Zero-rated and exempt supplies | Box 8 (value, no VAT) |
| Intra-EU supplies | Box 8 + VIES listing |
| Intra-EU acquisitions | Box 2 (output) + Box 4 (input) |
| Reverse charge received | Box 2 (output) + Box 4 (input) |
| Import VAT | Box 4 (input, separately identified) |
| Input VAT on purchases | Box 4 |

---

## 10. Audit Events

| Event | Trigger |
|---|---|
| `VAT_TREATMENT_ASSIGNED` | VAT treatment set on a transaction or invoice |
| `VAT_TREATMENT_OVERRIDDEN` | Manual override of assigned VAT treatment |
| `REVERSE_CHARGE_APPLIED` | Reverse-charge entries created |
| `ACQUISITION_VAT_APPLIED` | Intra-EU acquisition entries created |

---

## Related Documents

- `vat_rate_policy.md` — rate values (19%, 9%, 5%, zero, exempt)
- `vat_entry_schema.md` — VAT entry DDL
- `vat_return_schema.md` — VAT return structure and box mapping
- `vies_record_schema.md` — VIES validation for intra-EU supplies
- `vies_submission_schema.md` — VIES listing submission
- `client_vat_validation_policy.md` — customer VAT number validation
- `invoice_schema.md` — invoice-level VAT treatment fields
- `expense_classification_policy.md` — VAT treatment on expense classification
