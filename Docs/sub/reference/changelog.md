# System Changelog

**Namespace:** N/A (cross-cutting)  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

This changelog records significant releases to the Cyprus bookkeeping SaaS platform. Entries follow the format: version, release date, summary, breaking changes, new features, and bug fixes.

Versions below v1.0 are considered pre-release. Breaking changes during pre-release do not require a deprecation window but must be documented here before merge.

---

## v0.6 — 2026-03-14

**Summary:** Review queue overhaul with issue grouping, bulk actions, and snooze carry-forward.

### Breaking Changes

- `review_issues.status` column: `OPEN` and `IN_PROGRESS` statuses merged into `OPEN`. Any client code checking for `IN_PROGRESS` must be updated to use `OPEN`. Migration: `20260312_review_issues_status_enum_migration.sql`.
- Review queue API endpoint `/api/review/items` now returns a paginated envelope (`{ data, meta, cursor }`) instead of a plain array. Callers must update pagination logic.

### New Features

- Issue grouping: issues of the same type within a period are grouped into a single card in the review queue UI. Group cards expand to show individual items.
- Bulk actions: accountants can approve, dispute, or snooze multiple Low and Medium severity items in a single action.
- Snooze carry-forward: snoozed items automatically resurface at the start of the next period if not resolved.
- Rescan on resolution: resolving a classification issue triggers a re-evaluation of related unmatched payments in the same period.
- New `REVIEW.ISSUE_SNOOZED` and `REVIEW.ISSUE_CARRY_FORWARDED` audit events added to taxonomy.

### Bug Fixes

- Fixed a race condition where two concurrent review approvals on the same issue could both succeed, leaving the issue in an inconsistent state. Resolution records are now written with an optimistic lock check.
- Fixed incorrect severity calculation for `UNMATCHED_PAYMENT` issues when the payment amount was below the rounding threshold.
- Fixed bulk action endpoint returning a 500 when the action set contained a mix of resolvable and already-resolved items.

---

## v0.5 — 2025-12-01

**Summary:** Archive and finalization pipeline — period lock, bundle generation, hash-chain verification, and step-up auth for archive access.

### Breaking Changes

- `periods.status` now includes `FINALIZED` as a terminal state. Previously finalized periods were marked `CLOSED`. A migration renames existing `CLOSED` values to `FINALIZED`.
- The finalization endpoint requires step-up MFA for all users. Clients that bypassed MFA for service accounts will receive `403 STEP_UP_REQUIRED`.

### New Features

- Period finalization: accountants can finalize a period after all review queue items are resolved. Finalization locks ledger entries and triggers archive bundle generation.
- Archive bundle: a deterministic ZIP containing signed ledger entries, matched invoices, and the period audit log slice is generated per finalized period.
- Hash-chain verification: each archive bundle is chained to the previous bundle's hash. Integrity checks run as a scheduled job (`ARCHIVE_INTEGRITY_CHECK`).
- Step-up authentication required for archive download and period unlock actions.
- `ARCHIVE.BUNDLE_GENERATED`, `ARCHIVE.INTEGRITY_CHECK_PASSED`, `ARCHIVE.INTEGRITY_CHECK_FAILED` audit events added.

### Bug Fixes

- Fixed an issue where ledger entries created in the final hour of a period could be excluded from the finalization snapshot due to a timezone conversion error.
- Fixed archive bundle generation failing silently when a document file was missing from storage.

---

## v0.4 — 2025-09-10

**Summary:** VIES integration for EU VAT number validation and counterparty enrichment.

### Breaking Changes

- None.

### New Features

- VIES validation: VAT numbers on incoming invoices and counterparty records are validated against the EU VIES service. Validation results are cached per `vies_quarterly_eligibility_policy.md`.
- Counterparty enrichment: validated VIES records populate the counterparty's legal name and country automatically.
- VIES submission tracking: businesses registered for EU VAT can log their quarterly VIES submissions. The system generates a summary XML file; submission to the Cyprus Tax Department is manual.
- `CLIENT_VAT.VALIDATED`, `CLIENT_VAT.VALIDATION_FAILED`, `VIES.SUBMISSION_LOGGED` audit events added.
- New `vies_validation_cache` table with per-record TTL and staleness refresh via `VIES_SYNC` scheduled job.

### Bug Fixes

- Fixed counterparty resolver incorrectly merging two distinct legal entities that share a trading name.
- Fixed VIES API timeout not being surfaced to the user — previously silently fell back to unvalidated, now returns a warning in the review queue.

---

## v0.3 — 2025-06-20

**Summary:** AI classification engine — multi-tier inference, confidence scoring, override memory, and vendor memory.

### Breaking Changes

- Classification is now required before matching. Documents that bypassed classification in v0.2 must be reclassified before matching can proceed. A backfill migration sets these to confidence 0 so they appear in the review queue.

### New Features

- AI classification: each transaction and document is classified against the chart of accounts using a three-tier model pipeline (rule-based → fast LLM → deliberate LLM). Tier routing is based on confidence thresholds per `classification_confidence_policy.md`.
- Confidence scoring: each classification result carries a 0–100 confidence score. Items below the review threshold appear in the review queue automatically.
- Override memory: accountant corrections are stored in vendor memory and applied to future transactions from the same counterparty.
- Bulk classification endpoint for processing multiple items in a single API call.
- AI usage tracking: token consumption and model version are recorded per classification in `ai_usage_records`.
- `CLASSIFICATION.AUTO_CLASSIFIED`, `CLASSIFICATION.MANUALLY_OVERRIDDEN`, `CLASSIFICATION.ESCALATED_TO_REVIEW` audit events added.

### Bug Fixes

- Fixed classification results not being invalidated when a counterparty's VAT status changed.
- Fixed a prompt injection vulnerability in the vendor name extraction step. Vendor names are now sanitised before inclusion in prompts.

---

## v0.2 — 2025-03-15

**Summary:** Bank feed integration via Nordigen, automated transaction ingestion, and deduplication.

### Breaking Changes

- The `/api/statements/upload` endpoint now requires a `source_format` field in the request body (`NORDIGEN`, `CSV_REVOLUT`, `CSV_ALPHA_BANK`, `MT940`). Requests without this field return 422.

### New Features

- Nordigen integration: business entities can connect their Cyprus bank accounts (Bank of Cyprus, Alpha Bank Cyprus, Revolut Cyprus) via the Nordigen Open Banking API. Transactions are pulled hourly via the `BANK_SYNC` scheduled job.
- Automatic transaction deduplication: duplicate transactions from repeated sync calls are detected and discarded using a fingerprint hash of amount, date, counterparty, and reference.
- Bank statement upload: supports manual CSV and MT940 uploads for banks not yet connected via Nordigen.
- `BANK_FEED.CONNECTED`, `BANK_FEED.SYNC_COMPLETED`, `BANK_FEED.TRANSACTION_INGESTED`, `STATEMENT.UPLOADED` audit events added.

### Bug Fixes

- Fixed Nordigen OAuth redirect failing when the user's browser blocked third-party cookies.
- Fixed MT940 parser truncating counterparty names longer than 35 characters.

---

## v0.1 — 2025-01-08

**Summary:** Foundation release — multi-tenant structure, authentication, org management, document intake, and OCR.

### Breaking Changes

- None (initial release).

### New Features

- Multi-tenant architecture: each business entity is isolated via row-level security. All data is scoped to `business_entity_id`.
- Authentication: email/password, magic link, and OAuth (Google) via Supabase Auth. MFA enrollment required for OWNER and ADMIN roles.
- Org management: invitation flow, role assignment (OWNER, ADMIN, ACCOUNTANT, VIEWER), and capacity limits.
- Document intake: file upload endpoint accepts PDF, PNG, JPG, HEIC. File size limit 50 MB. Content sniffing validates MIME type before storage.
- OCR: uploaded documents are processed by the OCR engine (max 50 pages per document). Extracted fields: vendor, date, total, VAT amount, line items.
- Chart of accounts: default Cyprus chart of accounts seeded for new business entities. Custom account codes can be added.
- Audit log: all state-changing actions emit structured audit events stored in `audit_log`.

### Bug Fixes

- None (initial release).

---

## Related Documents

- `reference/known_limitations.md` — Current constraints and planned resolutions
- `reference/technical_architecture_overview.md` — System architecture background
- `policies/supabase_migration_tooling_policy.md` — Migration conventions referenced in breaking change entries
