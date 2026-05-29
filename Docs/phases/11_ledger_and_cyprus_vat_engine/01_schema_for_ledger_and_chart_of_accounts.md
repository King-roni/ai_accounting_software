# Block 11 — Phase 01: Schema for Ledger Entries & Chart of Accounts

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Compliance Fields per Ledger Entry; Chart of Accounts)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phases 04 — ledger schema commitment; Phase 07 — finalized archive)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 05 — RLS template)
- Decisions log: `Docs/decisions_log.md` (Cyprus-friendly default chart; accrual-only; dedicated equity/loan accounts; non-deductible sub-accounts; multi-line invoice consolidation)

## Phase Goal

Provision the operational-DB schema this block writes against: `draft_ledger_entries` with all 11 compliance fields, the per-business `chart_of_accounts` and account-mapping structures, and the version-pin row that lets Phase 03's customization remain replay-safe across finalized periods. After this phase, Phases 02–10 have the data infrastructure they need; no other block creates these tables.

## Dependencies

- Block 02 Phase 01 (tenancy schema — `organization_id`, `business_id`)
- Block 02 Phase 05 (RLS template)
- Block 04 Phase 02 (`transactions` — `parent_transaction_id` FK)
- Block 04 Phase 03 (`match_records` — `match_record_id` FK)
- Block 04 Phase 04 (`review_issues` — accountant-review flag emits review issues here)
- Block 05 Phase 02 (audit log API — for the audit events declared below)

## Deliverables

- **`draft_ledger_entries` table** — the operational-DB row produced by every Block 11 phase. Columns:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `parent_transaction_id` (FK to `transactions`; nullable for adjustment entries that don't trace to a transaction)
  - `match_record_id` (FK to `match_records`; nullable for transaction types where evidence is not invoice-based — e.g., `INTERNAL_TRANSFER`, `BANK_FEE`)
  - `entry_kind` (`PRIMARY` for a non-derived entry; `VAT_RECLAIM`, `VAT_OUTPUT`, `ROUNDING`, `FX_DELTA` for derived entries — Phase 07 enumerates which kinds each transaction type produces). A single transaction can produce **multiple PRIMARY entries** (e.g., FX_EXCHANGE legs, multi-line invoices that split across distinct expense categories). No DB constraint enforces "one PRIMARY per transaction"; the count is determined by the type-aware path in Phase 07.
  - `debit_account_code`, `credit_account_code` (FK to `chart_of_accounts.code`)
  - `debit_amount`, `credit_amount`, `currency` (a single entry has either a debit or a credit amount; double-entry symmetry comes from the matched pair of rows under the same `parent_transaction_id`)
  - `entry_period` (the bookkeeping period the entry belongs to — typically the transaction's settlement month)
  - **Compliance fields (canonical 11; the architecture-doc list is the source of truth):**
    - `counterparty_country` (ISO-3166 alpha-2; nullable)
    - `counterparty_vat_number` (canonicalised string; nullable)
    - `vat_treatment` (enum: one of the eight Phase 05 values; defaults to `UNKNOWN` until classified)
    - `input_vat_reclaimable_flag`, `input_vat_reclaimable_amount`
    - `output_vat_due_flag`, `output_vat_due_amount`
    - `reverse_charge_relevant` (boolean)
    - `vies_relevant` (boolean)
    - `requires_contract`, `requires_invoice`, `requires_receipt` (booleans)
    - `requires_accountant_review` (boolean), `accountant_review_reason` (text; nullable)
  - **Versioning + status:**
    - `chart_mapping_version_id` (FK to `chart_of_accounts_mapping_versions.id`; pinned at draft time)
    - `vat_rate_table_version` (text; pinned at draft time — Stage 4 sub-doc covers VAT-rate sourcing)
    - `status` (`DRAFT`, `READY_FOR_FINALIZATION`, `LOCKED`; transitions to `LOCKED` are owned by Block 15, not this block)
    - `created_at`, `last_recomputed_at` — drafts can be re-derived if upstream data changes; `last_recomputed_at` records the most recent regeneration
  - **Cross-currency fields (nullable; populated only when transaction currency differs from bookkeeping currency):**
    - `entry_currency_original` (text; ISO-4217)
    - `entry_amount_original` (numeric)
  - **VIES export fields (nullable; populated only when `vies_relevant = true` per Phase 06 / Phase 08):**
    - `vies_period` (text; `YYYY-MM`)
    - `vies_value_basis_eur` (numeric)
  - **Plain-language explanation field (nullable; populated by Phase 09's `ledger.generate_vat_explanations`):**
    - `vat_treatment_explanation` (text)
  - **Manual-override fields (nullable; populated only when an Owner / Admin overrides per Phase 08):**
    - `manual_override_by` (FK to `users`)
    - `manual_override_reason` (text)
    - `manual_override_at` (timestamp)
  - **Indexes:** `(business_id, entry_period)`, `(business_id, vat_treatment)`, `(business_id, requires_accountant_review)`, `(parent_transaction_id)`, `(match_record_id)`.
- **`chart_of_accounts` table** — per-business chart catalog. Columns:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `code` (text — the account code; unique per business; e.g., `6010` for Travel — deductible)
  - `name` (text — display name)
  - `account_class` (enum: `ASSET`, `LIABILITY`, `EQUITY`, `REVENUE`, `EXPENSE`, `CONTRA`)
  - `parent_code` (nullable — for sub-accounts, e.g., `6010-ND` is a sub-account under `6010`)
  - `category` (text — e.g., `TRAVEL`, `IT`, `PROFESSIONAL_FEES`; used by tag→account mapping in Phase 03)
  - `deductibility` (enum: `DEDUCTIBLE`, `NON_DEDUCTIBLE`, `MIXED`, `NA`)
  - `is_seeded` (boolean; `true` for entries from the Cyprus-friendly default chart in Phase 02, `false` for per-business additions)
  - `disabled_at` (nullable timestamp — accounts can be disabled but not deleted; references existing entries must remain renderable)
  - `created_at`, `updated_at`
  - **Indexes:** `(business_id, code)` unique; `(business_id, account_class)`; `(business_id, category)`.
- **`chart_of_accounts_mappings` table** — the rules that resolve `(transaction_type, tag, vat_treatment) → account_code`:
  - `id`, `organization_id`, `business_id`
  - `transaction_type` (one of the 12 from Block 08; nullable when the rule applies across types)
  - `tag` (nullable; matches Block 08 Phase 05's tag taxonomy)
  - `vat_treatment` (nullable; matches Phase 05's enum)
  - `entry_kind` (nullable; default rule applies to `PRIMARY` only unless specified)
  - `direction` (`DEBIT` or `CREDIT` — which side this rule populates)
  - `account_code` (FK to `chart_of_accounts.code`)
  - `priority` (integer — higher wins on ambiguity; sub-doc covers ordering rules)
  - `is_seeded` (boolean)
  - `created_at`, `updated_at`
- **`chart_of_accounts_mapping_versions` table** — the version-pin row Phase 03 increments on every customization:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `version_number` (monotonic integer per business)
  - `effective_from` (timestamp; the period from which this version applies)
  - `created_by`, `created_at`
  - `frozen_at` (nullable; set when a finalized period pins this version — the row becomes immutable)
- **RLS** on every new table per the Block 02 Phase 05 template.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `LEDGER` for ledger entries, `CHART` for chart-of-accounts changes):
  - `LEDGER_DRAFT_ENTRY_CREATED`
  - `LEDGER_DRAFT_ENTRY_RECOMPUTED`
  - `LEDGER_ACCOUNTANT_REVIEW_FLAGGED` (declared here; raised by Phase 08 — canonical name aligns with Phase 08's emission)
  - `CHART_ACCOUNT_CREATED`, `CHART_ACCOUNT_DISABLED`, `CHART_ACCOUNT_UPDATED`
  - `CHART_MAPPING_RULE_CREATED`, `CHART_MAPPING_RULE_DISABLED`
  - `CHART_MAPPING_VERSION_CREATED`, `CHART_MAPPING_VERSION_FROZEN`

## Definition of Done

- All four tables exist with correct columns, FKs, constraints, and indexes.
- A test inserts a draft ledger entry; RLS prevents cross-tenant SELECT.
- The unique constraint on `(business_id, code)` blocks duplicate account codes within a business.
- A test creates a mapping version row; finalizing a period (mocked Block 15 call) sets `frozen_at` and subsequent updates to that version's mapping rules are blocked.
- A test verifies that disabling an account does not cascade-delete its draft entries (referenced rows still render).
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Compliance-fields canonical schema sub-doc** — exact column types, defaults, evolution rules.
- **Mapping-rule resolution sub-doc** — priority ordering, tie-breaking, fallback to default rule.
- **Mapping-version freeze semantics sub-doc** — exact rule for when Block 15 freezes a version, what edits are still permitted (none).
- **Adjustment-entry schema sub-doc** — how adjustment runs (Block 03 Phase 11) write to `draft_ledger_entries` with `parent_transaction_id = null` and a delta-style payload.
- **Index-strategy sub-doc** — query plans for VAT summary, missing-evidence reports, accountant-review queue.
