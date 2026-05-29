# Chart of Accounts Policy

**Category:** Policies · **Owning block:** 05 — Ledger & Accounts · **Stage:** 4 sub-doc (Layer 2)

This policy governs the structure, seeding, customisation, and immutability rules for the chart of accounts on the platform. All account creation, modification, and deactivation decisions must conform to these rules.

---

## 1. Account Code Structure

Account codes are four-digit integers. The code is the primary identifier used in ledger entries, VAT control accounts, and report definitions. The format is fixed: exactly four decimal digits, no alphabetic characters, no separators.

Sub-accounts within a parent range are expressed by adding a decimal suffix: `6010`, `6011`, `6012` are sub-accounts of `6010`. The platform stores the code as `TEXT` (not integer) to preserve leading zeros and sub-account notation. The sort order for display is lexicographic on the code column.

Codes are allocated by range according to Cyprus accounting standards:

| Range | Category |
|---|---|
| 1000–1999 | Assets |
| 2000–2999 | Liabilities |
| 3000–3999 | Equity |
| 4000–4999 | Revenue |
| 5000–5999 | VAT Control Accounts |
| 6000–6999 | Expenses |

No ranges outside 1000–6999 are permitted. Codes below 1000 or above 6999 are rejected at the database constraint level.

---

## 2. Reserved Code Ranges

Certain codes within each range are reserved for system use and may not be modified or deactivated by business entities. Reserved codes are seeded at business creation and locked against name changes.

Reserved codes include (non-exhaustive):

- `1100` — Bank (current account)
- `1200` — Accounts Receivable
- `2100` — Accounts Payable
- `3000` — Share Capital
- `4000` — General Revenue
- `5100` — VAT Output Control
- `5200` — VAT Input Control
- `5300` — VAT Payable
- `6000` — General Expenses

The complete reserved code list is stored in the platform seed migration and is not configurable per business entity.

---

## 3. Default Chart for New Businesses

When a business entity is created, a default chart of accounts is seeded from the platform-level template. The seeding operation runs within the business creation transaction and cannot be deferred.

The default chart includes approximately 40 accounts covering the most common Cyprus SME account types. All seeded accounts have `is_system_seeded = true`. Custom accounts added by the business have `is_system_seeded = false`.

Seeding is idempotent: if the business creation transaction is retried, duplicate seeding is prevented by the unique constraint on `(business_entity_id, account_code)`.

---

## 4. Custom Account Creation Rules

Business entities may add accounts within any permitted range, subject to the following constraints:

1. The code must fall within a permitted range (1000–6999).
2. The code must not already exist for the business entity.
3. The account name must be non-empty and unique within the business entity.
4. Custom accounts must be assigned to a parent range matching their code prefix (e.g. code `6150` must be in the Expenses range).
5. A maximum of 500 total accounts per business entity is enforced. If the limit is reached, no further accounts may be created until existing accounts are deactivated.

Custom accounts are created via the `chart_of_accounts` write path. Creation emits `ACCOUNT_CREATED` to the audit log.

---

## 5. Immutability After Period Lock

Once a period is locked (`period_lock_schema.md`), the accounts referenced by ledger entries in that period are subject to the following restrictions:

- An account that has any ledger entry in a locked period cannot be deleted or deactivated.
- An account code cannot be changed at any time (codes are immutable after creation, regardless of lock state).
- An account name may be changed even after period lock, but only by `org:owner` or `org:accountant` roles. The change is logged as `ACCOUNT_NAME_CHANGED`.
- New accounts may be added to the chart at any time, including after a period is locked. Adding an account does not affect the integrity of existing locked entries.

Attempts to deactivate an account with locked-period ledger entries return a BLOCKING error: `ACCOUNT_HAS_LOCKED_ENTRIES`.

---

## 6. Account Deactivation Rules

An account may be deactivated (set `is_active = false`) if all of the following conditions are met:

1. The account has no ledger entries in any locked period.
2. The account has no open invoices, payments, or workflow runs referencing it.
3. The account is not a reserved system account (`is_system_seeded = true`).
4. The deactivation is performed by `org:owner` or `org:accountant`.

Deactivated accounts do not appear in the account selector in the UI, but remain in the chart for historical reporting. Ledger entries that already reference a deactivated account are unaffected.

Reactivation of a deactivated account is permitted at any time by the same roles, without conditions.

Deactivation emits `ACCOUNT_DEACTIVATED`. Reactivation emits `ACCOUNT_REACTIVATED`.

---

## 7. VAT Control Accounts (5000–5999)

The 5000–5999 range is reserved exclusively for VAT control accounts. These accounts are written by the platform's VAT calculation engine and must not be written directly by ledger entry tools or manual journal entries.

The VAT control accounts are seeded with the business and reflect the Cyprus VAT return structure. Custom accounts may be added in the 5000–5999 range only for ancillary VAT tracking purposes (e.g. a separate sub-account for reverse-charge VAT), subject to `org:accountant` approval.

Direct manual entries to 5000–5999 accounts are rejected with severity HIGH: `VAT_CONTROL_DIRECT_WRITE_BLOCKED`.

---

## 8. Audit Events

| Event | Trigger |
|---|---|
| `ACCOUNT_CREATED` | New account added to the chart |
| `ACCOUNT_NAME_CHANGED` | Account name updated |
| `ACCOUNT_DEACTIVATED` | Account set to is_active = false |
| `ACCOUNT_REACTIVATED` | Account set to is_active = true |
| `ACCOUNT_SEEDED` | System seeding during business creation |

---

## Related Documents

- `chart_of_accounts_schema.md` — DDL and column reference for the accounts table
- `ledger_account_chart_schema.md` — ledger account chart view
- `ledger_entry_schema.md` — how account codes are referenced in journal entries
- `period_lock_schema.md` — period lock state that restricts account deactivation
- `vat_entry_schema.md` — VAT control account writes
- `vat_rate_policy.md` — VAT rates mapped to VAT control accounts
- `chart_customization_policy.md` — UI-layer rules for account customisation
- `double_entry_validation_policy.md` — validation that uses account range checks

---

## 9. Account Range Enforcement at Write Time

The platform enforces range membership at the point of ledger entry creation, not only at account creation. If an account is reclassified (which is not permitted — codes are immutable), any subsequent entry to that account would still be validated against the original range. In practice, range enforcement at entry creation time means:

- An entry with account code `4500` is accepted without further range checks — the code itself encodes the range.
- An entry referencing a deactivated account is rejected with: `ACCOUNT_INACTIVE`.
- An entry referencing an account belonging to a different business entity is rejected with: `ACCOUNT_TENANT_MISMATCH`.

These checks are implemented in the ledger entry insertion path and are not bypassable via direct SQL from application code (RLS enforces tenant isolation).
