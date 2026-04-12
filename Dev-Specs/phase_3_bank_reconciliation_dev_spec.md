# Phase 3 Bank Reconciliation Dev Spec

## 1. Document Purpose

This document defines the definitive Phase 3 development specification for the AI-native bookkeeping platform. It builds on Phase 1 Foundation and Phase 2 Invoice Engine and introduces the first real bank-data and reconciliation workflows of the system.

Phase 3 is the point where the platform begins connecting invoice truth to money-movement truth. It introduces bank accounts, bank statement ingestion, transaction normalization, transaction classification, invoice-to-transaction matching, reconciliation workflows, partial settlement handling, unmatched transaction handling, and bank-side review behavior.

This phase is intentionally limited to the bank and reconciliation domain. It does not yet implement mature cross-platform integrations such as Revolut live sync, broad automation policies, full anomaly intelligence across all accounting objects, final ledger posting, filing exports, or full dashboard intelligence.

The purpose of this phase is to establish a trustworthy reconciliation engine that can safely connect financial evidence and actual financial movement without collapsing unresolved ambiguity into false accounting certainty.

---

## 2. Phase Objective

The objective of Phase 3 is to make the platform operationally capable of receiving bank evidence, turning it into normalized transaction records, classifying those records, identifying likely relationships with invoices, routing ambiguous settlement cases into review, and progressing accepted relationships into reconciled financial truth at the transaction and invoice-settlement layer.

At the end of Phase 3, the system should support:

- bank account records
- bank statement ingestion by file upload
- statement parsing and transaction candidate creation
- normalized transaction records
- transaction classification workflows
- invoice-to-transaction matching workflows
- partial payment handling
- unmatched transaction handling
- reconciliation workflows
- bank- and reconciliation-scope review items and alerts
- audit-safe traceability from statement evidence to reconciled outcome

At the end of Phase 3, the system should still not behave like a fully autonomous bank integration platform, a final accounting posting engine, or a full filing system.

---

## 3. Phase Boundary

### Included in Phase 3
Phase 3 includes only the bank ingestion and reconciliation layer.

### Excluded from Phase 3
Phase 3 explicitly excludes:

- live Revolut sync
- email ingestion
- generalized external bank-connector framework maturity
- broad policy-based auto-reconciliation across production categories
- final ledger posting logic as authoritative accounting truth
- filing exports
- period locking and amendment workflows
- mature cross-object anomaly engine beyond bank/reconciliation scope
- full dashboard metrics maturity
- cross-channel notification expansion

This boundary must remain strict. Phase 3 is where the system learns to reconcile money movement, not where it becomes a complete autonomous accounting and filing operator.

---

## 4. Phase 3 Design Decisions

## 4.1 Reconciliation posture

### Decision
Phase 3 introduces real reconciliation workflows, but only at the invoice-to-transaction settlement layer.

### Meaning
Phase 3 must support:

- statement ingestion
- normalized transactions
- transaction classification
- matching candidates between invoices and transactions
- explicit acceptance or rejection of matches
- transaction reconciliation states
- invoice payment-state progression based on accepted matches

Phase 3 must not yet support:

- generalized reconciliation against all future accounting object types
- autonomous reconciliation across all categories
- final ledger posting as the source of truth

### Reason
The roadmap places bank reconciliation after invoice truth and before mature automation and reporting. This phase must establish trustworthy settlement logic without overextending into complete accounting closure.

---

## 4.2 Bank ingestion posture

### Decision
Phase 3 will introduce bank statement ingestion through uploaded statements, not live bank sync.

### Meaning
Phase 3 must support:

- manual bank statement upload
- statement evidence preservation
- statement-to-transaction parsing
- explicit statement lifecycle and import status

Phase 3 must not yet require:

- live API integrations
- webhook ingestion
- external sync retry frameworks
- provider-specific pending-versus-posted transaction reconciliation

### Reason
Statement upload is the correct bridge between invoice truth and live bank integrations. It keeps the phase operational while avoiding premature integration complexity.

---

## 4.3 Transaction truth posture

### Decision
Phase 3 introduces normalized transaction truth as an operational layer distinct from source statement evidence.

### Meaning
The platform must preserve:

- source statement evidence
- imported statement line context
- normalized transaction records used for classification, matching, and reconciliation

### Required separation
A statement line as read from a file is not the same as a normalized transaction record. The normalized transaction is the usable operational object.

### Reason
This separation is already embedded in the project domain model and is essential for trust, reviewability, and future integrations.

---

## 4.4 Matching posture

### Decision
Phase 3 introduces a real invoice-to-transaction matching engine, but only as a controlled matching layer.

### Meaning
The system must support:

- one transaction to one invoice
- one transaction to multiple invoices
- multiple transactions to one invoice
- partial payment handling
- grouped settlement candidates
- uncertain candidate matches requiring review

The system must not:

- silently finalize ambiguous matches
- auto-merge or suppress records based on low-confidence matching
- treat a proposed match as reconciled truth until acceptance occurs

### Reason
Matching is core to reconciliation but is too risky to treat as implicit truth.

---

## 4.5 Reconciliation acceptance posture

### Decision
Phase 3 introduces accepted reconciliation outcomes, but still not final accounting posting.

### Meaning
An accepted reconciliation outcome means:

- a transaction has been sufficiently resolved against one or more invoices or approved settlement targets
- invoice payment status may progress accordingly
- the transaction may move to reconciled state

It does not mean:

- ledger posting is complete
- reporting is final
- filing treatment is finalized

### Reason
The project architecture requires reconciliation truth to exist separately from posting truth.

---

## 4.6 Partial-payment posture

### Decision
Phase 3 must explicitly support partial settlement.

### Meaning
The system must allow:

- one invoice to be only partly settled by a transaction
- multiple transactions to contribute to the same invoice over time
- visible residual unpaid amounts on invoices
- match objects that record amount-linked scope, not just boolean success

### Reason
Partial settlement is too common to postpone and is foundational to realistic reconciliation.

---

## 4.7 Unmatched posture

### Decision
Phase 3 must treat unmatched transactions as first-class operational outcomes.

### Meaning
The system must support:

- transactions that remain unmatched after import
- review items or alerts for unresolved material unmatched transactions
- manual classification without forced invoice linkage where appropriate

### Important note
Unmatched does not automatically mean erroneous. It means unresolved within the current reconciliation context.

---

## 4.8 Duplicate posture in bank context

### Decision
Phase 3 will introduce limited transaction and statement duplicate warnings, but not a fully mature duplicate engine.

### Meaning
The system may detect:

- repeated statement imports
- repeated transaction lines with highly similar characteristics
- duplicated settlement attempts against the same invoice

The system must:

- surface warnings
- preserve context
- require human resolution for material duplicate risk

The system must not:

- auto-delete duplicated transaction records
- silently auto-resolve ambiguous duplication

---

## 4.9 Auto-reconciliation posture

### Decision
Phase 3 remains strongly human-in-the-loop.

### Meaning
The system may support limited low-risk auto-acceptance only for narrowly constrained cases if they do not introduce unresolved contradiction, but broad auto-reconciliation is out of scope.

### Reason
Reconciliation is too sensitive to automate broadly before live integration maturity, broader rules maturity, and real performance data exist.

---

## 5. Scope of Phase 3 Modules

## 5.1 Bank account foundation

Phase 3 must introduce BankAccount as an operational entity.

### Required fields
At minimum:

- company_id
- institution_name
- account_label
- masked_account_identifier
- currency
- country
- active_status
- created_at / updated_at

### Required behavior
- create bank account record
- edit bank account record
- associate statements and transactions to bank account

### Important note
This is still upload-based statement handling, not live sync connection management.

---

## 5.2 Statement ingestion

Phase 3 must implement uploaded bank statement ingestion.

### Required behavior
- upload statement file manually
- preserve original statement evidence in document vault
- create Statement record
- trigger statement parsing flow
- track statement processing lifecycle
- store source import metadata where available

### Supported file direction
This phase should support the chosen initial file types for statement import, but the spec does not force the exact parser format strategy yet.

---

## 5.3 Statement parsing and transaction candidate creation

Phase 3 must create normalized transaction records from statement imports.

### Required behavior
- parse statement content into source line representations
- create normalized Transaction records
- preserve statement-to-transaction lineage
- allow partial parse outcomes without destroying statement integrity

### Required separation
A failed or partial statement parse must not destroy already preserved statement evidence.

---

## 5.4 Transaction normalization

Phase 3 must normalize imported transaction data into a consistent internal form.

### Required normalization scope
- booking date
- value date where available
- amount
- direction
- currency
- description
- normalized description
- source reference
- bank account linkage
- statement linkage

### Required rule
Normalization must preserve original source context while creating a clean operational transaction object.

---

## 5.5 Transaction classification

Phase 3 must introduce transaction-level classification workflows.

### Required behavior
- classify likely transaction meaning
- suggest likely contact where possible
- suggest likely transaction category or type
- route uncertain cases to review
- preserve classification as reviewable interpretation or accepted classification state

### Important note
Transaction classification in Phase 3 supports reconciliation and handling of unmatched items. It is not yet the full accounting categorization engine for every future use case.

---

## 5.6 Invoice-to-transaction matching

Phase 3 must implement real matching workflows.

### Required match patterns
- one transaction to one invoice
- one transaction to many invoices
- many transactions to one invoice
- partial settlement
- grouped settlement candidates

### Required behavior
- generate match candidates
- attach confidence and rationale context
- allow human acceptance or rejection
- preserve match objects and match history
- update invoice payment-state posture when accepted
- update transaction reconciliation posture when accepted

### Important rule
A proposed match must remain distinct from an accepted match.

---

## 5.7 Reconciliation workflow

Phase 3 must implement transaction-level reconciliation workflows.

### Required behavior
- move transactions through match candidate into matched and reconciled states
- allow rejection and rework of settlement attempts
- preserve unresolved transactions as unmatched or review-sensitive
- update invoice payment-state posture based on accepted match amounts

### Required boundary
Reconciliation in Phase 3 is settlement truth, not final ledger truth.

---

## 5.8 Unmatched handling and manual resolution

Phase 3 must implement controlled handling for unmatched transactions.

### Required behavior
- list unmatched transactions
- allow manual review and classification
- allow manual non-invoice resolution posture where appropriate
- preserve unresolved status when no safe resolution exists

### Important note
The platform must not force every transaction into an invoice match if the correct resolution is still uncertain.

---

## 5.9 Statement- and reconciliation-scope alerts and review items

Phase 3 must implement limited bank/reconciliation issue surfacing.

### Alerts in scope
- statement import failure
- partial statement parse
- material unmatched transaction
- conflicting match candidates
- duplicate statement import suspicion
- duplicate transaction suspicion
- inconsistent settlement amount posture

### Review items in scope
- unresolved unmatched transaction
- ambiguous transaction classification
- ambiguous invoice-to-transaction matching
- duplicate resolution
- partial settlement review

---

## 5.10 Reconciliation audit hardening

Phase 3 must deepen audit coverage for bank evidence, normalized transaction creation, matching, and reconciliation outcomes.

### Additional audit-covered actions
- bank account created or edited
- statement uploaded
- statement parse started and completed
- transaction created from statement import
- transaction normalized or corrected
- match candidate created
- match accepted or rejected
- reconciliation completed
- unmatched transaction manually resolved
- duplicate warning resolved or dismissed

---

## 6. Required Phase 3 Data Model Changes

Phase 3 builds on Phase 1 and Phase 2 and requires the following entities in operational form:

- BankAccount
- Statement
- Transaction
- Match
- ReviewItem
- Alert
- Document
- DocumentVersion
- Invoice
- Contact

### Additional strongly recommended support structures
Phase 3 should introduce operational support structures such as:

- StatementImportResult or equivalent parse artifact model
- TransactionClassificationResult or equivalent classification artifact model
- TransactionDuplicateCandidate or equivalent comparison artifact model
- ReconciliationResolution metadata support where not modeled directly on Match or Transaction

### Important modeling principle
Source statement evidence, normalized transaction truth, match proposals, accepted matches, and reconciled outcomes must remain separable in storage and logic.

---

## 7. Phase 3 State Behavior

## 7.1 Statement states in scope

Phase 3 must operationalize:
- received
- queued_for_import
- importing
- imported
- needs_review
- reconciled_ready
- archived
- failed_import

### Important rule
A statement may become `reconciled_ready` even while some resulting transactions still require later resolution, provided the statement itself is sufficiently imported and usable.

---

## 7.2 Transaction states in scope

Phase 3 must operationalize:
- imported
- normalized
- classified
- needs_review
- match_candidate
- matched
- reconciled
- exception_flagged
- archived

### Important rule
`matched` must remain distinct from `reconciled`. A transaction can have an accepted match relationship without yet being fully resolved in the broader transaction context.

---

## 7.3 Match states in scope

Phase 3 must operationalize:
- proposed
- under_review
- accepted
- partially_applied
- rejected
- superseded

### Important rule
Match state is independent from invoice lifecycle state and transaction lifecycle state.

---

## 7.4 ReviewItem states in scope

Phase 3 continues support for:
- open
- in_progress
- awaiting_input
- resolved
- dismissed
- escalated

---

## 7.5 Alert states in scope

Phase 3 continues support for:
- active
- acknowledged
- linked_to_review
- resolved
- dismissed
- expired

---

## 7.6 Invoice payment-status posture in scope

Phase 3 must operationalize invoice payment-status progression as a sub-layer based on accepted matches.

### States in scope
- unpaid
- partially_paid
- paid
- overpaid
- refunded
- write_off_candidate schema-ready only

### Important rule
These are payment-status outcomes only. They do not imply posting, filing, or final accounting closure.

---

## 8. Required Backend Operations in Phase 3

Every critical backend operation must continue to follow the trusted mutation pattern:
1. authenticate request
2. validate tenant scope
3. validate permission
4. execute structured mutation
5. create audit event
6. return updated state

### Required backend operations
- create bank account
- update bank account
- upload statement document
- create statement record
- trigger statement parsing flow
- create transactions from statement import
- update normalized transaction fields
- create transaction classification result
- create match candidate
- accept match
- reject match
- partially apply match
- mark transaction reconciled
- resolve unmatched transaction manually
- create reconciliation alert
- acknowledge or resolve reconciliation alert
- create duplicate warning artifact for statement or transaction
- resolve duplicate warning outcome

---

## 9. Storage and Evidence Rules

Phase 3 continues all earlier evidence-preservation rules and adds bank-specific requirements.

### Required rules
- uploaded statement files must be preserved as source evidence
- statement re-uploads or replacements must create explicit new document versions where applicable
- normalized transactions must preserve statement lineage
- transaction corrections must not overwrite source statement evidence
- accepted matches must remain linked to both source evidence chain and approved invoice truth

### Important rule
A transaction correction is not the same thing as altering the source statement. Evidence and normalized transaction truth must remain distinct.

---

## 10. Security and Permission Rules

Phase 3 builds on earlier RBAC and introduces bank/reconciliation-specific permissions.

### Founder and Admin
May:
- create and edit bank accounts
- upload statement files
- trigger statement imports
- edit normalized transactions where allowed
- accept or reject matches
- resolve unmatched items
- view bank/reconciliation audit history

### Accountant
May:
- view statement evidence
- edit normalized transactions where allowed
- accept or reject matches where allowed by company policy
- resolve unmatched items where allowed
- view bank/reconciliation audit history

### Reviewer
May:
- view statement evidence
- view normalized transactions
- resolve review items
- acknowledge alerts
- propose or edit match handling where allowed

May not by default:
- create or edit bank accounts
- approve high-impact reconciliation outcomes unless explicitly granted later

### Important implementation note
Match acceptance permissions should be at least as strict as invoice approval permissions, and may be stricter depending on company policy.

---

## 11. Validation and Review Rules

## 11.1 Statement import blockers

The following must block clean statement import completion and route the statement toward failure or review posture:
- unreadable or unsupported import content
- missing core transaction line structure
- unrecoverable parse contradiction
- duplicate statement import marked as material

## 11.2 Match acceptance blockers

The following must block match acceptance:
- contradictory accepted match already consuming the same amount improperly
- amount relationship that exceeds allowed settlement logic without explicit override path
- missing invoice or transaction identity integrity
- unresolved duplicate blocker affecting the same settlement attempt

## 11.3 Review triggers

The following must create or strongly suggest review:
- ambiguous transaction classification
- multiple plausible invoice candidates
- partial settlement with residual ambiguity
- material unmatched transaction
- statement parse partially_succeeded posture
- duplicate suspicion at statement or transaction level

## 11.4 Non-authoritative placeholders

Any future posting, filing, or deep tax-treatment placeholders must not drive final accounting logic in Phase 3.

---

## 12. Audit Requirements

Every meaningful bank-ingestion and reconciliation mutation must generate an audit event.

### Additional minimum audit contents where relevant
- previous and new transaction state
- previous and new match state
- previous and new invoice payment status
- originating statement and bank account references
- accepted linked amount context
- actor identity or policy identity

### Minimum bank/reconciliation audit coverage
- bank account created or edited
- statement uploaded
- statement import state changed
- transaction created from statement source
- transaction normalized or corrected
- classification result created or changed
- match candidate created
- match accepted, rejected, partially applied, or superseded
- transaction reconciled
- unmatched transaction resolved or left unresolved
- duplicate warning resolved or dismissed

---

## 13. Acceptance Criteria

Phase 3 is complete only when all of the following are true:

1. A user can create a bank account record.
2. A user can upload bank statement evidence and trigger statement-oriented processing.
3. The system can create a Statement record and preserve the original statement file as source evidence.
4. The system can parse statement content into normalized Transaction records while preserving statement lineage.
5. The system can classify transactions and preserve classification outcomes.
6. The system can generate invoice-to-transaction match candidates with rationale or comparison context.
7. A permitted actor can accept or reject a match candidate.
8. Accepted matches can update invoice payment-status posture to unpaid, partially_paid, paid, overpaid, or refunded where appropriate.
9. A transaction can move into reconciled state only through controlled reconciliation workflow.
10. The system can support partial settlement across one-to-many and many-to-one settlement scenarios.
11. Material unmatched transactions can remain visible and reviewable without forced false resolution.
12. The system can create bank/reconciliation-scope alerts and review items.
13. All critical statement, transaction, match, and reconciliation actions are auditable.
14. No Phase 3 feature silently overwrites statement evidence.
15. No Phase 3 feature collapses source statement evidence, normalized transaction truth, proposed match logic, and reconciled truth into a single uncontrolled record.
16. No Phase 3 feature implements live bank sync, final ledger posting, or filing behavior under the reconciliation label.

---

## 14. Items Explicitly Deferred After Phase 3

The following remain out of scope after this phase and must be handled in later dev-specs:

- live Revolut integration
- generalized external banking connector framework
- broad policy-based auto-reconciliation
- final ledger posting logic
- dashboard accounting totals maturity
- filing exports
- period locking and amendment
- mature cross-object anomaly intelligence
- cross-channel notifications
- Cyprus tax-rule completeness

---

## 15. Implementation Order Recommendation

The recommended implementation order inside Phase 3 is:

1. bank account model
2. statement upload and statement lifecycle
3. transaction creation and normalization from statement import
4. transaction classification artifacts and review posture
5. invoice-to-transaction matching engine
6. partial-settlement and payment-status progression logic
7. unmatched handling and duplicate warnings
8. reconciliation audit hardening and permission refinement

This sequence ensures that the platform first becomes capable of preserving and normalizing money-movement evidence before it begins resolving that evidence against invoice truth.

---

## 16. Final Phase 3 Summary

Phase 3 turns the platform from an invoice-truth system into a reconciliation-capable bookkeeping system. It introduces bank accounts, statement ingestion, normalized transaction truth, matching, partial settlement handling, unmatched transaction handling, and controlled reconciliation outcomes.

At the end of this phase, the platform will be able to connect approved invoice truth to actual money movement safely, while still stopping short of live integrations, full automation, final posting, and filing behavior. That boundary is intentional and necessary for architectural clarity and trust.

