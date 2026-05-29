# GDPR Data Subject Rights Policy

**Block:** 05 — Security, Audit & Compliance  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This policy defines how the platform processes data subject rights requests under the EU General Data Protection Regulation (GDPR). It covers each right separately, including trigger conditions, intake procedures, internal processing steps, SLAs, system behaviour, and Cyprus-specific legal constraints. Where financial record retention obligations conflict with GDPR erasure rights, the applicable exemption and its scope are stated precisely.

---

## 1. Legal Basis and Context

The platform acts as a **data controller** for personal data of its users (account holders, invited members) and as a **data processor** for personal data contained in business financial records uploaded by business owners.

Cyprus transposed the GDPR via Law 125(I)/2018. The Cyprus Commissioner for Personal Data Protection is the competent supervisory authority. For business financial records, the Cyprus Income Tax Law (Cap. 297) and VAT Law (95(I)/2000) mandate 7-year retention of accounting records, providing the Article 17(3)(b) exemption for erasure requests that conflict with that obligation.

All data subject rights requests are handled with a maximum **30-calendar-day SLA** from receipt of a verifiable request, extendable by an additional 60 days where the complexity or volume of requests justifies it, with prior notification to the data subject.

---

## 2. Data Subject Request Intake Flow

All requests follow a standardised intake procedure regardless of the right being exercised:

```
1. REQUEST RECEIVED
   ↓
2. IDENTITY VERIFIED
   ↓
3. DPO REVIEW
   ↓
4. ACTION EXECUTED
   ↓
5. CONFIRMATION SENT
```

**Step 1 — Request received.** Requests may be submitted via the in-app privacy portal (authenticated users) or via email to the designated DPO address. The intake timestamp is recorded and an acknowledgement is dispatched within 3 business days.

**Step 2 — Identity verified.** For authenticated in-app requests, the active session is sufficient. For email requests, the user must provide a government-issued ID or confirm control of the registered email address via a one-time link. Requests from third parties on behalf of a data subject require a signed letter of authorisation.

**Step 3 — DPO review.** The Data Protection Officer reviews the request for completeness, applicability, and any legal constraints. For erasure requests, the DPO checks the retention register (Section 9) before approving execution.

**Step 4 — Action executed.** The appropriate technical action is performed by the platform team under DPO supervision. Execution is logged via the relevant audit event.

**Step 5 — Confirmation sent.** A written response is delivered to the data subject describing the action taken, any limitations applied, and any exemptions invoked.

---

## 3. Article 15 — Right of Access

**Trigger:** A data subject requests confirmation of whether personal data is being processed and, if so, access to that data and supplementary information (processing purposes, categories, recipients, retention periods, rights available).

**Process:**
1. Intake as described in Section 2.
2. Platform generates a scoped data export covering all personal data held for the requesting data subject across all business contexts they belong to.
3. Export includes: account profile, session history summary, MFA device records (excluding secrets), audit log entries where the user is named, and any business-scoped personal data for which the user is a member.
4. Delivered in JSON format (machine-readable, structured).

**System behaviour:**
- The export job is created by the DPO operator on behalf of the data subject using the `export_jobs` mechanism described in `data_export_policy.md`.
- The export includes data from all `business_id` contexts the user belongs to.
- Encrypted fields (counterparty PII, etc.) are decrypted for inclusion in the subject access export.

**Audit event:** `GDPR_ACCESS_REQUESTED` (LOW) — emitted when the DPO creates the subject access export job. Payload: `user_id`, `request_received_at`, `dpo_user_id`, `export_job_id`.

**SLA:** 30 calendar days from receipt of verified request.

---

## 4. Article 16 — Right of Rectification

**Trigger:** A data subject identifies personal data that is inaccurate or incomplete and requests correction.

**Process:**
1. Intake as described in Section 2.
2. DPO identifies the relevant data records and the appropriate correction action.
3. Corrections are applied directly to the relevant tables. If the record is part of a finalized period (locked ledger), a formal adjustment workflow is required per `invoice_amendment_policy.md` or `adjustment_policy.md`.
4. Where rectification affects a finalized archive bundle, the DPO records a documented exception and the archive bundle is annotated with a correction note. The bundle itself is not altered (Object Lock prevents modification).

**System behaviour:**
- Profile data (`users` table): updated directly.
- Transaction or invoice data: updated via the standard amendment tools if the period is not locked; via adjustment workflow if locked.
- No special rectification tooling is required beyond existing amendment procedures.

**Audit event:** `BUSINESS_UPDATED` (LOW) — emitted per standard business record update logic when corrections are applied to business-owned records. `USER_UPDATED` (LOW) — emitted when profile records are corrected.

**SLA:** 30 calendar days.

---

## 5. Article 17 — Right to Erasure (Right to Be Forgotten)

**Trigger:** A data subject requests deletion of their personal data. This is the most complex right to process due to retention law conflicts.

### 5.1 Erasure Scope and Process

1. Intake as described in Section 2.
2. DPO checks the retention register (Section 9) to determine which data categories are subject to the 7-year financial records retention exemption.
3. For data not subject to the exemption: hard deletion is executed (row deleted from primary tables, object storage objects deleted, DEK-encrypted fields made unrecoverable by DEK destruction for that scope if applicable).
4. For data subject to the exemption: pseudonymisation is applied — identifying fields (name, email, phone, address) are replaced with opaque identifiers. The financial record (transaction, invoice, ledger entry) is retained in pseudonymised form for the mandatory retention period.

### 5.2 Cyprus Tax Law Exemption — Article 17(3)(b)

GDPR Article 17(3)(b) permits refusal or restriction of erasure where processing is necessary for compliance with a legal obligation under Union or Member State law.

In Cyprus, the following laws mandate retention of accounting records for **7 years** from the end of the tax year to which they relate:

- Cyprus Income Tax Law, Cap. 297, Section 31.
- Cyprus VAT Law 95(I)/2000, Section 37.

Data categories subject to this exemption:

| Category | Retention Basis | Erasure Action |
|----------|----------------|----------------|
| Transaction records | VAT Law, Income Tax Law | Pseudonymised; not deleted |
| Invoice records | VAT Law | Pseudonymised; not deleted |
| Ledger entries | Income Tax Law | Pseudonymised; not deleted |
| VAT entries and periods | VAT Law | Pseudonymised; not deleted |
| Bank statement rows | Income Tax Law | Pseudonymised; not deleted |

Data categories **not** subject to the exemption (deleted on valid erasure request):

| Category | Action |
|----------|--------|
| User profile (`users` table) | Hard deleted or anonymised |
| Session records | Hard deleted after SLA window |
| MFA device records | Hard deleted |
| Non-financial audit log entries | Pseudonymised (audit entries cannot be deleted; see Section 5.3) |
| Export job metadata | Pseudonymised (`requested_by` replaced with null UUID) |

### 5.3 Audit Log Entries

Audit log entries are append-only and protected by a hash chain. Individual entries cannot be deleted without breaking the chain integrity. For erasure requests, the `user_id` field in the `audit_log` table is pseudonymised to a stable opaque identifier per business, so the audit trail integrity is preserved without retaining the linking identifier.

### 5.4 System Behaviour

The DPO executes erasure via an internal admin tool. The tool:
1. Classifies each data category against the retention register.
2. Executes hard deletions for non-exempt categories.
3. Applies pseudonymisation via `data.pseudonymise_user` for exempt categories.
4. Triggers DEK rotation if the data subject is the sole member of a business.
5. Invalidates all active sessions for the requesting user.

**Audit events:**
- `GDPR_ERASURE_REQUESTED` (MEDIUM) — emitted at intake when a verified erasure request is received. Payload: `user_id`, `request_received_at`, `dpo_user_id`.
- `GDPR_PSEUDONYMIZED` (MEDIUM) — emitted when pseudonymisation is applied to a data record. Payload: `user_id`, `table_name`, `record_count`, `pseudonymised_at`.
- `GDPR_ANONYMIZED` (MEDIUM) — emitted when hard deletion or anonymisation is applied. Payload: `user_id`, `table_name`, `record_count`, `anonymised_at`.

**SLA:** 30 calendar days. Erasure of pseudonymised records is completed at the end of the mandatory retention period (7 years from period close).

---

## 6. Article 18 — Right to Restriction of Processing

**Trigger:** A data subject contests the accuracy of personal data, objects to processing, or requests restriction while a dispute over erasure is pending.

**Process:**
1. Intake as described in Section 2.
2. DPO applies a restriction flag on the affected data records.
3. Restricted records are excluded from AI processing, reporting, and any automated decision-making.
4. Restricted records remain accessible to the data subject and for legal compliance purposes.

**System behaviour:**
- A `processing_restricted` boolean column is set on the relevant `users` row.
- The classification engine skips restricted records.
- Restricted records are excluded from AI training pipelines (no records enter AI training from this platform).

**SLA:** 30 calendar days to confirm restriction is in place.

---

## 7. Article 20 — Right to Data Portability

**Trigger:** A data subject requests their data in a portable, structured, machine-readable format, or requests direct transfer to another controller.

**Process and system behaviour:**

Portability requests are fulfilled via the data export mechanism defined in `data_export_policy.md`. The DPO creates an export job on behalf of the data subject using the `JSON` format. The export covers all data categories listed in that policy.

Direct transfer to another controller (controller-to-controller transfer) is not currently automated. The DPO provides the JSON export file to the data subject, who may then submit it to the receiving controller.

**SLA:** 30 calendar days.

---

## 8. Article 21 — Right to Object

**Trigger:** A data subject objects to processing of their personal data where the legal basis is legitimate interests (Article 6(1)(f)) or public interest (Article 6(1)(e)).

**Process:**
1. Intake as described in Section 2.
2. DPO assesses whether the objection relates to processing based on legitimate interests or direct marketing.
3. For direct marketing: processing ceases immediately, no balancing test required.
4. For other legitimate-interest processing: a balancing test is conducted. If the controller cannot demonstrate compelling legitimate grounds that override the data subject's interests, processing ceases.

**System behaviour:**
- A `marketing_opt_out` flag is set on the `users` row.
- The notification dispatch system excludes opted-out users from non-essential communications.
- Core account and financial processing continues as it is necessary for contractual performance (Article 6(1)(b)).

**SLA:** Objections to direct marketing are processed immediately (within 1 business day). Other objections within 30 calendar days.

---

## 9. Retention Register

The DPO maintains a retention register that maps each data category to its legal basis, retention period, and applicable exemptions. The register is the authoritative source for erasure eligibility decisions.

| Data Category | Legal Basis for Processing | Retention Period | Erasure Exemption |
|---------------|---------------------------|-------------------|-------------------|
| Transaction records | GDPR Art. 6(1)(b) + Cyprus VAT Law | 7 years from period close | Art. 17(3)(b) |
| Invoice records | GDPR Art. 6(1)(b) + Cyprus VAT Law | 7 years from period close | Art. 17(3)(b) |
| Ledger entries | GDPR Art. 6(1)(c) + Income Tax Law | 7 years from period close | Art. 17(3)(b) |
| User profile | GDPR Art. 6(1)(b) | Duration of account + 90 days | None |
| Session records | GDPR Art. 6(1)(f) (fraud prevention) | 90 days | None |
| Audit log entries | GDPR Art. 6(1)(c) (legal obligation) | 7 years | Art. 17(3)(b) — pseudonymise only |
| AI classification results | GDPR Art. 6(1)(b) | Duration of run + 7-day Processing zone TTL | None after TTL |

---

## 10. Pseudonymisation vs Deletion

**Pseudonymisation** replaces directly identifying fields with opaque, business-scoped identifiers. The pseudonymisation mapping is stored separately under DPO-exclusive access. The record remains in the database and retains its referential integrity for financial reporting. Pseudonymised records cannot be re-identified by the platform without DPO access to the mapping table.

**Hard deletion** removes the row from the primary table and deletes any associated object storage objects. No mapping is retained. This is the preferred action for non-exempt data categories.

Pseudonymisation satisfies the GDPR erasure obligation for records that must be retained under financial law, because the data is no longer attributable to an identified or identifiable natural person without additional data held exclusively by the DPO.

---

## 11. Cyprus-Specific Compliance Notes

- The Cyprus Commissioner for Personal Data Protection (CPDP) is the lead supervisory authority. The DPO must notify the CPDP of any data breach within 72 hours under Article 33.
- Cyprus Law 125(I)/2018, Article 9, permits continued processing of personal data in financial records for archiving purposes in the public interest and for scientific, historical, or statistical purposes, provided appropriate safeguards apply.
- The 7-year retention period under Cyprus tax law runs from the end of the tax year to which the financial record relates, not from the date of processing.
- Requests from data subjects resident in other EU member states are treated identically. There is no reduced protection for non-Cyprus residents.

---

## 12. Related Documents

- `policies/data_export_policy.md`
- `policies/data_retention_policy.md`
- `policies/encryption_at_rest_policy.md`
- `policies/redaction_at_write_policy.md`
- `reference/audit_event_taxonomy.md`
- `schemas/user_schema.md`
- `schemas/audit_log_query_schema.md`
