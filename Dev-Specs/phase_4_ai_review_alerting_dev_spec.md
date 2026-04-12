# Phase 4 AI Review and Alerting Dev Spec

## 1. Document Purpose

This document defines the definitive Phase 4 development specification for the AI-native bookkeeping platform. It builds on Phase 1 Foundation, Phase 2 Invoice Engine, and Phase 3 Bank Reconciliation and introduces the first platform-wide AI review and alerting control layer.

Phase 4 is the point where the product stops behaving like a set of separate processing modules and begins behaving like a coordinated operational control system. The system already has invoice truth and reconciliation truth at narrower levels. This phase introduces generalized AI-driven prioritization, confidence-aware routing, risk-aware escalation, broader review queue behavior, alert lifecycle maturity, anomaly surfacing, and explanation-driven control workflows.

This phase is intentionally limited to review, alerting, anomaly handling, prioritization, and AI control behavior. It does not yet implement broad production-grade auto-approval, live bank integrations, final ledger posting, filing exports, or full dashboard intelligence.

The purpose of this phase is to create the platform layer that decides what needs human attention, why it needs attention, how urgent it is, and how the founder or reviewer should resolve it without losing traceability or control.

---

## 2. Phase Objective

The objective of Phase 4 is to unify the platform’s interpretation, validation, uncertainty, anomaly, and control signals into one coherent AI-assisted review system.

At the end of Phase 4, the system should support:

- a generalized review queue across invoices, transactions, matches, statements, and alerts
- confidence-aware and risk-aware routing
- AI explanation surfaces for suggestions and warnings
- broader alert generation and lifecycle handling
- anomaly detection across currently supported domains
- review prioritization by urgency, materiality, blockage, and tax sensitivity
- escalation behavior for unresolved or high-risk cases
- policy scaffolding for future automation control
- platform-level traceability for AI-assisted control decisions

At the end of Phase 4, the platform should behave like an intelligent operational reviewer that helps the founder focus only on what deserves attention.

---

## 3. Phase Boundary

### Included in Phase 4
Phase 4 includes the platform-wide AI review and alerting control layer.

### Excluded from Phase 4
Phase 4 explicitly excludes:

- broad production-grade policy-based auto-approval
- live Revolut integration
- generalized external banking connector framework
- final ledger posting logic
- filing exports
- period locking and amendment workflows
- mature dashboard analytics and executive reporting surfaces
- cross-channel notification expansion beyond core in-app delivery patterns
- full production governance model for autonomous bookkeeping

This boundary must remain strict. Phase 4 creates platform-wide control intelligence, not full autonomy and not final accounting closure.

---

## 4. Phase 4 Design Decisions

## 4.1 AI control posture

### Decision
Phase 4 introduces AI as a real platform-wide control and prioritization layer, but not yet as a broadly autonomous decision-maker.

### Meaning
AI in Phase 4 must support:

- confidence-aware interpretation handling
- review routing
- explanation generation
- anomaly surfacing
- prioritization across different object types
- escalation recommendation

AI in Phase 4 must not yet support:

- broad auto-approval of accounting truth
- broad auto-reconciliation without policy maturity
- silent resolution of tax-sensitive ambiguity
- silent suppression of meaningful review work

### Reason
The AI automation model explicitly requires progressive maturity. Phase 4 expands control intelligence while preserving strong human oversight.

---

## 4.2 Review posture

### Decision
Phase 4 introduces a generalized review system across all currently supported operational domains.

### Meaning
Review is no longer invoice-only or reconciliation-only. The system must support a single operational review layer that can surface work across:

- invoices
- invoice extraction outcomes
- statements
- transactions
- matches
- duplicate warnings
- approval blockers
- import failures and partial successes

### Required principle
The generalized review system must preserve the linked object context, not flatten everything into generic tickets with lost accounting meaning.

---

## 4.3 Alert posture

### Decision
Phase 4 introduces a mature platform-level alerting model for currently supported object types.

### Meaning
Alerts become a structured cross-domain signal layer rather than isolated invoice or bank warnings.

The system must support:

- alert categorization
- severity levels
- linked object context
- AI explanation context
- alert lifecycle management
- connection between alerts and review items when needed

### Important note
Phase 4 matures alerting within the product, but does not yet require external notification-channel complexity.

---

## 4.4 Confidence and risk posture

### Decision
Phase 4 operationalizes confidence and risk as routing inputs.

### Meaning
The platform must be able to use:

- extraction confidence
- classification confidence
- match confidence
- anomaly confidence
- risk level based on amount, tax sensitivity, period sensitivity, contradiction, and workflow impact

These signals must influence:

- whether a review item is created
- whether an alert is informational or blocking
- how work is prioritized
- whether escalation is required

### Important rule
Confidence and risk must remain separate concepts. High confidence does not automatically imply low risk.

---

## 4.5 Prioritization posture

### Decision
Phase 4 introduces platform-wide prioritization of review work.

### Meaning
The platform must be able to rank work across supported object types using signals such as:

- financial materiality
- tax sensitivity
- workflow blockage
- unresolved duration
- confidence shortfall
- contradiction severity
- import or processing failure impact

### Reason
The founder should not be forced to manually triage accounting uncertainty across disconnected modules.

---

## 4.6 Explanation posture

### Decision
Phase 4 operationalizes explanation surfaces for AI-driven suggestions, warnings, and routing outcomes.

### Meaning
The system must explain, in bounded human-readable form:

- what it believes
- why it believes that
- what evidence it used
- how confident it is
- why review is needed or not needed
- what action is recommended next

### Important note
This is not raw reasoning exposure. It is product-grade explainability intended for review and operational trust.

---

## 4.7 Escalation posture

### Decision
Phase 4 introduces explicit escalation behavior for unresolved, contradictory, or high-severity cases.

### Meaning
The system must support escalation when:

- a review item remains unresolved beyond meaningful thresholds
- risk is high enough that ordinary handling is insufficient
- repeated contradictions occur on the same object
- tax-sensitive ambiguity remains unresolved
- import or matching failures materially block bookkeeping progress

### Escalation outcome
Escalation may change severity, priority, routing target, or review-item state.

---

## 4.8 Automation posture

### Decision
Phase 4 introduces policy scaffolding for future automation, but not broad automation itself.

### Meaning
The system may start storing policy-relevant routing context and threshold readiness, but must not yet use that as the basis for wide autonomous approval behavior.

### Reason
The product needs mature review/alerting behavior before broader autonomy becomes safe.

---

## 5. Scope of Phase 4 Modules

## 5.1 Unified review queue

Phase 4 must implement a generalized review queue.

### Required supported object types
The queue must be able to surface review work from:

- invoice candidates
- approved invoices with contradictions or later issues where allowed
- statement imports
- transactions
- matches
- duplicate candidates
- alert-linked issues
- import and parsing partial-success outcomes

### Required behavior
- list open review items
- group or filter by object type, severity, status, and urgency
- sort by priority
- open underlying context from the queue
- preserve direct navigation to source evidence and object detail

### Required principle
The review queue must be a work center, not a disconnected ticket list.

---

## 5.2 Review routing engine

Phase 4 must implement generalized review routing logic.

### Required behavior
The routing layer must be able to decide whether an outcome:

- creates no review item
- creates a review item
- creates an alert only
- creates both an alert and a review item
- escalates an existing review path

### Required routing inputs
- confidence
- risk
- blocking rule failures
- unresolved contradictions
- duplicate risk
- tax sensitivity indicators
- period sensitivity indicators where available
- severity of downstream workflow impact

### Required principle
Routing outcomes must remain inspectable and auditable.

---

## 5.3 Alert engine maturity

Phase 4 must implement a platform-level alert engine for supported domains.

### Required alert categories
At minimum, the system must support alert categories for:

- extraction uncertainty
- validation blockers
- duplicate suspicion
- import failure or partial import
- reconciliation contradiction
- material unmatched transaction
- tax-sensitive ambiguity
- numbering conflict
- processing failure
- escalation condition

### Required alert fields
At minimum:

- company_id
- category
- severity
- title
- explanation
- linked_object_type
- linked_object_id
- status
- created_at
- acknowledged_at nullable
- resolved_at nullable

### Required behavior
- create alert
- acknowledge alert
- link alert to review item
- resolve alert
- dismiss alert
- expire alert where context becomes obsolete

---

## 5.4 Explanation surfaces

Phase 4 must implement explanation surfaces for supported AI-driven outcomes.

### Required explanation targets
- invoice extraction outcomes
- transaction classification outcomes
- match candidate outcomes
- duplicate suspicion outcomes
- review routing outcomes
- alert creation outcomes

### Required explanation content posture
Each explanation should be able to communicate:

- summary belief
- evidence basis
- confidence posture
- uncertainty or contradiction summary
- recommended next step

### Required principle
Explanations must be concise, helpful, and tied to concrete objects.

---

## 5.5 Anomaly detection layer

Phase 4 must implement anomaly surfacing across currently supported domains.

### Required anomaly domains
- invoice anomalies
- statement import anomalies
- transaction anomalies
- match and settlement anomalies
- duplicate patterns within supported domains

### Examples in scope
- inconsistent totals
- repeated numbering conflicts
- suspicious duplicate records
- contradictory settlement attempts
- repeated low-confidence supplier or contact recognition
- unexpected import patterns

### Important note
Phase 4 introduces anomaly surfacing, not a final mature anomaly intelligence platform.

---

## 5.6 Prioritization engine

Phase 4 must implement priority scoring for review work.

### Required prioritization inputs
- severity
- amount materiality
- tax sensitivity
- workflow blockage
- unresolved age
- confidence shortfall
- contradiction depth
- repeat recurrence

### Required behavior
- compute priority posture for review items
- enable review queue ordering
- support filtering for high-priority versus routine work

### Important rule
Priority should help humans work smarter, not obscure why an item matters.

---

## 5.7 Escalation handling

Phase 4 must implement escalation behavior across review and alert workflows.

### Required behavior
- escalate unresolved or severe review items
- escalate alerts when linked issues remain unresolved
- change review-item state to escalated where required
- preserve escalation reason
- preserve escalation timestamp
- preserve actor or policy source for escalation

### Required principle
Escalation must remain visible and auditable, not just a hidden priority bump.

---

## 5.8 Policy scaffolding for future automation

Phase 4 must introduce minimal policy scaffolding for future automation control.

### Required support
The platform should begin storing or supporting:

- threshold-ready confidence posture
- threshold-ready risk posture
- object-type-specific automation eligibility placeholders
- policy reasoning context for future auto-approval and auto-reconciliation decisions

### Important rule
This scaffolding must not yet enable broad production-grade autonomous approval.

---

## 5.9 AI control audit hardening

Phase 4 must deepen audit coverage around AI-assisted review and alerting control actions.

### Additional audit-covered actions
- review item created by routing engine
- review priority recalculated materially
- alert created by AI/rule combination
- explanation output attached or refreshed
- escalation triggered
- review item auto-linked to alert
- review item dismissed as non-issue
- alert expired due to context change

---

## 6. Required Phase 4 Data Model Changes

Phase 4 builds on earlier phases and requires the following entities in fully operational form:

- ReviewItem
- Alert
- ApprovalDecision
- Invoice
- Statement
- Transaction
- Match
- ExtractionResult
- ParsingRun

### Additional strongly recommended support structures
Phase 4 should introduce operational support structures such as:

- ReviewRoutingDecision or equivalent routing artifact model
- ExplanationArtifact or equivalent explanation model
- PriorityScoreSnapshot or equivalent prioritization artifact model
- EscalationRecord or equivalent escalation artifact model
- AnomalySignal or equivalent anomaly artifact model
- AutomationPolicyContext or equivalent future-control scaffold model

### Important modeling principle
The system must preserve the distinction between:
- underlying accounting object
- review work object
- alert signal object
- explanation object
- routing decision object
- escalation object

These must not be collapsed into one generic issue blob.

---

## 7. Phase 4 State Behavior

## 7.1 ReviewItem states in scope

Phase 4 continues and matures support for:
- open
- in_progress
- awaiting_input
- resolved
- dismissed
- escalated

### Additional Phase 4 rule
A review item may be escalated directly by routing logic or later due to unresolved duration or rising severity.

---

## 7.2 Alert states in scope

Phase 4 continues and matures support for:
- active
- acknowledged
- linked_to_review
- resolved
- dismissed
- expired

### Additional Phase 4 rule
An alert may transition to `linked_to_review` automatically when the platform determines a formal work item is required.

---

## 7.3 ApprovalDecision states in scope

Phase 4 continues support for:
- pending
- approved
- rejected
- superseded

### Important note
Phase 4 may create richer review and alert context around approvals, but does not broaden approval automation.

---

## 7.4 Underlying object states in scope

Phase 4 does not redefine the invoice, statement, transaction, match, or parsing lifecycles created in earlier phases.

### Required principle
Phase 4 must consume and interpret those states for control purposes, not replace or collapse them.

---

## 8. Required Backend Operations in Phase 4

Every critical backend operation must continue to follow the trusted mutation pattern:
1. authenticate request
2. validate tenant scope
3. validate permission
4. execute structured mutation
5. create audit event
6. return updated state

### Required backend operations
- generate review routing decision
- create review item from routed object
- update review priority materially
- attach explanation artifact to supported object
- create alert from AI/rule/control signal
- acknowledge alert
- resolve alert
- dismiss alert
- expire alert due to context change
- link alert to review item
- escalate review item
- escalate alert-linked issue
- record anomaly signal
- fetch unified review queue
- filter and sort review queue by priority, severity, status, and object type

---

## 9. Storage and Evidence Rules

Phase 4 continues all earlier evidence-preservation rules and adds AI-control-specific requirements.

### Required rules
- AI explanations must remain linked to the relevant object and evidence context
- routing decisions must not overwrite underlying accounting data
- anomaly signals must not replace underlying object truth
- escalation records must preserve prior state context
- dismissal of a review item or alert must remain traceable

### Important rule
AI control artifacts are not accounting truth. They are control-layer context and must remain separate from underlying evidence and approved accounting objects.

---

## 10. Security and Permission Rules

Phase 4 builds on earlier RBAC and introduces review-control-specific permissions.

### Founder and Admin
May:
- view full review queue
- resolve or dismiss review items
- acknowledge, resolve, or dismiss alerts
- escalate issues
- view explanations and anomaly context
- view review/control audit history

### Accountant
May:
- view review queue where allowed
- resolve review items where allowed
- acknowledge and resolve alerts where allowed
- view explanations and anomaly context
- view review/control audit history where allowed

### Reviewer
May:
- view assigned or visible review items
- resolve review items where allowed
- acknowledge alerts
- view explanations

May not by default:
- dismiss high-severity alerts permanently
- alter policy scaffolding
- view company-wide control history unless explicitly granted later

### Important implementation note
Permissions for dismissing or escalating high-severity issues should be stricter than permissions for viewing them.

---

## 11. Validation and Review Rules

## 11.1 Review creation rules

The platform must create or strongly suggest a review item when:
- confidence is materially below threshold on a required field or outcome
- risk is materially high relative to the object type
- contradictory interpretations remain unresolved
- a blocking validation failure requires human correction
- duplicate suspicion is material
- settlement ambiguity is material
- partial import or partial success creates unresolved accounting uncertainty

## 11.2 Alert creation rules

The platform must create an alert when:
- a processing failure occurs
- a validation blocker exists
- a material duplicate suspicion exists
- a materially unmatched transaction persists
- a tax-sensitive ambiguity is present
- an escalation condition is triggered
- a numbering conflict is detected
- a significant contradiction remains unresolved

## 11.3 Escalation rules

The platform must escalate when:
- a high-severity issue remains unresolved
- repeated failures or contradictions occur on the same linked object
- an unresolved blocker threatens period readiness or bookkeeping continuity
- a human resolution path has stalled meaningfully

## 11.4 Non-authoritative policy scaffolding

Risk scores, confidence scores, automation eligibility placeholders, and routing-policy context must not yet act as broad auto-approval authority in Phase 4.

---

## 12. Audit Requirements

Every meaningful AI-review and alerting control action must generate an audit event.

### Additional minimum audit contents where relevant
- originating object type and id
- routing decision summary
- explanation reference
- priority before and after materially relevant recalculation
- escalation reason
- alert severity before and after where changed
- actor identity or system-policy identity

### Minimum Phase 4 audit coverage
- routing decision created
- review item created
- priority materially recalculated
- alert created
- alert acknowledged
- alert resolved
- alert dismissed
- alert expired
- explanation attached or refreshed
- escalation triggered
- review item dismissed or resolved
- anomaly signal created or resolved

---

## 13. Acceptance Criteria

Phase 4 is complete only when all of the following are true:

1. The system can create and manage review items across invoices, statements, transactions, matches, and related control signals.
2. The system can generate a unified review queue with filtering and prioritization.
3. The system can generate alerts across supported domains with category, severity, explanation, and lifecycle state.
4. The system can generate bounded explanation artifacts for supported AI-driven outcomes.
5. The system can use confidence and risk posture to influence routing and prioritization.
6. The system can escalate unresolved or high-severity issues visibly and audibly within the product.
7. Review items, alerts, explanations, and anomaly signals remain linked to their underlying object context.
8. No Phase 4 feature silently resolves meaningful accounting uncertainty into approved truth.
9. No Phase 4 feature collapses review work, alert signals, explanations, and underlying accounting objects into one uncontrolled record.
10. All critical review-control actions are auditable.
11. The founder can use the product to focus on meaningful exceptions rather than manually searching for problems across modules.
12. No Phase 4 feature implements broad autonomous approval, live bank sync, final ledger posting, or filing behavior under the AI-control label.

---

## 14. Items Explicitly Deferred After Phase 4

The following remain out of scope after this phase and must be handled in later dev-specs:

- broad policy-based auto-approval
- broad policy-based auto-reconciliation
- live Revolut integration
- generalized external banking connector framework
- final ledger posting logic
- filing exports
- period locking and amendment
- mature dashboard analytics and executive reporting
- cross-channel notification expansion
- full autonomous bookkeeping governance model
- Cyprus tax-rule completeness

---

## 15. Implementation Order Recommendation

The recommended implementation order inside Phase 4 is:

1. generalized review queue foundation
2. review routing artifact model and routing logic
3. alert engine maturity and lifecycle handling
4. explanation artifact model and explanation surfaces
5. prioritization logic and queue ordering
6. anomaly signal support across supported domains
7. escalation logic and audit hardening
8. policy scaffolding for later automation phases

This sequence ensures that the platform first becomes able to collect and route meaningful work before it becomes more sophisticated in prioritization and future automation readiness.

---

## 16. Final Phase 4 Summary

Phase 4 turns the platform from a set of domain workflows into a coordinated AI-assisted control system. It introduces a unified review queue, a platform-level alert engine, bounded explanations, anomaly surfacing, prioritization, escalation, and policy scaffolding for future automation.

At the end of this phase, the platform will be able to tell the founder what matters, why it matters, and what to do next, while still stopping short of broad autonomy, live integrations, final posting, and filing behavior. That boundary is intentional and necessary for maintaining trust and operational clarity.

