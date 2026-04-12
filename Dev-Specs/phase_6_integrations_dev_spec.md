# Phase 6 Integrations Dev Spec

## 1. Document Purpose

This document defines the definitive Phase 6 development specification for the AI-native bookkeeping platform. It builds on Phase 1 Foundation, Phase 2 Invoice Engine, Phase 3 Bank Reconciliation, Phase 4 AI Review and Alerting, and Phase 5 Dashboard and Reporting and introduces the first real external integration layer.

Phase 6 is the point where the platform moves from manually initiated bookkeeping workflows into externally fed automation workflows. The system already supports evidence handling, invoice workflows, reconciliation workflows, cross-domain review intelligence, and founder-facing reporting. This phase adds controlled external inputs such as email ingestion and Revolut integration, plus the underlying infrastructure required to handle sync, source traceability, retries, idempotency, and integration-safe failure recovery.

This phase is intentionally limited to integration intake, integration control, sync lifecycle behavior, source normalization, and integration-safe operational handling. It does not yet implement broad autonomous bookkeeping governance, final ledger posting, filing exports, period locking and amendment workflows, or advanced multi-provider connector maturity far beyond the selected first integrations.

The purpose of this phase is to make the platform capable of receiving bookkeeping evidence and transaction inputs automatically, while preserving the same trust, traceability, and review discipline already established in earlier phases.

---

## 2. Phase Objective

The objective of Phase 6 is to introduce real automation entry points into the bookkeeping platform without weakening evidence integrity, tenant safety, or accounting control.

At the end of Phase 6, the system should support:

- email-based document ingestion
- Revolut transaction integration
- integration connection records and lifecycle handling
- secure credential and connection management
- external-source traceability
- sync jobs and retry behavior
- idempotent import behavior
- integration-generated review items and alerts
- operational visibility into integration health and failures

At the end of Phase 6, the platform should be able to accept automatic inputs safely, explain where they came from, show whether they were processed cleanly, and surface anything that still needs human attention.

---

## 3. Phase Boundary

### Included in Phase 6
Phase 6 includes the first external integration layer and its supporting control model.

### Excluded from Phase 6
Phase 6 explicitly excludes:

- broad multi-bank connector framework maturity beyond selected initial integrations
- broad production-grade auto-approval of accounting outcomes
- broad production-grade auto-reconciliation across all categories
- final ledger posting logic
- filing exports
- period locking and amendment workflows
- advanced forecasting or BI integrations
- marketplace-style third-party integration ecosystem
- full autonomous bookkeeping governance model

This boundary must remain strict. Phase 6 introduces trustworthy automation inputs, not fully autonomous accounting finality.

---

## 4. Phase 6 Design Decisions

## 4.1 Integration posture

### Decision
Phase 6 introduces external integrations as first-class platform subsystems.

### Meaning
Integrations must not be implemented as hidden side paths or special-case hacks. Each integration must have:

- connection identity
- lifecycle state
- source traceability
- sync visibility
- failure visibility
- review and alert hooks
- auditability

### Reason
The architecture explicitly defines integrations as first-class system capabilities. Once external sources can change bookkeeping state, they must be treated with the same discipline as core accounting workflows.

---

## 4.2 Email ingestion posture

### Decision
Phase 6 introduces email ingestion as a real evidence-entry channel.

### Meaning
The system must support an email-based intake model in which:

- email-received accounting evidence can enter the platform automatically
- attachments can be extracted and preserved as source evidence
- source email metadata can be preserved in traceable form
- email-originated documents can enter the same invoice-processing pipeline as manually uploaded documents

### Important note
The platform does not need to treat the full raw email body as a primary accounting object unless operationally useful, but it must preserve enough metadata and linkage to explain where the document came from.

---

## 4.3 Revolut posture

### Decision
Phase 6 introduces Revolut as the first live transaction integration.

### Meaning
The system must support:

- secure Revolut connection setup
- controlled retrieval of transaction source data
- external reference preservation
- idempotent normalization into Transaction records
- sync status visibility
- review and alert generation for failures, ambiguity, or contradictory updates

### Important note
Phase 6 introduces live transaction intake, but not broad autonomous settlement or posting.

---

## 4.4 Source traceability posture

### Decision
All integration-derived objects must preserve their external-source lineage.

### Meaning
The platform must be able to answer:

- which integration created this object
- when it was synced
- what the external reference was
- whether it was imported once or updated later
- whether the imported record was idempotently recognized or newly created

### Reason
Once data arrives automatically, traceability becomes even more important than in manual flows.

---

## 4.5 Idempotency posture

### Decision
Phase 6 must treat idempotency as a core integration requirement.

### Meaning
The system must protect against:

- repeated import of the same external transaction as a new internal record
- repeated ingestion of the same email attachment as a distinct document without reason
- duplicate sync effects caused by retries, polling overlap, or partial failures

### Required principle
The platform must preserve source identity and handle repeated external deliveries safely.

---

## 4.6 Sync lifecycle posture

### Decision
Phase 6 introduces explicit sync lifecycle management.

### Meaning
The platform must support:

- sync start
- sync success
- sync partial success
- sync failure
- retry or replay behavior
- last successful sync visibility
- degraded connection visibility

### Reason
A platform that depends on automation inputs must make sync health visible. Invisible sync failure is a bookkeeping risk.

---

## 4.7 Failure and recovery posture

### Decision
Phase 6 introduces integration-safe failure handling and recovery behavior.

### Meaning
The platform must support:

- failed import detection
- partial import detection
- retry-safe processing
- review and alert creation when automation leaves bookkeeping incomplete
- visibility into unresolved integration failures

### Important note
Failure recovery must not create duplicate internal truth or destroy source context.

---

## 4.8 Security posture

### Decision
Integration credentials and connection state must be treated as highly sensitive control assets.

### Meaning
The platform must support:

- secure credential storage
- backend-only credential use
- no client-side exposure of privileged secrets
- permission-aware connection setup and management
- connection revocation and disablement

### Reason
An integration that can feed financial data into the system is effectively a privileged input channel and must be protected accordingly.

---

## 4.9 Automation posture

### Decision
Phase 6 introduces automated input, not broad autonomous accounting decision-making.

### Meaning
The system may automatically ingest and normalize incoming data, but must still respect the earlier review, alerting, and approval boundaries.

### Important rule
External ingestion does not create permission to bypass the trust model.

---

## 5. Scope of Phase 6 Modules

## 5.1 Integration connection model

Phase 6 must implement IntegrationConnection as a fully operational entity.

### Required fields
At minimum:

- company_id
- provider_name
- connection_type
- status
- sync_mode
- credential_reference
- last_sync_started_at nullable
- last_sync_completed_at nullable
- last_sync_status nullable
- last_error_summary nullable
- created_at / updated_at

### Required behavior
- create connection
- update connection configuration where allowed
- disable connection
- revoke connection
- inspect connection health

### Important note
Connection state must be visible in the product because it affects bookkeeping completeness.

---

## 5.2 Email ingestion module

Phase 6 must implement email ingestion as an operational intake channel.

### Required behavior
- define email ingestion pathway
- receive accounting-relevant messages or forwarded messages
- extract attachments
- preserve source email metadata sufficient for traceability
- create Document records and DocumentVersions for attachments
- connect email-originated documents to invoice intake workflows
- avoid duplicate document creation on repeated delivery where possible

### Minimum metadata posture
The system should preserve enough metadata to support:

- sender identity where available
- received timestamp
- source message reference where available
- attachment reference and relation to created Document

### Important rule
Email ingestion must feed the same controlled document pipeline used by manual uploads, not a separate undocumented shortcut.

---

## 5.3 Revolut integration module

Phase 6 must implement Revolut as a live transaction source.

### Required behavior
- configure Revolut connection securely
- trigger sync manually and/or on schedule
- retrieve transaction source records
- preserve external references
- normalize transactions into internal Transaction records
- avoid duplicate internal transactions on repeated sync
- track sync lifecycle and health
- create review items or alerts when imported data is incomplete, contradictory, or operationally risky

### Important note
Revolut sync should feed the same normalized transaction and reconciliation pipeline already built in earlier phases.

---

## 5.4 Import identity and deduplication layer

Phase 6 must implement a clear import-identity strategy.

### Required behavior
The system must be able to determine whether an externally received item is:

- a new object
- the same object delivered again
- an updated version of a previously imported object
- a contradictory or duplicate external source event

### Required support
The platform should preserve:

- external source object id where available
- provider name
- source channel
- first seen timestamp
- last seen timestamp
- import/update decision outcome

### Important rule
Idempotency logic must be inspectable and should never silently create competing internal truth.

---

## 5.5 Sync job orchestration

Phase 6 must implement integration-aware sync jobs.

### Required behavior
- create sync jobs for integration pulls or ingestion runs
- preserve job state and timing
- link sync jobs to IntegrationConnection
- support retry-safe execution
- support partial-success visibility
- preserve job-to-import lineage where meaningful

### Important note
Sync jobs are not just technical plumbing. They are part of the accounting control chain because they determine whether external bookkeeping inputs entered the system correctly.

---

## 5.6 Integration-generated review and alerting

Phase 6 must connect integration outcomes into the Phase 4 control model.

### Required review-item triggers
- incomplete imported transaction context
- contradictory source update
- ambiguous source mapping
- repeated failed sync attempts
- unresolved email attachment ambiguity where it blocks invoice handling

### Required alert triggers
- integration connection degraded
- sync failure
- partial sync
- repeated duplicate or idempotency conflict
- external source contradiction
- revoked or expired connection status

### Important rule
Integration alerts must behave like true operational bookkeeping alerts, not just technical developer logs.

---

## 5.7 Integration health visibility

Phase 6 must expose integration health into dashboard and reporting surfaces.

### Required capabilities
- show connection status
- show last successful sync
- show failed or degraded syncs
- show unresolved integration-generated review items and alerts
- allow navigation into integration-specific detail view

### Important note
Automation without health visibility is not operationally trustworthy.

---

## 5.8 Integration audit hardening

Phase 6 must deepen audit coverage for connection setup, sync events, import decisions, and integration failure handling.

### Additional audit-covered actions
- connection created
- connection configuration changed
- connection disabled or revoked
- sync started
- sync succeeded, partially succeeded, or failed
- email message ingested where policy requires
- attachment imported into document pipeline
- external transaction imported or recognized idempotently
- contradictory source update handled
- integration alert resolved or dismissed

---

## 6. Required Phase 6 Data Model Changes

Phase 6 builds on earlier phases and requires the following entities in fully operational form:

- IntegrationConnection
- ProcessingJob
- Document
- DocumentVersion
- Invoice
- Statement where integration source linkage applies
- Transaction
- ReviewItem
- Alert
- AuditEvent

### Additional strongly recommended support structures
Phase 6 should introduce operational support structures such as:

- ExternalSourceReference or equivalent source-lineage model
- SyncRun or equivalent integration-sync artifact model
- ImportDecisionRecord or equivalent idempotency outcome model
- EmailIngestionRecord or equivalent source-email artifact model
- IntegrationHealthSnapshot or equivalent health-view support model

### Important modeling principle
The system must preserve the distinction between:
- integration connection
- sync execution attempt
- external source identity
- imported internal object
- review/alert control object

These must not be collapsed into one generic integration row.

---

## 7. Phase 6 State Behavior

## 7.1 IntegrationConnection states in scope

Phase 6 must operationalize:
- unconfigured
- configuring
- active
- syncing
- degraded
- disconnected
- revoked

### Important rule
Connection state must reflect operational trust. A degraded or disconnected integration must remain visible until recovered or revoked.

---

## 7.2 SyncRun or sync-job states in scope

Phase 6 must operationalize sync execution states such as:
- queued
- running
- succeeded
- partially_succeeded
- failed
- cancelled

### Important rule
A partially succeeded sync must remain visible and must not be reported as clean success.

---

## 7.3 Email-ingestion outcome posture

Phase 6 does not require a standalone complex state machine for email messages unless needed by the implementation, but the system must at minimum distinguish outcomes such as:
- received
- attachments_extracted
- imported
- partially_imported
- failed
- duplicate_or_already_processed

### Important rule
Repeated delivery must not create uncontrolled duplicate document truth.

---

## 7.4 Imported object states

Phase 6 does not redefine the document, invoice, transaction, review, or alert state machines created earlier.

### Required principle
Integration flows must feed those existing state machines and trust layers rather than create parallel alternative state worlds.

---

## 8. Required Backend Operations in Phase 6

Every critical backend operation must continue to follow the trusted pattern:
1. authenticate request where user-driven
2. validate tenant scope and permission
3. execute secure integration or ingestion action
4. create or update structured internal records
5. create audit and control artifacts
6. return updated operational state

### Required backend operations
- create integration connection
- update integration connection
- disable or revoke integration connection
- trigger integration sync
- process sync result
- create or update external source reference
- perform idempotent import decision
- ingest email message or forwarded payload
- extract and import attachments into document pipeline
- import external transaction source into normalized transaction pipeline
- create integration-generated review item
- create integration-generated alert
- fetch integration health summary
- fetch integration sync history

---

## 9. Storage, Security, and Credential Rules

Phase 6 adds integration-specific security requirements.

### Required rules
- credentials must be stored securely and referenced indirectly
- no client-side permanent access to privileged integration secrets
- sensitive connection changes must be permission-controlled
- imported attachments must still use the standard document vault and versioning model
- import logs and source references must remain tenant-scoped

### Important rule
An integration must never bypass the platform’s evidence-preservation model just because its data arrives automatically.

---

## 10. Security and Permission Rules

Phase 6 builds on earlier RBAC and introduces integration-specific permissions.

### Founder and Admin
May:
- create, configure, disable, and revoke integrations
- trigger syncs
- view integration health and sync history
- resolve integration-generated review items and alerts
- inspect imported source context where allowed

### Accountant
May:
- view integration health and sync outcomes where allowed
- inspect imported accounting objects and related review context
- resolve integration-generated accounting review items where allowed

May not by default:
- configure or revoke integrations
- manage credentials

### Reviewer
May:
- view integration-generated review items and alerts where relevant
- inspect resulting accounting object context

May not by default:
- manage connections
- trigger syncs
- inspect sensitive credential or provider setup information

### Important implementation note
Connection management permissions must be stricter than normal object-edit permissions because integration setup controls future bookkeeping input channels.

---

## 11. Validation and Integration Control Rules

## 11.1 Idempotency rules

The system must prevent repeated external delivery from creating uncontrolled duplicate internal truth.

This must apply to:
- repeated email attachment ingestion
- repeated transaction sync delivery
- retry-induced duplicate import attempts

## 11.2 Sync failure rules

The system must create alerts and/or review posture when:
- sync fails completely
- sync partially succeeds
- source data is contradictory or incomplete
- connection state is degraded or revoked

## 11.3 Review routing rules

The system must route integration outcomes into review when:
- imported data cannot be mapped cleanly into existing pipelines
- contradictory source updates appear
- idempotency cannot be confidently resolved
- imported content creates material bookkeeping ambiguity

## 11.4 Non-authoritative automation rule

Integration-originated data is still subject to the same trust model as manual data. It must not bypass validation, review, approval, or reconciliation boundaries simply because the source is automated.

---

## 12. Audit Requirements

Every meaningful integration-control and import action must generate an audit event.

### Additional minimum audit contents where relevant
- provider name
- connection id
- sync run or job id
- external reference where meaningful
- import decision outcome
- actor identity or system identity
- tenant/company scope
- timestamp

### Minimum Phase 6 audit coverage
- connection created
- connection updated
- connection disabled or revoked
- sync started
- sync succeeded, partially succeeded, failed, or cancelled
- email-ingested source imported
- attachment imported to document pipeline
- external transaction imported or recognized as already known
- contradictory source update recorded
- integration-generated alert created, resolved, dismissed, or expired
- integration-generated review item created, resolved, dismissed, or escalated

---

## 13. Acceptance Criteria

Phase 6 is complete only when all of the following are true:

1. The platform can create and manage IntegrationConnection records.
2. The platform can ingest accounting-relevant email input and extract attachments into the standard document pipeline.
3. The platform preserves traceable email-source metadata sufficient to explain document origin.
4. The platform can connect to Revolut securely and retrieve transaction source data.
5. The platform can normalize Revolut transaction inputs into the existing transaction pipeline without bypassing trust boundaries.
6. The platform can preserve external source references and idempotently decide whether an item is new, already known, updated, or contradictory.
7. The platform can create sync jobs or sync runs with explicit state and history.
8. The platform can surface integration health, degraded state, and sync failure visibility.
9. The platform can create integration-generated review items and alerts when automation leaves bookkeeping incomplete or risky.
10. No Phase 6 feature silently creates duplicate internal truth from repeated external delivery.
11. No Phase 6 feature bypasses evidence preservation, validation, review, approval, or reconciliation boundaries simply because data came from an integration.
12. All critical integration and import actions are auditable.
13. No Phase 6 feature implements final ledger posting, filing exports, or broad autonomous bookkeeping governance under the integration label.

---

## 14. Items Explicitly Deferred After Phase 6

The following remain out of scope after this phase and must be handled in later dev-specs or future design work:

- broad multi-provider banking framework
- broad autonomous approval and reconciliation governance
- final ledger posting logic
- filing exports
- period locking and amendment
- advanced forecasting or BI integrations
- marketplace-scale connector ecosystem
- fully autonomous bookkeeping governance model
- Cyprus tax-rule completeness for filing-grade outputs

---

## 15. Implementation Order Recommendation

The recommended implementation order inside Phase 6 is:

1. IntegrationConnection model and permission boundaries
2. sync-run and import-identity support structures
3. email ingestion pipeline into document intake
4. Revolut connection and transaction retrieval flow
5. idempotent import decision layer
6. integration-generated review and alert hooks
7. integration health visibility and audit hardening

This sequence ensures that the system first becomes capable of representing and controlling external connections before it starts consuming live external bookkeeping inputs at scale.

---

## 16. Final Phase 6 Summary

Phase 6 turns the platform from a manually driven bookkeeping system into one that can safely accept automatic external inputs. It introduces email ingestion, Revolut integration, sync lifecycle handling, source traceability, idempotent import behavior, and integration-generated review and alert control.

At the end of this phase, the platform will be able to receive bookkeeping evidence and transaction data automatically while preserving tenant safety, evidence integrity, review discipline, and auditability. It still stops short of broad autonomous accounting governance, final posting, filing, and period-control finality. That boundary is intentional and necessary for maintaining trust and architectural discipline.

