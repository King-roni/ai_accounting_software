# Phase 1 Foundation Dev Spec

## 1. Document Purpose

This document defines the definitive Phase 1 development specification for the AI-native bookkeeping platform. It translates the project blueprint into an implementation-ready foundation scope that is narrow, stable, and consistent with the existing project files.

Phase 1 is not the invoice engine, not the reconciliation engine, not the AI accounting engine, and not the reporting engine. Phase 1 exists to establish the system foundation on which all later phases depend.

The purpose of this phase is to build the trust-bearing platform skeleton: tenant structure, company settings, access control, foundational domain records, document vault behavior, baseline reporting periods, async processing scaffolding, and audit infrastructure.

This phase must preserve the platform’s core design principles from the start:

- multi-tenant architecture
- founder-first product direction
- accountant-safe backend design
- strict separation between source truth, machine interpretation, and approved accounting truth
- evidence preservation and auditability
- future readiness for AI-driven bookkeeping without prematurely implementing it

---

## 2. Phase Objective

The objective of Phase 1 is to create a durable operational base that supports later accounting automation without forcing later phases to redesign the platform’s foundations.

At the end of Phase 1, the system should support:

- tenant-scoped company setup
- authenticated users with company-scoped roles
- secure foundational permissions
- contact management
- secure financial document upload and versioning
- foundational invoice records
- baseline reporting periods
- explicit processing job scaffolding
- explicit parsing-attempt scaffolding
- append-oriented audit history

At the end of Phase 1, the system should not yet perform meaningful accounting automation, reconciliation, approval routing, policy-driven posting, or filing workflows.

---

## 3. Phase Boundary

### Included in Phase 1
Phase 1 includes only the foundation layer.

### Excluded from Phase 1
Phase 1 explicitly excludes:

- OCR quality implementation
- invoice extraction logic
- AI classification logic
- invoice review workflows
- approval workflows
- posting workflows
- ledger-based accounting logic
- bank statement ingestion workflows
- transaction normalization workflows
- matching and reconciliation workflows
- duplicate detection logic
- alert engine logic
- review queue workflows
- operational dashboard metrics
- email ingestion
- Revolut sync
- export package generation
- filing workflows
- period locking and amendment workflows

This boundary must be respected strictly. No Phase 2 or later behavior should be pulled forward into Phase 1 just because schema placeholders exist.

---

## 4. Phase 1 Design Decisions

## 4.1 Ledger posture

### Decision
Phase 1 will create **ledger-ready schema scaffolding only** and will not implement operational posting logic.

### Meaning
The data model may include:

- `ledger_entries`
- `ledger_entry_lines`

but Phase 1 must not:

- create ledger entries through UI actions
- create ledger entries through background processing
- use ledger data for accounting totals, balances, reporting, or workflows
- rely on ledger tables for any operational product behavior

### Reason
The project files intentionally leave room for simpler early ledger depth while preserving future structured posting capability. Foundation must preserve extensibility without pretending that posting logic already exists.

---

## 4.2 Approval versus posting boundary

### Decision
Phase 1 supports neither business approval workflows nor posting workflows.

### Meaning
Phase 1 may include schema-ready entities such as:

- `approval_decisions`
- approval-related status fields
- posting-related status fields

but Phase 1 must not:

- expose approve or reject actions in the UI
- allow approval decisions to be created through normal workflows
- create posting records
- treat any invoice or parsing outcome as approved accounting truth

### Reason
Foundation must preserve trust-layer separation. Approval and posting belong to later product phases.

---

## 4.3 Reporting-period baseline

### Decision
Phase 1 implements ReportingPeriod as a baseline configuration and control entity only.

### Meaning
Phase 1 will support:

- company financial year configuration
- baseline period generation
- open period records
- optional linking readiness from future accounting objects

Phase 1 will not support:

- lock workflows
- unlock workflows
- amendment workflows
- export-state workflows
- filing-state workflows
- hard period enforcement in business logic

### Additional decision: generation timing
Baseline reporting periods must be generated automatically at company creation for the current fiscal year.

The system must also provide a founder/admin-only action to regenerate or extend periods when needed.

### Reason
Reporting periods are structurally core, but period control behavior belongs later.

---

## 4.4 Document-to-object linkage baseline

### Decision
Phase 1 must support an extensible document-linkage model while keeping the UI simple.

### Required structural support
Phase 1 must support:

- one `Document` to many `DocumentVersions`
- one `Document` to zero or more `Invoices`
- one `Document` to zero or more `ParsingRuns`

### Phase 1 UI behavior
The user-facing experience may optimize for the common path of one primary document linked to one invoice record, but the schema must not hardcode that limitation.

### Important state implication
Because document-to-invoice linking is in scope in Phase 1, the `linked` state must be treated as a real operational document state, not only future scaffolding.

### Reason
The domain model already requires flexible linkage. Foundation must stay extensible without making the UI unnecessarily complex.

---

## 4.5 Role and permission baseline

### Decision
Phase 1 will implement real company-scoped RBAC.

### Roles in scope
- founder
- admin
- accountant
- reviewer

### Permission domains in scope
- manage company settings
- manage company members and role assignments
- upload documents
- view documents
- create document versions
- create and edit contacts
- create and edit foundational invoice records
- link and unlink documents to invoices
- generate baseline reporting periods
- trigger processing jobs and parsing runs
- view audit history

### Explicitly out of scope for Phase 1
- approve accounting outcomes
- post accounting outcomes
- lock periods
- manage live integrations
- generate filing-ready exports

### Required enforcement layers
Permissions must be enforced across:

- frontend action visibility
- backend mutation checks
- database row-level protections
- signed storage access generation

### Reason
Roles and permissions are part of the trust foundation and cannot be postponed.

---

## 4.6 Job orchestration baseline

### Decision
Phase 1 will use a database-backed job model for async work.

### Job entity name
Use a dedicated operational entity such as `processing_jobs`.

### Minimum fields
A processing job must include at least:

- id
- company_id
- job_type
- status
- source_object_type
- source_object_id
- payload
- attempts_count
- error_summary
- created_at
- started_at
- completed_at

### Job types in scope for Phase 1
- document_post_upload_processing
- file_hash_generation
- parsing_run_execution
- retry_failed_processing

### Rules
Phase 1 must not rely on opaque background execution. Async work must remain visible, retryable, and stateful.

### Reason
The architecture requires explicit, recoverable job behavior without forcing heavy infrastructure too early.

---

## 4.7 Parsing job versus ParsingRun normalization

### Decision
Phase 1 will normalize terminology as follows:

- `ProcessingJob` = orchestration wrapper for async work
- `ParsingRun` = persistent domain record representing one processing attempt on one source object

### Required relationship
- one ProcessingJob may create one ParsingRun
- retries create new ProcessingJobs and may create new ParsingRuns
- ParsingRun remains the domain and audit-relevant attempt object

### Reason
This resolves terminology drift between architecture and domain modeling.

---

## 5. Scope of Phase 1 Modules

## 5.1 Tenant and company foundation

Phase 1 must implement a company-scoped tenant foundation.

### Required company fields
At minimum, the Company model must support:

- legal name
- jurisdiction
- VAT registration context
- base currency
- financial year start
- default reporting period type
- invoice numbering configuration placeholder
- filing settings placeholder
- created_at / updated_at

### Required behavior
- company creation
- company settings update
- tenant ownership on all core operational records
- tenant-safe access boundaries

---

## 5.2 Authentication and user model

Phase 1 must implement an authenticated user model that supports company-scoped participation.

### Required behavior
- authenticated access
- membership in one or more companies through role assignment
- separation of human user identity from future automation identities
- permission-aware session handling

### Important note
Human actors and future system actors must remain distinguishable in audit design from day one.

---

## 5.3 Role model and authorization matrix

Phase 1 must implement the following baseline matrix.

### Founder
May:
- manage company settings
- manage company users and role assignments
- upload and view documents
- create document versions
- create and edit contacts
- create and edit invoice records
- link and unlink documents to invoices
- generate baseline reporting periods
- trigger processing jobs
- view audit history

### Admin
May:
- manage company settings
- manage company users and role assignments
- upload and view documents
- create document versions
- create and edit contacts
- create and edit invoice records
- link and unlink documents to invoices
- generate baseline reporting periods
- trigger processing jobs
- view audit history

### Accountant
May:
- view company settings
- view documents
- create document versions where allowed
- create and edit contacts
- create and edit invoice records
- link and unlink documents to invoices
- view reporting periods
- trigger parsing-related processing where allowed
- view audit history

May not:
- manage company users or roles
- edit sensitive company configuration

### Reviewer
May:
- view documents
- create document versions where allowed
- view contacts
- create and edit foundational invoice records where allowed
- link and unlink documents to invoices
- view reporting periods

May not:
- manage company settings
- manage users or roles
- view full audit history unless explicitly granted later

### Important implementation note
This is the Phase 1 baseline. Future phases may refine permissions further.

---

## 5.4 Contact management foundation

Phase 1 must implement foundational Contact management.

### Required fields
At minimum:

- company_id
- legal_name
- aliases
- VAT_number
- country
- email_addresses
- default_classification_hints
- risk_notes
- created_at / updated_at

### Required behavior
- create contact
- edit contact
- list contacts
- reuse contacts across invoice records

---

## 5.5 Document vault foundation

Phase 1 must implement the document evidence foundation.

### Required document fields
At minimum, Document must support:

- company_id
- document_type
- source_channel
- current_version_id
- archive_state
- created_at / updated_at

### Required document version fields
At minimum, DocumentVersion must support:

- document_id
- version_number
- storage_path
- file_hash
- file_size
- mime_type
- created_by_actor
- created_at
- replacement_reason where applicable

### Required behavior
- authenticated upload
- private tenant-aware storage path generation
- document record creation
- document version creation
- file hash capture
- secure signed retrieval
- archive state tracking
- explicit version creation on replacement

### Required rule
A replacement must create a new DocumentVersion and must never silently overwrite the prior evidence version.

---

## 5.6 Foundational invoice records

Phase 1 must implement foundational invoice records only.

### Required invoice support
The schema must support:

- incoming invoices
- outgoing invoices
- credit notes
- debit notes

### Required fields
At minimum, Invoice should support:

- company_id
- contact_id
- primary_document_link reference or relationship
- direction
- type
- invoice_number
- invoice_date
- due_date
- currency
- subtotal
- tax_amount
- total_amount
- payment_status
- review_status
- approval_status
- tax_treatment_summary_placeholder
- reporting_period_id nullable
- created_at / updated_at

### Required line-item support
InvoiceLine should support:

- invoice_id
- description
- quantity
- unit_price
- net_amount
- tax_amount
- gross_amount
- tax_code_placeholder
- category_placeholder

### Required behavior
- manual invoice creation
- manual invoice edit
- link invoice to contact
- link invoice to one or more source documents

### Important Phase 1 constraint
Invoice records in Phase 1 are foundational records only. They are not approved accounting truth and must not drive posting, compliance automation, or reporting logic.

---

## 5.7 ReportingPeriod baseline

Phase 1 must implement baseline ReportingPeriod support.

### Required fields
At minimum:

- company_id
- period_type
- start_date
- end_date
- status
- created_at / updated_at

### Required status behavior in Phase 1
Operationally, Phase 1 only needs `open` periods.

Schema may leave room for later states such as:
- under_review
- ready_to_lock
- locked
- exported
- amended

but Phase 1 must not expose those workflows.

### Required behavior
- auto-generate current fiscal-year periods at company creation
- allow founder/admin to generate missing future periods manually
- allow invoices to reference a period optionally

---

## 5.8 Parsing and extraction scaffolding

Phase 1 must implement the domain scaffolding for processing attempts.

### ParsingRun fields
At minimum:

- company_id
- document_id
- parser_type
- parser_version nullable
- status
- started_at
- completed_at
- confidence_summary nullable
- error_summary nullable

### ExtractionResult fields
At minimum:

- parsing_run_id
- extracted_payload
- field_confidence_payload nullable
- explanation_summary nullable
- created_at

### Phase 1 ParsingRun states
To remain consistent with the state-machine document, Phase 1 must use:

- pending
- running
- succeeded
- partially_succeeded
- failed
- cancelled

### Required behavior
- creation of ParsingRun from a processing job
- optional creation of ExtractionResult from a placeholder or primitive pipeline
- persistence of attempt history

### Important Phase 1 constraint
ExtractionResult data must remain interpretation-layer data only and must not automatically mutate invoice records into approved truth.

---

## 5.9 Audit infrastructure

Phase 1 must implement append-oriented audit history as a first-class subsystem.

### Required AuditEvent fields
At minimum:

- company_id
- actor_type
- actor_id
- action_type
- object_type
- object_id
- before_snapshot nullable
- after_snapshot nullable
- metadata_context nullable
- created_at

### Required audit-covered actions
- company created
- company settings changed
- user added to company
- role assignment changed
- contact created
- contact edited
- document uploaded
- document version created
- invoice created
- invoice edited
- document linked to invoice
- document unlinked from invoice
- reporting periods generated
- processing job created
- ParsingRun created
- ParsingRun succeeded / partially_succeeded / failed / cancelled

### Required rule
Audit history must be append-oriented. Business actions must never mutate or erase prior audit events.

---

## 6. Required Phase 1 Data Model

Phase 1 must include the following entities in working form:

- Company
- User
- Role
- CompanyUserRoleAssignment or equivalent membership join structure
- Contact
- Document
- DocumentVersion
- DocumentInvoiceLink or equivalent extensible linkage model
- Invoice
- InvoiceLine
- ReportingPeriod
- ProcessingJob
- ParsingRun
- ExtractionResult
- AuditEvent

Phase 1 must also include the following entities in schema-ready form only:

- ApprovalDecision
- LedgerEntry
- LedgerEntryLine

### Schema-ready only rule
For schema-ready-only entities, Phase 1 must provide:
- tables or migration definitions
- basic relational integrity

Phase 1 must not provide:
- user-facing creation flows
- normal write APIs
- background-generated usage
- business logic that depends on them

---

## 7. Phase 1 State Behavior

## 7.1 Document states in scope

Phase 1 must operationally support:
- uploaded
- queued_for_processing
- processing
- processed
- failed_processing
- linked
- archived

Phase 1 may leave room in schema for later states such as `needs_review`, but review routing is out of scope.

## 7.2 ProcessingJob states in scope

Phase 1 should support:
- queued
- running
- succeeded
- failed
- cancelled

## 7.3 ParsingRun states in scope

Phase 1 must support:
- pending
- running
- succeeded
- partially_succeeded
- failed
- cancelled

## 7.4 Invoice state posture in scope

Operationally, Phase 1 should treat invoice records as foundational objects only.

### UI-active states in Phase 1
- draft
- archived

### Schema-ready but non-operational states
- extracted
- validated
- needs_review
- approved
- posted
- partially_paid
- paid
- disputed
- voided

### Important rule
The existence of these fields or enums in schema must not be interpreted as implementation of those workflows.

---

## 8. Backend Operations Required in Phase 1

The backend is the only trusted mutation layer.

Every critical backend operation must follow this sequence:
1. authenticate request
2. validate tenant scope
3. validate permission
4. execute structured mutation
5. create audit event
6. return updated state

### Required backend operations
- create company
- update company settings
- add company member
- change member role
- create contact
- update contact
- upload document
- create document version
- create signed document access
- create invoice
- update invoice
- link document to invoice
- unlink document from invoice
- generate baseline reporting periods
- create processing job
- create ParsingRun
- create ExtractionResult optional placeholder
- fetch audit history by company or object

---

## 9. Storage and Security Rules

## 9.1 Storage rules

Phase 1 must enforce:
- private storage only for financial evidence
- tenant-aware storage paths
- no permanent public URLs
- signed retrieval only
- one document record per meaningful stored file
- explicit document versioning for replacement

## 9.2 Security rules

Phase 1 must enforce:
- backend-only privileged mutations
- strict company ownership checks on every mutation
- tenant-scoped row-level protections
- no permission trust placed in client-only logic
- clear separation between user permissions and future system automation permissions

---

## 10. Audit Requirements

Every meaningful Phase 1 mutation must generate an audit event.

### Audit event minimum contents
- actor_type
- actor_id
- action_type
- object_type
- object_id
- company_id
- timestamp
- before snapshot where applicable
- after snapshot where applicable
- metadata context where useful

### Important rule
State transitions that occur through policy or system activity in the future must also remain attributable, but in Phase 1 the foundation is human-driven plus explicit processing scaffolding.

---

## 11. Acceptance Criteria

Phase 1 is complete only when all of the following are true:

1. A company can be created with tenant-scoped foundational settings.
2. Users can belong to a company through role assignments.
3. Permissions are enforced server-side, database-side, and in signed file access behavior.
4. Contacts can be created, edited, listed, and reused.
5. A user can upload a financial document into private storage.
6. Every uploaded file creates a Document and DocumentVersion with hash and audit history.
7. A document can be linked to one or more invoice records.
8. A foundational invoice record can be created and edited manually.
9. Baseline reporting periods are generated automatically at company creation for the current fiscal year.
10. Founder or admin can generate missing future periods manually.
11. A ProcessingJob can be created for a document.
12. A ParsingRun can be created from that processing flow and persisted with explicit state.
13. An optional ExtractionResult can be stored without being treated as approved truth.
14. Every critical mutation in Phase 1 is auditable.
15. No feature in Phase 1 silently overwrites accounting evidence.
16. No feature in Phase 1 collapses source truth, machine interpretation, and approved accounting truth into a single uncontrolled record.
17. No UI or API in Phase 1 exposes approval, posting, locking, matching, reconciliation, or filing workflows.

---

## 12. Items Explicitly Deferred After Phase 1

The following remain out of scope after this phase and must be handled in later dev-specs:

- invoice extraction quality
- invoice review routing
- approval decision workflows
- posting logic
- bank statement ingestion
- transaction normalization
- matching logic
- reconciliation logic
- duplicate detection
- alert engine
- review queue
- dashboard metrics
- email ingestion
- Revolut integration
- export packages
- filing workflows
- period locking and amendment
- Cyprus tax-rule completeness
- policy-based automation thresholds

---

## 13. Implementation Order Recommendation

The recommended implementation order inside Phase 1 is:

1. company, auth, membership, and role model
2. permission enforcement and tenant protections
3. contact management
4. document and document version foundation
5. invoice foundation and document linkage
6. reporting period baseline generation
7. processing job scaffolding
8. ParsingRun and ExtractionResult scaffolding
9. audit coverage hardening

This sequence reduces rework and ensures that all later records inherit the correct trust structure.

---

## 14. Final Phase 1 Summary

Phase 1 builds the platform’s durable trust foundation. It establishes tenant ownership, permissions, company settings, document evidence storage, foundational invoice records, baseline reporting periods, async processing scaffolding, and append-oriented audit history.

It deliberately does not yet implement intelligent bookkeeping behavior. Instead, it ensures that when later phases introduce AI, review workflows, matching, compliance checks, and automation, they will be built on infrastructure that already respects evidence integrity, trust-layer separation, tenant safety, and accounting-safe control boundaries.

