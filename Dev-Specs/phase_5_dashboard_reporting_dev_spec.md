# Phase 5 Dashboard and Reporting Dev Spec

## 1. Document Purpose

This document defines the definitive Phase 5 development specification for the AI-native bookkeeping platform. It builds on Phase 1 Foundation, Phase 2 Invoice Engine, Phase 3 Bank Reconciliation, and Phase 4 AI Review and Alerting and introduces the first mature founder-facing dashboard and reporting layer.

Phase 5 is the point where the platform stops feeling like a set of back-office workflows and starts feeling like an operational financial command center. By this stage, the system already supports foundational evidence handling, invoice truth, reconciliation truth, and cross-domain review intelligence. This phase turns those structured states into usable visibility, summaries, filters, trends, and control-oriented reporting surfaces.

This phase is intentionally limited to dashboarding, operational reporting, founder-facing visibility, and accountant-safe summaries derived from already-supported platform truth. It does not yet implement filing exports, final ledger-driven financial statements, period locking and amendment workflows, live banking integrations, or broad autonomous bookkeeping governance.

The purpose of this phase is to make the platform continuously understandable: the founder should be able to open the system and immediately know what is healthy, what is unresolved, what is risky, and what requires action.

---

## 2. Phase Objective

The objective of Phase 5 is to create a founder-first dashboard and reporting layer that translates the platform’s evidence, invoice, reconciliation, review, and alerting states into practical operational visibility.

At the end of Phase 5, the system should support:

- a founder-facing dashboard home
- operational summary cards across currently supported domains
- issue and health indicators
- invoice status reporting
- reconciliation status reporting
- review and alert visibility
- filtered object-level list views
- period-oriented operational summaries
- accountant-safe reporting surfaces derived from current platform truth
- consistent distinction between operational summaries and final accounting or filing outputs

At the end of Phase 5, the platform should feel usable not only as a workflow engine, but also as an always-on financial control cockpit.

---

## 3. Phase Boundary

### Included in Phase 5
Phase 5 includes the founder dashboard and reporting layer for currently supported system truth.

### Excluded from Phase 5
Phase 5 explicitly excludes:

- filing exports
- statutory or government-submission outputs
- final ledger-driven financial statements
- period locking and amendment workflows
- live Revolut integration
- generalized external banking connector framework
- broad production-grade autonomous approval and reconciliation
- advanced forecasting engine
- mature executive BI or custom analytics builder
- cross-channel notification expansion beyond core in-app visibility

This boundary must remain strict. Phase 5 reports on supported operational truth; it does not yet claim final accounting closure or filing-grade finality.

---

## 4. Phase 5 Design Decisions

## 4.1 Dashboard posture

### Decision
Phase 5 introduces a founder-first operational dashboard rather than an accountant-first report console.

### Meaning
The dashboard must prioritize:

- clarity
- current control state
- unresolved work
- health signals
- actionability
- operational confidence

The dashboard must not prioritize:

- raw accounting jargon without context
- full statutory report complexity
- deep ledger-first workflows

### Reason
The product direction is explicitly founder-first in the interface while remaining accountant-safe in the backend.

---

## 4.2 Reporting posture

### Decision
Phase 5 introduces operational reporting, not final accounting statement reporting.

### Meaning
Reports in Phase 5 may summarize:

- invoices
- outgoing invoicing activity
- payment-status posture
- statement import health
- transaction reconciliation posture
- review workload
- alert posture
- period-oriented operational summaries

Reports in Phase 5 must not claim to be:

- final statutory financial statements
- final filing outputs
- complete ledger-truth financial reporting

### Reason
The project architecture requires clear separation between operational truth and final accounting closure.

---

## 4.3 Source-of-truth posture

### Decision
Phase 5 dashboarding and reporting must consume structured platform truth from earlier phases, not raw source files alone.

### Meaning
The reporting layer must be built on:

- approved invoice truth where applicable
- reconciliation truth where applicable
- review and alert control states
- current operational statuses

The reporting layer must not:

- infer finality from unapproved interpretation records
- show unreviewed AI candidates as settled truth without clear distinction
- hide uncertainty by blending unresolved items into healthy summaries

### Reason
The dashboard must help the founder trust the product, not create false calm by obscuring unresolved context.

---

## 4.4 Period summary posture

### Decision
Phase 5 introduces period-oriented operational summaries, but not final period-close workflows.

### Meaning
The system must be able to summarize a period in terms of:

- invoice counts and states
- outgoing invoice issuance posture
- payment-status posture
- statement and transaction ingestion completeness posture
- reconciliation completeness posture
- unresolved review items and alerts

The system must not yet:

- lock periods
- certify period finality
- claim filing readiness beyond operational indicators

### Reason
The reporting layer should prepare the founder for later period-control maturity without pretending it already exists.

---

## 4.5 Alert and review visibility posture

### Decision
Phase 5 must make review and alerting visible as first-class dashboard concerns.

### Meaning
The dashboard must surface:

- how many unresolved review items exist
- their severity and urgency posture
- how many active alerts exist
- whether any are blocking or escalated
- where work is concentrated

### Important note
The dashboard must not bury control problems under high-level summary cards.

---

## 4.6 Metric posture

### Decision
Phase 5 introduces operational metrics, not full accounting KPIs dependent on final posting.

### Examples of metrics in scope
- invoice counts by status
- outgoing invoice counts by issue posture
- payment-status counts
- number of unmatched transactions
- number of reconciled transactions
- active review items
- active alerts
- number of recent uploads and processing outcomes
- import success and failure posture

### Important note
If a metric depends on not-yet-implemented final accounting truth, it must either be omitted or clearly labeled as operational and provisional.

---

## 4.7 Trend posture

### Decision
Phase 5 may introduce basic trend views where derived from existing operational truth.

### Examples in scope
- invoices created over time
- outgoing invoices issued over time
- statement imports over time
- reconciliation completion trend
- review queue trend
- alert creation and resolution trend

### Important rule
Trend views must remain rooted in implemented system truth and must not imply final financial statement quality.

---

## 4.8 Accountant-safe reporting posture

### Decision
Phase 5 should expose accountant-safe summaries, but not yet full handoff export maturity.

### Meaning
The system may provide filtered reporting views and structured lists useful to an accountant, but full export-package maturity remains later.

### Reason
By this stage, the product should be reviewable by a professional, but export and filing workflows still belong later.

---

## 4.9 Dashboard calm posture

### Decision
The dashboard must be designed to create calm through clarity, not calm through omission.

### Meaning
The platform should make it easy for the founder to see:

- what is under control
- what is waiting for review
- what is failing or blocked
- what is improving or worsening

### Important note
A dashboard that looks calm while hiding unresolved blockers is a design failure.

---

## 5. Scope of Phase 5 Modules

## 5.1 Dashboard home

Phase 5 must implement a founder-facing dashboard home.

### Required content areas
The home dashboard must be able to show:

- summary cards for current operational health
- recent system activity highlights
- unresolved review work snapshot
- active alert snapshot
- invoice and reconciliation health snapshot
- period-oriented operational snapshot

### Required principle
The dashboard home must function as a control center, not just a landing page.

---

## 5.2 Summary cards layer

Phase 5 must implement summary-card style operational visibility.

### Required summary-card families
At minimum, the dashboard should support cards for:

- incoming invoices
- outgoing invoices
- payment-status posture
- statement import posture
- transaction reconciliation posture
- review workload
- alert severity posture
- recent processing failures or issues

### Required behavior
Cards should be clickable or navigable into filtered detail views where practical.

---

## 5.3 Invoice reporting views

Phase 5 must implement invoice-focused reporting surfaces.

### Required capabilities
- list and filter invoices by direction, type, state, period, contact, and status
- show invoice counts by state
- show payment-status posture for invoices
- show outgoing invoice issuance posture
- surface duplicate-warning or review context where relevant

### Important note
Invoice reporting in Phase 5 is operational reporting, not full receivables/payables accounting close.

---

## 5.4 Reconciliation reporting views

Phase 5 must implement reconciliation-focused reporting surfaces.

### Required capabilities
- list and filter statements by import and review state
- list and filter transactions by reconciliation state
- show unmatched transaction counts
- show matched and reconciled transaction counts
- surface partial-settlement posture
- surface duplicate or contradiction indicators where relevant

### Important note
These views should help the founder understand money-movement control health, not just raw transaction volume.

---

## 5.5 Review and alert views

Phase 5 must expose review and alerting state through dedicated visibility surfaces.

### Required capabilities
- show unresolved review items by severity, age, object type, and status
- show active alerts by severity, category, and state
- show escalated items clearly
- allow navigation from report view into detailed review and underlying object context

### Important principle
The founder must be able to move from summary to action without losing context.

---

## 5.6 Period-oriented operational summaries

Phase 5 must implement period-filterable operational summaries.

### Required capabilities
- select or filter by reporting period
- summarize invoices and outgoing issuance within period context
- summarize statement imports and reconciliations within period context
- summarize unresolved review items and alerts linked to the period or period-relevant objects where possible
- indicate whether the period appears clean, noisy, or blocked from an operational perspective

### Important note
These are operational readiness indicators, not final close indicators.

---

## 5.7 Recent activity and processing health

Phase 5 must implement recent-activity and processing-health visibility.

### Required capabilities
- show recent uploads
- show recent parsing outcomes
- show recent statement imports
- show recent outgoing invoice generation events
- show recent approval decisions where relevant
- show recent failures or partial successes requiring attention

### Important principle
The founder should not have to search log-like screens to understand whether the system has been working correctly.

---

## 5.8 Filtered list views and drill-down behavior

Phase 5 must implement filtered list and drill-down experiences from dashboard summaries.

### Required behavior
- clicking a summary or metric should open a filtered list where practical
- list views should retain filter state
- users should be able to move from list view to object detail without losing navigational context

### Important rule
Reporting must lead cleanly into action-oriented workflows.

---

## 5.9 Basic trend surfaces

Phase 5 may implement lightweight trend surfaces.

### Examples in scope
- invoice volume trend
- outgoing invoice issuance trend
- review queue trend
- alert trend
- statement import success/failure trend
- reconciliation completion trend

### Important rule
Trend views must be clearly labeled, period-aware, and based only on current implemented truth.

---

## 5.10 Dashboard and reporting audit hardening

Phase 5 must harden the traceability of dashboard and report generation context.

### Additional audit-covered actions
- report view opened where audit-worthy by policy
- filtered report generated where meaningful
- period summary generated where meaningful
- high-sensitivity reporting view accessed where meaningful

### Important note
Not every dashboard page view must become a heavy audit event, but sensitive reporting access patterns should remain traceable where needed.

---

## 6. Required Phase 5 Data and Query Layer Changes

Phase 5 builds on earlier phases and requires operational reporting views over existing entities such as:

- Invoice
- InvoiceLine
- ApprovalDecision
- Statement
- Transaction
- Match
- ReviewItem
- Alert
- ParsingRun
- ExtractionResult
- ReportingPeriod
- ProcessingJob
- Document

### Additional strongly recommended support structures
Phase 5 should introduce reporting-support structures such as:

- DashboardSnapshot or equivalent summary cache model where needed
- ReportFilterPreset or equivalent saved filter model where useful
- ReportingViewDefinition or equivalent internal query abstraction where helpful
- MetricComputationSnapshot or equivalent precomputed metric support where necessary

### Important modeling principle
Reporting-support artifacts must never replace underlying operational truth. They are read-optimization or visibility structures only.

---

## 7. Phase 5 View and State Behavior

## 7.1 Dashboard state posture

Phase 5 does not create a new core accounting object state machine. It consumes states from earlier phases.

### Required principle
Dashboard and reporting views must reflect object states correctly and must never flatten different meanings into one generic status without explanation.

---

## 7.2 Review and alert state visibility

Phase 5 must visibly distinguish:
- open versus resolved review work
- active versus resolved alerts
- escalated versus non-escalated work
- blocked versus informational issues where meaningful

### Important rule
The reporting layer must preserve the semantics of the underlying control state.

---

## 7.3 Payment-status visibility

Phase 5 must visibly distinguish invoice payment-status posture such as:
- unpaid
- partially_paid
- paid
- overpaid
- refunded

### Important rule
Payment-status visibility must not imply final ledger completion or filing status.

---

## 7.4 Reconciliation state visibility

Phase 5 must visibly distinguish transaction and statement states such as:
- imported
- normalized
- classified
- match_candidate
- matched
- reconciled
- exception_flagged
- needs_review
- failed_import
- reconciled_ready

### Important rule
The dashboard must not collapse `matched` and `reconciled` into the same meaning.

---

## 8. Required Backend Operations in Phase 5

Every critical backend operation must continue to follow the trusted pattern:
1. authenticate request
2. validate tenant scope
3. validate permission
4. execute structured read or reporting query
5. create audit event where required by sensitivity or policy
6. return filtered or summarized result

### Required backend operations
- fetch dashboard home summary
- fetch invoice reporting summary
- fetch reconciliation reporting summary
- fetch review and alert reporting summary
- fetch period-oriented operational summary
- fetch recent activity summary
- fetch filtered invoice list
- fetch filtered statement list
- fetch filtered transaction list
- fetch filtered review-item list
- fetch filtered alert list
- fetch lightweight trend data where implemented

### Important note
These are primarily read-oriented operations, but they remain permission-sensitive and may require audit visibility depending on the surface.

---

## 9. Storage, Query, and Performance Rules

Phase 5 adds reporting-specific read requirements.

### Required rules
- dashboard queries must remain tenant-scoped
- reporting surfaces must respect role and permission boundaries
- slow reporting views may use precomputed or cached support structures where necessary
- caches or snapshots must be invalidation-aware and must not become a hidden competing truth source
- report queries must preserve operational truth distinctions

### Important rule
Performance optimization must not introduce stale or misleading state presentation without clear handling.

---

## 10. Security and Permission Rules

Phase 5 builds on earlier RBAC and introduces reporting-visibility rules.

### Founder and Admin
May:
- view full dashboard home
- view invoice, reconciliation, review, and alert reporting surfaces
- view period-oriented operational summaries
- access all currently supported drill-down views within company scope

### Accountant
May:
- view accountant-safe reporting surfaces where allowed
- view invoice and reconciliation summaries where allowed
- view issue and review posture where allowed
- access filtered lists relevant to accounting review where allowed

### Reviewer
May:
- view review and alert reporting surfaces
- view object summaries relevant to assigned or visible work
- access detail views needed to resolve work

May not by default:
- view broad company-wide sensitive reporting if not needed for review role
- access high-sensitivity operational views beyond permitted scope

### Important implementation note
Reporting access must remain role-aware. A simple dashboard is still sensitive when it summarizes financial control posture.

---

## 11. Validation and Reporting Rules

## 11.1 Reporting truth rules

The system must not include unresolved or unapproved interpretation-layer data in summaries as if it were approved truth unless clearly labeled.

## 11.2 Visibility rules

The system must clearly surface when operational summaries are affected by:
- unresolved review items
- active alerts
- incomplete statement imports
- unresolved matching or reconciliation ambiguity
- partial workflow completion

## 11.3 Metric labeling rules

If a metric is operational rather than final, the reporting layer must preserve that distinction in wording or semantics.

## 11.4 Non-authoritative reporting rules

Phase 5 metrics and summaries must not be used as a substitute for final statutory reporting, final filing data, or final ledger-based accounting statements.

---

## 12. Audit Requirements

Every meaningfully sensitive reporting access pattern defined by policy must generate an audit event.

### Additional minimum audit contents where relevant
- report surface type
- filter context where meaningful
- period context where meaningful
- actor identity
- company scope
- timestamp

### Minimum Phase 5 audit coverage where policy requires
- sensitive report access
- accountant-oriented summary access where meaningful
- period-oriented operational summary generation where meaningful
- high-sensitivity filtered report generation where meaningful

### Important note
Audit must remain proportional. The goal is traceability for sensitive reporting, not noisy over-logging of every harmless screen load.

---

## 13. Acceptance Criteria

Phase 5 is complete only when all of the following are true:

1. The founder can open a dashboard home that summarizes current operational financial control posture.
2. The dashboard can display summary cards across invoices, outgoing invoicing, reconciliation, review workload, and alert posture.
3. The system can provide filtered invoice reporting views.
4. The system can provide filtered reconciliation reporting views.
5. The system can provide review and alert visibility surfaces with drill-down behavior.
6. The system can provide period-oriented operational summaries.
7. The system can provide recent-activity and processing-health visibility.
8. The system can display lightweight trend views where implemented from supported truth.
9. The reporting layer does not misrepresent interpretation-layer uncertainty as approved truth.
10. The reporting layer does not collapse different underlying states such as matched versus reconciled or open versus resolved.
11. Reporting access remains tenant-safe and permission-aware.
12. Sensitive reporting access is auditable where required by policy.
13. No Phase 5 feature claims final filing-grade or final ledger-grade reporting under the dashboard label.

---

## 14. Items Explicitly Deferred After Phase 5

The following remain out of scope after this phase and must be handled in later dev-specs:

- filing exports
- final ledger-driven statements
- period locking and amendment
- live Revolut integration
- generalized external banking connector framework
- broad autonomous bookkeeping governance
- advanced forecasting
- mature executive BI and custom analytics builder
- cross-channel notification expansion
- Cyprus tax-rule completeness for final filing outputs

---

## 15. Implementation Order Recommendation

The recommended implementation order inside Phase 5 is:

1. dashboard home foundation
2. summary cards and current-health surfaces
3. invoice reporting views
4. reconciliation reporting views
5. review and alert visibility surfaces
6. period-oriented operational summaries
7. recent activity and processing health
8. lightweight trends and drill-down refinement
9. reporting access audit hardening and performance optimization

This sequence ensures that the platform first becomes understandable at a high level before expanding into richer detail and trend surfaces.

---

## 16. Final Phase 5 Summary

Phase 5 turns the platform into a founder-facing financial command center. It introduces dashboard home, operational reporting, current-health visibility, drill-down navigation, period-oriented summaries, review and alert visibility, and lightweight trends based on already-supported system truth.

At the end of this phase, the founder should be able to open the platform and quickly understand what is healthy, what is unresolved, and what needs attention, while the system still stops short of final filing, final ledger reporting, live integrations, and broad autonomous bookkeeping governance. That boundary is intentional and necessary for maintaining trust, clarity, and architectural discipline.

