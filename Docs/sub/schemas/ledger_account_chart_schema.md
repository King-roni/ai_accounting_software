# Ledger Account Chart Schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Canonical DDL for the `chart_of_accounts` table. Every business starts with a pre-seeded set of Cyprus-specific system accounts. Accountants may extend the chart by adding custom codes; system accounts cannot be deleted or deactivated. Account code changes over time are tracked in `ledger_account_mapping_versions`.

---

## Enum type declaration

```sql
CREATE TYPE account_type_enum AS ENUM (
  'ASSET',
  'LIABILITY',
  'EQUITY',
  'REVENUE',
  'EXPENSE',
  'VAT_CONTROL'
);
```

---

## chart_of_accounts DDL

```sql
CREATE TABLE chart_of_accounts (
  id                  uuid        NOT NULL DEFAULT gen_uuid_v7()          PRIMARY KEY,
  business_id         uuid        NOT NULL REFERENCES business_entities(id),

  account_code        text        NOT NULL,
  account_name        text        NOT NULL,
  account_type        account_type_enum NOT NULL,

  -- Self-referential parent for hierarchical chart structure.
  -- NULL for top-level accounts (e.g. 1000, 4000, 5000).
  parent_account_id   uuid        NULL REFERENCES chart_of_accounts(id),

  -- System accounts are pre-seeded at business creation and cannot be
  -- deleted or deactivated. is_system_account = true is set exclusively
  -- by the seeding migration; no application-layer path sets it to true.
  is_system_account   boolean     NOT NULL DEFAULT false,

  is_active           boolean     NOT NULL DEFAULT true,

  -- Normal balance side for this account type
  normal_side         text        NOT NULL CHECK (normal_side IN ('DEBIT', 'CREDIT')),

  -- Tax-related hints (populated for EXPENSE and REVENUE accounts; NULL for balance-sheet accounts)
  vat_treatment_hint  text        NULL,

  -- VIES reporting flag: true for accounts used to record intra-EU supplies subject to VIES reporting
  vies_eligible       boolean     NOT NULL DEFAULT false,

  -- Lifecycle: accounts may be retired rather than hard-deleted
  retired_at          timestamptz NULL,
  retired_reason      text        NULL,

  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chart_of_accounts_business_code_uniq
    UNIQUE (business_id, account_code)
);
```

---

## Indexes

```sql
CREATE INDEX chart_of_accounts_business_id_idx
  ON chart_of_accounts (business_id)
  WHERE is_active = true;

CREATE INDEX chart_of_accounts_account_type_idx
  ON chart_of_accounts (business_id, account_type)
  WHERE is_active = true;

CREATE INDEX chart_of_accounts_parent_account_id_idx
  ON chart_of_accounts (parent_account_id)
  WHERE parent_account_id IS NOT NULL;
```

---

## Row-level security

```sql
ALTER TABLE chart_of_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY chart_of_accounts_tenant_isolation
  ON chart_of_accounts
  USING (business_id = auth.current_business_id());
```

---

## Cyprus-specific system accounts

The following accounts are pre-seeded on every business creation via a deterministic migration. `is_system_account = true` on all rows below. Deactivation of these rows is blocked at the application layer; any attempt returns a `CHART_SYSTEM_ACCOUNT_PROTECTED` error.

| account_code | account_name | account_type |
|---|---|---|
| 1000 | Cash | ASSET |
| 1100 | Accounts Receivable | ASSET |
| 2100 | Accounts Payable | LIABILITY |
| 2200 | VAT Control — Cyprus 19% | VAT_CONTROL |
| 2201 | VAT Control — Cyprus 9% | VAT_CONTROL |
| 2202 | VAT Control — Cyprus 5% | VAT_CONTROL |
| 3000 | Owner Equity | EQUITY |
| 4000 | Revenue (General) | REVENUE |
| 5000 | Expense (General) | EXPENSE |

Codes 4001–4999 and 5001–5999 are reserved for custom revenue and expense sub-accounts. Businesses may freely create codes in these ranges without clashing with system accounts.

The three VAT_CONTROL accounts map to Cyprus's three active VAT rates. The account code for a transaction's VAT line is determined by the `vat_rate_table_reference.md` rate-to-code mapping applied at ledger posting time.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `LEDGER_ACCOUNT_CREATED` | LOW | A new non-system `chart_of_accounts` row is inserted |
| `LEDGER_ACCOUNT_DEACTIVATED` | LOW | `is_active` transitions to `false` on a non-system account |

Both events carry `account_id`, `business_id`, `account_code`, `account_name`, and `account_type` in their payload. `LEDGER_ACCOUNT_DEACTIVATED` additionally carries `deactivated_by_user_id`.

---

## Design notes

`account_code` is a free-form text field, not an integer. This allows codes like "4100-A" if a business uses a suffixed chart structure. The uniqueness constraint is on the `(business_id, account_code)` pair.

The `parent_account_id` hierarchy is advisory for reporting grouping (e.g. all 4xxx codes roll up under 4000). The ledger engine does not traverse the hierarchy during posting; it posts directly to the leaf account code specified by the ledger mapping.

`is_system_account` enforcement is in the application layer because PostgreSQL CHECK constraints cannot reference row-level business logic. The guard is in `ledger.post` and in the account management API — attempts to deactivate or delete a system account are rejected before any SQL reaches the table.

---

## Cross-references

- `ledger_entry_schema.md` — ledger entries reference account codes from this table
- `vat_account_code_reference.md` — maps Cyprus VAT rates to VAT_CONTROL account codes
- `ledger_account_mapping_version_schema.md` — tracks when account codes change
- `cyprus_vat_rule_catalog.md` — canonical Cyprus VAT rate table
- `data_layer_conventions_policy` — identifier generation (gen_uuid_v7), canonical JSON
- `audit_event_taxonomy` — canonical event catalogue for LEDGER domain events
- `audit_log_policies` — audit chain partitioning, per-role RLS on audit rows

## Open items deferred to later sub-docs

- Sub-account seeding for businesses that migrate from an existing chart — Block 11 Phase 03
- Chart export to standard Cyprus accounting formats — Block 16 Phase 02
- Account code range reservations for multi-business consolidated reporting — Stage 2+
