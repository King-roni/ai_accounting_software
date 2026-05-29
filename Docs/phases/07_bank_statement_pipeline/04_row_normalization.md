# Block 07 — Phase 04: Row Normalization

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 7.3 — Transaction Normalization)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 02 `transactions` schema)
- Decisions log: `Docs/decisions_log.md` (FX exchange = one transaction with paired legs)

## Phase Goal

Convert each `ParsedRow` (from Phase 02 or Phase 03) into a canonical `NormalizedTransaction` that matches the `transactions` schema. After this phase, every row has been through description cleanup, direction inference, hash computation, and FX-paired-leg structuring — and is ready for the deduplication engine in Phase 05.

## Dependencies

- Phase 02 (CSV `ParsedRow[]`)
- Phase 03 (PDF `ParsedRow[]`)
- Block 04 Phase 01 (hashing helpers — `sourceRowHash`, `transactionFingerprint`)
- Block 04 Phase 02 (`transactions` table schema, including `fx_paired_legs` JSONB)
- Block 05 Phase 05 (`encrypt_field` + `mask_field` for `counterparty_identifier_*` columns)
- Block 06 Phase 02 (Privacy Gateway — counterparty-extraction AI fallback dispatched through the gateway)
- Block 06 Phase 06 (Tier 2 local LLM where the fallback runs when deterministic patterns don't match)

## Deliverables

- **Normalization function** — `normalize(parsedRow, statementContext) → NormalizedTransaction`:
  - Converts `date_text` → ISO 8601 date and (where present) booking date.
  - Converts `amount_text` → `numeric(20, 4)`; rejects rows with zero amount (likely informational lines, not real transactions).
  - Validates `currency` against ISO-4217 list.
  - Sets `direction` (`IN` if amount positive, `OUT` if negative); the absolute value populates `amount`.
  - Cleans `description_text` → `normalized_description` (whitespace, removed transaction codes, decoded character entities).
  - Extracts `counterparty_name` from description and reference fields using deterministic patterns first; falls back to Tier 2 LLM via Block 06 only when patterns don't match.
  - Computes `counterparty_identifier_masked` and `counterparty_identifier_encrypted` using Block 05 Phase 05's helpers (when an IBAN-shaped identifier is present).
  - Computes `source_row_hash` via Block 04 Phase 01's `sourceRowHash` (over the raw row content).
  - Computes `transaction_fingerprint` via `transactionFingerprint` (over date + amount + currency + cleaned description).
- **FX paired-leg structure** (Stage 1 decision):
  - When a Revolut FX exchange line appears (typically two adjacent rows: one "out" leg in source currency, one "in" leg in target currency), Phase 04 collapses them into **one transaction** with `transaction_type` candidate `FX_EXCHANGE` and `fx_paired_legs` JSONB carrying:
    ```json
    {
      "leg_out": { "currency": "EUR", "amount": 100.00 },
      "leg_in":  { "currency": "USD", "amount": 108.42 },
      "rate": 1.0842,
      "fee_currency": "EUR",
      "fee_amount": 0.50
    }
    ```
  - The transaction's `amount` and `currency` reflect the leg the bank account "saw" (typically the out-leg for the source account).
  - The pairing is detected deterministically: same timestamp ± a few seconds, same FX-exchange marker in description, opposite direction signs, matching reference.
- **Confidence propagation:**
  - PDF-sourced rows with `parser_confidence: LOW` (Phase 03) inherit a `normalization_confidence: LOW` flag that downstream phases honour.
  - Rows where counterparty extraction needed AI fallback record `extraction_method: AI_FALLBACK` for audit visibility.
- **Bulk normalization:**
  - All rows from a single statement upload are normalized as one workflow tool invocation; the call is dedup-key'd via Block 03 Phase 07 so a retry doesn't double-process.
  - **Phase 04 does NOT insert into `transactions`.** It returns a `NormalizedTransaction[]` value to the caller (Phase 05's dedup tool). The actual insert is owned by Phase 05, which decides per-row whether to insert (`NEW`) or raise a review issue (`DUPLICATE_POSSIBLE`, `NEEDS_REVIEW`) or silently reject (`DUPLICATE_EXACT`).
- **Audit events:** `TRANSACTION_NORMALIZED` (per row; can be batch-aggregated for performance), `STATEMENT_NORMALIZATION_FAILED` (with row index), `STATEMENT_NORMALIZATION_FX_PAIR_RESOLVED`, `STATEMENT_NORMALIZATION_AI_FALLBACK_USED` (counterparty).

## Definition of Done

- A `ParsedRow[]` from a clean Revolut CSV produces `NormalizedTransaction[]` with every required field populated.
- An FX exchange line collapses into a single transaction with a correct `fx_paired_legs` JSONB and the right `amount`/`currency` for the bank account.
- Counterparty IBANs are encrypted via Block 05 Phase 05; the masked form is populated.
- `source_row_hash` and `transaction_fingerprint` are deterministic and match Block 04 Phase 01's golden values.
- Zero-amount rows are rejected with a clear reason in the `NORMALIZATION_FAILED` event.
- A row with low parser confidence carries `normalization_confidence: LOW` through to the next phase.

## Sub-doc Hooks (Stage 4)

- **Description cleanup rules sub-doc** — patterns to strip, character-set handling, multi-language considerations.
- **FX paired-leg JSONB schema sub-doc** — exact JSON shape, validation rules, edge cases (multi-step FX, partial conversion).
- **Counterparty extraction rules sub-doc** — deterministic regex patterns, when AI fallback fires, confidence calibration.
- **Currency validation sub-doc** — ISO-4217 list source, exotic-currency handling, deprecation policy.
- **Bulk-normalization tool registration sub-doc** — Block 03 Phase 03 declaration shape, side-effect class, dedup-key generator.
