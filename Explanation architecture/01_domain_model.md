# Domain Model

## 1. Document Purpose

This document defines the core domain model of the AI-native bookkeeping software. It translates the master blueprint into the logical system entities, relationships, responsibilities, and behavioral rules that govern how the product operates.

The purpose of this document is to create a shared understanding of the business objects inside the system before detailed engineering implementation begins. It is not yet a table-by-table database schema, but it is more precise than the master blueprint. It defines what the system knows, what it stores, how objects relate to one another, and where the boundaries between source truth, AI interpretation, and approved accounting truth must be maintained.

This document should be used as the bridge between the master blueprint and the later technical development specifications.

---

## 2. Domain Philosophy

The system is not built around files alone. It is built around financial evidence, financial interpretation, and financial decisions.

This means the domain model must preserve three layers at all times:

- source records
- interpreted records
- approved accounting records

A PDF invoice is not the same thing as an invoice entity. A bank statement file is not the same thing as a transaction record. AI-extracted fields are not the same thing as approved bookkeeping truth.

The domain model must therefore treat accounting evidence as a structured chain rather than a flat upload system.

---

## 3. Core Domain Layers

The software domain is organized into six main layers.

### 3.1 Tenant and access layer
This layer defines who owns data, who can access it, and under which company or tenant scope the data exists.

### 3.2 Evidence layer
This layer stores raw financial evidence, such as uploaded documents and imported source transactions.

### 3.3 Interpretation layer
This layer stores machine-generated and system-generated interpretations of source evidence.

### 3.4 Accounting layer
This layer stores structured financial objects that the system treats as operational truth after review and approval.

### 3.5 Control layer
This layer stores review states, alerts, approvals, audit history, and period controls.

### 3.6 Integration layer
This layer stores external connections, ingestion jobs, sync metadata, and external-source references.

---

## 4. Primary Domain Entities

The domain model is centered around the following primary entities:

- Company
- User
- Role
- Contact
- Document
- DocumentVersion
- Invoice
- InvoiceLine
- BankAccount
- Statement
- Transaction
- Match
- TaxProfile
- TaxCode
- ReviewItem
- Alert
- ApprovalDecision
- AuditEvent
- ReportingPeriod
- ExportJob
- IntegrationConnection
- ParsingRun
- ExtractionResult
- LedgerEntry
- LedgerEntryLine

Each of these entities represents a distinct responsibility inside the system.

---

## 5. Company

### Purpose
The Company entity represents the legal and operational accounting owner within the platform.

### Responsibilities
The Company defines the tenant scope for almost all important records. It contains the legal, tax, currency, and workflow settings that shape how bookkeeping is interpreted.

### Key concepts
A Company should include concepts such as:

- legal entity identity
- jurisdiction
- VAT registration context
- base currency
- accounting period configuration
- invoice numbering configuration
- filing settings
- automation thresholds
- integration ownership

### Relationships
A Company has many:

- Users
- Contacts
- Documents
- Invoices
- Statements
- Transactions
- Alerts
- ReportingPeriods
- ExportJobs
- IntegrationConnections

Every major operational record should belong to exactly one Company.

---

## 6. User

### Purpose
The User entity represents a human operator or reviewer inside the platform.

### Responsibilities
A User may upload evidence, review items, approve decisions, manage settings, or consume reports, depending on permissions.

### Relationships
A User belongs to one or more Companies through role assignments.
A User may create or interact with:

- Documents
- ReviewItems
- ApprovalDecisions
- AuditEvents
- Exports
- Alerts

### Important note
User identity must remain distinct from automation identity. Human actions and system actions must never be confused in audit history.

---

## 7. Role

### Purpose
The Role entity defines what a user is allowed to do within a company scope.

### Examples
Potential roles include:

- founder
- admin
- accountant
- reviewer
- finance assistant

### Responsibilities
A Role governs access to actions such as:

- upload
- review
- approve
- edit
- export
- lock period
- manage settings
- manage integrations

### Relationships
Roles are assigned to Users within a Company context.

---

## 8. Contact

### Purpose
The Contact entity represents a supplier, customer, or other financial counterparty.

### Responsibilities
A Contact provides the identity layer for invoices, transactions, and AI recognition logic.

### Key concepts
A Contact should support:

- legal name
- aliases
- address
- VAT number
- country
- email addresses
- payment terms
- bank identifiers where relevant
- default classification hints
- risk notes

### Relationships
A Contact may be linked to:

- many Invoices
- many Transactions
- many Matches
- many Alerts

A Contact belongs to one Company.

---

## 9. Document

### Purpose
The Document entity represents a stored piece of financial evidence.

### Examples
Documents include:

- invoice PDFs
- invoice scans
- credit note files
- bank statement files
- attachments
- exported generated invoice files

### Responsibilities
A Document stores the logical identity of a financial file while preserving its source role in the system.

### Key concepts
A Document should include concepts such as:

- document type
- source channel
- storage reference
- upload timestamp
- current version pointer
- file hash
- visibility status
- archive state
- linked company

### Relationships
A Document:

- belongs to one Company
- has many DocumentVersions
- may be linked to one or more Invoices
- may be linked to one Statement
- may be linked to ParsingRuns
- may trigger ReviewItems or Alerts

### Important note
The Document entity is not the same as the structured accounting object derived from it.

---

## 10. DocumentVersion

### Purpose
The DocumentVersion entity preserves file-level immutability and historical traceability.

### Responsibilities
If a file is replaced, re-uploaded, re-generated, corrected, or archived, the system must preserve version history without destroying source evidence.

### Key concepts
A DocumentVersion should include:

- version number
- storage path
- hash
- file size
- MIME type
- created timestamp
- created by actor
- replacement reason where applicable

### Relationships
A DocumentVersion belongs to one Document.

### Important note
Silent overwrite must never exist. A version must always remain reconstructable.

---

## 11. Invoice

### Purpose
The Invoice entity represents a structured financial obligation or receivable recognized by the system.

### Types
The Invoice entity must support:

- incoming invoice
- outgoing invoice
- credit note
- debit note

### Responsibilities
An Invoice is the structured accounting representation of a billable or payable record. It is not merely a document file.

### Key concepts
An Invoice should support:

- direction
- type
- invoice number
- invoice date
- supply date
- due date
- currency
- subtotal
- tax amount
- total amount
- payment status
- review status
- approval status
- tax treatment summary
- company link
- counterparty link
- source document link

### Relationships
An Invoice:

- belongs to one Company
- may reference one primary Contact
- may reference one or more Documents
- has many InvoiceLines
- may link to many Transactions through Matches
- may generate many Alerts
- may produce LedgerEntries
- belongs to one ReportingPeriod once posted

### Important note
The Invoice is one of the main bridge entities between documents, tax logic, matching logic, and reporting.

---

## 12. InvoiceLine

### Purpose
The InvoiceLine entity represents a detailed line item within an invoice.

### Responsibilities
Invoice lines allow more granular tax logic, categorization, and accounting treatment than invoice-level totals alone.

### Key concepts
An InvoiceLine should support:

- description
- quantity
- unit price
- net amount
- tax amount
- gross amount
- category suggestion
- tax code
- accounting destination hint

### Relationships
An InvoiceLine belongs to one Invoice.
An Invoice may have many InvoiceLines.

---

## 13. BankAccount

### Purpose
The BankAccount entity represents a financial account owned or operated by the company.

### Responsibilities
It anchors statements, imported transactions, balances, and integration references.

### Key concepts
A BankAccount should support:

- institution name
- account label
- masked account identifier
- currency
- country
- integration connection
- active status

### Relationships
A BankAccount belongs to one Company.
A BankAccount has many Statements and many Transactions.

---

## 14. Statement

### Purpose
The Statement entity represents a bank statement ingestion event or logical bank statement record.

### Responsibilities
A Statement acts as the parent object for imported or parsed transaction lines.

### Key concepts
A Statement should support:

- source type
- statement period start and end
- opening balance
- closing balance
- import method
- source document link where relevant
- processing status

### Relationships
A Statement:

- belongs to one Company
- belongs to one BankAccount
- may reference one Document
- has many Transactions
- may generate ReviewItems or Alerts

---

## 15. Transaction

### Purpose
The Transaction entity represents a normalized financial movement entry.

### Responsibilities
A Transaction is the structured representation of money movement that may later be matched, categorized, reconciled, and posted.

### Key concepts
A Transaction should support:

- booking date
- value date
- amount
- currency
- direction
- description
- normalized description
- reference
- counterparty hint
- bank account link
- statement link
- match status
- reconciliation status
- category suggestion
- tax relevance flag

### Relationships
A Transaction:

- belongs to one Company
- belongs to one BankAccount
- may belong to one Statement
- may be linked to one or more Invoices through Matches
- may generate LedgerEntries
- may generate Alerts

### Important note
A raw bank statement line and a normalized Transaction must remain logically linked, but the normalized Transaction is the usable accounting object.

---

## 16. Match

### Purpose
The Match entity represents a relationship between one or more transactions and one or more invoices or other accounting objects.

### Responsibilities
A Match allows the system to express settlement, probable association, partial payment, or reconciliation relationships.

### Types of match situations
The model must support:

- one transaction to one invoice
- one transaction to multiple invoices
- multiple transactions to one invoice
- partial payment
- grouped settlement
- uncertain candidate match

### Key concepts
A Match should support:

- confidence level
- match type
- amount linked
- source of match decision
- approval status
- exception notes

### Relationships
A Match belongs to one Company and connects Transactions and Invoices.

---

## 17. TaxProfile

### Purpose
The TaxProfile entity represents company-level tax configuration context.

### Responsibilities
It determines which rules and tax behaviors are relevant for the company.

### Key concepts
A TaxProfile should support:

- jurisdiction
- VAT registration context
- default rule set
- filing frequency
- active tax logic version

### Relationships
A TaxProfile belongs to one Company and governs Invoice, InvoiceLine, Transaction, and ReportingPeriod interpretation.

---

## 18. TaxCode

### Purpose
The TaxCode entity represents a specific tax treatment option used by the system.

### Responsibilities
It is the practical classification used for invoice lines, invoice summaries, or postings.

### Key concepts
A TaxCode should support:

- label
- description
- rate
- jurisdictional meaning
- exempt or reverse-charge indicators
- reporting behavior
- active status

### Relationships
A TaxCode belongs to a Company or a platform-level rule set and may be applied to InvoiceLines, Invoices, Transactions, and LedgerEntryLines.

---

## 19. ParsingRun

### Purpose
The ParsingRun entity represents an attempt by the system or AI layer to process a document or source record.

### Responsibilities
It allows the platform to preserve how extraction happened, with what confidence, and under which model or parser version.

### Key concepts
A ParsingRun should support:

- input source
- parser type
- parser version
- start and completion time
- outcome status
- confidence summary
- error summary

### Relationships
A ParsingRun belongs to one Company and is linked to one Document or other source object.
A ParsingRun may produce one or more ExtractionResults.

---

## 20. ExtractionResult

### Purpose
The ExtractionResult entity stores structured interpreted output from parsing or AI reasoning.

### Responsibilities
It preserves the machine interpretation layer without confusing it with approved accounting truth.

### Key concepts
An ExtractionResult should support:

- extracted fields
- confidence by field
- inferred document type
- candidate contact
- candidate invoice totals
- candidate dates
- suggested tax treatment
- explanation summary

### Relationships
An ExtractionResult belongs to one ParsingRun and may be linked to one Document, Invoice, Statement, or Transaction creation flow.

### Important note
ExtractionResult data must remain separable from approved final accounting values.

---

## 21. ReviewItem

### Purpose
The ReviewItem entity represents a discrete piece of work that requires human attention.

### Responsibilities
The system should not rely on passive warnings alone. It should convert meaningful uncertainty and exceptions into active review work.

### Examples
Review items may be created for:

- low-confidence extraction
- tax ambiguity
- unmatched payment
- duplicate risk
- missing mandatory field
- conflicting identity data
- exception during reconciliation

### Key concepts
A ReviewItem should support:

- reason
- severity
- linked source object
- status
- assigned user
- due context
- resolution note

### Relationships
A ReviewItem belongs to one Company and may reference:

- Document
- Invoice
- Transaction
- Match
- Statement
- Alert

---

## 22. Alert

### Purpose
The Alert entity represents a surfaced system warning, notification, or compliance signal.

### Responsibilities
Alerts make the system’s concerns visible to the founder or reviewer.

### Key concepts
An Alert should support:

- category
- severity
- title
- explanation
- linked object
- status
- created time
- acknowledged time
- resolved time

### Relationships
An Alert belongs to one Company and may reference many operational entities.

### Important note
Not every Alert must become a ReviewItem, but many review-worthy alerts should produce one.

---

## 23. ApprovalDecision

### Purpose
The ApprovalDecision entity records a formal human acceptance or rejection of an AI suggestion, accounting classification, or operational action.

### Responsibilities
It provides traceable transition from machine interpretation to approved accounting truth.

### Key concepts
An ApprovalDecision should support:

- decision type
- object under decision
- actor
- timestamp
- accepted or rejected state
- reason note
- previous value snapshot
- approved value snapshot

### Relationships
An ApprovalDecision belongs to one Company and may reference Invoices, Transactions, Matches, or ReviewItems.

---

## 24. LedgerEntry

### Purpose
The LedgerEntry entity represents an accounting entry recognized by the system after approval or automated posting.

### Responsibilities
It converts business events into accounting records.

### Key concepts
A LedgerEntry should support:

- posting date
- source event type
- source object link
- reporting period
- posting status
- explanation or memo

### Relationships
A LedgerEntry belongs to one Company and has many LedgerEntryLines.
A LedgerEntry may be linked to an Invoice, Transaction, Match, or adjustment workflow.

### Important note
In the first version, ledger depth may be simpler than full enterprise accounting, but the model should leave room for proper structured posting.

---

## 25. LedgerEntryLine

### Purpose
The LedgerEntryLine entity represents a line within an accounting entry.

### Responsibilities
It captures the destination, amount, and tax behavior of individual posting lines.

### Key concepts
A LedgerEntryLine should support:

- amount
- currency
- account destination
- tax code
- memo
- direction

### Relationships
A LedgerEntryLine belongs to one LedgerEntry.

---

## 26. ReportingPeriod

### Purpose
The ReportingPeriod entity represents a controlled accounting window.

### Responsibilities
It provides the structure for reporting, closing, locking, export readiness, and future filing preparation.

### Key concepts
A ReportingPeriod should support:

- start date
- end date
- period type
- status
- lock state
- export state
- filing state
- notes

### Relationships
A ReportingPeriod belongs to one Company and may contain many Invoices, Transactions, LedgerEntries, Alerts, and Exports.

---

## 27. ExportJob

### Purpose
The ExportJob entity represents a generated output package or data extraction event.

### Responsibilities
It gives traceability to accountant handoff, evidence packs, summary exports, and filing-ready outputs.

### Key concepts
An ExportJob should support:

- export type
- filters
- generation time
- generated by actor
- file location
- included period context
- status

### Relationships
An ExportJob belongs to one Company and may reference many Documents, Invoices, Transactions, and ReportingPeriods.

---

## 28. IntegrationConnection

### Purpose
The IntegrationConnection entity represents an active or configured external system connection.

### Examples
Examples include:

- email ingestion connection
- Revolut connection
- future bank connection
- future filing-related connection

### Responsibilities
It stores ownership, authentication state, sync state, and operational metadata for automated intake.

### Key concepts
An IntegrationConnection should support:

- provider name
- connection status
- linked company
- sync mode
- last sync time
- credential reference
- failure state

### Relationships
An IntegrationConnection belongs to one Company and may be linked to BankAccounts, Statements, Transactions, Documents, or ImportJobs.

---

## 29. AuditEvent

### Purpose
The AuditEvent entity records meaningful actions and state transitions across the system.

### Responsibilities
It is the durable operational history layer.

### Key concepts
An AuditEvent should support:

- actor type
- actor identity
- action type
- source object type
- source object identity
- timestamp
- before snapshot
- after snapshot
- context metadata

### Relationships
An AuditEvent belongs to one Company and may reference any major domain entity.

---

## 30. Entity Relationship Principles

The following relationship principles must hold across the model:

- every important operational record belongs to exactly one Company
- every source file belongs to the evidence layer before becoming an accounting object
- every AI output belongs to the interpretation layer before becoming approved truth
- every approved accounting action must remain traceable to its source and review path
- every alert or review state must be linked to a concrete object or event
- every period-sensitive accounting object must become assignable to a ReportingPeriod

These principles are more important than any specific storage implementation.

---

## 31. Source Truth vs Approved Truth

A central model rule is that the system must not collapse source truth into approved truth.

Examples:

- a document file is not the same as an invoice record
- an extracted total is not the same as an approved total
- a match suggestion is not the same as a reconciled payment
- a parser classification is not the same as a final tax treatment

The system may connect these states, but must never hide the distinction between them.

---

## 32. Lifecycle Ownership Principles

Different domain objects own different parts of the lifecycle.

- Documents own evidence preservation
- ParsingRuns own machine processing attempts
- ExtractionResults own machine interpretation
- ReviewItems own human intervention tasks
- ApprovalDecisions own human acceptance history
- Invoices own financial obligation structure
- Transactions own money movement structure
- Matches own settlement relationships
- LedgerEntries own accounting posting outcomes
- ReportingPeriods own temporal control

This separation reduces ambiguity and helps future state-machine design.

---

## 33. Domain Events Concept

Although this document does not define a full event architecture, the domain clearly depends on meaningful events.

Examples include:

- document uploaded
- parsing completed
- extraction failed
- invoice created
- invoice approved
- transaction imported
- transaction matched
- alert generated
- review resolved
- period locked
- export completed

These events will later be important for automation, audit logging, notifications, and asynchronous workflows.

---

## 34. Domain Constraints

The domain model should respect the following constraints:

- no silent overwrite of accounting evidence
- no tenant-unsafe data mixing
- no approval without traceability
- no AI suggestion treated as final truth without explicit rule or approval path
- no period locking without audit visibility
- no deletion behavior that destroys accounting reconstruction capability

These are structural guardrails for the domain.

---

## 35. Domain Model Summary

The domain model defines the bookkeeping platform as a system of connected evidence, interpretation, accounting, control, and integration entities rather than a simple upload application.

At its core, the model must preserve:

- tenant isolation
- evidence integrity
- machine interpretation traceability
- human approval traceability
- accounting object clarity
- review and alert structure
- period control
- exportability

This document now serves as the logical reference point for the next documentation layers, especially the system architecture document, the compliance and audit document, the AI automation model, and the phase-based development specifications.

