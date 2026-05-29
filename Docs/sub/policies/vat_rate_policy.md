# VAT Rate Policy

**Category:** Policies · **Owning block:** 09 — VAT & Compliance · **Stage:** 4 sub-doc (Layer 2)

This policy defines the VAT rates applicable under Cyprus VAT law as implemented in the platform, explains when each rate applies, covers VAT group registration, and describes how the system enforces rate assignment and handles rate changes.

---

## 1. Standard Rate

The standard VAT rate in Cyprus is **19%**. This rate applies to all supplies of goods and services in Cyprus that are not explicitly subject to a reduced rate, zero rate, or exemption under the Cyprus VAT Law (Law 95(I)/2000 and its amendments).

The standard rate is stored in the `vat_categories` table with `rate = 0.19` and `category_code = 'CY_STANDARD'`. It is the default rate assigned when no other rate is explicitly applicable.

---

## 2. Reduced Rates

Cyprus applies two reduced rates:

### 2.1 Nine Percent (9%)

The 9% rate applies to:
- Hotel accommodation and hospitality services (restaurants, cafes — food and beverages consumed on premises).
- Passenger transport services within Cyprus.
- Certain cultural services (admission to cultural events not covered by the 5% rate).

Category code: `CY_REDUCED_9`.

### 2.2 Five Percent (5%)

The 5% rate applies to:
- Food products for human consumption (not restaurant/catering — retail food).
- Pharmaceutical products and medicines.
- Books, newspapers, and periodicals (including e-books as of the 2022 EU harmonisation).
- Cultural services: admission to museums, theatres, concerts, cinemas.
- Repair of private dwellings and housing (social housing schemes).
- Specific social services.

Category code: `CY_REDUCED_5`.

Both reduced rates are stored in the `vat_categories` table with `rate = 0.09` and `rate = 0.05` respectively.

---

## 3. Zero Rate

Zero-rated supplies are taxable supplies on which VAT is charged at 0%. The supplier can recover input VAT. Zero rate applies to:

- Exports of goods outside the EU.
- International transport of passengers and goods (air, sea, and road crossing EU borders).
- Supply of goods to VAT-registered businesses in other EU member states (intra-Community supplies), subject to VIES verification.
- Supply of goods to passengers departing the EU (tax-free retail).

Category code: `CY_ZERO`.

---

## 4. Exempt Supplies

Exempt supplies are not subject to VAT, and the supplier cannot recover input VAT attributable to exempt supplies (partial exemption rules apply where both taxable and exempt supplies are made). Exempt categories in Cyprus:

- Healthcare: medical and dental services by registered practitioners, hospital and nursing services.
- Education: school and university education, vocational training by recognised institutions.
- Financial services: lending, deposit-taking, insurance, and reinsurance.
- Insurance: supply of insurance and reinsurance services.
- Postal services: universal postal services by Cyprus Post.
- Letting of immovable property (residential, with the commercial property option-to-tax available).

Category code: `CY_EXEMPT`.

Exempt supplies do not generate VAT output entries in the platform. Input VAT on costs related exclusively to exempt supplies is blocked from recovery.

---

## 5. Reduced Rate vs Exempt: Key Distinction

A common classification error is treating zero-rated and exempt supplies interchangeably. They are distinct:

| Attribute | Zero Rate | Exempt |
|---|---|---|
| VAT charged | 0% | None |
| Input VAT recovery | Yes, in full | No (or partial, if mixed use) |
| Appears on VAT return | Yes (Box 8 or intra-EU) | No (or only in exempt output box) |
| VIES reporting required | Yes (for intra-EU) | No |

The system enforces this distinction at the VAT entry level. Zero-rated transactions create a `vat_entries` row with `rate = 0` and `vat_type = 'ZERO_RATED'`. Exempt transactions create a `vat_entries` row with `vat_type = 'EXEMPT'` and no rate field.

---

## 6. VAT Group Registration

Cyprus permits VAT grouping: multiple legal entities under common control may register as a single VAT group. Within a VAT group:

- Supplies between group members are disregarded for VAT purposes.
- The representative member submits a single VAT return for the group.

The platform supports VAT group registration via the `business_settings_schema.md` `vat_group_id` field. When a `vat_group_id` is set, intercompany transactions between group members are classified with `vat_type = 'INTRAGROUP'` and excluded from VAT output and input calculations.

---

## 7. VAT Category Enforcement

All transactions processed by the platform must be assigned a `vat_category_id` referencing a row in the `vat_categories` table. The assignment is:

1. Proposed by the AI classification engine based on the transaction's description, counterparty, and amount pattern.
2. Validated against the `vat_categories` table: only active, applicable-for-Cyprus categories are accepted.
3. Confirmed by a reviewer for transactions below the AI confidence threshold.

Manual override of the VAT category is permitted for `org:accountant` and `org:owner` roles. Overrides are logged as `VAT_CATEGORY_OVERRIDDEN` with the previous and new category.

---

## 8. Rate Change Handling

VAT rate changes (e.g. a legislated increase or decrease in the standard or reduced rate) are rare. When a rate change is enacted:

1. A new `vat_categories` row is created with the new rate and an `effective_from` date. The old row is not deleted.
2. The platform uses `effective_from` to select the correct rate for each transaction based on its tax point date (supply date, not invoice date, per Cyprus VAT rules).
3. All existing finalised transactions retain their rate at the time of finalisation. No retroactive recalculation.
4. An audit event `VAT_RATE_CHANGED` is emitted covering the old and new rates and the effective date.
5. The change is communicated to all `org:accountant` and `org:owner` users via an in-app notification.

Rate changes require a platform-level migration and cannot be applied via business entity settings. See `vat_recalculation_runbook.md` for the operational procedure.

---

## 9. Audit Events

| Event | Trigger |
|---|---|
| `VAT_CATEGORY_ASSIGNED` | VAT category set on a transaction |
| `VAT_CATEGORY_OVERRIDDEN` | Manual override of AI-assigned category |
| `VAT_RATE_CHANGED` | Platform-level VAT rate update |

---

## Related Documents

- `vat_entry_schema.md` — VAT entry DDL
- `vat_period_schema.md` — VAT period for grouping entries
- `vat_return_schema.md` — VAT return submission structure
- `vat_treatment_policy.md` — how specific transaction types are VAT-treated
- `vat_validation_cache_schema.md` — VAT number validation cache
- `vies_record_schema.md` — VIES validation for EU supplies
- `client_vat_validation_policy.md` — client-level VAT validation
- `expense_classification_policy.md` — expense classification including VAT category
- `vat_recalculation_runbook.md` — operational procedure for rate changes
