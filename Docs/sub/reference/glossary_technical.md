# Technical Glossary

**Block:** Cross-cutting
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

Definitions for technical terms used across the platform codebase, documentation,
and architecture. Terms are listed alphabetically within each section. Where a term
has a specific meaning that differs from general industry usage, the platform-specific
meaning is given first.

---

## Enumerations

**run_status_enum**
The lifecycle states of a workflow run. Stored in the `workflow_runs.status` column.
Related terms: finalization gate, compensating transaction.

Values:
- `CREATED` — Run row has been inserted but phase execution has not started.
- `RUNNING` — Phase execution is in progress. The engine is advancing through phases.
- `PAUSED` — Execution is suspended, typically awaiting a user action or an asynchronous
  response (e.g. bank feed reconnect). Can be manually resumed.
- `REVIEW_HOLD` — One or more review issues in the review queue are blocking phase
  advancement. Execution resumes automatically when all blocking issues are resolved.
- `AWAITING_APPROVAL` — The run has reached a phase that requires explicit accountant or
  owner approval before continuing. The approval gate is checked before each advance.
- `FINALIZING` — The finalization sequence is running: ledger locked, archive bundle
  created and promoted to WORM storage, RFC 3161 timestamp applied.
- `FINALIZED` — Finalization completed successfully. The run is immutable.
- `FAILED` — An unrecoverable error has halted execution. Human investigation is required.
- `CANCELLED` — The run was explicitly cancelled before finalization. A cancelled run
  may be re-created for the same period.
- `COMPENSATING` — A compensating transaction sequence is running to undo the effects
  of a partially-executed or failed run.

**dedup_status_enum**
The deduplication status of an ingested document or transaction. Values: `UNIQUE`,
`DUPLICATE_EXACT` (SHA-256 match), `DUPLICATE_NEAR` (fuzzy match above threshold),
`PENDING_REVIEW` (similarity is ambiguous). Related terms: idempotency key.

**match_level_enum**
Confidence level assigned to a document-transaction match by the matching engine. See
`match_level_enum.md` for the full value list. Representative values: `EXACT` (hash
match), `HIGH` (strong signal match above threshold), `MEDIUM`, `LOW`, `UNMATCHED`.
Related terms: MATCHING_AUTO_CONFIRMED, review queue.

**invoice_status_enum**
Lifecycle states of a tax invoice. Values: `DRAFT` (editable, not sent), `SENT`
(delivered to recipient), `PARTIALLY_PAID` (one or more partial payments recorded),
`PAID` (balance settled in full), `OVERDUE` (past due date, balance outstanding),
`VOID` (cancelled; a credit note has been or will be issued). Rounding on all monetary
values uses HALF_UP. Related terms: credit note, pro-forma invoice.

---

## Storage and Data Architecture

**Processing zone**
The Supabase Storage bucket (`processing-zone`) where raw uploaded documents are held
during OCR, parsing, and classification. Objects are automatically deleted after 7 days
by the TTL purge job. The zone should remain small in steady state. Related terms:
Archive zone, Export-temp zone.

**Operational zone**
The Supabase Storage bucket (`operational`) holding processed previews, thumbnails, and
working copies of documents. Objects in this zone are deleted when the parent document
row is deleted. Grows moderately with the document count. Related terms: Processing zone.

**Archive zone**
The Supabase Storage bucket (`archive-zone`) where finalized, RFC 3161-timestamped
archive bundles are permanently stored. This bucket is configured with Object Lock
(WORM). No TTL. The archive zone grows at approximately 50 MB per active business entity
per year. Related terms: WORM storage, RFC 3161 timestamp, Object Lock.

**Export-temp zone**
The Supabase Storage bucket (`export-temp`) holding exports generated for user download.
Objects are automatically purged 24 hours after creation by the export cleanup scheduled
job. Should be near-zero in steady state. Related terms: Processing zone.

**WORM storage**
Write Once Read Many. A storage configuration in which written objects cannot be
overwritten or deleted within a defined retention period. Implemented via Supabase
Storage Object Lock on the archive-zone bucket. Enforces the 7-year document retention
obligation under Cyprus tax law. Related terms: Object Lock, Archive zone.

**Object Lock**
The Supabase Storage (and underlying S3-compatible) feature that enforces WORM
semantics by setting a retention period on individual objects. Once locked, the object
cannot be deleted or replaced until the retention period expires. The platform sets a
retention period of 7 years on all archive bundle objects at the time of promotion.
Related terms: WORM storage, Archive zone.

**hash chain**
An integrity mechanism where each audit event record stores the SHA-256 hash of the
concatenation of the previous event's hash and the current event's canonical JSON
payload. This produces a tamper-evident chain: modifying any event invalidates the hash
of all subsequent events. The platform maintains three separate chains: global, per-org,
and per-business. Related terms: audit event, ARCHIVE_BUNDLE_PROMOTED.

---

## Authentication and Security

**JWT claim**
A key-value assertion embedded in a JSON Web Token (JWT). The platform extends Supabase's
standard JWT claims with custom claims such as `org_id`, `business_ids`, `role`, and
`aal` (Authentication Assurance Level). Custom claims are set by an Auth hook at login
time and used by RLS policies. Related terms: RLS, step-up authentication.

**RLS (Row Level Security)**
PostgreSQL's built-in access control mechanism that filters rows based on the current
session context. The platform uses RLS as the primary multi-tenancy enforcement layer.
Every table that stores business data has RLS policies that restrict access to the
`business_entity_id` values present in the authenticated user's JWT claims.
Related terms: JWT claim, supabase_project_config.

**step-up authentication**
An additional authentication challenge (TOTP verification) required before performing
high-risk operations (period lock, role change, finalization approval). The user must
complete a step-up challenge that produces a short-lived, purpose-bound token. The token
is consumed on the first use and cannot be reused. Related terms: JWT claim, MFA.

**idempotency key**
A caller-supplied unique identifier (`X-Idempotency-Key` header) that allows a mutating
request to be safely retried. If the server has already processed a request with the
same key within the 24-hour window, it returns the original response without
re-executing the operation. Related terms: dedup_status_enum.

---

## Identifiers

**gen_uuid_v7()**
A PostgreSQL function that generates a UUID version 7 (time-ordered). UUIDv7 encodes
the creation timestamp in the most significant bits, making it monotonically sortable
by `id` column. Used as the default primary key generator for all business entity tables.
Preferred over `gen_random_uuid()` for PKs because it provides natural ordering without
a separate `created_at` sort. Related terms: gen_random_uuid().

**gen_random_uuid()**
A PostgreSQL function that generates a UUID version 4 (random). Used for non-PK
identifiers where time ordering is not needed (e.g. webhook delivery IDs, idempotency
key storage). Related terms: gen_uuid_v7().

---

## Finance and Accounting

**VIES**
VAT Information Exchange System. An EU service for validating VAT registration numbers
of counterparties in other EU member states. The platform calls the VIES API before
creating or updating supplier records to confirm the VAT number is active.
Related terms: ECB rate, cyprus_vat_rule_catalog.

**ECB rate**
The European Central Bank foreign exchange reference rate. The platform fetches ECB
rates daily and caches them in the `ecb_fx_rate_cache` table. Used for converting
non-EUR transactions to EUR for VAT calculation. If the ECB rate is unavailable for a
given date, the previous available date's rate is used. Related terms: VIES,
ecb_rate_unavailable_runbook.

**pro-forma invoice**
An invoice issued before the goods or services are delivered, used to confirm the
order details and amount. A pro-forma invoice does not create a tax obligation. In the
platform, a pro-forma invoice has `invoice_status = DRAFT` and a flag `is_proforma = true`.
It cannot be submitted to the Cyprus Tax Department in place of a VAT invoice.
Related terms: invoice_status_enum, credit note.

**credit note**
A document issued to partially or fully cancel a previously issued invoice. Creates a
negative ledger entry offsetting the original invoice amount. A credit note is required
when voiding an invoice that has been sent. Related terms: pro-forma invoice,
invoice_status_enum (VOID).

**ledger entry**
A single debit or credit record in the double-entry bookkeeping system. Every financial
event (invoice, payment, VAT adjustment) produces one or more ledger entries. Ledger
entries are immutable once created; corrections are made via compensating entries.
Related terms: double-entry bookkeeping, compensating transaction, LEDGER_ENTRY_CREATED.

**double-entry bookkeeping**
An accounting system in which every transaction is recorded as both a debit in one
account and an equal credit in another account. The platform enforces that the sum of
all debit amounts equals the sum of all credit amounts within a closed period. Any
imbalance triggers a review issue. Related terms: ledger entry, period lock.

**compensating transaction**
A transaction that reverses or offsets the effects of a prior transaction that must be
undone. Used when a run in COMPENSATING status needs to roll back partial ledger
entries or reverse a VAT posting. Compensating transactions are themselves immutable
ledger entries; they do not delete the original entries. Related terms: run_status_enum
(COMPENSATING), ledger entry.

**period lock**
The state in which a financial period's ledger is closed to further modifications.
Once a period is locked, new ledger entries for that period are blocked unless an
authorised period lock override is executed (which requires step-up authentication and
produces an audit event). Related terms: finalization gate, step-up authentication.

**finalization gate**
A set of pre-conditions that must all be satisfied before a run can transition to
FINALIZING status. Gate conditions include: all review issues resolved, bank statement
reconciliation complete, VAT calculation validated, and period not previously finalized.
Failure of any gate condition returns `ENGINE_GATE_FAILED`. Related terms: run_status_enum,
period lock.

---

## Deployment

**canary deployment**
A deployment strategy in which a new version is initially served to a small percentage
of traffic (typically 5–10%), with monitoring in place, before full rollout. Used for
significant tool or AI model changes to limit blast radius if a regression is
introduced. Related terms: run_status_enum, audit event.

**feedback loop**
The process by which accountant overrides of AI classification decisions are collected,
labelled, and fed back into the training dataset for the next model version. The
feedback loop is the primary mechanism for improving classification accuracy over time.
Related terms: AI_CLASSIFICATION_OVERRIDDEN, high_classification_error_rate_runbook.

---

## Compliance

**RFC 3161 timestamp**
A cryptographic timestamp token issued by a trusted Timestamp Authority (TSA) that
proves a document existed in its current form at a specific time. The platform applies
RFC 3161 tokens to archive bundles at finalization. This satisfies the Cyprus tax
requirement for tamper-evident long-term document storage. Related terms: WORM storage,
Archive zone, ARCHIVE_BUNDLE_PROMOTED.

---

## Related Documents

- `/Docs/sub/reference/audit_event_taxonomy.md`
- `/Docs/sub/reference/run_phase_enum.md`
- `/Docs/sub/reference/match_level_enum.md`
- `/Docs/sub/reference/match_status_enum.md`
- `/Docs/sub/reference/workflow_state_enum.md`
- `/Docs/sub/reference/vat_rate_table_reference.md`
- `/Docs/sub/reference/glossary.md`
