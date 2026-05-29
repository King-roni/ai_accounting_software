# GDPR Right to Erasure Policy

**Category:** Policies · **Owning block:** 05 — Security, Audit & Compliance · **Stage:** 4 sub-doc (Layer 2)

This policy defines how the platform handles erasure requests under GDPR Article 17 (right to
erasure / "right to be forgotten"). It specifies what data is erasable, what is exempt, the
process for executing erasure, response timelines, and obligations under Cyprus data protection law.

---

## 1. Legal context

Cyprus transposed the GDPR via Law 125(I)/2018. The Cyprus Commissioner for Personal Data
Protection (the "Commissioner") is the competent supervisory authority. Erasure requests submitted
by data subjects are handled under GDPR Article 17, subject to the exemptions in Article 17(3).

The Article 17(3)(b) exemption (compliance with a legal obligation) applies to business financial
records. Cyprus Income Tax Law (Cap. 297) and the VAT Law (95(I)/2000) require that accounting
records be retained for a minimum of 7 years from the end of the relevant tax year. These records
may not be erased regardless of a data subject erasure request until the 7-year retention period
has expired.

The platform operates as:

- **Data controller** for personal data of platform users (account holders, invited members).
- **Data processor** for personal data contained within business financial documents and
  transactions uploaded by the business owner.

---

## 2. What can be erased

The following categories of data are erasable upon a valid Article 17 request:

| Data category | Table / location | Erasure method |
|---|---|---|
| User display name | `user_profiles.display_name` | Replaced with anonymised placeholder |
| User avatar | `user_profiles.avatar_url` | Set to NULL; Storage object deleted |
| User preferred locale and timezone | `user_profiles` | Reset to system defaults |
| Contact details (email display) | `user_profiles` (derived from auth) | Auth account deletion |
| PII in transaction descriptions | `transactions.description`, `transactions.raw_description` | Redacted to `[ERASED]` |
| Counterparty names linked to the user | `counterparties.name` where sourced from user input | Redacted per `redaction_policies` |
| Bank account references linked to the user | `bank_feeds.masked_account_ref` | Set to NULL |
| Auth account | `auth.users` | Supabase Auth account deletion |

Erasure of `auth.users` cascades to `user_profiles` via the `ON DELETE CASCADE` FK and
invalidates all active sessions for the user.

---

## 3. What cannot be erased

The following categories are permanently exempt from erasure:

### 3a. Audit logs

`audit_logs` is an append-only table. No `UPDATE` or `DELETE` policy exists on the table;
the RLS configuration prevents any modification after insert. Audit logs are exempt from
erasure under Article 17(3)(b) (legal obligation to maintain accurate accounting and compliance
records) and Article 17(3)(e) (establishment, exercise, or defence of legal claims).

### 3b. Financial records during the 7-year retention period

The following tables are exempt while a business's retention period is active:

- `ledger_entries`
- `invoices` and `invoice_line_items`
- `transactions` (the record itself; description field is erasable — see Section 2)
- `vat_entries`, `vat_returns`
- `periods` and `period_locks`
- `archive_bundles` and all contents

Records become eligible for deletion only after the 7-year retention window expires per
`data_retention_policy`. Period-locked ledger entries cannot be erased under any circumstances
while the period lock is active.

### 3c. Other exemptions

- Anonymised or aggregated data that cannot be re-linked to the individual.
- Data required to fulfil an ongoing contractual obligation (e.g., an active subscription record).

---

## 4. Erasure process

All erasure requests are processed through the `data.erase_user_pii` tool, which executes in
the service role context to bypass RLS across all business entities the user belongs to.

### Step 1 — Request receipt and verification

Requests may be submitted via the in-app privacy portal (authenticated session required) or via
the designated DPO email address. Identity must be verified before processing begins.

### Step 2 — Eligibility check

`data.erase_user_pii` performs a pre-flight check:

- Identifies all `business_entity_id` values linked to the user via `org_members`.
- For each business, checks for active `period_locks` that would block financial record erasure.
- Flags any financial records within the 7-year window as non-erasable.
- Returns an erasure plan: a list of actions that will and will not be performed.

### Step 3 — DPO review

The erasure plan is reviewed by the Data Protection Officer (DPO). If the plan includes partial
erasure (some data exempt), the DPO confirms that the partial erasure response to the data subject
is accurate.

### Step 4 — Execution

`data.erase_user_pii` executes the approved erasure plan within a single transaction where
possible. Each erasure action emits an audit event (see Section 5).

### Step 5 — Confirmation

A written confirmation is sent to the data subject listing what was erased, what was exempted
and why, and the date of completion.

---

## 5. Audit events

| Event | Emitted when |
|---|---|
| `PRIVACY_ERASURE_REQUESTED` | Data subject request received and logged |
| `PRIVACY_USER_PII_ERASED` | `data.erase_user_pii` completes an erasure action |
| `PRIVACY_ERASURE_PARTIALLY_EXEMPTED` | Erasure completed with at least one exempt record |
| `PRIVACY_ERASURE_DENIED` | Request denied (identity not verified, or all data exempt) |

These events are written to `audit_logs` and are themselves append-only. They are not erased
even when processing an erasure for the same user.

---

## 6. Timelines

| Milestone | Deadline |
|---|---|
| Acknowledgement to data subject | 3 business days from receipt |
| Erasure completion | 30 calendar days from receipt of verifiable request |
| Extension (complex / high-volume) | Up to 60 additional calendar days, with prior notice to data subject |

If the deadline cannot be met, the DPO must notify the data subject before the 30-day deadline
expires, stating the reason for the extension.

---

## 7. DPA notification threshold

Notification to the Cyprus Commissioner for Personal Data Protection is required in the following
circumstances related to erasure:

- A request is refused in full and the data subject contests the refusal — the data subject has
  the right to lodge a complaint with the Commissioner directly.
- A personal data breach occurs during or as a result of the erasure process — standard breach
  notification obligations apply per GDPR Article 33 (72-hour threshold).

The platform does not proactively notify the Commissioner for routine erasure completions.
Notification obligations are triggered only by refusals and breaches, as above.

---

## Related Documents

- `gdpr_data_subject_rights_policy` — full data subject rights framework (all GDPR rights)
- `data_retention_policy` — 7-year retention schedule and table-level retention rules
- `audit_log_policies` — append-only guarantee; why audit_logs cannot be erased
- `redaction_policies` — redaction patterns for PII in descriptions and counterparty fields
- `redaction_at_write_policy` — PII redaction at ingestion time
- `redaction_field_map` — field-by-field redaction specification
- `multi_tenancy_isolation_policy` — service role usage in `data.erase_user_pii`
- `finalization_lock_policy` — period-locked entries and exemption from erasure
- `tools/data_erase_user_pii` — tool specification for the erasure executor
