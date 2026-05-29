# VAT Account Code Reference

**Category:** Reference · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Canonical catalog of Cyprus VAT account codes used in the ledger subsystem. These codes follow the Cyprus chart of accounts standard and are the authoritative mapping between `vat_treatment_enum` values and the account code pairs recorded on `ledger_entries` and `vat_entries`. Any change to this catalog requires an amendment to `ledger_account_mapping_version_schema.md` and the creation of a new mapping version.

---

## Purpose

The ledger engine (Block 11) produces double-entry ledger rows for every transaction. VAT-bearing rows require one or more VAT account codes to record the output and input VAT components separately. This document defines:

- The account code structure and range
- All output VAT account codes (2310–2314)
- All input VAT account codes (2410–2414)
- Reverse charge codes (2315, 2415)
- Intra-EU acquisition codes (2316, 2416)
- The mapping from each `vat_treatment_enum` value to its account code pair

---

## Account code structure

Account codes follow a 4-digit scheme aligned with the Cyprus chart of accounts standard. VAT accounts occupy the `2000–2999` range, subdivided as follows:

| Range | Category |
|---|---|
| `2300–2399` | Output VAT (tax collected on sales and deemed supplies) |
| `2400–2499` | Input VAT (tax recoverable on purchases) |

Codes outside these sub-ranges but within `2000–2999` are reserved for future use. The ledger engine must not write to a code outside the defined catalog without a catalog amendment.

---

## Output VAT codes

Output VAT is the tax collected by the business on sales. It is a liability.

| Code | Description | Rate | Notes |
|---|---|---|---|
| `2310` | Standard output VAT | 19% | Applied to standard-rated taxable supplies in Cyprus |
| `2311` | Reduced output VAT | 9% | Restaurant services, hotel accommodation, passenger transport |
| `2312` | Reduced output VAT | 5% | Pharmaceuticals, certain foodstuffs, books, newspapers |
| `2313` | Zero-rated output VAT | 0% | Exports, intra-EU supplies of goods, international transport |
| `2314` | Exempt (no VAT) | n/a | Financial services, insurance, certain land/property transactions; no VAT charged, no input recovery on related costs |

Note on `2314`: exempt transactions do not carry a VAT amount. The `vat_entries` row for an exempt transaction has `vat_rate = 0` and `vat_amount_eur = 0.00`. The account code is recorded on the `ledger_entries` output side to indicate the treatment decision; it is not posted in the VAT control account sense.

---

## Input VAT codes

Input VAT is the tax paid by the business on purchases. It is an asset (recoverable) or an expense (non-recoverable).

| Code | Description | Rate | Deductibility | Notes |
|---|---|---|---|---|
| `2410` | Standard input VAT | 19% | 100% | Fully deductible purchases for business use |
| `2411` | Reduced input VAT | 9% | 100% | Purchases at the 9% reduced rate |
| `2412` | Reduced input VAT | 5% | 100% | Purchases at the 5% reduced rate |
| `2413` | Partially deductible input VAT | 19% | 50% | Passenger car purchase or leasing; Cyprus VAT Act limits recovery to 50% |
| `2414` | Non-deductible input VAT | 19% or reduced | 0% | Entertainment expenses, non-business use; no recovery permitted |

`2413` and `2414` result in a split ledger entry: the recoverable portion of the input VAT is posted to `2413`/`2414`, and the non-recoverable portion is expensed to the relevant expense account rather than the VAT control account.

---

## Reverse charge codes

Reverse charge applies when a Cyprus VAT-registered business receives services from a non-established supplier (B2B intra-EU services, or services under Article 9 of the EU VAT Directive).

| Code | Description | Notes |
|---|---|---|
| `2315` | Output reverse charge | Buyer accounts for output VAT on behalf of the supplier. Posted on the output side. |
| `2415` | Input reverse charge | Buyer recovers input VAT (if fully deductible). Posted on the input side. Offsets `2315` when fully deductible. |

For a fully deductible reverse charge transaction: `2315` and `2415` are posted in equal amounts with opposite signs. The net VAT cash flow is zero. Both codes must appear on the `vat_entries` row to allow correct VAT return population.

For a partially deductible reverse charge (e.g. a reverse charge on a passenger car): only the recoverable portion offsets; the remainder is expensed.

---

## Intra-EU acquisition codes

Intra-EU acquisition VAT applies to goods purchased from a VAT-registered supplier in another EU member state and brought into Cyprus.

| Code | Description | Notes |
|---|---|---|
| `2316` | EU acquisition output VAT | The buyer (Cyprus business) accounts for output VAT at the Cyprus standard rate on the acquisition value. |
| `2416` | EU acquisition input VAT | The buyer recovers the input VAT if the acquisition is for taxable business use. Offsets `2316` when fully deductible. |

The mechanism is identical in effect to reverse charge: `2316` and `2416` net to zero for a fully deductible acquisition. For businesses with partial exemption, only the deductible portion is posted to `2416`; the remainder is expensed.

---

## `vat_treatment_enum` to account code mapping

| `vat_treatment_enum` value | Output code | Input code | Net VAT effect |
|---|---|---|---|
| `STANDARD_RATED` | `2310` | `2410` | Output liability posted; input recovered on purchases |
| `REDUCED_RATE_9` | `2311` | `2411` | As above at 9% |
| `REDUCED_RATE_5` | `2312` | `2412` | As above at 5% |
| `ZERO_RATED` | `2313` | `2410` | Zero output; input still recoverable |
| `EXEMPT` | `2314` | n/a | No VAT; input not recoverable on directly related costs |
| `REVERSE_CHARGE` | `2315` | `2415` | Self-assessed; net zero if fully deductible |
| `EU_ACQUISITION` | `2316` | `2416` | Self-assessed acquisition VAT; net zero if fully deductible |
| `PASSENGER_CAR` | `2310` | `2413` | Standard rate; 50% input recovery |
| `NON_DEDUCTIBLE` | `2310` | `2414` | Standard rate; zero input recovery |
| `UNKNOWN` | n/a | n/a | Review issue raised; ledger entry blocked until resolved |

For `ZERO_RATED`: the output side is `2313` (zero-rated supply); when the same transaction involves a purchase, the input code `2410` applies because zero-rated purchases are still deductible. The ledger engine selects output vs. input based on the transaction direction (credit = income side; debit = expense side).

For `UNKNOWN`: no `vat_entries` row is written. A `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED` review issue blocks the ledger entry until a reviewer assigns a treatment.

For `ZERO_RATED` on the income side: the transaction is a supply at 0%. Output code `2313` is used; no input VAT applies to the supply itself. If the same transaction represents both an income line and an associated cost, they are on separate `ledger_entries` rows with independent VAT treatment per entry.

---

## VAT return population

The Cyprus VAT return (Φ.Π.Α. Form 4) populates its boxes from aggregated `vat_entries` rows per period. The mapping from account code to VAT return box is:

| Account code | VAT return box | Description |
|---|---|---|
| `2310` | Box 1A | Standard-rated output tax |
| `2311` | Box 1B | Reduced-rate (9%) output tax |
| `2312` | Box 1C | Reduced-rate (5%) output tax |
| `2313` | Box 2 | Zero-rated supplies (amount, no tax) |
| `2314` | Box 3 | Exempt supplies (amount, no tax) |
| `2315` | Box 4A | Reverse charge output (self-assessed) |
| `2316` | Box 4B | EU acquisition output (self-assessed) |
| `2410` | Box 5 | Input tax recoverable — standard rate |
| `2411` | Box 5 | Input tax recoverable — reduced 9% |
| `2412` | Box 5 | Input tax recoverable — reduced 5% |
| `2413` | Box 5 (50%) | Input tax partially recoverable — passenger cars |
| `2414` | n/a | Non-deductible; expensed, not on return |
| `2415` | Box 6 | Reverse charge input recovery |
| `2416` | Box 6 | EU acquisition input recovery |

The VAT return generation tool (Block 16 reporting) reads `vat_entries` for the period, groups by `output_account_code` and `input_account_code`, and sums the `vat_amount_eur` per box. This document is the lookup table for that grouping logic. Any change to the box mapping above requires a corresponding change in the VAT return generation tool and a new mapping version.

---

## Versioning

The account code catalog is part of the ledger account mapping and is versioned via `ledger_account_mapping_versions`. The `effective_from` date on a mapping version determines which codes apply to transactions in a given period. Codes do not change retroactively within a finalized period. Finalization freezes the mapping version via `LEDGER_MAPPING_VERSION_FROZEN`.

Amendments to this catalog require:
1. Creating a new entry in `cyprus_vat_rule_catalog.md`.
2. Incrementing the mapping version in `ledger_account_mapping_version_schema.md`.
3. Emitting `LEDGER_MAPPING_VERSION_CREATED` with `changed_category_count > 0`.

---

## Cross-references

- `vat_entry_schema.md` — `vat_entries` table DDL; `output_account_code`, `input_account_code`, `vat_treatment` columns
- `ledger_entry_schema.md` — `ledger_entries` table DDL; debit/credit account code fields
- `cyprus_vat_rule_catalog.md` — binding VAT rate catalog for Cyprus; maps product/service categories to `vat_treatment_enum` values
- `ledger_account_mapping_version_schema.md` — versioning mechanism for the account code catalog; `effective_from`, `frozen_at` fields
