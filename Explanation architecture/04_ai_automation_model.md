# AI Automation Model

## 1. Document Purpose

This document defines how AI should operate inside the bookkeeping platform. It explains the role of AI, the boundaries of AI authority, the trust model, the interpretation pipeline, the confidence model, the review model, the escalation logic, and the progression from human-in-the-loop workflows toward increasingly autonomous bookkeeping.

The purpose of this document is to ensure that AI is treated as a controlled accounting operator rather than an uncontrolled black box. AI is central to the value of the product, but it must work inside explicit system boundaries that preserve accounting integrity, reviewability, and compliance-oriented behavior.

This document builds on the master blueprint, domain model, system architecture, and compliance-and-audit model.

---

## 2. AI Philosophy

The platform is not using AI as a cosmetic feature. AI is a core operating layer of the product.

AI exists to reduce bookkeeping friction by taking on the interpretation-heavy and decision-support-heavy work that normally consumes time and attention. This includes understanding documents, reading transactions, suggesting classifications, finding links between records, surfacing anomalies, and prioritizing what requires human review.

However, the platform must never confuse AI usefulness with AI authority.

AI should be powerful, but controlled.
AI should be explainable, but not trusted blindly.
AI should accelerate accounting operations, but not erase the distinction between suggestion and approved truth.

---

## 3. Core AI Objective

The core objective of the AI layer is to move the founder from manual bookkeeping toward exception-based oversight.

In practical terms, AI must help the founder reach a state where:

- most incoming financial evidence is automatically understood
- most routine classifications are automatically proposed
- most likely matches are automatically suggested
- suspicious or uncertain outcomes are surfaced early
- human time is spent only on ambiguity, risk, and final control

Over time, the platform should evolve from AI-assisted bookkeeping to AI-operated bookkeeping with human supervision and then to AI-operated bookkeeping with exception-driven intervention.

---

## 4. AI Boundaries

AI must operate within clear product and trust boundaries.

### AI should do the following
- extract
- classify
- normalize
- suggest
- rank
- compare
- explain
- detect anomalies
- route work
- recommend actions

### AI should not do the following without approved policy
- silently finalize high-risk accounting outcomes
- silently overwrite approved records
- silently resolve tax-sensitive ambiguity
- silently hide low-confidence outputs
- silently bypass period restrictions
- silently erase source uncertainty

The platform must always know where AI ended and where a system rule or human decision took over.

---

## 5. AI Trust Model

The platform must preserve a structured AI trust model.

### 5.1 Source truth
This is the original financial evidence or imported transaction source.

### 5.2 AI interpretation
This is the machine-generated understanding of the source. It may include extracted fields, classifications, suggested tax treatment, match candidates, anomaly signals, and explanations.

### 5.3 Approved accounting truth
This is the human-approved or policy-approved accounting state that the platform treats as operational truth.

### Key principle
AI interpretation is valuable, but it is not automatically equivalent to approved truth.

This distinction is the central safety mechanism of the product.

---

## 6. Core AI Responsibilities

The AI layer should support the following operational responsibilities.

### 6.1 Document understanding
AI should identify whether a document is likely an incoming invoice, outgoing invoice, credit note, debit note, bank statement, or supporting financial document.

### 6.2 Field extraction
AI should extract structured values such as:

- invoice number
- invoice date
- due date
- supplier or customer identity
- amounts
- tax amounts
- line items where possible
- currency
- payment references

### 6.3 Contact recognition
AI should identify likely counterparties by comparing extracted or imported information against existing contacts and prior patterns.

### 6.4 Categorization
AI should suggest accounting categories, internal expense groupings, and other structural classifications.

### 6.5 Tax treatment suggestion
AI should suggest plausible tax treatment based on document content, transaction context, company settings, and rule-engine feedback.

### 6.6 Matching and reconciliation support
AI should identify likely relationships between invoices and transactions, including probable settlements, partial payments, grouped payments, and ambiguous candidates.

### 6.7 Anomaly detection
AI should identify suspicious patterns, unusual classifications, duplicate risks, inconsistencies, or unexpected combinations of values.

### 6.8 Review prioritization
AI should help determine what requires attention first by ranking risk, uncertainty, and operational importance.

### 6.9 Explanation generation
AI should help explain why a suggestion, alert, or uncertainty exists in language that is understandable to the founder or reviewer.

---

## 7. AI Operating Modes

The platform should support progressive AI operating modes.

### 7.1 Assist mode
In this mode, AI proposes outcomes and humans review most meaningful decisions.

### 7.2 Supervised automation mode
In this mode, AI may automatically process low-risk, high-confidence cases within policy boundaries, while uncertain or sensitive cases are routed to review.

### 7.3 Exception-driven autonomous mode
In this mode, AI handles the majority of bookkeeping operations and humans mainly handle flagged exceptions, policy changes, or sensitive anomalies.

### Important principle
The product should not jump directly to the third mode. Trust must be earned through system performance, review quality, and policy confidence.

---

## 8. AI Capability Areas

The AI layer should be designed as several cooperating capability areas rather than one vague intelligence block.

### 8.1 Extraction capability
Converts raw evidence into candidate structured data.

### 8.2 Interpretation capability
Transforms extracted data into candidate accounting meaning.

### 8.3 Matching capability
Finds likely links between records.

### 8.4 Detection capability
Finds anomalies, conflicts, duplicates, and suspicious outcomes.

### 8.5 Explanation capability
Expresses reasoning outcomes in human-readable form.

### 8.6 Prioritization capability
Ranks work and risk.

This separation helps later implementation and evaluation.

---

## 9. AI Pipeline Model

A typical AI pipeline should follow a controlled multi-step pattern.

### Step 1: source intake
A source document or transaction enters the system.

### Step 2: source preparation
Content is prepared for machine processing.

### Step 3: machine extraction
AI or parser systems extract candidate structured values.

### Step 4: machine interpretation
The system infers what the extracted data likely means in bookkeeping terms.

### Step 5: normalization
The machine outputs are normalized into internal candidate structures.

### Step 6: deterministic rule validation
The rules engine checks required fields, plausibility, policy restrictions, and control logic.

### Step 7: confidence and risk scoring
The platform evaluates whether the candidate outcome appears safe, uncertain, contradictory, or suspicious.

### Step 8: routing decision
The result is either:

- sent to review
- accepted under policy
- partially accepted with alerting
- blocked pending correction

### Step 9: audit and explanation capture
The system stores what AI proposed, how confident it was, and why the outcome was routed the way it was.

This pipeline should remain explicit and observable.

---

## 10. Confidence Model

The platform should treat confidence as a structured operational signal, not as a decorative number.

Confidence should help determine:

- whether a machine output is usable
- whether a review item should be created
- whether a human must approve
- whether an automated path is allowed
- whether extra warnings should be shown

### Confidence should exist at multiple levels
- field-level confidence
- object-level confidence
- workflow-level confidence
- match-level confidence
- anomaly-level confidence

### Why this matters
A document can have high confidence for date extraction but low confidence for supplier identification. A transaction can have high confidence for amount normalization but low confidence for categorization. A match can have medium confidence even if the underlying transaction data is clean.

The confidence model must be granular.

---

## 11. Confidence Dimensions

Confidence should not come from one source only. It should reflect multiple dimensions.

### Possible dimensions include
- extraction clarity
- source quality
- completeness of required fields
- internal consistency
- historical pattern similarity
- contact recognition strength
- rule-engine conflicts
- contradiction with prior records
- ambiguity in tax interpretation
- ambiguity in matching relationships

### Design principle
Confidence should reflect not only what AI thinks, but how well the system as a whole believes the candidate outcome fits the accounting context.

---

## 12. Risk Model

Confidence alone is not enough. The platform also needs a separate risk model.

### Why risk matters
A high-confidence suggestion may still be high-risk if it affects tax treatment, reporting period assignment, or a large amount of money. A low-risk item may be acceptable for automation even at moderate confidence if it has limited financial consequence.

### Risk considerations should include
- tax sensitivity
- amount size
- reporting period impact
- likelihood of duplicate consequence
- effect on filing outputs
- policy sensitivity
- whether the result changes a locked period
- whether the result creates downstream accounting consequences

### Core principle
Automation decisions should consider both confidence and risk.

---

## 13. Review Routing Model

The AI layer must route work intelligently.

### A candidate result should be sent to review when
- confidence is below threshold
- risk is above threshold
- a blocking rule fails
- a policy restriction applies
- a contradiction exists with prior approved truth
- the object falls into a review-mandatory category
- the period state disallows auto-processing

### A candidate result may be auto-processed when
- confidence is above threshold
- risk is low enough
- no blocking rules fail
- no contradiction exists
- policy allows auto-processing
- the object is in an automation-safe state

This routing logic is the bridge between AI capability and accounting safety.

---

## 14. Human-in-the-Loop Model

The first version of the platform must use a strong human-in-the-loop model.

### This means
- AI proposes, humans inspect
- AI explains, humans confirm
- AI flags, humans resolve
- AI matches, humans approve where needed
- AI suggests tax treatment, humans approve sensitive outcomes

### Product principle
Human-in-the-loop is not a temporary inconvenience. It is the trust-building layer that teaches the platform where its automation boundaries can later expand.

---

## 15. Policy-Based Auto-Approval Model

Over time, the product should allow policy-based auto-approval for safe categories of work.

### Auto-approval may be allowed when
- the workflow type is approved for automation
- the confidence score is high enough
- the risk score is low enough
- no critical rule violations exist
- no prior contradiction exists
- the relevant period is open and automation-eligible
- the company policy explicitly allows it

### Auto-approval must still preserve
- the policy used
- the threshold context
- the AI output
- the validation outcome
- the audit event

Auto-approval is acceptable only when the system can explain why it happened.

---

## 16. AI Explanation Model

Every meaningful AI suggestion or warning should be explainable.

### Explanation should answer
- what the AI believes
- why it believes that
- what evidence it used
- how confident it is
- what uncertainty remains
- what the user should do next

### Explanation types may include
- extraction explanation
- classification explanation
- match explanation
- anomaly explanation
- tax treatment explanation
- review-routing explanation

### Design principle
The platform should not expose raw chain-of-thought style internals. It should expose useful, bounded, review-friendly explanations.

---

## 17. AI Extraction Model

The extraction subsystem should convert source evidence into structured candidate values.

### It should support
- date extraction
- identity extraction
- amount extraction
- tax field extraction
- currency extraction
- reference extraction
- line-item extraction where practical
- statement-line extraction for bank statement inputs

### Important principle
Extracted values must remain stored as interpretation records rather than silently replacing the accounting object’s approved fields.

---

## 18. AI Classification Model

The classification subsystem should assign likely meaning to extracted or imported records.

### Classification targets include
- document type
- invoice direction
- contact candidate
- category suggestion
- expense grouping
- revenue grouping
- tax treatment category
- transaction type

### Important principle
Classification is suggestion-driven unless trusted rules or policies allow automation.

---

## 19. AI Matching Model

The matching subsystem should propose relationships between financial objects.

### It should support
- invoice-to-transaction matching
- one-to-one settlement detection
- one-to-many settlement detection
- many-to-one settlement detection
- partial payment detection
- grouped payment recognition
- reference-based matching
- amount-plus-date matching
- historical pattern-assisted matching

### Matching outputs should include
- confidence
- rationale
- linked amount
- ambiguity notes
- recommended next action

### Important principle
A proposed match is not a reconciled match until the workflow or policy says so.

---

## 20. AI Anomaly Detection Model

The anomaly subsystem should identify patterns that deserve attention.

### Examples include
- likely duplicate invoice
- suspicious amount discrepancy
- inconsistent tax amount
- unexpected supplier behavior
- strange period assignment
- recurring transaction without expected document
- low-quality statement parse
- unexpected contact mismatch
- inconsistent totals across related records

### Design principle
Anomaly detection should prioritize useful exceptions, not noisy speculation.

The system should optimize for meaningful financial attention rather than novelty for its own sake.

---

## 21. AI Prioritization Model

AI should help the founder focus on what matters first.

### Prioritization should consider
- financial materiality
- tax sensitivity
- reporting period urgency
- confidence shortfall
- anomaly severity
- overdue operational impact
- downstream workflow blockage

### Example principle
A low-value, medium-confidence office expense should not outrank a high-value, tax-sensitive invoice with contradictory VAT indicators.

The prioritization system should behave like an intelligent operations queue.

---

## 22. AI Escalation Model

The AI layer should escalate issues when it cannot safely proceed.

### Escalation triggers may include
- low confidence in a required field
- missing mandatory source information
- tax treatment ambiguity
- contradictory match candidates
- duplicate uncertainty with material consequences
- locked-period conflict
- integration inconsistency affecting accounting completeness

### Escalation outcomes may include
- alert creation
- review item creation
- automation block
- policy exception note
- founder notification

Escalation is a sign of control, not weakness.

---

## 23. AI Learning and Improvement Direction

The product should become more reliable over time, but this must happen in a controlled manner.

### The platform should improve through
- repeated pattern recognition
- historical correction learning
- supplier-specific structure familiarity
- transaction matching history
- policy refinement
- review outcome feedback

### Important boundary
The system may learn from prior outcomes, but it must not become non-transparent or irreproducible.

Any improvement mechanism must still preserve reviewability and policy control.

---

## 24. AI Memory Within Tenant Context

AI behavior should become more useful within a given company context.

### Useful contextual memory may include
- known suppliers
- recurring invoice formats
- common categories
- common payment patterns
- known tax treatment defaults
- recurring explanations and resolutions

### Important principle
This contextual intelligence must remain tenant-scoped and should never cross tenant boundaries.

---

## 25. AI Failure Model

The platform must assume AI will sometimes fail, and it must handle that failure gracefully.

### AI failure examples include
- unreadable document parse
- wrong supplier identification
- wrong tax suggestion
- incomplete line extraction
- incorrect match proposal
- excessive anomaly noise

### The system should respond by
- preserving the failed attempt
- flagging uncertainty
- routing the case to review
- allowing manual correction
- recording the outcome for future improvement

The system should never hide AI failure behind false certainty.

---

## 26. Deterministic Rules vs AI Reasoning

The product must maintain a clear separation between AI reasoning and deterministic control logic.

### AI reasoning should handle
- inference
- probability
- pattern recognition
- classification
- explanation

### Deterministic rules should handle
- required field checks
- period restrictions
- policy thresholds
- tax plausibility checks
- duplicate blocker logic where rule-based
- lock-state restrictions
- escalation requirements

### Why this matters
This separation makes the system easier to trust, maintain, and audit.

---

## 27. AI Outcome Classes

AI outputs should be grouped into structured outcome classes.

### Suggested outcome classes
- extracted value
- suggested classification
- suggested match
- suggested tax treatment
- anomaly signal
- explanation output
- routing recommendation

This keeps the AI subsystem understandable and makes downstream workflow logic cleaner.

---

## 28. AI Evaluation Direction

The product should be designed so AI quality can be evaluated systematically.

### Important evaluation categories include
- extraction accuracy
- contact recognition accuracy
- categorization quality
- tax treatment suggestion quality
- matching precision
- anomaly usefulness
- false positive rate
- review deflection rate
- correction frequency after automation

### Product principle
The platform should eventually know where AI performs well and where it still needs stronger review controls.

---

## 29. Progression to Autonomy

The system should move toward greater autonomy in stages.

### Stage 1
AI performs mostly extraction and suggestion, while humans review nearly all sensitive outcomes.

### Stage 2
AI auto-processes stable, low-risk, high-confidence patterns under policy control.

### Stage 3
AI handles most routine bookkeeping tasks and surfaces only exceptions.

### Stage 4
AI functions as an accounting operator inside a controlled review and period-governance environment.

### Important principle
Autonomy should be earned through observed reliability, not assumed from model capability alone.

---

## 30. Founder Experience Goal

The founder should experience AI as a calm and useful accounting operator.

This means the founder should feel that:

- the system understands most documents and transactions automatically
- the system only asks for input when needed
- the system clearly explains issues
- the system catches mistakes early
- the system gets better over time
- the system reduces stress instead of creating more uncertainty

The AI layer should make the bookkeeping workspace feel intelligent without feeling dangerous.

---

## 31. Non-Goals of This Document

This document does not define:

- the exact AI vendor or model provider
- the exact OCR tool selection
- the exact prompt templates
- the exact scoring formulas
- the exact state transition tables
- the exact UI wording for explanations and alerts
- the exact benchmark thresholds for production rollout

Those details belong in later technical and implementation documents.

---

## 32. AI Automation Model Summary

The AI layer should be built as a structured operational intelligence system that extracts, interprets, suggests, explains, prioritizes, and escalates, while remaining bounded by deterministic rules, review workflows, confidence-aware routing, risk-aware policy control, and strict separation between source truth, machine interpretation, and approved accounting truth.

The end goal is not reckless full automation. The end goal is a trustworthy AI accountant operating inside controlled software, where the founder only needs to intervene when something truly deserves attention.

This document now serves as the AI behavior reference for state-machine design and for the later phase-based development specifications.

