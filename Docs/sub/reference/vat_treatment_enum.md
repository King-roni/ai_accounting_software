# VAT Treatment Enum

**Category:** Reference data · **Owning block:** 04 — Data Architecture · **Co-owners:** 11, 16 · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The closed 8-value Cyprus VAT treatment enum. Block 11 Phase 05 is the canonical classifier; this taxonomy is the contract every consumer (`draft_ledger_entries.vat_treatment`, Block 16 VAT prep + VIES exports, Block 14 review issue routing for tax-VAT issues) binds to. Adding a value requires a `Docs/decisions_log.md` amendment.

The classifier inputs are (transaction type, counterparty country, counterparty VAT number presence + validity, document type, manual override). The classifier output is exactly one of these 8 values.

---

## The 8 values

| Value | Applies when | Cyprus VAT rate | Reverse charge | VIES relevance |
| --- | --- | --- | --- | --- |
| `DOMESTIC_STANDARD` | Cyprus-domestic supply at the standard rate | 19% | No | No |
| `DOMESTIC_REDUCED` | Cyprus-domestic supply at a reduced rate (9%, 5%) | 9% or 5% | No | No |
| `DOMESTIC_ZERO` | Cyprus-domestic zero-rated supply (e.g., specific exports outside EU, international transport) | 0% | No | No |
| `EU_REVERSE_CHARGE` | B2B intra-EU service (or specific goods) where the buyer accounts for VAT | 0% on invoice; reverse-charged in books | Yes | Yes (VIES-reportable on the supplier side; on the IN side, only when client VAT number is validated) |
| `IMPORT_OR_ACQUISITION` | Goods imported from outside EU OR intra-EU goods acquisition | Cyprus rate self-assessed | Reverse-charge style (paid + reclaimed) | No (IMPORT) / Yes (intra-EU ACQUISITION) — see Phase 06 |
| `NON_EU_SERVICE` | Service exported to a customer outside the EU (zero-rated) | 0% | No | **No** — reportable on Cyprus VAT return but NOT on VIES (per the Block 11 Phase 05 IN-3 fix; distinct from `OUTSIDE_SCOPE`) |
| `OUTSIDE_SCOPE` | Transaction is outside the VAT regime entirely (e.g., loans, internal transfers, director's loan movements, intercompany capital flows) | — | — | No |
| `UNKNOWN` | The classifier could not determine treatment with confidence; deferred for accountant review | — | — | No |

## Per-treatment routing

### `DOMESTIC_STANDARD` / `DOMESTIC_REDUCED` / `DOMESTIC_ZERO`

- Standard Cyprus VAT lifecycle
- VAT amount lives on the PRIMARY ledger entry (per `vat_rate_table_cyprus`)
- No derived VAT_OUTPUT / VAT_RECLAIM entries
- Block 16's Cyprus VAT preparation report consumes these directly

### `EU_REVERSE_CHARGE`

- Stage 1 decision pins full VIES export (regulator-required) — Block 16 Phase 11 generates the XML
- Block 11 Phase 06 derives the (VAT_RECLAIM, VAT_OUTPUT) entry pair from the PRIMARY entry
- The PRIMARY entry carries VAT amount = 0; the derived entries carry the actual reverse-charged amount per `vat_rate_table_cyprus`
- IN-side `EU_REVERSE_CHARGE` requires a validated EU client VAT number — if missing, the classifier routes to `UNKNOWN` instead (per the 2026-05-08 Block 11 IN-2 fix)
- VIES record generation per `vies_record_format`

### `IMPORT_OR_ACQUISITION`

- OUT-side only (per the Block 13 / Block 11 fix — the IN-side has no `IMPORT_OR_ACQUISITION` analog)
- Self-assessed Cyprus VAT (reverse-charge style for goods)
- INVOICE_PDF render rejects this treatment on FINAL render per `pro_forma_policies` / Block 13 Phase 04 (the treatment is OUT-side only; a tax invoice issued IN-side cannot carry this treatment)

### `NON_EU_SERVICE`

- IN-side zero-rated export of services to non-EU customers
- Reportable on the Cyprus VAT return as zero-rated supply
- NOT VIES-reportable (VIES covers intra-EU only)
- Distinct from `OUTSIDE_SCOPE` — `NON_EU_SERVICE` IS in scope (zero-rated and reportable), `OUTSIDE_SCOPE` is not in scope at all

### `OUTSIDE_SCOPE`

- Transactions outside the VAT regime entirely
- Examples: loans, internal transfers, capital injections, dividends, gifts
- May carry `counterparty_*` fields null (per the Block 11 Phase 09 exit-gate rewrite)
- Not reportable on the VAT return

### `UNKNOWN`

- Deferred classification; raises `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED` audit event
- Surfaces in the review queue as `Possible Tax-VAT Issue` (MEDIUM by default; HIGH when the transaction is non-trivial)
- Blocks finalization until reclassified
- `counterparty_*` fields may be null (UNRESOLVED counterparty case per Block 11 Phase 04)

## VIES-relevance projection

`vies_relevant` boolean is derived from `vat_treatment` per the following projection:

```sql
CASE
  WHEN vat_treatment = 'EU_REVERSE_CHARGE' THEN true
  WHEN vat_treatment = 'IMPORT_OR_ACQUISITION'
    AND import_acquisition_subtype = 'INTRA_EU_ACQUISITION' THEN true
  ELSE false
END
```

The projection lives on `draft_ledger_entries.vies_relevant` (computed column, refreshed on classifier write). Per Stage 1 decision, the project commits to full VIES file export.

## Manual override

Per `vat_treatment_classifier` (Block 11 Phase 05) and the manual-override pre-check rule:

- The classifier reads `ledger_manual_override.vat_treatment` first
- If present and valid for the transaction type, short-circuit + emit `LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE`
- Otherwise run the standard classification

Manual overrides cannot widen — e.g., a user cannot manually mark an `OUTSIDE_SCOPE` transaction as `DOMESTIC_STANDARD` to invent a VAT obligation; the system rejects the override.

## Storage

`draft_ledger_entries.vat_treatment` column. Postgres ENUM:

```sql
CREATE TYPE vat_treatment_enum AS ENUM (
  'DOMESTIC_STANDARD',
  'DOMESTIC_REDUCED',
  'DOMESTIC_ZERO',
  'EU_REVERSE_CHARGE',
  'IMPORT_OR_ACQUISITION',
  'NON_EU_SERVICE',
  'OUTSIDE_SCOPE',
  'UNKNOWN'
);
```

Mirrored on `archive.locked_ledger_entries.vat_treatment` for finalized data. The two columns share the ENUM type via `USING ... :: vat_treatment_enum`.

## Cross-references

- `vat_rate_table_cyprus` — actual rate values per treatment (the 9%, 5%, 19%, etc.)
- `vies_record_format` — VIES CSV/XML field layout per the export contract
- `cyprus_vat_rule_catalog` — rule precedence and edge cases (Block 11 Reference data)
- `cyprus_default_chart_catalog` — chart-of-accounts mapping per treatment
- `cyprus_deductibility_table` — non-deductible vs deductible per category
- `transaction_type_enum` — orthogonal taxonomy
- `vat_treatment_explanation_prompt` (Prompts, Block 11) — plain-language explanation generator
- Block 11 Phase 05 — VAT treatment classifier
- Block 11 Phase 06 — reverse charge & VIES relevance
- Block 11 Phase 08 — VAT amount + evidence flags
- Block 16 Phase 11 — accountant pack + VIES regulator XML

---

## Cyprus VAT law citations per treatment

The following citations are to the Cyprus Value Added Tax Law of 2000 (N. 95(I)/2000) as amended.

| Treatment | Governing article(s) | Summary |
| --- | --- | --- |
| `DOMESTIC_STANDARD` | Article 5(1) — Taxable supply; Schedule 1 (standard rate 19%) | Standard-rate taxable supply of goods or services in Cyprus. The supplier charges VAT at 19% and accounts for it on the VAT return |
| `DOMESTIC_REDUCED` | Article 5(1); Schedule 5 (reduced rates — 9% and 5%) | Reduced-rate supply. Schedule 5 Part I lists 9% supplies (e.g., hospitality); Part II lists 5% supplies (e.g., certain foodstuffs, books, medical equipment) |
| `DOMESTIC_ZERO` | Article 5(1); Schedule 2 (zero-rated supplies) | Zero-rated supply — taxable but at 0%. Includes exports of goods outside the EU (Article 26(1)(a)), international transport (Article 26(1)(c)), and certain financial/insurance services supplied internationally |
| `EU_REVERSE_CHARGE` | Article 11B — Intra-EU services (B2B); Article 11A — Intra-EU goods (acquisition by Cyprus business) | The recipient accounts for VAT in their member state. The Cyprus supplier issues an invoice with 0% VAT and the note "Reverse charge applies". For goods: Article 11A; for services: Article 11B |
| `IMPORT_OR_ACQUISITION` | Article 11A (Intra-EU acquisition); Article 12 (Import of goods from outside EU) | Intra-EU acquisition: Cyprus business acquires goods from another EU member state; accounts for VAT at the Cyprus rate and simultaneously reclaims (if the goods are used for taxable purposes). Import: goods entering Cyprus from outside EU; import VAT paid at customs |
| `NON_EU_SERVICE` | Article 11B read together with Article 26(1)(b) — place of supply rules for B2B services outside EU | Service supplied to a non-EU business customer; place of supply is the customer's country (not Cyprus); therefore outside Cyprus VAT scope but zero-rated for Cyprus VAT return purposes. Distinct from `OUTSIDE_SCOPE` — this IS reported on the Cyprus VAT return as a zero-rated supply |
| `OUTSIDE_SCOPE` | Not subject to VAT Law — outside the scope of Articles 5–12 entirely | Transactions that are not supplies of goods or services for VAT purposes: loans (Article 26(1)(b) exemption applied to financial services), capital movements, internal transfers between own accounts, dividends |
| `UNKNOWN` | N/A — deferred; no article can be cited until classification is resolved | Blocking issue; requires accountant review to assign one of the 7 other treatments |

---

## VIES eligibility notes per treatment

VIES reporting is required for intra-EU transactions where Cyprus is the supplier and the recipient is a VAT-registered business in another EU member state.

| Treatment | VIES-reportable? | Validation required | Notes |
| --- | --- | --- | --- |
| `DOMESTIC_STANDARD` | No | No | Domestic; no VIES obligation |
| `DOMESTIC_REDUCED` | No | No | Domestic |
| `DOMESTIC_ZERO` | No | No | Zero-rated exports are reported on the Cyprus VAT return but NOT on VIES |
| `EU_REVERSE_CHARGE` | Yes | Yes — client's EU VAT number must be validated via VIES online service before the invoice is issued | The client's validated VAT number is the VIES record's `client_vat_number` field |
| `IMPORT_OR_ACQUISITION` — intra-EU acquisition | Yes (for the acquisition side; Cyprus reports as acquirer) | The supplier's VAT number should be validated | Reported in the VIES Acquisition column |
| `IMPORT_OR_ACQUISITION` — non-EU import | No | No | Import from outside EU is not a VIES transaction |
| `NON_EU_SERVICE` | No | No | Non-EU customer; VIES covers intra-EU only |
| `OUTSIDE_SCOPE` | No | No | Outside VAT regime |
| `UNKNOWN` | Deferred | Deferred | Cannot determine VIES obligation until reclassified |

For `EU_REVERSE_CHARGE`, the VIES validation check fires at Block 11 Phase 06. If the client's VAT number fails validation (invalid, deregistered, or VIES service unavailable), the transaction is held with a `Possible Tax-VAT Issue` at HIGH severity.

---

## Additional cross-references

- `ledger_entry_schema` — `vat_treatment` column on `draft_ledger_entries` and `archive.locked_ledger_entries`
- `vat_entry_schema` — the `vat_entries` table that carries the derived VAT_OUTPUT and VAT_RECLAIM rows produced from `EU_REVERSE_CHARGE` and `IMPORT_OR_ACQUISITION` treatments
