# Block 11 — Phase 02: Default Cyprus-Friendly Chart of Accounts

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Chart of Accounts; Owner / director / shareholder movements; Non-deductible expenses)
- Decisions log: `Docs/decisions_log.md` (MVP ships with a Cyprus-friendly standard chart; dedicated equity/loan accounts; non-deductible sub-accounts per category)

## Phase Goal

Ship the seeded chart of accounts every new business gets at provisioning. The seed covers the canonical Cyprus-relevant account classes (asset, liability, equity, revenue, expense, contra), the dedicated equity and loan accounts (Director's Loan Account, Shareholder Capital), and a deductible/non-deductible sub-account pair for every expense category where Cyprus tax law commonly distinguishes them. After this phase, Phase 03 can layer per-business customization on top of a known-good baseline.

## Dependencies

- Phase 01 (`chart_of_accounts`, `chart_of_accounts_mappings`, `chart_of_accounts_mapping_versions`)
- Phase 05 (read-only contract dependency: the canonical eight-value `vat_treatment` enum lives there; the seed mapping rules reference its values verbatim — Phase 01 also declares the column, but Phase 05 is the source of truth for the enum membership)
- Block 02 Phase 01 (business provisioning — seeding fires when a business row is created)
- Block 08 Phase 05 (tag taxonomy — the seed mapping rules reference tag values from there)

## Deliverables

- **Seed catalog file** — a versioned JSON or YAML asset (`docs-only at this stage; sub-doc names the location`) listing the Cyprus-friendly default accounts. Stage 1 commits to **representative coverage**, not exhaustive Cyprus-specific account codes (which the sub-doc finalizes). The seed includes:
  - **Assets:** Bank accounts (one row per bank account is created later by Block 02 Phase 01 — the seed provides only the Bank Accounts header / category), Trade Debtors, Other Debtors, VAT Receivable, Prepaid Expenses, Fixed Assets header.
  - **Liabilities:** Trade Creditors, Other Creditors, VAT Payable, Accrued Expenses, **Director's Loan Account**, **Shareholder Loan Account**.
  - **Equity:** **Shareholder Capital**, Retained Earnings, Current Year Earnings.
  - **Revenue:** Sales — Cyprus, Sales — EU (B2B reverse-charge eligible), Sales — Non-EU, Other Income, Refunds Received.
  - **Expense:** A standard list of expense categories — Travel, Meals & Entertainment, IT & Software, Professional Fees, Office Supplies, Rent, Utilities, Bank Charges, Marketing, Subscriptions, Salaries & Wages, Contractor Payments, Tax Payments, Other Expenses. **Each category that admits a deductibility distinction in Cyprus has both a `— deductible` and a `— non-deductible` sub-account** (e.g., `Meals & Entertainment — deductible`, `Meals & Entertainment — non-deductible`). The deductibility flag on the parent and on each sub-account is set per the seed.
  - **Contra:** Input VAT, Output VAT, FX Gains, FX Losses, Rounding.
- **Seed mapping rules** — default `chart_of_accounts_mappings` rows shipping with each business:
  - **Per transaction type** — at minimum one default rule per Block 08 transaction type (the 12-type list) so Phase 07's dispatcher always finds an applicable rule.
  - **Per common tag** — selected high-traffic tag → account associations (e.g., `tag:saas_subscription → IT & Software — deductible`; `tag:client_dinner → Meals & Entertainment — non-deductible`).
  - **Per VAT-treatment branch** — selected entries tied to specific VAT treatments (e.g., `EU_REVERSE_CHARGE` on the credit side maps to `Sales — EU`).
- **Seed loader** — `loadDefaultChartForBusiness(business_id) → void`:
  - Idempotent: if any rows already exist for the business, the loader is a no-op.
  - Creates a `chart_of_accounts_mapping_versions` row with `version_number = 1` and `effective_from = business.created_at`.
  - Inserts every seed account into `chart_of_accounts` with `is_seeded = true`.
  - Inserts every seed mapping rule with `is_seeded = true`.
  - Emits one `CHART_DEFAULT_SEEDED` audit event per business with the seed catalog version stamp.
- **Seed catalog versioning:**
  - The seed catalog itself carries a version (e.g., `cyprus_default_chart_v1`); the catalog version is recorded on the initial mapping-version row.
  - Future catalog versions don't rewrite existing businesses' charts; they only affect newly provisioned businesses. Sub-doc tracks the per-business migration path if ever needed.
- **Audit events:**
  - `CHART_DEFAULT_SEEDED` (with the seed catalog version)
  - Plus the per-row events from Phase 01 (`CHART_ACCOUNT_CREATED`, `CHART_MAPPING_RULE_CREATED`, `CHART_MAPPING_VERSION_CREATED`) emitted by the seeded inserts.

## Definition of Done

- Provisioning a new business automatically seeds the chart and mapping rules; the loader is idempotent on re-run.
- The seed includes every transaction type's default rule so Phase 07 can never produce a "no-rule" result on a freshly seeded business.
- Each deductibility-relevant expense category has both a deductible and a non-deductible sub-account, with the right `deductibility` flag.
- Director's Loan Account, Shareholder Capital, and Shareholder Loan Account are present and tagged with the right `account_class`.
- The seed catalog version is recorded; one `CHART_DEFAULT_SEEDED` event is emitted per business.
- Tests cover: idempotency, presence of all 12 default transaction-type rules, deductible/non-deductible pairs, equity/loan accounts.

## Sub-doc Hooks (Stage 4)

- **Cyprus-friendly default chart catalog sub-doc** — the exact JSON/YAML, finalized account codes, names per Cyprus convention.
- **Default mapping rules sub-doc** — the exact set of seed rules, priorities, fallback chains.
- **Catalog version migration sub-doc** — strategy for evolving the default catalog without disrupting existing businesses.
- **Tag → account convention sub-doc** — how tag values from Block 08 map to account categories; conventions for new tags introduced post-MVP.
- **Cyprus-specific deductibility table sub-doc** — which categories admit a deductibility distinction (entertainment, fines, etc.), aligned to current Cyprus tax law.
