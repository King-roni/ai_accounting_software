# Block 11 — Phase 06: Reverse Charge & VIES Relevance

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Compliance Fields per Ledger Entry — `reverse_charge_relevant`, `vies_relevant`; Interfaces — full VIES file export)
- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (full VIES file export to current specification — Stage 1 user upgrade)
- Decisions log: `Docs/decisions_log.md` (VIES scope: full file export to current specification)

## Phase Goal

Set the two compliance booleans the VIES export and reverse-charge bookkeeping rely on: `reverse_charge_relevant` and `vies_relevant`. Both follow deterministically from Phase 05's VAT treatment plus a small set of additional signals (transaction direction, service-vs-goods, counterparty VAT-number validity). After this phase, Block 16's VIES export tool can pull every VIES-relevant entry with a single SQL filter.

## Dependencies

- Phase 01 (`reverse_charge_relevant`, `vies_relevant` columns on `draft_ledger_entries`)
- Phase 04 (`counterparty_country`, `counterparty_vat_number`)
- Phase 05 (`vat_treatment` already decided)
- Block 16 (consumer of the `vies_relevant` flag — phase docs not yet written; the contract from this phase is what Block 16's decomposition must honor)

## Deliverables

- **`computeReverseChargeAndVies(draft_entry, business_profile, transaction) → ReverseChargeViesResult`:**
  - Returns `{ reverse_charge_relevant: boolean, vies_relevant: boolean, vies_period: 'YYYY-MM' | null, supporting_signals: { ... } }`.
  - Pure function over the draft entry's already-populated fields plus the business profile; no external lookups in Stage 1 (VIES-online validity check is deferred — see "Out of scope" below).
  - **Note on `vies_value_basis_eur`:** this column is populated by Phase 08's `ledger.compute_vat_and_evidence_flags`, not here. Phase 06 runs before any amounts are derived and intentionally only sets the booleans + period. Phase 08 conditionally fills `vies_value_basis_eur` when `vies_relevant = true`.
- **`reverse_charge_relevant` rule** (Stage 1):
  - **`true` when** `vat_treatment ∈ {EU_REVERSE_CHARGE, IMPORT_OR_ACQUISITION}` **AND** the entry direction is OUT-side (the business is the recipient of a service or goods on which it self-accounts for VAT).
  - **`true` also when** the entry is IN-side AND `vat_treatment = EU_REVERSE_CHARGE` AND the business is the supplier (the customer self-accounts; the business issues an invoice noting reverse charge applies). This dual treatment matters for downstream reporting — the bookkeeping entry on each side carries the flag.
  - **`false`** otherwise.
- **`vies_relevant` rule** (Stage 1):
  - **`true` when** the entry is IN-side AND `vat_treatment = EU_REVERSE_CHARGE` AND counterparty is in EU AND counterparty has a valid (format-valid per Phase 04) VAT number AND business is VAT-registered. This is the canonical "VIES export must include this sale" case.
  - **`false`** for OUT-side entries (Cyprus VIES is supplier-side reporting).
  - **`false`** when counterparty VAT number is missing or invalid — the entry instead raises `VIES_VAT_NUMBER_MISSING_OR_INVALID` review issue (Phase 08 emits) and stays out of the VIES export until resolved.
  - **`false`** when treatment is not `EU_REVERSE_CHARGE` (the eight-treatment closed enum makes this the only VIES-eligible branch in Stage 1).
- **`vies_period` (when `vies_relevant = true`):**
  - `vies_period` = entry's bookkeeping period as `YYYY-MM` (Cyprus VIES is monthly; sub-doc tracks quarterly thresholds if applicable).
  - `vies_value_basis_eur` is set later by Phase 08, not here (see note above).
- **Reverse-charge book-keeping coupling (clarified for Phase 07):**
  - When `reverse_charge_relevant = true` AND OUT-side, Phase 07's ledger paths produce **two derived entries** in addition to the primary expense entry: a `VAT_RECLAIM` entry on Input VAT (debit) and a `VAT_OUTPUT` entry on Output VAT (credit), of equal amount. Net VAT impact is zero, but both sides surface in the VAT summary.
  - When `reverse_charge_relevant = true` AND IN-side, the primary entry credits revenue and **does not** add a domestic Output VAT entry — the customer self-accounts. The supplier-side entry carries the VIES flag.
- **VIES export contract (durable cross-block contract for Block 16):**
  - Block 16's full VIES file export pulls every `draft_ledger_entries` row (within the period) where `vies_relevant = true`, ordered by `counterparty_vat_number`.
  - Per-counterparty rollup is performed at export time by Block 16, not in this phase — this phase emits only per-entry flags.
  - The export's record format is `{ counterparty_country, counterparty_vat_number, vies_value_basis_eur }`. Goods vs services distinction (currently required by Cyprus VIES) is derived at export time from the entry's `vat_treatment` (`IMPORT_OR_ACQUISITION` ≈ goods, `EU_REVERSE_CHARGE` for IN-side ≈ services) — sub-doc finalizes the precise mapping.
- **Out of scope (deferred):**
  - **VIES-online validity check** (calling the EU VIES web service to confirm the VAT number is currently registered) — deferred to a Stage 2+ enhancement; Stage 1 trusts Phase 04's format-only validity.
  - **Quarterly threshold logic** (some businesses qualify for quarterly VIES) — sub-doc tracks; Stage 1 defaults to monthly.
  - **Non-EUR bookkeeping currency** — Cyprus businesses use EUR by default in Stage 1; non-EUR bookkeeping currencies are out of MVP scope. The `vies_value_basis_eur` field (populated by Phase 08) is the bookkeeping-currency-EUR value for EUR-bookkeeping businesses; sub-doc tracks the rate-source contract for any future non-EUR-bookkeeping-currency support.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `LEDGER`):
  - `LEDGER_REVERSE_CHARGE_FLAGGED`
  - `LEDGER_VIES_RELEVANCE_DECIDED` (with `vies_relevant` value)
  - `LEDGER_VIES_VAT_NUMBER_MISSING_RAISED` (when an `EU_REVERSE_CHARGE` IN-side entry would be VIES-eligible but the counterparty VAT number is missing or invalid)

## Definition of Done

- An OUT-side entry with `vat_treatment = EU_REVERSE_CHARGE` carries `reverse_charge_relevant = true` and `vies_relevant = false` (Cyprus VIES is supplier-side).
- An IN-side entry with `vat_treatment = EU_REVERSE_CHARGE` and a valid customer VAT number carries `reverse_charge_relevant = true` AND `vies_relevant = true` with the right `vies_period` and `vies_value_basis`.
- An IN-side `EU_REVERSE_CHARGE` with missing VAT number leaves `vies_relevant = false` and raises `VIES_VAT_NUMBER_MISSING_OR_INVALID`.
- An `IMPORT_OR_ACQUISITION` OUT-side entry carries `reverse_charge_relevant = true`, `vies_relevant = false` (acquisitions report on the VAT return, not VIES).
- A `DOMESTIC_CYPRUS_VAT` entry has both flags `false`.
- The two derived entries (VAT_RECLAIM + VAT_OUTPUT) are produced for OUT-side reverse-charge cases (verified by Phase 07's test stub here, full integration in Phase 07).
- Tests cover: every VAT treatment × OUT/IN combination → expected flags.

## Sub-doc Hooks (Stage 4)

- **VIES record-format sub-doc** — the exact Cyprus VIES specification fields, goods-vs-services derivation table.
- **Quarterly VIES eligibility sub-doc** — when a business qualifies, how the period field changes.
- **VIES-online validation sub-doc (deferred Stage 2+)** — how the live check would integrate, caching, failure modes.
- **FX-conversion source sub-doc** — exact contract with the Block 10 Phase 02 FX path; per-entry rate version stamping.
- **Reverse-charge derived-entry sub-doc** — the exact `(VAT_RECLAIM, VAT_OUTPUT)` pair shape, account codes from Phase 02's seed.
