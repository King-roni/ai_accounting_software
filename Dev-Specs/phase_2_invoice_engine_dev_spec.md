# Phase 2 Invoice Engine Dev Spec

## 1. Document Purpose

This document defines the definitive Phase 2 development specification for the AI-native bookkeeping platform. It builds directly on Phase 1 Foundation and introduces the first real invoice-processing workflows of the system.

Phase 2 is the point where the platform moves beyond foundational record storage and begins behaving like an operational invoice engine. It introduces invoice ingestion behavior, extraction-driven invoice creation, review workflows, approval decisions, validation rules, and structured separation between source truth, machine interpretation, and approved accounting truth.

This phase is intentionally limited to the invoice domain. It does not yet implement bank statement ingestion, transaction normalization, matching, reconciliation, duplicate engine maturity, alert center maturity, dashboard metrics maturity, filing exports, or full accounting posting logic.

The purpose of this phase is to create a trustworthy invoice operating layer that can later integrate cleanly with reconciliation, AI automation, compliance controls, and reporting.

---

## 2. Phase Objective

The objective of Phase 2 is to make the platform operationally capable of receiving invoice evidence, interpreting it, validating it, routing uncertain or sensitive cases to review, allowing humans to correct or approve invoice outcomes, and preserving the full chain between source evidence, machine interpretation, review decisions, and approved invoice truth.

At the end of Phase 2, the system should support:

- invoice-oriented document ingestion
- parsing-triggered invoice candidate generation
- extraction result presentation
- invoice validation rules
- invoice review workflows
- explicit approval decisions for invoice outcomes
- clear invoice lifecycle progression through review and approval
- outgoing invoice generation and issue handling at an operational level
- invoice-centric alerts and review items
- invoice-safe audit and control behavior

At the end of Phase 2, the system should still not behave like a full accounting, reconciliation, or filing engine.

---

## 3. Phase Boundary

### Included in Phase 2
Phase 2 includes only the invoice engine layer.

### Excluded from Phase 2
Phase 2 explicitly excludes:

- bank statement ingestion workflows
- transaction normalization workflows
- invoice-to-transaction matching workflows
- reconciliation workflows
- payment-settlement automation driven by bank data
- mature duplicate engine across all objects
- advanced anomaly engine beyond invoice-scope rule checks
- reporting dashboards with accounting totals
- ledger posting logic as operational truth
- filing exports
- email ingestion
- Revolut sync
- period locking and amendment workflows
- policy-driven auto-approval for broad production categories

This boundary must remain strict. Phase 2 should produce approved invoice truth, not full financial reconciliation truth.

---

## 4. Phase 2 Design Decisions

## 4.1 Invoice engine posture

### Decision
Phase 2 introduces a real invoice engine but not a full accounting engine.

### Meaning
Phase 2 must support:

- invoice evidence intake
- extraction-driven invoice candidate creation
- invoice review and approval
- invoice lifecycle progression through validated and approved states
- outgoing invoice generation and issuance

Phase 2 must not yet support:

- payment settlement driven by bank evidence
- reconciliation-complete invoice truth
- ledger-driven accounting reports
- automated filing outcomes

### Reason
The roadmap places invoice behavior before reconciliation and before full reporting. This phase must establish invoice truth safely without pretending the full bookkeeping chain already exists.

---

## 4.2 Approval posture

### Decision
Phase 2 introduces explicit invoice approval workflows.

### Meaning
Approval in Phase 2 means:

- a human has accepted the invoice record as accounting-valid at the invoice layer
- the system may treat the invoice as approved invoice truth
- approval decisions must be recorded as first-class objects

Approval in Phase 2 does not mean:

- posting to a final accounting ledger
- payment settlement confirmation
- filing readiness
- reporting period closure

### Reason
The project architecture requires approval as the bridge between interpretation and approved truth. Phase 2 is where that bridge becomes operational for invoices.

---

## 4.3 Posting posture

### Decision
Phase 2 still does not implement full operational posting.

### Meaning
Phase 2 may optionally create posting-ready scaffolding references, but must not:

- create ledger entries as authoritative accounting output
- rely on ledger entries for invoice lifecycle progression
- expose posting UI or posting APIs

### Reason
Posting belongs after invoice and reconciliation maturity. Approval is in scope now; posting remains deferred.

---

## 4.4 Invoice validation posture

### Decision
Phase 2 introduces invoice validation as a deterministic control layer.

### Validation scope in Phase 2
The system must be able to validate:

- required invoice fields presence
- amount coherence at invoice level
- document-to-invoice structural completeness
- obvious invoice type consistency
- basic tax field completeness posture
- outgoing invoice numbering validity within system rules

### Important note
Cyprus-specific legal completeness is still not fully codified here. Phase 2 focuses on invoice-operational validation and compliance-oriented readiness, not fully finalized jurisdictional tax logic.

---

## 4.5 Review posture

### Decision
Phase 2 introduces formal invoice review workflows.

### Meaning
The system must support:

- review items for invoice uncertainty and validation issues
- invoice review screens with side-by-side evidence and extracted values
- human correction of invoice candidate data
- explicit resolution of review items

### Important note
Phase 2 review is invoice-focused. It is not yet the generalized platform-wide review center envisioned in later phases.

---

## 4.6 Alert posture

### Decision
Phase 2 introduces invoice-scope alerts only.

### Meaning
Alerts may be created for:

- missing required invoice fields
- extraction uncertainty
- basic tax-field inconsistency posture
- suspicious outgoing invoice numbering conflicts
- duplicate risk indicators limited to invoice-scope heuristics

Phase 2 must not yet attempt a mature platform-wide alert engine.

---

## 4.7 Duplicate posture

### Decision
Phase 2 introduces limited invoice duplicate warnings, not full duplicate resolution automation.

### Meaning
The system may detect duplicate-like conditions using invoice-number, contact, amount, and date heuristics.

The system must:

- surface warnings or review items
- preserve the candidate comparison context
- require human resolution for material duplicate risk

The system must not:

- auto-suppress invoice records
- auto-merge invoices
- treat duplicate suspicion as final truth without review

### Reason
Invoice duplicate risk is too important to ignore, but full duplicate engine maturity belongs later.

---

## 4.8 Outgoing invoice posture

### Decision
Phase 2 introduces operational outgoing invoice generation.

### Meaning
The platform must support:

- founder-created outgoing invoices
- invoice numbering assignment
- generated invoice file preservation
- issue state tracking
- delivery state placeholder support

The platform does not yet need:

- automated external sending infrastructure
- payment settlement from bank evidence
- full receivables dashboarding

### Reason
Outgoing invoices are core to the invoice engine and should not be postponed beyond the invoice phase.

---

## 4.9 Auto-approval posture

### Decision
Phase 2 must remain strongly human-in-the-loop.

### Meaning
The system may support configuration-ready policy structures, but broad auto-approval is out of scope.

At most, narrowly constrained internal low-risk transitions may occur automatically only when they do not convert interpretation into approved truth.

### Reason
The project files explicitly prioritize review-heavy early phases. Invoice truth must become trustworthy before automation expands.

---

## 5. Scope of Phase 2 Modules

## 5.1 Invoice-oriented document ingestion

Phase 2 must extend document handling into invoice-specific intake workflows.

### Required behavior
- upload invoice evidence manually
- classify uploaded evidence into invoice-oriented pathways
- create or associate document records from Foundation
- trigger processing jobs and parsing runs for invoice documents
- route processed invoice documents into candidate creation flows

### Important note
This is not yet email ingestion. It remains app-driven document intake.

---

## 5.2 Invoice candidate generation

Phase 2 must introduce invoice candidate creation from interpretation-layer data.

### Required behavior
- use ParsingRun and ExtractionResult outputs to create or update invoice candidates
- preserve explicit linkage between Document, ParsingRun, ExtractionResult, and Invoice
- ensure invoice candidates remain distinguishable from approved invoice truth until approval occurs

### Required rule
Candidate generation must never destroy the original machine interpretation record.

---

## 5.3 Invoice validation engine

Phase 2 must introduce deterministic validation for invoice records.

### Required validation domains
- required field presence
- invoice total coherence
- line-total coherence where line items exist
- direction/type consistency
- contact linkage presence or review requirement
- document linkage presence for document-originated invoices
- outgoing invoice numbering uniqueness within company scope
- approval blocking conditions

### Validation outputs
The system must be able to produce:

- pass
- warning
- blocking failure

### Important rule
Validation results must remain inspectable and should drive review routing and approval eligibility.

---

## 5.4 Invoice review workflow

Phase 2 must implement invoice review as a real user workflow.

### Required behavior
- create ReviewItems for invoice cases requiring human intervention
- present original document and extracted values together
- highlight uncertain, missing, or conflicting invoice fields
- allow human edits to invoice candidate data
- re-run validation after edits
- resolve or escalate invoice review items appropriately

### Required UX principle
The review experience should feel guided and bounded. It should not look like a raw database editor.

---

## 5.5 Invoice approval workflow

Phase 2 must implement explicit approval decisions for invoices.

### Required behavior
- allow eligible invoice candidates to be approved by permitted actors
- create ApprovalDecision records
- update invoice state from review-oriented or validated posture into approved posture
- preserve before and after context in audit history

### Required approval rule
An invoice may not be approved if blocking validation failures remain active.

### Required separation
Approval must convert invoice data into approved invoice truth, but not into posted ledger truth.

---

## 5.6 Outgoing invoice generation

Phase 2 must implement operational outgoing invoice creation.

### Required behavior
- create outgoing invoice drafts
- select or create linked customer contact
- define line items and totals
- assign numbering using company rules
- generate a preserved outgoing invoice file
- mark invoice as generated and issued
- optionally record delivery status manually

### Required evidence rule
Generated outgoing invoices must be preserved in the document vault as evidence, just like uploaded source documents.

---

## 5.7 Invoice-scope alerts and review items

Phase 2 must implement limited invoice-scope issue surfacing.

### Alerts in scope
- missing required fields
- extraction low-confidence indicators
- approval blocker indicators
- basic duplicate suspicion indicators
- numbering conflict indicators for outgoing invoices

### Review items in scope
- unresolvable extraction ambiguity
- contact ambiguity
- duplicate-risk resolution
- tax-field review posture
- blocking validation failures requiring manual correction

### Important note
Alerts and review items must remain distinct, consistent with the broader project model.

---

## 5.8 Invoice duplicate warnings

Phase 2 must implement lightweight invoice duplicate heuristics.

### Minimum heuristic inputs
- invoice number
- contact
- invoice date
- total amount
- direction

### Required behavior
- produce duplicate warnings or review items
- show comparison context
- allow human dismissal or resolution
- preserve the decision context in audit

---

## 5.9 Invoice-centric audit hardening

Phase 2 must deepen audit coverage for interpretation-to-approval transitions.

### Additional audit-covered actions
- invoice candidate created from ExtractionResult
- invoice validation result changes
- review item created for invoice
- invoice fields corrected during review
- invoice approved
- invoice approval rejected or deferred
- outgoing invoice generated
- outgoing invoice numbering assigned
- duplicate warning resolved or dismissed

---

## 6. Required Phase 2 Data Model Changes

Phase 2 builds on Phase 1 and requires the following entities in operational form:

- Invoice
- InvoiceLine
- Document
- DocumentVersion
- ParsingRun
- ExtractionResult
- ReviewItem
- Alert
- ApprovalDecision
- Contact

### Additional strongly recommended support structures
Phase 2 should introduce operational support structures such as:

- InvoiceValidationResult or equivalent validation artifact model
- InvoiceDuplicateCandidate or equivalent comparison artifact model
- OutgoingInvoiceGeneration metadata support if not modeled directly on Invoice and Document

### Important modeling principle
Interpretation artifacts, review artifacts, and approved invoice truth must remain separable in storage and logic.

---

## 7. Phase 2 State Behavior

## 7.1 Document states in scope

Phase 2 continues operational support for:
- uploaded
- queued_for_processing
- processing
- processed
- failed_processing
- linked
- archived

### Additional Phase 2 rule
Invoice documents should move into `linked` when they are associated with an invoice candidate or approved invoice.

---

## 7.2 ParsingRun states in scope

Phase 2 continues support for:
- pending
- running
- succeeded
- partially_succeeded
- failed
- cancelled

### Additional Phase 2 rule
A `partially_succeeded` ParsingRun must remain eligible to create candidate invoice data, but typically routes into review-sensitive handling.

---

## 7.3 ExtractionResult states in scope

Phase 2 must operationalize these states:
- generated
- validated
- flagged
- accepted_for_review
- superseded
- rejected

### Important rule
ExtractionResult remains interpretation-layer data throughout.

---

## 7.4 Invoice states in scope

Phase 2 must operationalize the following invoice states:
- draft
- extracted
- validated
- needs_review
- approved
- archived

### Schema-ready but still non-operational in Phase 2
- posted
- partially_paid
- paid
- disputed
- voided

### Important rule
Phase 2 must not operationalize payment-settlement states through actual reconciliation logic.

---

## 7.5 ReviewItem states in scope

Phase 2 must operationalize:
- open
- in_progress
- awaiting_input
- resolved
- dismissed
- escalated

---

## 7.6 Alert states in scope

Phase 2 must operationalize:
- active
- acknowledged
- linked_to_review
- resolved
- dismissed
- expired

---

## 7.7 ApprovalDecision states in scope

Phase 2 must operationalize:
- pending
- approved
- rejected
- superseded

### Important rule
ApprovalDecision becomes a live entity in Phase 2.

---

## 7.8 Outgoing invoice generation states in scope

Phase 2 must operationalize:
- drafting
- generated
- issued
- delivered
- cancelled

### Schema-ready but still non-operational in Phase 2
- overdue
- settled
- credited

---

## 8. Required Backend Operations in Phase 2

Every critical backend operation must continue to follow the trusted mutation pattern:
1. authenticate request
2. validate tenant scope
3. validate permission
4. execute structured mutation
5. create audit event
6. return updated state

### Required backend operations
- upload invoice document
- trigger invoice parsing flow
- create invoice candidate from ExtractionResult
- update invoice candidate fields
- run invoice validation
- create invoice review item
- resolve invoice review item
- create invoice alert
- acknowledge or resolve invoice alert
- approve invoice
- reject or defer invoice approval decision
- create outgoing invoice draft
- generate outgoing invoice number
- generate outgoing invoice file
- mark outgoing invoice issued
- record manual delivery status
- create duplicate warning artifact
- resolve duplicate warning outcome

---

## 9. Storage and Evidence Rules

Phase 2 continues all Phase 1 evidence-preservation rules and adds invoice-engine-specific requirements.

### Required rules
- invoice-source documents remain preserved as original evidence
- generated outgoing invoice files must also be preserved as evidence
- invoice review corrections must never overwrite source evidence
- regenerated or corrected output files must create explicit new versions where applicable
- interpretation outputs must remain linked but distinct from approved invoice records

### Important rule
A corrected invoice field is not the same thing as a corrected source document. Source evidence and approved invoice data must not be conflated.

---

## 10. Security and Permission Rules

Phase 2 builds on Phase 1 RBAC and introduces invoice-specific permissions.

### Founder and Admin
May:
- upload invoice documents
- create and edit invoice candidates
- resolve invoice review items
- approve invoices
- create outgoing invoices
- issue outgoing invoices
- resolve duplicate warnings
- view invoice-scope audit history

### Accountant
May:
- view invoice documents
- edit invoice candidates where allowed
- resolve review items where allowed
- approve invoices where allowed by company policy
- create and edit outgoing invoices where allowed
- view invoice audit history

### Reviewer
May:
- view invoice documents
- edit invoice candidates where allowed
- resolve review items
- acknowledge alerts

May not by default:
- approve invoices
- manage numbering rules
- manage company-wide settings

### Important implementation note
Approval permissions must be stricter than edit permissions.

---

## 11. Validation and Review Rules

## 11.1 Approval blockers

The following must block invoice approval in Phase 2:
- missing required invoice fields
- irreconcilable amount incoherence at invoice level
- missing document linkage for document-originated invoice candidates
- unresolved duplicate blocker marked as material
- unresolved contact ambiguity when contact linkage is required

## 11.2 Review triggers

The following must create or strongly suggest invoice review:
- low-confidence extraction on required fields
- conflicting extracted values
- invoice candidate created from `partially_succeeded` ParsingRun
- outgoing numbering conflict
- duplicate suspicion
- tax-related ambiguity flagged at invoice layer

## 11.3 Non-authoritative placeholders

Fields such as tax-treatment placeholders or future payment-status placeholders must not drive posting or compliance-final logic in Phase 2.

---

## 12. Audit Requirements

Every meaningful invoice-engine mutation must generate an audit event.

### Additional minimum audit contents where relevant
- previous invoice state
- new invoice state
- previous review status
- new review status
- previous approval status
- new approval status
- originating document and parsing references where relevant
- actor identity or policy identity

### Minimum invoice-engine audit coverage
- invoice candidate created
- invoice field edited
- validation result created or changed
- review item created
- review item resolved, escalated, or dismissed
- alert created, acknowledged, resolved, or dismissed
- approval decision created
- invoice approved or rejected
- outgoing invoice number assigned
- outgoing invoice file generated
- duplicate warning resolved

---

## 13. Acceptance Criteria

Phase 2 is complete only when all of the following are true:

1. A user can upload invoice evidence and trigger invoice-oriented processing.
2. The system can create a ParsingRun and persist ExtractionResult data for invoice documents.
3. The system can create an invoice candidate from interpretation-layer data without collapsing it into approved truth.
4. The system can validate invoice candidates and classify validation outputs as pass, warning, or blocking failure.
5. The system can create invoice review items for cases requiring human intervention.
6. A reviewer can inspect original evidence and extracted values together.
7. A reviewer can edit invoice candidate data and re-run validation.
8. An eligible invoice candidate can be approved by an authorized actor.
9. Approval creates an ApprovalDecision record and transitions the invoice into approved state.
10. Approval does not create ledger truth or posting behavior.
11. The system can create outgoing invoices, assign numbering, generate preserved invoice files, and mark them issued.
12. The system can create invoice-scope duplicate warnings and require human resolution for material cases.
13. All critical invoice-engine actions are auditable.
14. No Phase 2 feature silently overwrites source evidence.
15. No Phase 2 feature collapses source truth, machine interpretation, and approved invoice truth into a single uncontrolled record.
16. No Phase 2 feature implements bank reconciliation, posting, or filing behavior under the invoice label.

---

## 14. Items Explicitly Deferred After Phase 2

The following remain out of scope after this phase and must be handled in later dev-specs:

- bank statement ingestion
- transaction normalization
- invoice-to-transaction matching
- reconciliation logic
- bank-driven settlement states
- ledger posting logic
- dashboard accounting totals
- broad duplicate engine maturity
- cross-object anomaly engine maturity
- email ingestion
- Revolut integration
- filing-oriented exports
- period locking and amendment
- Cyprus tax-rule completeness
- broad policy-based automation thresholds

---

## 15. Implementation Order Recommendation

The recommended implementation order inside Phase 2 is:

1. invoice-oriented document intake and processing triggers
2. invoice candidate generation from ExtractionResult
3. invoice validation artifact model and validation rules
4. invoice review workflow and review UI
5. approval decision workflow
6. outgoing invoice generation and numbering
7. invoice-scope alerts and duplicate warnings
8. audit hardening and permission refinement

This sequence ensures that approvalable invoice truth is introduced only after candidate generation and review are already trustworthy.

---

## 16. Final Phase 2 Summary

Phase 2 turns the platform from a foundational evidence system into a real invoice engine. It introduces invoice candidate generation, validation, review, approval, outgoing invoice generation, and invoice-scope issue handling while preserving the project’s central trust model.

At the end of this phase, the platform will be able to create approved invoice truth safely, but it will still stop short of full reconciliation, posting, and filing behavior. That boundary is intentional and necessary for maintaining architectural clarity.

