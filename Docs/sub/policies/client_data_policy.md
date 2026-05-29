# Client Data Policy

**Block:** data
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This policy governs the collection, storage, access, use, and deletion of client data within the platform. Client data refers to all information about the businesses and individuals that a platform user (the account-holding business) invoices or transacts with. This includes client names, legal names, VAT numbers, addresses, email addresses, and phone numbers.

Client records are created and owned by a specific business entity on the platform. They are not shared across business entities. This policy defines the legal basis for processing, retention rules, access controls, export rights, deletion constraints, and breach obligations as they apply to client data.

## Scope

This policy applies to all data stored in the `clients` table and any derived records that contain client identifiers, including:

- Invoice records referencing `client_id`
- Credit note records referencing `client_id`
- VIES validation cache records referencing the client's VAT number
- Audit log entries that capture client creation, update, or deactivation events
- Data export bundles that include client records

## Legal Basis for Processing

Processing of client personal data is conducted under **GDPR Article 6(1)(b)** — processing is necessary for the performance of a contract to which the data subject is party, or in order to take steps at the request of the data subject prior to entering into a contract.

Specifically: the platform processes client contact details (email, phone) and identifying information (name, VAT number, address) because those details are required to generate legally valid invoices, which is a contractual obligation between the platform user and their client.

For EU-based company clients, processing of the VAT number also falls under **GDPR Article 6(1)(c)** — processing is necessary for compliance with a legal obligation (VAT reporting requirements under Cyprus and EU law).

No special-category data as defined by GDPR Article 9 is collected or processed for client records.

## Data Fields and Classification

| Field | PII Classification | Notes |
|---|---|---|
| name | PII — Indirect | May be a personal name for INDIVIDUAL clients |
| legal_name | PII — Indirect | As above |
| email | PII — Direct | Primary contact; used for invoice delivery |
| phone | PII — Direct | Optional; for contact purposes only |
| vat_number | PII — Indirect | Publicly registered for companies; personal tax ID for individuals |
| address_line1, address_line2, city, postal_code | PII — Indirect | |
| country_code | Non-PII | |
| payment_terms_days | Non-PII | Business configuration |
| notes | PII — Contextual | Free text; may contain personal information |
| is_active | Non-PII | Soft-delete flag |

All PII fields are stored encrypted at rest per `encryption_at_rest_policy.md`. Email and phone fields are subject to redaction in log output per `redaction_at_write_policy.md`.

## Data Access Controls

Client data is scoped exclusively to the business entity that created the client record. Access control is enforced at two layers:

**Row-Level Security (RLS):** All queries against the `clients` table pass through Supabase RLS policies. A member of business A cannot read, update, or delete client records belonging to business B. RLS policies use the `business_id` column for all scoping. See `supabase_rls_policy_map.md` for the specific policy definitions.

**Application Layer:** The application validates that the authenticated user is an active member of the target business before any client operation. Role requirements:

- `VIEWER` — read client list and individual client records
- `ACCOUNTANT` — read + create + update clients
- `ADMIN` — read + create + update + deactivate clients

No role can delete a client record directly. Deletion is subject to the constraints defined in the Deactivation and Deletion section below.

## Client Deactivation vs. Deletion

**Soft deactivation** is the standard mechanism for removing a client from active use. Setting `is_active = false` hides the client from default list views and prevents new invoices from being created against them. The client record and all associated invoices remain intact and queryable.

**Hard deletion** of a client record is blocked in the following circumstances:

- One or more invoices exist with `status` of `DRAFT`, `SENT`, `PARTIALLY_PAID`, or `OVERDUE` referencing the client. Outstanding financial obligations must be resolved (paid, voided, or credited) before the client record can be permanently removed.
- One or more credit notes exist with an open balance referencing the client.
- The client appears in any finalized run's archive bundle. Once an archive bundle has been sealed (Object Lock COMPLIANCE), the underlying client record may not be deleted because it forms part of a tamper-evident financial record.

When hard deletion is permitted (no outstanding invoices, no archive references), the deletion cascades to:
- The `clients` row
- Any VIES validation cache rows for the client's VAT number (these are ephemeral anyway — see VIES Validation section)
- Audit log entries referencing the client are **not** deleted; the audit log is append-only and permanent

The application emits no `CLIENT_DELETED` audit event for hard deletes that pass all preconditions. If a future requirement adds hard-delete audit logging, it should be added to the audit event taxonomy.

## GDPR Data Subject Rights

Client data may involve natural persons (INDIVIDUAL client type or named contacts at COMPANY clients). Where the data subject exercises rights under GDPR Chapter III, the following handling applies:

**Right of access (Art. 15):** The platform user (data controller) is responsible for fulfilling subject access requests from their clients. The platform provides a data export mechanism (see Data Portability section) that the platform user can use to extract client data and supply it to the requester.

**Right to rectification (Art. 16):** Any ACCOUNTANT or ADMIN member of the owning business may update client fields at any time. Updates are audit-logged as `CLIENT_UPDATED`.

**Right to erasure (Art. 17):** Erasure of client data is subject to the deletion constraints above. Where financial records referencing the client must be retained under tax law (7-year obligation), erasure of the client record itself is deferred until that obligation lapses. The platform user should document this deferral when responding to the data subject.

**Right to data portability (Art. 20):** Covered by the data export mechanism described below.

All GDPR data subject rights procedures are governed by `gdpr_data_subject_rights_policy.md`, which takes precedence in the event of any conflict with this policy.

## Data Portability

Client records are included in full data exports requested by the business account owner. Export format is structured JSON. The export includes all fields from the `clients` table for all clients belonging to the business, plus invoice records keyed to each client.

Export jobs are managed per `data_export_policy.md`. Export download links expire after 24 hours (Export-temp zone). The exported file itself is not retained by the platform after link expiry.

The audit event `CLIENT_DATA_EXPORTED` (LOW severity) is emitted each time a data export that includes client records is generated.

## VIES Validation

For clients with `client_type = 'EU_COMPANY'` and a non-null `vat_number`, the platform validates the VAT number against the EU VIES system via `ledger.validate_vies` before the first invoice is created against that client.

Validation results are cached for **24 hours** in the `vat_validation_cache` table (see `vat_validation_cache_schema.md`). The cache stores:
- The VAT number queried
- The VIES response (valid/invalid, trader name if returned)
- The timestamp of validation
- The expiry timestamp (now + 24h)

Cached validation results are **not** treated as a permanent record and are not subject to the 7-year retention rule. Cache rows are deleted on expiry by the scheduled cleanup job.

The `vat_number_valid` boolean on the `clients` row is updated to reflect the most recent VIES check. A `null` value means no validation has been performed yet.

VIES validation policy details are in `client_vat_validation_policy.md`.

## Data Retention

Client records fall in the **Operational zone** and are retained for **7 years** from creation. This retention period is required by:

- Cyprus Tax Law 4/1978 — requires retention of all records relevant to tax assessments
- Income Tax Law 118(I)/2002 — requires retention of accounting records supporting filed returns

After 7 years, client records may be deleted subject to the hard-deletion constraints above. If any invoice created against the client is still within its own 7-year retention window, the client record must be retained until all associated invoices have also aged out.

The VIES validation cache is exempt from the 7-year rule. See the VIES Validation section above.

## Cyprus Data Protection Commissioner

The platform operator is required to be registered with the **Cyprus Data Protection Commissioner** (Αρχή Προστασίας Δεδομένων Προσωπικού Χαρακτήρα) as a data controller for the processing activities described in this policy. Registration must be maintained and updated if the categories of data processed or the purposes of processing change materially.

Contact details and registration reference are maintained in the platform's internal legal records. The Cyprus DPA can be reached at: Commissioner for Personal Data Protection, 1 Iasonos Street, 1082 Nicosia, Cyprus.

## Breach Notification

If a security incident results in unauthorized access to, disclosure of, or destruction of client personal data, the following obligations apply:

1. **Internal detection and containment:** The security team must be notified immediately upon discovery.
2. **Risk assessment:** Within 24 hours of discovery, the team must assess whether the breach is likely to result in a risk to the rights and freedoms of natural persons.
3. **Supervisory authority notification:** If the risk assessment determines a notifiable breach exists, the Cyprus DPA must be notified within **72 hours** of the platform becoming aware of the breach, per GDPR Article 33. If notification cannot be made within 72 hours, it must be made without undue further delay with a documented explanation of the delay.
4. **Data subject notification:** Where the breach is likely to result in a high risk to the rights and freedoms of natural persons (GDPR Art. 34), affected data subjects (the platform user's clients) must be notified without undue delay.

Breach notification content requirements are defined in the internal incident response runbook. The platform user (data controller) may also carry independent notification obligations to their own clients.

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| CLIENT_CREATED | LOW | New client record inserted |
| CLIENT_UPDATED | LOW | Any field on the client record changed |
| CLIENT_DEACTIVATED | LOW | `is_active` set to false |
| CLIENT_DATA_EXPORTED | LOW | Data export bundle generated that includes client records |

All audit events are written to the append-only audit log per `audit_log_schema.md`. The audit log is permanent and not subject to deletion.

## Related Documents

- `schemas/client_schema.md` — DDL for the clients table
- `gdpr_data_subject_rights_policy.md` — Full GDPR rights handling procedures
- `data_export_policy.md` — Export pipeline and format specification
- `data_retention_policy.md` — Master retention rules for all data zones
- `encryption_at_rest_policy.md` — Encryption standards for PII fields
- `redaction_at_write_policy.md` — Log redaction rules for PII fields
- `client_vat_validation_policy.md` — VIES validation policy
- `vat_validation_cache_schema.md` — VIES cache schema
- `supabase_rls_policy_map.md` — RLS policy definitions
- `audit_log_schema.md` — Audit log schema
- `row_level_security_policies.md` — RLS implementation patterns
