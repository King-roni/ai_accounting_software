# Product Flows and User Journeys

## 1. Document Purpose

This document defines the major end-to-end product flows and user journeys inside the AI-native bookkeeping platform. It explains how users, system components, AI processes, review logic, and accounting controls interact during real operational scenarios.

The purpose of this document is to connect the product vision, domain model, architecture, compliance model, AI automation model, and state machines into practical operational journeys. It ensures that the future development specifications are grounded not only in technical structure, but also in actual usage behavior.

This document is human-readable and operational in nature. It focuses on what happens, in what sequence, why it happens, what the system is expected to do, and where human review or control enters the flow.

---

## 2. Flow Design Philosophy

The platform is designed to reduce bookkeeping stress by absorbing complexity into structured workflows. That means the system must guide the founder through practical accounting operations without forcing the founder to think in fragmented technical terms.

Every major flow in the product should therefore follow these principles:

- the entry point should be simple
- the system should preserve source evidence immediately
- AI should do the heavy interpretation work where possible
- the system should expose uncertainty rather than hide it
- review should happen only where needed
- accounting outcomes should become structured and traceable
- the dashboard should reflect the real status of the flow
- audit and compliance context should be preserved throughout

The best user journey is one in which the founder feels that the system is doing the bookkeeping work and only asking for help when something genuinely needs judgment.

---

## 3. Core Product Journey Categories

The most important journeys in the product fall into the following categories:

- incoming invoice handling
- outgoing invoice handling
- bank statement handling
- transaction reconciliation
- AI review and correction
- anomaly and alert resolution
- integration-driven bookkeeping automation
- period review and close
- export and accountant handoff
- settings and control changes

These are the operational journeys that together define the product.

---

## 4. Incoming Invoice Upload Journey

### User goal
The founder wants to add an incoming invoice to the system and have the software understand, organize, and process it.

### Typical trigger
The founder uploads a PDF, image, or other invoice file manually.

### Flow sequence
1. The founder opens the upload flow.
2. The founder selects one or more invoice files.
3. The system receives the files through an authenticated upload flow.
4. The system stores the original files in private storage.
5. The system creates document records and audit events.
6. The system places the documents into a processing queue.
7. AI and parsing services classify the document type and extract candidate invoice fields.
8. The rules layer validates required fields, amount consistency, and obvious structural issues.
9. The system creates or updates a structured invoice candidate.
10. The system determines whether the invoice is safe for next-step progression or requires review.
11. If review is required, a review item and alert may be created.
12. If review is not required, the invoice may progress toward approval or policy-controlled acceptance.
13. The founder sees the invoice appear in the dashboard or review queue.

### System expectations
The founder should not need to manually re-enter every invoice field unless the system fails or a sensitive ambiguity exists.

### Important design note
The document upload event is not the same thing as invoice approval. Upload begins the evidence chain. Approval belongs later in the flow.

---

## 5. Incoming Invoice Review Journey

### User goal
The founder wants to inspect and confirm an invoice that the system could not fully trust automatically.

### Typical trigger
A review item appears because of low confidence, missing fields, tax ambiguity, or another exception.

### Flow sequence
1. The founder opens the invoice review interface.
2. The system presents the original document alongside extracted values and explanations.
3. The system highlights missing, conflicting, or uncertain fields.
4. The founder inspects the evidence and makes corrections where necessary.
5. The founder confirms or adjusts supplier identity, dates, amounts, tax treatment, or category.
6. The system validates the edited outcome again.
7. If no blocking issues remain, the founder approves the invoice.
8. The system records the approval decision.
9. The system updates invoice state and downstream accounting readiness.
10. Any linked alerts or review items are resolved or updated.

### Founder experience goal
The review screen should feel like a guided correction and approval workspace rather than a raw accounting form.

---

## 6. Outgoing Invoice Creation Journey

### User goal
The founder wants to create and issue an outgoing invoice from inside the platform.

### Typical trigger
The founder opens a create-invoice flow to bill a customer.

### Flow sequence
1. The founder opens the outgoing invoice creation interface.
2. The founder selects or creates a customer.
3. The founder enters invoice details or uses a template.
4. The system applies numbering rules and company defaults.
5. The system generates the invoice record and output file.
6. The generated invoice is stored as preserved evidence.
7. The invoice enters issued status.
8. If sent through the platform or marked as delivered, that status is recorded.
9. The invoice becomes visible in receivables and dashboard summaries.
10. Later payment events may move the invoice into partial or full settlement flows.

### System expectations
Outgoing invoices should behave as both operational business records and preserved financial evidence.

---

## 7. Outgoing Invoice Settlement Journey

### User goal
The founder wants the system to recognize when an outgoing invoice has been paid.

### Typical trigger
A payment arrives through a bank statement or Revolut sync.

### Flow sequence
1. A transaction enters the system.
2. The system normalizes and classifies the transaction.
3. The matching engine identifies one or more likely outgoing invoice targets.
4. If confidence and policy allow, the match may be accepted automatically.
5. If ambiguity exists, the founder is asked to review the candidate match.
6. Once accepted, the invoice payment status updates to partially paid or paid.
7. The transaction moves toward reconciled state.
8. The dashboard updates receivables and cash summaries.

### Important design note
Settlement is not just a dashboard update. It is a cross-object accounting event involving transactions, matches, invoices, and possibly period logic.

---

## 8. Bank Statement Upload Journey

### User goal
The founder wants to upload a bank statement so the system can ingest and interpret transactions.

### Typical trigger
The founder uploads a PDF, CSV, or other supported bank statement file.

### Flow sequence
1. The founder selects the statement file.
2. The system stores the original statement as preserved evidence.
3. The system creates a statement record.
4. The statement is queued for parsing and import.
5. The system extracts or reads the transaction lines.
6. The system normalizes dates, amounts, references, and descriptions.
7. Normalized transaction records are created.
8. The system evaluates whether the imported statement appears complete and coherent.
9. If issues exist, the statement enters review-oriented handling.
10. If import quality is acceptable, the transactions move into classification and matching workflows.

### Founder experience goal
The founder should feel that a statement upload produces usable bookkeeping progress, not merely a static file archive.

---

## 9. Revolut Sync Journey

### User goal
The founder wants transactions to enter the platform automatically without manual statement uploads.

### Typical trigger
A configured Revolut connection runs a sync.

### Flow sequence
1. A scheduled or user-triggered sync starts.
2. The system authenticates against the configured Revolut connection.
3. The system retrieves new or updated transaction source data.
4. External references and sync metadata are preserved.
5. Normalized internal transaction records are created or updated.
6. The system runs classification, matching, and anomaly checks.
7. New review items or alerts are created where needed.
8. The sync result is logged and surfaced in integration status views.
9. The dashboard updates based on the newly available financial movement data.

### Important design note
Automatic sync should feel calm and invisible when healthy, but highly visible when failures or gaps threaten bookkeeping completeness.

---

## 10. Transaction Classification Journey

### User goal
The founder wants the system to understand what imported transactions likely represent.

### Typical trigger
A transaction enters the platform through statement upload or integration sync.

### Flow sequence
1. The transaction is normalized.
2. AI and rules evaluate the transaction description, amount, timing, references, and historical patterns.
3. The system suggests a likely transaction type, category, contact, and accounting meaning.
4. If confidence is strong and risk is low, the classification may be accepted under policy.
5. If ambiguity remains, the transaction enters review.
6. The resulting classification becomes available to matching, reconciliation, and reporting logic.

### Important design note
Classification is often a bridge step, not a final accounting outcome.

---

## 11. Invoice-to-Transaction Matching Journey

### User goal
The founder wants the system to connect invoices and transactions automatically where possible.

### Typical trigger
An invoice or transaction enters a match-ready state.

### Flow sequence
1. The matching engine evaluates candidate relationships.
2. It compares amounts, dates, references, contact patterns, historical behavior, and settlement context.
3. The system produces one or more proposed matches.
4. Each proposal includes confidence, rationale, and potential ambiguity notes.
5. If policy allows, a low-risk high-confidence match may be accepted automatically.
6. Otherwise, the founder or reviewer confirms or rejects the match.
7. Accepted matches update invoice payment status and transaction reconciliation progress.
8. Rejected matches remain historically visible and may inform future suggestions.

### Founder experience goal
The founder should feel that the system is doing the detective work and only asking for confirmation when needed.

---

## 12. Duplicate Detection Journey

### User goal
The founder wants the system to prevent duplicate invoices or duplicate accounting treatment.

### Typical trigger
A new invoice or transaction resembles an existing record strongly enough to create risk.

### Flow sequence
1. A new object is created or imported.
2. The duplicate detection subsystem compares it against prior records.
3. The system identifies duplicate candidates based on amount, date, supplier, invoice number, reference patterns, or file similarity.
4. If the duplicate risk is material, an alert or review item is created.
5. The founder inspects the duplicate comparison.
6. The founder confirms whether the item is a duplicate, a related record, or a false positive.
7. The system updates status and reasoning context accordingly.

### Important design note
Duplicate handling should be structured carefully because false positives can be annoying, while false negatives can damage accounting accuracy.

---

## 13. AI Review Queue Journey

### User goal
The founder wants a single place to handle all bookkeeping issues that actually need human input.

### Typical trigger
Multiple review items are created across invoices, transactions, matches, alerts, or period controls.

### Flow sequence
1. The founder opens the review queue.
2. The system groups and prioritizes review items by severity, urgency, amount, tax sensitivity, and downstream blockage.
3. The founder selects a review item.
4. The system presents the underlying object, evidence, extracted values, explanations, and suggested actions.
5. The founder resolves the issue.
6. The system validates the new outcome and updates downstream states.
7. The queue updates dynamically as items are resolved.

### Founder experience goal
The queue should feel like an intelligent work center, not a pile of accounting problems.

---

## 14. Alert Resolution Journey

### User goal
The founder wants to understand and resolve system warnings without confusion.

### Typical trigger
An alert appears for a missing field, tax anomaly, duplicate suspicion, integration problem, or other issue.

### Flow sequence
1. The founder opens the alert.
2. The system shows the reason, severity, related object, and explanation.
3. The system indicates whether the alert is informational, actionable, or blocking.
4. If action is needed, the founder follows the linked review or correction path.
5. Once the underlying issue is fixed or accepted, the alert resolves automatically or through user acknowledgment.
6. The resolution is recorded in audit and workflow history.

### Important design note
Alerts should not force the founder to search for context. The alert must point directly to the problem and the likely resolution path.

---

## 15. Tax Warning Resolution Journey

### User goal
The founder wants to fix an issue the system believes may conflict with Cyprus-oriented tax logic.

### Typical trigger
The rules layer or AI layer surfaces a tax-sensitive warning.

### Flow sequence
1. The system flags the relevant invoice, transaction, or period item.
2. The founder opens the warning context.
3. The platform explains the likely issue, such as missing tax information, implausible treatment, or reporting inconsistency.
4. The founder reviews the source evidence and existing interpretation.
5. The founder corrects the tax treatment or sends the item into deeper review if needed.
6. The system re-validates the corrected result.
7. If the issue is cleared, the warning resolves.
8. If ambiguity remains, the item stays in review-sensitive status.

### Founder experience goal
Tax warnings should feel serious but understandable, not vague or threatening.

---

## 16. Low-Confidence Extraction Journey

### User goal
The founder wants to quickly fix a document the system could not read with enough confidence.

### Typical trigger
AI extraction produces low confidence for key fields.

### Flow sequence
1. The document is processed.
2. The system finds that one or more required fields have weak confidence.
3. The document or derived invoice enters needs-review logic.
4. The founder opens the review screen.
5. The system highlights the uncertain fields.
6. The founder verifies the evidence and corrects or confirms the fields.
7. The system revalidates the object and allows it to continue.

### Important design note
Low-confidence handling should minimize rework by focusing only on what is uncertain.

---

## 17. Policy-Based Auto-Processing Journey

### User goal
The founder wants routine bookkeeping to happen automatically when it is safe.

### Typical trigger
The system encounters a familiar, low-risk, high-confidence case that is allowed by automation policy.

### Flow sequence
1. A document, transaction, or match candidate is processed.
2. The AI layer produces a candidate outcome.
3. The rules engine checks policy, confidence, risk, and blocking conditions.
4. The system determines that auto-processing is allowed.
5. The outcome is accepted automatically.
6. Audit records capture the policy-driven acceptance.
7. The founder sees the result reflected in normal operational views without needing to intervene.

### Important design note
Automatic acceptance must still remain visible and reviewable historically.

---

## 18. Manual Override Journey

### User goal
The founder wants to change an AI-suggested or system-proposed outcome.

### Typical trigger
The system made a suggestion that the founder believes is incorrect or unsuitable.

### Flow sequence
1. The founder opens the relevant object.
2. The system shows the original suggestion and explanation.
3. The founder edits the relevant field or decision.
4. The system validates the new result.
5. The system records the override, including old and new values.
6. Any dependent alerts, review items, or state transitions update accordingly.

### Important design note
Manual overrides must feel safe and easy, but never hidden.

---

## 19. Month-End Review Journey

### User goal
The founder wants to understand whether a reporting period is ready to close.

### Typical trigger
A month or defined reporting period approaches completion.

### Flow sequence
1. The system evaluates the current period.
2. It checks unresolved review items, active critical alerts, unmatched transactions, and other blockers.
3. The dashboard indicates whether the period is open, under review, or close-ready.
4. The founder opens the period review workspace.
5. The system surfaces unresolved items in priority order.
6. The founder resolves remaining critical issues.
7. Once blockers are cleared, the period can move to ready-to-lock.

### Founder experience goal
Month-end should feel like guided closure rather than a stressful hunt for missing issues.

---

## 20. Reporting Period Lock Journey

### User goal
The founder wants to formally lock a completed period to prevent uncontrolled changes.

### Typical trigger
The system indicates the period is ready to lock.

### Flow sequence
1. The founder opens the period control screen.
2. The system shows lock readiness, unresolved blockers, and impact notes.
3. If all control conditions are satisfied, the founder confirms the lock action.
4. The system changes the reporting period state to locked.
5. The platform enforces stricter change controls on linked objects.
6. The action is fully logged.

### Important design note
Locking is not merely visual. It must materially affect what can or cannot be changed afterward.

---

## 21. Post-Lock Adjustment Journey

### User goal
The founder or reviewer needs to correct something that affects a locked period.

### Typical trigger
A late document, correction, or discovered error affects a period already locked.

### Flow sequence
1. A change attempt touches a locked-period object.
2. The system blocks casual modification and indicates the lock restriction.
3. The user is offered an amendment or controlled adjustment path if permissions allow.
4. The system records the reason for the change.
5. The amendment flow proceeds under stricter audit visibility.
6. The affected period is marked as amended or adjustment-aware.

### Important design note
This flow is essential for real-world accounting, where late corrections happen, but must never happen invisibly.

---

## 22. Export Package Journey

### User goal
The founder wants to generate a structured export of bookkeeping records and source evidence.

### Typical trigger
The founder selects a period, object group, or accountant-handoff action.

### Flow sequence
1. The founder opens the export interface.
2. The founder chooses scope and filters.
3. The system validates permissions and scope.
4. An export job is created.
5. The backend assembles structured data and relevant files.
6. The export artifact is generated and stored.
7. The founder receives access to download the package.
8. The export event is logged for traceability.

### Important design note
Exports should be reproducible and should preserve evidence context, not only spreadsheet-like summaries.

---

## 23. Accountant Handoff Journey

### User goal
The founder wants to hand over a clean and reviewable set of records to an accountant.

### Typical trigger
The founder prepares an accounting package for review or filing support.

### Flow sequence
1. The founder initiates an accountant-oriented export or access flow.
2. The system prepares a package containing structured records, supporting documents, and relevant summaries.
3. The platform ensures the package reflects clear period boundaries and review state.
4. The founder shares or downloads the package.
5. The system logs the handoff-related export event.

### Accountant-safe outcome
The accountant should be able to inspect evidence, structured records, and key approvals without needing hidden product knowledge.

---

## 24. Integration Failure Recovery Journey

### User goal
The founder wants to know when automation is incomplete and recover it safely.

### Typical trigger
An email ingestion flow, Revolut sync, or other integration fails or becomes degraded.

### Flow sequence
1. The integration layer detects failure or degraded behavior.
2. The system creates an alert and updates integration state.
3. The founder sees the issue in the dashboard or integration view.
4. The platform explains the failure category where possible.
5. The founder retries, reauthenticates, or postpones the issue depending on available options.
6. Once the integration is restored, sync resumes and missing data can be recovered if supported.

### Important design note
Integration problems are bookkeeping problems when they interrupt data completeness. The product must make that visible.

---

## 25. Settings Change Journey

### User goal
The founder wants to change a company setting that affects bookkeeping behavior.

### Typical trigger
The founder edits tax settings, invoice numbering rules, integration settings, or automation thresholds.

### Flow sequence
1. The founder opens settings.
2. The system presents the current configuration and any sensitive implications.
3. The founder edits the relevant values.
4. The system validates the changes.
5. Sensitive changes may require stronger permissions or confirmation.
6. The changes are saved and logged.
7. Future system behavior reflects the updated configuration.

### Important design note
Settings are not cosmetic in this product. Many settings directly shape accounting outcomes and must therefore be treated with control awareness.

---

## 26. Daily Founder Journey

### User goal
The founder wants to check whether bookkeeping is under control without doing unnecessary work.

### Typical daily experience
1. The founder opens the dashboard.
2. The system shows overall financial health, open issues, unresolved reviews, unmatched transactions, overdue invoices, and recent automation activity.
3. The founder sees whether attention is required.
4. If there are no important issues, the founder leaves with confidence.
5. If issues exist, the founder enters the review queue or relevant object flow.
6. The founder resolves only the items that need judgment.

### Core emotional goal
The founder should feel calm, informed, and in control.

That is one of the deepest product goals of the whole platform.

---

## 27. Weekly or Periodic Review Journey

### User goal
The founder wants to ensure bookkeeping is progressing cleanly over time, not just react to individual events.

### Typical review flow
1. The founder checks the dashboard trend and issue summaries.
2. The founder reviews unresolved alerts and long-open review items.
3. The founder checks statement completeness, invoice status, and reconciliation health.
4. The founder resolves any lingering blockers before month-end pressure builds.
5. The system reflects the improved control state.

### Product value
This journey helps shift bookkeeping from reactive chaos to controlled operational hygiene.

---

## 28. End-to-End Automation Vision Journey

### Long-term goal
The platform should evolve toward a flow in which most routine bookkeeping happens with minimal manual effort.

### Long-term journey shape
1. Documents and transactions enter automatically.
2. The system extracts, classifies, matches, and validates them.
3. Low-risk items flow through policy-controlled automation.
4. The founder receives only meaningful review items and exceptions.
5. The dashboard remains continuously current.
6. Period close becomes a guided confirmation process rather than a reconstruction effort.
7. Export and accountant handoff become lightweight operational actions.

### Strategic meaning
This is the journey that turns the product into a real AI accountant inside its own software environment.

---

## 29. Flow Dependencies

The following dependencies exist across flows:

- invoice review depends on document ingestion and extraction
- reconciliation depends on transaction normalization and matching
- tax warning resolution depends on validation and review workflows
- period lock depends on unresolved review and alert state
- accountant handoff depends on evidence preservation and export generation
- automation confidence depends on prior system learning and policy control

These dependencies must be respected when phase dev-specs are created.

---

## 30. Non-Goals of This Document

This document does not define:

- exact UI layouts
- exact API contracts
- exact database mutations
- exact event payloads
- exact transition guards for every object
- exact AI scoring formulas
- exact export file structures

Those details belong in the phase-based development specifications and supporting technical documents.

---

## 31. Product Flows and User Journeys Summary

The platform is built around real operational journeys rather than isolated features. The most important journeys cover incoming invoices, outgoing invoices, statements, integrations, AI review, alert resolution, reconciliation, period control, exports, and accountant handoff.

Together, these journeys define how the founder will actually experience the product: as a calm, intelligent bookkeeping workspace that does the heavy lifting, preserves control, and only asks for attention when real judgment is required.

This document now completes the core documentation layer that should exist before phase-based development specifications begin.

