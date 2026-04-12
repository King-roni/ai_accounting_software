# System Architecture

## 1. Document Purpose

This document defines the high-level system architecture for the AI-native bookkeeping platform. It translates the master blueprint and domain model into an implementation-oriented structure that explains how the platform should be organized across frontend, backend, storage, processing, AI orchestration, integrations, security, and operational boundaries.

This is still a human-readable architecture document rather than a low-level engineering build sheet. Its job is to define how the major technical pieces fit together so that later phase-specific development specifications can be created with consistency.

The architecture must support the following product realities:

- founder-first interface design
- accountant-safe backend structure
- multi-tenant isolation
- Cyprus-aware bookkeeping workflows
- AI-assisted and later AI-driven accounting operations
- ingestion of invoices, outgoing invoices, bank statements, email flows, and Revolut data
- auditability, traceability, and filing-ready expansion

---

## 2. Architectural Philosophy

The system should be designed as a modular, event-aware, AI-native financial operations platform.

It must not be built as a simple CRUD dashboard attached directly to a file bucket. It must be built as a layered operational system in which:

- source evidence enters through controlled ingestion channels
- files and transaction feeds are preserved as source truth
- AI and parsing pipelines produce structured interpretations
- review and approval flows convert interpretations into accounting truth
- reporting and dashboard layers consume approved or review-aware data
- audit trails and period controls preserve long-term integrity

The architecture should always preserve the distinction between evidence, interpretation, and approved truth.

---

## 3. Architectural Goals

The architecture must satisfy the following goals:

### 3.1 Product usability goal
The founder should interact with a clear and responsive application, not a fragmented toolchain.

### 3.2 Accounting integrity goal
The backend must preserve the accounting evidence chain, human decisions, and posting traceability.

### 3.3 Automation goal
The system must support increasing levels of automation over time without needing to be rebuilt.

### 3.4 Multi-tenant goal
All major subsystems must be scoped so that data, files, settings, and workflows remain tenant-safe.

### 3.5 Security goal
Financial documents and records must be protected with private storage, strong access control, and careful operational separation.

### 3.6 Compliance goal
The system must support auditability, period control, exportability, and jurisdiction-aware validation.

### 3.7 Scalability goal
The architecture should be designed so that adding new integrations, rule engines, and workflow logic does not require a structural rewrite.

---

## 4. High-Level Architecture Overview

At a high level, the system should be divided into the following technical layers:

1. client application layer
2. application backend layer
3. database and storage layer
4. processing and job orchestration layer
5. AI and rules engine layer
6. integration layer
7. audit and observability layer
8. export and reporting layer

These layers should work together through explicit service boundaries and event-driven workflow transitions rather than tightly coupled direct mutations everywhere.

---

## 5. Client Application Layer

### Purpose
The client application layer is the founder-facing and reviewer-facing application interface.

### Suggested implementation direction
A modern web application framework is the correct choice here, with a strong preference for a Next.js-based frontend because it aligns well with app-style dashboards, authenticated flows, secure server-side actions, and future extensibility.

### Responsibilities
The client layer should handle:

- authentication entry points
- dashboard rendering
- document upload interfaces
- invoice review interfaces
- bank transaction review interfaces
- alerts and review queues
- settings management
- export initiation
- integration management views
- reporting views

### Architectural principle
The frontend should not contain core accounting logic or trust-sensitive rule logic. It should display data, collect actions, and invoke backend capabilities.

### UX principle
The frontend must be optimized for clarity, prioritization, and confidence. It should surface what matters, not expose raw backend complexity.

---

## 6. Application Backend Layer

### Purpose
The backend layer is the orchestration and trust layer of the system.

### Responsibilities
The backend should own:

- authenticated business logic
- authorization enforcement
- mutation handling
- workflow transitions
- validation orchestration
- integration callbacks
- AI pipeline invocation
- export job creation
- audit event generation
- period control logic

### Suggested implementation direction
Given the intended stack direction, the backend can be implemented through a combination of:

- Next.js server actions or route handlers for app-facing operations
- Supabase-backed APIs and database functions where appropriate
- Edge or server-side functions for integration workflows and async operations

### Architectural principle
The backend should be the only layer allowed to convert user intent into trusted system mutations.

The frontend must never directly author critical accounting state changes without backend enforcement.

---

## 7. Database Layer

### Purpose
The database layer stores the structured source, interpretation, accounting, and control objects defined in the domain model.

### Suggested implementation direction
Postgres, via Supabase, is a strong fit because the product requires:

- relational integrity
- tenant-aware isolation
- transactional consistency
- flexible querying
- audit-friendly modeling
- structured status-driven workflows

### Responsibilities
The database should store:

- company and settings records
- user and role records
- contact records
- document metadata
- invoice structures
- statement records
- transaction records
- matching records
- tax configuration
- review objects
- alerts
- approval records
- reporting periods
- exports
- integration metadata
- audit events

### Architectural principle
The database should store durable truth and status. It should not become a dumping ground for uncontrolled JSON blobs that hide important accounting structure.

JSON can be used where flexible machine outputs are useful, but the core accounting model must remain queryable and explicit.

---

## 8. Storage Layer

### Purpose
The storage layer preserves original accounting evidence and generated artifacts.

### Suggested implementation direction
Supabase Storage is a practical fit, provided it is used with strong private-bucket patterns and signed access controls.

### Storage categories
The storage layer should support separate logical areas for:

- uploaded source documents
- generated outgoing invoices
- bank statement files
- export packages
- temporary processing artifacts where allowed

### Responsibilities
The storage layer must support:

- private object storage
- tenant-aware path organization
- file version preservation
- metadata linking to database records
- secure download flows
- retention-aware storage practices

### Architectural principle
Storage should never be treated as the source of business truth by itself. Every meaningful file must be represented and governed through database records.

---

## 9. Processing and Job Orchestration Layer

### Purpose
The processing layer handles asynchronous work that should not block the main user interaction flow.

### Examples of processing work
This layer should handle jobs such as:

- OCR processing
- document parsing
- extraction normalization
- email ingestion processing
- statement parsing
- transaction normalization
- duplicate detection
- matching suggestions
- alert generation
- export creation
- integration sync tasks

### Why this layer matters
Bookkeeping automation includes many operations that are computationally heavier, potentially slow, or integration-dependent. These should not be executed inline inside normal UI requests wherever it can be avoided.

### Suggested implementation direction
This layer can begin with server-side async workflows and progress toward more formal job queues and workers as the system matures.

Possible implementation directions include:

- database-backed job tables
- edge functions or server functions triggered by events
- scheduled jobs for sync and maintenance
- queue workers for heavier AI and parsing workloads

### Architectural principle
All long-running or failure-prone operations should move through explicit job states, not opaque background behavior.

---

## 10. AI and Rules Engine Layer

### Purpose
This layer gives the system its accounting intelligence.

### Responsibilities
It should handle:

- OCR-assisted extraction
- document classification
- invoice field extraction
- statement line interpretation
- counterparty recognition
- categorization suggestions
- tax treatment suggestions
- match candidate generation
- anomaly detection
- explanation generation
- confidence scoring
- rule validation

### Internal architecture principle
The AI and rules layer should be split conceptually into two subsystems:

#### 10.1 Machine interpretation subsystem
This subsystem is responsible for extracting, inferring, and suggesting.

#### 10.2 Deterministic validation subsystem
This subsystem is responsible for rule checks, required fields, period checks, tax plausibility checks, and control rules.

### Why the split matters
AI should suggest. Rules should enforce or flag.

This prevents the system from behaving like a black box and makes it far easier to explain alerts and maintain trust.

### Architectural principle
The AI layer must never silently overwrite approved accounting truth. It should operate through proposals, confidence levels, and review-aware pathways.

---

## 11. Integration Layer

### Purpose
The integration layer connects the platform to external systems that provide financial inputs or future filing-oriented outputs.

### Initial integrations in scope direction
The architecture must explicitly support:

- email ingestion
- Revolut integration

### Future expansion direction
The architecture should later support:

- additional bank connections
- accountant workflow integrations
- future tax or filing export integrations
- structured e-invoice or partner integrations where needed

### Responsibilities
The integration layer should handle:

- credential configuration
- connection state
- sync scheduling
- webhook handling where relevant
- polling flows where relevant
- source normalization
- failure handling
- replay or retry support

### Architectural principle
Each integration should be represented as a first-class system capability, not as hidden special logic embedded directly into the main app.

---

## 12. Audit and Observability Layer

### Purpose
The audit and observability layer ensures that the system remains traceable, supportable, and safe to operate.

### Responsibilities
This layer should support:

- operational audit events
- system workflow visibility
- integration sync history
- job status monitoring
- error capture
- review history
- period lock history
- export history
- parsing and extraction history

### Architectural principle
The system should be able to answer questions such as:

- what happened
- when it happened
- who triggered it
- what data changed
- which source produced the data
- whether AI or a human made the decision
- why an alert was created

That visibility is essential for trust and debugging.

---

## 13. Export and Reporting Layer

### Purpose
This layer is responsible for producing founder-facing and accountant-facing outputs.

### Responsibilities
It should support:

- dashboard query views
- period summaries
- invoice exports
- transaction exports
- evidence pack creation
- VAT-oriented summaries
- accountant handoff outputs
- filing-ready output preparation

### Architectural principle
Reporting should consume review-aware and accounting-aware structured data, not raw source files alone.

---

## 14. Multi-Tenant Architecture Model

### Core principle
The system must be multi-tenant at the data, storage, permission, and workflow levels.

### This means
- each company is logically isolated
- every important data record carries tenant ownership
- every storage path is tenant-aware
- every integration is scoped to a company
- every export is scoped to a company
- every role assignment is scoped to a company
- backend authorization always validates tenant ownership before mutation or access

### Security implication
Tenant isolation should not be treated only as a frontend concept. It must be enforced in database policies, backend authorization, storage access, and job processing.

---

## 15. Suggested Stack Direction

The stack should remain pragmatic, modern, and controllable.

### Suggested architecture stack
- frontend: Next.js application
- authentication: Supabase Auth
- relational database: Supabase Postgres
- file storage: Supabase Storage
- backend logic: Next.js server-side actions and route handlers, plus server functions where needed
- asynchronous processing: server-side jobs, functions, and later worker-based execution where useful
- AI processing: external model calls or document-processing services invoked through controlled backend pipelines
- notifications: in-app first, with optional email or messaging expansion later

### Why this stack fits
This stack supports fast iteration, private data handling, structured relational modeling, dashboard-style UX, and extensible backend workflows without requiring premature infrastructure complexity.

---

## 16. Separation of Concerns

The architecture must keep the following responsibilities separate:

### 16.1 UI state vs accounting truth
The frontend may hold temporary UI state, but not authoritative accounting truth.

### 16.2 files vs records
A storage object is not the same as a document record.

### 16.3 source data vs AI suggestions
Imported data and AI interpretations must remain distinct.

### 16.4 AI reasoning vs deterministic control
AI may infer. Rules may validate. Workflow logic decides the allowed next step.

### 16.5 reviewable states vs final states
A suggestion, alert, or draft classification must not be treated the same as a posted accounting outcome.

This separation is one of the most important architectural integrity principles in the whole product.

---

## 17. Request Flow Model

A normal user-initiated application flow should follow this pattern:

1. user action begins in the frontend
2. authenticated request reaches backend
3. backend validates tenant and permission scope
4. backend writes or updates source records
5. backend triggers any required job or follow-up workflow
6. backend records audit event
7. frontend receives current status and reflects system state

This pattern should apply consistently across uploads, reviews, approvals, exports, and integration actions.

---

## 18. Ingestion Architecture

### 18.1 Manual upload ingestion
Manual file upload should follow a controlled ingestion flow:

- file is uploaded through authenticated client
- backend creates or validates document record
- file is stored in private tenant-aware path
- document metadata is persisted
- parsing job is queued
- audit event is created
- review or alert outcomes are created after processing

### 18.2 Email ingestion
Email ingestion should follow a pipeline such as:

- message received through dedicated ingestion channel
- attachments extracted
- source message metadata recorded
- document records created
- parsing jobs queued
- duplicates and contact recognition applied

### 18.3 Revolut ingestion
Revolut ingestion should follow a structured sync model:

- secure connection established and stored
- sync job retrieves transaction source data
- raw source references preserved
- transactions normalized into internal transaction records
- matching and review logic triggered
- sync status recorded

---

## 19. Processing Pipeline Architecture

A general processing pipeline should follow these conceptual stages:

### Stage 1: source capture
The system receives a file or financial source event.

### Stage 2: source preservation
The original evidence is stored and linked.

### Stage 3: machine processing
OCR, parsing, and extraction are run.

### Stage 4: normalization
The machine output is transformed into structured internal candidates.

### Stage 5: validation
Deterministic rule checks are applied.

### Stage 6: review routing
If uncertainty or risk exists, review items and alerts are created.

### Stage 7: approval or auto-processing
The system waits for human approval or proceeds under trusted rules.

### Stage 8: accounting outcome generation
Approved outcomes update invoices, transactions, matches, and ledger-oriented objects.

### Stage 9: reporting availability
The structured result becomes available to dashboards, reports, exports, and period summaries.

This pipeline model should be reused across multiple financial object types.

---

## 20. Workflow State Management Direction

Although state machines will be documented separately later, the architecture must already assume explicit stateful workflows.

This means entities such as:

- documents
- parsing jobs
- invoices
- transactions
- matches
- alerts
- review items
- reporting periods
- export jobs
- integrations

must each move through controlled states rather than ad hoc field toggles.

The architecture should therefore support state transitions that are validated, logged, and recoverable.

---

## 21. Security Architecture Direction

### Purpose
The product handles highly sensitive financial data and must therefore use a security-first architecture.

### Core security principles
The architecture should support:

- private storage buckets only for sensitive documents
- signed access URLs for controlled download
- row-level security for tenant-scoped data access
- backend-only privileged operations
- secure credential storage for integrations
- strict separation between user session permissions and system service permissions
- append-oriented audit event capture
- careful handling of admin and lock-related operations

### Important principle
The client must never receive unnecessary secrets, permanent file access, or privileged integration credentials.

---

## 22. Authorization Model Direction

Authorization should happen at multiple layers:

### Frontend layer
The UI may hide actions a user cannot perform.

### Backend layer
The backend must enforce permissions before every critical action.

### Database layer
Database policies should prevent unauthorized tenant access even if a request path is misused.

### Storage layer
File access should require permission-aware signed retrieval patterns.

### Operational principle
Authorization must never depend on frontend behavior alone.

---

## 23. Storage Path Strategy

Storage paths should be structured in a way that supports tenant isolation, traceability, and file organization.

A conceptual structure could separate files by:

- tenant or company
- file category
- object type
- object identity
- version

This helps with governance, retrieval, debugging, and future retention handling.

The exact path convention can be decided later, but the architecture must preserve strong structure.

---

## 24. Data Mutation Strategy

The architecture should favor controlled writes over broad update behavior.

### Principles
- create source records early
- attach interpretations as separate records
- create review and alert records explicitly
- log meaningful changes
- prefer versioning or snapshots for sensitive updates
- avoid destructive mutation patterns where accounting reconstruction matters

This approach is especially important for documents, tax decisions, approvals, and period-sensitive accounting records.

---

## 25. AI Pipeline Architecture Direction

The AI subsystem should be invoked through backend-controlled pipelines, not directly from the browser.

### Reasons
- financial data is sensitive
- prompts and extracted results require controlled handling
- confidence scoring and rule validation need trusted orchestration
- AI outputs must be stored as interpretation records, not silently applied

### Pipeline pattern
A typical AI pipeline should follow this pattern:

- source object identified
- content prepared for processing
- AI extraction or interpretation invoked
- output normalized into structured extraction results
- confidence and explanation stored
- deterministic validation executed
- review or auto-processing decision applied
- audit and alert events created

This pattern should stay consistent across invoice parsing, statement interpretation, and anomaly detection.

---

## 26. Rules Engine Architecture Direction

The rules engine should be treated as its own architectural capability, even if it begins simply.

### Responsibilities
It should evaluate:

- required fields
- tax plausibility
- period validity
- duplicate heuristics
- matching plausibility
- company-specific policy thresholds
- Cyprus-aware rule checks

### Architectural principle
Rules should be versionable and explainable.

The system should be able to answer not only that a rule failed, but which rule failed and why.

This is especially important for review workflows and future compliance trust.

---

## 27. Matching Engine Architecture Direction

The matching engine should be architected as a distinct subsystem rather than being buried inside invoice or transaction logic.

### Responsibilities
It should evaluate relationships between:

- invoices and transactions
- transactions and grouped settlements
- transaction references and contact patterns
- duplicate transactions and duplicate invoices

### Outputs
The matching engine should produce:

- candidate matches
- confidence levels
- exception reasons
- partial settlement indicators
- review recommendations

### Architectural principle
A suggested match is not the same thing as a reconciled match. The system must preserve that distinction.

---

## 28. Notification Architecture Direction

Notifications should be event-driven and grounded in meaningful business states.

### Notification triggers may include
- new high-priority alert created
- new review item assigned
- sync failure occurred
- overdue threshold crossed
- period ready for close
- export completed

### Delivery layers
The architecture should initially support:

- in-app notification center
- inline issue surfacing on dashboard and object detail pages

Later it may support:

- email notifications
- messaging or internal alert integrations

### Architectural principle
Notifications should be generated from structured alert or workflow states, not from scattered ad hoc frontend logic.

---

## 29. Reporting Architecture Direction

Reporting should be architected around structured queryable models, not generated from ad hoc calculations in the browser.

### This means
- major financial metrics should come from backend queries
- dashboards should consume prepared or composable data views
- reporting should understand review states and period boundaries
- exports should be reproducible from structured data

### Important principle
Metrics shown to the founder must clearly align with the accounting status model. For example, a reviewed and posted amount should not be confused with an unreviewed AI suggestion.

---

## 30. Period Control Architecture Direction

Period management should be implemented as a core control subsystem.

### Responsibilities
It should support:

- open period management
- review state awareness
- lock and unlock workflows
- period-linked exports
- filing-readiness indicators
- late adjustment visibility

### Architectural principle
Period control must influence what records can be changed and under what conditions. It is not just a reporting convenience feature.

---

## 31. Export Architecture Direction

Exports should be generated through explicit server-side jobs.

### Reasons
- exports may include sensitive evidence
- large export bundles can take time
- accountant packages should be reproducible
- period-based exports should remain traceable

### Examples
The export subsystem should eventually support:

- invoice file bundles
- statement file bundles
- monthly evidence packs
- VAT-oriented summaries
- transaction exports
- accountant handoff packages

### Architectural principle
Every important export generation should create an export record and audit event.

---

## 32. Failure Handling Strategy

The platform must treat failure as normal and manageable rather than exceptional chaos.

### The architecture should support
- job retries
- sync retry handling
- parser failure states
- integration disconnection states
- partial processing visibility
- manual recovery paths
- alert generation for failed automations

### Architectural principle
Failures must be visible and recoverable. The founder should never be left wondering whether the system silently broke.

---

## 33. Environment Strategy

The platform should be developed with clearly separated environments.

### Minimum environment model
- local development environment
- staging or pre-production environment
- production environment

### Architectural principle
Sensitive integrations, real financial data, and production storage should remain carefully separated from development and testing flows.

---

## 34. Logging and Monitoring Direction

The architecture should include both product-facing and system-facing monitoring.

### Product-facing monitoring
- audit events
- review counts
- sync statuses
- export statuses
- alert activity

### System-facing monitoring
- function failures
- job durations
- integration failures
- parser error rates
- AI pipeline failure patterns
- storage access failures

This monitoring is necessary for operational trust and future scale.

---

## 35. Non-Goals of This Architecture Layer

This document does not yet define:

- exact API contracts
- exact database schema definitions
- exact queue provider choices
- exact UI component structures
- exact AI model vendor choices
- exact tax rule formulas by jurisdiction
- exact state-machine transition tables

Those details belong in later technical documents.

---

## 36. Architecture Summary

The system architecture should be built as a layered, secure, multi-tenant, AI-native financial operations platform with clear separation between user interface, backend orchestration, relational data storage, file evidence storage, asynchronous processing, AI interpretation, deterministic validation, integrations, auditability, and reporting.

Its technical design must support the product’s central promise: the founder should experience a calm and intelligent bookkeeping workspace, while the backend preserves the full evidence chain, operational controls, and accounting-safe structure needed for serious financial management.

This document now serves as the architecture reference for the next layers, especially the compliance and audit document, the AI automation model, and the phase-based development specifications.

