# AI Accounting Software Master Blueprint

## 1. Document Purpose

This document is the master human-readable blueprint for the AI-native bookkeeping software being built for a Cyprus-based company. It defines the product vision, user goals, system boundaries, architectural philosophy, compliance direction, operational workflows, AI responsibilities, review flows, dashboard expectations, and phased roadmap.

This document is intentionally written for humans first. It is not a low-level engineering specification. Its purpose is to align product thinking before implementation is split into phase-specific development specifications, state-machine documents, data models, and execution plans.

The software is being designed for the founder’s own company first, but the architecture must be multi-tenant from day one so that future expansion remains possible without structural rewrites.

---

## 2. Product Vision

The product is an AI-native bookkeeping system with its own dashboard, its own accounting workflows, and its own compliance-aware automation layer. The purpose of the software is not merely to store invoices or display financial data, but to act as an operational accounting system that can ingest financial documents and transactions, interpret them, propose accounting treatment, detect mistakes and compliance issues, alert the founder when human intervention is needed, and gradually evolve toward highly autonomous bookkeeping.

The long-term goal is to create an internal AI accountant that operates inside proprietary software. Instead of the founder manually maintaining bookkeeping, the system itself should carry the accounting workload, while the founder only reviews flagged issues, unusual cases, or compliance-sensitive exceptions.

This means the software must combine document management, transaction analysis, accounting logic, tax-rule awareness, anomaly detection, approval controls, and founder-friendly reporting into one cohesive platform.

---

## 3. Core Product Objective

The software must reduce bookkeeping stress to near zero.

In practical terms, this means the system should make it possible for the founder to:

- upload or ingest incoming and outgoing invoices
- upload or ingest bank statements
- connect financial sources such as email and Revolut for automation
- let AI extract, organize, interpret, and match bookkeeping records
- receive warnings when AI detects errors, inconsistencies, missing information, or Cyprus-rule risks
- correct only the items that require human judgment
- view all financial data in a clean dashboard
- export all underlying documents and supporting data when needed
- maintain an accountant-safe and audit-safe bookkeeping environment

The product must aim to become a true accounting operator, not just an accounting assistant.

---

## 4. Product Positioning

This software should be positioned internally as a founder-first, accountant-safe, AI-native bookkeeping platform for a Cyprus-based business.

It is founder-first because the interface must be intuitive, clear, practical, and decision-oriented rather than built like traditional accounting software that assumes an accountant is the daily operator.

It is accountant-safe because beneath the simple interface, the system must preserve proper records, audit history, original documents, structured classifications, and exportable accounting data in a way that supports external accounting review and tax reporting.

It is AI-native because AI is not a side feature. AI is the operational layer that powers ingestion, interpretation, categorization, matching, anomaly detection, and workflow prioritization.

---

## 5. Jurisdiction and Compliance Context

The company is based in Cyprus. The product must therefore be built in a Cyprus-first way, especially in relation to VAT-awareness, record retention, auditability, period control, documentation quality, and accounting reviewability.

This software should not pretend to replace a licensed tax advisor or guarantee perfect legal interpretation in all cases. Instead, it must be built to be Cyprus-ready, compliance-oriented, and structurally strong enough that an accountant or tax professional can validate, review, and rely on its outputs.

The platform should support the following compliance philosophy:

- original accounting evidence must remain preserved
- records must remain readable and retrievable
- key financial actions must be logged
- financial periods must be reviewable and lockable
- tax-relevant classifications must be transparent
- suspicious or incomplete items must be flagged rather than silently accepted
- filing-ready outputs must be supported even if direct filing integrations are not yet live in the first version

This means the product must be designed not only for convenience, but also for evidence, traceability, and review integrity.

---

## 6. Scope of the First System

The first version of the system must support both incoming and outgoing invoices and must also support bank statements. This is critical because the real bookkeeping value does not come from documents alone. It comes from connecting documents to financial transactions and then turning those relationships into a coherent accounting record.

The system must therefore support three core information streams:

### 6.1 Document stream
This includes all uploaded or ingested accounting documents, such as:

- incoming invoices
- outgoing invoices
- credit notes
- debit notes
- bank statements
- supporting documents or attachments

### 6.2 Transaction stream
This includes all actual money movement data, such as:

- bank statement entries
- card transactions
- transfers
- refunds
- fees
- payment settlements

### 6.3 Accounting object stream
This includes the structured accounting entities created or updated by the system, such as:

- contacts
- invoices
- invoice lines
- tax treatments
- ledger records
- payment statuses
- review states
- exceptions
- alerts

The system’s job is to connect these streams in a reliable and reviewable way.

---

## 7. Intended User Experience

The founder should not have to think like an accountant in order to operate the software. The software should translate accounting complexity into clear actions.

The dashboard and workflows should answer practical questions such as:

- what needs review right now
- which invoices are still open
- which bank transactions are unmatched
- where AI is uncertain
- where Cyprus-rule risks may exist
- what VAT-related issues need attention
- which documents are missing mandatory information
- which financial periods are ready to close
- what has already been handled correctly

The founder experience should feel like operating a smart financial command center, not like manually maintaining a bookkeeping spreadsheet.

---

## 8. Founder-First Interface Principles

The product must be designed with founder-first interface principles.

This means:

- the UI should prioritize clarity over accounting jargon
- the system should surface decisions, not raw complexity
- the software should explain why something is flagged
- the software should guide the user toward resolution
- common actions should require minimal friction
- uncertainty should be visible
- important issues should be impossible to miss
- low-risk items should feel calm and effortless

The founder should always understand what the system believes, what the system is uncertain about, and what the founder is expected to do next.

---

## 9. Accountant-Safe Backend Principles

Although the interface is simplified for the founder, the underlying backend must preserve accounting integrity.

This means the backend must support:

- document retention
- original document preservation
- structured accounting records
- audit history
- status transitions
- approval tracking
- period locking
- exportability
- configuration of tax logic
- clear distinction between raw source data, AI interpretation, and approved accounting truth

This allows the software to remain operationally elegant without losing professional rigor.

---

## 10. Multi-Tenant Architecture Principle

Although the first operational use case is only the founder’s own company, the architecture must be multi-tenant from the start.

This means:

- all key records must belong to a company or tenant
- access control must be scoped by tenant
- storage paths must be tenant-aware
- audit events must be tenant-aware
- integrations must be tenant-aware
- settings must be tenant-aware

Even if only one company is active in the short term, the system must be built as if multiple entities may exist later. This prevents major rework and enforces clean data separation.

---

## 11. Core Product Modules

The software should be structured around the following major modules.

### 11.1 Company and Settings Module
This module stores the legal and operational configuration of each company. It should include:

- legal company information
- country and jurisdiction
- VAT registration details
- base currency
- financial year configuration
- invoice numbering formats
- filing period settings
- default tax profile
- integration settings
- notification settings

### 11.2 Contact Management Module
This module stores supplier and customer master data. It should include:

- legal name
- address
- VAT number
- country
- email details
- payment terms
- default categorization patterns
- risk flags
- alias matching rules

This allows repeated counterparties to be recognized consistently across invoices, payments, and AI workflows.

### 11.3 Document Vault Module
This module stores original files and document metadata. It must preserve original accounting evidence. It should support:

- private storage of original files
- file version history
- file hashing
- metadata extraction
- document type identification
- download capability
- archive status
- attachment relationships

The original file must never be silently overwritten.

### 11.4 Invoice Module
This module stores structured invoice records for both incoming and outgoing invoices. It should support:

- incoming invoices
- outgoing invoices
- credit notes
- debit notes
- invoice dates
- due dates
- invoice numbers
- supplier or customer links
- currency and totals
- tax treatment fields
- source document links
- review status
- payment status

### 11.5 Bank Statement and Transaction Module
This module stores uploaded bank statements and normalized transaction entries. It should support:

- statement uploads
- account mapping
- transaction line extraction
- normalization rules
- payment reference parsing
- transaction categorization suggestions
- match candidates
- transaction review states

### 11.6 Matching and Reconciliation Module
This module connects documents and transactions. It should support:

- matching bank transactions to invoices
- identifying likely duplicates
- identifying likely payments
- partial matches
- multi-transaction settlements
- unmatched exceptions
- manual override flows

### 11.7 Tax and Rule Engine Module
This module applies Cyprus-aware logic and validation rules. It should support:

- VAT rate suggestions
- exempt logic
- reverse-charge logic
- domestic vs cross-border classification
- required field validation
- anomaly checks
- compliance warnings
- rule versioning

### 11.8 AI Interpretation and Review Module
This module powers the AI behavior of the software. It should support:

- OCR and text extraction
- structured field extraction
- confidence scoring
- categorization suggestions
- accounting suggestions
- anomaly detection
- explanation generation
- review routing

### 11.9 Audit and History Module
This module stores the operational memory of the system. It should support:

- who uploaded what
- who changed which field
- what AI originally suggested
- what was approved
- when status changed
- when periods were locked
- what exports were generated
- what alerts were resolved

### 11.10 Dashboard and Reporting Module
This module provides founder-facing visibility. It should support:

- financial overview cards
- review queues
- anomalies and alerts
- invoice summaries
- cash movement summaries
- overdue items
- VAT-related summaries
- period close readiness indicators

### 11.11 Export and Accountant Handoff Module
This module enables structured data extraction for external use. It should support:

- document downloads
- period-based zip packages
- invoice exports
- transaction exports
- accountant-ready summaries
- evidence packs
- VAT summary exports

### 11.12 Integration Module
This module supports automated data intake and external connections. It should support:

- email ingestion
- Revolut integration
- future bank integrations
- future accounting portal integrations
- future filing-oriented outputs

---

## 12. Inputs and Ingestion Channels

The software should support multiple intake channels so that bookkeeping does not depend on one manual process.

### 12.1 Manual Upload
Users must be able to upload invoices, statements, and supporting files manually.

### 12.2 Email Ingestion
The system should support a dedicated inbox or forwarding flow so that accounting documents arriving by email can automatically enter the system.

### 12.3 Revolut Integration
The system should support integration with Revolut so that transactions can be imported automatically. This is strategically important because it reduces manual work and creates the basis for ongoing reconciliation.

### 12.4 Future Banking Integrations
Although Revolut is the priority, the architecture should be built in a way that makes additional financial-source integrations possible later.

---

## 13. Trust Model for Financial Data

The system must clearly distinguish between three levels of trust.

### 13.1 Source Truth
This is the original underlying file or imported transaction as received by the system.

### 13.2 Machine Interpretation
This is the AI-extracted, AI-normalized, or AI-suggested understanding of the source truth.

### 13.3 Approved Accounting Truth
This is the reviewed and accepted accounting outcome that the platform treats as operationally authoritative.

This distinction is essential because it prevents AI interpretation from being confused with approved bookkeeping truth.

---

## 14. AI Role in the System

AI is the operational reasoning layer of the platform. It should be responsible for helping the system understand, classify, and prioritize financial information.

The AI layer should support:

- document classification
- OCR-assisted extraction
- invoice field extraction
- bank transaction understanding
- supplier and customer recognition
- category suggestion
- tax treatment suggestion
- matching suggestions
- duplicate detection
- anomaly detection
- completeness checks
- reasoned warnings
- explanation of uncertainty

AI should never be treated as infallible. In the first version, AI should operate with substantial human review. Over time, AI autonomy may increase based on trust and performance.

---

## 15. Automation Philosophy

The system should be built according to a progressive automation philosophy.

### 15.1 Phase A: AI Assist
AI proposes and the founder reviews most meaningful outputs.

### 15.2 Phase B: AI Supervised Automation
AI processes standard, high-confidence cases automatically, while uncertain or risky cases are routed to human review.

### 15.3 Phase C: Exception-Driven Autonomy
AI performs the majority of bookkeeping operations autonomously, and the founder mainly interacts with alerts, anomalies, and exceptions.

This progressive model is safer, more realistic, and more sustainable than attempting total autonomy too early.

---

## 16. Review Philosophy

The first version of the system must assume high review intensity.

This means:

- AI suggestions should be visible before becoming final
- risk-sensitive items should not auto-post without rules
- uncertain tax interpretations should be escalated
- missing mandatory fields should trigger review
- unmatched bank transactions should be clearly visible
- inconsistent data should be flagged for correction

The review process is not a weakness. It is the trust-building bridge that allows the system to later move toward full automation.

---

## 17. Alerts and Exception Philosophy

The system should notify the founder only when there is a meaningful reason.

The alert engine should focus on useful financial issues such as:

- missing mandatory invoice fields
- inconsistent tax treatment
- suspicious VAT calculations
- duplicate invoice risk
- unmatched payment events
- overdue invoices
- bank transactions without accounting destination
- conflicting contact identity data
- AI confidence below threshold
- period close blockers

Each alert should explain:

- what the issue is
- why it matters
- what the likely fix is
- what data the AI used to form that conclusion

The software should not merely say that something is wrong. It should help the founder resolve it.

---

## 18. Legal Immutability Principle

The system must preserve original accounting evidence in a way that prevents silent destruction or silent rewriting of the source record.

This means:

- original uploaded files must remain preserved
- original imported records must remain reconstructable
- corrections must create logged changes rather than invisible overwrites
- changed interpretations must remain historically traceable
- old and new values should be preserved where relevant
- file versions must be explicit if replacement is ever allowed

This principle is essential for trust, auditability, and long-term compliance confidence.

---

## 19. Audit Trail Principle

Every meaningful operational action should be recorded.

This includes:

- uploads
- ingestion events
- parsing runs
- extraction outputs
- field changes
- status transitions
- approvals
- postings
- reconciliations
- locks and unlocks
- export generation
- integration sync events

An audit trail should not only show what changed. It should show who triggered the change, when it happened, and where the change came from.

---

## 20. Period Control Principle

The software must treat accounting periods as controlled operating windows rather than passive date ranges.

This means the system should support:

- open periods
- review periods
- locked periods
- exported periods
- adjusted or amended periods

Period control is necessary because bookkeeping becomes much more reliable once completed periods are frozen unless intentionally reopened under a logged process.

---

## 21. Cyprus-Rule Awareness Concept

The platform must include a Cyprus-aware rule layer. The purpose of this layer is not to replace tax advice, but to identify patterns that look inconsistent, incomplete, or risky according to the company’s jurisdictional needs.

This rule layer should eventually support:

- VAT completeness checks
- rate plausibility checks
- invoice field validation
- reverse-charge awareness
- exempt handling awareness
- domestic vs international pattern checks
- missing VAT-number warnings where relevant
- invoice numbering anomalies
- period allocation anomalies

This layer should be configurable and version-aware so that tax rules and logic can evolve without forcing redesign of the whole platform.

---

## 22. Filing-Ready Direction

The founder wants filing-oriented functionality included in the long-term design. This means that while the first version does not need direct live submission into government systems, the system should be built so that future filing workflows are feasible.

This means the product should support:

- period-based tax summaries
- export-ready VAT data
- filing status fields
- filing package generation
- accountant handoff packs
- traceable links between source evidence and summary outputs

This is the correct middle ground: not direct filing on day one, but structurally ready for filing-related expansion.

---

## 23. Outgoing Invoice Generation

The system should not only process incoming financial evidence. It should also generate outgoing invoices.

This includes:

- creating invoices from within the system
- assigning numbering automatically
- generating downloadable invoice files
- storing the generated invoice as preserved evidence
- tracking sent and paid status
- connecting payments back to invoices
- exposing outstanding receivables in the dashboard

Outgoing invoices are a core part of the accounting lifecycle and should not be treated as a secondary add-on.

---

## 24. Bank Statement and Reconciliation Direction

Because the founder wants the software to handle bookkeeping rather than only store invoices, bank statements are essential.

Bank-related functionality should support:

- statement upload
- parsing of lines and balances
- normalization of merchant and payment references
- matching transactions to invoices
- detecting fees and refunds
- identifying transfers and ambiguous movements
- tracking unmatched items
- supporting manual corrections where necessary

Reconciliation is a major part of the product’s value, because it is where financial evidence becomes financially verified.

---

## 25. Notification Philosophy

Notifications must be meaningful, not noisy.

The system should notify the founder when:

- a new review item appears
- a compliance warning is created
- a bank statement is partially unmatched
- a suspicious duplicate is detected
- an invoice is overdue
- a period is ready for close
- a filing summary has blockers
- an integration sync fails

Notifications should be grouped by urgency and should be presented both in-dashboard and through configurable channels where appropriate.

---

## 26. Security and Data Protection Direction

The software will handle financially sensitive documents and records, so privacy and access control are core system properties.

The system should therefore support:

- private storage buckets
- signed file access
- strong authentication
- role-based access control
- tenant-scoped row-level security
- server-side integration credentials
- append-oriented audit trails
- soft-delete patterns where necessary
- backup and recovery planning

The product should not rely on convenience shortcuts that weaken evidence integrity or expose sensitive financial data.

---

## 27. Role Model

Even though the first operational user is the founder, the system should be designed with a role model that allows future collaboration.

Roles may eventually include:

- founder or primary operator
- accountant or reviewer
- admin
- finance assistant
- system automation role

Permissions should be separable across actions such as:

- upload
- review
- approve
- export
- lock period
- manage settings
- manage integrations

---

## 28. Data Model Direction

The software should be designed around structured entities, not loose files. The most important domain entities are likely to include:

- companies
- users
- roles
- contacts
- documents
- document versions
- invoices
- invoice lines
- bank accounts
- statements
- transactions
- matches
- tax codes
- alerts
- audit events
- review decisions
- reporting periods
- exports
- integrations

The data model must distinguish clearly between source records, interpreted records, and approved accounting outcomes.

---

## 29. Dashboard Direction

The dashboard should function as a financial control center.

It should eventually show:

- total revenue
- total expenses
- cash movement snapshots
- unpaid outgoing invoices
- unpaid incoming invoices
- unmatched bank transactions
- review queue count
- high-priority alerts
- VAT-related summaries
- month and quarter trends
- recent AI decisions
- recent resolved issues

The dashboard should support confidence and calm. The founder should immediately understand the system’s current accounting health.

---

## 30. Exports and Evidence Packs

The founder wants to be able to download all invoices, and the broader design requires strong exportability.

The system should therefore support:

- single-document download
- filtered document exports
- monthly or quarterly zip evidence packs
- invoice data exports
- bank transaction exports
- summary exports
- accountant handoff exports
- filing-preparation exports

These exports should be practical, organized, and easy to audit.

---

## 31. Product Boundaries

To keep the first system realistic, some areas should not be treated as immediate first-version priorities.

Examples of likely later-phase areas include:

- direct government filing submission
- full payroll handling
- fixed asset depreciation systems
- advanced multi-country tax engines
- enterprise consolidation
- highly advanced forecasting layers

These may become relevant later, but the first system should remain focused on bookkeeping operations, financial evidence, matching, review, alerts, and reporting.

---

## 32. Phased Roadmap Direction

The system should be built in structured phases.

### Phase 1: Foundation
Establish tenant structure, settings, contacts, storage, documents, invoices, users, roles, and audit infrastructure.

### Phase 2: Invoice Engine
Implement incoming and outgoing invoice flows, document parsing, invoice extraction, review interface, and invoice statuses.

### Phase 3: Bank Statement and Reconciliation Engine
Implement statement ingestion, transaction normalization, matching logic, and reconciliation workflows.

### Phase 4: AI Review and Alerting Layer
Implement confidence-based AI behavior, anomaly detection, explanation-driven alerts, and review prioritization.

### Phase 5: Dashboard and Reporting Layer
Implement founder-facing financial command center views, trends, summaries, and operational status panels.

### Phase 6: Integrations and Filing-Ready Expansion
Implement email ingestion, Revolut automation, export packs, and filing-oriented readiness features.

This phased direction keeps the system buildable while preserving the full long-term vision.

---

## 33. Relationship Between This Document and Future Specs

This document is the top-level master blueprint. It explains what the system is, why it exists, and how it should behave.

It must later be followed by more detailed documents, including:

- a domain model document
- a system architecture document
- a compliance and audit document
- an AI automation model document
- a state-machine document
- phase-based development specifications

Those later documents should remain aligned to this blueprint.

---

## 34. Final Product Intent

The final intent of this software is to create a founder-trusted, AI-operated bookkeeping environment that substantially removes manual bookkeeping stress while preserving financial integrity, accounting traceability, and Cyprus-aware operational safety.

The software should feel like an internal AI accountant with its own workspace, not a generic bookkeeping app.

The founder should eventually reach a point where the system continuously processes the company’s bookkeeping, flags only meaningful problems, keeps clean records, prepares accountant-safe outputs, and allows the founder to stay fully in control without having to manually manage every accounting detail.

---

## 35. Working Conclusion

This product should be built as a multi-tenant, founder-first, accountant-safe, AI-native bookkeeping platform for a Cyprus-based company, starting with incoming invoices, outgoing invoices, bank statements, review workflows, and alert-driven control, and expanding toward increasingly autonomous bookkeeping with filing-ready outputs.

This document now serves as the master reference for the next documentation layer.

