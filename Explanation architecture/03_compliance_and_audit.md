# Compliance and Audit

## 1. Document Purpose

This document defines the compliance, evidence, retention, traceability, and audit philosophy of the AI-native bookkeeping platform. It explains how the software must preserve financial records, track changes, support reviewability, and maintain a structurally trustworthy accounting environment for a Cyprus-based company.

This document is not a substitute for legal advice or licensed tax advice. Its role is to define the product and system behaviors that make the platform compliance-oriented, accountant-safe, audit-safe, and filing-ready.

The purpose is to ensure that automation and AI do not weaken accounting integrity. Instead, the product must be designed so that increased automation still results in better traceability, stronger evidence preservation, and clearer reviewability.

---

## 2. Compliance Philosophy

The software must be designed around the principle that convenience never overrides accounting integrity.

The platform is being built to reduce bookkeeping stress, but that reduction may never come from hiding important financial uncertainty, silently rewriting accounting evidence, or making untraceable decisions. The system must make bookkeeping easier by improving structure, not by reducing accountability.

The compliance philosophy of the platform should therefore be based on the following principles:

- original evidence must remain preserved
- accounting-relevant actions must be traceable
- important changes must be reviewable
- AI interpretation must remain distinguishable from approved accounting truth
- tax-sensitive issues must be surfaced rather than hidden
- reporting periods must be controllable
- exports must remain reproducible
- the platform must support accountant review and future filing needs

This software should be easy to use, but difficult to misuse.

---

## 3. Cyprus-Oriented Compliance Direction

The company is based in Cyprus, so the system must be built with Cyprus-oriented compliance assumptions in mind.

This means the platform should support a bookkeeping environment in which:

- VAT-relevant records remain preserved and retrievable
- accounting documents remain readable over time
- records can be linked back to their source evidence
- classifications and exceptions can be reviewed later
- tax-sensitive issues can be identified before reporting
- reporting periods can be organized and locked
- accountant handoff is practical and defensible

The platform does not need to act as a licensed tax authority or guarantee perfect legal treatment in every case. However, it must produce a structurally strong environment that can support reliable accounting operations and professional review.

---

## 4. Evidence Integrity Principle

Evidence integrity is one of the core compliance foundations of the platform.

The system must always preserve the integrity of accounting evidence. This means that when a financial document or source transaction enters the platform, the software must maintain the ability to reconstruct what the original source was, how the system interpreted it, what was changed later, and what final accounting treatment was approved.

Evidence integrity requires more than keeping files in storage. It requires a chain of custody between source evidence, interpretation records, approvals, and accounting outcomes.

The platform must therefore preserve:

- original source object identity
- source timestamps where available
- file or input-level integrity markers
- interpretation history
- approval history
- accounting outcome history
- export traceability

This chain is essential for trust, review, and audit support.

---

## 5. Original Evidence Preservation

Original evidence must remain preserved.

This applies to:

- uploaded invoice files
- uploaded bank statement files
- imported transaction source records
- system-generated outgoing invoices
- important source attachments

The platform must not rely on a model in which the latest version replaces the past. Instead, the system must preserve the original evidence and any later versions or derived interpretations as separate, traceable records.

### Product requirement
The original uploaded or imported source must remain reconstructable even if later corrections are made.

### Why this matters
Bookkeeping integrity depends on being able to show:

- what the original source looked like
- what the system extracted from it
- what the user corrected
- why the final accounting outcome differs from the first interpretation if relevant

This requirement is especially important when AI participates in extraction and classification.

---

## 6. Legal Immutability Principle

The platform must enforce document-level immutability and evidence-level traceability.

This does not mean the system must prevent all corrections. It means corrections must be made through traceable change patterns rather than destructive overwrite.

### The platform must support the following rules
- original evidence must not be silently overwritten
- replacement files must be stored as explicit versions if allowed
- important field changes must preserve before and after visibility
- accounting decisions must remain attributable to an actor and time
- deleted items must remain reconstructable where accounting relevance exists

### Practical interpretation
The platform should behave as follows:

- files are preserved as original versions
- metadata corrections are stored as recorded changes
- AI outputs are versioned as interpretation artifacts
- approvals are recorded as decisions rather than invisible updates

This creates a system that is safe for review and resilient under scrutiny.

---

## 7. Source Truth, Machine Interpretation, and Approved Truth

A core compliance requirement is that the system must never collapse different trust layers into one invisible record.

The platform must clearly preserve the distinction between:

### 7.1 Source truth
The actual uploaded or imported source evidence.

### 7.2 Machine interpretation
The AI-generated or parser-generated understanding of that evidence.

### 7.3 Approved accounting truth
The reviewed and accepted accounting representation used operationally by the platform.

### Why this matters
Without this distinction, the system becomes hard to audit because it becomes impossible to tell whether a value came from a document, from AI, from a human correction, or from a later rule-driven adjustment.

The platform must always preserve the origin of truth.

---

## 8. Traceability Principle

Every material accounting decision or workflow transition must be traceable.

Traceability means that the platform should be able to answer:

- where did this number come from
- which document or source event created this record
- which parser or AI process proposed this interpretation
- who reviewed the item
- what was changed
- when was it changed
- why was it changed
- what rule or warning applied
- whether the outcome was manually approved or automatically accepted under trusted policy

A bookkeeping platform cannot be trusted long-term if it produces results without preserving the route by which it arrived at them.

---

## 9. Auditability Principle

The platform must be designed so that a knowledgeable reviewer can inspect the accounting chain without relying on hidden assumptions.

Auditability in this context means:

- financial evidence can be retrieved
- linked records can be followed
- interpretations can be inspected
- approvals can be reviewed
- accounting outcomes can be traced to sources
- exports can be tied back to underlying records
- period changes can be understood
- exceptions and overrides can be examined

The platform should not only store what happened. It should preserve enough context that what happened still makes sense later.

---

## 10. Audit Trail Requirements

The system must maintain an audit trail for all meaningful financial and control actions.

### Actions that should create audit events include
- document upload
- document replacement or versioning
- parsing start and completion
- extraction creation
- invoice creation
- invoice field correction
- transaction import
- transaction correction
- match creation
- match approval or rejection
- alert creation
- alert resolution
- review item resolution
- approval decisions
- posting events
- export generation
- integration sync events
- reporting period lock and unlock
- settings changes affecting accounting behavior

### Audit event contents should include
- actor type
- actor identity
- action type
- object type
- object identifier
- timestamp
- before state where relevant
- after state where relevant
- contextual metadata

The audit trail must be durable and queryable.

---

## 11. Human vs System Actor Separation

The audit model must distinguish clearly between human actors and system actors.

### Human actors may include
- founder
- reviewer
- accountant
- admin

### System actors may include
- parser process
- AI interpretation pipeline
- rules engine
- integration sync worker
- scheduled export job

### Why this matters
The platform must never produce an audit trail in which it is unclear whether a value was entered by a person, generated by AI, or created by a system rule.

This distinction is essential for trust and accountability.

---

## 12. Reviewability Requirement

The system must remain reviewable by humans.

Even if the product becomes highly automated, a reviewer must still be able to inspect:

- the source evidence
- the extracted values
- the suggested tax treatment
- the reason for any alert
- the approval or override decision
- the current accounting status
- the reporting period context

The platform should never force a reviewer to blindly trust hidden automation.

Reviewability is one of the strongest defenses against silent compliance drift.

---

## 13. Explainability Requirement

When the platform flags a problem or proposes a sensitive classification, it should be able to explain itself.

This requirement is especially important for:

- tax warnings
- duplicate detection warnings
- low-confidence extraction outcomes
- matching suggestions
- anomaly detection
- compliance-related alerts

The platform should be able to communicate:

- what triggered the issue
- what evidence was considered
- how confident the system is
- what the user is expected to do next

This requirement applies both to product design and to AI workflow design.

---

## 14. Retention Philosophy

Financial and tax-relevant records must be retained in a way that supports long-term review.

The software should assume that important evidence may need to be retrieved later for accounting review, tax review, operational disputes, or filing support.

Retention therefore applies not only to source documents, but also to:

- metadata about those documents
- linked invoice records
- linked transaction records
- approvals
- alerts
- exports
- period history
- audit events

The system should be designed with a retention-minded architecture from the start.

---

## 15. Retention Controls

The platform should support structured retention controls rather than ad hoc deletion behavior.

### Retention control expectations
- source evidence should not be easily deleted
- accounting-relevant records should remain preserved through the required review horizon
- deletion-sensitive actions should require elevated permissions
- deletion or archival behavior should be logged
- soft-delete behavior should be preferred over destructive deletion where accounting relevance exists
- retention decisions should be company-aware and policy-aware

### Important note
The exact legal retention durations and interpretations should ultimately be validated with a Cyprus tax professional, but the software architecture must already assume a serious long-term retention posture.

---

## 16. Readability Requirement

Preserved financial records must remain readable and retrievable.

This means the system must ensure that:

- files remain downloadable
- file formats remain accessible
- important financial content remains inspectable
- historical exports remain reconstructable
- evidence packs remain intelligible to a reviewer

There is little value in preserving an object that can no longer be meaningfully reviewed.

Readability is a compliance requirement in practice, not just a storage concern.

---

## 17. Data Reconstruction Requirement

The system must preserve enough information to reconstruct the accounting chain.

This means that for a given invoice or transaction, the platform should be able to reconstruct:

- the source evidence
- the parsing attempt
- the extraction result
- the rule checks applied
- any alerts or review items created
- the approval decision
- the final accounting outcome
- the reporting period association
- any export or filing-oriented output involving the record

This reconstruction capability is critical for debugging, accountant review, and formal scrutiny.

---

## 18. Accounting Change Control

Changes to accounting-relevant records must be controlled and visible.

### Examples of accounting-relevant changes
- invoice total correction
- tax code change
- contact reassignment
- due date correction
- category reassignment
- transaction amount correction
- match approval reversal
- reporting period reassignment

### Change control expectation
The platform should preserve:

- what changed
- who changed it
- when it changed
- why it changed where practical
- what the prior value was
- what the resulting value became

Accounting systems become dangerous when changes can happen without control context.

---

## 19. Approval Control Philosophy

Approvals should act as the formal bridge between interpretation and accounting truth.

### Approval control expectations
- sensitive outcomes should require explicit approval in early product phases
- approvals should be attributable to a human or trusted policy
- approvals should preserve the decision context
- approvals should remain historically inspectable
- rejected proposals should remain traceable where relevant

### Why this matters
A platform that uses AI for bookkeeping must never hide how uncertain interpretations became accepted accounting facts.

Approval history is not optional. It is part of the accounting trust model.

---

## 20. Policy-Based Automation Control

As the platform matures, more automation may become policy-driven. This requires compliance-aware control.

### The platform should support the concept of trusted policy automation
This means the system may automatically accept certain outcomes only if:

- confidence is above threshold
- no blocking rules fail
- no period restrictions apply
- no contradiction exists with prior records
- the company’s automation policy allows it

### Compliance requirement
Even when an outcome is automatically accepted, the system must still preserve:

- why it was auto-accepted
- under which policy it was accepted
- what rule checks were passed
- whether a human later changed it

Automation without policy traceability is not acceptable.

---

## 21. Tax Rule Review Philosophy

Tax-aware logic must be treated as review-sensitive rather than blindly final.

### The platform should detect and surface issues such as
- missing tax identifiers where relevant
- implausible tax rates
- missing mandatory invoice elements
- reverse-charge risk indicators
- inconsistent domestic versus international treatment
- unexpected exempt treatment
- period mismatch risk

### Important product rule
The system should prefer flagging suspicious tax outcomes over silently accepting them.

This creates safer bookkeeping behavior and protects the founder from false confidence.

---

## 22. Cyprus-Aware Rule Layer Expectations

The Cyprus-aware rule layer should be designed as a configurable and explainable control layer.

It should support:

- mandatory field checks relevant to VAT-sensitive documents
- tax rate plausibility logic
- invoice numbering anomaly detection
- period allocation warnings
- reporting-readiness checks
- filing blocker detection
- review escalation for uncertain cross-border or special-case treatments

The product should be designed so that jurisdiction-aware logic can evolve without requiring the entire architecture to be rewritten.

---

## 23. Period Control and Locking

The system must treat reporting periods as compliance control units.

### The platform should support
- open periods
- in-review periods
- locked periods
- exported periods
- adjusted periods where supported

### Locking principle
Once a period is reviewed and locked, the platform should restrict uncontrolled changes to records associated with that period.

### If changes after lock are allowed
They must require:

- explicit unlock or amendment path
- logged actor identity
- recorded reason
- audit visibility

Period control is one of the most important safeguards against accidental reporting drift.

---

## 24. Filing-Readiness Philosophy

The founder wants filing-oriented capability included in the long-term design.

This means the platform should not only support bookkeeping, but also support later preparation of filing-quality outputs.

### Filing-readiness means
- relevant records are period-aware
- tax-sensitive classifications are structured
- source evidence remains linked
- summaries can be reproduced
- accountant handoff is practical
- filing blockers can be surfaced before submission preparation

### Important note
The first product version does not need to perform direct tax submission. However, it must be built in a way that allows filing support to become a natural extension rather than a redesign.

---

## 25. Export Reproducibility Requirement

Exports must be reproducible and traceable.

If the platform generates a monthly export, accountant pack, invoice bundle, or filing-preparation package, the system should be able to explain:

- when the export was generated
- by whom or by which system process
- which filters or periods were used
- which records were included
- which underlying documents or summaries were referenced

This is necessary because exported outputs often become the artifacts that external reviewers actually use.

---

## 26. Accountant-Handoff Safety

The platform must be accountant-safe, not just founder-friendly.

This means an accountant or reviewer should be able to:

- inspect original documents
- inspect structured invoice and transaction data
- inspect alerts and review outcomes
- inspect approvals and overrides
- inspect period boundaries
- retrieve export packs
- understand where judgment calls were made

The platform should not trap accounting knowledge inside hidden AI logic that a reviewer cannot access.

---

## 27. Exception Management Requirement

Exceptions are a normal part of accounting operations and must be handled as first-class objects.

### Examples of exceptions
- low-confidence extraction
- duplicate invoice suspicion
- missing mandatory invoice field
- unmatched bank transaction
- conflicting contact identity
- suspicious tax treatment
- integration failure affecting bookkeeping completeness

### Compliance principle
Exceptions must be surfaced, tracked, and resolvable. They must not disappear silently because the platform wishes to appear smooth.

Good compliance design means making the difficult cases visible.

---

## 28. Integration Compliance Considerations

Integrations that ingest financial data must also preserve traceability.

### This means the system should preserve
- integration source identity
- sync timestamps
- external reference identifiers where relevant
- import status
- failure status
- retry visibility
- mapping from external source to internal record

This is especially important for transaction feeds because imported transactions become part of the accounting evidence chain.

---

## 29. Security as a Compliance Enabler

Security and compliance are not separate concerns in this product. Security architecture supports compliance outcomes.

### Compliance-supporting security expectations
- access is permission-aware
- file downloads are controlled
- secrets are stored securely
- tenant boundaries are enforced
- privileged actions are auditable
- evidence is protected against casual tampering

A weak security model would directly weaken the credibility of the accounting record environment.

---

## 30. Deletion Philosophy

The platform should be extremely careful with deletion behavior.

### Deletion rules should follow these principles
- source evidence should not be casually deletable
- accounting-relevant records should favor archival or soft deletion over destructive removal
- destructive deletion should be rare, permission-gated, and logged
- deleted states should preserve reconstruction where legally and operationally required

### Why this matters
Bookkeeping systems that allow easy destruction of accounting context quickly become untrustworthy.

---

## 31. Override Philosophy

Overrides are allowed, but they must be visible.

### Override examples
- user changes AI-suggested tax treatment
- user rejects a suggested invoice match
- user replaces a suggested counterparty
- user manually resolves a flagged anomaly

### Override requirement
The platform should preserve:

- what was originally suggested
- what was changed
- who changed it
- when it changed
- why it changed where relevant

Overrides are not a weakness. Hidden overrides are.

---

## 32. Compliance-Oriented Notification Behavior

Notifications should reinforce compliance control rather than merely create noise.

The system should notify or surface warnings when:

- mandatory source fields are missing
- a period is close-ready but blocked
- a suspicious tax treatment exists
- a review-sensitive issue remains unresolved
- an integration failure may have created incomplete bookkeeping
- an export was generated from sensitive data

The platform should ensure that important control issues are visible at the moment they matter.

---

## 33. Governance of Configuration Changes

Changes to company-level settings that affect accounting interpretation must be treated as compliance-sensitive.

### Examples of compliance-sensitive configuration changes
- VAT registration settings
- jurisdiction changes
- invoice numbering settings
- automation thresholds
- period definitions
- tax code configuration
- integration mapping behavior

### Governance requirement
These changes should be permission-controlled and auditable.

Configuration is not harmless. In accounting systems, configuration shapes outcomes.

---

## 34. Testing and Verification Direction

Compliance-oriented behavior must eventually be tested explicitly.

### Important testing directions include
- source preservation tests
- audit event generation tests
- period lock enforcement tests
- role-based access tests
- rule-trigger tests
- export reproducibility tests
- override traceability tests
- integration mapping traceability tests

The platform should not assume that compliance-oriented behavior will emerge naturally. It must be engineered and verified.

---

## 35. Non-Goals of This Document

This document does not define:

- the exact Cyprus legal interpretation of every tax scenario
- the exact retention duration implementation for every record type
- the exact database schema for audit and retention tables
- the exact user interface for review and compliance actions
- the exact text of future filing exports

Those details belong in later implementation documents and should be validated with professional tax input where necessary.

---

## 36. Compliance and Audit Summary

The platform must be built as a compliance-oriented accounting environment in which original evidence is preserved, AI interpretation remains distinguishable from approved truth, important changes are traceable, periods are controllable, exceptions are surfaced, exports are reproducible, and accountant review remains practical.

The product’s promise is not only that bookkeeping becomes easier. Its deeper promise is that bookkeeping becomes easier without losing integrity.

This document now serves as the compliance and audit reference for later state-machine work, phase-based development specifications, approval-flow design, and rule-engine design.

