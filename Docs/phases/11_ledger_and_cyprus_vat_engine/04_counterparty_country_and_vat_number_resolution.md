# Block 11 — Phase 04: Counterparty Country & VAT Number Resolution

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Compliance Fields per Ledger Entry — `counterparty_country`, `counterparty_vat_number`)
- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Phase 04 — extracted fields including supplier address, VAT number)
- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Phase 03 — vendor memory; supplier/client registry)

## Phase Goal

Derive the two compliance fields the VAT classifier (Phase 05) absolutely requires: `counterparty_country` and `counterparty_vat_number`. The resolver runs deterministically: extracted document fields first, then the per-business vendor registry, then a final structured fallback. When no source decides, the entry is flagged for accountant review — the classifier never guesses these fields.

## Dependencies

- Phase 01 (`draft_ledger_entries.counterparty_country`, `counterparty_vat_number` columns)
- Block 09 Phase 04 (`documents.extracted_fields_json` — supplier name, address, VAT number, country)
- Block 08 Phase 03 (`recurring_vendor_memory` — historical resolution per vendor)
- Block 02 Phase 01 (per-business country / VAT registration profile — for "is the counterparty domestic to my business" comparisons)

## Deliverables

- **`resolveCounterparty(transaction, match_record?) → CounterpartyResolution`:**
  - Returns `{ counterparty_country | null, counterparty_vat_number | null, source: 'DOCUMENT' | 'CLIENTS_REGISTRY' | 'VENDOR_MEMORY' | 'TRANSACTION_METADATA' | 'UNRESOLVED', confidence: 'HIGH' | 'MEDIUM' | 'LOW', evidence_pointer: { document_id?, client_id?, vendor_memory_id?, transaction_field? } }`.
  - **Resolution chain (first hit wins; Stage 1 ordering):**
    1. **Matched-document extracted fields** — when the transaction has an associated `match_record` with status in `MATCHED_*`, pull from `documents.extracted_fields_json`:
       - `counterparty_country` derived from supplier address country code (extraction owns the canonicalisation; Stage 4 sub-doc tracks ambiguity rules like multi-country addresses).
       - `counterparty_vat_number` taken directly when present and well-formed.
       - **Confidence:** `HIGH` when both are present and the document's extraction layer is `TIER3_AI` or `DETERMINISTIC`; `MEDIUM` when extracted from `TIER2_AI` only.
    1.5. **`clients` registry lookup (IN-side runs only — `IN_MONTHLY` / `IN_ADJUSTMENT`)** — Block 13 Phase 02 owns the registry; this step resolves via two helpers it exposes:
       - `getClientByName({ business_id, normalized_client_name }) → Client | null` — exact normalized-name match.
       - `getClientByVatNumber({ business_id, vat_number }) → Client | null` — VAT-number match (canonicalised per the rules below).
       - **Confidence:** exact name match → `HIGH`; fuzzy / canonicalized match → `MEDIUM`; VAT-number-only match (no name) → `MEDIUM`.
       - **OUT-side runs skip this step entirely** — `clients` is the IN-side counterparty registry; OUT-side counterparties live in `recurring_vendor_memory` (Step 2). The branch is run-type conditional.
    2. **Vendor memory** — if the transaction's normalized counterparty signature (from Block 08 Phase 03) hits the vendor registry, pull the most recent confirmed `counterparty_country` and `counterparty_vat_number` from there.
       - **Confidence:** `HIGH` when the vendor memory tier is `HIGH` (≥3 confirmations, per Block 08 Phase 03); `MEDIUM` for medium tier; `LOW` for single-confirmation entries. The matching engine's `recurring_vendor_signal` value is intentionally NOT reused as the confidence — this phase's confidence refers to the resolver's certainty about the counterparty fields, not match-pair confidence.
    3. **Transaction metadata** — when the bank statement's transaction row carries explicit fields (counterparty IBAN's country prefix, SEPA counterparty BIC's country, descriptor text matching a known vendor pattern), use them as a low-confidence fallback.
       - **Confidence:** `LOW`. IBAN-prefix-only resolution never produces a `counterparty_vat_number` — only a country candidate.
    4. **Unresolved** — none of the above produced both fields; resolver returns `UNRESOLVED` with whichever fields it managed to fill.
- **VAT-number canonicalisation:**
  - The string is normalised: country prefix uppercased, internal spaces and hyphens removed, leading/trailing whitespace stripped.
  - **Format-only validity check** at this phase — pattern matching against the country's VAT-number format (e.g., `CY99999999X` for Cyprus). VIES-online validation is deferred to Phase 06 (`vies_relevant` is set there, not here).
  - When the canonicalisation succeeds but the format check fails, the field is stored AND a `COUNTERPARTY_VAT_NUMBER_INVALID` review issue is raised (severity `MEDIUM`, bucket `Possible Tax/VAT Issue`).
- **Country canonicalisation:**
  - Always ISO-3166 alpha-2 in storage. Extraction's free-text country names are mapped via a fixed lookup (sub-doc tracks the table; Stage 1 ships ISO names + common aliases).
  - When two sources disagree (e.g., document says `DE`, vendor memory says `IE`), the higher-confidence source wins; the disagreement raises a `COUNTERPARTY_COUNTRY_DISAGREEMENT` review issue (severity `MEDIUM`).
- **Unresolved-field handling:**
  - When the resolver returns `UNRESOLVED` for `counterparty_country`, Phase 08 raises `COUNTERPARTY_COUNTRY_UNRESOLVED` review issue (severity `MEDIUM`); the draft entry's `vat_treatment` defaults to `UNKNOWN` and `requires_accountant_review = true`.
  - When `counterparty_vat_number` is unresolved BUT country is known and the country is non-EU or transaction nature doesn't require a VAT number (e.g., domestic Cyprus retail receipt), the resolver finishes successfully with `counterparty_vat_number = null` and no review issue; Phase 05 may still pick a definite treatment.
- **Vendor-registry write-back:**
  - When the resolver succeeds via the document path with `HIGH` confidence, the resolved fields are written back to `recurring_vendor_memory` for future runs. This is the same memory Block 08 Phase 03 maintains; the helper from Block 08 owns the write.
  - The write-back is gated on Block 08's confirmations counter — only confirmed-match cases write back, not speculative resolutions.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention):
  - `LEDGER_COUNTERPARTY_RESOLVED` (with `source` and `confidence`)
  - `LEDGER_COUNTERPARTY_UNRESOLVED` (when both fields end up null)
  - `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED` (when sources conflict)

## Definition of Done

- A transaction with a `MATCHED_*` document containing supplier country and VAT number resolves with `source = DOCUMENT`, `confidence = HIGH`.
- Same transaction, but document extraction layer is `TIER2_AI`: resolves with `confidence = MEDIUM`.
- A transaction without a matched document but with a recurring vendor memory hit (high tier) resolves with `source = VENDOR_MEMORY`, `confidence = HIGH`.
- A transaction with neither but with a SEPA counterparty BIC starting `DE` resolves country-only with `confidence = LOW`; VAT number remains null; no review issue if the transaction nature doesn't require a VAT number.
- A document and vendor memory disagreement raises `COUNTERPARTY_COUNTRY_DISAGREEMENT` and the higher-confidence source wins.
- An invalid-format VAT number is canonicalised, stored, and `COUNTERPARTY_VAT_NUMBER_INVALID` is raised.
- An unresolved country sets the entry's `vat_treatment = UNKNOWN` and raises the right review issue.
- High-confidence document-sourced resolutions write back to vendor memory.

## Sub-doc Hooks (Stage 4)

- **Country-name canonicalisation table sub-doc** — alias table; multi-country address handling.
- **VAT-number format catalog sub-doc** — per-country regex; rare formats (Greek 9-digit; Northern Ireland XI prefix; etc.).
- **IBAN/BIC country derivation sub-doc** — the lookup tables and edge cases (multi-country IBANs, virtual IBANs).
- **Vendor-memory write-back sub-doc** — exact contract with Block 08 Phase 03's helper, idempotency.
- **Resolver tracing sub-doc** — what we record for each resolution attempt (used for debugging accountant-review cases).
