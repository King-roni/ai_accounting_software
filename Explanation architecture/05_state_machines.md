# State Machines

## 1. Document Purpose

This document defines the major state machines that govern how key entities move through the bookkeeping platform. It describes the lifecycle logic of core objects, the meaning of each state, the allowed transitions between states, and the control principles that determine when a transition is valid.

The purpose of this document is to prevent the system from evolving into ad hoc status fields and inconsistent workflow logic. Each important operational object in the platform must move through explicit, reviewable, and auditable lifecycle states.

This document builds on the master blueprint, the domain model, the system architecture, the compliance and audit model, and the AI automation model.

---

## 2. State Machine Philosophy

The platform is designed as an operational accounting environment, not a loose set of CRUD records. That means important objects must behave predictably over time.

A state machine in this product is not just a UI convenience. It is a control mechanism. It determines:

- where an object currently sits in its lifecycle
- what has already happened to it
- what may happen next
- which transitions require review or approval
- which transitions are blocked by policy, rules, or period controls
- which transitions must create audit events

State machines exist to protect integrity, reduce ambiguity, and support automation without chaos.

---

## 3. General State Machine Principles

The following principles apply across all state machines in the platform.

### 3.1 Explicit state ownership
Each important object must have one primary lifecycle state at a time.

### 3.2 No silent transitions
State changes must happen through explicit actions, workflows, or policies rather than invisible mutation.

### 3.3 Auditability
Every meaningful transition must be auditable.

### 3.4 Rule-aware transitions
Transitions may be blocked by missing fields, failed validations, lock states, or policy restrictions.

### 3.5 Human-review sensitivity
Some transitions may happen automatically, while others must require review or explicit approval depending on risk and confidence.

### 3.6 Recoverability
Where practical, the state model should support recovery from failure or exception states without destroying traceability.

### 3.7 Separation of object lifecycles
A document, invoice, transaction, and alert may be related, but they do not share the same lifecycle. Each object type needs its own state machine.

---

## 4. Document State Machine

### Purpose
The document state machine governs the lifecycle of source evidence files and generated financial documents.

### Core states

#### uploaded
The document has been received and preserved in storage but has not yet been processed.

#### queued_for_processing
The document has been accepted into a processing workflow and is waiting for parsing or classification.

#### processing
The document is currently being parsed, classified, or analyzed.

#### processed
The machine-processing pipeline has completed and interpretation outputs exist.

#### needs_review
The document or its derived interpretation requires human inspection before downstream acceptance.

#### linked
The document has been linked to one or more structured accounting objects.

#### archived
The document remains preserved but is no longer active in current workflow handling.

#### failed_processing
The document could not be processed successfully and requires retry or manual handling.

### Typical transitions
- uploaded → queued_for_processing
- queued_for_processing → processing
- processing → processed
- processing → failed_processing
- processed → needs_review
- processed → linked
- needs_review → linked
- linked → archived
- failed_processing → queued_for_processing

### Transition notes
A document may move to linked only when the system has successfully created or associated a meaningful downstream object, or when a human has confirmed the relevant linkage.

A document should never lose its preserved status even if processing fails.

---

## 5. Parsing Run State Machine

### Purpose
The parsing run state machine governs each machine-processing attempt on a source object.

### Core states

#### pending
A parsing run record exists but has not started.

#### running
The parsing attempt is actively executing.

#### succeeded
The parsing attempt completed successfully and produced output.

#### partially_succeeded
The parsing attempt completed with usable output but also with gaps, warnings, or confidence problems.

#### failed
The parsing attempt completed unsuccessfully.

#### cancelled
The parsing attempt was intentionally stopped or invalidated.

### Typical transitions
- pending → running
- running → succeeded
- running → partially_succeeded
- running → failed
- pending → cancelled
- running → cancelled

### Transition notes
Multiple parsing runs may exist over time for one document, especially if retry, model upgrades, or manual reprocessing are introduced.

The parsing run state machine is attempt-level, not object-level.

---

## 6. Extraction Result State Machine

### Purpose
The extraction result state machine governs the lifecycle of a machine-generated interpretation artifact.

### Core states

#### generated
The extraction result has been created by a parser or AI pipeline.

#### validated
The extraction result has passed normalization and deterministic validation steps.

#### flagged
The extraction result contains uncertainty, missing information, contradiction, or rule-sensitive issues.

#### accepted_for_review
The extraction result is ready to be used in a human review flow.

#### superseded
A newer or corrected extraction result has replaced it as the current active interpretation.

#### rejected
The extraction result was explicitly rejected as unsuitable.

### Typical transitions
- generated → validated
- generated → flagged
- validated → accepted_for_review
- flagged → accepted_for_review
- accepted_for_review → superseded
- accepted_for_review → rejected
- validated → superseded
- flagged → superseded

### Transition notes
An extraction result should never become final accounting truth by itself. It remains an interpretation artifact until an approval or policy-controlled transition occurs elsewhere.

---

## 7. Invoice State Machine

### Purpose
The invoice state machine governs the lifecycle of a structured invoice record, whether incoming or outgoing.

### Core states

#### draft
The invoice exists as an incomplete or pre-final accounting object.

#### extracted
The invoice has been created from machine interpretation or draft generation, but has not yet been validated.

#### validated
The invoice has passed structural checks and is internally coherent enough for workflow progression.

#### needs_review
The invoice requires human review because of uncertainty, policy, or compliance sensitivity.

#### approved
The invoice has been accepted as an accounting-valid record.

#### posted
The invoice has been formally accepted into downstream accounting and period-aware logic.

#### partially_paid
The invoice has been matched to one or more payments, but not in full.

#### paid
The invoice has been fully settled.

#### disputed
The invoice is under correction, dispute, or unresolved contradiction.

#### voided
The invoice is no longer operationally active because it was cancelled or invalidated.

#### archived
The invoice is preserved historically but not part of active handling.

### Typical transitions
- draft → extracted
- extracted → validated
- extracted → needs_review
- validated → approved
- validated → needs_review
- needs_review → approved
- approved → posted
- posted → partially_paid
- partially_paid → paid
- posted → paid
- posted → disputed
- disputed → needs_review
- approved → voided
- posted → archived
- paid → archived
- voided → archived

### Transition notes
Outgoing invoices may begin in draft through internal generation, while incoming invoices may begin in extracted after document processing.

The approved → posted distinction is important. Approval means the invoice is accepted; posting means the invoice has entered the operational accounting chain.

A paid invoice remains historically visible and should not collapse into a hidden terminal condition.

---

## 8. Invoice Payment Status Layer

### Purpose
Because payment progression is important enough to deserve separate handling, invoices should conceptually have a payment-status sub-layer even if the implementation remains inside the invoice model.

### Payment states
- unpaid
- partially_paid
- paid
- overpaid
- refunded
- write_off_candidate

### Why this matters
A structurally valid invoice can still have multiple financial settlement conditions. Separating lifecycle state from payment condition avoids confusion.

---

## 9. Outgoing Invoice Generation State Machine

### Purpose
This state machine governs invoices created inside the platform for company billing.

### Core states

#### drafting
The outgoing invoice is being prepared by a user or template.

#### generated
The invoice content and number have been generated.

#### issued
The invoice is considered officially issued and preserved as evidence.

#### delivered
The invoice has been sent or made available externally.

#### overdue
The invoice remains unpaid beyond expected due date.

#### settled
The invoice has been fully paid.

#### credited
The invoice has been fully or partially offset by credit note logic.

#### cancelled
The invoice was invalidated before operational completion.

### Typical transitions
- drafting → generated
- generated → issued
- issued → delivered
- delivered → overdue
- delivered → settled
- overdue → settled
- delivered → credited
- overdue → credited
- generated → cancelled
- issued → cancelled where policy allows

### Transition notes
This state machine coexists with the broader invoice lifecycle and represents the commercial generation process rather than only the accounting posture.

---

## 10. Statement State Machine

### Purpose
The statement state machine governs the lifecycle of uploaded or imported bank statement records.

### Core states

#### received
The statement file or source payload has entered the system.

#### queued_for_import
The statement is waiting to be processed.

#### importing
The statement is actively being parsed and converted into transaction candidates.

#### imported
The statement has produced normalized transaction records.

#### needs_review
The statement produced warnings, gaps, or inconsistencies that require human inspection.

#### reconciled_ready
The statement is sufficiently clean for transaction-level reconciliation workflows.

#### archived
The statement remains preserved but is no longer active in current processing.

#### failed_import
The statement import attempt failed.

### Typical transitions
- received → queued_for_import
- queued_for_import → importing
- importing → imported
- importing → failed_import
- imported → needs_review
- imported → reconciled_ready
- needs_review → reconciled_ready
- reconciled_ready → archived
- failed_import → queued_for_import

### Transition notes
A statement does not become reconciled in the same sense as transactions. The statement mainly acts as a source container and readiness unit.

---

## 11. Transaction State Machine

### Purpose
The transaction state machine governs the lifecycle of normalized financial movement records.

### Core states

#### imported
The transaction has entered the internal model from a statement or integration source.

#### normalized
The transaction has been standardized and is ready for interpretation.

#### classified
The transaction has received a likely category or accounting meaning.

#### needs_review
The transaction cannot safely proceed without human input.

#### match_candidate
The system believes one or more likely relationships exist but none are yet final.

#### matched
The transaction has been linked to a financial object or set of objects.

#### reconciled
The transaction has been accepted as fully resolved within the accounting flow.

#### exception_flagged
The transaction is blocked by contradiction, anomaly, or unresolved issue.

#### archived
The transaction is historically preserved and no longer operationally active.

### Typical transitions
- imported → normalized
- normalized → classified
- normalized → needs_review
- classified → match_candidate
- classified → needs_review
- match_candidate → matched
- matched → reconciled
- matched → needs_review
- needs_review → classified
- needs_review → matched
- classified → exception_flagged
- match_candidate → exception_flagged
- exception_flagged → needs_review
- reconciled → archived

### Transition notes
A matched transaction is not automatically reconciled. Reconciliation should indicate that the financial movement is sufficiently resolved for accounting purposes.

---

## 12. Match State Machine

### Purpose
The match state machine governs the lifecycle of relationships proposed or accepted between invoices and transactions.

### Core states

#### proposed
A likely match has been identified by the system.

#### under_review
The proposed match is being evaluated by a human or control policy.

#### accepted
The match has been accepted as a valid relationship.

#### partially_applied
The match is valid but only resolves part of the financial amount or obligation.

#### rejected
The proposed match was determined to be incorrect.

#### superseded
The match is no longer active because a better or corrected match replaced it.

### Typical transitions
- proposed → under_review
- proposed → accepted under policy
- proposed → rejected
- under_review → accepted
- under_review → rejected
- accepted → partially_applied
- partially_applied → accepted when final settlement completes
- accepted → superseded
- rejected → superseded if later replaced conceptually

### Transition notes
A match object should preserve whether acceptance came from a human or policy path.

Match state is distinct from transaction state and invoice payment state.

---

## 13. Review Item State Machine

### Purpose
The review item state machine governs human work units created by uncertainty, compliance concerns, or unresolved workflow issues.

### Core states

#### open
The review item has been created and is awaiting action.

#### in_progress
A human has begun working on the item.

#### awaiting_input
The item cannot be resolved yet because additional information or external clarification is required.

#### resolved
The issue has been handled and no further action is currently required.

#### dismissed
The item has been intentionally closed without substantive action because it was deemed non-issue, duplicate, or obsolete.

#### escalated
The review item requires higher-authority or specialized handling.

### Typical transitions
- open → in_progress
- open → dismissed
- in_progress → awaiting_input
- in_progress → resolved
- in_progress → escalated
- awaiting_input → in_progress
- escalated → in_progress
- escalated → resolved

### Transition notes
A resolved review item should preserve the resolution note or action path.

Dismissal should be used carefully and remain auditable.

---

## 14. Alert State Machine

### Purpose
The alert state machine governs surfaced warnings and system signals.

### Core states

#### active
The alert is currently relevant and unresolved.

#### acknowledged
A user has seen the alert and accepted awareness of it.

#### linked_to_review
The alert has been converted into or linked to a formal review process.

#### resolved
The alert condition is no longer active.

#### dismissed
The alert was intentionally dismissed as non-actionable or duplicate.

#### expired
The alert is no longer relevant because the context has passed.

### Typical transitions
- active → acknowledged
- active → linked_to_review
- active → resolved
- acknowledged → linked_to_review
- acknowledged → resolved
- linked_to_review → resolved
- active → dismissed
- acknowledged → dismissed
- active → expired

### Transition notes
An alert may be resolved indirectly when the underlying object transitions into a compliant or accepted state.

An alert is not always a task, which is why alerts and review items remain distinct.

---

## 15. Approval Decision State Machine

### Purpose
The approval decision state machine governs formal acceptance or rejection events for sensitive outcomes.

### Core states

#### pending
A reviewable outcome is waiting for approval.

#### approved
The outcome has been accepted.

#### rejected
The outcome has been rejected.

#### superseded
The decision is no longer current because a later decision replaced the context.

### Typical transitions
- pending → approved
- pending → rejected
- approved → superseded
- rejected → superseded

### Transition notes
Approval decisions are event-like objects, so their lifecycle is simpler than long-lived domain objects.

---

## 16. Ledger Entry State Machine

### Purpose
The ledger entry state machine governs accounting posting outcomes.

### Core states

#### draft
The ledger entry has been created but not finalized.

#### ready_to_post
The ledger entry is complete enough for posting.

#### posted
The entry has been accepted into the accounting record.

#### adjusted
The entry remains valid historically but has been followed by corrective or adjusting action.

#### reversed
The entry has been reversed through valid accounting workflow.

#### locked
The entry belongs to a locked period and can no longer be freely changed.

### Typical transitions
- draft → ready_to_post
- ready_to_post → posted
- posted → adjusted
- posted → reversed
- posted → locked
- adjusted → locked
- reversed → locked

### Transition notes
Locked does not mean the entry disappears from accounting visibility. It means its mutability is constrained by period controls.

---

## 17. Reporting Period State Machine

### Purpose
The reporting period state machine governs the lifecycle of accounting periods.

### Core states

#### open
The period is active and normal processing is allowed.

#### under_review
The period is being checked for completeness, exceptions, and close readiness.

#### ready_to_lock
The period appears operationally complete and is ready for final control.

#### locked
The period has been formally closed for uncontrolled changes.

#### exported
A structured output or filing-oriented package has been generated from the period context.

#### amended
A locked or exported period has undergone a controlled adjustment workflow.

### Typical transitions
- open → under_review
- under_review → ready_to_lock
- ready_to_lock → locked
- locked → exported
- locked → amended
- exported → amended
- amended → locked

### Transition notes
A period should not move to ready_to_lock while unresolved critical alerts or blocking review items remain.

Amendment must remain controlled, exceptional, and auditable.

---

## 18. Export Job State Machine

### Purpose
The export job state machine governs package-generation workflows.

### Core states

#### requested
The export has been requested.

#### preparing
The system is assembling records and files.

#### generated
The export artifact has been successfully created.

#### failed
The export process failed.

#### downloaded
The generated export has been accessed.

#### expired
The export artifact is no longer available through active delivery path.

### Typical transitions
- requested → preparing
- preparing → generated
- preparing → failed
- generated → downloaded
- generated → expired
- failed → requested for retry

### Transition notes
The export job state concerns delivery lifecycle, not the legal validity of included records.

---

## 19. Integration Connection State Machine

### Purpose
The integration connection state machine governs external source connectivity.

### Core states

#### unconfigured
The integration exists conceptually but has not been set up.

#### configuring
Credentials or setup are in progress.

#### active
The integration is configured and operational.

#### syncing
The integration is actively exchanging data.

#### degraded
The integration remains connected but has errors or incomplete behavior.

#### disconnected
The integration is no longer operational.

#### revoked
The connection was intentionally disabled or permission was removed.

### Typical transitions
- unconfigured → configuring
- configuring → active
- active → syncing
- syncing → active
- active → degraded
- degraded → active
- active → disconnected
- degraded → disconnected
- disconnected → configuring
- active → revoked
- disconnected → revoked

### Transition notes
Integration state should be visible because bookkeeping completeness may depend on it.

---

## 20. Notification Delivery State Machine

### Purpose
This optional state machine governs the operational delivery lifecycle of notifications themselves.

### Core states
- queued
- delivered
- failed
- read
- archived

### Why this matters
Notifications are not the same as alerts. An alert is a business signal. A notification is a delivery attempt.

This distinction may become important as the product expands notification channels.

---

## 21. Cross-State Dependencies

Although each object has its own lifecycle, important dependencies exist.

### Examples
- a document cannot become meaningfully linked until processing yields a usable result or a human links it manually
- an invoice should not become approved if blocking validation or review conditions remain unresolved
- a transaction should not become reconciled unless match or classification conditions are sufficiently complete
- a reporting period should not become ready_to_lock while critical open review items exist
- an export may be blocked by period or permission state
- alerts may resolve automatically when underlying objects move into acceptable states

These dependency rules should later be made explicit in implementation specs.

---

## 22. Automatic vs Manual Transitions

Not all transitions should be triggered the same way.

### Automatically triggered transitions may include
- uploaded → queued_for_processing
- queued_for_processing → processing
- processing → processed
- imported → normalized
- proposed → accepted under trusted policy
- open period → under_review via scheduled close workflow

### Human-triggered transitions may include
- needs_review → approved
- under_review → resolved
- ready_to_lock → locked
- rejected or superseded workflow actions
- override-sensitive transitions

### Mixed-control transitions may include
- auto-accept under policy with later human override possible
- alert resolution driven by underlying system fix and then confirmed by user experience logic

This distinction matters for dev-spec precision and audit design.

---

## 23. Transition Guard Conditions

Many transitions should only occur when guard conditions are satisfied.

### Common guard condition examples
- required fields are present
- no blocking rule failures exist
- tenant context is valid
- actor has permission
- reporting period is open or amendment path exists
- confidence and risk thresholds permit automation
- no contradictory active match exists
- source evidence still exists and is linked correctly

Guard conditions are critical because they turn state machines into real control systems instead of decorative labels.

---

## 24. Audit Expectations for State Changes

The following expectations should apply whenever meaningful state changes occur:

- the transition should be logged
- the actor should be recorded
- the object identity should be recorded
- the old state and new state should be recorded
- contextual metadata should be preserved where useful
- policy-triggered transitions should remain attributable to policy logic

This is especially important for approval, posting, reconciliation, period locking, and exception resolution.

---

## 25. State Machine Design Warnings

The following anti-patterns should be avoided during implementation.

### Anti-pattern 1: overloaded statuses
One status field should not try to represent processing state, review state, payment state, and archival state all at once.

### Anti-pattern 2: hidden terminal states
Objects should not vanish into ambiguous states that hide whether they were completed, failed, rejected, or archived.

### Anti-pattern 3: silent correction transitions
A system should not quietly move an object into a clean state without preserving how the correction occurred.

### Anti-pattern 4: irreversible destructive state handling
Failure or rejection states should generally remain recoverable or historically visible.

### Anti-pattern 5: mixing evidence state and accounting state
A document lifecycle and an invoice lifecycle should not be collapsed into one field.

Avoiding these anti-patterns will make the later dev-specs much stronger.

---

## 26. State Machine Summary

The platform relies on explicit lifecycle control for documents, parsing runs, extraction artifacts, invoices, statements, transactions, matches, review items, alerts, approvals, ledger entries, reporting periods, exports, and integrations.

These state machines provide the operational skeleton of the system. They make automation safer, review clearer, audit trails stronger, and later development specifications much more coherent.

This document now serves as the lifecycle reference for the next layer of work: the phase-based development specifications and any later transition tables or event-driven implementation plans.

